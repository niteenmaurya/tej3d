import 'dart:math' as math;

import 'vec.dart';

/// Unity-style `Mathf` helpers. Pure Dart, no engine imports.
class Mathf {
  Mathf._();

  static const double epsilon = 1e-6;
  static const double deg2Rad = math.pi / 180.0;
  static const double rad2Deg = 180.0 / math.pi;

  static double clamp(double v, double min, double max) {
    if (v.isNaN) return min;
    return v < min ? min : (v > max ? max : v);
  }

  static double clamp01(double v) => clamp(v, 0.0, 1.0);

  /// Like Unity: `t` is clamped to 0..1.
  static double lerp(double a, double b, double t) => a + (b - a) * clamp01(t);

  static double lerpUnclamped(double a, double b, double t) => a + (b - a) * t;

  static double inverseLerp(double a, double b, double v) =>
      a == b ? 0.0 : clamp01((v - a) / (b - a));

  /// Maps [v] from the range inMin..inMax to the range outMin..outMax.
  static double remap(
    double v,
    double inMin,
    double inMax,
    double outMin,
    double outMax,
  ) => lerp(outMin, outMax, inverseLerp(inMin, inMax, v));

  /// Unity gives 1 for zero. Same here.
  static double sign(double v) => v >= 0.0 ? 1.0 : -1.0;

  static double moveTowards(double current, double target, double maxDelta) {
    if ((target - current).abs() <= maxDelta) return target;
    return current + sign(target - current) * maxDelta;
  }

  /// Loops [t] so it is never bigger than [length] and never below 0.
  static double repeat(double t, double length) {
    if (length <= 0.0) return 0.0;
    return clamp(t - (t / length).floorToDouble() * length, 0.0, length);
  }

  /// Goes up and down between 0 and [length].
  static double pingPong(double t, double length) {
    if (length <= 0.0) return 0.0;
    final r = repeat(t, length * 2.0);
    return length - (r - length).abs();
  }

  /// Shortest difference between two angles in degrees, -180..180.
  static double deltaAngle(double current, double target) {
    var d = repeat(target - current, 360.0);
    if (d > 180.0) d -= 360.0;
    return d;
  }

  static double lerpAngle(double a, double b, double t) =>
      a + deltaAngle(a, b) * clamp01(t);

  static double moveTowardsAngle(double current, double target, double maxDelta) {
    final d = deltaAngle(current, target);
    if (-maxDelta < d && d < maxDelta) return target;
    return moveTowards(current, current + d, maxDelta);
  }

  static double smoothStep(double from, double to, double t) {
    final u = clamp01(t);
    final s = u * u * (3.0 - 2.0 * u);
    return from + (to - from) * s;
  }

  static bool approximately(double a, double b) {
    final scale = math.max(a.abs(), b.abs()) * 1e-6;
    return (a - b).abs() < math.max(scale, epsilon * 8.0);
  }

  static Vector3 lerpV(Vector3 a, Vector3 b, double t) {
    final u = clamp01(t);
    return Vector3(
      a.x + (b.x - a.x) * u,
      a.y + (b.y - a.y) * u,
      a.z + (b.z - a.z) * u,
    );
  }

  static Vector3 moveTowardsV(Vector3 current, Vector3 target, double maxDelta) {
    final d = target - current;
    final len = d.length;
    if (len <= maxDelta || len < 1e-12) return target.clone();
    return current + d.scaled(maxDelta / len);
  }
}

/// Unity `Mathf.SmoothDamp` for one number. Keep one object per value.
class SmoothDamp {
  double velocity = 0.0;

  double step(
    double current,
    double target,
    double smoothTime,
    double dt, {
    double maxSpeed = double.infinity,
  }) {
    if (dt <= 0.0) return current;
    final st = math.max(0.0001, smoothTime);
    final omega = 2.0 / st;
    final x = omega * dt;
    final e = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x);
    var change = current - target;
    final originalTo = target;
    final maxChange = maxSpeed * st;
    change = Mathf.clamp(change, -maxChange, maxChange);
    final t = current - change;
    final temp = (velocity + omega * change) * dt;
    velocity = (velocity - omega * temp) * e;
    var output = t + (change + temp) * e;
    if ((originalTo - current > 0.0) == (output > originalTo)) {
      output = originalTo;
      velocity = (output - originalTo) / dt;
    }
    return output;
  }
}

/// `SmoothDamp` for a position. Good for cameras and followers.
class SmoothDamp3 {
  final SmoothDamp _x = SmoothDamp();
  final SmoothDamp _y = SmoothDamp();
  final SmoothDamp _z = SmoothDamp();

  Vector3 step(
    Vector3 current,
    Vector3 target,
    double smoothTime,
    double dt, {
    double maxSpeed = double.infinity,
  }) => Vector3(
    _x.step(current.x, target.x, smoothTime, dt, maxSpeed: maxSpeed),
    _y.step(current.y, target.y, smoothTime, dt, maxSpeed: maxSpeed),
    _z.step(current.z, target.z, smoothTime, dt, maxSpeed: maxSpeed),
  );
}

/// Small seeded random numbers. Same seed gives the same numbers on every
/// platform (32-bit xorshift, safe on web too).
class Rng {
  Rng([int seed = 0]) : _s = _fix(seed);

  int _s;

  static int _fix(int seed) {
    final s = seed & 0xFFFFFFFF;
    return s == 0 ? 0x9E3779B9 : s;
  }

