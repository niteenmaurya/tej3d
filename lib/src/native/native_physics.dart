import 'dart:typed_data';

import '../math/vec.dart';

import '../engine/game_object.dart';
import '../engine/render/mesh.dart';
import '../engine/debug_draw.dart';
import 'native_character.dart';
import 'native_world.dart';

/// Connects the Dart scene to the C++ physics. Make one, add bodies with
/// [NativeRigidBody] and [NativeMeshCollider], and call
/// [step] from `Tej3DGame.onFixedUpdate` (or directly in headless scripts —
/// attached bodies are auto-created on the first [step] or `createJoint` call
/// even if `scene.update()` has not run yet).
class NativePhysics {
  NativePhysics(this.world);

  final NativeWorld world;
  final Map<int, NativeRigidBody> bodies = {};

  final List<NativeCharacterController> characters = [];
  final Set<NativeRigidBody> _trackedBodies = {};
  final Set<NativeMeshCollider> _trackedMeshes = {};
  final Set<NativeCharacterController> _trackedCharacters = {};
  final List<void Function(double dt)> _preStepHooks = [];
  Vector3 _gravity = Vector3(0, -9.81, 0);

  Vector3 get gravity => _gravity.clone();
  set gravity(Vector3 g) {
    _gravity = g.clone();
    world.gravity = g;
  }

  /// Internal registration helpers so bodies/colliders/characters auto-awake before step/joints.
  void registerBody(NativeRigidBody b) => _trackedBodies.add(b);
  void unregisterBody(NativeRigidBody b) => _trackedBodies.remove(b);
  void registerMeshCollider(NativeMeshCollider m) => _trackedMeshes.add(m);
  void unregisterMeshCollider(NativeMeshCollider m) => _trackedMeshes.remove(m);
  void registerCharacter(NativeCharacterController c) => _trackedCharacters.add(c);
  void unregisterCharacter(NativeCharacterController c) {
    _trackedCharacters.remove(c);
    characters.remove(c);
  }

  /// Registers a callback invoked before each native physics world update (e.g. vehicles).
  void addPreStepHook(void Function(double dt) hook) {
    if (!_preStepHooks.contains(hook)) _preStepHooks.add(hook);
  }

  void removePreStepHook(void Function(double dt) hook) => _preStepHooks.remove(hook);

  /// Ensures every attached body, mesh collider, and character has been created in C++.
  void ensureAllCreated() {
    for (final b in List<NativeRigidBody>.of(_trackedBodies)) {
      b.ensureCreated();
    }
    for (final m in List<NativeMeshCollider>.of(_trackedMeshes)) {
      m.ensureCreated();
    }
    for (final c in List<NativeCharacterController>.of(_trackedCharacters)) {
      c.ensureCreated();
    }
  }

  /// Runs one physics step of [dt] seconds, moves dynamic objects to where
  /// the physics put them, and calls the collision and trigger callbacks.
  void step(double dt) {
    ensureAllCreated();
    for (final hook in List<void Function(double)>.of(_preStepHooks)) {
      hook(dt);
    }
    for (final c in List<NativeCharacterController>.of(characters)) {
      c.physicsStep(dt);
    }
    for (final b in bodies.values) {
      b._beforeStep(dt);
    }
    world.update(dt);
    _readBack();
    _dispatch(world.takeEvents());
  }

  void _readBack() {
    final dynamicBodies = [
      for (final b in bodies.values)
        if (b.isDynamic && b.enabled) b,
    ];
    if (dynamicBodies.isEmpty) return;
    final p = world.readTransforms([for (final b in dynamicBodies) b.bodyId]);
    for (var i = 0; i < dynamicBodies.length; i++) {
      final t = dynamicBodies[i].transform;
      final o = i * 7;
      t.worldPosition = Vector3(p[o], p[o + 1], p[o + 2]);
      t.worldRotation = Quaternion(p[o + 3], p[o + 4], p[o + 5], p[o + 6]);
    }
  }

  void _dispatch(List<NativeContactEvent> events) {
    for (final e in events) {
      final a = bodies[e.bodyA], b = bodies[e.bodyB];
      if (a == null || b == null) continue;
      _notify(a.gameObject, b.gameObject, e);
      _notify(b.gameObject, a.gameObject, e);
    }
  }

  void _notify(GameObject on, GameObject other, NativeContactEvent e) {
    if (on.isDestroyed) return;
    final comps = on.components;
    for (var i = 0; i < comps.length; i++) {
      final c = comps[i];
      if (!c.isAttached || !c.enabled || on.isDestroyed) continue;
      if (e.isTrigger) {
        e.isEnd ? c.onTriggerExit(other) : c.onTriggerEnter(other);
      } else {
        e.isEnd ? c.onCollisionExit(other) : c.onCollisionEnter(other);
      }
    }
  }

