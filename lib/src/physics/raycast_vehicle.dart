import 'dart:math' as math;
import '../math/vec.dart';

/// Configuration for a real-Earth 4-wheel raycast vehicle (SI units: kg, m, s, N, Nm, RPM).
class VehicleConfig {
  VehicleConfig({
    this.mass = 1450.0,
    this.wheelbase = 2.76,
    this.trackWidth = 1.88,
    this.wheelRadius = 0.36,
    this.suspensionRestLength = 0.42,
    this.suspensionStiffness = 28000.0,
    this.suspensionDamping = 4200.0,
    this.maxSteerAngle = 0.48,
    this.steerRate = 1.8,
    this.engineForce = 9500.0,
    this.useGearbox = true,
    this.peakTorqueNm = 310.0,
    this.idleRpm = 900.0,
    this.peakTorqueRpm = 4200.0,
    this.redlineRpm = 6800.0,
    this.upshiftRpm = 6100.0,
    this.downshiftRpm = 2300.0,
    this.gearRatios = const [3.54, 2.13, 1.36, 1.00, 0.81, 0.65],
    this.reverseRatio = 3.20,
    this.finalDrive = 3.73,
    this.drivetrainEfficiency = 0.88,
    this.brakeForce = 14500.0,
    this.corneringStiffness = 11000.0,
    this.tireGripMu = 1.05,
    this.dragCoefficient = 0.32,
    this.frontalArea = 2.1,
    this.airDensity = 1.225,
    this.rollingResistance = 0.015,
    this.gravity = 9.81,
  });

  final double mass;
  final double wheelbase;
  final double trackWidth;
  final double wheelRadius;
  final double suspensionRestLength;
  final double suspensionStiffness;
  final double suspensionDamping;
  final double maxSteerAngle;
  final double steerRate;

  /// Legacy flat drive force (only used when [useGearbox] is false).
  final double engineForce;

  /// When true (default), computes drive force from the engine torque curve + multi-speed gearbox.
  final bool useGearbox;

  /// Peak engine torque in Newton-meters (e.g. 310 Nm for a sporty 2.0L turbo / 3.0L V6).
  final double peakTorqueNm;
  final double idleRpm;
  final double peakTorqueRpm;
  final double redlineRpm;
  final double upshiftRpm;
  final double downshiftRpm;

  /// Forward gear ratios (1st .. Nth gear).
  final List<double> gearRatios;
  final double reverseRatio;
  final double finalDrive;
  final double drivetrainEfficiency;

  final double brakeForce;
  final double corneringStiffness;
  final double tireGripMu;
  final double dragCoefficient;
  final double frontalArea;
  final double airDensity;
  final double rollingResistance;
  final double gravity;
}

/// Live state of a single wheel (FL, FR, RL, RR).
class WheelState {
  WheelState({
    required this.localAnchor,
    required this.isFront,
    required this.isDriven,
  });

  final Vector3 localAnchor;
  final bool isFront;
  final bool isDriven;

  bool grounded = false;
  double compression = 0.0;
  double prevCompression = 0.0;
  double normalForce = 0.0;
  double steerAngle = 0.0;
  double spinAngle = 0.0;
  double slipRatio = 0.0;
  double suspensionLength = 0.42;
}

/// Real-Earth 4-wheel raycast vehicle physics solver:
/// - Hooke's Law spring-damper suspension (real roll, pitch, and weight transfer)
/// - Engine torque/power curve + automatic multi-speed gearbox with realistic top speed
/// - Progressive steering rack with speed-sensitive Ackermann geometry
/// - Pacejka-style lateral & longitudinal tire forces clamped by Coulomb friction circle
/// - Aerodynamic drag and rolling resistance
class RaycastVehicle {
  RaycastVehicle({VehicleConfig? config}) : config = config ?? VehicleConfig() {
    final hx = this.config.trackWidth * 0.5;
    final hz = this.config.wheelbase * 0.5;
    wheels = [
      WheelState(localAnchor: Vector3(-hx, 0.0, -hz), isFront: true, isDriven: false),
      WheelState(localAnchor: Vector3(hx, 0.0, -hz), isFront: true, isDriven: false),
      WheelState(localAnchor: Vector3(-hx, 0.0, hz), isFront: false, isDriven: true),
      WheelState(localAnchor: Vector3(hx, 0.0, hz), isFront: false, isDriven: true),
    ];
    engineRpm = this.config.idleRpm;
  }

