/// Reuses objects instead of making new ones, so the garbage collector does
/// not cause frame drops (bullets, particles, effects).
class ObjectPool<T> {
  ObjectPool({
    required T Function() create,
    void Function(T item)? onGet,
    void Function(T item)? onRelease,
    this.maxSize = 256,
    int prewarm = 0,
  }) : _create = create,
       _onGet = onGet,
       _onRelease = onRelease {
    final count = prewarm < 0 ? 0 : (prewarm > maxSize ? maxSize : prewarm);
    for (var i = 0; i < count; i++) {
      final item = _make();
      _free.add(item);
      _freeSet.add(item);
    }
  }

  final T Function() _create;
  final void Function(T item)? _onGet;
  final void Function(T item)? _onRelease;

  /// Free items above this number are thrown away on release.
  final int maxSize;

  final List<T> _free = [];
  final Set<T> _freeSet = Set<T>.identity();
  int _created = 0;

  int get available => _free.length;
  int get totalCreated => _created;

  T _make() {
    _created++;
    return _create();
  }

  T get() {
    final T item;
    if (_free.isEmpty) {
      item = _make();
    } else {
      item = _free.removeLast();
      _freeSet.remove(item);
    }
    _onGet?.call(item);
    return item;
  }

  void release(T item) {
    if (_freeSet.contains(item)) return;
    _onRelease?.call(item);
    if (_free.length < maxSize) {
      _free.add(item);
      _freeSet.add(item);
    }
  }
}
