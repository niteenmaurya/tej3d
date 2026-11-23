import 'dart:math' as math;

import '../math/vec.dart';

import '../editor/inspector.dart';
import '../engine/game_object.dart';
import 'audio_backend.dart';

/// How a sound gets quieter with distance.
enum AudioRolloff {
  /// Falls in a straight line from [AudioSource.minDistance] to [AudioSource.maxDistance], silent beyond.
  linear,

  /// Real-world style 1/distance. Never quite silent; cut to 0 beyond max distance.
  inverse,
}

/// Works out how each sound should be heard (volume, left/right, pitch) and
/// tells the [AudioBackend]. Call [update] once per frame, after objects moved.
///
/// ```dart
/// final audio = AudioSystem(backend);
/// camera.addComponent(AudioListener(audio));
/// emitter.addComponent(AudioSource(audio, clip: engineLoop, loop: true, playOnAwake: true));
/// audio.playOneShot(explosion, position: pos, group: 'sfx');
/// // each frame:
/// audio.update(dt);
/// ```
class AudioSystem {
  AudioSystem(this.backend);

  final AudioBackend backend;

  /// Volume of everything, 0..1.
  double masterVolume = 1.0;

  /// 0 turns doppler off, 1 is real life, higher exaggerates.
  double dopplerFactor = 1.0;

  /// Speed of sound in m/s, for doppler.
  double speedOfSound = 343.0;

  /// The pitch is kept between these.
  double minPitch = 0.25, maxPitch = 4.0;

  final Map<String, double> _groups = {};
  final Set<String> _muted = {};

  AudioListener? listener;
  final List<AudioSource> _sources = [];
  final List<_OneShot> _oneShots = [];

  /// Volume of a group such as `'music'` or `'sfx'`. Unknown groups are 1.
  double groupVolume(String group) => _groups[group] ?? 1.0;
  void setGroupVolume(String group, double v) => _groups[group] = v.clamp(0.0, 1.0);
  void muteGroup(String group, bool muted) => muted ? _muted.add(group) : _muted.remove(group);
  bool isGroupMuted(String group) => _muted.contains(group);

  /// Number of sounds playing now (components and one shots).
  int get activeVoices =>
      _sources.where((s) => s.isPlaying).length + _oneShots.length;

  /// Plays [clip] once and forgets it. With [position] it is heard in 3D;
  /// without, it plays flat (menus, music).
  int playOneShot(
    AudioClip clip, {
    Vector3? position,
    double volume = 1.0,
    double pitch = 1.0,
    String group = 'sfx',
    double minDistance = 1.0,
    double maxDistance = 50.0,
    AudioRolloff rolloff = AudioRolloff.inverse,
  }) {
    final shot = _OneShot(
      position?.clone(),
      volume,
      pitch,
      group,
      minDistance,
      maxDistance,
      rolloff,
    );
    final m = _mix(
      position: shot.position,
      velocity: null,
      volume: volume,
      pitch: pitch,
      group: group,
      minDistance: minDistance,
      maxDistance: maxDistance,
      rolloff: rolloff,
    );
    shot.voice = backend.play(clip, volume: m.volume, pan: m.pan, pitch: m.pitch, loop: false);
    _oneShots.add(shot);
    return shot.voice;
  }

  /// Stops everything.
  void stopAll() {
    for (final s in List<AudioSource>.of(_sources)) {
      s.stop();
    }
    for (final o in _oneShots) {
      backend.stop(o.voice);
    }
    _oneShots.clear();
  }

  /// Call once per frame with the time since the last frame.
  void update(double dt) {
    _oneShots.removeWhere((o) {
      if (!backend.isPlaying(o.voice)) return true;
      final m = _mix(
        position: o.position,
        velocity: null,
        volume: o.volume,
        pitch: o.pitch,
        group: o.group,
        minDistance: o.minDistance,
        maxDistance: o.maxDistance,
        rolloff: o.rolloff,
      );
      backend.update(o.voice, volume: m.volume, pan: m.pan, pitch: m.pitch);
      return false;
    });
    listener?._track(dt);
    for (final s in List<AudioSource>.of(_sources)) {
      s._tick(dt);
    }
  }

  /// Frees the backend.
  void dispose() {
    stopAll();
    backend.dispose();
  }

  // ---- the math: how loud, which side, how fast.

  _Mix _mix({
    required Vector3? position,
    required Vector3? velocity,
    required double volume,
    required double pitch,
    required String group,
    required double minDistance,
    required double maxDistance,
    required AudioRolloff rolloff,
    bool spatial = true,
  }) {
    var vol = volume * masterVolume * groupVolume(group);
    if (_muted.contains(group)) vol = 0;
    var pan = 0.0;
    var p = pitch;
    final l = listener;
    if (spatial && position != null && l != null) {
      final toSource = position - l.position;
      final dist = toSource.length;
      vol *= attenuation(dist, minDistance, maxDistance, rolloff);
      if (dist > 1e-4) {
        final dir = toSource / dist;
        // Left/right from where the sound is, fading to centre when it is very close.
        final side = dir.dot(l.rightVector);
        final nearFade = math.min(1.0, dist / math.max(minDistance, 1e-3));
        pan = side * nearFade;
        if (dopplerFactor > 0) {
          final vl = l.velocity.dot(dir);                       // listener towards source
          final vs = (velocity ?? Vector3.zero()).dot(dir);     // source moving away along dir
          final c = speedOfSound;
          final vlc = (vl * dopplerFactor).clamp(-c * 0.5, c * 0.5);
          final vsc = (vs * dopplerFactor).clamp(-c * 0.5, c * 0.5);
          p *= (c + vlc) / (c + vsc);
        }
      }
    }
    return _Mix(vol.clamp(0.0, 1.0), pan.clamp(-1.0, 1.0), p.clamp(minPitch, maxPitch));
  }

