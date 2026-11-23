import 'dart:math' as math;
import 'dart:typed_data';
import '../math/vec.dart';

/// Generated smooth-shaded 3D triangle mesh (interleaved 8 floats/vertex: pos3, norm3, uv2).
class SmoothMeshData {
  SmoothMeshData(this.vertices, this.indices);

  final Float32List vertices;
  final Uint32List indices;

  int get vertexCount => vertices.length ~/ 8;
  int get triangleCount => indices.length ~/ 3;
}

/// Pure-Dart smooth spline & cross-section lofting mesh builder for curved 3D geometry
/// (automotive bodies, fuselages, arches, tracks) with area-weighted smooth vertex normals.
class SplineMeshBuilder {
  /// Evaluates a Catmull-Rom spline at `t` in `[0, 1]` between `p1` and `p2`.
  static Vector3 catmullRom(Vector3 p0, Vector3 p1, Vector3 p2, Vector3 p3, double t) {
    final t2 = t * t;
    final t3 = t2 * t;
    return Vector3(
      0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3),
      0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3),
      0.5 * ((2 * p1.z) + (-p0.z + p2.z) * t + (2 * p0.z - 5 * p1.z + 4 * p2.z - p3.z) * t2 + (-p0.z + 3 * p1.z - 3 * p2.z + p3.z) * t3),
    );
  }

  /// Lofts a sequence of closed rings (each ring having the same vertex count) into a
  /// watertight smooth-shaded mesh with outward area-weighted vertex normals and UV coordinates.
  static SmoothMeshData loftRings(List<List<Vector3>> rings, {bool capEnds = true}) {
    if (rings.length < 2 || rings.first.length < 3) {
      throw ArgumentError('Need at least 2 rings with >= 3 points each.');
    }
    final cols = rings.first.length;
    final rows = rings.length;
    final pos = <Vector3>[];
    final uvs = <(double, double)>[];

    for (var r = 0; r < rows; r++) {
      final v = r / (rows - 1);
      for (var c = 0; c < cols; c++) {
        pos.add(rings[r][c]);
        uvs.add((c / cols, v));
      }
    }

    final idx = <int>[];
    for (var r = 0; r < rows - 1; r++) {
      for (var c = 0; c < cols; c++) {
        final cn = (c + 1) % cols;
        final a = r * cols + c;
        final b = r * cols + cn;
        final d = (r + 1) * cols + c;
        final e = (r + 1) * cols + cn;
        idx.addAll([a, d, b, b, d, e]);
      }
    }

    if (capEnds) {
      // Front cap
      final frontCenter = _centroid(rings.first);
      final fcIdx = pos.length;
      pos.add(frontCenter);
      uvs.add((0.5, 0.0));
      for (var c = 0; c < cols; c++) {
        idx.addAll([fcIdx, c, (c + 1) % cols]);
      }
      // Rear cap
      final backCenter = _centroid(rings.last);
      final bcIdx = pos.length;
      pos.add(backCenter);
      uvs.add((0.5, 1.0));
      final base = (rows - 1) * cols;
      for (var c = 0; c < cols; c++) {
        idx.addAll([bcIdx, base + (c + 1) % cols, base + c]);
      }
    }

    // Area-weighted smooth vertex normals
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

  /// Generates a smooth sculpted coupe body shell (curved hood, fenders, fastback roof)
  /// with zero flat-box primitives.
  static SmoothMeshData buildCurvedCoupeBody() {
    // (z, halfWidth, bottomY, beltY, roofY, roofWidthFactor)
    const stations = [
      (-2.22, 0.72, 0.24, 0.44, 0.48, 0.78),
      (-2.05, 0.90, 0.18, 0.56, 0.62, 0.80),
      (-1.55, 0.98, 0.16, 0.68, 0.74, 0.82),
      (-0.92, 0.96, 0.16, 0.74, 0.82, 0.80),
      (-0.28, 0.95, 0.16, 0.76, 1.24, 0.66),
      ( 0.45, 0.96, 0.16, 0.78, 1.26, 0.64),
      ( 1.22, 1.00, 0.17, 0.80, 1.02, 0.72),
      ( 1.85, 0.96, 0.19, 0.78, 0.84, 0.78),
      ( 2.20, 0.80, 0.24, 0.64, 0.70, 0.76),
    ];

    final rings = <List<Vector3>>[];
    for (final s in stations) {
      final (z, hw, by, belt, ry, rwf) = s;
      final rw = hw * rwf;
      final ring = <Vector3>[
        Vector3(0.0, by, z),
        Vector3(hw * 0.78, by + 0.02, z),
        Vector3(hw, by + (belt - by) * 0.35, z),
        Vector3(hw * 0.99, belt, z),
        Vector3(rw, belt + (ry - belt) * 0.75, z),
        Vector3(rw * 0.55, ry, z),
        Vector3(0.0, ry + 0.03, z),
        Vector3(-rw * 0.55, ry, z),
        Vector3(-rw, belt + (ry - belt) * 0.75, z),
        Vector3(-hw * 0.99, belt, z),
        Vector3(-hw, by + (belt - by) * 0.35, z),
        Vector3(-hw * 0.78, by + 0.02, z),
      ];
      rings.add(ring);
    }
    return loftRings(rings, capEnds: true);
  }

  static Vector3 _centroid(List<Vector3> pts) {
    var sum = Vector3.zero();
    for (final p in pts) {
      sum += p;
    }
    return sum * (1.0 / math.max(1, pts.length));
  }
}
