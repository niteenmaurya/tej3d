import 'dart:math' as math;
import 'dart:typed_data';

import '../math/vec.dart';

import '../engine/render/mesh.dart';
import '../math/mathf.dart';
import 'mesh_tools.dart';

/// A height map: a grid of heights that makes hills and valleys.
///
/// Heights are stored in [heights], row by row (`index = z * countX + x`).
/// Point (0, 0) of the grid is at [origin]; grid points are [cellSize] meters
/// apart. The ground is made of triangles, and [heightAt] gives the exact
/// height of those triangles, so a character or a ball standing on the mesh
/// stands where [heightAt] says.
///
/// ```dart
/// final terrain = Terrain.fromNoise(countX: 129, countZ: 129, cellSize: 1, amplitude: 12, seed: 3);
/// final mesh = terrain.buildMesh();
/// ground.addComponent(MeshRenderer(mesh));
/// ground.addComponent(NativeMeshCollider(physics, mesh));   // walk and fall on it
/// hero.transform.localPosition.y = terrain.heightAt(x, z);
/// ```
///
/// Big terrains are best split with [buildChunks]: every chunk is a mesh of
/// its own, so the engine can skip chunks outside the view.
class Terrain {
  Terrain({
    required this.countX,
    required this.countZ,
    required this.heights,
    this.cellSize = 1.0,
    Vector3? origin,
  })  : origin = origin ?? Vector3.zero(),
        assert(countX >= 2 && countZ >= 2, 'a terrain needs at least 2 x 2 points'),
        assert(heights.length == countX * countZ, 'heights must have countX * countZ values');

  /// Flat ground at height 0.
  factory Terrain.flat({required int countX, required int countZ, double cellSize = 1.0, Vector3? origin}) =>
      Terrain(countX: countX, countZ: countZ, heights: Float32List(countX * countZ), cellSize: cellSize, origin: origin);

  /// Rolling hills from smooth noise. [scale] is the size of the hills in
  /// meters; [octaves] adds finer bumps on top.
  factory Terrain.fromNoise({
    required int countX,
    required int countZ,
    double cellSize = 1.0,
    double amplitude = 10.0,
    double scale = 40.0,
    int octaves = 3,
    int seed = 0,
    Vector3? origin,
  }) {
    final noise = PerlinNoise(seed);
    final h = Float32List(countX * countZ);
    for (var z = 0; z < countZ; z++) {
      for (var x = 0; x < countX; x++) {
        var v = 0.0, amp = 1.0, freq = 1.0, norm = 0.0;
        for (var o = 0; o < octaves; o++) {
          v += amp * noise.noise2(x * cellSize / scale * freq, z * cellSize / scale * freq);
          norm += amp;
          amp *= 0.5;
          freq *= 2.0;
        }
        h[z * countX + x] = (v / norm) * amplitude;
      }
    }
    return Terrain(countX: countX, countZ: countZ, heights: h, cellSize: cellSize, origin: origin);
  }

  /// From 8-bit gray values (for example a gray height map picture): 0 is
  /// [minHeight], 255 is [maxHeight].
  factory Terrain.fromGray8({
    required int countX,
    required int countZ,
    required Uint8List gray,
    double cellSize = 1.0,
    double minHeight = 0.0,
    double maxHeight = 20.0,
    Vector3? origin,
  }) {
    assert(gray.length == countX * countZ);
    final h = Float32List(countX * countZ);
    for (var i = 0; i < h.length; i++) {
      h[i] = minHeight + (maxHeight - minHeight) * gray[i] / 255.0;
    }
    return Terrain(countX: countX, countZ: countZ, heights: h, cellSize: cellSize, origin: origin);
  }

  final int countX, countZ;
  final Float32List heights;
  final double cellSize;
  final Vector3 origin;

  /// Size in meters.
  double get sizeX => (countX - 1) * cellSize;
  double get sizeZ => (countZ - 1) * cellSize;

  double heightAtGrid(int x, int z) =>
      heights[z.clamp(0, countZ - 1) * countX + x.clamp(0, countX - 1)];

  void setHeightAtGrid(int x, int z, double h) {
    heights[z * countX + x] = h;
  }

  /// True if the world point (x, z) is over the terrain.
  bool contains(double x, double z) {
    final lx = x - origin.x, lz = z - origin.z;
    return lx >= 0 && lz >= 0 && lx <= sizeX && lz <= sizeZ;
  }

  /// World height of the ground at (x, z). Outside the terrain the nearest
  /// edge height is used. The result matches the mesh triangles exactly.
  double heightAt(double x, double z) {
    final fx = ((x - origin.x) / cellSize).clamp(0.0, (countX - 1).toDouble());
    final fz = ((z - origin.z) / cellSize).clamp(0.0, (countZ - 1).toDouble());
    var ix = fx.floor(), iz = fz.floor();
    if (ix >= countX - 1) ix = countX - 2;
    if (iz >= countZ - 1) iz = countZ - 2;
    final u = fx - ix, v = fz - iz;
    final h00 = heights[iz * countX + ix];
    final h10 = heights[iz * countX + ix + 1];
    final h01 = heights[(iz + 1) * countX + ix];
    final h11 = heights[(iz + 1) * countX + ix + 1];
    // Each cell is two triangles split along the diagonal (0,0)-(1,1), the same as buildMesh.
    final h = u >= v ? h00 + (h10 - h00) * u + (h11 - h10) * v : h00 + (h11 - h01) * u + (h01 - h00) * v;
    return origin.y + h;
  }

