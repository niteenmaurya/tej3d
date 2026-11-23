import 'package:flutter/foundation.dart';

/// The set of overlay names that are visible. Like Flame's `overlays`.
///
/// ```dart
/// game.overlays.add('hud');
/// game.overlays.remove('hud');
/// ```
class ActiveOverlays extends ChangeNotifier {
  final Set<String> _names = <String>{};

  Set<String> get names => Set.unmodifiable(_names);

  bool isActive(String name) => _names.contains(name);

  /// Shows an overlay. Returns false if it was already active.
  bool add(String name) {
    final added = _names.add(name);
    if (added) notifyListeners();
    return added;
  }

  /// Shows several overlays with one notification.
  void addAll(Iterable<String> names) {
    final before = _names.length;
    _names.addAll(names);
    if (_names.length != before) notifyListeners();
  }

  /// Hides an overlay. Returns false if it was not active.
  bool remove(String name) {
    final removed = _names.remove(name);
    if (removed) notifyListeners();
    return removed;
  }

  void clear() {
    if (_names.isEmpty) return;
    _names.clear();
    notifyListeners();
  }
}