  void dispose({bool ownsWorld = false}) {
    bodies.clear();
    characters.clear();
    _trackedBodies.clear();
    _trackedMeshes.clear();
    _trackedCharacters.clear();
    _preStepHooks.clear();
    if (ownsWorld) world.dispose();
  }
}

/// Shapes of a [NativeRigidBody]. A capsule is a round ended cylinder (people,
/// barrels, pills) standing along the object's Y axis. A compound is several
/// shapes in one body. A convexHull is any convex polyhedron defined by vertices.
enum NativeShape { sphere, box, capsule, compound, convexHull }

/// A physics body on a [GameObject].
///
/// * `mass: 0` is a static body (ground, walls).
/// * `isKinematic`: you move the object, the body follows and pushes others.
/// * `isTrigger`: no push, only `onTriggerEnter` / `onTriggerExit`.
/// * `ccd`: swept continuous collision detection for fast projectiles/bullets.
///
/// Use it on top level objects (no parent).
class NativeRigidBody extends Component {
  NativeRigidBody(
    this.physics, {
    this.shape = NativeShape.box,
    Vector3? halfExtents,
    this.mass = 1,
    this.isKinematic = false,
    this.isTrigger = false,
    this.friction = 0.5,
    this.restitution = 0,
    this.linearDamping = 0.01,
    this.angularDamping = 0.05,
    this.layer = 0,
    this.mask = 0xFFFFFFFF,
    this.gravityScale = 1,
    this.parts = const [],
    this.hullVertices,
    bool ccd = false,
  }) : halfExtents = halfExtents?.clone() ?? Vector3(0.5, 0.5, 0.5),
       _ccd = ccd {
    physics.registerBody(this);
  }

  NativeRigidBody.sphere(
    NativePhysics physics, {
    double radius = 0.5,
    double mass = 1,
    bool isKinematic = false,
    bool isTrigger = false,
    double friction = 0.5,
    double restitution = 0,
    int layer = 0,
    int mask = 0xFFFFFFFF,
    bool ccd = false,
  }) : this(
         physics,
         shape: NativeShape.sphere,
         halfExtents: Vector3(radius, radius, radius),
         mass: mass,
         isKinematic: isKinematic,
         isTrigger: isTrigger,
         friction: friction,
         restitution: restitution,
         layer: layer,
         mask: mask,
         ccd: ccd,
       );

  /// A capsule standing along the Y axis: [radius] of the round body and the
  /// whole [height] (at least twice the radius). Lay it down by turning the object.
  NativeRigidBody.capsule(
    NativePhysics physics, {
    double radius = 0.3,
    double height = 1.8,
    double mass = 1,
    bool isKinematic = false,
    bool isTrigger = false,
    double friction = 0.5,
    double restitution = 0,
    double linearDamping = 0.01,
    double angularDamping = 0.05,
    int layer = 0,
    int mask = 0xFFFFFFFF,
    bool ccd = false,
  }) : this(
         physics,
         shape: NativeShape.capsule,
         halfExtents: Vector3(radius, (height / 2 - radius).clamp(0.0, double.infinity), 0),
         mass: mass,
         isKinematic: isKinematic,
         isTrigger: isTrigger,
         friction: friction,
         restitution: restitution,
         linearDamping: linearDamping,
         angularDamping: angularDamping,
         layer: layer,
         mask: mask,
         ccd: ccd,
       );

  /// Several shapes in one body. The object's position is the center of mass.
  NativeRigidBody.compound(
    NativePhysics physics, {
    required List<NativeChildShape> parts,
    double mass = 1,
    bool isKinematic = false,
    bool isTrigger = false,
    double friction = 0.5,
    double restitution = 0,
    double linearDamping = 0.01,
    double angularDamping = 0.05,
    int layer = 0,
    int mask = 0xFFFFFFFF,
    bool ccd = false,
  }) : this(
         physics,
         shape: NativeShape.compound,
         parts: parts,
         mass: mass,
         isKinematic: isKinematic,
         isTrigger: isTrigger,
         friction: friction,
         restitution: restitution,
         linearDamping: linearDamping,
         angularDamping: angularDamping,
         layer: layer,
         mask: mask,
         ccd: ccd,
       );

  /// A convex polyhedron defined by local-space [vertices] (x, y, z per vertex, at least 4 vertices).
  NativeRigidBody.convexHull(
    NativePhysics physics, {
    required Float32List vertices,
    double mass = 1,
    bool isKinematic = false,
    bool isTrigger = false,
    double friction = 0.5,
    double restitution = 0,
    double linearDamping = 0.01,
    double angularDamping = 0.05,
    int layer = 0,
    int mask = 0xFFFFFFFF,
    bool ccd = false,
  }) : this(
         physics,
         shape: NativeShape.convexHull,
         hullVertices: vertices,
         halfExtents: _computeHullHalfExtents(vertices),
         mass: mass,
         isKinematic: isKinematic,
         isTrigger: isTrigger,
         friction: friction,
         restitution: restitution,
         linearDamping: linearDamping,
         angularDamping: angularDamping,
         layer: layer,
         mask: mask,
         ccd: ccd,
       );

