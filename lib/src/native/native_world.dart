import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import '../math/vec.dart';

import '../engine/post_effects.dart';
import 'bindings.dart';
import 'native_lib.dart';

/// One piece of a loaded model (`.glb`).
/// One animation (for example `Walk`) found in a model file.
class NativeModelClip {
  NativeModelClip({required this.name, required this.clipId, required this.skeleton, required this.duration});

  final String name;

  /// Native clip id (play it on an animator of [skeleton]).
  final int clipId;
  final int skeleton;

  /// Length in seconds.
  final double duration;
}

/// What a model file holds: its pieces and its animations.
class NativeModel {
  NativeModel(this.parts, this.clips);
  final List<NativeModelPart> parts;
  final List<NativeModelClip> clips;
}

class NativeModelPart {
  NativeModelPart({
    this.skeleton = -1,
    this.joints,
    this.weights,
    required this.name,
    required this.transform,
    required this.vertices,
    required this.indices,
    required this.color,
    required this.textureId,
  });

  /// Native skeleton id if this piece is bone animated, else -1.
  final int skeleton;

  /// Bone data per vertex (4 numbers and 4 weights) for animated pieces.
  final Uint8List? joints;
  final Float32List? weights;

  /// Node name from the file, for example `Pillar.1`.
  final String name;

  /// Node transform in model space.
  final Matrix4 transform;

  /// 8 floats per vertex: position(3), normal(3), uv(2).
  final Float32List vertices;
  final Uint32List indices;

  /// Base color (rgba 0..1).
  final Vector4 color;

  /// Native texture id, or -1.
  final int textureId;
}

class NativeRayHit {
  NativeRayHit(this.body, this.distance, this.point, this.normal);
  final int body;
  final double distance;
  final Vector3 point;
  final Vector3 normal;
}

/// A begin or end of a touch between two bodies.
class NativeContactEvent {
  NativeContactEvent(this.bodyA, this.bodyB, this.isEnd, this.isTrigger);
  final int bodyA;
  final int bodyB;
  final bool isEnd;
  final bool isTrigger;
}

/// Settings for a physics body. Shapes: 0 sphere (radius = half.x), 1 box,
/// 2 static triangle mesh (set [trimesh]).
/// One part of a compound body (see [NativeRigidBody.compound]).
class NativeChildShape {
  NativeChildShape.sphere(double radius, {Vector3? position, Quaternion? rotation})
      : type = 0,
        half = Vector3(radius, radius, radius),
        position = position ?? Vector3.zero(),
        rotation = rotation ?? Quaternion.identity();

  NativeChildShape.box(Vector3 halfExtents, {Vector3? position, Quaternion? rotation})
      : type = 1,
        half = halfExtents.clone(),
        position = position ?? Vector3.zero(),
        rotation = rotation ?? Quaternion.identity();

  /// A capsule along the part's own Y axis: [radius] of the round body and
  /// [height] of the whole capsule (at least twice the radius).
  NativeChildShape.capsule(double radius, double height, {Vector3? position, Quaternion? rotation})
      : type = 3,
        half = Vector3(radius, (height / 2 - radius).clamp(0.0, double.infinity), 0),
        position = position ?? Vector3.zero(),
        rotation = rotation ?? Quaternion.identity();

  /// 0 sphere, 1 box, 3 capsule.
  final int type;
  final Vector3 half;
  final Vector3 position;
  final Quaternion rotation;
}

class NativeBodyDesc {
  NativeBodyDesc({
    this.shape = 1,
    Vector3? half,
    this.mass = 1,
    this.kinematic = false,
    this.sensor = false,
    Vector3? position,
    Quaternion? rotation,
    this.friction = 0.5,
    this.restitution = 0,
    this.linearDamping = 0.01,
    this.angularDamping = 0.05,
    this.layer = 0,
    this.mask = 0xFFFFFFFF,
    this.gravityScale = 1,
    this.trimesh = -1,
  }) : half = half ?? Vector3(0.5, 0.5, 0.5),
       position = position ?? Vector3.zero(),
       rotation = rotation ?? Quaternion.identity();

  int shape;
  Vector3 half;
  double mass;
  bool kinematic;
  bool sensor;
  Vector3 position;
  Quaternion rotation;
  double friction, restitution, linearDamping, angularDamping, gravityScale;
  int layer, mask, trimesh;
}

/// Where a character capsule is after a move (feet position and contacts).
class NativeCharacterState {
  NativeCharacterState({
    required this.position,
    required this.grounded,
    required this.hitCeiling,
    required this.hitWall,
    required this.groundBody,
    required this.groundNormal,
  });
  final Vector3 position;
  final bool grounded, hitCeiling, hitWall;

  /// Body id of what it stands on, or -1.
  final int groundBody;
  final Vector3 groundNormal;
}

/// Typed wrapper around the C++ core: physics, models, textures and the CPU
/// renderer. Needs the native library (see `TejNative`). Not for the web.
///
/// Status: tested against the real native library (`test/native_bridge_test.dart`).
class NativeWorld {
  NativeWorld() : handle = TejNative.api.worldCreate();

  final Pointer<Void> handle;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  TejBindings get _a => TejNative.api;

  NativeBytes? _frame;

  void _checkAlive() {
    if (_disposed) throw StateError('NativeWorld has been disposed.');
  }

