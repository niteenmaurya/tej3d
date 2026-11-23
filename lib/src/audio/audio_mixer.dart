/// Audio mixing buses, smooth music crossfading, and spatial reverb zones.
library;

import '../engine/game_object.dart';
import '../math/vec.dart';

/// One channel bus (Master, Music, SFX, Voice) with volume and mute state.
class AudioBus {
  AudioBus(this.name, {this.volume = 1.0, this.muted = false, this.parent});

  final String name;
  double volume;
  bool muted;
  final AudioBus? parent;

  /// Effective linear gain (0..1) combining this bus and all parent buses.
  double get effectiveVolume {
    if (muted) return 0.0;
    final p = parent?.effectiveVolume ?? 1.0;
    return (volume.clamp(0.0, 2.0) * p).toDouble();
  }
}

/// Hierarchical audio mixer with standard Master / Music / SFX / Voice buses.
class AudioMixer {
  AudioMixer() {
    master = AudioBus('Master');
    music = AudioBus('Music', parent: master);
    sfx = AudioBus('SFX', parent: master);
    voice = AudioBus('Voice', parent: master);
    _buses['Master'] = master;
    _buses['Music'] = music;
    _buses['SFX'] = sfx;
    _buses['Voice'] = voice;
  }

  late final AudioBus master;
  late final AudioBus music;
  late final AudioBus sfx;
  late final AudioBus voice;
  final Map<String, AudioBus> _buses = {};

  AudioBus? bus(String name) => _buses[name];

  AudioBus addBus(String name, {String parent = 'Master', double volume = 1.0}) {
    final b = AudioBus(name, volume: volume, parent: _buses[parent] ?? master);
    _buses[name] = b;
    return b;
  }
}

/// Smoothly crossfades volume between an outgoing and incoming music track.
class MusicCrossfader {
  String? currentTrack;
  String? nextTrack;
  double currentVolume = 1.0;
  double nextVolume = 0.0;
  double _duration = 0.0;
  double _elapsed = 0.0;

  bool get isTransitioning => nextTrack != null;

  void startTrack(String track) {
    currentTrack = track;
    nextTrack = null;
    currentVolume = 1.0;
    nextVolume = 0.0;
  }

  void crossfadeTo(String track, {double duration = 2.0}) {
    if (track == currentTrack) return;
    if (duration <= 0) {
      startTrack(track);
      return;
    }
    nextTrack = track;
    _duration = duration;
    _elapsed = 0.0;
    nextVolume = 0.0;
  }

  void update(double dt) {
    if (nextTrack == null || dt <= 0) return;
    _elapsed += dt;
    final t = (_elapsed / _duration).clamp(0.0, 1.0).toDouble();
    currentVolume = 1.0 - t;
    nextVolume = t;
    if (t >= 1.0) {
      currentTrack = nextTrack;
      nextTrack = null;
      currentVolume = 1.0;
      nextVolume = 0.0;
    }
  }
}

/// Spatial reverb zone component (caves, halls, tunnels).
class ReverbZone extends Component {
  ReverbZone({
    this.minDistance = 5.0,
    this.maxDistance = 15.0,
    this.decaySeconds = 2.5,
    this.wetMix = 0.6,
  });

  double minDistance;
  double maxDistance;
  double decaySeconds;
  double wetMix;

  /// Computes effective wet reverb mix (0..wetMix) at [listenerPosition].
  double mixAt(Vector3 listenerPosition) {
    final dist = (listenerPosition - transform.worldPosition).length;
    if (dist <= minDistance) return wetMix;
    if (dist >= maxDistance) return 0.0;
    final t = 1.0 - (dist - minDistance) / (maxDistance - minDistance);
    return wetMix * t;
  }
}
