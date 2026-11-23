import 'dart:math' as math;
import 'dart:typed_data';

import 'material.dart';
import 'render_frame.dart';
import '../light.dart';

/// Triangles in screen pixels with a color per corner, far to near.
class RasterResult {
  RasterResult(this.positions, this.colors, this.triangleCount);

  /// x, y for each of the 3 corners of each triangle (6 numbers a triangle).
  final Float32List positions;

  /// ARGB for each corner (3 numbers a triangle).
  final Int32List colors;

  final int triangleCount;
}

/// Turns a [RenderFrame] into lit screen triangles in plain Dart. No GPU.
/// It does vertex lighting (ambient, sun, point lights, optional shine),
/// near plane clipping, back face culling and sorts triangles far to near
/// (painter's algorithm). It is made as a fallback that runs on every
/// platform, good for low poly scenes. A GPU backend replaces it later.
class SoftwareRasterizer {
  // Reused buffers.
  Float64List _clip = Float64List(0); // x y z w per vertex
  Float64List _col = Float64List(0); // r g b per vertex

  final List<double> _pos = [];
  final List<int> _colors = [];
  final List<double> _depth = [];

  RasterResult rasterize(RenderFrame frame, double width, double height) {
    _pos.clear();
    _colors.clear();
    _depth.clear();
    for (final item in frame.items) {
      if (item.shadowOnly) continue;
      _drawItem(frame, item, width, height);
    }
    final n = _depth.length;
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) => _depth[b].compareTo(_depth[a]));
    final pos = Float32List(n * 6);
    final col = Int32List(n * 3);
    for (var k = 0; k < n; k++) {
      final t = order[k];
      for (var i = 0; i < 6; i++) {
        pos[k * 6 + i] = _pos[t * 6 + i];
      }
      for (var i = 0; i < 3; i++) {
        col[k * 3 + i] = _colors[t * 3 + i];
      }
    }
    return RasterResult(pos, col, n);
  }

  void _ensure(int vertexCount) {
    if (_clip.length < vertexCount * 4) {
      _clip = Float64List(vertexCount * 4);
      _col = Float64List(vertexCount * 3);
    }
  }

  void _drawItem(RenderFrame f, DrawItem item, double w, double h) {
    final mesh = item.mesh.arrays;
    final vc = mesh.vertexCount;
    if (vc == 0) return;
    _ensure(vc);
    final world = item.world;
    final vp = f.viewProjection;
    final m = item.material;
    final e = world.storage; // column major
    final p = mesh.positions;
    final nrm = mesh.normals;
    final lights = f.lights;
    final cam = f.cameraPosition;

    // Compute inverse-transpose of the upper-left 3x3 world matrix for normals.
    final c00 = e[5] * e[10] - e[9] * e[6];
    final c10 = -(e[4] * e[10] - e[8] * e[6]);
    final c20 = e[4] * e[9] - e[8] * e[5];
    final c01 = -(e[1] * e[10] - e[9] * e[2]);
    final c11 = e[0] * e[10] - e[8] * e[2];
    final c21 = -(e[0] * e[9] - e[8] * e[1]);
    final c02 = e[1] * e[6] - e[5] * e[2];
    final c12 = -(e[0] * e[6] - e[4] * e[2]);
    final c22 = e[0] * e[5] - e[4] * e[1];
    final det = e[0] * c00 + e[1] * c10 + e[2] * c20;
    final double n00, n10, n20, n01, n11, n21, n02, n12, n22;
    if (det.abs() > 1e-12) {
      final id = 1.0 / det;
      n00 = c00 * id;
      n10 = c10 * id;
      n20 = c20 * id;
      n01 = c01 * id;
      n11 = c11 * id;
      n21 = c21 * id;
      n02 = c02 * id;
      n12 = c12 * id;
      n22 = c22 * id;
    } else {
      n00 = e[0];
      n10 = e[1];
      n20 = e[2];
      n01 = e[4];
      n11 = e[5];
      n21 = e[6];
      n02 = e[8];
      n12 = e[9];
      n22 = e[10];
    }

    for (var i = 0; i < vc; i++) {
      final x = p[i * 3], y = p[i * 3 + 1], z = p[i * 3 + 2];
      final wx = e[0] * x + e[4] * y + e[8] * z + e[12];
      final wy = e[1] * x + e[5] * y + e[9] * z + e[13];
      final wz = e[2] * x + e[6] * y + e[10] * z + e[14];
      final c = vp.storage;
      _clip[i * 4] = c[0] * wx + c[4] * wy + c[8] * wz + c[12];
      _clip[i * 4 + 1] = c[1] * wx + c[5] * wy + c[9] * wz + c[13];
      _clip[i * 4 + 2] = c[2] * wx + c[6] * wy + c[10] * wz + c[14];
      _clip[i * 4 + 3] = c[3] * wx + c[7] * wy + c[11] * wz + c[15];

      var r = m.emissive.x;
      var g = m.emissive.y;
      var b = m.emissive.z;
      if (m.unlit) {
        r += m.color.r;
        g += m.color.g;
        b += m.color.b;
      } else {
        // World normal via inverse-transpose 3x3 (handles non-uniform scale).
        final nx0 = nrm[i * 3], ny0 = nrm[i * 3 + 1], nz0 = nrm[i * 3 + 2];
        var nx = n00 * nx0 + n01 * ny0 + n02 * nz0;
        var ny = n10 * nx0 + n11 * ny0 + n12 * nz0;
        var nz = n20 * nx0 + n21 * ny0 + n22 * nz0;
        final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
        if (nl > 1e-12) {
          nx /= nl;
          ny /= nl;
          nz /= nl;
        }
        var dr = f.ambient.x, dg = f.ambient.y, db = f.ambient.z;
        var sr = 0.0, sg = 0.0, sb = 0.0;
        for (final l in lights) {
          double lx, ly, lz, att = 1.0;
          if (l.type == LightType.directional) {
            lx = -l.direction.x;
            ly = -l.direction.y;
            lz = -l.direction.z;
          } else {
            if (l.range <= 1e-6) continue;
            lx = l.position.x - wx;
            ly = l.position.y - wy;
            lz = l.position.z - wz;
            final d = math.sqrt(lx * lx + ly * ly + lz * lz);
            if (d < 1e-9) continue;
            lx /= d;
            ly /= d;
            lz /= d;
            final q = d / l.range;
            att = 1.0 / (1.0 + q * q);
          }
          final ndl = nx * lx + ny * ly + nz * lz;
          if (ndl <= 0.0) continue;
          dr += l.color.x * ndl * att;
          dg += l.color.y * ndl * att;
          db += l.color.z * ndl * att;
          if (m.specular > 0.0) {
            var vx = cam.x - wx, vy = cam.y - wy, vz = cam.z - wz;
            final vl = math.sqrt(vx * vx + vy * vy + vz * vz);
            if (vl > 1e-9) {
              vx /= vl;
              vy /= vl;
              vz /= vl;
            }
            var hx = lx + vx, hy = ly + vy, hz = lz + vz;
            final hl = math.sqrt(hx * hx + hy * hy + hz * hz);
            if (hl > 1e-9) {
              hx /= hl;
              hy /= hl;
              hz /= hl;
              final ndh = nx * hx + ny * hy + nz * hz;
              if (ndh > 0.0) {
                final s = math.pow(ndh, m.shininess).toDouble() *
                    m.specular *
                    att;
                sr += l.color.x * s;
                sg += l.color.y * s;
                sb += l.color.z * s;
              }
            }
          }
        }
        r += m.color.r * dr + sr;
        g += m.color.g * dg + sg;
        b += m.color.b * db + sb;
      }
      _col[i * 3] = r;
      _col[i * 3 + 1] = g;
      _col[i * 3 + 2] = b;
    }

    final alpha = ((m.alpha * m.color.a).clamp(0.0, 1.0) * 255.0).round();
    final idx = mesh.indices;
    for (var t = 0; t + 2 < idx.length; t += 3) {
      _triangle(idx[t], idx[t + 1], idx[t + 2], m.cull, alpha, w, h);
    }
  }

  // Polygon after clipping: up to 4 corners, each x y z w r g b.
  final List<List<double>> _poly = [];

  List<double> _vertex(int i) => [
    _clip[i * 4],
    _clip[i * 4 + 1],
    _clip[i * 4 + 2],
    _clip[i * 4 + 3],
    _col[i * 3],
    _col[i * 3 + 1],
    _col[i * 3 + 2],
  ];

  void _triangle(int a, int b, int c, CullMode cull, int alpha, double w, double h) {
    final xa = _clip[a * 4], ya = _clip[a * 4 + 1];
    final za = _clip[a * 4 + 2], wa = _clip[a * 4 + 3];
    final xb = _clip[b * 4], yb = _clip[b * 4 + 1];
    final zb = _clip[b * 4 + 2], wb = _clip[b * 4 + 3];
    final xc = _clip[c * 4], yc = _clip[c * 4 + 1];
    final zc = _clip[c * 4 + 2], wc = _clip[c * 4 + 3];

    // Trivially outside one side of the view: skip.
    if (xa > wa && xb > wb && xc > wc) return;
    if (xa < -wa && xb < -wb && xc < -wc) return;
    if (ya > wa && yb > wb && yc > wc) return;
    if (ya < -wa && yb < -wb && yc < -wc) return;
    if (za > wa && zb > wb && zc > wc) return;

    final da = za + wa, db = zb + wb, dc = zc + wc;
    if (da < 0.0 && db < 0.0 && dc < 0.0) return;

    _poly.clear();
    if (da >= 0.0 && db >= 0.0 && dc >= 0.0) {
      _poly
        ..add(_vertex(a))
        ..add(_vertex(b))
        ..add(_vertex(c));
    } else {
      // Clip against the near plane (z + w >= 0).
      final input = [_vertex(a), _vertex(b), _vertex(c)];
      final dist = [da, db, dc];
      for (var i = 0; i < 3; i++) {
        final j = (i + 1) % 3;
        final inI = dist[i] >= 0.0;
        final inJ = dist[j] >= 0.0;
        if (inI) _poly.add(input[i]);
        if (inI != inJ) {
          final t = dist[i] / (dist[i] - dist[j]);
          _poly.add([
            for (var k = 0; k < 7; k++)
              input[i][k] + (input[j][k] - input[i][k]) * t,
          ]);
        }
      }
      if (_poly.length < 3) return;
    }

    for (var k = 1; k + 1 < _poly.length; k++) {
      _emit(_poly[0], _poly[k], _poly[k + 1], cull, alpha, w, h);
    }
  }

  void _emit(
    List<double> v0,
    List<double> v1,
    List<double> v2,
    CullMode cull,
    int alpha,
    double w,
    double h,
  ) {
    if (v0[3].abs() < 1e-9 || v1[3].abs() < 1e-9 || v2[3].abs() < 1e-9) return;
    final i0 = 1.0 / v0[3], i1 = 1.0 / v1[3], i2 = 1.0 / v2[3];
    final x0 = v0[0] * i0, y0 = v0[1] * i0;
    final x1 = v1[0] * i1, y1 = v1[1] * i1;
    final x2 = v2[0] * i2, y2 = v2[1] * i2;
    final area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);
    if (cull == CullMode.back && area <= 0.0) return;
    if (cull == CullMode.front && area >= 0.0) return;
    if (area == 0.0) return;

    _pos.addAll([
      (x0 * 0.5 + 0.5) * w,
      (1.0 - (y0 * 0.5 + 0.5)) * h,
      (x1 * 0.5 + 0.5) * w,
      (1.0 - (y1 * 0.5 + 0.5)) * h,
      (x2 * 0.5 + 0.5) * w,
      (1.0 - (y2 * 0.5 + 0.5)) * h,
    ]);
    _colors
      ..add(_pack(v0, alpha))
      ..add(_pack(v1, alpha))
      ..add(_pack(v2, alpha));
    _depth.add((v0[2] * i0 + v1[2] * i1 + v2[2] * i2) / 3.0);
  }

  static int _pack(List<double> v, int alpha) {
    final r = (v[4].clamp(0.0, 1.0) * 255.0).round();
    final g = (v[5].clamp(0.0, 1.0) * 255.0).round();
    final b = (v[6].clamp(0.0, 1.0) * 255.0).round();
    return (alpha << 24) | (r << 16) | (g << 8) | b;
  }
}
