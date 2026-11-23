/// Loads assets once and shares them, with a reference count, like Unity
/// Addressables. The first `load` of a key runs the loader. Every `load`
/// must be matched by one `release`. At 0 the asset is disposed.
class AssetCache {
  final Map<String, _Entry> _entries = {};

  int get count => _entries.length;

  bool contains(String key) => _entries.containsKey(key);

  int refCount(String key) => _entries[key]?.refs ?? 0;

  Future<T> load<T extends Object>(
    String key,
    Future<T> Function() loader, {
    void Function(T asset)? onDispose,
  }) async {
    var e = _entries[key];
    if (e == null) {
      e = _Entry(
        Future<Object>.sync(loader),
        onDispose == null ? null : (Object o) => onDispose(o as T),
      );
      _entries[key] = e;
    }
    e.refs++;
    try {
      final v = await e.future;
      return v as T;
    } catch (_) {
      e.refs--;
      if (identical(_entries[key], e)) {
        _entries.remove(key);
      }
      rethrow;
    }
  }

  /// Gives one reference back. Returns true if the asset was disposed.
  bool release(String key) {
    final e = _entries[key];
    if (e == null) return false;
    e.refs--;
    if (e.refs > 0) return false;
    _entries.remove(key);
    e.future.then((v) => e.dispose?.call(v), onError: (Object _) {});
    return true;
  }

  void clear() {
    for (final key in _entries.keys.toList()) {
      final e = _entries.remove(key)!;
      e.future.then((v) => e.dispose?.call(v), onError: (Object _) {});
    }
  }
}

class _Entry {
  _Entry(this.future, this.dispose);

  final Future<Object> future;
  final void Function(Object asset)? dispose;
  int refs = 0;
}
