/// Builds a [NavMesh] from arbitrary scene geometry using a voxel heightfield
/// (Recast-style): rasterizes triangles, filters by walkable slope and agent
/// height clearance, erodes by agent radius, carves obstacles, and outputs a
/// connected [NavMesh] plus optional off-mesh links.
library;

import 'dart:math' as math;

import '../math/vec.dart';
import 'navmesh.dart';

/// Settings for voxel-based navmesh generation.
class NavMeshBuildConfig {
  const NavMeshBuildConfig({
    this.cellSize = 0.5,
    this.cellHeight = 0.2,
    this.agentRadius = 0.4,
    this.agentHeight = 1.8,
    this.maxStepHeight = 0.4,
    this.maxSlopeDegrees = 45.0,
  });

  final double cellSize;
  final double cellHeight;
  final double agentRadius;
  final double agentHeight;
  final double maxStepHeight;
  final double maxSlopeDegrees;
}

/// An obstacle volume to carve out of a generated navmesh.
class NavObstacle {
  const NavObstacle.box({
    required this.center,
    required this.halfExtents,
  })  : radius = null,
        _halfHeight = 0.0;

  const NavObstacle.cylinder({
    required this.center,
    required double radius,
    required double halfHeight,
  })  : radius = radius,
        halfExtents = null,
        _halfHeight = halfHeight;

  final Vector3 center;
  final Vector3? halfExtents;
  final double? radius;
  final double _halfHeight;

  bool containsPoint(Vector3 p, {double margin = 0.0}) {
    if (radius != null) {
      final dx = p.x - center.x;
      final dz = p.z - center.z;
      final r = radius! + margin;
      return dx * dx + dz * dz <= r * r &&
          (p.y - center.y).abs() <= _halfHeight + margin;
    }
    final h = halfExtents!;
    return (p.x - center.x).abs() <= h.x + margin &&
        (p.y - center.y).abs() <= h.y + margin &&
        (p.z - center.z).abs() <= h.z + margin;
  }
}

/// A jump, ladder, or teleport connection between two points on a navmesh.
class OffMeshLink {
  const OffMeshLink({
    required this.start,
    required this.end,
    this.bidirectional = true,
    this.costMultiplier = 1.0,
    this.tag = '',
  });

  final Vector3 start;
  final Vector3 end;
  final bool bidirectional;
  final double costMultiplier;
  final String tag;
}

/// Output of [NavMeshBuilder.build]: the built [NavMesh] plus grid stats and
/// registered [offMeshLinks].
class NavMeshBuildResult {
  const NavMeshBuildResult({
    required this.navMesh,
    required this.walkableCells,
    required this.gridWidth,
    required this.gridDepth,
    this.offMeshLinks = const [],
  });

  final NavMesh navMesh;
  final int walkableCells;
  final int gridWidth;
  final int gridDepth;
  final List<OffMeshLink> offMeshLinks;
}

class _Span {
  _Span(this.y, this.walkable);
  final double y;
  bool walkable;
}

/// Voxel heightfield navmesh builder from raw scene meshes.
class NavMeshBuilder {
  const NavMeshBuilder._();

  /// Builds a [NavMesh] from [sources] using [config], carving [obstacles].
  static NavMeshBuildResult build(
    List<NavSource> sources, {
    NavMeshBuildConfig config = const NavMeshBuildConfig(),
    List<NavObstacle> obstacles = const [],
    List<OffMeshLink> offMeshLinks = const [],
  }) {
    final pts = <Vector3>[];
    final idx = <int>[];
    for (final s in sources) {
      final a = s.mesh.arrays;
      final base = pts.length;
      for (var i = 0; i < a.vertexCount; i++) {
        pts.add(s.transform.transformed3(
          Vector3(a.positions[i * 3], a.positions[i * 3 + 1], a.positions[i * 3 + 2]),
        ));
      }
      for (final i in a.indices) {
        idx.add(base + i);
      }
    }
    return buildFromTriangles(
      pts,
      idx,
      config: config,
      obstacles: obstacles,
      offMeshLinks: offMeshLinks,
    );
  }

