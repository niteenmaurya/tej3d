/// Unity-style ready-to-use gameplay components and a pre-wired
/// [BuiltInRegistry] so developers can build, play, save, and load 3D games
/// in minutes without writing boilerplate from scratch.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../editor/inspector.dart';
import '../engine/game_object.dart';
import '../engine/render/mesh.dart';
import '../engine/render/primitives.dart';
import '../math/mathf.dart';
import '../math/vec.dart';
import '../mesh/procedural_world.dart';
import '../mesh/spline_mesh.dart';
import '../serialization/component_registry.dart';
import '../world/mesh_tools.dart';
import 'custom_controls.dart';
import 'hud_canvas.dart';
import 'shooter_br_kit.dart';
import 'visual_script.dart';

Quaternion _eulerQuat(double rx, double ry, double rz) {
  final qy = Quaternion.axisAngle(Vector3(0, 1, 0), ry);
  final qx = Quaternion.axisAngle(Vector3(1, 0, 0), rx);
  final qz = Quaternion.axisAngle(Vector3(0, 0, 1), rz);
  return (qy * qx * qz).normalized();
}

Quaternion _lerpQuat(Quaternion a, Quaternion b, double t) {
  var dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
  var bx = b.x, by = b.y, bz = b.z, bw = b.w;
  if (dot < 0) {
    dot = -dot;
    bx = -bx;
    by = -by;
    bz = -bz;
    bw = -bw;
  }
  return Quaternion(
    a.x + (bx - a.x) * t,
    a.y + (by - a.y) * t,
    a.z + (bz - a.z) * t,
    a.w + (bw - a.w) * t,
  ).normalized();
}

Mesh _meshFromSmooth(SmoothMeshData d, String name) {
  final vc = d.vertexCount;
  final pos = Float32List(vc * 3);
  final nrm = Float32List(vc * 3);
  final uvs = Float32List(vc * 2);
  for (var i = 0; i < vc; i++) {
    final s = i * 8;
    pos[i * 3] = d.vertices[s];
    pos[i * 3 + 1] = d.vertices[s + 1];
    pos[i * 3 + 2] = d.vertices[s + 2];
    nrm[i * 3] = d.vertices[s + 3];
    nrm[i * 3 + 1] = d.vertices[s + 4];
    nrm[i * 3 + 2] = d.vertices[s + 5];
    uvs[i * 2] = d.vertices[s + 6];
    uvs[i * 2 + 1] = d.vertices[s + 7];
  }
  return Mesh(
    MeshArrays(pos, nrm, d.indices, uvs: uvs),
    name: name,
  );
}

/// Ready-to-use rigidbody physics component with Earth gravity, drag, bounce,
/// and simple floor contact so Play Mode works identically on every platform.
class SimpleRigidbody extends Component implements Inspectable {
  SimpleRigidbody({
    this.mass = 1.0,
    this.useGravity = true,
    this.isKinematic = false,
    this.gravity = -9.81,
    this.drag = 0.08,
    this.bounciness = 0.25,
    this.groundY = 0.5,
  });

  double mass;
  bool useGravity;
  bool isKinematic;
  double gravity;
  double drag;
  double bounciness;
  double groundY;

  final Vector3 velocity = Vector3.zero();
  final Vector3 _forceAccum = Vector3.zero();
  bool isGrounded = false;

  void addForce(Vector3 force) {
    if (isKinematic || mass <= 0) return;
    _forceAccum.add(force);
  }

  void addImpulse(Vector3 impulse) {
    if (isKinematic || mass <= 0) return;
    velocity.x += impulse.x / mass;
    velocity.y += impulse.y / mass;
    velocity.z += impulse.z / mass;
  }

  @override
  void fixedUpdate(double dt) {
    if (isKinematic || dt <= 0) return;
    if (mass > 0) {
      velocity.x += (_forceAccum.x / mass) * dt;
      velocity.y += (_forceAccum.y / mass) * dt;
      velocity.z += (_forceAccum.z / mass) * dt;
    }
    _forceAccum.setZero();
    if (useGravity) {
      velocity.y += gravity * dt;
    }
    final damp = math.max(0.0, 1.0 - drag * dt);
    velocity.x *= damp;
    velocity.z *= damp;

    final p = transform.worldPosition.clone();
    p.x += velocity.x * dt;
    p.y += velocity.y * dt;
    p.z += velocity.z * dt;

    var supportY = groundY;
    final myCol = gameObject.getComponent<BoxCollider>();
    final myHalfX = (myCol?.size.x ?? 1.0) * transform.localScale.x.abs() * 0.5;
    final myHalfY = (myCol?.size.y ?? 1.0) * transform.localScale.y.abs() * 0.5;
    final myHalfZ = (myCol?.size.z ?? 1.0) * transform.localScale.z.abs() * 0.5;

    final sc = gameObject.scene;
    if (sc != null) {
      sc.forEachActive((other) {
        if (identical(other, gameObject)) return;
        final col = other.getComponent<BoxCollider>();
        if (col == null || !col.enabled || col.isTrigger) return;
        final op = other.transform.worldPosition;
        final ohx = col.size.x * other.transform.localScale.x.abs() * 0.5;
        final ohy = col.size.y * other.transform.localScale.y.abs() * 0.5;
        final ohz = col.size.z * other.transform.localScale.z.abs() * 0.5;
        final overlapX = (p.x - op.x).abs() < (myHalfX + ohx);
        final overlapZ = (p.z - op.z).abs() < (myHalfZ + ohz);
        final overlapY = (p.y - op.y).abs() < (myHalfY + ohy);
        if (overlapX && overlapZ) {
          final topY = op.y + ohy + myHalfY;
          if (p.y >= topY - 0.65 && velocity.y <= 0.1 && topY > supportY) {
            supportY = topY;
          } else if (overlapY && other.tag != "Ground" && (ohy > 0.45 || other.tag == "Enemy" || other.tag == "Wall")) {
            final penX = (myHalfX + ohx) - (p.x - op.x).abs();
            final penZ = (myHalfZ + ohz) - (p.z - op.z).abs();
            if (penX < penZ) {
              final dir = (p.x >= op.x) ? 1.0 : -1.0;
              p.x += dir * penX;
              velocity.x = -velocity.x * bounciness;
            } else {
              final dir = (p.z >= op.z) ? 1.0 : -1.0;
              p.z += dir * penZ;
              velocity.z = -velocity.z * bounciness;
            }
          }
        }
      });
    }

    if (p.y <= supportY) {
      p.y = supportY;
      if (velocity.y < -0.5) {
        velocity.y = -velocity.y * bounciness;
      } else {
        velocity.y = 0.0;
      }
      isGrounded = true;
    } else {
      isGrounded = false;
    }
    transform.worldPosition = p;
  }

