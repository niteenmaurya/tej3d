/// Root motion extraction and animation retargeting between skeletons.
library;

import 'dart:math' as math;

import '../math/vec.dart';

/// Local transform (position, rotation, scale) of a single bone.
class BoneTransform {
  BoneTransform({
    Vector3? position,
    Quaternion? rotation,
    Vector3? scale,
  })  : position = position?.clone() ?? Vector3.zero(),
        rotation = rotation?.clone() ?? Quaternion.identity(),
        scale = scale?.clone() ?? Vector3.all(1.0);

  Vector3 position;
  Quaternion rotation;
  Vector3 scale;

  BoneTransform clone() => BoneTransform(
        position: position.clone(),
        rotation: rotation.clone(),
        scale: scale.clone(),
      );
}

/// A named pose of a skeleton (bone name -> local [BoneTransform]).
class SkeletonPose {
  SkeletonPose([Map<String, BoneTransform>? bones])
      : bones = bones != null
            ? {for (final e in bones.entries) e.key: e.value.clone()}
            : {};

  final Map<String, BoneTransform> bones;

  BoneTransform? operator [](String name) => bones[name];

  void operator []=(String name, BoneTransform value) {
    bones[name] = value;
  }

  SkeletonPose clone() => SkeletonPose(bones);
}

/// Frame-to-frame root motion delta extracted from an animated root bone.
class RootMotionDelta {
  const RootMotionDelta({
    required this.translation,
    required this.rotation,
    required this.yawDelta,
  });

  final Vector3 translation;
  final Quaternion rotation;

  /// Change in Y-axis heading in radians.
  final double yawDelta;
}

/// Extracts per-frame root motion from a named root bone so gameplay code can
/// move a character controller instead of sliding the mesh inside its rig.
class RootMotionExtractor {
  RootMotionExtractor({
    this.rootBone = 'Hips',
    this.extractHorizontal = true,
    this.extractVertical = false,
    this.extractYaw = true,
  });

  final String rootBone;
  final bool extractHorizontal;
  final bool extractVertical;
  final bool extractYaw;

  Vector3? _lastPos;
  double? _lastYaw;

  void reset() {
    _lastPos = null;
    _lastYaw = null;
  }

  /// Extracts the motion delta since the previous call and removes the
  /// extracted components from [pose] in place so the skeleton stays centered.
  RootMotionDelta extract(SkeletonPose pose, {bool looped = false}) {
    final root = pose[rootBone];
    if (root == null) {
      return RootMotionDelta(
        translation: Vector3.zero(),
        rotation: Quaternion.identity(),
        yawDelta: 0.0,
      );
    }

    final currentPos = root.position.clone();
    final currentYaw = _extractYaw(root.rotation);

    Vector3 deltaPos;
    double deltaYaw;
    if (_lastPos == null || looped) {
      deltaPos = Vector3.zero();
      deltaYaw = 0.0;
    } else {
      deltaPos = currentPos - _lastPos!;
      deltaYaw = _wrapAngle(currentYaw - (_lastYaw ?? currentYaw));
    }

    _lastPos = currentPos;
    _lastYaw = currentYaw;

    final outTrans = Vector3(
      extractHorizontal ? deltaPos.x : 0.0,
      extractVertical ? deltaPos.y : 0.0,
      extractHorizontal ? deltaPos.z : 0.0,
    );
    final outYaw = extractYaw ? deltaYaw : 0.0;
    final outRot = Quaternion.axisAngle(Vector3(0, 1, 0), outYaw);

    // Strip extracted motion from the pose so it does not double-apply.
    if (extractHorizontal) {
      root.position.x = 0.0;
      root.position.z = 0.0;
    }
    if (extractVertical) {
      root.position.y = 0.0;
    }
    if (extractYaw && currentYaw.abs() > 1e-9) {
      final invYaw = Quaternion.axisAngle(Vector3(0, 1, 0), -currentYaw);
      root.rotation = (invYaw * root.rotation)..normalize();
    }

    return RootMotionDelta(
      translation: outTrans,
      rotation: outRot,
      yawDelta: outYaw,
    );
  }

  static double _extractYaw(Quaternion q) {
    final fwd = q.rotateVector(Vector3(0, 0, -1));
    return math.atan2(-fwd.x, -fwd.z);
  }

  static double _wrapAngle(double a) {
    while (a > math.pi) {
      a -= 2 * math.pi;
    }
    while (a < -math.pi) {
      a += 2 * math.pi;
    }
    return a;
  }
}

/// Maps bone names from a source skeleton to a target skeleton.
class BoneMap {
  BoneMap(Map<String, String> sourceToTarget, {this.rootBone = 'Hips'})
      : _map = Map<String, String>.from(sourceToTarget);

