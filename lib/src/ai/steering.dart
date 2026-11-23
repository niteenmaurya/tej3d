import '../math/vec.dart';

/// Classic steering helpers. Each returns a wanted velocity (a direction with
/// a speed). Use [steer] to turn it into a limited push.
class Steering {
  Steering._();

  static Vector3 seek(Vector3 position, Vector3 target, double maxSpeed) {
    final d = target - position;
    if (d.length2 < 1e-12) return Vector3.zero();
    return d.normalized().scaled(maxSpeed);
  }

  static Vector3 flee(Vector3 position, Vector3 threat, double maxSpeed) =>
      seek(threat, position, maxSpeed);

  /// Like seek, but slows down inside [slowRadius].
  static Vector3 arrive(
    Vector3 position,
    Vector3 target,
    double maxSpeed,
    double slowRadius,
  ) {
    final d = target - position;
    final dist = d.length;
    if (dist < 1e-6) return Vector3.zero();
    final speed = dist < slowRadius ? maxSpeed * dist / slowRadius : maxSpeed;
    return d.scaled(speed / dist);
  }

  /// Aims at where a moving target will be.
  static Vector3 pursue(
    Vector3 position,
    Vector3 targetPosition,
    Vector3 targetVelocity,
    double maxSpeed,
  ) {
    final dist = (targetPosition - position).length;
    final t = maxSpeed <= 0.0 ? 0.0 : dist / maxSpeed;
    return seek(position, targetPosition + targetVelocity.scaled(t), maxSpeed);
  }

  /// Pushes away from close neighbors. Add it to other behaviors.
  static Vector3 separation(
    Vector3 position,
    List<Vector3> neighbors,
    double radius,
    double maxSpeed,
  ) {
    final sum = Vector3.zero();
    for (final n in neighbors) {
      final d = position - n;
      final dist = d.length;
      if (dist > 1e-6 && dist < radius) {
        sum.add(d.normalized().scaled((radius - dist) / radius));
      }
    }
    if (sum.length2 < 1e-12) return Vector3.zero();
    return sum.normalized().scaled(maxSpeed);
  }

  /// Wanted velocity minus current velocity, limited to [maxForce].
  static Vector3 steer(Vector3 desired, Vector3 current, double maxForce) {
    final f = desired - current;
    final len = f.length;
    if (len > maxForce && len > 1e-12) f.scale(maxForce / len);
    return f;
  }
}
