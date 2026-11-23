/// Morph targets (blend shapes) for meshes: facial expressions, breathing,
/// squash and stretch, or damage states.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../engine/render/mesh.dart';
import '../world/mesh_tools.dart';

/// One morph target: per-vertex position (and optional normal) offsets relative
/// to the base mesh.
class MorphTarget {
  MorphTarget({
    required this.name,
    required this.positionDeltas,
    this.normalDeltas,
  }) {
    if (positionDeltas.length % 3 != 0) {
      throw ArgumentError('positionDeltas length must be a multiple of 3');
    }
    if (normalDeltas != null && normalDeltas!.length != positionDeltas.length) {
      throw ArgumentError('normalDeltas length must match positionDeltas');
    }
  }

  final String name;

  /// Position offsets (dx, dy, dz per vertex).
  final Float32List positionDeltas;

  /// Optional normal offsets (dnx, dny, dnz per vertex).
  final Float32List? normalDeltas;

  int get vertexCount => positionDeltas.length ~/ 3;
}

/// Applies weighted [MorphTarget]s on top of a base [Mesh] to produce a
/// deformed [Mesh].
class MorphController {
  MorphController(this.baseMesh, List<MorphTarget> targets)
      : targets = List.unmodifiable(targets),
        _weights = Float64List(targets.length) {
    final vCount = baseMesh.vertexCount;
    for (final t in targets) {
      if (t.vertexCount != vCount) {
        throw ArgumentError(
          'MorphTarget "${t.name}" has ${t.vertexCount} vertices, expected $vCount',
        );
      }
      _byName[t.name] = _byName.length;
    }
  }

  final Mesh baseMesh;
  final List<MorphTarget> targets;
  final Float64List _weights;
  final Map<String, int> _byName = {};

  int get targetCount => targets.length;

  /// Weight of target [index] (typically 0..1, but values outside are allowed
  /// unless [clamp] is true).
  double weightAt(int index) => _weights[index];

  /// Weight of target named [name], or 0 if not found.
  double weightOf(String name) {
    final idx = _byName[name];
    return idx == null ? 0.0 : _weights[idx];
  }

  void setWeightAt(int index, double weight, {bool clamp = false}) {
    _weights[index] = clamp ? weight.clamp(0.0, 1.0).toDouble() : weight;
  }

  bool setWeight(String name, double weight, {bool clamp = false}) {
    final idx = _byName[name];
    if (idx == null) return false;
    setWeightAt(idx, weight, clamp: clamp);
    return true;
  }

  void resetWeights() {
    _weights.fillRange(0, _weights.length, 0.0);
  }

  /// Evaluates all active morph targets and returns a new deformed [Mesh].
  /// When [renormalize] is true, blended normals are normalized to unit length.
  Mesh evaluate({bool renormalize = true}) {
    final base = baseMesh.arrays;
    final pos = Float32List.fromList(base.positions);
    final norm = Float32List.fromList(base.normals);
    final idx = Uint32List.fromList(base.indices);

    var normalsModified = false;
    for (var ti = 0; ti < targets.length; ti++) {
      final w = _weights[ti];
      if (w.abs() < 1e-7) continue;
      final t = targets[ti];
      final dp = t.positionDeltas;
      for (var i = 0; i < pos.length; i++) {
        pos[i] += dp[i] * w;
      }
      final dn = t.normalDeltas;
      if (dn != null) {
        normalsModified = true;
        for (var i = 0; i < norm.length; i++) {
          norm[i] += dn[i] * w;
        }
      }
    }

    if (renormalize && normalsModified) {
      for (var i = 0; i < norm.length; i += 3) {
        final nx = norm[i], ny = norm[i + 1], nz = norm[i + 2];
        final len = math.sqrt(nx * nx + ny * ny + nz * nz);
        if (len > 1e-6) {
          norm[i] = nx / len;
          norm[i + 1] = ny / len;
          norm[i + 2] = nz / len;
        }
      }
    }

    return Mesh(
      MeshArrays(pos, norm, idx, joints: base.joints, weights: base.weights),
      name: baseMesh.name,
    );
  }
}