  int nextUint32() {
    var x = _s;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _s = x & 0xFFFFFFFF;
    return _s;
  }

  /// 0 (included) to 1 (not included).
  double nextDouble() => nextUint32() / 4294967296.0;

  /// 0 to max-1.
  int nextInt(int max) => max <= 1 ? 0 : nextUint32() % max;

  bool nextBool() => (nextUint32() & 1) == 1;

  double range(double min, double max) => min + (max - min) * nextDouble();

  /// [min] included, [maxExclusive] not included.
  int intRange(int min, int maxExclusive) => min + nextInt(maxExclusive - min);

  /// True with probability [p] (0..1).
  bool chance(double p) => nextDouble() < p;

  Vector2 insideUnitCircle() {
    final a = nextDouble() * 2.0 * math.pi;
    final r = math.sqrt(nextDouble());
    return Vector2(r * math.cos(a), r * math.sin(a));
  }

  Vector3 onUnitSphere() {
    final z = nextDouble() * 2.0 - 1.0;
    final a = nextDouble() * 2.0 * math.pi;
    final r = math.sqrt(math.max(0.0, 1.0 - z * z));
    return Vector3(r * math.cos(a), r * math.sin(a), z);
  }

  T pick<T>(List<T> items) {
    if (items.isEmpty) {
      throw StateError('Cannot pick from an empty list.');
    }
    return items[nextInt(items.length)];
  }

  void shuffle<T>(List<T> items) {
    for (var i = items.length - 1; i > 0; i--) {
      final j = nextInt(i + 1);
      final tmp = items[i];
      items[i] = items[j];
      items[j] = tmp;
    }
  }

  /// Picks an index. A bigger weight is picked more often.
  int weighted(List<double> weights) {
    if (weights.isEmpty) {
      throw StateError('Cannot pick from an empty weights list.');
    }
    var total = 0.0;
    for (final w in weights) {
      if (w.isFinite && w > 0.0) total += w;
    }
    if (total <= 0.0) return nextInt(weights.length);
    var r = nextDouble() * total;
    for (var i = 0; i < weights.length; i++) {
      final w = weights[i];
      if (!w.isFinite || w <= 0.0) continue;
      r -= w;
      if (r < 0.0) return i;
    }
    for (var i = weights.length - 1; i >= 0; i--) {
      if (weights[i].isFinite && weights[i] > 0.0) return i;
    }
    return weights.length - 1;
  }
}

/// Perlin noise (Ken Perlin's improved version). Output is about -1..1.
class PerlinNoise {
  PerlinNoise([int seed = 0]) {
    final p = List<int>.generate(256, (i) => i);
    final r = Rng(seed);
    for (var i = 255; i > 0; i--) {
      final j = r.nextInt(i + 1);
      final tmp = p[i];
      p[i] = p[j];
      p[j] = tmp;
    }
    _p = List<int>.generate(512, (i) => p[i & 255]);
  }

  late final List<int> _p;

  static double _fade(double t) => t * t * t * (t * (t * 6.0 - 15.0) + 10.0);

  static double _mix(double t, double a, double b) => a + t * (b - a);

  static double _grad(int hash, double x, double y, double z) {
    final h = hash & 15;
    final u = h < 8 ? x : y;
    final v = h < 4 ? y : ((h == 12 || h == 14) ? x : z);
    return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v);
  }

  double noise3(double x, double y, double z) {
    final xi = x.floor() & 255;
    final yi = y.floor() & 255;
    final zi = z.floor() & 255;
    final xf = x - x.floorToDouble();
    final yf = y - y.floorToDouble();
    final zf = z - z.floorToDouble();
    final u = _fade(xf);
    final v = _fade(yf);
    final w = _fade(zf);
    final a = _p[xi] + yi;
    final aa = _p[a] + zi;
    final ab = _p[a + 1] + zi;
    final b = _p[xi + 1] + yi;
    final ba = _p[b] + zi;
    final bb = _p[b + 1] + zi;
    return _mix(
      w,
      _mix(
        v,
        _mix(u, _grad(_p[aa], xf, yf, zf), _grad(_p[ba], xf - 1, yf, zf)),
        _mix(
          u,
          _grad(_p[ab], xf, yf - 1, zf),
          _grad(_p[bb], xf - 1, yf - 1, zf),
        ),
      ),
      _mix(
        v,
        _mix(
          u,
          _grad(_p[aa + 1], xf, yf, zf - 1),
          _grad(_p[ba + 1], xf - 1, yf, zf - 1),
        ),
        _mix(
          u,
          _grad(_p[ab + 1], xf, yf - 1, zf - 1),
          _grad(_p[bb + 1], xf - 1, yf - 1, zf - 1),
        ),
      ),
    );
  }

  double noise2(double x, double y) => noise3(x, y, 0.0);

  /// Layers of noise: rough shapes plus fine detail. Good for terrain.
  double fbm2(
    double x,
    double y, {
    int octaves = 4,
    double lacunarity = 2.0,
    double gain = 0.5,
  }) {
    var sum = 0.0;
    var amp = 1.0;
    var freq = 1.0;
    var norm = 0.0;
    for (var i = 0; i < octaves; i++) {
      sum += noise2(x * freq, y * freq) * amp;
      norm += amp;
      amp *= gain;
      freq *= lacunarity;
    }
    return norm == 0.0 ? 0.0 : sum / norm;
  }
}
