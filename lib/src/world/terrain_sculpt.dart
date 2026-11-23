import 'dart:math' as math;
import 'dart:typed_data';

import '../editor/inspector.dart';
import '../engine/game_object.dart';
import '../engine/mesh_renderer.dart';
import '../engine/render/material.dart';
import '../engine/render/mesh.dart';
import '../engine/render/primitives.dart';
import '../math/vec.dart';
import '../world/mesh_tools.dart';

/// Paintable terrain surface layers (for texture splatting / vertex tinting).
enum TerrainLayer { grass, dirt, road, rock, snow }

/// Interactive Unity-style heightmap terrain with live sculpt brushes
/// (Raise, Lower, Smooth, Flatten), surface layer painting, and foliage scatter.
class EditableTerrainComponent extends Component implements Inspectable {
  EditableTerrainComponent({
    this.gridWidth = 32,
    this.gridDepth = 32,
    this.worldWidth = 96.0,
    this.worldDepth = 96.0,
    this.brushRadius = 6.0,
    this.brushStrength = 1.2,
  }) : heights = Float32List((gridWidth + 1) * (gridDepth + 1)),
       layers = Uint8List((gridWidth + 1) * (gridDepth + 1));

  final int gridWidth;
  final int gridDepth;
  final double worldWidth;
  final double worldDepth;

  double brushRadius;
  double brushStrength;

  /// Height values per grid vertex (`(gridWidth + 1) * (gridDepth + 1)`).
  final Float32List heights;

  /// Surface material layer index per vertex (`TerrainLayer.index`).
  final Uint8List layers;

  /// World-space foliage positions scattered by [scatterFoliage].
  final List<Vector3> foliagePoints = [];

  int _idx(int gx, int gz) => gz * (gridWidth + 1) + gx;

  double _worldX(int gx) => (gx / gridWidth - 0.5) * worldWidth;
  double _worldZ(int gz) => (gz / gridDepth - 0.5) * worldDepth;

  /// Bilinear terrain height at any world `(x, z)` coordinate.
  double sampleHeight(double wx, double wz) {
    final fx = ((wx / worldWidth) + 0.5) * gridWidth;
    final fz = ((wz / worldDepth) + 0.5) * gridDepth;
    final x0 = fx.floor().clamp(0, gridWidth - 1);
    final z0 = fz.floor().clamp(0, gridDepth - 1);
    final tx = (fx - x0).clamp(0.0, 1.0);
    final tz = (fz - z0).clamp(0.0, 1.0);
    final h00 = heights[_idx(x0, z0)];
    final h10 = heights[_idx(x0 + 1, z0)];
    final h01 = heights[_idx(x0, z0 + 1)];
    final h11 = heights[_idx(x0 + 1, z0 + 1)];
    final a = h00 + (h10 - h00) * tx;
    final b = h01 + (h11 - h01) * tx;
    return a + (b - a) * tz;
  }

  /// Raises (`delta > 0`) or lowers (`delta < 0`) terrain around `(wx, wz)` with smooth cosine falloff.
  void sculpt(double wx, double wz, {double? delta, double? radius}) {
    final r = math.max(0.5, radius ?? brushRadius);
    final d = delta ?? brushStrength;
    for (var gz = 0; gz <= gridDepth; gz++) {
      final vz = _worldZ(gz);
      for (var gx = 0; gx <= gridWidth; gx++) {
        final vx = _worldX(gx);
        final dist = math.sqrt((vx - wx) * (vx - wx) + (vz - wz) * (vz - wz));
        if (dist < r) {
          final falloff = 0.5 * (1.0 + math.cos(math.pi * dist / r));
          heights[_idx(gx, gz)] += d * falloff;
        }
      }
    }
    rebuildMesh();
  }

