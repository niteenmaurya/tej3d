/// Inverse kinematics: given where a hand or foot should be, find where the joints must go.
///
/// Pure math on positions (no scene needed), so you can use it with any skeleton:
///
/// ```dart
/// // an arm: shoulder, elbow, hand. The hand should reach the cup; the elbow points to the side.
/// final r = TwoBoneIk.solve(shoulder, elbow, hand, cup, pole: elbowHint);
/// elbowObject.transform.worldPosition = r.mid;
/// handObject.transform.worldPosition = r.end;
///
/// // a tail or a tentacle with many joints
/// final joints = Fabrik.solve([p0, p1, p2, p3, p4], target);
/// ```
///
/// To turn bones instead of moving points, use [Ik.rotationBetween] or
/// [SkinnedIkSolver] with optional [IkConstraint] joint limits.
library;

import 'dart:math' as math;

import '../engine/transform.dart';
import '../math/vec.dart';

/// The new places of the middle and the end joint.
class IkResult {
  const IkResult(this.mid, this.end, this.reached);

  final Vector3 mid, end;

  /// False when the target was too far (or too near): the limb is straight (or folded) towards it.
  final bool reached;
}

/// Angular limit for a joint during IK solving (cone swing limit around a
/// reference direction, or hinge limits around a single axis).
class IkConstraint {
  const IkConstraint.cone({
    required this.maxAngleRadians,
    this.referenceAxis,
  })  : hingeAxis = null,
        minAngleRadians = 0.0;

  const IkConstraint.hinge({
    required Vector3 axis,
    required this.minAngleRadians,
    required this.maxAngleRadians,
  })  : hingeAxis = axis,
        referenceAxis = null;

  /// Max swing angle from rest direction (cone) or upper hinge angle.
  final double maxAngleRadians;

  /// Lower hinge angle (hinge mode only).
  final double minAngleRadians;

  /// Optional reference axis for cone constraint (defaults to rest bone dir).
  final Vector3? referenceAxis;

  /// Hinge rotation axis (non-null for hinge constraints).
  final Vector3? hingeAxis;

  /// Clamps a desired bone direction [dir] relative to [restDir].
  Vector3 clampDirection(Vector3 dir, Vector3 restDir) {
    final d = dir.normalized();
    final ref = (referenceAxis ?? restDir).normalized();

    if (hingeAxis != null) {
      final axis = hingeAxis!.normalized();
      // Project both onto the plane perpendicular to the hinge axis.
      var projRef = ref - axis * ref.dot(axis);
      var projDir = d - axis * d.dot(axis);
      if (projRef.length2 < 1e-12 || projDir.length2 < 1e-12) return ref;
      projRef.normalize();
      projDir.normalize();
      final sinA = axis.dot(projRef.cross(projDir));
      final cosA = projRef.dot(projDir).clamp(-1.0, 1.0).toDouble();
      final angle = math.atan2(sinA, cosA);
      final clamped = angle.clamp(minAngleRadians, maxAngleRadians).toDouble();
      return Quaternion.axisAngle(axis, clamped).rotateVector(projRef).normalized();
    }

    // Cone limit around ref.
    final dot = ref.dot(d).clamp(-1.0, 1.0).toDouble();
    final angle = math.acos(dot);
    if (angle <= maxAngleRadians) return d;
    final cross = ref.cross(d);
    if (cross.length2 < 1e-12) return ref;
    return Quaternion.axisAngle(cross.normalized(), maxAngleRadians).rotateVector(ref).normalized();
  }
}

/// A limb with two bones (arm, leg): root joint, middle joint (elbow, knee), end (hand, foot).
class TwoBoneIk {
  const TwoBoneIk._();