  /// Standard humanoid aliases (Mixamo, Blender Rigify, Unity Humanoid, generic).
  static const Map<String, List<String>> standardHumanoidAliases = {
    'Hips': ['hips', 'pelvis', 'mixamorig:hips', 'root_hips'],
    'Spine': ['spine', 'spine1', 'mixamorig:spine'],
    'Chest': ['chest', 'spine2', 'upperchest', 'mixamorig:spine2'],
    'Neck': ['neck', 'mixamorig:neck'],
    'Head': ['head', 'mixamorig:head'],
    'LeftUpperArm': ['leftupperarm', 'upperarm_l', 'l_upperarm', 'mixamorig:leftarm'],
    'LeftLowerArm': ['leftlowerarm', 'lowerarm_l', 'forearm_l', 'mixamorig:leftforearm'],
    'LeftHand': ['lefthand', 'hand_l', 'l_hand', 'mixamorig:lefthand'],
    'RightUpperArm': ['rightupperarm', 'upperarm_r', 'r_upperarm', 'mixamorig:rightarm'],
    'RightLowerArm': ['rightlowerarm', 'lowerarm_r', 'forearm_r', 'mixamorig:rightforearm'],
    'RightHand': ['righthand', 'hand_r', 'r_hand', 'mixamorig:righthand'],
    'LeftUpperLeg': ['leftupperleg', 'thigh_l', 'l_thigh', 'mixamorig:leftupleg'],
    'LeftLowerLeg': ['leftlowerleg', 'calf_l', 'shin_l', 'mixamorig:leftleg'],
    'LeftFoot': ['leftfoot', 'foot_l', 'l_foot', 'mixamorig:leftfoot'],
    'RightUpperLeg': ['rightupperleg', 'thigh_r', 'r_thigh', 'mixamorig:rightupleg'],
    'RightLowerLeg': ['rightlowerleg', 'calf_r', 'shin_r', 'mixamorig:rightleg'],
    'RightFoot': ['rightfoot', 'foot_r', 'r_foot', 'mixamorig:rightfoot'],
  };

  /// Automatically builds a [BoneMap] between [sourceBones] and [targetBones]
  /// by matching exact names (case-insensitive) and standard humanoid aliases.
  factory BoneMap.autoMatch(
    Iterable<String> sourceBones,
    Iterable<String> targetBones,
  ) {
    final targetByNorm = <String, String>{};
    final targetByCanonical = <String, String>{};
    for (final t in targetBones) {
      final norm = _norm(t);
      targetByNorm[norm] = t;
      final canon = _canonicalHumanoid(norm);
      if (canon != null) targetByCanonical[canon] = t;
    }

    final mapping = <String, String>{};
    String root = 'Hips';
    for (final s in sourceBones) {
      final norm = _norm(s);
      String? matched = targetByNorm[norm];
      final canon = _canonicalHumanoid(norm);
      matched ??= canon != null ? targetByCanonical[canon] : null;
      if (matched != null) {
        mapping[s] = matched;
        if (canon == 'Hips') root = s;
      }
    }
    return BoneMap(mapping, rootBone: root);
  }

  final Map<String, String> _map;
  final String rootBone;

  Map<String, String> get entries => Map.unmodifiable(_map);

  String? targetFor(String sourceBone) => _map[sourceBone];

  int get length => _map.length;

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[\s\-]+'), '_');

  static String? _canonicalHumanoid(String normalized) {
    for (final e in standardHumanoidAliases.entries) {
      if (e.key.toLowerCase() == normalized || e.value.contains(normalized)) {
        return e.key;
      }
    }
    return null;
  }
}

/// Retargets [SkeletonPose] frames from a source rig to a target rig using a
/// [BoneMap] and both skeletons' bind (rest) poses.
class AnimationRetargeter {
  AnimationRetargeter({
    required this.boneMap,
    required this.sourceBindPose,
    required this.targetBindPose,
  });

  final BoneMap boneMap;
  final SkeletonPose sourceBindPose;
  final SkeletonPose targetBindPose;

  /// Ratio of target hip height to source hip height for scaling root translation.
  double get rootHeightScale {
    final sRoot = sourceBindPose[boneMap.rootBone];
    final tName = boneMap.targetFor(boneMap.rootBone);
    final tRoot = tName != null ? targetBindPose[tName] : null;
    if (sRoot == null || tRoot == null || sRoot.position.y.abs() < 1e-5) {
      return 1.0;
    }
    return tRoot.position.y / sRoot.position.y;
  }

  /// Retargets [sourcePose] onto the target skeleton.
  /// Rotation is transferred as a delta relative to each bone's bind rotation:
  /// `targetRot = targetBind * (sourceBind^-1 * sourceRot)`.
  /// Root bone translation delta is scaled by [rootHeightScale].
  SkeletonPose retarget(SkeletonPose sourcePose) {
    final result = targetBindPose.clone();
    final scaleY = rootHeightScale;

    for (final entry in boneMap.entries.entries) {
      final sName = entry.key;
      final tName = entry.value;
      final sAnim = sourcePose[sName];
      if (sAnim == null) continue;

      final sBind = sourceBindPose[sName] ?? BoneTransform();
      final tBind = targetBindPose[tName] ?? BoneTransform();

      final sBindInv = sBind.rotation.conjugated()..normalize();
      final deltaRot = (sBindInv * sAnim.rotation)..normalize();
      final outRot = (tBind.rotation * deltaRot)..normalize();

      Vector3 outPos = tBind.position.clone();
      if (sName == boneMap.rootBone) {
        final deltaPos = (sAnim.position - sBind.position) * scaleY;
        outPos = tBind.position + deltaPos;
      }

      result[tName] = BoneTransform(
        position: outPos,
        rotation: outRot,
        scale: tBind.scale.clone(),
      );
    }

    return result;
  }
}
