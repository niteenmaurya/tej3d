import 'dart:math' as math;

/// A cell on the grid.
typedef Cell = (int x, int y);

/// A* path finding on a 2D grid. Use it for AI on the ground plane: map world
/// X and Z to cells yourself (for example `cell = (x / size).floor()`).
class GridPath {
  GridPath(this.width, this.height)
    : assert(width > 0 && height > 0),
      _blocked = List.filled(width * height, false);

  final int width;
  final int height;
  final List<bool> _blocked;

  bool inside(int x, int y) => x >= 0 && y >= 0 && x < width && y < height;

  void setBlocked(int x, int y, bool blocked) {
    if (inside(x, y)) _blocked[y * width + x] = blocked;
  }

  bool isBlocked(int x, int y) => !inside(x, y) || _blocked[y * width + x];

  /// Finds the cheapest path from [start] to [end], both included.
  /// Returns null if there is none. Diagonal moves never cut corners.
  List<Cell>? find(Cell start, Cell end, {bool diagonal = true}) {
    if (isBlocked(start.$1, start.$2) || isBlocked(end.$1, end.$2)) return null;
    if (start == end) return [start];

    final n = width * height;
    final g = List<double>.filled(n, double.infinity);
    final from = List<int>.filled(n, -1);
    final closed = List<bool>.filled(n, false);
    final open = _Heap();

    int idx(Cell c) => c.$2 * width + c.$1;
    double h(int x, int y) {
      final dx = (x - end.$1).abs();
      final dy = (y - end.$2).abs();
      if (!diagonal) return (dx + dy).toDouble();
      return (dx + dy) + (math.sqrt2 - 2) * math.min(dx, dy);
    }

    final s = idx(start);
    final e = idx(end);
    g[s] = 0;
    open.push(s, h(start.$1, start.$2));

    while (open.isNotEmpty) {
      final cur = open.pop();
      if (closed[cur]) continue;
      closed[cur] = true;
      if (cur == e) break;
      final cx = cur % width;
      final cy = cur ~/ width;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final diag = dx != 0 && dy != 0;
          if (diag && !diagonal) continue;
          final nx = cx + dx;
          final ny = cy + dy;
          if (isBlocked(nx, ny)) continue;
          if (diag && (isBlocked(cx + dx, cy) || isBlocked(cx, cy + dy))) {
            continue;
          }
          final ni = ny * width + nx;
          if (closed[ni]) continue;
          final cost = g[cur] + (diag ? math.sqrt2 : 1.0);
          if (cost < g[ni]) {
            g[ni] = cost;
            from[ni] = cur;
            open.push(ni, cost + h(nx, ny));
          }
        }
      }
    }

    if (from[e] == -1) return null;
    final path = <Cell>[];
    for (var i = e; i != -1; i = from[i]) {
      path.add((i % width, i ~/ width));
    }
    return path.reversed.toList();
  }
}

// A small binary min-heap of (cell index, priority). Stale entries are
// skipped by the caller through the `closed` list.
class _Heap {
  final List<int> _items = [];
  final List<double> _prio = [];

  bool get isNotEmpty => _items.isNotEmpty;

  void push(int item, double priority) {
    _items.add(item);
    _prio.add(priority);
    var i = _items.length - 1;
    while (i > 0) {
      final p = (i - 1) ~/ 2;
      if (_prio[p] <= _prio[i]) break;
      _swap(i, p);
      i = p;
    }
  }

  int pop() {
    final top = _items.first;
    final last = _items.length - 1;
    _swap(0, last);
    _items.removeLast();
    _prio.removeLast();
    var i = 0;
    while (true) {
      final l = 2 * i + 1;
      final r = l + 1;
      var m = i;
      if (l < _items.length && _prio[l] < _prio[m]) m = l;
      if (r < _items.length && _prio[r] < _prio[m]) m = r;
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
    final tp = _prio[a];
    _prio[a] = _prio[b];
    _prio[b] = tp;
  }
}