  /// Smooths sharp height spikes around `(wx, wz)`.
  void smooth(double wx, double wz, {double? radius, double factor = 0.5}) {
    final r = math.max(0.5, radius ?? brushRadius);
    final copy = Float32List.fromList(heights);
    for (var gz = 1; gz < gridDepth; gz++) {
      final vz = _worldZ(gz);
      for (var gx = 1; gx < gridWidth; gx++) {
        final vx = _worldX(gx);
        final dist = math.sqrt((vx - wx) * (vx - wx) + (vz - wz) * (vz - wz));
        if (dist < r) {
          final avg = (copy[_idx(gx - 1, gz)] +
                  copy[_idx(gx + 1, gz)] +
                  copy[_idx(gx, gz - 1)] +
                  copy[_idx(gx, gz + 1)] +
                  copy[_idx(gx, gz)]) /
              5.0;
          final falloff = 0.5 * (1.0 + math.cos(math.pi * dist / r));
          final i = _idx(gx, gz);
          heights[i] = copy[i] + (avg - copy[i]) * factor * falloff;
        }
      }
    }
    rebuildMesh();
  }

  /// Flattens terrain around `(wx, wz)` toward [targetHeight].
  void flatten(double wx, double wz, double targetHeight, {double? radius, double factor = 0.8}) {
    final r = math.max(0.5, radius ?? brushRadius);
    for (var gz = 0; gz <= gridDepth; gz++) {
      final vz = _worldZ(gz);
      for (var gx = 0; gx <= gridWidth; gx++) {
        final vx = _worldX(gx);
        final dist = math.sqrt((vx - wx) * (vx - wx) + (vz - wz) * (vz - wz));
        if (dist < r) {
          final falloff = 0.5 * (1.0 + math.cos(math.pi * dist / r));
          final i = _idx(gx, gz);
          heights[i] = heights[i] + (targetHeight - heights[i]) * factor * falloff;
        }
      }
    }
    rebuildMesh();
  }

  /// Paints a [TerrainLayer] (grass, dirt, road, rock, snow) within [radius] around `(wx, wz)`.
  void paintLayer(double wx, double wz, TerrainLayer layer, {double? radius}) {
    final r = math.max(0.5, radius ?? brushRadius);
    for (var gz = 0; gz <= gridDepth; gz++) {
      final vz = _worldZ(gz);
      for (var gx = 0; gx <= gridWidth; gx++) {
        final vx = _worldX(gx);
        final dist = math.sqrt((vx - wx) * (vx - wx) + (vz - wz) * (vz - wz));
        if (dist < r) {
          layers[_idx(gx, gz)] = layer.index;
        }
      }
    }
  }

  /// Generates natural rolling hills + central valley/arena using deterministic layered sine waves.
  void generateHills({double amplitude = 5.5, double frequency = 0.08, bool flatCenterArena = true}) {
    for (var gz = 0; gz <= gridDepth; gz++) {
      final vz = _worldZ(gz);
      for (var gx = 0; gx <= gridWidth; gx++) {
        final vx = _worldX(gx);
        var h = math.sin(vx * frequency) * math.cos(vz * frequency) * amplitude +
            math.sin(vx * frequency * 2.3 + 1.1) * math.sin(vz * frequency * 1.9) * (amplitude * 0.35);
        if (flatCenterArena) {
          final distCenter = math.sqrt(vx * vx + vz * vz);
          final mask = ((distCenter - 12.0) / 14.0).clamp(0.0, 1.0);
          h *= mask * mask;
        }
        heights[_idx(gx, gz)] = h;
        layers[_idx(gx, gz)] = h > amplitude * 0.65 ? TerrainLayer.rock.index : TerrainLayer.grass.index;
      }
    }
    rebuildMesh();
  }