  /// Volume (0..1) of a sound at [distance] meters.
  static double attenuation(double distance, double minDistance, double maxDistance, AudioRolloff rolloff) {
    if (distance <= minDistance) return 1.0;
    if (distance >= maxDistance) return 0.0;
    switch (rolloff) {
      case AudioRolloff.linear:
        return 1.0 - (distance - minDistance) / (maxDistance - minDistance);
      case AudioRolloff.inverse:
        return minDistance / distance;
    }
  }
}

class _Mix {
  _Mix(this.volume, this.pan, this.pitch);
  final double volume, pan, pitch;
}

class _OneShot {
  _OneShot(this.position, this.volume, this.pitch, this.group, this.minDistance, this.maxDistance, this.rolloff);
  final Vector3? position;
  final double volume, pitch, minDistance, maxDistance;
  final String group;
  final AudioRolloff rolloff;
  int voice = -1;
}

/// The ears. Put one on the camera or the player. Only one is used.
class AudioListener extends Component {
  AudioListener(this.audio);

  final AudioSystem audio;

  Vector3 position = Vector3.zero();
  Vector3 velocity = Vector3.zero();
  Vector3 rightVector = Vector3(1, 0, 0);
  bool _first = true;

  @override
  void awake() {
    audio.listener = this;
    _read();
    _first = false;
  }

  void _read() {
    position = transform.worldPosition;
    rightVector = transform.right;
  }

  void _track(double dt) {
    final old = position;
    _read();
    velocity = (_first || dt <= 0) ? Vector3.zero() : (position - old) / dt;
    _first = false;
  }

  @override
  void onDestroy() {
    if (identical(audio.listener, this)) audio.listener = null;
  }
}

/// A thing that makes sound. Needs an [AudioListener] to be heard in 3D.
class AudioSource extends Component implements Inspectable {
  AudioSource(
    this.audio, {
    this.clip,
    this.volume = 1.0,
    this.pitch = 1.0,
    this.loop = false,
    this.spatial = true,
    this.group = 'sfx',
    this.minDistance = 1.0,
    this.maxDistance = 50.0,
    this.rolloff = AudioRolloff.inverse,
    this.playOnAwake = false,
  });

  final AudioSystem audio;
  AudioClip? clip;
  double volume, pitch, minDistance, maxDistance;
  bool loop, spatial, playOnAwake;
  String group;
  AudioRolloff rolloff;

  int _voice = -1;
  bool _paused = false;
  Vector3? _lastPos;
  Vector3 _velocity = Vector3.zero();

  bool get isPlaying => _voice >= 0 && audio.backend.isPlaying(_voice);
  bool get isPaused => _paused;

  /// Starts the clip from the beginning (stops it first if it is playing).
  void play() {
    final c = clip;
    if (c == null) return;
    stop();
    final m = _compute();
    _voice = audio.backend.play(c, volume: m.volume, pan: m.pan, pitch: m.pitch, loop: loop);
    _paused = false;
  }

  void stop() {
    if (_voice >= 0) audio.backend.stop(_voice);
    _voice = -1;
    _paused = false;
  }

  void pause() {
    if (isPlaying && !_paused) {
      audio.backend.pause(_voice);
      _paused = true;
    }
  }

  void resume() {
    if (_voice >= 0 && _paused) {
      audio.backend.resume(_voice);
      _paused = false;
    }
  }

  @override
  void awake() {
    audio._sources.add(this);
    _lastPos = transform.worldPosition;
    if (playOnAwake) play();
  }

  _Mix _compute() => audio._mix(
        position: transform.worldPosition,
        velocity: _velocity,
        volume: volume,
        pitch: pitch,
        group: group,
        minDistance: minDistance,
        maxDistance: maxDistance,
        rolloff: rolloff,
        spatial: spatial,
      );

  void _tick(double dt) {
    final p = transform.worldPosition;
    final last = _lastPos;
    _velocity = (last == null || dt <= 0) ? Vector3.zero() : (p - last) / dt;
    _lastPos = p;
    if (_voice < 0) return;
    if (!audio.backend.isPlaying(_voice)) {
      if (!_paused) _voice = -1;
      return;
    }
    final m = _compute();
    audio.backend.update(_voice, volume: m.volume, pan: m.pan, pitch: m.pitch);
  }

  @override
  void onDestroy() {
    stop();
    audio._sources.remove(this);
  }

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.text('clip', () => clip?.name ?? '', null, help: 'Set from code'),
        InspectorField.float('volume', () => volume, (v) => volume = v, min: 0, max: 4),
        InspectorField.float('pitch', () => pitch, (v) => pitch = v, min: 0.05, max: 8),
        InspectorField.boolean('loop', () => loop, (v) => loop = v),
        InspectorField.boolean('spatial', () => spatial, (v) => spatial = v, help: 'Sound comes from the object place'),
        InspectorField.text('group', () => group, (v) => group = v),
        InspectorField.float('minDistance', () => minDistance, (v) => minDistance = v, min: 0.01),
        InspectorField.float('maxDistance', () => maxDistance, (v) => maxDistance = v, min: 0.01),
        InspectorField.choice<AudioRolloff>('rolloff', AudioRolloff.values, () => rolloff, (v) => rolloff = v),
        InspectorField.boolean('playOnAwake', () => playOnAwake, (v) => playOnAwake = v),
        InspectorField.boolean('isPlaying', () => isPlaying, null),
      ];
}
