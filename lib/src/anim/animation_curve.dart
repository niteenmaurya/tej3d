import '../math/mathf.dart';

/// What a curve or clip does before the first key and after the last key.
enum WrapMode { clamp, loop, pingPong }

/// One point of a curve. The tangents are slopes (value per second).
/// `double.infinity` as a tangent makes a hard step.
class CurveKey {
  CurveKey(this.time, this.value, {this.inTangent = 0.0, this.outTangent = 0.0});

  double time;
  double value;
  double inTangent;
  double outTangent;
}

/// A smooth curve through keys, like Unity `AnimationCurve` (Hermite spline).
class AnimationCurve {
  AnimationCurve(
    List<CurveKey> keys, {
    this.preWrap = WrapMode.clamp,
    this.postWrap = WrapMode.clamp,
  }) : keys = List.of(keys)..sort((a, b) => a.time.compareTo(b.time));

  /// Straight line from (t0, v0) to (t1, v1).
  factory AnimationCurve.linear(double t0, double v0, double t1, double v1) {
    final slope = t1 == t0 ? 0.0 : (v1 - v0) / (t1 - t0);
    return AnimationCurve([
      CurveKey(t0, v0, inTangent: slope, outTangent: slope),
      CurveKey(t1, v1, inTangent: slope, outTangent: slope),
    ]);
  }

  /// Same value for the whole time.
  factory AnimationCurve.constant(double t0, double t1, double v) =>
      AnimationCurve([CurveKey(t0, v), CurveKey(t1, v)]);

  /// Slow start, slow end (flat tangents).
  factory AnimationCurve.easeInOut(double t0, double v0, double t1, double v1) =>
      AnimationCurve([CurveKey(t0, v0), CurveKey(t1, v1)]);

  /// Keys with automatic smooth tangents (Catmull-Rom style).
  factory AnimationCurve.smooth(
    List<CurveKey> keys, {
    WrapMode preWrap = WrapMode.clamp,
    WrapMode postWrap = WrapMode.clamp,
  }) {
    final c = AnimationCurve(keys, preWrap: preWrap, postWrap: postWrap);
    final k = c.keys;
    for (var i = 0; i < k.length; i++) {
      final prev = k[i > 0 ? i - 1 : i];
      final next = k[i < k.length - 1 ? i + 1 : i];
      final dt = next.time - prev.time;
      final slope = dt <= 0.0 ? 0.0 : (next.value - prev.value) / dt;
      k[i].inTangent = slope;
      k[i].outTangent = slope;
    }
    return c;
  }

  final List<CurveKey> keys;
  final WrapMode preWrap;
  final WrapMode postWrap;

  /// Time of the last key.
  double get length => keys.isEmpty ? 0.0 : keys.last.time;

  double _wrapTime(double t) {
    final t0 = keys.first.time;
    final t1 = keys.last.time;
    final len = t1 - t0;
    if (len <= 0.0) return t0;
    if (t >= t0 && t <= t1) return t;
    final mode = t < t0 ? preWrap : postWrap;
    switch (mode) {
      case WrapMode.clamp:
        return Mathf.clamp(t, t0, t1);
      case WrapMode.loop:
        return t0 + Mathf.repeat(t - t0, len);
      case WrapMode.pingPong:
        return t0 + Mathf.pingPong(t - t0, len);
    }
  }

  double evaluate(double time) {
    if (keys.isEmpty) return 0.0;
    if (keys.length == 1) return keys.first.value;
    final t = _wrapTime(time);
    var lo = 0;
    var hi = keys.length - 2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (keys[mid].time <= t) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final a = keys[lo];
    final b = keys[lo + 1];
    final dt = b.time - a.time;
    if (dt <= 0.0) return b.value;
    if (a.outTangent.isInfinite || b.inTangent.isInfinite) {
      return t >= b.time ? b.value : a.value;
    }
    final u = (t - a.time) / dt;
    final u2 = u * u;
    final u3 = u2 * u;
    final m0 = a.outTangent * dt;
    final m1 = b.inTangent * dt;
    return (2 * u3 - 3 * u2 + 1) * a.value +
        (u3 - 2 * u2 + u) * m0 +
        (-2 * u3 + 3 * u2) * b.value +
        (u3 - u2) * m1;
  }
}
