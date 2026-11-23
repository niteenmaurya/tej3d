import '../../math/vec.dart';

import '../../world/mesh_tools.dart';

/// Triangle geometry plus its bounding box. Triangles must be wound
/// counter-clockwise when seen from outside.
class Mesh {
  Mesh(this.arrays, {this.name = ''}) : bounds = _bounds(arrays);

  final MeshArrays arrays;
  final String name;

  /// Box around all vertices, in the mesh's own space.
  final Aabb3 bounds;

  int get vertexCount => arrays.vertexCount;
  int get triangleCount => arrays.triangleCount;

  static Aabb3 _bounds(MeshArrays a) {
    if (a.vertexCount == 0) return Aabb3();
    final p = a.positions;
    var minX = p[0], minY = p[1], minZ = p[2];
    var maxX = minX, maxY = minY, maxZ = minZ;
    for (var i = 3; i < p.length; i += 3) {
      if (p[i] < minX) minX = p[i];
      if (p[i] > maxX) maxX = p[i];
      if (p[i + 1] < minY) minY = p[i + 1];
      if (p[i + 1] > maxY) maxY = p[i + 1];
      if (p[i + 2] < minZ) minZ = p[i + 2];
      if (p[i + 2] > maxZ) maxZ = p[i + 2];
    }
    return Aabb3.minMax(
      Vector3(minX, minY, minZ),
      Vector3(maxX, maxY, maxZ),
    );
  }
}
