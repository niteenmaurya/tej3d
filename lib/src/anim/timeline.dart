import '../math/vec.dart';

/// How a value moves between two keyframes.
enum Ease { linear, easeIn, easeOut, easeInOut }

double applyEase(Ease ease, double t) {
  switch (ease) {
    case Ease.linear:
      return t;
    case Ease.easeIn:
      return t * t;
    case Ease.easeOut:
      return 1.0 - (1.0 - t) * (1.0 - t);
    case Ease.easeInOut:
      return t * t * (3.0 - 2.0 * t);
  }
}

class Keyframe<T> {
  const Keyframe(this.time, this.value);
  final double time;
  final T value;
}

/// Keyframes over time for a number. Use it for fades, camera moves, cutscenes.
class DoubleTrack {
  DoubleTrack(List<Keyframe<double>> keys, {this.ease = Ease.linear})
    : keys = List.of(keys)..sort((a, b) => a.time.compareTo(b.time)),
      assert(keys.isNotEmpty);

  final List<Keyframe<double>> keys;
  final Ease ease;

  double get duration => keys.last.time;

  double sample(double time) {
    if (time <= keys.first.time) return keys.first.value;
    if (time >= keys.last.time) return keys.last.value;
    for (var i = 0; i < keys.length - 1; i++) {
      final a = keys[i];
      final b = keys[i + 1];
      if (time <= b.time) {
        final u = (time - a.time) / (b.time - a.time);
        return a.value + (b.value - a.value) * applyEase(ease, u);
      }
    }
    return keys.last.value;
  }
}

/// Keyframes over time for a position or direction.
class Vector3Track {
  Vector3Track(List<Keyframe<Vector3>> keys, {this.ease = Ease.linear})
    : keys = List.of(keys)..sort((a, b) => a.time.compareTo(b.time)),
      assert(keys.isNotEmpty);

  final List<Keyframe<Vector3>> keys;
  final Ease ease;

  double get duration => keys.last.time;

  Vector3 sample(double time) {
    if (time <= keys.first.time) return keys.first.value.clone();
    if (time >= keys.last.time) return keys.last.value.clone();
    for (var i = 0; i < keys.length - 1; i++) {
      final a = keys[i];
      final b = keys[i + 1];
      if (time <= b.time) {
        final u = applyEase(ease, (time - a.time) / (b.time - a.time));
        return a.value + (b.value - a.value) * u;
      }
    }
    return keys.last.value.clone();
  }
}