  /// Scatters [count] foliage tree GameObjects as children of [parent] (or this object) seated on the terrain.
  List<GameObject> scatterFoliage({
    int count = 16,
    int seed = 42,
    double minCenterClearance = 10.0,
    GameObject? parent,
  }) {
    final rng = math.Random(seed);
    final spawned = <GameObject>[];
    final targetParent = parent ?? (isAttached ? gameObject : null);
    for (var i = 0; i < count; i++) {
      final wx = (rng.nextDouble() - 0.5) * (worldWidth * 0.86);
      final wz = (rng.nextDouble() - 0.5) * (worldDepth * 0.86);
      if (math.sqrt(wx * wx + wz * wz) < minCenterClearance) continue;
      final wy = sampleHeight(wx, wz);
      foliagePoints.add(Vector3(wx, wy, wz));
      if (targetParent != null) {
        final tree = GameObject('Tree_${foliagePoints.length}', position: Vector3(wx, wy, wz));
        final trunk = GameObject('Trunk', position: Vector3(0, 1.1, 0));
        trunk.addComponent(MeshRenderer(
          Primitives.cylinder(0.26, 2.2, sides: 10),
          material: StandardMaterial(color: Vector4(0.42, 0.27, 0.15, 1), roughness: 0.9),
        ));
        final crown = GameObject('Crown', position: Vector3(0, 3.0, 0));
        crown.addComponent(MeshRenderer(
          Primitives.sphere(1.45, rings: 8, sectors: 12),
          material: StandardMaterial(color: Vector4(0.16, 0.48 + rng.nextDouble() * 0.14, 0.20, 1), roughness: 0.85),
        ));
        tree.addChild(trunk);
        tree.addChild(crown);
        targetParent.addChild(tree);
        spawned.add(tree);
      }
    }
    return spawned;
  }

  /// Builds a fresh [Mesh] with smooth central-difference normals and UVs,
  /// and updates the attached [MeshRenderer] if present.
  Mesh buildMesh() {
    final cols = gridWidth + 1;
    final rows = gridDepth + 1;
    final vc = cols * rows;
    final pos = Float32List(vc * 3);
    final nor = Float32List(vc * 3);
    final uvs = Float32List(vc * 2);
    final stepX = worldWidth / gridWidth;
    final stepZ = worldDepth / gridDepth;

    for (var gz = 0; gz < rows; gz++) {
      for (var gx = 0; gx < cols; gx++) {
        final i = gz * cols + gx;
        pos[i * 3] = _worldX(gx);
        pos[i * 3 + 1] = heights[i];
        pos[i * 3 + 2] = _worldZ(gz);
        uvs[i * 2] = gx / gridWidth;
        uvs[i * 2 + 1] = gz / gridDepth;

        final hL = heights[_idx(math.max(0, gx - 1), gz)];
        final hR = heights[_idx(math.min(gridWidth, gx + 1), gz)];
        final hD = heights[_idx(gx, math.max(0, gz - 1))];
        final hU = heights[_idx(gx, math.min(gridDepth, gz + 1))];
        final n = Vector3(hL - hR, 2.0 * math.min(stepX, stepZ), hD - hU).normalized();
        nor[i * 3] = n.x;
        nor[i * 3 + 1] = n.y;
        nor[i * 3 + 2] = n.z;
      }
    }

    final idx = <int>[];
    for (var gz = 0; gz < gridDepth; gz++) {
      for (var gx = 0; gx < gridWidth; gx++) {
        final a = gz * cols + gx;
        final b = (gz + 1) * cols + gx;
        final c = gz * cols + gx + 1;
        final d = (gz + 1) * cols + gx + 1;
        idx.addAll([a, b, c, b, d, c]);
      }
    }
    return Mesh(MeshArrays(pos, nor, idx, uvs: uvs), name: 'editable_terrain');
  }

  /// Rebuilds the mesh and swaps it onto this object's [MeshRenderer] if attached.
  void rebuildMesh() {
    if (!isAttached) return;
    final mr = gameObject.getComponent<MeshRenderer>();
    if (mr != null) {
      mr.mesh = buildMesh();
    }
  }

  String get inspectorTitle => 'Editable Terrain';

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.float('Brush Radius', () => brushRadius, (v) => brushRadius = v, min: 1, max: 30),
        InspectorField.float('Brush Strength', () => brushStrength, (v) => brushStrength = v, min: 0.1, max: 10),
      ];
}