  @override
  List<InspectorField> get inspectorFields => [
    InspectorField.float('mass', () => mass, (v) => mass = v, min: 0.1, max: 1000),
    InspectorField.boolean('useGravity', () => useGravity, (v) => useGravity = v),
    InspectorField.boolean('isKinematic', () => isKinematic, (v) => isKinematic = v),
    InspectorField.float('gravity', () => gravity, (v) => gravity = v, min: -50, max: 50),
    InspectorField.float('drag', () => drag, (v) => drag = v, min: 0, max: 10),
    InspectorField.float('bounciness', () => bounciness, (v) => bounciness = v, min: 0, max: 1),
    InspectorField.float('groundY', () => groundY, (v) => groundY = v, min: -100, max: 100),
  ];
}

/// Axis-aligned box collider with trigger/overlap detection.
class BoxCollider extends Component implements Inspectable {
  BoxCollider({
    Vector3? size,
    this.isTrigger = false,
  }) : size = size ?? Vector3(1, 1, 1);

  Vector3 size;
  bool isTrigger;

  bool intersects(BoxCollider other) {
    final a = transform.worldPosition;
    final b = other.transform.worldPosition;
    final asx = size.x * transform.localScale.x.abs() * 0.5;
    final asy = size.y * transform.localScale.y.abs() * 0.5;
    final asz = size.z * transform.localScale.z.abs() * 0.5;
    final bsx = other.size.x * other.transform.localScale.x.abs() * 0.5;
    final bsy = other.size.y * other.transform.localScale.y.abs() * 0.5;
    final bsz = other.size.z * other.transform.localScale.z.abs() * 0.5;
    return (a.x - b.x).abs() <= (asx + bsx) &&
        (a.y - b.y).abs() <= (asy + bsy) &&
        (a.z - b.z).abs() <= (asz + bsz);
  }

  @override
  List<InspectorField> get inspectorFields => [
    InspectorField.vector3('size', () => size, (v) => size = v),
    InspectorField.boolean('isTrigger', () => isTrigger, (v) => isTrigger = v),
  ];
}

/// Continuously rotates an object around X/Y/Z axes (degrees per second).
class SpinScript extends Component implements Inspectable {
  SpinScript({this.speedX = 0, this.speedY = 90, this.speedZ = 0});

  double speedX;
  double speedY;
  double speedZ;

  @override
  void update(double dt) {
    final dx = speedX * dt * Mathf.deg2Rad;
    final dy = speedY * dt * Mathf.deg2Rad;
    final dz = speedZ * dt * Mathf.deg2Rad;
    final delta = _eulerQuat(dx, dy, dz);
    transform.localRotation = (transform.localRotation * delta).normalized();
  }

  @override
  List<InspectorField> get inspectorFields => [
    InspectorField.float('speedX', () => speedX, (v) => speedX = v, min: -720, max: 720),
    InspectorField.float('speedY', () => speedY, (v) => speedY = v, min: -720, max: 720),
    InspectorField.float('speedZ', () => speedZ, (v) => speedZ = v, min: -720, max: 720),
  ];
}

/// Moves an object back and forth along an offset vector (platforms, patrols).
class PatrolScript extends Component implements Inspectable {
  PatrolScript({
    Vector3? offset,
    this.speed = 1.5,
  }) : offset = offset ?? Vector3(4, 0, 0);

  Vector3 offset;
  double speed;

  Vector3? _origin;
  double _phase = 0;

  @override
  void start() {
    _origin = transform.localPosition.clone();
    _phase = 0;
  }

  @override
  void update(double dt) {
    _origin ??= transform.localPosition.clone();
    _phase += dt * speed;
    final t = (math.sin(_phase) + 1.0) * 0.5;
    transform.localPosition = Vector3(
      _origin!.x + offset.x * t,
      _origin!.y + offset.y * t,
      _origin!.z + offset.z * t,
    );
  }

  @override
  List<InspectorField> get inspectorFields => [
    InspectorField.vector3('offset', () => offset, (v) => offset = v),
    InspectorField.float('speed', () => speed, (v) => speed = v, min: 0, max: 20),
  ];
}