  final VehicleConfig config;
  late final List<WheelState> wheels;

  /// Current smoothed center steering angle in radians (+left, -right).
  double steerAngle = 0.0;

  /// Current gear: -1 = Reverse, 1..N = Forward gears.
  int currentGear = 1;

  /// Current engine speed in RPM.
  double engineRpm = 900.0;

  /// Current engine output torque in Nm (before gear multiplication).
  double currentTorqueNm = 0.0;

  double _shiftCooldown = 0.0;

  /// Evaluates a realistic combustion-engine torque curve (Nm) at [rpm].
  /// Broad midrange around [VehicleConfig.peakTorqueRpm], tapering off cleanly at redline.
  double evaluateTorqueCurve(double rpm) {
    if (rpm >= config.redlineRpm) return 0.0;
    final clamped = rpm.clamp(config.idleRpm, config.redlineRpm);
    if (clamped <= config.peakTorqueRpm) {
      final t = (clamped - config.idleRpm) / math.max(1.0, config.peakTorqueRpm - config.idleRpm);
      // Smooth rise from 62% peak torque at idle to 100% at peakTorqueRpm
      final factor = 0.62 + 0.38 * math.sin(t * math.pi * 0.5);
      return config.peakTorqueNm * factor;
    } else {
      final t = (clamped - config.peakTorqueRpm) / math.max(1.0, config.redlineRpm - config.peakTorqueRpm);
      // Taper from 100% at peakTorqueRpm down to 68% right before redline cutoff
      final factor = 1.0 - 0.32 * t * t;
      return config.peakTorqueNm * factor;
    }
  }

  /// Updates automatic gearbox, engine RPM, and returns total wheel longitudinal drive force (N)
  /// across all driven wheels for the given [forwardSpeed] (m/s) and [throttle] (-1..1).
  double updatePowertrain(double forwardSpeed, double throttle, double dt) {
    if (!config.useGearbox) {
      engineRpm = (config.idleRpm + forwardSpeed.abs() * 90.0).clamp(config.idleRpm, config.redlineRpm);
      currentTorqueNm = config.peakTorqueNm * throttle.abs();
      return throttle.clamp(-1.0, 1.0) * config.engineForce;
    }

    if (_shiftCooldown > 0.0) _shiftCooldown = math.max(0.0, _shiftCooldown - dt);

    // Reverse engagement when stopped or reversing with negative throttle
    if (throttle < -0.05 && forwardSpeed < 1.0) {
      currentGear = -1;
    } else if (throttle > 0.05 && currentGear < 1) {
      currentGear = 1;
    }

    final ratios = config.gearRatios.isEmpty ? const [1.0] : config.gearRatios;
    final wheelRadius = math.max(1e-4, config.wheelRadius);
    final ratio = currentGear < 0
        ? config.reverseRatio
        : ratios[(currentGear - 1).clamp(0, ratios.length - 1)];
    final wheelRpm = (forwardSpeed.abs() / (2.0 * math.pi * wheelRadius)) * 60.0;
    final coupledRpm = wheelRpm * ratio * config.finalDrive;
    engineRpm = math.max(config.idleRpm, coupledRpm);

    // Automatic shifting with hysteresis + short shift cooldown
    if (currentGear >= 1 && _shiftCooldown <= 0.0) {
      if (engineRpm >= config.upshiftRpm && currentGear < ratios.length) {
        currentGear++;
        _shiftCooldown = 0.28;
      } else if (engineRpm <= config.downshiftRpm && currentGear > 1) {
        currentGear--;
        _shiftCooldown = 0.25;
      }
    }

    final activeRatio = currentGear < 0
        ? config.reverseRatio
        : ratios[(currentGear - 1).clamp(0, ratios.length - 1)];
    engineRpm = math.max(config.idleRpm, wheelRpm * activeRatio * config.finalDrive);

    final tIn = throttle.clamp(-1.0, 1.0);
    // Reverse throttle while moving forward in a forward gear applies braking instead of forward acceleration.
    if (currentGear >= 1 && tIn < -0.05) {
      currentTorqueNm = 0.0;
      return forwardSpeed > 0.05 ? -tIn.abs() * config.brakeForce : 0.0;
    }

    // Rev limiter cut at redline
    if (engineRpm >= config.redlineRpm) {
      currentTorqueNm = 0.0;
      return 0.0;
    }

    if (tIn.abs() <= 1e-4) {
      currentTorqueNm = 0.0;
      // Mild engine braking proportional to RPM
      return forwardSpeed.abs() > 0.5 ? -forwardSpeed.sign * (120.0 + engineRpm * 0.04) : 0.0;
    }

    final engineTorque = evaluateTorqueCurve(engineRpm) * tIn.abs();
    currentTorqueNm = engineTorque;
    final wheelTorque = engineTorque * activeRatio * config.finalDrive * config.drivetrainEfficiency;
    final totalForce = wheelTorque / wheelRadius;
    return currentGear < 0 ? -totalForce : totalForce;
  }

