import 'dart:math' as math;
import 'dart:typed_data';

import '../math/vec.dart';

import '../engine/render/mesh.dart';

/// A triangle mesh of the ground where characters can walk, with a path finder.
///
/// Make one from the triangles of your level (everything that is not too steep
/// can be walked on) with [NavMesh.fromMeshes], [NavMesh.fromTriangles] or
/// from a `Terrain` mesh. Then ask for paths:
///
/// ```dart
/// final nav = NavMesh.fromMeshes([NavSource(groundMesh, groundTransform.worldMatrix)], agentRadius: 0.4);
/// final path = nav.findPath(from, to);          // list of points, or null if no way
/// ```
///
/// The path is the shortest one that stays on the mesh (A* over the triangles,
/// then straightened with the funnel algorithm). Walls and holes are simply
/// places where there are no triangles: leave them out of the mesh (a wall is
/// too steep to walk, so it is left out by itself). [agentRadius] keeps the
/// path away from the corners of holes. Walls and holes that appear while the
/// game runs: [blockCircle].
class NavMesh {
  NavMesh._(this.vertices, this._tri, this._neighbor, double cell)
      : triangleCount = _tri.length ~/ 3,
        _cell = cell {
    _blocked = Uint8List(triangleCount);
    _centers = List.generate(triangleCount, (t) => (vertices[_tri[t * 3]] + vertices[_tri[t * 3 + 1]] + vertices[_tri[t * 3 + 2]]) / 3.0);
    _buildGrid();
  }

  /// Welded corner points.
  final List<Vector3> vertices;

  /// Number of walkable triangles.
  final int triangleCount;

  /// Distance kept from corners of holes (set by the factory).
  double agentRadius = 0;

  final Int32List _tri; // 3 corner indices per triangle, counter clockwise seen from above
  final Int32List _neighbor; // 3 per triangle: the triangle across edge (v0 v1), (v1 v2), (v2 v0), or -1
  late final Uint8List _blocked;
  late final List<Vector3> _centers;
  final double _cell;
  final Map<int, List<int>> _grid = {};
  double _gridMinX = 0, _gridMinZ = 0;

  /// Makes a navmesh from triangles given as points and index triples.
  /// Triangles steeper than [maxSlopeDegrees] are left out (walls, cliffs).
  /// Triangles may face up or down; they are turned to face up.
  factory NavMesh.fromTriangles(
    List<Vector3> points,
    List<int> indices, {
    double maxSlopeDegrees = 45,
    double agentRadius = 0,
    double weldDistance = 1e-3,
  }) {
    final cosSlope = math.cos(maxSlopeDegrees * math.pi / 180.0);
    final welded = <Vector3>[];
    final ids = <(int, int, int), int>{};
    int weld(Vector3 p) {
      final k = ((p.x / weldDistance).round(), (p.y / weldDistance).round(), (p.z / weldDistance).round());
      return ids.putIfAbsent(k, () {
        welded.add(p.clone());
        return welded.length - 1;
      });
    }

    final tris = <int>[];
    for (var i = 0; i + 2 < indices.length; i += 3) {
      final a = points[indices[i]], b = points[indices[i + 1]], c = points[indices[i + 2]];
      final n = (b - a).cross(c - a);
      final len = n.length;
      if (len < 1e-12) continue; // a line or a point
      final ny = n.y / len;
      if (ny.abs() < cosSlope) continue; // too steep
      var ia = weld(a), ib = weld(b), ic = weld(c);
      if (ia == ib || ib == ic || ia == ic) continue;
      if (ny < 0) {
        final t = ib;
        ib = ic;
        ic = t; // turn it to face up
      }
      tris.addAll([ia, ib, ic]);
    }
    final triArr = Int32List.fromList(tris);
    // neighbours across shared edges
    final nb = Int32List(triArr.length)..fillRange(0, triArr.length, -1);
    final edgeOwner = <(int, int), int>{}; // directed edge -> triangle*3 + edge number
    for (var t = 0; t < triArr.length ~/ 3; t++) {
      for (var e = 0; e < 3; e++) {
        final a = triArr[t * 3 + e], b = triArr[t * 3 + (e + 1) % 3];
        final other = edgeOwner[(b, a)]; // the neighbour walks the same edge the other way
        if (other != null) {
          nb[t * 3 + e] = other ~/ 3;
          nb[other] = t;
        } else {
          edgeOwner[(a, b)] = t * 3 + e;
        }
      }
    }
    // grid cell size from the average edge length
    var sum = 0.0, cnt = 0;
    for (var t = 0; t < triArr.length ~/ 3; t++) {
      sum += (welded[triArr[t * 3]] - welded[triArr[t * 3 + 1]]).length;
      cnt++;
    }
    final cell = cnt == 0 ? 1.0 : math.max(0.25, sum / cnt * 2);
    return NavMesh._(welded, triArr, nb, cell)..agentRadius = agentRadius;
  }

