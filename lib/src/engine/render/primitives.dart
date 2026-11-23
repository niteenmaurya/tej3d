import 'dart:math' as math;
import 'dart:typed_data';

import '../../math/vec.dart';

import '../../world/mesh_tools.dart';
import 'mesh.dart';

/// Ready shapes: box, plane, sphere, cylinder (all with positions, normals and UVs).
class Primitives {
  Primitives._();

  /// A box centered on the origin. [size] is the full width, height, depth.
  static Mesh box(Vector3 size) {
    final h = size * 0.5;
    final pos = <double>[];
    final nor = <double>[];
    final uv = <double>[];
    final idx = <int>[];
    // normal, u, v (u x v = normal, so corners are counter-clockwise)
    final faces = <List<Vector3>>[
      [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)],
      [Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
      [Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)],
      [Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
      [Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
      [Vector3(0, 0, -1), Vector3(0, 1, 0), Vector3(1, 0, 0)],
    ];
    const corners = [
      [-1.0, -1.0],
      [1.0, -1.0],
      [1.0, 1.0],
      [-1.0, 1.0],
    ];
    const cornerUvs = [
      [0.0, 0.0],
      [1.0, 0.0],
      [1.0, 1.0],
      [0.0, 1.0],
    ];
    for (final f in faces) {
      final n = f[0], u = f[1], v = f[2];
      final base = pos.length ~/ 3;
      for (var ci = 0; ci < 4; ci++) {
        final c = corners[ci];
        final p = Vector3(
          (n.x + u.x * c[0] + v.x * c[1]) * h.x,
          (n.y + u.y * c[0] + v.y * c[1]) * h.y,
          (n.z + u.z * c[0] + v.z * c[1]) * h.z,
        );
        pos.addAll([p.x, p.y, p.z]);
        nor.addAll([n.x, n.y, n.z]);
        uv.addAll(cornerUvs[ci]);
      }
      idx.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
    }
    return Mesh(_arrays(pos, nor, idx, uv), name: 'box');
  }

  /// A flat floor on the XZ plane, facing up, centered on the origin.
  /// Use more [segments] for big floors: the software renderer sorts by
  /// triangle, so one huge triangle can draw over things behind it.
  static Mesh plane(double width, double depth, {int segments = 1}) {
    final n = math.max(1, segments);
    final pos = <double>[];
    final nor = <double>[];
    final uv = <double>[];
    final idx = <int>[];
    for (var i = 0; i <= n; i++) {
      for (var j = 0; j <= n; j++) {
        pos.addAll([(j / n - 0.5) * width, 0.0, (i / n - 0.5) * depth]);
        nor.addAll([0.0, 1.0, 0.0]);
        uv.addAll([j / n, i / n]);
      }
    }
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        final a = i * (n + 1) + j; // (x0, z0)
        final b = (i + 1) * (n + 1) + j; // (x0, z1)
        final c = i * (n + 1) + j + 1; // (x1, z0)
        final d = (i + 1) * (n + 1) + j + 1; // (x1, z1)
        idx.addAll([a, b, c, b, d, c]);
      }
    }
    return Mesh(_arrays(pos, nor, idx, uv), name: 'plane');
  }

  static Mesh sphere(double radius, {int rings = 12, int sectors = 20}) {
    final pos = <double>[];
    final nor = <double>[];
    final uv = <double>[];
    final idx = <int>[];
    for (var i = 0; i <= rings; i++) {
      final theta = math.pi * i / rings;
      for (var j = 0; j <= sectors; j++) {
        final phi = 2.0 * math.pi * j / sectors;
        final nx = math.sin(theta) * math.cos(phi);
        final ny = math.cos(theta);
        final nz = math.sin(theta) * math.sin(phi);
        pos.addAll([nx * radius, ny * radius, nz * radius]);
        nor.addAll([nx, ny, nz]);
        uv.addAll([j / sectors, i / rings]);
      }
    }
    for (var i = 0; i < rings; i++) {
      for (var j = 0; j < sectors; j++) {
        final a = i * (sectors + 1) + j;
        final b = (i + 1) * (sectors + 1) + j;
        final c = b + 1;
        final d = a + 1;
        idx.addAll([a, d, c, a, c, b]);
      }
    }
    return Mesh(_arrays(pos, nor, idx, uv), name: 'sphere');
  }

  /// A cylinder standing on the Y axis, centered on the origin.
  static Mesh cylinder(double radius, double height, {int sides = 20}) {
    final pos = <double>[];
    final nor = <double>[];
    final uv = <double>[];
    final idx = <int>[];
    final hy = height / 2.0;
    for (var i = 0; i <= sides; i++) {
      final phi = 2.0 * math.pi * i / sides;
      final c = math.cos(phi);
      final s = math.sin(phi);
      final u = i / sides;
      pos.addAll([c * radius, hy, s * radius]);
      nor.addAll([c, 0.0, s]);
      uv.addAll([u, 1.0]);
      pos.addAll([c * radius, -hy, s * radius]);
      nor.addAll([c, 0.0, s]);
      uv.addAll([u, 0.0]);
    }
    for (var i = 0; i < sides; i++) {
      final a = i * 2; // top i
      final b = a + 1; // bottom i
      final d = a + 2; // top i+1
      final c = a + 3; // bottom i+1
      idx.addAll([a, d, c, a, c, b]);
    }
    // caps
    for (final top in [true, false]) {
      final y = top ? hy : -hy;
      final ny = top ? 1.0 : -1.0;
      final center = pos.length ~/ 3;
      pos.addAll([0.0, y, 0.0]);
      nor.addAll([0.0, ny, 0.0]);
      uv.addAll([0.5, 0.5]);
      for (var i = 0; i <= sides; i++) {
        final phi = 2.0 * math.pi * i / sides;
        final c = math.cos(phi);
        final s = math.sin(phi);
        pos.addAll([c * radius, y, s * radius]);
        nor.addAll([0.0, ny, 0.0]);
        uv.addAll([0.5 + 0.5 * c, 0.5 + 0.5 * s]);
      }
      for (var i = 0; i < sides; i++) {
        final p0 = center + 1 + i;
        final p1 = p0 + 1;
        if (top) {
          idx.addAll([center, p1, p0]);
        } else {
          idx.addAll([center, p0, p1]);
        }
      }
    }
    return Mesh(_arrays(pos, nor, idx, uv), name: 'cylinder');
  }

  static MeshArrays _arrays(List<double> p, List<double> n, List<int> i, List<double> uv) =>
      MeshArrays(Float32List.fromList(p), Float32List.fromList(n), i, uvs: Float32List.fromList(uv));
}