  /// Computes Ackermann left/right front wheel angles for a given center steer angle.
  (double left, double right) computeAckermann(double centerSteer) {
    if (centerSteer.abs() < 1e-4) return (0.0, 0.0);
    final turnRadius = config.wheelbase / math.tan(centerSteer.abs());
    final halfTrack = config.trackWidth * 0.5;
    final inner = math.atan(config.wheelbase / math.max(0.5, turnRadius - halfTrack));
    final outer = math.atan(config.wheelbase / (turnRadius + halfTrack));
    return centerSteer > 0 ? (inner, outer) : (-outer, -inner);
  }

  /// Smoothly updates the steering rack (never snaps instantaneously) with
  /// speed-sensitive max lock angle so high-speed steering feels stable.
  double updateSteering(double steerInput, double forwardSpeed, double dt) {
    final speedFactor = 1.0 / (1.0 + (forwardSpeed.abs() * 0.045));
    final minSteer = math.min(0.14, config.maxSteerAngle);
    final maxAllowed = (config.maxSteerAngle * speedFactor).clamp(minSteer, config.maxSteerAngle);
    final target = steerInput.clamp(-1.0, 1.0) * maxAllowed;
    final maxDelta = config.steerRate * dt;
    final delta = (target - steerAngle).clamp(-maxDelta, maxDelta);
    steerAngle += delta;

    final (left, right) = computeAckermann(steerAngle);
    wheels[0].steerAngle = left;
    wheels[1].steerAngle = right;
    wheels[2].steerAngle = 0.0;
    wheels[3].steerAngle = 0.0;
    return steerAngle;
  }

  /// Evaluates Hooke's Law spring-damper suspension force for one wheel given its
  /// raycast hit distance (`hitDistance == null` means wheel is airborne).
  double solveWheelSuspension(WheelState wheel, double? hitDistance, double dt) {
    wheel.prevCompression = wheel.compression;
    final maxRay = config.suspensionRestLength + config.wheelRadius;
    if (hitDistance == null || hitDistance >= maxRay) {
      wheel.grounded = false;
      wheel.compression = 0.0;
      wheel.normalForce = 0.0;
      wheel.suspensionLength = config.suspensionRestLength;
      return 0.0;
    }
    wheel.grounded = true;
    wheel.suspensionLength = (hitDistance - config.wheelRadius).clamp(0.05, config.suspensionRestLength);
    wheel.compression = (config.suspensionRestLength - wheel.suspensionLength).clamp(0.0, config.suspensionRestLength);
    final compVel = dt > 1e-6 ? (wheel.compression - wheel.prevCompression) / dt : 0.0;
    final f = config.suspensionStiffness * wheel.compression + config.suspensionDamping * compVel;
    wheel.normalForce = f > 0.0 ? f : 0.0;
    return wheel.normalForce;
  }

