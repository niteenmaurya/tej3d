/// One sound to play: a file path, an asset name, or bytes. The engine does not
/// read it; your [AudioBackend] decides what [source] means.
class AudioClip {
  const AudioClip(this.name, {this.source, this.duration});

  /// Short unique name, for example `'jump'`.
  final String name;

  /// What your backend loads (a path, an asset key, bytes, a URL).
  final Object? source;

  /// Length in seconds, if known. Lets [RecordingAudioBackend] end sounds.
  final double? duration;

  @override
  String toString() => 'AudioClip($name)';
}

/// The part that makes real sound. The engine works out volume, left/right
/// balance and pitch (distance, doppler, groups); a backend only plays them.
///
/// Write one with any audio plugin:
///
/// ```dart
/// class MyBackend implements AudioBackend { ... }
/// final audio = AudioSystem(MyBackend());
/// ```
///
/// A voice is one playing sound. [play] gives you its id.
abstract class AudioBackend {
  /// Starts [clip]. [volume] 0..1, [pan] -1 (left) .. 1 (right), [pitch] 1 is normal speed.
  int play(AudioClip clip, {required double volume, required double pan, required double pitch, required bool loop});

  /// Changes a playing voice. Null means no change.
  void update(int voice, {double? volume, double? pan, double? pitch});

  void pause(int voice);
  void resume(int voice);
  void stop(int voice);

  /// False once a non-looping voice has finished or was stopped.
  bool isPlaying(int voice);

  void dispose();
}

/// A backend that makes no sound and writes down what it was asked to do.
/// For tests, servers, and games run without audio. Non-looping voices end
/// after `clip.duration` seconds of [advance] (or never if the length is null).
class RecordingAudioBackend implements AudioBackend {
  final Map<int, RecordedVoice> voices = {};
  final List<String> log = [];
  int _next = 1;

  @override
  int play(AudioClip clip, {required double volume, required double pan, required double pitch, required bool loop}) {
    final id = _next++;
    voices[id] = RecordedVoice(clip, volume, pan, pitch, loop);
    log.add('play ${clip.name}');
    return id;
  }

  @override
  void update(int voice, {double? volume, double? pan, double? pitch}) {
    final v = voices[voice];
    if (v == null) return;
    if (volume != null) v.volume = volume;
    if (pan != null) v.pan = pan;
    if (pitch != null) v.pitch = pitch;
  }

  @override
  void pause(int voice) {
    voices[voice]?.paused = true;
    log.add('pause');
  }

  @override
  void resume(int voice) {
    voices[voice]?.paused = false;
    log.add('resume');
  }

  @override
  void stop(int voice) {
    final v = voices[voice];
    if (v != null) v.playing = false;
    log.add('stop');
  }

  @override
  bool isPlaying(int voice) => voices[voice]?.playing ?? false;

  /// Moves time forward so short sounds can finish.
  void advance(double seconds) {
    for (final v in voices.values) {
      if (!v.playing || v.paused || v.loop) continue;
      final d = v.clip.duration;
      if (d == null) continue;
      v.time += seconds * v.pitch;
      if (v.time >= d) v.playing = false;
    }
  }

  /// Voices that are still playing.
  Iterable<RecordedVoice> get active => voices.values.where((v) => v.playing);

  @override
  void dispose() => voices.clear();
}

class RecordedVoice {
  RecordedVoice(this.clip, this.volume, this.pan, this.pitch, this.loop);
  final AudioClip clip;
  double volume, pan, pitch;
  final bool loop;
  bool playing = true, paused = false;
  double time = 0;
}
