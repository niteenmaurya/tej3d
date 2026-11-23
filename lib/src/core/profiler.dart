/// Frame time statistics and named timing sections.
class FrameProfiler {
  FrameProfiler({this.capacity = 120});

  /// How many recent frames are kept.
  final int capacity;

  final List<double> _frames = [];
  final Map<String, Stopwatch> _watches = {};
  final Map<String, double> _avgMs = {};

  /// Record the length of one frame, in seconds.
  void frame(double seconds) {
    _frames.add(seconds);
    if (_frames.length > capacity) _frames.removeAt(0);
  }

  double get averageMs {
    if (_frames.isEmpty) return 0.0;
    var s = 0.0;
    for (final f in _frames) {
      s += f;
    }
    return s / _frames.length * 1000.0;
  }

  double get fps {
    final a = averageMs;
    return a <= 0.0 ? 0.0 : 1000.0 / a;
  }

  double get worstMs {
    var w = 0.0;
    for (final f in _frames) {
      if (f > w) w = f;
    }
    return w * 1000.0;
  }

  /// Frames slower than 33 ms (below 30 fps) among the kept frames.
  int get spikes => _frames.where((f) => f > 0.0333).length;

  void begin(String name) {
    (_watches[name] ??= Stopwatch()).reset();
    _watches[name]!.start();
  }

  void end(String name) {
    final sw = _watches[name];
    if (sw == null) return;
    sw.stop();
    final ms = sw.elapsedMicroseconds / 1000.0;
    final prev = _avgMs[name];
    _avgMs[name] = prev == null ? ms : prev * 0.9 + ms * 0.1;
  }

  /// Runs [body] and measures it as section [name].
  R time<R>(String name, R Function() body) {
    begin(name);
    try {
      return body();
    } finally {
      end(name);
    }
  }

  /// Smoothed time of a section in milliseconds, 0 if never measured.
  double sectionMs(String name) => _avgMs[name] ?? 0.0;

  Map<String, double> get sections => Map.unmodifiable(_avgMs);
}