  static Vector3 _computeHullHalfExtents(Float32List verts) {
    if (verts.length < 3) return Vector3(0.5, 0.5, 0.5);
    var mx = 0.0, my = 0.0, mz = 0.0;
    for (var i = 0; i < verts.length; i += 3) {
      final ax = verts[i].abs(), ay = verts[i + 1].abs(), az = verts[i + 2].abs();
      if (ax > mx) mx = ax;
      if (ay > my) my = ay;
      if (az > mz) mz = az;
    }
    return Vector3(mx > 0 ? mx : 0.5, my > 0 ? my : 0.5, mz > 0 ? mz : 0.5);
  }

  final NativePhysics physics;
  final NativeShape shape;

  /// The parts of a compound body.
  final List<NativeChildShape> parts;

  /// Local-space vertices (x, y, z per vertex) for [NativeShape.convexHull].
  final Float32List? hullVertices;

  final Vector3 halfExtents;
  final double mass;
  final bool isKinematic;
  final bool isTrigger;
  final double friction, restitution, linearDamping, angularDamping, gravityScale;
  final int layer, mask;

  bool _ccd;
  int bodyId = -1;
  Vector3? _lastKinematic;

  bool get isDynamic => mass > 0 && !isKinematic;

  /// Enables or disables swept Continuous Collision Detection (CCD) on this body.
  bool get ccd => _ccd;
  set ccd(bool value) {
    _ccd = value;
    if (bodyId >= 0) physics.world.setBodyCcd(bodyId, value);
  }

  /// Ensures the native body is created in C++ (safe to call before `scene.update()`).
  void ensureCreated() {
    if (bodyId >= 0 || !isAttached) return;
    final p = transform.worldPosition;
    bodyId = physics.world.createBody(NativeBodyDesc(
      shape: const {
        NativeShape.sphere: 0,
        NativeShape.box: 1,
        NativeShape.capsule: 3,
        NativeShape.compound: 4,
        NativeShape.convexHull: 5,
      }[shape]!,
      half: halfExtents,
      mass: mass,
      kinematic: isKinematic,
      sensor: isTrigger,
      position: p,
      rotation: transform.worldRotation,
      friction: friction,
      restitution: restitution,
      linearDamping: linearDamping,
      angularDamping: angularDamping,
      layer: layer,
      mask: mask,
      gravityScale: gravityScale,
    ));
    if (shape == NativeShape.compound && !physics.world.setBodyChildren(bodyId, parts)) {
      physics.world.destroyBody(bodyId);
      bodyId = -1;
      throw StateError('The compound body has a part that is not allowed (use sphere, box or capsule).');
    }
    if (shape == NativeShape.convexHull) {
      if (hullVertices == null || !physics.world.setBodyConvexHull(bodyId, hullVertices!)) {
        physics.world.destroyBody(bodyId);
        bodyId = -1;
        throw StateError('ConvexHull body requires at least 4 valid vertices (12 floats).');
      }
    }
    if (_ccd) physics.world.setBodyCcd(bodyId, true);
    physics.bodies[bodyId] = this;
    _lastKinematic = p;
  }

  @override
  void awake() => ensureCreated();

  void _beforeStep(double dt) {
    if (!isKinematic || !enabled || dt <= 0) return;
    final target = transform.worldPosition;
    final prev = _lastKinematic ?? target;
    final w = physics.world;
    w.setBodyTransform(bodyId, prev, transform.worldRotation);
    w.setBodyVelocity(bodyId, (target - prev)..scale(1.0 / dt));
    _lastKinematic = target;
  }

  /// Moves object and body at once (no pushing on the way).
  void teleport(Vector3 position, [Quaternion? rotation]) {
    ensureCreated();
    transform.worldPosition = position;
    if (rotation != null) transform.worldRotation = rotation;
    physics.world.setBodyTransform(bodyId, position, transform.worldRotation);
    _lastKinematic = position.clone();
  }

  Vector3 get velocity {
    ensureCreated();
    final v = physics.world.getBodyVelocity(bodyId);
    return Vector3(v[0], v[1], v[2]);
  }

  set velocity(Vector3 v) {
    ensureCreated();
    physics.world.setBodyVelocity(bodyId, v, angularVelocity);
  }