/// Ready-to-use 3D player movement & jump controller (WASD / virtual stick).
class PlayerController3D extends Component implements Inspectable {
  PlayerController3D({
    this.moveSpeed = 6.0,
    this.jumpSpeed = 7.5,
    this.turnSpeed = 8.0,
    this.groundY = 0.5,
  });

  double moveSpeed;
  double jumpSpeed;
  double turnSpeed;
  double groundY;

  /// External input axes (-1..1) set by keyboard, gamepad, or editor UI.
  double inputX = 0;
  double inputZ = 0;
  bool jumpQueued = false;

  double _verticalVel = 0;

  @override
  void update(double dt) {
    final rb = gameObject.getComponent<SimpleRigidbody>();
    final p = transform.localPosition;
    var mx = inputX;
    var mz = inputZ;
    final len = math.sqrt(mx * mx + mz * mz);
    if (len > 1.0) {
      mx /= len;
      mz /= len;
    }

    p.x += mx * moveSpeed * dt;
    p.z += mz * moveSpeed * dt;

    if (len > 0.05) {
      final yaw = math.atan2(-mx, -mz);
      final targetRot = Quaternion.axisAngle(Vector3(0, 1, 0), yaw);
      transform.localRotation = _lerpQuat(
        transform.localRotation,
        targetRot,
        Mathf.clamp(turnSpeed * dt, 0.0, 1.0),
      );
    }

    if (rb != null) {
      if (jumpQueued && rb.isGrounded) {
        rb.velocity.y = jumpSpeed;
        rb.isGrounded = false;
      }
    } else {
      if (jumpQueued && p.y <= groundY + 0.02) {
        _verticalVel = jumpSpeed;
      }
      _verticalVel += -18.0 * dt;
      p.y += _verticalVel * dt;
      if (p.y <= groundY) {
        p.y = groundY;
        _verticalVel = 0;
      }
    }
    jumpQueued = false;
    transform.localPosition = p;
  }

  @override
  List<InspectorField> get inspectorFields => [
    InspectorField.float('moveSpeed', () => moveSpeed, (v) => moveSpeed = v, min: 0.5, max: 50),
    InspectorField.float('jumpSpeed', () => jumpSpeed, (v) => jumpSpeed = v, min: 0, max: 30),
    InspectorField.float('turnSpeed', () => turnSpeed, (v) => turnSpeed = v, min: 1, max: 30),
    InspectorField.float('groundY', () => groundY, (v) => groundY = v, min: -100, max: 100),
  ];
}

/// Smooth Unity Cinemachine-style 3rd-person follow camera component.
class FollowCameraScript extends Component implements Inspectable {
  FollowCameraScript({
    this.targetName = 'Player',
    Vector3? offset,
    this.smoothSpeed = 6.0,
  }) : offset = offset ?? Vector3(0, 4.5, 9.0);

  String targetName;
  Vector3 offset;
  double smoothSpeed;

  @override
  void lateUpdate(double dt) {
    final scene = gameObject.scene;
    if (scene == null) return;
    final target = scene.find(targetName);
    if (target == null) return;
    final desired = target.transform.worldPosition + offset;
    final cur = transform.worldPosition;
    final t = Mathf.clamp(smoothSpeed * dt, 0.0, 1.0);
    transform.worldPosition = Vector3(
      cur.x + (desired.x - cur.x) * t,
      cur.y + (desired.y - cur.y) * t,
      cur.z + (desired.z - cur.z) * t,
    );
    transform.lookAt(target.transform.worldPosition + Vector3(0, 1.0, 0));
  }

  @override
  List<InspectorField> get inspectorFields => [
    InspectorField.text('targetName', () => targetName, (v) => targetName = v),
    InspectorField.vector3('offset', () => offset, (v) => offset = v),
    InspectorField.float('smoothSpeed', () => smoothSpeed, (v) => smoothSpeed = v, min: 0.5, max: 30),
  ];
}

/// Bobbing collectible pickup that triggers when a target object approaches.
class CollectibleScript extends Component implements Inspectable {
  CollectibleScript({
    this.points = 10,
    this.pickupRadius = 1.4,
    this.collectorName = 'Player',
    this.onCollected,
  });

  int points;
  double pickupRadius;
  String collectorName;
  void Function(int points)? onCollected;

  double _time = 0;
  double? _baseY;
  bool collected = false;

  @override
  void update(double dt) {
    if (collected) return;
    _baseY ??= transform.localPosition.y;
    _time += dt;
    final p = transform.localPosition;
    p.y = _baseY! + math.sin(_time * 3.0) * 0.18;
    transform.localPosition = p;
    transform.localRotation =
        (transform.localRotation * Quaternion.axisAngle(Vector3(0, 1, 0), 2.2 * dt))
            .normalized();

    final collector = gameObject.scene?.find(collectorName);
    if (collector != null) {
      final dist = (collector.transform.worldPosition - transform.worldPosition).length;
      if (dist <= pickupRadius) {
        collected = true;
        gameObject.active = false;
        onCollected?.call(points);
      }
    }
  }

  @override
  List<InspectorField> get inspectorFields => [
    InspectorField.integer('points', () => points, (v) => points = v, min: 1, max: 10000),
    InspectorField.float('pickupRadius', () => pickupRadius, (v) => pickupRadius = v, min: 0.2, max: 20),
    InspectorField.text('collectorName', () => collectorName, (v) => collectorName = v),
  ];
}


/// Hazard obstacle that damages or respawns the player on contact.
class HazardScript extends Component implements Inspectable {
  HazardScript({
    this.damage = 1,
    this.hitRadius = 1.2,
    this.targetName = 'Player',
    this.onHit,
  });