  /// Computes longitudinal and lateral tire force components `(fLong, fLat)`
  /// clamped to the Coulomb friction circle `mu * normalForce`.
  ///
  /// Pass [totalDriveForce] from [updatePowertrain] when using the gearbox/torque curve
  /// (if omitted, automatically evaluates the torque curve for the current gear/RPM).
  (double fLong, double fLat) solveTireForces(
    WheelState wheel, {
    required double forwardSpeed,
    required double lateralSpeed,
    required double throttle,
    required double brake,
    double? totalDriveForce,
  }) {
    if (!wheel.grounded || wheel.normalForce <= 0.0) {
      wheel.slipRatio = 0.0;
      return (0.0, 0.0);
    }

    final drivenCount = math.max(1, wheels.where((w) => w.isDriven).length);
    double fLong = 0.0;
    if (wheel.isDriven) {
      if (totalDriveForce != null) {
        fLong += totalDriveForce / drivenCount;
      } else if (throttle.abs() > 1e-4) {
        if (config.useGearbox) {
          final ratios = config.gearRatios.isEmpty ? const [1.0] : config.gearRatios;
          final wheelRadius = math.max(1e-4, config.wheelRadius);
          final ratio = currentGear < 0
              ? config.reverseRatio
              : ratios[(currentGear - 1).clamp(0, ratios.length - 1)];
          final wheelRpm = (forwardSpeed.abs() / (2.0 * math.pi * wheelRadius)) * 60.0;
          final rpm = math.max(config.idleRpm, wheelRpm * ratio * config.finalDrive);
          final tq = evaluateTorqueCurve(rpm) * throttle.abs().clamp(0.0, 1.0);
          final total = (tq * ratio * config.finalDrive * config.drivetrainEfficiency) / wheelRadius;
          fLong += (throttle >= 0 ? total : -total) / drivenCount;
        } else {
          fLong += throttle.clamp(-1.0, 1.0) * (config.engineForce / drivenCount);
        }
      }
    }
    if (brake > 1e-4 && forwardSpeed.abs() > 0.05) {
      fLong -= forwardSpeed.sign * brake.clamp(0.0, 1.0) * (config.brakeForce * 0.25);
    }
    // Rolling resistance
    if (forwardSpeed.abs() > 0.05) {
      fLong -= forwardSpeed.sign * config.rollingResistance * wheel.normalForce;
    }

    // Pacejka-style lateral cornering force proportional to lateral slip velocity
    final nominalLoad = config.mass * config.gravity * 0.25;
    final loadRatio = nominalLoad > 1e-4 ? (wheel.normalForce / nominalLoad) : 0.0;
    double fLat = -lateralSpeed * config.corneringStiffness * loadRatio;

    // Clamp combined tire vector to real Coulomb friction circle: sqrt(fLong^2 + fLat^2) <= mu * Fn
    final maxGrip = config.tireGripMu * wheel.normalForce;
    final mag = math.sqrt(fLong * fLong + fLat * fLat);
    if (mag > maxGrip && mag > 1e-6) {
      final scale = maxGrip / mag;
      fLong *= scale;
      fLat *= scale;
      wheel.slipRatio = ((mag - maxGrip) / maxGrip).clamp(0.0, 1.0);
    } else {
      wheel.slipRatio = 0.0;
    }
    return (fLong, fLat);
  }

  /// Aerodynamic drag force opposing velocity: `0.5 * rho * Cd * A * v^2`.
  Vector3 computeAeroDrag(Vector3 velocity) {
    final speedSq = velocity.length2;
    if (speedSq < 1e-6) return Vector3.zero();
    final speed = math.sqrt(speedSq);
    final dragMag = 0.5 * config.airDensity * config.dragCoefficient * config.frontalArea * speedSq;
    return velocity * (-dragMag / speed);
  }
}
