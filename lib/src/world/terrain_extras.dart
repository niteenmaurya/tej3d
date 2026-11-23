/// Terrain splatmap texture painting (4-layer RGBA blending) and procedural
/// foliage scattering (trees, grass, rocks) filtered by height and slope.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../math/vec.dart';
import 'terrain.dart';

/// 4-channel texture weight map (layers 0..3: e.g. grass, dirt, rock, snow)
/// painted over a [Terrain] with normalized weights summing to 1.0.
class TerrainSplatMap {
  TerrainSplatMap({
    required this.width,
    required this.height,
    int defaultLayer = 0,
  }) : weights = Float32List(width * height * 4) {
    final l = defaultLayer.clamp(0, 3);
    for (var i = 0; i < width * height; i++) {
      weights[i * 4 + l] = 1.0;
    }
  }

  final int width;
  final int height;

  /// Interleaved 4 floats per texel (layer 0, 1, 2, 3).
  final Float32List weights;

  /// Paints [layer] (0..3) at normalized UV `(u, v)` in `0..1` with a soft
  /// circular brush of normalized [radius] and [strength] (0..1).
  void paint(double u, double v, int layer, {double radius = 0.1, double strength = 0.5}) {
    final l = layer.clamp(0, 3);
    final cx = u * (width - 1);
    final cz = v * (height - 1);
    final rPx = radius * math.max(width, height);
    final x0 = math.max(0, (cx - rPx).floor());
    final x1 = math.min(width - 1, (cx + rPx).ceil());
    final z0 = math.max(0, (cz - rPx).floor());
    final z1 = math.min(height - 1, (cz + rPx).ceil());

    for (var z = z0; z <= z1; z++) {
      for (var x = x0; x <= x1; x++) {
        final d = math.sqrt((x - cx) * (x - cx) + (z - cz) * (z - cz));
        if (d > rPx) continue;
        final falloff = 1.0 - (d / math.max(1e-5, rPx));
        final add = (falloff * strength).clamp(0.0, 1.0).toDouble();
        final base = (z * width + x) * 4;
        final cur = weights[base + l];
        final target = (cur + add).clamp(0.0, 1.0).toDouble();
        final delta = target - cur;
        if (delta <= 0) continue;
        weights[base + l] = target;
        // Renormalize remaining channels so sum stays 1.0
        var others = 0.0;
        for (var c = 0; c < 4; c++) {
          if (c != l) others += weights[base + c];
        }
        final remain = math.max(0.0, 1.0 - target);
        if (others > 1e-6) {
          final scale = remain / others;
          for (var c = 0; c < 4; c++) {
            if (c != l) weights[base + c] *= scale;
          }
        }
      }
    }
  }

  Vector4 sample(double u, double v) {
    final x = (u.clamp(0.0, 1.0) * (width - 1)).round();
    final z = (v.clamp(0.0, 1.0) * (height - 1)).round();
    final base = (z * width + x) * 4;
    return Vector4(weights[base], weights[base + 1], weights[base + 2], weights[base + 3]);
  }
}

/// One placed foliage item (tree, bush, grass tuft) on a [Terrain].
class FoliageInstance {
  const FoliageInstance({
    required this.position,
    required this.yawRadians,
    required this.scale,
  });

  final Vector3 position;
  final double yawRadians;
  final double scale;

  Matrix4 toMatrix() {
    final m = Matrix4.identity();
    m.setTranslation(position);
    return m;
  }
}

/// Procedurally scatters foliage instances on a [Terrain] respecting height
/// bounds and maximum walkable slope.
class TerrainFoliage {
  const TerrainFoliage._();

  static List<FoliageInstance> scatter(
    Terrain terrain, {
    required int count,
    double minHeight = -double.infinity,
    double maxHeight = double.infinity,
    double maxSlopeDegrees = 35.0,
    double minScale = 0.8,
    double maxScale = 1.2,
    int seed = 42,
  }) {
    final rng = math.Random(seed);
    final out = <FoliageInstance>[];
    final maxSlopeRad = maxSlopeDegrees * math.pi / 180.0;
    final maxAttempts = count * 6;
    final halfW = terrain.sizeX * 0.5;
    final halfZ = terrain.sizeZ * 0.5;

    for (var i = 0; i < maxAttempts && out.length < count; i++) {
      final x = (rng.nextDouble() * 2 - 1) * halfW;
      final z = (rng.nextDouble() * 2 - 1) * halfZ;
      final y = terrain.heightAt(x, z);
      if (y < minHeight || y > maxHeight) continue;
      if (math.acos(terrain.normalAt(x, z).y.clamp(-1.0, 1.0)) > maxSlopeRad) continue;
      final sc = minScale + rng.nextDouble() * (maxScale - minScale);
      out.add(FoliageInstance(
        position: Vector3(x, y, z),
        yawRadians: rng.nextDouble() * math.pi * 2,
        scale: sc,
      ));
    }
    return out;
  }
}