  int damage;
  double hitRadius;
  String targetName;
  void Function(int damage)? onHit;

  double _cooldown = 0.0;

  @override
  void update(double dt) {
    if (_cooldown > 0) {
      _cooldown -= dt;
      return;
    }
    final target = gameObject.scene?.find(targetName);
    if (target == null) return;
    final dist = (target.transform.worldPosition - transform.worldPosition).length;
    if (dist <= hitRadius) {
      _cooldown = 1.0;
      onHit?.call(damage);
    }
  }

  @override
  List<InspectorField> get inspectorFields => [
    InspectorField.integer('damage', () => damage, (v) => damage = v, min: 1, max: 100),
    InspectorField.float('hitRadius', () => hitRadius, (v) => hitRadius = v, min: 0.2, max: 20),
    InspectorField.text('targetName', () => targetName, (v) => targetName = v),
  ];
}

/// Goal / Finish portal that triggers Victory when the player reaches it.
class GoalZoneScript extends Component implements Inspectable {
  GoalZoneScript({
    this.triggerRadius = 1.8,
    this.targetName = 'Player',
    this.requiredScore = 0,
    this.scoreProvider,
    this.onGoalReached,
  });

  double triggerRadius;
  String targetName;
  int requiredScore;
  int Function()? scoreProvider;
  void Function()? onGoalReached;

  bool reached = false;

  int _currentScore(Scene scene) {
    if (scoreProvider != null) return scoreProvider!();
    var total = 0;
    scene.forEachAll((go) {
      for (final c in go.getComponents<CollectibleScript>()) {
        if (c.collected) total += c.points;
      }
      for (final v in go.getComponents<VisualScriptComponent>()) {
        total += v.scoreDelta;
      }
    });
    return total;
  }

  @override
  void update(double dt) {
    if (reached) return;
    final scene = gameObject.scene;
    if (scene == null) return;
    final target = scene.find(targetName);
    if (target == null) return;
    if (requiredScore > 0 && _currentScore(scene) < requiredScore) return;
    final dist = (target.transform.worldPosition - transform.worldPosition).length;
    if (dist <= triggerRadius) {
      reached = true;
      onGoalReached?.call();
    }
  }

  @override
  List<InspectorField> get inspectorFields => [
    InspectorField.float('triggerRadius', () => triggerRadius, (v) => triggerRadius = v, min: 0.5, max: 20),
    InspectorField.integer('requiredScore', () => requiredScore, (v) => requiredScore = v, min: 0, max: 10000),
    InspectorField.text('targetName', () => targetName, (v) => targetName = v),
  ];
}

/// Built-in zero-dependency SFX component synced with SfxSynth & PcmSoftwareAudioBackend.
class AudioEffectComponent extends Component implements Inspectable {
  AudioEffectComponent({
    this.clipName = 'coin',
    this.volume = 0.85,
    this.loop = false,
    this.spatial = true,
  });

  String clipName; // 'coin', 'jump', 'laser', 'explosion'
  double volume;
  bool loop;
  bool spatial;

  @override
  List<InspectorField> get inspectorFields => [
    InspectorField.text('clipName', () => clipName, (v) => clipName = v),
    InspectorField.float('volume', () => volume, (v) => volume = v, min: 0.0, max: 2.0),
    InspectorField.boolean('loop', () => loop, (v) => loop = v),
    InspectorField.boolean('spatial', () => spatial, (v) => spatial = v),
  ];
}

/// Built-in 3D Proximity / Team Voice Chat zone synced with VoiceChatManager.
class VoiceZoneComponent extends Component implements Inspectable {
  VoiceZoneComponent({
    this.channel = 'proximity',
    this.maxDistance = 30.0,
    this.pushToTalk = false,
  });

  String channel; // 'proximity', 'team', 'global'
  double maxDistance;
  bool pushToTalk;

  @override
  List<InspectorField> get inspectorFields => [
    InspectorField.text('channel', () => channel, (v) => channel = v),
    InspectorField.float('maxDistance', () => maxDistance, (v) => maxDistance = v, min: 2.0, max: 200.0),
    InspectorField.boolean('pushToTalk', () => pushToTalk, (v) => pushToTalk = v),
  ];
}

/// Factory helpers to create common Unity-style primitives & environment meshes
/// by string key for serialization and editor spawning.

/// Progressive smooth-steering 3D vehicle controller for curved sports cars
/// (smooth steering ramp, acceleration, reverse, drag, and yaw physics).
class CarController3D extends Component implements Inspectable {
  CarController3D({
    this.maxSpeed = 22.0,
    this.acceleration = 14.0,
    this.brakeForce = 20.0,
    this.steerRate = 2.6,
    this.maxSteerAngle = 0.55,
    this.drag = 0.35,
  });

  double maxSpeed;
  double acceleration;
  double brakeForce;
  double steerRate;
  double maxSteerAngle;
  double drag;

  double throttle = 0.0; // -1..1
  double steerInput = 0.0; // -1..1
  double speed = 0.0;
  double currentSteer = 0.0;
  double heading = 0.0;
  double _verticalVel = 0.0;

  @override
  void start() {
    final f = transform.forward;
    if (f.x * f.x + f.z * f.z > 1e-8) {
      heading = math.atan2(-f.x, -f.z);
    }
  }

