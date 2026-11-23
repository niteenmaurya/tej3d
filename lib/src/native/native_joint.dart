import '../math/vec.dart';

import 'native_physics.dart';

/// What a joint does.
enum NativeJointType {
  /// The two anchor points stay together; the bodies turn freely (shoulder,
  /// chain link, pendulum).
  ball,

  /// Like glue: anchors together and no turning against each other.
  fixed,

  /// Like [ball], but only turning around one axis (door, wheel, lever). Can
  /// have angle limits and a motor.
  hinge,

  /// Keeps the anchors between a minimum and a maximum distance (rope, leash).
  rope,

  /// Pulls the anchors to a rest length with a soft spring (suspension, bungee).
  spring,

  /// Prismatic slider: allows translation along one axis (with optional
  /// lower..upper limits and motor) while locking perpendicular motion & rotation.
  slider,

  /// Ball-and-socket joint with a swing cone angle limit (`upper` = max swing radians).
  coneTwist,
}

/// A joint between two physics bodies (or a body and the world). Make it with
/// [NativeJoints.createJoint].
class NativeJoint {
  NativeJoint._(this.physics, this.id, this.type);

  final NativePhysics physics;
  final int id;
  final NativeJointType type;

  /// False once destroyed, broken, or when one of its bodies is gone.
  bool get isAlive => physics.world.jointAlive(id);

  /// True if it was torn off by its break force.
  bool get isBroken => physics.world.jointBroken(id);

  /// Hinge: how far body A is turned relative to B (or the world), in radians,
  /// -pi..pi. 0 is where it was when the joint was made.
  double get angle => physics.world.jointAngle(id);

  /// Force in newtons the joint carries now (holding its anchors together).
  double get force => physics.world.jointForce(id);

  /// Hinge/Slider motor: drive at [speed] (rad/s or m/s) with at most
  /// [maxTorque] (N*m or N). A max torque of 0 switches the motor off.
  void setMotor(double speed, double maxTorque) => physics.world.setJointMotor(id, speed, maxTorque);

  /// Hinge/Slider/ConeTwist: keep the angle or slide position between [lower] and [upper].
  void setLimits(double lower, double upper) => physics.world.setJointLimits(id, enabled: true, lower: lower, upper: upper);

  void clearLimits() => physics.world.setJointLimits(id, enabled: false);

  void destroy() => physics.world.destroyJoint(id);
}

extension NativeJoints on NativePhysics {
  /// Joins [a] to [b] (or to the world when [b] is null).
  ///
  /// Automatically creates the native bodies if `scene.update()` has not run yet.
  NativeJoint createJoint(
    NativeJointType type,
    NativeRigidBody a, {
    NativeRigidBody? b,
    required Vector3 anchor,
    Vector3? anchorB,
    Vector3? axis,
    bool limit = false,
    double lower = 0,
    double upper = 0,
    double motorSpeed = 0,
    double motorMaxTorque = 0,
    double? minLength,
    double? maxLength,
    double? restLength,
    double frequency = 4,
    double damping = 0.5,
    double breakForce = 0,
    bool collideConnected = false,
  }) {
    // Auto-ensure bodies exist even when createJoint is called before the first scene.update().
    a.ensureCreated();
    b?.ensureCreated();
    if (a.bodyId < 0 || (b != null && b.bodyId < 0)) {
      throw StateError('The bodies must be attached to a GameObject before creating a joint.');
    }
    Vector3 local(NativeRigidBody body, Vector3 worldPoint) {
      final t = body.transform;
      return t.worldRotation.conjugated().rotateVector(worldPoint - t.worldPosition);
    }

    final pointB = anchorB ?? anchor;
    final la = local(a, anchor);
    final lb = b == null ? pointB.clone() : local(b, pointB);
    final axisWorld = (axis ?? Vector3(0, 1, 0)).normalized();
    final axisLocalA = a.transform.worldRotation.conjugated().rotateVector(axisWorld);
    final dist = (pointB - anchor).length;
    final params = <double>[
      limit ? 1 : 0,
      lower,
      upper,
      motorSpeed,
      motorMaxTorque,
      minLength ?? 0,
      maxLength ?? dist,
      restLength ?? dist,
      frequency,
      damping,
      breakForce,
      collideConnected ? 1 : 0,
    ];
    final id = world.createJointRaw(
      type: type.index,
      a: a.bodyId,
      b: b?.bodyId ?? -1,
      anchorA: la,
      anchorB: lb,
      axis: axisLocalA,
      params: params,
    );
    if (id < 0) throw StateError('Could not make the joint (bodies missing, or both sides are the world).');
    return NativeJoint._(this, id, type);
  }
}
