/// Ribbon trail renderer and particle texture atlas / sub-emitter helpers.
library;

import 'dart:typed_data';

import '../math/vec.dart';
import '../world/mesh_tools.dart';
import 'game_object.dart';
import 'render/mesh.dart';

class _TrailPoint {
  _TrailPoint(this.pos, this.age);
  final Vector3 pos;
  double age;
}

/// Leaves a smooth camera-facing ribbon trail behind a moving [GameObject]
/// (sword swings, projectiles, tire tracks, contrails).
class TrailRenderer extends Component {
  TrailRenderer({
    this.lifetime = 0.6,
    this.minVertexDistance = 0.1,
    this.startWidth = 0.3,
    this.endWidth = 0.02,
    this.emitting = true,
  });

  double lifetime;
  double minVertexDistance;
  double startWidth;
  double endWidth;
  bool emitting;

  final List<_TrailPoint> _points = [];

  int get pointCount => _points.length;

  void clear() => _points.clear();

  @override
  void update(double dt) {
    for (final p in _points) {
      p.age += dt;
    }
    _points.removeWhere((p) => p.age >= lifetime);

    if (emitting) {
      final cur = transform.worldPosition;
      if (_points.isEmpty || (cur - _points.last.pos).length >= minVertexDistance) {
        _points.add(_TrailPoint(cur.clone(), 0.0));
      }
    }
  }

  /// Builds a triangle-strip ribbon [Mesh] facing [cameraPosition].
  Mesh? buildMesh(Vector3 cameraPosition) {
    if (_points.length < 2) return null;
    final n = _points.length;
    final pos = Float32List(n * 2 * 3);
    final norm = Float32List(n * 2 * 3);
    final idx = Uint32List((n - 1) * 6);

    for (var i = 0; i < n; i++) {
      final p = _points[i];
      final t = (p.age / lifetime).clamp(0.0, 1.0).toDouble();
      final halfW = (startWidth * (1.0 - t) + endWidth * t) * 0.5;
      final tangent = i == 0
          ? (_points[1].pos - p.pos).normalized()
          : (p.pos - _points[i - 1].pos).normalized();
      final toCam = (cameraPosition - p.pos).normalized();
      var side = tangent.cross(toCam);
      if (side.length2 < 1e-8) side = Vector3(1, 0, 0);
      side.normalize();

      final left = p.pos - side * halfW;
      final right = p.pos + side * halfW;

      final b0 = (i * 2) * 3;
      pos[b0] = left.x;
      pos[b0 + 1] = left.y;
      pos[b0 + 2] = left.z;
      norm[b0] = toCam.x;
      norm[b0 + 1] = toCam.y;
      norm[b0 + 2] = toCam.z;

      final b1 = (i * 2 + 1) * 3;
      pos[b1] = right.x;
      pos[b1 + 1] = right.y;
      pos[b1 + 2] = right.z;
      norm[b1] = toCam.x;
      norm[b1 + 1] = toCam.y;
      norm[b1 + 2] = toCam.z;
    }

    var k = 0;
    for (var i = 0; i < n - 1; i++) {
      final v0 = i * 2;
      final v1 = v0 + 1;
      final v2 = v0 + 2;
      final v3 = v0 + 3;
      idx[k++] = v0;
      idx[k++] = v2;
      idx[k++] = v1;
      idx[k++] = v1;
      idx[k++] = v2;
      idx[k++] = v3;
    }

    return Mesh(MeshArrays(pos, norm, idx), name: 'trail');
  }
}

/// UV frame calculator for animated sprite-sheet particle atlases.
class SpriteSheetConfig {
  const SpriteSheetConfig({required this.columns, required this.rows});

  final int columns;
  final int rows;

  int get totalFrames => columns * rows;

  /// Returns `(u0, v0, u1, v1)` for normalized particle lifetime `t` in `0..1`.
  (double, double, double, double) uvRectAt(double normalizedTime) {
    final idx = (normalizedTime.clamp(0.0, 0.9999) * totalFrames).floor();
    final col = idx % columns;
    final row = idx ~/ columns;
    final du = 1.0 / columns;
    final dv = 1.0 / rows;
    return (col * du, row * dv, (col + 1) * du, (row + 1) * dv);
  }
}