  /// Moves the end to [target] when it can reach, keeping both bone lengths. The middle joint bends
  /// towards [pole] (a point in the world, for example in front of the knee). Without [pole] the joint
  /// keeps bending the way it bends now.
  static IkResult solve(Vector3 root, Vector3 mid, Vector3 end, Vector3 target, {Vector3? pole}) {
    final l1 = (mid - root).length, l2 = (end - mid).length;
    final toTarget = target - root;
    var dist = toTarget.length;
    if (dist < 1e-9) {
      // target is on the root: fold the limb back on itself, towards the old bend
      dist = 1e-9;
    }
    final dir = dist <= 1e-9 ? (end - root).normalized() : toTarget / dist;
    final maxReach = l1 + l2, minReach = (l1 - l2).abs();
    final reached = dist <= maxReach && dist >= minReach;
    final d = dist.clamp(minReach, maxReach).toDouble();

    // where the middle joint sits along the root-target line, and how far it sticks out
    final a = d == 0 ? 0.0 : (l1 * l1 - l2 * l2 + d * d) / (2.0 * d);
    final h = math.sqrt(math.max(0.0, l1 * l1 - a * a));

    // the direction it sticks out: from the pole, else from the current bend
    Vector3 bend = Vector3.zero();
    if (pole != null) bend = _perp(pole - root, dir);
    if (bend.length2 < 1e-12) bend = _perp(mid - root, dir);
    if (bend.length2 < 1e-12) bend = _anyPerp(dir);
    bend.normalize();

    final newMid = root + dir * a + bend * h;
    final newEnd = root + dir * d;
    return IkResult(newMid, newEnd, reached);
  }

  static Vector3 _perp(Vector3 v, Vector3 axis) => v - axis * v.dot(axis);

  static Vector3 _anyPerp(Vector3 axis) {
    final other = axis.x.abs() < 0.9 ? Vector3(1, 0, 0) : Vector3(0, 1, 0);
    return _perp(other, axis);
  }
}

/// A chain with any number of joints (tail, spine, tentacle, rope). The first joint stays where it is.
class Fabrik {
  const Fabrik._();

  /// Returns new places for [joints] (the list you give is not changed). The distance between
  /// neighbours stays the same. Stops after [iterations] rounds or when the end is within [tolerance]
  /// of [target]. If the target is too far the chain stretches straight towards it.
  /// Optional [constraints] (keyed by joint index) clamp each segment direction.
  static List<Vector3> solve(
    List<Vector3> joints,
    Vector3 target, {
    int iterations = 16,
    double tolerance = 1e-4,
    Map<int, IkConstraint>? constraints,
  }) {
    final n = joints.length;
    final p = [for (final j in joints) j.clone()];
    if (n < 2) return p;
    final len = [for (var i = 0; i < n - 1; i++) (joints[i + 1] - joints[i]).length];
    final restDirs = [
      for (var i = 0; i < n - 1; i++)
        _dirOrAny(joints[i + 1] - joints[i], Vector3(0, 1, 0)),
    ];
    final total = len.fold<double>(0.0, (a, b) => a + b);
    final root = p.first.clone();

    if ((target - root).length >= total && (constraints == null || constraints.isEmpty)) {
      // out of reach: a straight line
      final dir = (target - root).normalized();
      var at = 0.0;
      for (var i = 1; i < n; i++) {
        at += len[i - 1];
        p[i] = root + dir * at;
      }
      return p;
    }

    for (var it = 0; it < iterations; it++) {
      if ((p.last - target).length <= tolerance) break;
      // backward: end on the target, pull the others after it
      p[n - 1] = target.clone();
      for (var i = n - 2; i >= 0; i--) {
        p[i] = p[i + 1] + _dirOrAny(p[i] - p[i + 1], joints[i] - joints[i + 1]) * len[i];
      }
      // forward: root back to its place, push the others after it
      p[0] = root.clone();
      for (var i = 1; i < n; i++) {
        var dir = _dirOrAny(p[i] - p[i - 1], restDirs[i - 1]);
        final c = constraints?[i - 1];
        if (c != null) {
          dir = c.clampDirection(dir, restDirs[i - 1]);
        }
        p[i] = p[i - 1] + dir * len[i - 1];
      }
    }
    return p;
  }

  static Vector3 _dirOrAny(Vector3 v, Vector3 fallback) {
    if (v.length2 > 1e-18) return v.normalized();
    return fallback.length2 > 1e-18 ? fallback.normalized() : Vector3(0, 1, 0);
  }
}

/// Helpers to turn bones.
class Ik {
  const Ik._();

