/// Level of Detail ([LODGroup]) and GPU Instancing ([InstancedMeshRenderer]).
library;

import 'dart:math' as math;

import '../math/vec.dart';
import 'game_object.dart';
import 'render/material.dart';
import 'render/mesh.dart';

/// One detail tier inside a [LODGroup].
class LODLevel {
  const LODLevel({
    required this.maxDistance,
    required this.mesh,
    this.material,
  });

  /// Maximum camera distance (meters) at which this mesh is selected.
  final double maxDistance;
  final Mesh mesh;
  final StandardMaterial? material;
}

/// Switches mesh detail automatically based on camera distance (Unity LODGroup).
class LODGroup extends Component {
  LODGroup(List<LODLevel> levels, {this.cullDistance = double.infinity, this.bias = 1.0})
      : levels = List<LODLevel>.from(levels)
          ..sort((a, b) => a.maxDistance.compareTo(b.maxDistance));

  final List<LODLevel> levels;

  /// Beyond this distance, the object is culled (returns null).
  double cullDistance;

  /// Global LOD bias (> 1 keeps higher detail further away).
  double bias;

  /// Returns the appropriate [LODLevel] for [cameraPosition], or null if culled.
  LODLevel? selectForCamera(Vector3 cameraPosition) {
    final dist = (transform.worldPosition - cameraPosition).length / math.max(0.01, bias);
    if (dist > cullDistance || levels.isEmpty) return null;
    for (final lvl in levels) {
      if (dist <= lvl.maxDistance) return lvl;
    }
    return levels.last;
  }
}

/// One instance inside an [InstancedMeshRenderer].
class MeshInstance {
  MeshInstance({
    required this.transform,
    Vector4? color,
  }) : color = color?.clone() ?? Vector4(1, 1, 1, 1);

  Matrix4 transform;
  Vector4 color;
}

/// Batches many identical meshes (trees, grass, rocks, debris) into one
/// GPU-instanced draw group with per-instance transform and tint color.
class InstancedMeshRenderer extends Component {
  InstancedMeshRenderer(
    this.mesh, {
    StandardMaterial? material,
    List<MeshInstance>? instances,
    this.castShadows = true,
    this.receiveShadows = true,
  })  : material = material ?? StandardMaterial(),
        instances = instances != null ? List<MeshInstance>.from(instances) : [];

  Mesh mesh;
  StandardMaterial material;
  final List<MeshInstance> instances;
  bool castShadows;
  bool receiveShadows;

  int get instanceCount => instances.length;

  void addInstance(Matrix4 worldTransform, {Vector4? color}) {
    instances.add(MeshInstance(transform: worldTransform, color: color));
  }

  void clearInstances() => instances.clear();

  /// Returns only instances whose transformed bounding box intersects [frustum].
  List<MeshInstance> cullFrustum(Frustum frustum) {
    final visible = <MeshInstance>[];
    for (final inst in instances) {
      final box = Aabb3.copy(mesh.bounds)..transform(inst.transform);
      if (frustum.intersectsWithAabb3(box)) visible.add(inst);
    }
    return visible;
  }
}