  /// Surface normal (unit, pointing up) at (x, z).
  Vector3 normalAt(double x, double z) {
    final e = cellSize * 0.5;
    final dx = heightAt(x + e, z) - heightAt(x - e, z);
    final dz = heightAt(x, z + e) - heightAt(x, z - e);
    return Vector3(-dx, 2 * e, -dz).normalized();
  }

  /// Steepness in degrees at (x, z): 0 flat, 90 a wall.
  double slopeDegreesAt(double x, double z) =>
      math.acos(normalAt(x, z).y.clamp(-1.0, 1.0)) * 180.0 / math.pi;

  /// Highest and lowest height of the whole terrain.
  (double, double) get heightRange {
    var lo = heights[0], hi = heights[0];
    for (final h in heights) {
      if (h < lo) lo = h;
      if (h > hi) hi = h;
    }
    return (origin.y + lo, origin.y + hi);
  }

  /// Raises (or lowers with a negative [amount]) a round hill around the
  /// world point. [falloff] 1 is smooth (cosine), larger is more pointed.
  void raise(double x, double z, double radius, double amount, {double falloff = 1.0}) {
    final x0 = ((x - radius - origin.x) / cellSize).floor().clamp(0, countX - 1);
    final x1 = ((x + radius - origin.x) / cellSize).ceil().clamp(0, countX - 1);
    final z0 = ((z - radius - origin.z) / cellSize).floor().clamp(0, countZ - 1);
    final z1 = ((z + radius - origin.z) / cellSize).ceil().clamp(0, countZ - 1);
    for (var gz = z0; gz <= z1; gz++) {
      for (var gx = x0; gx <= x1; gx++) {
        final d = math.sqrt(math.pow(origin.x + gx * cellSize - x, 2) + math.pow(origin.z + gz * cellSize - z, 2));
        if (d >= radius) continue;
        final t = math.pow(0.5 + 0.5 * math.cos(d / radius * math.pi), falloff).toDouble();
        heights[gz * countX + gx] += (amount * t).toDouble();
      }
    }
  }

  /// One mesh for the whole terrain (or the part [x0, z0]..[x1, z1] in grid
  /// points). [step] 2 uses every second point (a lower detail copy).
  /// The mesh is positioned like the terrain (use it with an object at 0, 0, 0).
  Mesh buildMesh({int x0 = 0, int z0 = 0, int? x1, int? z1, int step = 1, double uvPerMeter = 0.1}) {
    x1 ??= countX - 1;
    z1 ??= countZ - 1;
    assert(step >= 1 && x1 > x0 && z1 > z0 && x1 < countX && z1 < countZ && x0 >= 0 && z0 >= 0);
    final xs = <int>[for (var x = x0; x < x1; x += step) x, x1];
    final zs = <int>[for (var z = z0; z < z1; z += step) z, z1];
    final nx = xs.length, nz = zs.length;
    final pos = Float32List(nx * nz * 3);
    final nor = Float32List(nx * nz * 3);
    for (var j = 0; j < nz; j++) {
      for (var i = 0; i < nx; i++) {
        final gx = xs[i], gz = zs[j];
        final wx = origin.x + gx * cellSize, wz = origin.z + gz * cellSize;
        final k = (j * nx + i) * 3;
        pos[k] = wx;
        pos[k + 1] = origin.y + heights[gz * countX + gx];
        pos[k + 2] = wz;
        // central differences on the full grid (same normals for every detail level)
        final hl = heightAtGrid(gx - 1, gz), hr = heightAtGrid(gx + 1, gz);
        final hd = heightAtGrid(gx, gz - 1), hu = heightAtGrid(gx, gz + 1);
        final sx = (gx == 0 || gx == countX - 1) ? 1.0 : 2.0;
        final sz = (gz == 0 || gz == countZ - 1) ? 1.0 : 2.0;
        final n = Vector3(-(hr - hl) / (sx * cellSize), 1.0, -(hu - hd) / (sz * cellSize)).normalized();
        nor[k] = n.x;
        nor[k + 1] = n.y;
        nor[k + 2] = n.z;
      }
    }
    // Triangles: counter-clockwise seen from above, split along (0,0)-(1,1).
    final idx = <int>[];
    for (var j = 0; j < nz - 1; j++) {
      for (var i = 0; i < nx - 1; i++) {
        final a = j * nx + i, b = a + 1, c = a + nx, d = c + 1;
        idx.addAll([a, c, d, a, d, b]);
      }
    }
    return Mesh(MeshArrays(pos, nor, idx), name: 'Terrain');
  }

  /// Splits the terrain into square chunks of [chunkCells] cells. Every
  /// chunk shares its edge points with the next one, so there are no cracks.
  List<TerrainChunk> buildChunks({int chunkCells = 32, int step = 1}) {
    final out = <TerrainChunk>[];
    for (var z = 0; z < countZ - 1; z += chunkCells) {
      for (var x = 0; x < countX - 1; x += chunkCells) {
        final x1 = math.min(x + chunkCells, countX - 1);
        final z1 = math.min(z + chunkCells, countZ - 1);
        final mesh = buildMesh(x0: x, z0: z, x1: x1, z1: z1, step: step);
        out.add(TerrainChunk(mesh, gridX: x, gridZ: z));
      }
    }
    return out;
  }
}

/// One piece of a big terrain. Give each chunk its own object at 0, 0, 0.
class TerrainChunk {
  TerrainChunk(this.mesh, {required this.gridX, required this.gridZ});
  final Mesh mesh;

  /// Grid point where the chunk starts.
  final int gridX, gridZ;
}
