import 'dart:math' as math;

import '../math/vec.dart';

import '../engine/transform.dart';

/// A camera that follows a target from behind.
///
/// Call [follow] every frame with the target position and heading (yaw).
/// Then call [applyTo] with the transform of your camera object.
class ChaseCamera {
  ChaseCamera({
    this.distance = 9.0,
    this.height = 3.5,
    this.lookHeight = 1.0,
    this.stiffness = 6.0,
    this.headingStiffness = 3.0,
  });

  /// Horizontal distance behind the target.
  final double distance;

  /// Camera height above the target.
  final double height;

  /// Height above the target that the camera looks at.
  final double lookHeight;

  /// Position follow speed. Higher is tighter.
  final double stiffness;

  /// How fast the camera swings behind a turning target.
  final double headingStiffness;

  double _yaw = 0.0;
  final Vector3 _position = Vector3(0, 4, -9);
  final Vector3 _target = Vector3.zero();
  bool _started = false;

  /// Camera yaw in radians (direction the camera looks along, around Y).
  double get yaw => _yaw;

  /// Where the camera is now.
  Vector3 get position => _position;

  /// What the camera looks at now.
  Vector3 get target => _target;

  /// Puts a camera object's transform at the camera pose.
  void applyTo(Transform t) {
    t.worldPosition = _position;
    t.lookAt(_target);
  }

  /// Jump to the target without easing.
  void snapTo(Vector3 targetPosition, double targetYaw) {
    _yaw = targetYaw;
    _place(targetPosition, 1.0);
    _started = true;
  }

  /// Ease toward the target. [targetYaw] is the heading to look along.
  void follow(Vector3 targetPosition, double targetYaw, double dt) {
    if (!_started) {
      snapTo(targetPosition, targetYaw);
      return;
    }
    final delta = _wrap(targetYaw - _yaw);
    _yaw += delta * (1.0 - math.exp(-headingStiffness * dt));
    _place(targetPosition, 1.0 - math.exp(-stiffness * dt));
  }

  void _place(Vector3 target, double t) {
    final desired = Vector3(
      target.x - math.sin(_yaw) * distance,
      target.y + height,
      target.z - math.cos(_yaw) * distance,
    );
    final look = Vector3(target.x, target.y + lookHeight, target.z);
    _position.add((desired - _position) * t);
    _target.add((look - _target) * t);
  }

  static double _wrap(double a) => math.atan2(math.sin(a), math.cos(a));
}