  /// The shortest turn that makes the direction [from] point along [to]. Both need a length above 0.
  static Quaternion rotationBetween(Vector3 from, Vector3 to) {
    final a = from.normalized(), b = to.normalized();
    final d = a.dot(b).clamp(-1.0, 1.0).toDouble();
    if (d > 1.0 - 1e-12) return Quaternion.identity();
    if (d < -1.0 + 1e-12) {
      // opposite: half a turn around any axis that is not along a
      final other = a.x.abs() < 0.9 ? Vector3(1, 0, 0) : Vector3(0, 1, 0);
      return Quaternion.axisAngle(a.cross(other), math.pi);
    }
    return Quaternion.axisAngle(a.cross(b), math.acos(d));
  }
}

/// Applies IK solutions directly onto a chain of scene [Transform] bones
/// (parent -> child -> ... -> effector) by rotating each bone's world
/// orientation rather than detaching bone lengths.
class SkinnedIkSolver {
  const SkinnedIkSolver._();

  /// Solves 2-bone IK for [upper] -> [lower] -> [effector] towards [target].
  /// [weight] blends from the current pose (0) to the solved IK pose (1).
  static IkResult applyTwoBone({
    required Transform upper,
    required Transform lower,
    required Transform effector,
    required Vector3 target,
    Vector3? pole,
    double weight = 1.0,
    IkConstraint? upperConstraint,
    IkConstraint? lowerConstraint,
  }) {
    final w = weight.clamp(0.0, 1.0).toDouble();
    final rootPos = upper.worldPosition;
    final midPos = lower.worldPosition;
    final endPos = effector.worldPosition;

    final solved = TwoBoneIk.solve(rootPos, midPos, endPos, target, pole: pole);
    if (w <= 1e-6) return solved;

    var desiredUpperDir = (solved.mid - rootPos).normalized();
    final curUpperDir = (midPos - rootPos).normalized();
    if (upperConstraint != null) {
      desiredUpperDir = upperConstraint.clampDirection(desiredUpperDir, curUpperDir);
    }
    _rotateBoneToDirection(upper, curUpperDir, desiredUpperDir, w);

    // Re-read after upper bone rotated.
    final newMid = lower.worldPosition;
    final newEnd = effector.worldPosition;
    var desiredLowerDir = (solved.end - newMid).normalized();
    final curLowerDir = (newEnd - newMid).normalized();
    if (lowerConstraint != null) {
      desiredLowerDir = lowerConstraint.clampDirection(desiredLowerDir, curLowerDir);
    }
    _rotateBoneToDirection(lower, curLowerDir, desiredLowerDir, w);

    return solved;
  }

  /// Solves multi-bone FABRIK for a parent-to-child [chain] of [Transform]s.
  static List<Vector3> applyChain({
    required List<Transform> chain,
    required Vector3 target,
    int iterations = 16,
    double tolerance = 1e-4,
    double weight = 1.0,
    Map<int, IkConstraint>? constraints,
  }) {
    final positions = [for (final t in chain) t.worldPosition];
    final solved = Fabrik.solve(
      positions,
      target,
      iterations: iterations,
      tolerance: tolerance,
      constraints: constraints,
    );
    final w = weight.clamp(0.0, 1.0).toDouble();
    if (w <= 1e-6 || chain.length < 2) return solved;

    for (var i = 0; i < chain.length - 1; i++) {
      final bone = chain[i];
      final child = chain[i + 1];
      final curDir = child.worldPosition - bone.worldPosition;
      final wantDir = solved[i + 1] - bone.worldPosition;
      if (curDir.length2 < 1e-12 || wantDir.length2 < 1e-12) continue;
      _rotateBoneToDirection(bone, curDir.normalized(), wantDir.normalized(), w);
    }
    return solved;
  }

  static void _rotateBoneToDirection(
    Transform bone,
    Vector3 currentWorldDir,
    Vector3 targetWorldDir,
    double weight,
  ) {
    final deltaWorld = Ik.rotationBetween(currentWorldDir, targetWorldDir);
    var q = deltaWorld;
    if (q.w < 0) q = Quaternion(-q.x, -q.y, -q.z, -q.w);
    final blended = Quaternion(
      q.x * weight,
      q.y * weight,
      q.z * weight,
      (1.0 - weight) + q.w * weight,
    )..normalize();
    final newWorldRot = (blended * bone.worldRotation)..normalize();
    final parent = bone.parent;
    if (parent == null) {
      bone.localRotation = newWorldRot;
    } else {
      final invParent = parent.worldRotation.conjugated()..normalize();
      bone.localRotation = (invParent * newWorldRot)..normalize();
    }
  }
}