  /// Runs `body` with a native float array that holds [values].
  R _floats<R>(List<double> values, R Function(Pointer<Float> p) body) {
    _checkAlive();
    final b = NativeFloats(values.length);
    try {
      b.list.setAll(0, values);
      return body(b.ptr);
    } finally {
      b.dispose();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _frame?.dispose();
    _frame = null;
    _a.worldDestroy(handle);
  }

  // ------------------------------------------------------------ physics

  /// Steps physics, animation and body-to-instance sync by [dt] seconds.
  void update(double dt) {
    _checkAlive();
    _a.worldUpdate(handle, dt);
  }

  set gravity(Vector3 g) {
    _checkAlive();
    _a.physicsSetGravity(handle, g.x, g.y, g.z);
  }

  /// Sets the parts of a compound body (shape 4). Each part is a sphere
  /// (half.x radius), box, or capsule (half.x radius, half.y half length) at
  /// a position and turn relative to the body. Returns false if refused.
  bool setBodyChildren(int body, List<NativeChildShape> parts) {
    _checkAlive();
    final f = NativeFloats(parts.length * 11);
    try {
      final l = f.list;
      for (var i = 0; i < parts.length; i++) {
        final c = parts[i];
        final o = i * 11;
        l[o] = c.type.toDouble();
        l[o + 1] = c.half.x;
        l[o + 2] = c.half.y;
        l[o + 3] = c.half.z;
        l[o + 4] = c.position.x;
        l[o + 5] = c.position.y;
        l[o + 6] = c.position.z;
        l[o + 7] = c.rotation.x;
        l[o + 8] = c.rotation.y;
        l[o + 9] = c.rotation.z;
        l[o + 10] = c.rotation.w;
      }
      return _a.bodySetChildren(handle, body, f.ptr, parts.length) == 1;
    } finally {
      f.dispose();
    }
  }

  /// Sets the local-space vertices (x, y, z per vertex) of a convex hull body (shape 5).
  bool setBodyConvexHull(int body, Float32List vertices) {
    _checkAlive();
    if (vertices.length < 12 || vertices.length % 3 != 0) return false;
    final f = NativeFloats(vertices.length);
    try {
      f.list.setAll(0, vertices);
      return _a.bodySetConvexHull(handle, body, f.ptr, vertices.length ~/ 3) == 1;
    } finally {
      f.dispose();
    }
  }

  int createBody(NativeBodyDesc d) {
    _checkAlive();
    final p = _a.alloc(sizeOf<TejBodyDesc>()).cast<TejBodyDesc>();
    try {
      p.ref
        ..shape = d.shape
        ..hx = d.half.x
        ..hy = d.half.y
        ..hz = d.half.z
        ..mass = d.mass
        ..kinematic = d.kinematic ? 1 : 0
        ..sensor = d.sensor ? 1 : 0
        ..px = d.position.x
        ..py = d.position.y
        ..pz = d.position.z
        ..qx = d.rotation.x
        ..qy = d.rotation.y
        ..qz = d.rotation.z
        ..qw = d.rotation.w
        ..friction = d.friction
        ..restitution = d.restitution
        ..linearDamping = d.linearDamping
        ..angularDamping = d.angularDamping
        ..layer = d.layer
        ..mask = d.mask
        ..gravityScale = d.gravityScale
        ..trimesh = d.trimesh;
      return _a.bodyCreate(handle, p);
    } finally {
      _a.free(p.cast());
    }
  }

  void destroyBody(int id) {
    _checkAlive();
    _a.bodyDestroy(handle, id);
  }

  /// Static triangle collider from [positions] (x, y, z per vertex).
  /// Returns an id for [NativeBodyDesc.trimesh]. Throws if the data is bad.
  int createTriMesh(Float32List positions, List<int> indices) {
    _checkAlive();
    final v = NativeFloats(positions.length);
    NativeUint32s? i;
    try {
      v.list.setAll(0, positions);
      i = NativeUint32s(indices.length);
      i.list.setAll(0, indices);
      final id = _a.trimeshCreate(handle, v.ptr, positions.length ~/ 3, i.ptr, indices.length);
      if (id < 0) throw ArgumentError('Bad triangle mesh (empty, or an index is out of range).');
      return id;
    } finally {
      i?.dispose();
      v.dispose();
    }
  }

  void setBodyTransform(int id, Vector3 p, Quaternion q) {
    _checkAlive();
    final pos = NativeFloats(3);
    NativeFloats? rot;
    try {
      pos.list.setAll(0, [p.x, p.y, p.z]);
      rot = NativeFloats(4);
      rot.list.setAll(0, [q.x, q.y, q.z, q.w]);
      _a.bodySetTransform(handle, id, pos.ptr, rot.ptr);
    } finally {
      rot?.dispose();
      pos.dispose();
    }
  }

  /// Reads the pose of many bodies. Returns 7 numbers per id: x y z, then the
  /// quaternion x y z w.
  Float32List readTransforms(List<int> ids) {
    _checkAlive();
    if (ids.isEmpty) return Float32List(0);
    final idBuf = NativeInt32s(ids.length);
    NativeFloats? out;
    try {
      idBuf.list.setAll(0, ids);
      out = NativeFloats(ids.length * 7);
      _a.bodyBatchGetTransform(handle, idBuf.ptr, ids.length, out.ptr);
      return Float32List.fromList(out.list);
    } finally {
      out?.dispose();
      idBuf.dispose();
    }
  }

  void setBodyVelocity(int id, Vector3 linear, [Vector3? angular]) {
    _checkAlive();
    final a = angular ?? Vector3.zero();
    final l = NativeFloats(3);
    NativeFloats? r;
    try {
      l.list.setAll(0, [linear.x, linear.y, linear.z]);
      r = NativeFloats(3);
      r.list.setAll(0, [a.x, a.y, a.z]);
      _a.bodySetVelocity(handle, id, l.ptr, r.ptr);
    } finally {
      r?.dispose();
      l.dispose();
    }
  }

  /// Returns [linear x, y, z, angular x, y, z].
  List<double> getBodyVelocity(int id) {
    _checkAlive();
    final b = NativeFloats(6);
    try {
      _a.bodyGetVelocity(handle, id, b.ptr);
      return List<double>.of(b.list);
    } finally {
      b.dispose();
    }
  }

  void applyForce(int id, Vector3 f) {
    _checkAlive();
    _a.bodyApplyForce(handle, id, f.x, f.y, f.z);
  }

  void applyImpulse(int id, Vector3 impulse, Vector3 worldPoint) {
    _checkAlive();
    _a.bodyApplyImpulse(
      handle,
      id,
      impulse.x,
      impulse.y,
      impulse.z,
      worldPoint.x,
      worldPoint.y,
      worldPoint.z,
    );
  }

  bool isSleeping(int id) {
    _checkAlive();
    return _a.bodyIsSleeping(handle, id) != 0;
  }

  /// Enables or disables swept continuous collision detection (CCD) on a body.
  void setBodyCcd(int id, bool enabled) {
    _checkAlive();
    _a.bodySetCcd(handle, id, enabled ? 1 : 0);
  }

  /// Sets metallic/roughness/AO PBR material parameters on a mesh instance.
  void setInstancePbr(int id, {required double metallic, required double roughness, double ao = 1.0}) {
    _checkAlive();
    _a.instanceSetPbr(handle, id, metallic, roughness, ao);
  }

  /// Enables or disables FXAA edge anti-aliasing on the software renderer.
  void setAntiAliasing(bool enabled) {
    _checkAlive();
    _a.envSetAa(handle, enabled ? 1 : 0);
  }

  /// Assigns tangent-space normal map and packed AO/Roughness/Metallic map to an instance.
  void setInstancePbrMaps(int id, {int normalTex = -1, int mrTex = -1}) {
    _checkAlive();
    _a.instanceSetPbrMaps(handle, id, normalTex, mrTex);
  }

  /// Sets dual-lobe clearcoat car paint parameters on an instance.
  void setInstanceClearcoat(int id, {required double clearcoat, double roughness = 0.06}) {
    _checkAlive();
    _a.instanceSetClearcoat(handle, id, clearcoat, roughness);
  }

  /// Sets surface opacity (< 1.0 enables depth-sorted physical Fresnel glass blending).
  void setInstanceAlpha(int id, double alpha) {
    _checkAlive();
    _a.instanceSetAlpha(handle, id, alpha);
  }

  /// Enables depth-buffer Screen-Space Ambient Occlusion (SSAO) contact shadows.
  void setSsao(bool enabled, {double strength = 0.55, int radius = 4}) {
    _checkAlive();
    _a.envSetSsao(handle, enabled ? 1 : 0, strength, radius);
  }

  /// Uploads a 6-face RGBA environment cubemap (+X,-X,+Y,-Y,+Z,-Z) for 360-degree IBL reflections.
  bool setCubemap(int faceSize, Uint8List rgba6Faces) {
    _checkAlive();
    final buf = NativeBytes(rgba6Faces.length);
    try {
      buf.list.setAll(0, rgba6Faces);
      return _a.envSetCubemap(handle, faceSize, buf.ptr) != 0;
    } finally {
      buf.dispose();
    }
  }

  /// Initializes the zero-dependency OpenGL 3.3 / GLES 3.0 hardware GPU bridge if a GL context is active.
  bool gpuInit() {
    _checkAlive();
    return _a.gpuInit(handle) != 0;
  }

  bool get gpuAvailable {
    _checkAlive();
    return _a.gpuIsAvailable(handle) != 0;
  }

  void gpuShutdown() {
    _checkAlive();
    _a.gpuShutdown(handle);
  }

  /// Renders using the Hardware OpenGL/GLES GPU backend when active, falling back
  /// seamlessly to the C++17 software PBR renderer if no GPU context is available.
  Uint8List gpuRenderRgba(
    int width,
    int height, {
    required Matrix4 view,
    required Matrix4 projection,
    required Vector3 eye,
  }) {
    _checkAlive();
    if (width <= 0 || height <= 0) return Uint8List(0);
    final v = NativeFloats(16);
    NativeFloats? pr;
    NativeFloats? ee;
    try {
      v.list.setAll(0, view.storage);
      pr = NativeFloats(16);
      pr.list.setAll(0, projection.storage);
      ee = NativeFloats(3);
      ee.list.setAll(0, [eye.x, eye.y, eye.z]);
      _a.cameraSetMatrices(handle, v.ptr, pr.ptr, ee.ptr);
    } finally {
      ee?.dispose();
      pr?.dispose();
      v.dispose();
    }
    final bytes = width * height * 4;
    if (_frame == null || _frame!.length < bytes) {
      _frame?.dispose();
      _frame = NativeBytes(bytes);
    }
    _a.gpuRender(handle, width, height, _frame!.ptr);
    return Uint8List.fromList(_frame!.list.sublist(0, bytes));
  }

  /// Encodes RGBA pixels to lossless PNG using the engine's zero-dependency C++ encoder.
  Uint8List encodePng(int width, int height, Uint8List rgba) {
    _checkAlive();
    final buf = NativeBytes(rgba.length);
    try {
      buf.list.setAll(0, rgba);
      final n = _a.encodePng(handle, width, height, buf.ptr);
      if (n <= 0) return Uint8List(0);
      final out = NativeBytes(n);
      try {
        _a.mediaCopy(handle, out.ptr, n);
        return Uint8List.fromList(out.list);
      } finally {
        out.dispose();
      }
    } finally {
      buf.dispose();
    }
  }

  /// Encodes RGBA pixels to baseline JPEG using the engine's zero-dependency C++ encoder.
  Uint8List encodeJpeg(int width, int height, Uint8List rgba, {int quality = 85}) {
    _checkAlive();
    final buf = NativeBytes(rgba.length);
    try {
      buf.list.setAll(0, rgba);
      final n = _a.encodeJpeg(handle, width, height, buf.ptr, quality);
      if (n <= 0) return Uint8List(0);
      final out = NativeBytes(n);
      try {
        _a.mediaCopy(handle, out.ptr, n);
        return Uint8List.fromList(out.list);
      } finally {
        out.dispose();
      }
    } finally {
      buf.dispose();
    }
  }

  /// Starts in-engine zero-dependency MJPEG-AVI video recording (no ffmpeg).
  bool videoBegin(int width, int height, {int fps = 30, int quality = 82}) {
    _checkAlive();
    return _a.videoBegin(handle, width, height, fps, quality) != 0;
  }

  /// Appends one RGBA frame to the active MJPEG-AVI recording.
  bool videoAddFrame(Uint8List rgba) {
    _checkAlive();
    final buf = NativeBytes(rgba.length);
    try {
      buf.list.setAll(0, rgba);
      return _a.videoAddFrame(handle, buf.ptr) != 0;
    } finally {
      buf.dispose();
    }
  }

  /// Finalizes the MJPEG-AVI container and returns the complete .avi bytes.
  Uint8List videoFinish() {
    _checkAlive();
    final n = _a.videoFinish(handle);
    if (n <= 0) return Uint8List(0);
    final out = NativeBytes(n);
    try {
      _a.mediaCopy(handle, out.ptr, n);
      return Uint8List.fromList(out.list);
    } finally {
      out.dispose();
    }
  }

  NativeRayHit? raycast(Vector3 origin, Vector3 direction, {double maxDistance = 1000, int mask = 0xFFFFFFFF, int ignoreBody = -1}) {
    _checkAlive();
    final out = NativeFloats(8);
    try {
      final hit = _a.raycast(handle, origin.x, origin.y, origin.z, direction.x, direction.y, direction.z, maxDistance, mask, ignoreBody, out.ptr);
      final l = out.list;
      return hit == 0 ? null : NativeRayHit(l[0].toInt(), l[1], Vector3(l[2], l[3], l[4]), Vector3(l[5], l[6], l[7]));
    } finally {
      out.dispose();
    }
  }

  /// Touches that began or ended in the last [update].
  List<NativeContactEvent> takeEvents() {
    _checkAlive();
    final n = _a.eventsCount(handle);
    if (n == 0) return const [];
    final b = NativeInt32s(n * 4);
    try {
      _a.eventsCopy(handle, b.ptr);
      final l = b.list;
      return [
        for (var i = 0; i < n; i++)
          NativeContactEvent(l[i * 4], l[i * 4 + 1], l[i * 4 + 2] == 1, l[i * 4 + 3] == 1),
      ];
    } finally {
      b.dispose();
    }
  }

  // ------------------------------------------------------------ character controller

  /// Makes a character capsule (see [NativeCharacterController]). [position]
  /// is the feet. Returns its id.
  int createCharacter({
    double radius = 0.4,
    double height = 1.8,
    double stepHeight = 0.35,
    double slopeLimitDegrees = 50,
    int mask = 0xFFFFFFFF,
    int ignoreBody = -1,
    required Vector3 position,
  }) {
    _checkAlive();
    return _a.characterCreate(handle, radius, height, stepHeight, slopeLimitDegrees, mask, ignoreBody, position.x, position.y, position.z);
  }

  void destroyCharacter(int id) {
    _checkAlive();
    _a.characterDestroy(handle, id);
  }

  /// Moves the capsule by [delta] (world meters) and slides it along what it
  /// touches. Read the result with [characterState].
  void moveCharacter(int id, Vector3 delta, {bool snapToGround = true}) {
    _checkAlive();
    _a.characterMove(handle, id, delta.x, delta.y, delta.z, snapToGround ? 1 : 0);
  }

  void teleportCharacter(int id, Vector3 feet) {
    _checkAlive();
    _a.characterTeleport(handle, id, feet.x, feet.y, feet.z);
  }

  NativeCharacterState characterState(int id) {
    _checkAlive();
    final b = NativeFloats(10);
    try {
      _a.characterState(handle, id, b.ptr);
      final l = b.list;
      return NativeCharacterState(
        position: Vector3(l[0], l[1], l[2]),
        grounded: l[3] != 0,
        hitCeiling: l[4] != 0,
        hitWall: l[5] != 0,
        groundBody: l[6].toInt(),
        groundNormal: Vector3(l[7], l[8], l[9]),
      );
    } finally {
      b.dispose();
    }
  }

  /// Toggles character crouch state (checks ceiling clearance when standing up).
  bool setCharacterCrouch(int id, bool crouch, {double crouchHeight = 1.0}) {
    _checkAlive();
    return _a.characterSetCrouch(handle, id, crouch ? 1 : 0, crouchHeight) == 1;
  }

  /// Returns true if the character is currently crouched.
  bool isCharacterCrouched(int id) {
    _checkAlive();
    return _a.characterIsCrouched(handle, id) != 0;
  }

  /// Sets horizontal impulse strength applied to dynamic bodies the character pushes.
  void setCharacterPushForce(int id, double pushForce) {
    _checkAlive();
    _a.characterSetPushForce(handle, id, pushForce);
  }

  /// Enables or disables ladder/vertical climbing mode on a character.
  void setCharacterClimbing(int id, bool climbing) {
    _checkAlive();
    _a.characterSetClimbing(handle, id, climbing ? 1 : 0);
  }

  // ------------------------------------------------------------ skeletons and animators

  /// Number of bones of a skeleton.
  int skeletonJointCount(int skeleton) {
    _checkAlive();
    return _a.skeletonJointCount(handle, skeleton);
  }

  /// Bone name from the model file, or an empty string.
  String skeletonJointName(int skeleton, int joint) {
    _checkAlive();
    final b = NativeBytes(128);
    try {
      _a.skeletonJointName(handle, skeleton, joint, b.ptr.cast<Int8>(), 128);
      return _cString(b.list);
    } finally {
      b.dispose();
    }
  }

  /// Makes an animator (the thing that plays clips) for a skeleton.
  int createAnimator(int skeleton) {
    _checkAlive();
    final id = _a.animatorCreate(handle, skeleton);
    if (id < 0) throw ArgumentError('Bad skeleton $skeleton.');
    return id;
  }

  void destroyAnimator(int animator) {
    _checkAlive();
    _a.animatorDestroy(handle, animator);
  }

  void playAnimator(int animator, int clip, {bool loop = true, double speed = 1}) {
    _checkAlive();
    _a.animatorPlay(handle, animator, clip, loop ? 1 : 0, speed);
  }

  void crossfadeAnimator(int animator, int clip, double seconds, {bool loop = true, double speed = 1}) {
    _checkAlive();
    _a.animatorCrossfade(handle, animator, clip, seconds, loop ? 1 : 0, speed);
  }

  /// 0..1 through the current clip.
  double animatorNormalizedTime(int animator) {
    _checkAlive();
    return _a.animatorNormalizedTime(handle, animator);
  }

  bool animatorFinished(int animator) {
    _checkAlive();
    return _a.animatorFinished(handle, animator) == 1;
  }

  /// Position and rotation of a bone in the model's own space, for attaching
  /// things to hands or heads.
  Matrix4 animatorJointMatrix(int animator, int joint) {
    _checkAlive();
    final b = NativeFloats(16);
    try {
      _a.animatorJointMatrix(handle, animator, joint, b.ptr);
      return Matrix4.fromFloat32List(Float32List.fromList(b.list));
    } finally {
      b.dispose();
    }
  }

  /// Gives a mesh its bone data (4 bone numbers and 4 weights per vertex).
  void setMeshSkin(int mesh, Uint8List joints, Float32List weights) {
    _checkAlive();
    final j = NativeBytes(joints.length);
    NativeFloats? w;
    try {
      j.list.setAll(0, joints);
      w = NativeFloats(weights.length);
      w.list.setAll(0, weights);
      _a.meshSetSkin(handle, mesh, j.ptr, w.ptr);
    } finally {
      w?.dispose();
      j.dispose();
    }
  }

  /// Links an object to an animator so its skinned mesh bends. -1 unlinks.
  void bindInstanceAnimator(int instance, int animator) {
    _checkAlive();
    _a.instanceBindAnimator(handle, instance, animator);
  }

  // ------------------------------------------------------------ joints

  /// Low level joint creation (see [NativePhysics.createJoint] for the easy way).
  int createJointRaw({
    required int type,
    required int a,
    required int b,
    required Vector3 anchorA,
    required Vector3 anchorB,
    required Vector3 axis,
    required List<double> params,
  }) {
    _checkAlive();
    assert(params.length == 12);
    final fa = NativeFloats(3);
    NativeFloats? fb;
    NativeFloats? ax;
    NativeFloats? p;
    try {
      fa.list.setAll(0, [anchorA.x, anchorA.y, anchorA.z]);
      fb = NativeFloats(3);
      fb.list.setAll(0, [anchorB.x, anchorB.y, anchorB.z]);
      ax = NativeFloats(3);
      ax.list.setAll(0, [axis.x, axis.y, axis.z]);
      p = NativeFloats(12);
      p.list.setAll(0, params);
      return _a.jointCreate(handle, type, a, b, fa.ptr, fb.ptr, ax.ptr, p.ptr);
    } finally {
      p?.dispose();
      ax?.dispose();
      fb?.dispose();
      fa.dispose();
    }
  }

  void destroyJoint(int id) {
    _checkAlive();
    _a.jointDestroy(handle, id);
  }

  bool jointAlive(int id) {
    _checkAlive();
    return _a.jointAlive(handle, id) == 1;
  }

  bool jointBroken(int id) {
    _checkAlive();
    return _a.jointBroken(handle, id) == 1;
  }

  double jointAngle(int id) {
    _checkAlive();
    return _a.jointAngle(handle, id);
  }

  double jointForce(int id) {
    _checkAlive();
    return _a.jointForce(handle, id);
  }

  void setJointMotor(int id, double speed, double maxTorque) {
    _checkAlive();
    _a.jointSetMotor(handle, id, speed, maxTorque);
  }

  void setJointLimits(int id, {required bool enabled, double lower = 0, double upper = 0}) {
    _checkAlive();
    _a.jointSetLimits(handle, id, enabled ? 1 : 0, lower, upper);
  }

  // ------------------------------------------------------------ models

  /// Loads a `.glb` (Blender: File > Export > glTF 2.0 > glTF Binary).
  /// Textures inside the file (PNG) are loaded too. Throws if the file is bad.
  /// The pieces also become render instances in this native world.
  /// By default the native render instances of the pieces are removed again,
  /// because you will make your own objects from the returned parts. Set
  /// [createInstances] to keep them and draw them with the native renderer.
  List<NativeModelPart> loadGlb(Uint8List bytes, {void Function(String warning)? onWarning, bool createInstances = false}) =>
      loadModel(bytes, onWarning: onWarning, createInstances: createInstances).parts;

  /// Like [loadGlb], and also returns the animations of the file.
  NativeModel loadModel(Uint8List bytes, {void Function(String warning)? onWarning, bool createInstances = false}) {
    _checkAlive();
    final first = _a.modelPartCount(handle);
    final firstClip = _a.modelClipCount(handle);
    final int n;
    final data = NativeBytes(bytes.length);
    try {
      data.list.setAll(0, bytes);
      n = _a.modelLoadGlb(handle, data.ptr, bytes.length);
    } finally {
      data.dispose();
    }
    if (n < 0) throw FormatException('Could not load model: ${_text(_a.modelError)}');
    final warning = _text(_a.modelWarning);
    if (warning.isNotEmpty) onWarning?.call(warning);
    final parts = <NativeModelPart>[];
    for (var i = first; i < first + n; i++) {
      final mesh = _a.modelPartMesh(handle, i);
      final int vc;
      final int ic;
      final info = NativeInt32s(2);
      try {
        _a.meshInfo(handle, mesh, info.ptr);
        vc = info.list[0];
        ic = info.list[1];
      } finally {
        info.dispose();
      }
      final v = NativeFloats(vc * 8);
      NativeUint32s? idx;
      NativeFloats? m;
      NativeFloats? c;
      NativeBytes? nameBuf;
      try {
        idx = NativeUint32s(ic);
        _a.meshCopy(handle, mesh, v.ptr, idx.ptr);
        m = NativeFloats(16);
        _a.modelPartMatrix(handle, i, m.ptr);
        c = NativeFloats(4);
        _a.modelPartColor(handle, i, c.ptr);
        nameBuf = NativeBytes(128);
        _a.modelPartName(handle, i, nameBuf.ptr.cast<Int8>(), 128);
        final skeleton = _a.modelPartSkeleton(handle, i);
        Uint8List? joints;
        Float32List? weights;
        if (skeleton >= 0) {
          final jb = NativeBytes(vc * 4);
          NativeFloats? wb;
          try {
            wb = NativeFloats(vc * 4);
            if (_a.meshSkinCopy(handle, mesh, jb.ptr, wb.ptr) == 1) {
              joints = Uint8List.fromList(jb.list);
              weights = Float32List.fromList(wb.list);
            }
          } finally {
            wb?.dispose();
            jb.dispose();
          }
        }
        parts.add(NativeModelPart(
          skeleton: joints == null ? -1 : skeleton,
          joints: joints,
          weights: weights,
          name: _cString(nameBuf.list),
          transform: Matrix4.fromFloat32List(Float32List.fromList(m.list)),
          vertices: Float32List.fromList(v.list),
          indices: Uint32List.fromList(idx.list),
          color: Vector4(c.list[0], c.list[1], c.list[2], c.list[3]),
          textureId: _a.modelPartTexture(handle, i),
        ));
      } finally {
        nameBuf?.dispose();
        c?.dispose();
        m?.dispose();
        idx?.dispose();
        v.dispose();
      }
    }
    if (!createInstances) {
      for (var i = first; i < first + n; i++) {
        _a.instanceDestroy(handle, _a.modelPartInstance(handle, i));
      }
    }
    final clips = <NativeModelClip>[];
    final cn = _a.modelClipCount(handle);
    for (var i = firstClip; i < cn; i++) {
      final nb = NativeBytes(128);
      try {
        _a.modelClipName(handle, i, nb.ptr.cast<Int8>(), 128);
        final id = _a.modelClipId(handle, i);
        clips.add(NativeModelClip(
          name: _cString(nb.list),
          clipId: id,
          skeleton: _a.modelClipSkeleton(handle, i),
          duration: _a.clipDuration(handle, id),
        ));
      } finally {
        nb.dispose();
      }
    }
    return NativeModel(parts, clips);
  }

  String _text(int Function(Pointer<Void>, Pointer<Int8>, int) read) {
    final len = read(handle, nullptr.cast<Int8>(), 0);
    if (len <= 0) return '';
    final b = NativeBytes(len + 1);
    try {
      read(handle, b.ptr.cast<Int8>(), len + 1);
      return _cString(b.list);
    } finally {
      b.dispose();
    }
  }

  String _cString(Uint8List bytes) {
    final end = bytes.indexOf(0);
    return utf8.decode(end < 0 ? bytes : bytes.sublist(0, end), allowMalformed: true);
  }

  // ------------------------------------------------------------ drawing

  int createMesh(Float32List vertices, List<int> indices) {
    _checkAlive();
    final v = NativeFloats(vertices.length);
    NativeUint32s? i;
    try {
      v.list.setAll(0, vertices);
      i = NativeUint32s(indices.length);
      i.list.setAll(0, indices);
      final id = _a.meshCreate(handle, v.ptr, vertices.length ~/ 8, i.ptr, indices.length);
      if (id < 0) throw ArgumentError('Bad mesh data.');
      return id;
    } finally {
      i?.dispose();
      v.dispose();
    }
  }

  /// [rgba] has 4 bytes per pixel (sRGB). Mip levels are made for you.
  int createTexture(int width, int height, Uint8List rgba) {
    _checkAlive();
    final b = NativeBytes(rgba.length);
    try {
      b.list.setAll(0, rgba);
      final id = _a.textureCreate(handle, width, height, b.ptr);
      if (id < 0) throw ArgumentError('Bad texture.');
      return id;
    } finally {
      b.dispose();
    }
  }

  int createInstance(int mesh) {
    _checkAlive();
    return _a.instanceCreate(handle, mesh);
  }

  void destroyInstance(int id) {
    _checkAlive();
    _a.instanceDestroy(handle, id);
  }

  void setInstanceMesh(int id, int mesh) {
    _checkAlive();
    _a.instanceSetMesh(handle, id, mesh);
  }

  void setInstanceVisible(int id, bool v) {
    _checkAlive();
    _a.instanceSetVisible(handle, id, v ? 1 : 0);
  }

  void setInstanceTexture(int id, int texture) {
    _checkAlive();
    _a.instanceSetTexture(handle, id, texture);
  }

  void setInstanceColor(int id, double r, double g, double b, [double a = 1]) {
    _checkAlive();
    _a.instanceSetColor(handle, id, r, g, b, a);
  }

  void setInstanceMaterial(int id, {bool unlit = false, bool doubleSided = false, double specular = 0.2, double emissive = 0}) {
    _checkAlive();
    _a.instanceSetMaterial(handle, id, unlit ? 1 : 0, doubleSided ? 1 : 0, specular, emissive);
  }

  /// Lines drawn over the scene (10 numbers each: a, b, rgba). An empty list clears them.
  void setDebugLines(Float32List lines, {bool depthTest = true}) {
    _checkAlive();
    if (lines.isEmpty) {
      _a.debugSetLines(handle, nullptr, 0, depthTest ? 1 : 0);
      return;
    }
    final b = NativeFloats(lines.length);
    try {
      b.list.setAll(0, lines);
      _a.debugSetLines(handle, b.ptr, lines.length ~/ 10, depthTest ? 1 : 0);
    } finally {
      b.dispose();
    }
  }

  /// Particle sprites (9 numbers each: position, size, rgba, flags). Empty clears them.
  void setParticles(Float32List sprites) {
    _checkAlive();
    if (sprites.isEmpty) {
      _a.particlesSet(handle, nullptr, 0);
      return;
    }
    final b = NativeFloats(sprites.length);
    try {
      b.list.setAll(0, sprites);
      _a.particlesSet(handle, b.ptr, sprites.length ~/ 9);
    } finally {
      b.dispose();
    }
  }

  /// Decodes a PNG or JPEG file into RGBA pixels. Returns null (and the reason
  /// in [error]) if the file cannot be read. JPEG: baseline and progressive (not arithmetic coded, lossless, 12 bit or CMYK).
  ({int width, int height, Uint8List rgba})? decodeImage(Uint8List bytes, {void Function(String error)? error}) =>
      NativeWorld.decodeImageStatic(bytes, error: error);

  static ({int width, int height, Uint8List rgba})? decodeImageStatic(Uint8List bytes, {void Function(String error)? error}) {
    final data = NativeBytes(bytes.length);
    NativeInt32s? wh;
    NativeBytes? err;
    try {
      data.list.setAll(0, bytes);
      wh = NativeInt32s(2);
      err = NativeBytes(256);
      final api = TejNative.api;
      var ok = api.decodeImage(data.ptr, bytes.length, wh.ptr, wh.ptr + 1, nullptr, err.ptr.cast<Int8>(), 256);
      ({int width, int height, Uint8List rgba})? result;
      if (ok == 1) {
        final w = wh.list[0], h = wh.list[1];
        final px = NativeBytes(w * h * 4);
        try {
          ok = api.decodeImage(data.ptr, bytes.length, wh.ptr, wh.ptr + 1, px.ptr, err.ptr.cast<Int8>(), 256);
          if (ok == 1) result = (width: w, height: h, rgba: Uint8List.fromList(px.list));
        } finally {
          px.dispose();
        }
      } else if (error != null) {
        var n = 0;
        final l = err.list;
        while (n < l.length && l[n] != 0) {
          n++;
        }
        error(String.fromCharCodes(l.sublist(0, n)));
      }
      return result;
    } finally {
      err?.dispose();
      wh?.dispose();
      data.dispose();
    }
  }

  /// Picture effects after drawing. Null (or neutral values) turns them off.
  void setPostEffects(PostEffects? p) {
    _checkAlive();
    if (p == null || p.isNeutral) {
      _a.envSetPost(handle, 0, 1, 0, 1, 1, 0, 0, 0.7);
      return;
    }
    _a.envSetPost(handle, 1, p.exposure, p.tonemap.index, p.contrast, p.saturation, p.vignette, p.bloom, p.bloomThreshold);
  }

  /// Shadows of the first directional light (needs a directional light).
  /// [distance] is meters from the camera, [strength] 0..1, [mapSize] 256..4096.
  void setShadows({required bool enabled, int mapSize = 1024, double distance = 30, double strength = 1}) {
    _checkAlive();
    _a.envSetShadows(handle, enabled ? 1 : 0, mapSize, distance, strength);
  }

  void setInstanceShadow(int id, {bool cast = true, bool receive = true, bool shadowOnly = false}) {
    _checkAlive();
    _a.instanceSetShadow(handle, id, (cast ? 1 : 0) | (receive ? 2 : 0) | (shadowOnly ? 4 : 0));
  }

  void setInstanceTransform(int id, Matrix4 m) =>
      _floats(m.storage.toList(), (p) => _a.instanceSetTransform(handle, id, p));

  /// type 0: directional ([vector] = direction the light travels),
  /// type 1: point ([vector] = position).
  int createLight(int type, Vector3 vector, Vector3 color, double intensity, [double range = 20]) {
    _checkAlive();
    return _a.lightCreate(handle, type, vector.x, vector.y, vector.z, color.x, color.y, color.z, intensity, range);
  }

  void setLight(int id, Vector3 vector, Vector3 color, double intensity, [double range = 20]) {
    _checkAlive();
    _a.lightSet(handle, id, vector.x, vector.y, vector.z, color.x, color.y, color.z, intensity, range);
  }

  void destroyLight(int id) {
    _checkAlive();
    _a.lightDestroy(handle, id);
  }

  void setEnvironment({double ambient = 0.35, double fogDensity = 0, Vector3? skyTop, Vector3? skyHorizon, Vector3? ground, Vector3? fogColor}) {
    _checkAlive();
    final t = skyTop ?? Vector3(0.25, 0.5, 0.85);
    final h = skyHorizon ?? Vector3(0.75, 0.85, 0.95);
    final g = ground ?? Vector3(0.25, 0.22, 0.2);
    final f = fogColor ?? h;
    // four separate small buffers keep us free of pointer arithmetic
    final top = NativeFloats(3);
    NativeFloats? hor;
    NativeFloats? gr;
    NativeFloats? fo;
    try {
      top.list.setAll(0, [t.x, t.y, t.z]);
      hor = NativeFloats(3);
      hor.list.setAll(0, [h.x, h.y, h.z]);
      gr = NativeFloats(3);
      gr.list.setAll(0, [g.x, g.y, g.z]);
      fo = NativeFloats(3);
      fo.list.setAll(0, [f.x, f.y, f.z]);
      _a.envSet(handle, ambient, fogDensity, top.ptr, hor.ptr, gr.ptr, fo.ptr);
    } finally {
      fo?.dispose();
      gr?.dispose();
      hor?.dispose();
      top.dispose();
    }
  }

  /// Flat ambient light (replaces the sky tinted ambient light).
  void setAmbientColor(Vector3 c) {
    _checkAlive();
    _a.envSetAmbientColor(handle, c.x, c.y, c.z);
  }

  /// Draws the world on the CPU and returns [width] x [height] RGBA bytes
  /// (a copy). With [view] and [projection] the camera is taken from them,
  /// otherwise from the last look-at camera of the native world.
  Uint8List renderRgba(int width, int height, {Matrix4? view, Matrix4? projection, Vector3? eye}) {
    _checkAlive();
    if (width <= 0 || height <= 0) return Uint8List(0);
    if (view != null && projection != null) {
      final v = NativeFloats(16);
      NativeFloats? p;
      NativeFloats? ee;
      try {
        v.list.setAll(0, view.storage);
        p = NativeFloats(16);
        p.list.setAll(0, projection.storage);
        final e = eye ?? Vector3.zero();
        ee = NativeFloats(3);
        ee.list.setAll(0, [e.x, e.y, e.z]);
        _a.cameraSetMatrices(handle, v.ptr, p.ptr, ee.ptr);
      } finally {
        ee?.dispose();
        p?.dispose();
        v.dispose();
      }
    }
    final need = width * height * 4;
    if ((_frame?.length ?? 0) != need) {
      _frame?.dispose();
      _frame = NativeBytes(need);
    }
    _a.renderSoftware(handle, width, height, _frame!.ptr);
    return Uint8List.fromList(_frame!.list);
  }

  /// Look-at camera for [renderRgba] without matrices.
  void setCamera(Vector3 position, Vector3 target, {double fovYRadians = 1.0, double near = 0.1, double far = 500}) {
    _checkAlive();
    _a.cameraSet(handle, position.x, position.y, position.z, target.x, target.y, target.z, fovYRadians, near, far);
  }
}
