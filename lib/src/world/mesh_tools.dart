import 'dart:math' as math;
import 'dart:typed_data';

import '../math/vec.dart';

/// Vertex data for a triangle mesh: positions, smooth normals and indices.
class MeshArrays {
  MeshArrays(this.positions, this.normals, this.indices, {this.uvs, this.joints, this.weights})
    : assert((joints == null) == (weights == null), 'joints and weights come together'),
      assert(uvs == null || uvs.length == (positions.length ~/ 3) * 2, 'uvs must have 2 floats per vertex');

  /// x, y, z per vertex.
  final Float32List positions;

  /// x, y, z per vertex, unit length, pointing outward.
  final Float32List normals;

  /// Three indices per triangle.
  final List<int> indices;

  /// Optional texture coordinates (u, v per vertex, 0..1).
  final Float32List? uvs;

  /// Bone data for animated characters: 4 bone numbers per vertex, and 4
  /// matching weights (they add up to 1). Both null for normal meshes.
  final Uint8List? joints;
  final Float32List? weights;

  bool get isSkinned => joints != null;

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => indices.length ~/ 3;
}

/// Makes smooth shapes from rings. Pure math, no engine needed, so it can be
/// tested and run in an isolate.
///
/// A *ring* is a closed loop of points. Rings placed one after another form a
/// tube (a "loft"). Bottles, vases, hulls and pipes are all lofts.
class MeshTools {
  const MeshTools._();

  /// Joins [rings] into a smooth closed surface. All rings need the same
  /// number of points. [capStart] and [capEnd] close the two ends.
  static MeshArrays loft(
    List<List<Vector3>> rings, {
    bool capStart = true,
    bool capEnd = true,
  }) {
    assert(rings.length >= 2);
    final k = rings.first.length;
    assert(k >= 3);
    final verts = <Vector3>[];
    final idx = <int>[];

    for (final r in rings) {
      assert(r.length == k);
      for (final p in r) {
        verts.add(p.clone());
      }
    }
    for (var i = 0; i < rings.length - 1; i++) {
      for (var j = 0; j < k; j++) {
        final j1 = (j + 1) % k;
        final a = i * k + j;
        final b = i * k + j1;
        final c = (i + 1) * k + j1;
        final d = (i + 1) * k + j;
        idx.addAll([a, b, c, a, c, d]);
      }
    }

    void cap(List<Vector3> ring, bool flip) {
      final base = verts.length;
      final center = Vector3.zero();
      for (final p in ring) {
        verts.add(p.clone());
        center.add(p);
      }
      center.scale(1.0 / k);
      verts.add(center);
      final ci = base + k;
      for (var j = 0; j < k; j++) {
        final j1 = (j + 1) % k;
        if (flip) {
          idx.addAll([base + j1, base + j, ci]);
        } else {
          idx.addAll([base + j, base + j1, ci]);
        }
      }
    }

    if (capStart) cap(rings.first, true);
    if (capEnd) cap(rings.last, false);

    // Make the triangles face outward whatever the ring direction was.
    if (_volume(verts, idx) < 0) {
      for (var t = 0; t < idx.length; t += 3) {
        final tmp = idx[t + 1];
        idx[t + 1] = idx[t + 2];
        idx[t + 2] = tmp;
      }
    }
    return _finish(verts, idx);
  }

  /// A closed loop shaped between an ellipse and a rounded box, in the XY
  /// plane. [n] = 2 is an ellipse, bigger is boxier. Returns [k] points.
  static List<Vector2> superellipse(
    double cx,
    double cy,
    double halfWidth,
    double halfHeight, {
    double n = 3.0,
    int k = 32,
  }) {
    final out = <Vector2>[];
    for (var j = 0; j < k; j++) {
      final t = 2 * math.pi * j / k;
      final c = math.cos(t);
      final s = math.sin(t);
      out.add(
        Vector2(
          cx + halfWidth * c.sign * math.pow(c.abs(), 2 / n),
          cy + halfHeight * s.sign * math.pow(s.abs(), 2 / n),
        ),
      );
    }
    return out;
  }

  /// Spins a [profile] of (position along the X axis, radius) around the X
  /// axis. Use it for bottles, vases, rings and columns.
  static MeshArrays lathe(
    List<(double axial, double radius)> profile, {
    int segments = 32,
    bool capStart = true,
    bool capEnd = true,
  }) {
    final rings = <List<Vector3>>[
      for (final (a, r) in profile)
        [
          for (var j = 0; j < segments; j++)
            Vector3(
              a,
              r * math.cos(2 * math.pi * j / segments),
              r * math.sin(2 * math.pi * j / segments),
            ),
        ],
    ];
    return loft(rings, capStart: capStart, capEnd: capEnd);
  }

  /// A smooth ellipsoid with the given radii.
  static MeshArrays ellipsoid(
    Vector3 radii, {
    int rings = 10,
    int segments = 18,
  }) {
    final rs = <List<Vector3>>[];
    for (var i = 1; i < rings; i++) {
      final ph = math.pi * i / rings;
      final z = radii.z * math.cos(ph);
      final rr = math.sin(ph);
      rs.add([
        for (var j = 0; j < segments; j++)
          Vector3(
            radii.x * rr * math.cos(2 * math.pi * j / segments),
            radii.y * rr * math.sin(2 * math.pi * j / segments),
            z,
          ),
      ]);
    }
    return loft(rs);
  }

  /// Volume enclosed by a closed mesh. Positive when triangles face outward.
  static double volume(MeshArrays m) {
    final v = <Vector3>[
      for (var i = 0; i < m.positions.length; i += 3)
        Vector3(m.positions[i], m.positions[i + 1], m.positions[i + 2]),
    ];
    return _volume(v, m.indices);
  }

  static double _volume(List<Vector3> v, List<int> idx) {
    var sum = 0.0;
    for (var t = 0; t < idx.length; t += 3) {
      final a = v[idx[t]];
      final b = v[idx[t + 1]];
      final c = v[idx[t + 2]];
      sum += a.dot(b.cross(c));
    }
    return sum / 6.0;
  }

  static MeshArrays _finish(List<Vector3> verts, List<int> idx) {
    final normals = List<Vector3>.generate(verts.length, (_) => Vector3.zero());
    for (var t = 0; t < idx.length; t += 3) {
      final a = verts[idx[t]];
      final b = verts[idx[t + 1]];
      final c = verts[idx[t + 2]];
      final fn = (b - a).cross(c - a);
      normals[idx[t]].add(fn);
      normals[idx[t + 1]].add(fn);
      normals[idx[t + 2]].add(fn);
    }
    final pos = Float32List(verts.length * 3);
    final nor = Float32List(verts.length * 3);
    for (var i = 0; i < verts.length; i++) {
      final n = normals[i];
      if (n.length2 > 0) n.normalize();
      pos[i * 3] = verts[i].x;
      pos[i * 3 + 1] = verts[i].y;
      pos[i * 3 + 2] = verts[i].z;
      nor[i * 3] = n.x;
      nor[i * 3 + 1] = n.y;
      nor[i * 3 + 2] = n.z;
    }
    return MeshArrays(pos, nor, idx);
  }
}
