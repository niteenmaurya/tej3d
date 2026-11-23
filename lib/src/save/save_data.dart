import 'dart:convert';

/// Where save data is kept. Implement this with shared_preferences, a file,
/// or a cloud service. The engine has no storage dependency on purpose.
abstract class SaveStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Keeps data in memory only. Good for tests.
class MemorySaveStorage implements SaveStorage {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

/// Simple key-value game save, stored as one JSON string.
///
/// ```dart
/// final save = SaveData(storage);
/// await save.load();
/// save.set('bestLap', 41.2);
/// await save.save();
/// ```
class SaveData {
  SaveData(this.storage, {this.key = 'tej3d_save'});

  final SaveStorage storage;
  final String key;
  Map<String, Object?> _values = {};

  Future<void> load() async {
    final text = await storage.read(key);
    if (text == null) {
      _values = {};
      return;
    }
    try {
      final decoded = jsonDecode(text);
      _values = decoded is Map<String, dynamic>
          ? Map<String, Object?>.from(decoded)
          : {};
    } on FormatException {
      _values = {};
    }
  }

  Future<void> save() => storage.write(key, jsonEncode(_values));

  Future<void> clear() async {
    _values = {};
    await storage.delete(key);
  }

  /// Value must be JSON friendly: num, String, bool, List, Map or null.
  void set(String name, Object? value) => _values[name] = value;

  T? get<T>(String name) {
    final v = _values[name];
    return v is T ? v : null;
  }

  int getInt(String name, [int fallback = 0]) {
    final v = _values[name];
    return v is num ? v.toInt() : fallback;
  }

  double getDouble(String name, [double fallback = 0.0]) {
    final v = _values[name];
    return v is num ? v.toDouble() : fallback;
  }

  bool has(String name) => _values.containsKey(name);
}