  /// Collects the triangles of [sources] (meshes with a world matrix).
  factory NavMesh.fromMeshes(
    List<NavSource> sources, {
    double maxSlopeDegrees = 45,
    double agentRadius = 0,
  }) {
    final pts = <Vector3>[];
    final idx = <int>[];
    for (final s in sources) {
      final a = s.mesh.arrays;
      final base = pts.length;
      for (var i = 0; i < a.vertexCount; i++) {
        pts.add(s.transform.transformed3(Vector3(a.positions[i * 3], a.positions[i * 3 + 1], a.positions[i * 3 + 2])));
      }
      for (final i in a.indices) {
        idx.add(base + i);
      }
    }
    return NavMesh.fromTriangles(pts, idx, maxSlopeDegrees: maxSlopeDegrees, agentRadius: agentRadius);
  }

  // ---------------------------------------------------------------- queries

  /// Switches a round area on or off (a closed door, a fallen tree, a crowd).
  /// Triangles whose center is inside the circle (on the ground plane) cannot
  /// be walked while blocked. Returns how many triangles changed.
  int blockCircle(Vector3 center, double radius, {bool blocked = true}) {
    _adj = null;
    var n = 0;
    final r2 = radius * radius;
    for (var t = 0; t < triangleCount; t++) {
      final c = _centers[t];
      final dx = c.x - center.x, dz = c.z - center.z;
      if (dx * dx + dz * dz <= r2 && (_blocked[t] == 1) != blocked) {
        _blocked[t] = blocked ? 1 : 0;
        n++;
      }
    }
    return n;
  }

  /// Makes every triangle walkable again.
  void clearBlocked() {
    _adj = null;
    _blocked.fillRange(0, _blocked.length, 0);
  }

  bool isBlocked(int triangle) => _blocked[triangle] == 1;

  /// True if the point is over a walkable triangle (ignores height).
  bool contains(Vector3 p, {double tolerance = 1e-4}) => _locate(p, tolerance) >= 0;

  /// The point on the navmesh nearest to [p] (null for an empty navmesh).
  Vector3? nearestPoint(Vector3 p) {
    final t = _nearestTriangle(p);
    if (t < 0) return null;
    return _closestOnTriangle(p, t);
  }

  /// Height of the walkable ground at (x, z) nearest to [y], or null if there is none.
  double? heightAt(double x, double z, {double? nearY}) {
    final t = _locate(Vector3(x, nearY ?? 0, z), 1e-6, preferY: nearY);
    if (t < 0) return null;
    return _heightOn(t, x, z);
  }

  /// The shortest path from [from] to [to] over the navmesh, as points to walk
  /// through (first is [from] moved onto the mesh, last is [to] moved onto the
  /// mesh). Null if there is no way.
  ///
  /// [maxSnap]: a point farther than this from the mesh gives null.
  List<Vector3>? findPath(Vector3 from, Vector3 to, {double maxSnap = double.infinity}) {
    final ta = _nearestTriangle(from, includeBlocked: false);
    final tb = _nearestTriangle(to, includeBlocked: false);
    if (ta < 0 || tb < 0) return null;
    final a = _closestOnTriangle(from, ta), b = _closestOnTriangle(to, tb);
    if ((a - from).length > maxSnap || (b - to).length > maxSnap) return null;
    if (ta == tb) return [a, b];
    if (agentRadius <= 0) {
      final direct = _theta(a, ta, b, tb);
      if (direct != null) return direct;
    }
    final corridor = _astar(ta, tb);
    if (corridor == null) return null;
    return _shortcut(_dedupe(_funnel(a, b, corridor)));
  }

