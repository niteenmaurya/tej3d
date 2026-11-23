import '../math/vec.dart';

/// A grid of cells for fast "what is near this point" questions
/// (AI sensing, pickups, explosions). Each item is stored by position.
class SpatialHash<T extends Object> {
  SpatialHash(this.cellSize) : assert(cellSize > 0);

  final double cellSize;

  final Map<(int, int, int), List<T>> _cells = {};
  final Map<T, (int, int, int)> _cellOf = {};
  final Map<T, Vector3> _pos = {};

  int get length => _pos.length;

  (int, int, int) _key(Vector3 p) => (
    (p.x / cellSize).floor(),
    (p.y / cellSize).floor(),
    (p.z / cellSize).floor(),
  );

  void insert(T item, Vector3 position) {
    if (_pos.containsKey(item)) remove(item);
    final k = _key(position);
    (_cells[k] ??= <T>[]).add(item);
    _cellOf[item] = k;
    _pos[item] = position.clone();
  }

  bool remove(T item) {
    final k = _cellOf.remove(item);
    if (k == null) return false;
    final list = _cells[k];
    list?.remove(item);
    if (list != null && list.isEmpty) _cells.remove(k);
    _pos.remove(item);
    return true;
  }

  /// Moves an item. Cheap when it stays in the same cell.
  void move(T item, Vector3 position) {
    final old = _cellOf[item];
    final k = _key(position);
    if (old == k) {
      _pos[item]!.setFrom(position);
      return;
    }
    insert(item, position);
  }

  Vector3? positionOf(T item) => _pos[item]?.clone();

  /// All items closer than [radius] to [center].
  List<T> queryRadius(Vector3 center, double radius) {
    final out = <T>[];
    final r2 = radius * radius;
    final lo = _key(Vector3(center.x - radius, center.y - radius, center.z - radius));
    final hi = _key(Vector3(center.x + radius, center.y + radius, center.z + radius));
    for (var x = lo.$1; x <= hi.$1; x++) {
      for (var y = lo.$2; y <= hi.$2; y++) {
        for (var z = lo.$3; z <= hi.$3; z++) {
          final list = _cells[(x, y, z)];
          if (list == null) continue;
          for (final item in list) {
            if (_pos[item]!.distanceToSquared(center) <= r2) out.add(item);
          }
        }
      }
    }
    return out;
  }

  void clear() {
    _cells.clear();
    _cellOf.clear();
    _pos.clear();
  }
}