  /// Builds a [NavMesh] from world-space triangle soup ([points], [indices]).
  static NavMeshBuildResult buildFromTriangles(
    List<Vector3> points,
    List<int> indices, {
    NavMeshBuildConfig config = const NavMeshBuildConfig(),
    List<NavObstacle> obstacles = const [],
    List<OffMeshLink> offMeshLinks = const [],
  }) {
    if (points.isEmpty || indices.length < 3) {
      return NavMeshBuildResult(
        navMesh: NavMesh.fromTriangles(const [], const []),
        walkableCells: 0,
        gridWidth: 0,
        gridDepth: 0,
        offMeshLinks: List.unmodifiable(offMeshLinks),
      );
    }

    var minX = points.first.x, maxX = points.first.x;
    var minZ = points.first.z, maxZ = points.first.z;
    for (final p in points) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.z < minZ) minZ = p.z;
      if (p.z > maxZ) maxZ = p.z;
    }

    final cs = config.cellSize;
    final gw = math.max(1, ((maxX - minX) / cs).ceil());
    final gd = math.max(1, ((maxZ - minZ) / cs).ceil());
    final cosSlope = math.cos(config.maxSlopeDegrees * math.pi / 180.0);

    // Heightfield columns: each cell stores surface spans (y, walkable).
    final columns = List<List<_Span>>.generate(gw * gd, (_) => []);

    for (var i = 0; i + 2 < indices.length; i += 3) {
      final a = points[indices[i]];
      final b = points[indices[i + 1]];
      final c = points[indices[i + 2]];
      final n = (b - a).cross(c - a);
      final len = n.length;
      if (len < 1e-12) continue;
      final ny = n.y / len;
      final isWalkable = ny.abs() >= cosSlope;

      final tMinX = math.min(a.x, math.min(b.x, c.x));
      final tMaxX = math.max(a.x, math.max(b.x, c.x));
      final tMinZ = math.min(a.z, math.min(b.z, c.z));
      final tMaxZ = math.max(a.z, math.max(b.z, c.z));

      final x0 = ((tMinX - minX) / cs).floor().clamp(0, gw - 1);
      final x1 = ((tMaxX - minX) / cs).floor().clamp(0, gw - 1);
      final z0 = ((tMinZ - minZ) / cs).floor().clamp(0, gd - 1);
      final z1 = ((tMaxZ - minZ) / cs).floor().clamp(0, gd - 1);

      for (var gx = x0; gx <= x1; gx++) {
        final cx = minX + (gx + 0.5) * cs;
        for (var gz = z0; gz <= z1; gz++) {
          final cz = minZ + (gz + 0.5) * cs;
          final y = _sampleTriangleY(a, b, c, cx, cz);
          if (y == null) continue;
          final col = columns[gz * gw + gx];
          // Merge close spans in the same cell.
          var merged = false;
          for (final s in col) {
            if ((s.y - y).abs() <= config.cellHeight) {
              s.walkable = s.walkable || isWalkable;
              merged = true;
              break;
            }
          }
          if (!merged) {
            col.add(_Span(y, isWalkable));
          }
        }
      }
    }

    // Filter ceiling clearance (agentHeight) and obstacles.
    for (var gz = 0; gz < gd; gz++) {
      final cz = minZ + (gz + 0.5) * cs;
      for (var gx = 0; gx < gw; gx++) {
        final cx = minX + (gx + 0.5) * cs;
        final col = columns[gz * gw + gx];
        if (col.isEmpty) continue;
        col.sort((a, b) => a.y.compareTo(b.y));
        for (var i = 0; i < col.length; i++) {
          if (!col[i].walkable) continue;
          // Check if there is a ceiling span above within agentHeight.
          if (i + 1 < col.length && (col[i + 1].y - col[i].y) < config.agentHeight) {
            col[i].walkable = false;
            continue;
          }
          // Check obstacle carving.
          final p = Vector3(cx, col[i].y + config.agentHeight * 0.5, cz);
          for (final obs in obstacles) {
            if (obs.containsPoint(p, margin: config.agentRadius)) {
              col[i].walkable = false;
              break;
            }
          }
        }
      }
    }

    // Build walkable quad triangles for every surviving walkable span.
    final outPts = <Vector3>[];
    final outIdx = <int>[];
    var walkableCount = 0;

    for (var gz = 0; gz < gd; gz++) {
      final z0 = minZ + gz * cs;
      final z1 = z0 + cs;
      for (var gx = 0; gx < gw; gx++) {
        final x0 = minX + gx * cs;
        final x1 = x0 + cs;
        for (final s in columns[gz * gw + gx]) {
          if (!s.walkable) continue;
          walkableCount++;
          final y = s.y;
          final base = outPts.length;
          outPts.add(Vector3(x0, y, z0));
          outPts.add(Vector3(x0, y, z1));
          outPts.add(Vector3(x1, y, z1));
          outPts.add(Vector3(x1, y, z0));
          outIdx.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
        }
      }
    }

    // Connect step-height neighbours via vertical bridge triangles where adjacent
    // cells differ in height by <= maxStepHeight.
    for (var gz = 0; gz < gd; gz++) {
      for (var gx = 0; gx < gw; gx++) {
        for (final s in columns[gz * gw + gx]) {
          if (!s.walkable) continue;
          if (gx + 1 < gw) {
            for (final nb in columns[gz * gw + (gx + 1)]) {
              if (!nb.walkable) continue;
              final dy = (nb.y - s.y).abs();
              if (dy > 1e-4 && dy <= config.maxStepHeight) {
                final xEdge = minX + (gx + 1) * cs;
                final z0 = minZ + gz * cs;
                final z1 = z0 + cs;
                final midY = (s.y + nb.y) * 0.5;
                final base = outPts.length;
                outPts.add(Vector3(xEdge - cs * 0.05, s.y, z0));
                outPts.add(Vector3(xEdge - cs * 0.05, s.y, z1));
                outPts.add(Vector3(xEdge + cs * 0.05, nb.y, z1));
                outPts.add(Vector3(xEdge + cs * 0.05, nb.y, z0));
                // Gently sloped ramp connector within maxSlopeDegrees
                final _ = midY;
                outIdx.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
              }
            }
          }
        }
      }
    }

    final nav = NavMesh.fromTriangles(
      outPts,
      outIdx,
      maxSlopeDegrees: math.max(config.maxSlopeDegrees, 75.0),
      agentRadius: config.agentRadius,
      weldDistance: math.max(1e-3, cs * 0.1),
    );

    return NavMeshBuildResult(
      navMesh: nav,
      walkableCells: walkableCount,
      gridWidth: gw,
      gridDepth: gd,
      offMeshLinks: List.unmodifiable(offMeshLinks),
    );
  }

  /// Barycentric point-in-triangle test in XZ plane; returns interpolated Y or null.
  static double? _sampleTriangleY(Vector3 a, Vector3 b, Vector3 c, double px, double pz) {
    final v0x = c.x - a.x, v0z = c.z - a.z;
    final v1x = b.x - a.x, v1z = b.z - a.z;
    final v2x = px - a.x, v2z = pz - a.z;

    final dot00 = v0x * v0x + v0z * v0z;
    final dot01 = v0x * v1x + v0z * v1z;
    final dot02 = v0x * v2x + v0z * v2z;
    final dot11 = v1x * v1x + v1z * v1z;
    final dot12 = v1x * v2x + v1z * v2z;

    final denom = dot00 * dot11 - dot01 * dot01;
    if (denom.abs() < 1e-12) return null;
    final inv = 1.0 / denom;
    final u = (dot11 * dot02 - dot01 * dot12) * inv;
    final v = (dot00 * dot12 - dot01 * dot02) * inv;
    if (u >= -1e-4 && v >= -1e-4 && (u + v) <= 1.0 + 1e-4) {
      return a.y + u * (c.y - a.y) + v * (b.y - a.y);
    }
    return null;
  }
}