  @override
  void update(double dt) {
    // Progressive steering rack (smoothly approaches target angle, never snaps)
    final targetSteer = steerInput.clamp(-1.0, 1.0) * maxSteerAngle;
    final maxStep = steerRate * dt;
    final diff = targetSteer - currentSteer;
    if (diff.abs() <= maxStep) {
      currentSteer = targetSteer;
    } else {
      currentSteer += diff.sign * maxStep;
    }

    if (throttle > 0.05) {
      speed += throttle * acceleration * dt;
    } else if (throttle < -0.05) {
      speed += throttle * brakeForce * dt;
    } else {
      speed *= math.max(0.0, 1.0 - drag * 3.0 * dt);
    }
    speed = speed.clamp(-maxSpeed * 0.45, maxSpeed);

    // Ackermann-style bicycle turning proportional to speed
    if (speed.abs() > 0.15) {
      final turnFactor = (speed / 6.0).clamp(-1.0, 1.0);
      heading -= currentSteer * turnFactor * 2.4 * dt;
    }

    final fx = -math.sin(heading);
    final fz = -math.cos(heading);
    final pos = transform.worldPosition.clone();
    pos.x += fx * speed * dt;
    pos.z += fz * speed * dt;

    // Earth gravity & ground support for vehicles
    if (pos.y > 0.08 || _verticalVel != 0.0) {
      _verticalVel += -9.81 * dt;
      pos.y += _verticalVel * dt;
      if (pos.y <= 0.08) {
        pos.y = 0.08;
        _verticalVel = 0.0;
      }
    }

    // Solid BoxCollider-to-BoxCollider collision separation (cars & guardrails never overlap!)
    final myCol = gameObject.getComponent<BoxCollider>();
    final sc = gameObject.scene;
    if (myCol != null && sc != null) {
      final myHx = myCol.size.x * transform.localScale.x.abs() * 0.5;
      final myHy = myCol.size.y * transform.localScale.y.abs() * 0.5;
      final myHz = myCol.size.z * transform.localScale.z.abs() * 0.5;
      sc.forEachActive((other) {
        if (identical(other, gameObject) || other.tag == "Ground") return;
        final col = other.getComponent<BoxCollider>();
        if (col == null || !col.enabled || col.isTrigger) return;
        final op = other.transform.worldPosition;
        final ohx = col.size.x * other.transform.localScale.x.abs() * 0.5;
        final ohy = col.size.y * other.transform.localScale.y.abs() * 0.5;
        final ohz = col.size.z * other.transform.localScale.z.abs() * 0.5;
        final penX = (myHx + ohx) - (pos.x - op.x).abs();
        final penY = (myHy + ohy) - (pos.y - op.y).abs();
        final penZ = (myHz + ohz) - (pos.z - op.z).abs();
        if (penX > 0 && penY > 0 && penZ > 0) {
          if (penX < penZ) {
            pos.x += (pos.x >= op.x ? 1.0 : -1.0) * penX;
            speed *= 0.85;
          } else {
            pos.z += (pos.z >= op.z ? 1.0 : -1.0) * penZ;
            speed = -speed * 0.35;
          }
        }
      });
    }

    transform.worldPosition = pos;
    transform.localRotation = Quaternion.axisAngle(Vector3(0, 1, 0), heading);
  }

  @override
  List<InspectorField> get inspectorFields => [
    InspectorField.float('maxSpeed', () => maxSpeed, (v) => maxSpeed = v, min: 4, max: 80),
    InspectorField.float('acceleration', () => acceleration, (v) => acceleration = v, min: 2, max: 50),
    InspectorField.float('steerRate', () => steerRate, (v) => steerRate = v, min: 0.5, max: 10),
    InspectorField.float('drag', () => drag, (v) => drag = v, min: 0.0, max: 5.0),
  ];
}

class ProceduralMeshCatalog {
  const ProceduralMeshCatalog._();

  static const List<String> names = [
    'box',
    'sphere',
    'cylinder',
    'plane',
    'pine',
    'boulder',
    'terrain',
    'coupe',
  ];

  static Mesh build(String key) {
    switch (key) {
      case 'sphere':
        return Primitives.sphere(0.6, rings: 12, sectors: 18);
      case 'cylinder':
        return Primitives.cylinder(0.5, 1.4, sides: 16);
      case 'plane':
        return Primitives.plane(24, 24, segments: 6);
      case 'pine':
        return _meshFromSmooth(
          ProceduralWorldMeshes.buildPineCanopy(
            totalHeight: 3.6,
            baseRadius: 1.5,
            tiers: 4,
            startY: 0.4,
          ),
          'pine',
        );
      case 'boulder':
        return _meshFromSmooth(
          ProceduralWorldMeshes.buildBoulder(radius: 1.0, seed: 42),
          'boulder',
        );
      case 'coupe':
        return _meshFromSmooth(SplineMeshBuilder.buildCurvedCoupeBody(), 'coupe');
      case 'terrain':
        return _meshFromSmooth(
          ProceduralWorldMeshes.buildTerrain(
            width: 28,
            depth: 28,
            segX: 14,
            segZ: 14,
            heightFn: (x, z) =>
                math.sin(x * 0.22) * math.cos(z * 0.22) * 1.4,
          ),
          'terrain',
        );
      case 'box':
      default:
        return Primitives.box(Vector3(1, 1, 1));
    }
  }
}

/// Stores the primitive mesh key alongside a [MeshRenderer] so scenes round-trip
/// cleanly to JSON and back without losing geometry.
class PrimitiveMeshTag extends Component implements Inspectable {
  PrimitiveMeshTag(this.meshKey);

  String meshKey;

  @override
  List<InspectorField> get inspectorFields => [
    InspectorField.text('meshKey', () => meshKey, (v) => meshKey = v),
  ];
}

