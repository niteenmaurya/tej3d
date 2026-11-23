import 'dart:math' as math;

import '../math/vec.dart';

/// Turns world positions into minimap positions. Pure math, easy to test.
///
/// The result is in the range -1 to 1 on both axes: x to the right, y down.
/// With [rotateWithHeading] the map turns so the player always points up.
class MinimapProjection {
  const MinimapProjection({
    required this.worldRadius,
    this.rotateWithHeading = true,
  });

  /// How much of the world fits from the center to the edge, in world units.
  final double worldRadius;
  final bool rotateWithHeading;

  /// [heading] is the yaw of the player, `atan2(forward.x, forward.z)`.
  (double x, double y) project(Vector3 world, Vector3 center, double heading) {
    final dx = world.x - center.x;
    final dz = world.z - center.z;
    var right = dx;
    var forward = dz;
    if (rotateWithHeading) {
      final c = math.cos(heading);
      final s = math.sin(heading);
      right = dx * c - dz * s;
      forward = dx * s + dz * c;
    }
    return (right / worldRadius, -forward / worldRadius);
  }
}
