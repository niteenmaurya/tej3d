import 'dart:math' as math;

typedef EaseFn = double Function(double t);

/// Easing functions (t goes 0..1, result goes about 0..1).
class Easing {
  Easing._();

  static double linear(double t) => t;

  static double quadIn(double t) => t * t;
  static double quadOut(double t) => t * (2.0 - t);
  static double quadInOut(double t) =>
      t < 0.5 ? 2.0 * t * t : -1.0 + (4.0 - 2.0 * t) * t;

  static double cubicIn(double t) => t * t * t;
  static double cubicOut(double t) {
    final u = t - 1.0;
    return u * u * u + 1.0;
  }

  static double cubicInOut(double t) {
    if (t < 0.5) return 4.0 * t * t * t;
    final u = 2.0 * t - 2.0;
    return 0.5 * u * u * u + 1.0;
  }

  static double quartIn(double t) => t * t * t * t;
  static double quartOut(double t) {
    final u = t - 1.0;
    return 1.0 - u * u * u * u;
  }

  static double sineIn(double t) => 1.0 - math.cos(t * math.pi / 2.0);
  static double sineOut(double t) => math.sin(t * math.pi / 2.0);
  static double sineInOut(double t) => -(math.cos(math.pi * t) - 1.0) / 2.0;

  static double expoIn(double t) =>
      t <= 0.0 ? 0.0 : math.pow(2.0, 10.0 * t - 10.0).toDouble();
  static double expoOut(double t) =>
      t >= 1.0 ? 1.0 : 1.0 - math.pow(2.0, -10.0 * t).toDouble();

  static double circIn(double t) => 1.0 - math.sqrt(1.0 - t * t);
  static double circOut(double t) {
    final u = t - 1.0;
    return math.sqrt(1.0 - u * u);
  }

  static double backIn(double t) {
    const c1 = 1.70158;
    const c3 = c1 + 1.0;
    return c3 * t * t * t - c1 * t * t;
  }

  static double backOut(double t) {
    const c1 = 1.70158;
    const c3 = c1 + 1.0;
    final u = t - 1.0;
    return 1.0 + c3 * u * u * u + c1 * u * u;
  }

  static double elasticOut(double t) {
    if (t <= 0.0) return 0.0;
    if (t >= 1.0) return 1.0;
    const c4 = 2.0 * math.pi / 3.0;
    return math.pow(2.0, -10.0 * t).toDouble() *
            math.sin((t * 10.0 - 0.75) * c4) +
        1.0;
  }

  static double bounceOut(double t) {
    const n1 = 7.5625;
    const d1 = 2.75;
    if (t < 1.0 / d1) return n1 * t * t;
    if (t < 2.0 / d1) {
      final u = t - 1.5 / d1;
      return n1 * u * u + 0.75;
    }
    if (t < 2.5 / d1) {
      final u = t - 2.25 / d1;
      return n1 * u * u + 0.9375;
    }
    final u = t - 2.625 / d1;
    return n1 * u * u + 0.984375;
  }

  static double bounceIn(double t) => 1.0 - bounceOut(1.0 - t);
}

/// One running tween: moves a number from [from] to [to].
class Tween {
  Tween({
    required this.from,
    required this.to,
    required this.duration,
    required this.onUpdate,
    this.ease = Easing.linear,
    this.delay = 0.0,
    this.loops = 1,
    this.yoyo = false,
    this.onComplete,
  }) : _delayLeft = delay;

  final double from;
  final double to;
  final double duration;
  final void Function(double value) onUpdate;
  final EaseFn ease;
  final double delay;

  /// How many times it plays. -1 means forever.
  final int loops;

  /// If true, every second pass plays backwards.
  final bool yoyo;
  final void Function()? onComplete;

  double _delayLeft;
  double _elapsed = 0.0;
  int _pass = 0;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void _apply(double u) {
    final k = (yoyo && _pass.isOdd) ? 1.0 - u : u;
    onUpdate(from + (to - from) * ease(k));
  }

  /// Returns true when finished (or cancelled).
  bool update(double dt) {
    if (_cancelled) return true;
    var step = dt;
    if (_delayLeft > 0.0) {
      _delayLeft -= step;
      if (_delayLeft > 0.0) return false;
      step = -_delayLeft;
      _delayLeft = 0.0;
    }
    if (duration <= 0.0) {
      onUpdate(to);
      onComplete?.call();
      return true;
    }
    _elapsed += step;
    while (_elapsed >= duration) {
      if (loops == -1 || _pass + 1 < loops) {
        _elapsed -= duration;
        _pass++;
      } else {
        _apply(1.0);
        onComplete?.call();
        return true;
      }
    }
    _apply(_elapsed / duration);
    return false;
  }
}

/// Runs tweens. Needs `update(dt)` every frame (`Tej3DGame` does it).
///
/// ```dart
/// game.tweens.to(0, 1, 0.5, (v) => fade = v, ease: Easing.cubicOut);
/// ```
class TweenRunner {
  final List<Tween> _active = [];

  int get count => _active.length;

  Tween to(
    double from,
    double to,
    double duration,
    void Function(double value) onUpdate, {
    EaseFn ease = Easing.linear,
    double delay = 0.0,
    int loops = 1,
    bool yoyo = false,
    void Function()? onComplete,
  }) {
    final t = Tween(
      from: from,
      to: to,
      duration: duration,
      onUpdate: onUpdate,
      ease: ease,
      delay: delay,
      loops: loops,
      yoyo: yoyo,
      onComplete: onComplete,
    );
    _active.add(t);
    return t;
  }

  void cancelAll() {
    for (final t in _active) {
      t.cancel();
    }
    _active.clear();
  }

  void update(double dt) {
    final finished = <Tween>[];
    for (final t in List<Tween>.of(_active)) {
      if (t.update(dt)) finished.add(t);
    }
    _active.removeWhere(finished.contains);
  }
}