/// Pre-wired [ComponentRegistry] for all core & built-in Unity-style components.
class BuiltInRegistry {
  const BuiltInRegistry._();

  static ComponentRegistry create() {
    final reg = ComponentRegistry();

    for (final name in ProceduralMeshCatalog.names) {
      reg.registerMesh(name, ProceduralMeshCatalog.build(name));
    }

    reg.register<PrimitiveMeshTag>(
      'PrimitiveMeshTag',
      toJson: (raw) => {'meshKey': (raw as PrimitiveMeshTag).meshKey},
      fromJson: (m) => PrimitiveMeshTag((m['meshKey'] as String?) ?? 'box'),
    );

    reg.register<SimpleRigidbody>(
      'SimpleRigidbody',
      toJson: (raw) {
        final r = raw as SimpleRigidbody;
        return {
          'mass': r.mass,
          'useGravity': r.useGravity,
          'isKinematic': r.isKinematic,
          'gravity': r.gravity,
          'drag': r.drag,
          'bounciness': r.bounciness,
          'groundY': r.groundY,
        };
      },
      fromJson: (m) => SimpleRigidbody(
        mass: (m['mass'] as num?)?.toDouble() ?? 1.0,
        useGravity: (m['useGravity'] as bool?) ?? true,
        isKinematic: (m['isKinematic'] as bool?) ?? false,
        gravity: (m['gravity'] as num?)?.toDouble() ?? -9.81,
        drag: (m['drag'] as num?)?.toDouble() ?? 0.08,
        bounciness: (m['bounciness'] as num?)?.toDouble() ?? 0.25,
        groundY: (m['groundY'] as num?)?.toDouble() ?? 0.5,
      ),
    );

    reg.register<BoxCollider>(
      'BoxCollider',
      toJson: (raw) {
        final c = raw as BoxCollider;
        return {
          'size': [c.size.x, c.size.y, c.size.z],
          'isTrigger': c.isTrigger,
        };
      },
      fromJson: (m) {
        final s = (m['size'] as List?) ?? const [1.0, 1.0, 1.0];
        return BoxCollider(
          size: Vector3(
            (s[0] as num).toDouble(),
            (s[1] as num).toDouble(),
            (s[2] as num).toDouble(),
          ),
          isTrigger: (m['isTrigger'] as bool?) ?? false,
        );
      },
    );

    reg.register<SpinScript>(
      'SpinScript',
      toJson: (raw) {
        final s = raw as SpinScript;
        return {'speedX': s.speedX, 'speedY': s.speedY, 'speedZ': s.speedZ};
      },
      fromJson: (m) => SpinScript(
        speedX: (m['speedX'] as num?)?.toDouble() ?? 0,
        speedY: (m['speedY'] as num?)?.toDouble() ?? 90,
        speedZ: (m['speedZ'] as num?)?.toDouble() ?? 0,
      ),
    );

    reg.register<PatrolScript>(
      'PatrolScript',
      toJson: (raw) {
        final p = raw as PatrolScript;
        return {
          'offset': [p.offset.x, p.offset.y, p.offset.z],
          'speed': p.speed,
        };
      },
      fromJson: (m) {
        final o = (m['offset'] as List?) ?? const [4.0, 0.0, 0.0];
        return PatrolScript(
          offset: Vector3(
            (o[0] as num).toDouble(),
            (o[1] as num).toDouble(),
            (o[2] as num).toDouble(),
          ),
          speed: (m['speed'] as num?)?.toDouble() ?? 1.5,
        );
      },
    );

    reg.register<PlayerController3D>(
      'PlayerController3D',
      toJson: (raw) {
        final p = raw as PlayerController3D;
        return {
          'moveSpeed': p.moveSpeed,
          'jumpSpeed': p.jumpSpeed,
          'turnSpeed': p.turnSpeed,
          'groundY': p.groundY,
        };
      },
      fromJson: (m) => PlayerController3D(
        moveSpeed: (m['moveSpeed'] as num?)?.toDouble() ?? 6.0,
        jumpSpeed: (m['jumpSpeed'] as num?)?.toDouble() ?? 7.5,
        turnSpeed: (m['turnSpeed'] as num?)?.toDouble() ?? 8.0,
        groundY: (m['groundY'] as num?)?.toDouble() ?? 0.5,
      ),
    );

    reg.register<FollowCameraScript>(
      'FollowCameraScript',
      toJson: (raw) {
        final c = raw as FollowCameraScript;
        return {
          'targetName': c.targetName,
          'offset': [c.offset.x, c.offset.y, c.offset.z],
          'smoothSpeed': c.smoothSpeed,
        };
      },
      fromJson: (m) {
        final o = (m['offset'] as List?) ?? const [0.0, 4.5, 9.0];
        return FollowCameraScript(
          targetName: (m['targetName'] as String?) ?? 'Player',
          offset: Vector3(
            (o[0] as num).toDouble(),
            (o[1] as num).toDouble(),
            (o[2] as num).toDouble(),
          ),
          smoothSpeed: (m['smoothSpeed'] as num?)?.toDouble() ?? 6.0,
        );
      },
    );

    reg.register<CollectibleScript>(
      'CollectibleScript',
      toJson: (raw) {
        final c = raw as CollectibleScript;
        return {
          'points': c.points,
          'pickupRadius': c.pickupRadius,
          'collectorName': c.collectorName,
        };
      },
      fromJson: (m) => CollectibleScript(
        points: (m['points'] as num?)?.toInt() ?? 10,
        pickupRadius: (m['pickupRadius'] as num?)?.toDouble() ?? 1.4,
        collectorName: (m['collectorName'] as String?) ?? 'Player',
      ),
    );

    reg.register<HazardScript>(
      'HazardScript',
      toJson: (raw) {
        final h = raw as HazardScript;
        return {
          'damage': h.damage,
          'hitRadius': h.hitRadius,
          'targetName': h.targetName,
        };
      },
      fromJson: (m) => HazardScript(
        damage: (m['damage'] as num?)?.toInt() ?? 1,
        hitRadius: (m['hitRadius'] as num?)?.toDouble() ?? 1.2,
        targetName: (m['targetName'] as String?) ?? 'Player',
      ),
    );

    reg.register<GoalZoneScript>(
      'GoalZoneScript',
      toJson: (raw) {
        final g = raw as GoalZoneScript;
        return {
          'triggerRadius': g.triggerRadius,
          'targetName': g.targetName,
          'requiredScore': g.requiredScore,
        };
      },
      fromJson: (m) => GoalZoneScript(
        triggerRadius: (m['triggerRadius'] as num?)?.toDouble() ?? 1.8,
        targetName: (m['targetName'] as String?) ?? 'Player',
        requiredScore: (m['requiredScore'] as num?)?.toInt() ?? 0,
      ),
    );

    reg.register<AudioEffectComponent>(
      'AudioEffectComponent',
      toJson: (raw) {
        final a = raw as AudioEffectComponent;
        return {
          'clipName': a.clipName,
          'volume': a.volume,
          'loop': a.loop,
          'spatial': a.spatial,
        };
      },
      fromJson: (m) => AudioEffectComponent(
        clipName: (m['clipName'] as String?) ?? 'coin',
        volume: (m['volume'] as num?)?.toDouble() ?? 0.85,
        loop: (m['loop'] as bool?) ?? false,
        spatial: (m['spatial'] as bool?) ?? true,
      ),
    );

    reg.register<VoiceZoneComponent>(
      'VoiceZoneComponent',
      toJson: (raw) {
        final v = raw as VoiceZoneComponent;
        return {
          'channel': v.channel,
          'maxDistance': v.maxDistance,
          'pushToTalk': v.pushToTalk,
        };
      },
      fromJson: (m) => VoiceZoneComponent(
        channel: (m['channel'] as String?) ?? 'proximity',
        maxDistance: (m['maxDistance'] as num?)?.toDouble() ?? 30.0,
        pushToTalk: (m['pushToTalk'] as bool?) ?? false,
      ),
    );

    reg.register<CarController3D>(
      'CarController3D',
      toJson: (raw) {
        final c = raw as CarController3D;
        return {
          'maxSpeed': c.maxSpeed,
          'acceleration': c.acceleration,
          'brakeForce': c.brakeForce,
          'steerRate': c.steerRate,
          'maxSteerAngle': c.maxSteerAngle,
          'drag': c.drag,
        };
      },
      fromJson: (m) => CarController3D(
        maxSpeed: (m['maxSpeed'] as num?)?.toDouble() ?? 22.0,
        acceleration: (m['acceleration'] as num?)?.toDouble() ?? 14.0,
        brakeForce: (m['brakeForce'] as num?)?.toDouble() ?? 20.0,
        steerRate: (m['steerRate'] as num?)?.toDouble() ?? 2.6,
        maxSteerAngle: (m['maxSteerAngle'] as num?)?.toDouble() ?? 0.55,
        drag: (m['drag'] as num?)?.toDouble() ?? 0.35,
      ),
    );

    reg.register<CustomControlLayoutComponent>(
      'CustomControlLayoutComponent',
      toJson: (raw) {
        final c = raw as CustomControlLayoutComponent;
        return {
          'buttons': [for (final b in c.buttons) b.toJson()],
        };
      },
      fromJson: (m) {
        final list = (m['buttons'] as List?) ?? const [];
        return CustomControlLayoutComponent(
          buttons: [
            for (final item in list)
              CustomControlButton.fromJson((item as Map).cast<String, Object?>()),
          ],
        );
      },
    );

    reg.register<HealthDamageComponent>(
      'HealthDamageComponent',
      toJson: (raw) {
        final h = raw as HealthDamageComponent;
        return {
          'maxHealth': h.maxHealth,
          'currentHealth': h.currentHealth,
          'maxShield': h.maxShield,
          'shield': h.shield,
          'destroyOnDeath': h.destroyOnDeath,
        };
      },
      fromJson: (m) => HealthDamageComponent(
        maxHealth: (m['maxHealth'] as num?)?.toDouble() ?? 100.0,
        currentHealth: (m['currentHealth'] as num?)?.toDouble(),
        maxShield: (m['maxShield'] as num?)?.toDouble() ?? 50.0,
        shield: (m['shield'] as num?)?.toDouble() ?? 25.0,
        destroyOnDeath: m['destroyOnDeath'] == true,
      ),
    );

    reg.register<WeaponComponent>(
      'WeaponComponent',
      toJson: (raw) {
        final w = raw as WeaponComponent;
        return {
          'weaponName': w.weaponName,
          'damage': w.damage,
          'fireRate': w.fireRate,
          'magSize': w.magSize,
          'ammo': w.ammo,
          'reserveAmmo': w.reserveAmmo,
          'reloadDuration': w.reloadDuration,
          'range': w.range,
          'recoilKick': w.recoilKick,
        };
      },
      fromJson: (m) => WeaponComponent(
        weaponName: (m['weaponName'] as String?) ?? 'AK-47 Tactical',
        damage: (m['damage'] as num?)?.toDouble() ?? 28.0,
        fireRate: (m['fireRate'] as num?)?.toDouble() ?? 8.5,
        magSize: (m['magSize'] as num?)?.toInt() ?? 30,
        ammo: (m['ammo'] as num?)?.toInt(),
        reserveAmmo: (m['reserveAmmo'] as num?)?.toInt() ?? 120,
        reloadDuration: (m['reloadDuration'] as num?)?.toDouble() ?? 1.6,
        range: (m['range'] as num?)?.toDouble() ?? 85.0,
        recoilKick: (m['recoilKick'] as num?)?.toDouble() ?? 0.04,
      ),
    );

    reg.register<EnemyBotAiComponent>(
      'EnemyBotAiComponent',
      toJson: (raw) {
        final b = raw as EnemyBotAiComponent;
        return {
          'targetTag': b.targetTag,
          'detectRange': b.detectRange,
          'attackRange': b.attackRange,
          'moveSpeed': b.moveSpeed,
          'patrolRadius': b.patrolRadius,
        };
      },
      fromJson: (m) => EnemyBotAiComponent(
        targetTag: (m['targetTag'] as String?) ?? 'Player',
        detectRange: (m['detectRange'] as num?)?.toDouble() ?? 28.0,
        attackRange: (m['attackRange'] as num?)?.toDouble() ?? 18.0,
        moveSpeed: (m['moveSpeed'] as num?)?.toDouble() ?? 4.2,
        patrolRadius: (m['patrolRadius'] as num?)?.toDouble() ?? 10.0,
      ),
    );

    reg.register<LootSpawnerComponent>(
      'LootSpawnerComponent',
      toJson: (raw) {
        final l = raw as LootSpawnerComponent;
        return {
          'lootType': l.lootType.name,
          'amount': l.amount,
          'pickupRadius': l.pickupRadius,
          'respawnSeconds': l.respawnSeconds,
        };
      },
      fromJson: (m) => LootSpawnerComponent(
        lootType: m['lootType'] is String
            ? (LootType.values.asNameMap()[m['lootType'] as String] ?? LootType.medkit)
            : LootType.medkit,
        amount: (m['amount'] as num?)?.toDouble() ?? 35.0,
        pickupRadius: (m['pickupRadius'] as num?)?.toDouble() ?? 2.0,
        respawnSeconds: (m['respawnSeconds'] as num?)?.toDouble() ?? 12.0,
      ),
    );

    reg.register<SafeZoneComponent>(
      'SafeZoneComponent',
      toJson: (raw) {
        final z = raw as SafeZoneComponent;
        return {
          'center': [z.center.x, z.center.y, z.center.z],
          'initialRadius': z.initialRadius,
          'minRadius': z.minRadius,
          'shrinkSpeed': z.shrinkSpeed,
          'damagePerSecond': z.damagePerSecond,
        };
      },
      fromJson: (m) {
        final c = m['center'];
        final center = (c is List && c.length == 3 && c.every((e) => e is num))
            ? Vector3((c[0] as num).toDouble(), (c[1] as num).toDouble(), (c[2] as num).toDouble())
            : null;
        return SafeZoneComponent(
          center: center,
          initialRadius: (m['initialRadius'] as num?)?.toDouble() ?? 48.0,
          minRadius: (m['minRadius'] as num?)?.toDouble() ?? 6.0,
          shrinkSpeed: (m['shrinkSpeed'] as num?)?.toDouble() ?? 1.4,
          damagePerSecond: (m['damagePerSecond'] as num?)?.toDouble() ?? 8.0,
        );
      },
    );

    reg.register<HudCanvasComponent>(
      'HudCanvasComponent',
      toJson: (raw) {
        final h = raw as HudCanvasComponent;
        return {
          'widgets': [for (final w in h.widgets) w.toJson()],
        };
      },
      fromJson: (m) {
        final list = m['widgets'];
        if (list is! List) return HudCanvasComponent();
        return HudCanvasComponent(
          widgets: [
            for (final item in list)
              if (item is Map) HudWidgetSpec.fromJson(item.cast<String, Object?>()),
          ],
        );
      },
    );

    reg.register<VfxEmitterComponent>(
      'VfxEmitterComponent',
      toJson: (raw) {
        final v = raw as VfxEmitterComponent;
        return {
          'preset': v.preset.name,
          'autoPlay': v.autoPlay,
          'intensity': v.intensity,
        };
      },
      fromJson: (m) => VfxEmitterComponent(
        preset: m['preset'] is String
            ? (VfxPreset.values.asNameMap()[m['preset'] as String] ?? VfxPreset.muzzleFlash)
            : VfxPreset.muzzleFlash,
        autoPlay: m['autoPlay'] == true,
        intensity: (m['intensity'] as num?)?.toDouble() ?? 1.0,
      ),
    );

    reg.register<VisualScriptComponent>(
      'VisualScriptComponent',
      toJson: (raw) {
        final vs = raw as VisualScriptComponent;
        return {
          'rules': [for (final r in vs.rules) r.toJson()],
        };
      },
      fromJson: (m) {
        final list = m['rules'];
        if (list is! List) return VisualScriptComponent();
        return VisualScriptComponent(
          rules: [
            for (final item in list)
              if (item is Map) VisualRule.fromJson(item.cast<String, Object?>()),
          ],
        );
      },
    );

    return reg;
  }
}