  /// Turning speed in radians per second around each axis.
  Vector3 get angularVelocity {
    ensureCreated();
    final v = physics.world.getBodyVelocity(bodyId);
    return Vector3(v[3], v[4], v[5]);
  }

  set angularVelocity(Vector3 w) {
    ensureCreated();
    physics.world.setBodyVelocity(bodyId, velocity, w);
  }

  /// Force for the next step (call it in `onFixedUpdate`).
  void addForce(Vector3 f) {
    ensureCreated();
    physics.world.applyForce(bodyId, f);
  }

  /// Instant push. [at] is a world point, the center if null.
  void addImpulse(Vector3 impulse, {Vector3? at}) {
    ensureCreated();
    physics.world.applyImpulse(bodyId, impulse, at ?? transform.worldPosition);
  }

  bool get isSleeping {
    ensureCreated();
    return physics.world.isSleeping(bodyId);
  }

  @override
  void onDestroy() {
    physics.unregisterBody(this);
    if (bodyId >= 0) {
      physics.world.destroyBody(bodyId);
      physics.bodies.remove(bodyId);
      bodyId = -1;
    }
  }
}

/// A static collider with the exact shape of a [Mesh] (tracks, terrain,
/// buildings). It is built once at the object's position, rotation and scale
/// when the object starts (or before the first `physics.step`).
class NativeMeshCollider extends Component {
  NativeMeshCollider(
    this.physics,
    this.mesh, {
    this.friction = 0.8,
    this.restitution = 0,
    this.layer = 0,
    this.mask = 0xFFFFFFFF,
  }) {
    physics.registerMeshCollider(this);
  }

  final NativePhysics physics;
  final Mesh mesh;
  final double friction, restitution;
  final int layer, mask;
  int bodyId = -1;

  /// Ensures the static triangle mesh collider exists in C++ even before `scene.update()`.
  void ensureCreated() {
    if (bodyId >= 0 || !isAttached) return;
    final m = transform.worldMatrix;
    final src = mesh.arrays.positions;
    final baked = Float32List(src.length);
    final v = Vector3.zero();
    for (var i = 0; i < src.length; i += 3) {
      v.setValues(src[i], src[i + 1], src[i + 2]);
      m.transform3(v);
      baked[i] = v.x;
      baked[i + 1] = v.y;
      baked[i + 2] = v.z;
    }
    final id = physics.world.createTriMesh(baked, mesh.arrays.indices);
    bodyId = physics.world.createBody(NativeBodyDesc(
      shape: 2,
      mass: 0,
      trimesh: id,
      friction: friction,
      restitution: restitution,
      layer: layer,
      mask: mask,
    ));
  }

  @override
  void awake() => ensureCreated();

  @override
  void onDestroy() {
    physics.unregisterMeshCollider(this);
    if (bodyId >= 0) {
      physics.world.destroyBody(bodyId);
      bodyId = -1;
    }
  }
}

/// Draws the shapes of the physics bodies and characters, to see what the
/// physics sees. Call it every frame from `update`:
/// `scene.debug.physicsShapes(physics);`
extension NativeDebugDraw on DebugDraw {
  void physicsShapes(NativePhysics physics) {
    for (final b in physics.bodies.values) {
      if (!b.enabled) continue;
      final t = b.transform;
      final color = b.isTrigger
          ? DebugColors.cyan
          : (!b.isDynamic ? DebugColors.green : (b.isSleeping ? Vector4(0.6, 0.6, 0.6, 1) : DebugColors.yellow));
      switch (b.shape) {
        case NativeShape.sphere:
          sphere(t.worldPosition, b.halfExtents.x, color: color, segments: 16);
        case NativeShape.box:
        case NativeShape.convexHull:
          box(t.worldPosition, b.halfExtents, rotation: t.worldRotation, color: color);
        case NativeShape.capsule:
          final up = t.worldRotation.rotateVector(Vector3(0, b.halfExtents.y, 0));
          capsule(t.worldPosition - up, t.worldPosition + up, b.halfExtents.x, color: color);
        case NativeShape.compound:
          for (final part in b.parts) {
            final p = t.worldPosition + t.worldRotation.rotateVector(part.position);
            final r = t.worldRotation * part.rotation;
            if (part.type == 0) {
              sphere(p, part.half.x, color: color, segments: 16);
            } else if (part.type == 1) {
              box(p, part.half, rotation: r, color: color);
            } else {
              final a = r.rotateVector(Vector3(0, part.half.y, 0));
              capsule(p - a, p + a, part.half.x, color: color);
            }
          }
      }
    }
    for (final c in physics.characters) {
      final feet = c.transform.worldPosition;
      capsule(feet + Vector3(0, c.radius, 0), feet + Vector3(0, c.height - c.radius, 0), c.radius,
          color: c.isGrounded ? DebugColors.green : DebugColors.orange);
    }
  }
}
