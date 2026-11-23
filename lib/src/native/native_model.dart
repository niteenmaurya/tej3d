import 'dart:typed_data';

import '../math/vec.dart';

import '../engine/game_object.dart';
import '../engine/mesh_renderer.dart';
import '../engine/render/material.dart';
import '../engine/render/mesh.dart';
import '../world/mesh_tools.dart';
import 'native_world.dart';

/// Loads a `.glb` (from Blender) and makes a [GameObject] with one child for
/// each piece. Child names are the node names from the file (for example
/// `Pillar.1`), so you can find them with `root.children`.
///
/// If the file has a skeleton and animations (a character), the root also gets
/// a [NativeModelAnimator]: `root.getComponent<NativeModelAnimator>()!.play('Walk')`.
/// Animated models are bent by the native renderer (`NativeRenderBackend`);
/// the plain Dart renderer draws them in their rest pose. The animation moves
/// forward when you call `physics.step(dt)` (the native world update).
///
/// Add the result to a scene: `scene.add(spawnModel(world, bytes))`.
/// Textures inside the file are loaded by the native core but are only drawn
/// by the native world's own instances, not by Dart scene objects yet.
///
/// Status: tested with the real native library (`test/native_bridge_test.dart`).
GameObject spawnModel(
  NativeWorld world,
  Uint8List glbBytes, {
  String name = 'Model',
  Vector3? position,
  void Function(String warning)? onWarning,
}) {
  final model = world.loadModel(glbBytes, onWarning: onWarning);
  final root = GameObject(name, position: position);
  final animators = <int, int>{}; // skeleton -> animator
  final armatures = <int, Matrix4>{}; // skeleton -> where its space sits in the model
  for (final p in model.parts) {
    final go = GameObject(p.name.isEmpty ? 'Part' : p.name);
    go.transform.setFromMatrix(p.transform);
    final r = MeshRenderer(meshFromPart(p), material: StandardMaterial(color: p.color.clone(), specular: 0.2, textureId: p.textureId));
    if (p.skeleton >= 0) {
      r.animatorId = animators[p.skeleton] ??= world.createAnimator(p.skeleton);
      armatures[p.skeleton] ??= p.transform.clone();
    }
    go.addComponent(r);
    root.addChild(go);
  }
  if (animators.isNotEmpty) {
    root.addComponent(NativeModelAnimator(world, animators, armatures, model.clips));
  }
  return root;
}

/// Plays the animations of a model made by [spawnModel] (walk, run, jump...).
///
/// ```dart
/// final anim = hero.getComponent<NativeModelAnimator>()!;
/// anim.play('Idle');
/// anim.crossfade('Run', 0.2);          // smooth change
/// final handPose = anim.boneWorldMatrix('Hand.R'); // put a sword there
/// ```
class NativeModelAnimator extends Component {
  NativeModelAnimator(this.world, this._animators, this._armatures, List<NativeModelClip> allClips)
      : clips = _group(allClips) {
    for (final e in _animators.entries) {
      final n = world.skeletonJointCount(e.key);
      for (var j = 0; j < n; j++) {
        final bone = world.skeletonJointName(e.key, j);
        if (bone.isNotEmpty) _bones.putIfAbsent(bone, () => _Bone(e.key, e.value, j));
      }
    }
  }

  static Map<String, List<NativeModelClip>> _group(List<NativeModelClip> all) {
    final m = <String, List<NativeModelClip>>{};
    for (final c in all) {
      (m[c.name] ??= []).add(c); // the same name can exist once per skeleton
    }
    return m;
  }

  final NativeWorld world;
  final Map<int, int> _animators;
  final Map<int, Matrix4> _armatures;
  final Map<String, _Bone> _bones = {};

  /// Clips by name (one entry per skeleton that has it).
  final Map<String, List<NativeModelClip>> clips;

  String? _current;

  /// Names of all animations.
  List<String> get clipNames => clips.keys.toList();

  bool hasClip(String name) => clips.containsKey(name);

  /// Length of a clip in seconds.
  double clipDuration(String name) => _clip(name).first.duration;

  /// Name of the clip played last, or null.
  String? get current => _current;

  List<NativeModelClip> _clip(String name) {
    final c = clips[name];
    if (c == null) throw ArgumentError('No animation "$name". Available: ${clipNames.join(', ')}');
    return c;
  }

  /// Starts a clip at once.
  void play(String name, {bool loop = true, double speed = 1}) {
    for (final c in _clip(name)) {
      world.playAnimator(_animators[c.skeleton]!, c.clipId, loop: loop, speed: speed);
    }
    _current = name;
  }

  /// Changes to a clip smoothly over [seconds].
  void crossfade(String name, double seconds, {bool loop = true, double speed = 1}) {
    for (final c in _clip(name)) {
      world.crossfadeAnimator(_animators[c.skeleton]!, c.clipId, seconds, loop: loop, speed: speed);
    }
    _current = name;
  }

  /// 0..1 through the current clip (looping clips start again at 0).
  double get normalizedTime {
    final name = _current;
    if (name == null) return 0;
    return world.animatorNormalizedTime(_animators[_clip(name).first.skeleton]!);
  }

  /// True when a clip that is not looping has reached its end.
  bool get isFinished {
    final name = _current;
    if (name == null) return false;
    return world.animatorFinished(_animators[_clip(name).first.skeleton]!);
  }

  /// Names of the bones (for [boneWorldMatrix]).
  List<String> get boneNames => _bones.keys.toList();

  bool hasBone(String name) => _bones.containsKey(name);

  /// Where a bone is now, in world space. Use it to put an object in a hand
  /// or on a head: `item.transform.setFromMatrix(anim.boneWorldMatrix('Hand.R'))`.
  Matrix4 boneWorldMatrix(String bone) {
    final b = _bones[bone];
    if (b == null) throw ArgumentError('No bone "$bone". Available: ${boneNames.join(', ')}');
    final inModel = (_armatures[b.skeleton] ?? Matrix4.identity()).multiplied(world.animatorJointMatrix(b.animator, b.joint));
    return transform.worldMatrix.multiplied(inModel);
  }

  @override
  void onDestroy() {
    for (final a in _animators.values) {
      world.destroyAnimator(a);
    }
    _animators.clear();
  }
}

class _Bone {
  _Bone(this.skeleton, this.animator, this.joint);
  final int skeleton, animator, joint;
}

/// Makes a Dart [Mesh] from a loaded piece.
Mesh meshFromPart(NativeModelPart p) {
  final n = p.vertices.length ~/ 8;
  final pos = Float32List(n * 3);
  final nor = Float32List(n * 3);
  final uvs = Float32List(n * 2);
  for (var i = 0; i < n; i++) {
    for (var k = 0; k < 3; k++) {
      pos[i * 3 + k] = p.vertices[i * 8 + k];
      nor[i * 3 + k] = p.vertices[i * 8 + 3 + k];
    }
    uvs[i * 2] = p.vertices[i * 8 + 6];
    uvs[i * 2 + 1] = p.vertices[i * 8 + 7];
  }
  return Mesh(MeshArrays(pos, nor, p.indices, uvs: uvs, joints: p.joints, weights: p.weights), name: p.name);
}
