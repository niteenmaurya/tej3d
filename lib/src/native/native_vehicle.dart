import 'dart:math' as math;

import '../engine/game_object.dart';
import '../math/vec.dart';
import '../physics/raycast_vehicle.dart';
import 'native_physics.dart';
import 'native_world.dart';

/// Ready-to-use 4-wheel raycast vehicle component that glues [RaycastVehicle]
/// directly to a [NativeRigidBody] inside [NativePhysics].
///
/// Attach both a [NativeRigidBody] (chassis) and [NativeVehicleBody] to the same
/// [GameObject], set [throttle], [brake], and [steer], and call `physics.step(dt)`:
///
/// ```dart
/// final car = scene.add(GameObject('Car', position: Vector3(0, 1.2, 0)));
/// final body = car.addComponent(NativeRigidBody(physics, mass: 1450, halfExtents: Vector3(0.95, 0.45, 2.2)));
/// final vehicle = car.addComponent(NativeVehicleBody(physics, body: body));
/// vehicle.throttle = 1.0;
/// ```
class NativeVehicleBody extends Component {
  NativeVehicleBody(
    this.physics, {
    NativeRigidBody? body,
    VehicleConfig? config,
    this.rayMask = 0xFFFFFFFF,
    this.antiRollStiffness = 2200.0,
  }) : _explicitBody = body,
       solver = RaycastVehicle(config: config ?? VehicleConfig()) {
    physics.addPreStepHook(_preStep);
  }

  final NativePhysics physics;
  final NativeRigidBody? _explicitBody;
  final RaycastVehicle solver;

  /// Collision layer mask for the 4 suspension rays.
  final int rayMask;

  /// Anti-roll bar stiffness (N/m) resisting body roll between left/right wheels.
  final double antiRollStiffness;

  /// Driver inputs: throttle (-1..1), brake (0..1), steer (-1..1).
  double throttle = 0.0;
  double brake = 0.0;
  double steer = 0.0;

  NativeRigidBody? _resolvedBody;

  /// The underlying chassis rigid body.
  NativeRigidBody get rigidBody {
    final b = _explicitBody ?? _resolvedBody ?? gameObject.getComponent<NativeRigidBody>();
    if (b == null) {
      throw StateError('NativeVehicleBody requires a NativeRigidBody on the same GameObject (or passed via body:).');
    }
    _resolvedBody = b;
    return b;
  }

  List<WheelState> get wheels => solver.wheels;
  int get currentGear => solver.currentGear;
  double get engineRpm => solver.engineRpm;
  double get currentTorqueNm => solver.currentTorqueNm;
  double get steerAngle => solver.steerAngle;

  /// Forward speed in meters per second along the car's local forward axis (-Z).
  double get forwardSpeedMs {
    final body = rigidBody;
    final fwd = transform.worldRotation.rotateVector(Vector3(0, 0, -1));
    return body.velocity.dot(fwd);
  }

  /// Forward speed in km/h.
  double get speedKmh => forwardSpeedMs * 3.6;

  /// Number of wheels currently touching the ground (0..4).
  int get groundedWheels => solver.wheels.where((w) => w.grounded).length;

  void _preStep(double dt) {
    if (!isAttached || !enabled || !gameObject.activeInHierarchy || dt <= 0) return;
    final body = rigidBody;
    body.ensureCreated();
    if (body.bodyId < 0) return;

    final pos = transform.worldPosition;
    final rot = transform.worldRotation;
    final up = rot.rotateVector(Vector3(0, 1, 0));
    final down = up * -1.0;
    final fwd = rot.rotateVector(Vector3(0, 0, -1));
    final right = rot.rotateVector(Vector3(1, 0, 0));

    final linVel = body.velocity;
    final angVel = body.angularVelocity;
    final forwardSpeed = linVel.dot(fwd);

    solver.updateSteering(steer, forwardSpeed, dt);
    final totalDriveForce = solver.updatePowertrain(forwardSpeed, throttle, dt);

    final maxRay = solver.config.suspensionRestLength + solver.config.wheelRadius;
    final hits = List<NativeRayHit?>.filled(4, null);
    final worldAnchors = List<Vector3>.generate(4, (i) => pos + rot.rotateVector(solver.wheels[i].localAnchor));

    for (var i = 0; i < 4; i++) {
      final hit = physics.world.raycast(
        worldAnchors[i],
        down,
        maxDistance: maxRay,
        mask: rayMask,
        ignoreBody: body.bodyId,
      );
      hits[i] = hit;
      solver.solveWheelSuspension(solver.wheels[i], hit?.distance, dt);
    }

    // Anti-roll bar forces (front axle 0-1, rear axle 2-3)
    final antiRoll = List<double>.filled(4, 0.0);
    if (antiRollStiffness > 0) {
      for (final pair in const [(0, 1), (2, 3)]) {
        final wL = solver.wheels[pair.$1];
        final wR = solver.wheels[pair.$2];
        final diff = wL.compression - wR.compression;
        final fRoll = diff * antiRollStiffness;
        if (wL.grounded) antiRoll[pair.$1] = fRoll;
        if (wR.grounded) antiRoll[pair.$2] = -fRoll;
      }
    }

    for (var i = 0; i < 4; i++) {
      final wheel = solver.wheels[i];
      final hit = hits[i];
      if (!wheel.grounded || hit == null) continue;

      final contactPt = hit.point;
      final r = contactPt - pos;
      final ptVel = linVel + angVel.cross(r);

      // Wheel heading rotated by steerAngle around chassis up axis
      final cosS = math.cos(wheel.steerAngle);
      final sinS = math.sin(wheel.steerAngle);
      final wFwd = (fwd * cosS) - (right * sinS);
      final wRight = (right * cosS) + (fwd * sinS);

      final wForwardSpeed = ptVel.dot(wFwd);
      final wLateralSpeed = ptVel.dot(wRight);
      if (solver.config.wheelRadius > 1e-4) {
        wheel.spinAngle += (wForwardSpeed / solver.config.wheelRadius) * dt;
      }

      final (fLong, fLat) = solver.solveTireForces(
        wheel,
        forwardSpeed: wForwardSpeed,
        lateralSpeed: wLateralSpeed,
        throttle: throttle,
        brake: brake,
        totalDriveForce: totalDriveForce,
      );

      final suspForce = math.max(0.0, wheel.normalForce + antiRoll[i]);
      final totalWheelForce = (up * suspForce) + (wFwd * fLong) + (wRight * fLat);
      body.addImpulse(totalWheelForce * dt, at: contactPt);
    }

    // Aerodynamic drag applied at center of mass
    final drag = solver.computeAeroDrag(linVel);
    if (drag.length2 > 1e-8) {
      body.addImpulse(drag * dt);
    }
  }

  @override
  void onEnable() {
    physics.addPreStepHook(_preStep);
  }

  @override
  void onDisable() {
    physics.removePreStepHook(_preStep);
  }

  @override
  void onDestroy() {
    physics.removePreStepHook(_preStep);
  }
}
