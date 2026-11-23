/// Cinematic sequencer (Unity Timeline equivalent): orchestrates camera cuts,
/// float property tracks, and timed gameplay events along a shared playhead.
library;

import '../math/vec.dart';

/// Base track inside a [CutsceneDirector].
abstract class CutsceneTrack {
  CutsceneTrack(this.name);
  final String name;
  void evaluate(double prevTime, double time);
}

class CameraCutClip {
  const CameraCutClip({
    required this.start,
    required this.end,
    required this.cameraName,
  });

  final double start;
  final double end;
  final String cameraName;
}

/// Switches active camera names across timed shots.
class CameraCutTrack extends CutsceneTrack {
  CameraCutTrack(super.name, this.clips, {this.onCameraChanged});

  final List<CameraCutClip> clips;
  final void Function(String cameraName)? onCameraChanged;
  String? activeCamera;

  @override
  void evaluate(double prevTime, double time) {
    String? chosen;
    for (final c in clips) {
      if (time >= c.start && time < c.end) {
        chosen = c.cameraName;
        break;
      }
    }
    if (chosen != null && chosen != activeCamera) {
      activeCamera = chosen;
      onCameraChanged?.call(chosen);
    }
  }
}

class CutsceneCue {
  const CutsceneCue(this.time, this.eventName, [this.payload]);
  final double time;
  final String eventName;
  final Object? payload;
}

/// Fires one-shot cues when the playhead crosses their timestamp.
class EventTrack extends CutsceneTrack {
  EventTrack(super.name, this.cues, {required this.onCue});

  final List<CutsceneCue> cues;
  final void Function(CutsceneCue cue) onCue;

  @override
  void evaluate(double prevTime, double time) {
    for (final c in cues) {
      final crossed = (prevTime < c.time && time >= c.time) ||
          (prevTime == 0.0 && c.time == 0.0 && time > 0.0);
      if (crossed) onCue(c);
    }
  }
}

class VectorKeyframe {
  const VectorKeyframe(this.time, this.value);
  final double time;
  final Vector3 value;
}

/// Smoothly interpolates a [Vector3] property across keyframes.
class VectorTrack extends CutsceneTrack {
  VectorTrack(super.name, List<VectorKeyframe> keys, {required this.onValue})
      : keys = List<VectorKeyframe>.from(keys)
          ..sort((a, b) => a.time.compareTo(b.time));

  final List<VectorKeyframe> keys;
  final void Function(Vector3 value) onValue;

  @override
  void evaluate(double prevTime, double time) {
    if (keys.isEmpty) return;
    if (time <= keys.first.time) {
      onValue(keys.first.value.clone());
      return;
    }
    if (time >= keys.last.time) {
      onValue(keys.last.value.clone());
      return;
    }
    for (var i = 0; i < keys.length - 1; i++) {
      final a = keys[i], b = keys[i + 1];
      if (time >= a.time && time <= b.time) {
        final t = (time - a.time) / (b.time - a.time);
        onValue(a.value * (1.0 - t) + b.value * t);
        return;
      }
    }
  }
}

/// Plays a multi-track cutscene sequence with play, pause, scrub, and loop.
class CutsceneDirector {
  CutsceneDirector({
    required this.duration,
    List<CutsceneTrack>? tracks,
    this.loop = false,
  }) : tracks = tracks != null ? List<CutsceneTrack>.from(tracks) : [];

  final double duration;
  final List<CutsceneTrack> tracks;
  bool loop;

  double _time = 0.0;
  bool playing = false;

  double get time => _time;
  bool get finished => !loop && _time >= duration;

  void play() => playing = true;
  void pause() => playing = false;

  void stop() {
    playing = false;
    _time = 0.0;
  }

  void seek(double t) {
    final prev = _time;
    _time = t.clamp(0.0, duration).toDouble();
    for (final tr in tracks) {
      tr.evaluate(prev, _time);
    }
  }

  void update(double dt) {
    if (!playing || dt <= 0) return;
    final prev = _time;
    var next = _time + dt;
    if (next >= duration) {
      if (loop && duration > 0) {
        for (final tr in tracks) {
          tr.evaluate(prev, duration);
        }
        _time = next % duration;
        for (final tr in tracks) {
          tr.evaluate(0.0, _time);
        }
        return;
      } else {
        next = duration;
        playing = false;
      }
    }
    _time = next;
    for (final tr in tracks) {
      tr.evaluate(prev, _time);
    }
  }
}