  /// Length of a path (sum of the segments).
  static double pathLength(List<Vector3> path) {
    var d = 0.0;
    for (var i = 0; i + 1 < path.length; i++) {
      d += (path[i + 1] - path[i]).length;
    }
    return d;
  }

  /// True if the straight line from [a] to [b] stays on the navmesh.
  bool lineOfWalk(Vector3 a, Vector3 b, {double step = 0.25}) {
    final d = b - a;
    final n = math.max(1, (d.length / step).ceil());
    for (var i = 0; i <= n; i++) {
      if (_locate(a + d * (i / n), 1e-3, preferY: a.y + d.y * (i / n)) < 0) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------- internals

  void _buildGrid() {
    if (triangleCount == 0) return;
    var minX = double.infinity, minZ = double.infinity;
    for (final v in vertices) {
      minX = math.min(minX, v.x);
      minZ = math.min(minZ, v.z);
    }
    _gridMinX = minX;
    _gridMinZ = minZ;
    for (var t = 0; t < triangleCount; t++) {
      final a = vertices[_tri[t * 3]], b = vertices[_tri[t * 3 + 1]], c = vertices[_tri[t * 3 + 2]];
      final x0 = _cx(math.min(a.x, math.min(b.x, c.x))), x1 = _cx(math.max(a.x, math.max(b.x, c.x)));
      final z0 = _cz(math.min(a.z, math.min(b.z, c.z))), z1 = _cz(math.max(a.z, math.max(b.z, c.z)));
      for (var z = z0; z <= z1; z++) {
        for (var x = x0; x <= x1; x++) {
          (_grid[_key(x, z)] ??= []).add(t);
        }
      }
    }
  }

  int _cx(double x) => ((x - _gridMinX) / _cell).floor();
  int _cz(double z) => ((z - _gridMinZ) / _cell).floor();
  int _key(int x, int z) => (x + 100000) * 200003 + (z + 100000);

  /// Triangle containing (p.x, p.z), the one whose height is nearest to [preferY] (or p.y).
  int _locate(Vector3 p, double tol, {double? preferY, bool includeBlocked = true}) {
    final list = _grid[_key(_cx(p.x), _cz(p.z))];
    if (list == null) return -1;
    var best = -1;
    var bestDy = double.infinity;
    final py = preferY ?? p.y;
    for (final t in list) {
      if (!includeBlocked && _blocked[t] == 1) continue;
      if (!_inside(t, p.x, p.z, tol)) continue;
      final dy = (_heightOn(t, p.x, p.z) - py).abs();
      if (dy < bestDy) {
        bestDy = dy;
        best = t;
      }
    }
    return best;
  }

  bool _inside(int t, double x, double z, double tol) {
    final a = vertices[_tri[t * 3]], b = vertices[_tri[t * 3 + 1]], c = vertices[_tri[t * 3 + 2]];
    final d1 = (x - b.x) * (a.z - b.z) - (a.x - b.x) * (z - b.z);
    final d2 = (x - c.x) * (b.z - c.z) - (b.x - c.x) * (z - c.z);
    final d3 = (x - a.x) * (c.z - a.z) - (c.x - a.x) * (z - a.z);
    final neg = d1 < -tol || d2 < -tol || d3 < -tol;
    final pos = d1 > tol || d2 > tol || d3 > tol;
    return !(neg && pos);
  }

  double _heightOn(int t, double x, double z) {
    final a = vertices[_tri[t * 3]], b = vertices[_tri[t * 3 + 1]], c = vertices[_tri[t * 3 + 2]];
    final den = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z);
    if (den.abs() < 1e-12) return a.y;
    final w0 = ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / den;
    final w1 = ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / den;
    return w0 * a.y + w1 * b.y + (1 - w0 - w1) * c.y;
  }

  int _nearestTriangle(Vector3 p, {bool includeBlocked = true}) {
    final inside = _locate(p, 1e-4, includeBlocked: includeBlocked);
    if (inside >= 0) return inside;
    var best = -1;
    var bestD = double.infinity;
    for (var t = 0; t < triangleCount; t++) {
      if (!includeBlocked && _blocked[t] == 1) continue;
      final d = (_closestOnTriangle(p, t) - p).length2;
      if (d < bestD) {
        bestD = d;
        best = t;
      }
    }
    return best;
  }

  Vector3 _closestOnTriangle(Vector3 p, int t) {
    final a = vertices[_tri[t * 3]], b = vertices[_tri[t * 3 + 1]], c = vertices[_tri[t * 3 + 2]];
    if (_inside(t, p.x, p.z, 0)) {
      return Vector3(p.x, _heightOn(t, p.x, p.z), p.z);
    }
    Vector3 onSeg(Vector3 s, Vector3 e) {
      final d = e - s;
      final l2 = d.length2;
      final k = l2 == 0 ? 0.0 : ((p - s).dot(d) / l2).clamp(0.0, 1.0);
      return s + d * k;
    }

    final c1 = onSeg(a, b), c2 = onSeg(b, c), c3 = onSeg(c, a);
    var best = c1;
    var bd = (c1 - p).length2;
    for (final q in [c2, c3]) {
      final d = (q - p).length2;
      if (d < bd) {
        bd = d;
        best = q;
      }
    }
    return best;
  }

  List<int>? _astar(int start, int goal) {
    final n = triangleCount;
    final g = Float64List(n)..fillRange(0, n, double.infinity);
    final from = Int32List(n)..fillRange(0, n, -1);
    final closed = Uint8List(n);
    final heap = _Heap();
    g[start] = 0;
    heap.push(start, (_centers[start] - _centers[goal]).length);
    while (heap.isNotEmpty) {
      final cur = heap.pop();
      if (closed[cur] == 1) continue;
      closed[cur] = 1;
      if (cur == goal) {
        final path = <int>[goal];
        var c = goal;
        while (from[c] >= 0) {
          c = from[c];
          path.add(c);
        }
        return path.reversed.toList();
      }
      for (var e = 0; e < 3; e++) {
        final nb = _neighbor[cur * 3 + e];
        if (nb < 0 || closed[nb] == 1 || _blocked[nb] == 1) continue;
        final cost = g[cur] + (_centers[cur] - _centers[nb]).length;
        if (cost < g[nb]) {
          g[nb] = cost;
          from[nb] = cur;
          heap.push(nb, cost + (_centers[nb] - _centers[goal]).length);
        }
      }
    }
    return null;
  }

  static double _area(Vector3 a, Vector3 b, Vector3 c) => (c.x - a.x) * (b.z - a.z) - (b.x - a.x) * (c.z - a.z);



  // ---------------------------------------------------------------- any angle search (Theta*)

  List<List<int>>? _adj; // vertex -> vertices joined by an edge of a walkable triangle

  List<List<int>> _adjacency() {
    final cached = _adj;
    if (cached != null) return cached;
    final adj = List.generate(vertices.length, (_) => <int>[]);
    for (var t = 0; t < triangleCount; t++) {
      if (_blocked[t] == 1) continue;
      for (var e = 0; e < 3; e++) {
        final u = _tri[t * 3 + e], v = _tri[t * 3 + (e + 1) % 3];
        if (!adj[u].contains(v)) adj[u].add(v);
        if (!adj[v].contains(u)) adj[v].add(u);
      }
    }
    return _adj = adj;
  }

  /// Shortest path with any angle: moves from corner to corner of the mesh and
  /// goes straight whenever the way is free. Null if the goal cannot be reached.
  List<Vector3>? _theta(Vector3 a, int ta, Vector3 b, int tb) {
    final adj = _adjacency();
    final nv = vertices.length;
    final start = nv, goal = nv + 1;
    Vector3 pos(int n) => n == start ? a : (n == goal ? b : vertices[n]);
    final g = <int, double>{start: 0};
    final parent = <int, int>{start: start};
    final closed = <int>{};
    final heap = _Heap();
    heap.push(start, (a - b).length);
    final goalCorners = {_tri[tb * 3], _tri[tb * 3 + 1], _tri[tb * 3 + 2]};
    List<int> neighbours(int n) {
      if (n == start) return [_tri[ta * 3], _tri[ta * 3 + 1], _tri[ta * 3 + 2]];
      final out = List<int>.of(adj[n]);
      if (goalCorners.contains(n)) out.add(goal);
      return out;
    }

    var expansions = 0;
    while (heap.isNotEmpty) {
      final cur = heap.pop();
      if (closed.contains(cur)) continue;
      if (cur == goal) {
        final path = <Vector3>[b];
        var c = goal;
        while (c != start) {
          c = parent[c]!;
          path.add(pos(c));
        }
        return _dedupe(path.reversed.toList());
      }
      closed.add(cur);
      if (++expansions > nv * 4 + 100) return null;
      final par = parent[cur]!;
      for (final nb in neighbours(cur)) {
        if (closed.contains(nb)) continue;
        final pn = pos(nb);
        var from = cur;
        // any angle: if the parent of the current point can see the neighbour, go straight from it
        if (par != cur && _visible(pos(par), pn)) {
          from = par;
        } else if (cur != start && nb != goal && !_edgeOpen(cur, nb)) {
          continue;
        }
        final cost = g[from]! + (pos(from) - pn).length;
        if (cost < (g[nb] ?? double.infinity) - 1e-9) {
          g[nb] = cost;
          parent[nb] = from;
          heap.push(nb, cost + (pn - b).length);
        }
      }
    }
    return null;
  }

  bool _edgeOpen(int u, int v) => _adjacency()[u].contains(v);

  // ---------------------------------------------------------------- straightening

  List<Vector3> _dedupe(List<Vector3> path) {
    final out = <Vector3>[];
    for (final p in path) {
      if (out.isEmpty || (out.last - p).length > 1e-5) out.add(p);
    }
    if (out.length == 1) out.add(out.first.clone());
    return out;
  }

  /// Removes corners that are not needed: from each point go to the farthest
  /// later point that can be seen in a straight line over the mesh.
  List<Vector3> _shortcut(List<Vector3> path) {
    if (path.length <= 2) return path;
    final out = <Vector3>[path.first];
    var i = 0;
    while (i < path.length - 1) {
      var j = path.length - 1;
      while (j > i + 1 && !_clearSegment(path[i], path[j])) {
        j--;
      }
      out.add(path[j]);
      i = j;
    }
    return out;
  }

  bool _clearSegment(Vector3 a, Vector3 b) {
    if (!_visible(a, b)) return false;
    if (agentRadius <= 0) return true;
    // keep the distance from the edges of the mesh: the two parallel lines at +- radius must be free too
    final d = b - a;
    final flat = Vector3(d.x, 0, d.z);
    if (flat.length < 1e-9) return true;
    final side = Vector3(-flat.z, 0, flat.x).normalized() * agentRadius;
    return _visible(a + side, b + side, snapY: true) && _visible(a - side, b - side, snapY: true);
  }

  /// Can you walk in a straight line from [a] to [b] without leaving the mesh
  /// or entering a blocked triangle? Exact: it follows the triangles the line crosses.
  bool _visible(Vector3 a, Vector3 b, {bool snapY = false}) {
    final starts = <int>[];
    final list = _grid[_key(_cx(a.x), _cz(a.z))];
    if (list == null) return false;
    for (final t in list) {
      if (_blocked[t] == 1) continue;
      if (!_inside(t, a.x, a.z, 1e-6)) continue;
      if (!snapY && (_heightOn(t, a.x, a.z) - a.y).abs() > 0.2) continue;
      starts.add(t);
    }
    for (final s in starts) {
      if (_walkRay(s, a, b)) return true;
    }
    return false;
  }

  bool _walkRay(int start, Vector3 a, Vector3 b) {
    var tri = start;
    var from = -1;
    for (var step = 0; step < triangleCount + 4; step++) {
      if (_inside(tri, b.x, b.z, 1e-6)) return true;
      final v0 = vertices[_tri[tri * 3]], v1 = vertices[_tri[tri * 3 + 1]], v2 = vertices[_tri[tri * 3 + 2]];
      final vs = [v0, v1, v2];
      var exitEdge = -1;
      var bestT = double.infinity;
      for (var e = 0; e < 3; e++) {
        if (_neighbor[tri * 3 + e] == from && from >= 0) continue;
        final p = vs[e], q = vs[(e + 1) % 3], third = vs[(e + 2) % 3];
        final inside = _area(p, q, third) >= 0 ? 1.0 : -1.0;
        final sa = _area(p, q, a) * inside;
        final sb = _area(p, q, b) * inside;
        if (sb < -1e-9 && sa >= -1e-7) {
          final t = sa / (sa - sb);
          if (t < bestT) {
            bestT = t;
            exitEdge = e;
          }
        }
      }
      if (exitEdge < 0) return false;
      final nb = _neighbor[tri * 3 + exitEdge];
      if (nb < 0 || _blocked[nb] == 1) return false;
      from = tri;
      tri = nb;
    }
    return false;
  }

  // The "simple stupid funnel algorithm": the shortest path through a row of gates.
  List<Vector3> _funnel(Vector3 start, Vector3 end, List<int> corridor) {
    final lefts = <Vector3>[start];
    final rights = <Vector3>[start];
    for (var i = 0; i + 1 < corridor.length; i++) {
      final t = corridor[i], next = corridor[i + 1];
      var e = 0;
      for (; e < 3; e++) {
        if (_neighbor[t * 3 + e] == next) break;
      }
      // Which end of the gate is on the left? Decide by looking at it from inside this triangle,
      // so it does not matter how the triangles are wound.
      final p = vertices[_tri[t * 3 + e]], q = vertices[_tri[t * 3 + (e + 1) % 3]];
      final c = _centers[t];
      Vector3 left, right;
      if (_area(c, p, q) > 0) {
        left = p.clone();
        right = q.clone();
      } else {
        left = q.clone();
        right = p.clone();
      }
      if (agentRadius > 0) {
        final edge = left - right;
        final len = edge.length;
        if (len > 2 * agentRadius) {
          final dir = edge / len;
          right += dir * agentRadius;
          left -= dir * agentRadius;
        } else {
          final mid = (left + right) * 0.5;
          left = mid.clone();
          right = mid.clone();
        }
      }
      lefts.add(left);
      rights.add(right);
    }
    lefts.add(end);
    rights.add(end);

    double area(Vector3 a, Vector3 b, Vector3 c) => _area(a, b, c);
    bool same(Vector3 a, Vector3 b) => (a.x - b.x).abs() < 1e-6 && (a.z - b.z).abs() < 1e-6;

    final path = <Vector3>[start];
    var apex = start.clone(), left = lefts[0].clone(), right = rights[0].clone();
    var apexI = 0, leftI = 0, rightI = 0;
    final count = lefts.length;
    var guard = 0;
    for (var i = 1; i < count && guard < count * 8; i++, guard++) {
      final l = lefts[i], r = rights[i];
      // tighten the right side
      if (area(apex, right, r) <= 0) {
        if (same(apex, right) || area(apex, left, r) > 0) {
          right = r.clone();
          rightI = i;
        } else {
          path.add(left.clone()); // the left side crossed over: left becomes a corner of the path
          apex = left.clone();
          apexI = leftI;
          left = apex.clone();
          right = apex.clone();
          leftI = apexI;
          rightI = apexI;
          i = apexI;
          continue;
        }
      }
      // tighten the left side
      if (area(apex, left, l) >= 0) {
        if (same(apex, left) || area(apex, right, l) < 0) {
          left = l.clone();
          leftI = i;
        } else {
          path.add(right.clone());
          apex = right.clone();
          apexI = rightI;
          left = apex.clone();
          right = apex.clone();
          leftI = apexI;
          rightI = apexI;
          i = apexI;
          continue;
        }
      }
    }
    if (path.length == 1 || !same(path.last, end)) path.add(end.clone());
    return path;
  }
}

/// A mesh and where it is in the world, for [NavMesh.fromMeshes].
class NavSource {
  NavSource(this.mesh, this.transform);
  final Mesh mesh;
  final Matrix4 transform;
}

class _Heap {
  final List<int> _items = [];
  final List<double> _keys = [];

  bool get isNotEmpty => _items.isNotEmpty;

  void push(int item, double key) {
    _items.add(item);
    _keys.add(key);
    var i = _items.length - 1;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_keys[p] <= _keys[i]) break;
      _swap(i, p);
      i = p;
    }
  }

  int pop() {
    final top = _items[0];
    final last = _items.length - 1;
    _swap(0, last);
    _items.removeLast();
    _keys.removeLast();
    var i = 0;
    while (true) {
      final l = i * 2 + 1, r = l + 1;
      var m = i;
      if (l < _items.length && _keys[l] < _keys[m]) m = l;
      if (r < _items.length && _keys[r] < _keys[m]) m = r;
      if (m == i) break;
      _swap(i, m);
      i = m;
    }
    return top;
  }

  void _swap(int a, int b) {
    final ti = _items[a];
    _items[a] = _items[b];
    _items[b] = ti;
    final tk = _keys[a];
    _keys[a] = _keys[b];
    _keys[b] = tk;
  }
}
