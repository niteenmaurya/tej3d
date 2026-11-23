/// Multi-agent crowd avoidance (reciprocal velocity obstacle / separation
/// steering) so multiple AI agents navigate around each other smoothly.
library;

import '../math/vec.dart';

/// One moving agent managed by [CrowdManager].
class CrowdAgent {
  CrowdAgent({
    required this.id,
    required Vector3 position,
    this.radius = 0.45,
    this.maxSpeed = 4.0,
    this.avoidanceWeight = 1.5,
  })  : position = position.clone(),
        velocity = Vector3.zero(),
        preferredVelocity = Vector3.zero();

  final int id;
  Vector3 position;
  Vector3 velocity;
  Vector3 preferredVelocity;
  double radius;
  double maxSpeed;
  double avoidanceWeight;
}

/// Computes collision-free velocities for groups of [CrowdAgent]s using
/// reciprocal avoidance forces and time-to-collision prediction.
class CrowdManager {
  CrowdManager({this.neighborDistance = 4.0, this.timeHorizon = 1.5});

  final double neighborDistance;
  final double timeHorizon;
  final List<CrowdAgent> agents = [];

  CrowdAgent addAgent(
    Vector3 position, {
    double radius = 0.45,
    double maxSpeed = 4.0,
  }) {
    final a = CrowdAgent(
      id: agents.length + 1,
      position: position,
      radius: radius,
      maxSpeed: maxSpeed,
    );
    agents.add(a);
    return a;
  }

  /// Advances all agents by [dt] seconds, resolving pairwise avoidance.
  void step(double dt) {
    final nextVels = List<Vector3>.generate(agents.length, (i) {
      final a = agents[i];
      var steer = a.preferredVelocity.clone();
      steer.y = 0;

      for (var j = 0; j < agents.length; j++) {
        if (i == j) continue;
        final b = agents[j];
        final relPos = Vector3(a.position.x - b.position.x, 0, a.position.z - b.position.z);
        final dist = relPos.length;
        final minDist = a.radius + b.radius;
        if (dist > neighborDistance) continue;

        if (dist < minDist * 1.35) {
          final pushDir = dist > 1e-5 ? relPos / dist : Vector3(1, 0, 0);
          final strength = ((minDist * 1.35 - dist) / minDist) * a.maxSpeed * a.avoidanceWeight;
          steer += pushDir * strength;
        }

        final relVel = Vector3(
          a.preferredVelocity.x - b.preferredVelocity.x,
          0,
          a.preferredVelocity.z - b.preferredVelocity.z,
        );
        final closing = -(relPos.dot(relVel));
        if (closing > 0 && dist > 1e-4) {
          final speedSq = relVel.length2;
          if (speedSq > 1e-5) {
            final ttc = (closing / speedSq).clamp(0.0, timeHorizon).toDouble();
            final futureRel = relPos + relVel * ttc;
            final futureDist = futureRel.length;
            if (futureDist < minDist * 1.15) {
              final side = futureDist > 1e-4
                  ? futureRel / futureDist
                  : Vector3(-relPos.z, 0, relPos.x).normalized();
              final urgency = (1.0 - ttc / timeHorizon) * a.maxSpeed * a.avoidanceWeight;
              steer += side * urgency;
            }
          }
        }
      }

      final spd = steer.length;
      if (spd > a.maxSpeed) {
        steer = steer * (a.maxSpeed / spd);
      }
      return steer;
    });

    for (var i = 0; i < agents.length; i++) {
      agents[i].velocity = nextVels[i];
      agents[i].position += nextVels[i] * dt;
    }

    for (var i = 0; i < agents.length; i++) {
      for (var j = i + 1; j < agents.length; j++) {
        final a = agents[i], b = agents[j];
        final d = Vector3(a.position.x - b.position.x, 0, a.position.z - b.position.z);
        final dist = d.length;
        final minD = a.radius + b.radius;
        if (dist < minD) {
          final n = dist > 1e-5 ? d / dist : Vector3(1, 0, 0);
          final half = (minD - dist) * 0.5;
          a.position += n * half;
          b.position -= n * half;
        }
      }
    }
  }
}
