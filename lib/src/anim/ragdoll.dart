/// Humanoid ragdoll builder: generates physics body and joint blueprints from
/// skeleton bone positions so a character can transition smoothly into ragdoll.
library;

import '../math/vec.dart';
import 'retarget.dart';

class RagdollLimbDesc {
  const RagdollLimbDesc({
    required this.boneName,
    required this.parentBone,
    required this.center,
    required this.radius,
    required this.halfLength,
    required this.mass,
    required this.maxSwingRadians,
  });

  final String boneName;
  final String? parentBone;
  final Vector3 center;
  final double radius;
  final double halfLength;
  final double mass;
  final double maxSwingRadians;
}

/// Builds a standard humanoid ragdoll capsule + cone-twist joint layout from a
/// [SkeletonPose] and total character [totalMass].
class RagdollBuilder {
  const RagdollBuilder._();

  static const Map<String, String> _parentOf = {
    'Spine': 'Hips',
    'Head': 'Spine',
    'LeftUpperArm': 'Spine',
    'LeftLowerArm': 'LeftUpperArm',
    'RightUpperArm': 'Spine',
    'RightLowerArm': 'RightUpperArm',
    'LeftUpperLeg': 'Hips',
    'LeftLowerLeg': 'LeftUpperLeg',
    'RightUpperLeg': 'Hips',
    'RightLowerLeg': 'RightUpperLeg',
  };

  static const Map<String, double> _massShare = {
    'Hips': 0.20,
    'Spine': 0.24,
    'Head': 0.08,
    'LeftUpperArm': 0.04,
    'LeftLowerArm': 0.03,
    'RightUpperArm': 0.04,
    'RightLowerArm': 0.03,
    'LeftUpperLeg': 0.11,
    'LeftLowerLeg': 0.06,
    'RightUpperLeg': 0.11,
    'RightLowerLeg': 0.06,
  };

  /// Generates [RagdollLimbDesc] entries for all humanoid bones present in [pose].
  static List<RagdollLimbDesc> buildHumanoid(
    SkeletonPose pose, {
    double totalMass = 75.0,
    double defaultRadius = 0.09,
  }) {
    final out = <RagdollLimbDesc>[];
    for (final entry in _massShare.entries) {
      final bone = entry.key;
      final xf = pose[bone];
      if (xf == null) continue;
      final parent = _parentOf[bone];
      final parentXf = parent != null ? pose[parent] : null;
      final center = parentXf != null
          ? (xf.position + parentXf.position) * 0.5
          : xf.position.clone();
      final segLen = parentXf != null ? (xf.position - parentXf.position).length : 0.25;
      final halfLen = (segLen * 0.5).clamp(0.05, 0.5).toDouble();

      out.add(RagdollLimbDesc(
        boneName: bone,
        parentBone: parentXf != null ? parent : null,
        center: center,
        radius: bone == 'Spine' || bone == 'Hips' ? defaultRadius * 1.6 : defaultRadius,
        halfLength: halfLen,
        mass: totalMass * entry.value,
        maxSwingRadians: bone.contains('Lower') ? 1.4 : 0.9,
      ));
    }
    return out;
  }
}
