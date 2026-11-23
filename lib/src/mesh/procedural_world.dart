import 'dart:math' as math;
import 'dart:typed_data';
import '../math/vec.dart';
import 'spline_mesh.dart';

/// Universal procedural 3D environment mesh builders (trees, rocks, rolling terrain)
/// for any game genre built on flutter_tej3d (RPG, shooter, racing, flight, sandbox).
class ProceduralWorldMeshes {
  /// Builds a multi-tiered evergreen pine/fir tree canopy (stacked serrated cone tiers)
  /// with smooth outward vertex normals — no lollipop spheres.
  static SmoothMeshData buildPineCanopy({
    int tiers = 4,
    int radialSegments = 10,
    double baseRadius = 1.6,
    double totalHeight = 4.6,
    double startY = 1.4,
  }) {
    final pos = <Vector3>[];
    final uvs = <(double, double)>[];
    final idx = <int>[];

    for (var t = 0; t < tiers; t++) {
      final frac = t / tiers;
      final r = baseRadius * (1.0 - frac * 0.62);
      final yBot = startY + frac * (totalHeight * 0.68);
      final yTop = yBot + (totalHeight / tiers) * 1.45;
      final baseIdx = pos.length;

      // Apex
      pos.add(Vector3(0, yTop, 0));
      uvs.add((0.5, 1.0));
      // Serrated bough ring
      for (var s = 0; s < radialSegments; s++) {
        final ang = (s / radialSegments) * math.pi * 2.0 + t * 0.35;
        final flare = (s % 2 == 0) ? 1.0 : 0.80;
        pos.add(Vector3(math.cos(ang) * r * flare, yBot, math.sin(ang) * r * flare));
        uvs.add((s / radialSegments, 0.0));
      }
      for (var s = 0; s < radialSegments; s++) {
        final next = (s + 1) % radialSegments;
        idx.addAll([baseIdx, baseIdx + 1 + next, baseIdx + 1 + s]);
      }
    }
    return _packSmoothMesh(pos, uvs, idx);
  }

  /// Builds a sculpted organic boulder/rock mesh by displacing a UV sphere with
  /// deterministic multi-frequency trigonometric noise.
  static SmoothMeshData buildBoulder({
    double radius = 1.0,
    int segments = 12,
    int rings = 8,
    int seed = 7,
  }) {
    final pos = <Vector3>[];
    final uvs = <(double, double)>[];
    final idx = <int>[];

    for (var r = 0; r <= rings; r++) {
      final v = r / rings;
      final phi = v * math.pi;
      for (var s = 0; s <= segments; s++) {
        final u = s / segments;
        final theta = u * math.pi * 2.0;
        final dx = math.sin(phi) * math.cos(theta);
        final dy = math.cos(phi);
        final dz = math.sin(phi) * math.sin(theta);
        final n = 1.0 +
            0.18 * math.sin(dx * 3.1 + seed) * math.cos(dz * 2.7 - seed) +
            0.10 * math.cos(dy * 4.3 + dx * 2.1 + seed * 0.5);
        pos.add(Vector3(dx * radius * n, dy * radius * 0.78 * n, dz * radius * n));
        uvs.add((u, v));
      }
    }
    final stride = segments + 1;
    for (var r = 0; r < rings; r++) {
      for (var s = 0; s < segments; s++) {
        final a = r * stride + s;
        final b = a + 1;
        final c = (r + 1) * stride + s;
        final d = c + 1;
        idx.addAll([a, c, b, b, c, d]);
      }
    }
    return _packSmoothMesh(pos, uvs, idx);
  }

  /// Builds a smooth rolling 3D terrain mesh from any user-supplied `heightFn(x, z)`.
  static SmoothMeshData buildTerrain({
    required double width,
    required double depth,
    int segX = 32,
    int segZ = 32,
    required double Function(double x, double z) heightFn,
    double uvScale = 8.0,
  }) {
    final pos = <Vector3>[];
    final uvs = <(double, double)>[];
    final idx = <int>[];

    for (var iz = 0; iz <= segZ; iz++) {
      final fz = iz / segZ;
      final z = (fz - 0.5) * depth;
      for (var ix = 0; ix <= segX; ix++) {
        final fx = ix / segX;
        final x = (fx - 0.5) * width;
        pos.add(Vector3(x, heightFn(x, z), z));
        uvs.add((fx * uvScale, fz * uvScale));
      }
    }
    final stride = segX + 1;
    for (var iz = 0; iz < segZ; iz++) {
      for (var ix = 0; ix < segX; ix++) {
        final a = iz * stride + ix;
        final b = a + 1;
        final c = (iz + 1) * stride + ix;
        final d = c + 1;
        idx.addAll([a, c, b, b, c, d]);
      }
    }
    return _packSmoothMesh(pos, uvs, idx);
  }

  static SmoothMeshData _packSmoothMesh(
    List<Vector3> pos,
    List<(double, double)> uvs,
    List<int> idx,
  ) {
    final norms = List<Vector3>.generate(pos.length, (_) => Vector3.zero());
    for (var i = 0; i < idx.length; i += 3) {
      final p0 = pos[idx[i]];
      final p1 = pos[idx[i + 1]];
      final p2 = pos[idx[i + 2]];
      final fn = (p1 - p0).cross(p2 - p0);
      norms[idx[i]] += fn;
      norms[idx[i + 1]] += fn;
      norms[idx[i + 2]] += fn;
    }
    final verts = Float32List(pos.length * 8);
    for (var i = 0; i < pos.length; i++) {
      final n = norms[i].length2 > 1e-10 ? norms[i].normalized() : Vector3(0, 1, 0);
      final o = i * 8;
      verts[o] = pos[i].x;
      verts[o + 1] = pos[i].y;
      verts[o + 2] = pos[i].z;
      verts[o + 3] = n.x;
      verts[o + 4] = n.y;
      verts[o + 5] = n.z;
      verts[o + 6] = uvs[i].$1;
      verts[o + 7] = uvs[i].$2;
    }
    return SmoothMeshData(verts, Uint32List.fromList(idx));
  }
}
