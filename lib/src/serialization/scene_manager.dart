import 'dart:async';

import '../engine/game_object.dart';

/// Builds the content of a scene. Add objects to [scene].
typedef SceneBuilder = FutureOr<void> Function(Scene scene);

/// Loads, unloads and updates several scenes (Unity `SceneManager`).
///
/// ```dart
/// final scenes = SceneManager()
///   ..register('menu', (s) => buildMenu(s))
///   ..register('level1', (s) => buildLevel(s))
///   ..register('hud', (s) => buildHud(s));
/// await scenes.load('level1');                    // replaces everything
/// await scenes.load('hud', additive: true);       // adds a second scene
/// scenes.update(dt);                              // updates all loaded scenes
/// ```
class SceneManager {
  final Map<String, SceneBuilder> _builders = {};
  final Map<String, Scene> _loaded = {};
  String? _active;

  /// Names the builder of a scene. Throws if the name is taken.
  void register(String name, SceneBuilder builder) {
    if (_builders.containsKey(name)) {
      throw ArgumentError('Scene "$name" is already registered.');
    }
    _builders[name] = builder;
  }

  /// Names of the loaded scenes, in load order.
  List<String> get loadedNames => List.unmodifiable(_loaded.keys);

  int get loadedCount => _loaded.length;

  bool isLoaded(String name) => _loaded.containsKey(name);

  /// The loaded scene named [name], or null.
  Scene? operator [](String name) => _loaded[name];

  /// The active scene (the one new objects should go to and whose lights and
  /// background are used). Null if nothing is loaded.
  Scene? get active => _active == null ? null : _loaded[_active];
  String? get activeName => _active;

  /// Makes a loaded scene the active one.
  void setActive(String name) {
    if (!_loaded.containsKey(name)) {
      throw StateError('Scene "$name" is not loaded.');
    }
    _active = name;
  }

  /// Loads [name]. Without [additive] every loaded scene is unloaded first.
  /// The new scene becomes active unless [makeActive] is false.
  ///
  /// The scene is only visible in [loadedNames] once its builder has finished.
  /// If the builder throws, the half built scene is cleared, and the error
  /// goes on to the caller.
  Future<Scene> load(
    String name, {
    bool additive = false,
    bool makeActive = true,
  }) async {
    final builder = _builders[name];
    if (builder == null) {
      throw ArgumentError('Scene "$name" is not registered.');
    }
    if (_loaded.containsKey(name)) {
      throw StateError('Scene "$name" is already loaded. Unload it first.');
    }
    if (!additive) unloadAll();
    final scene = Scene();
    try {
      await builder(scene);
    } catch (_) {
      scene.clear();
      rethrow;
    }
    _loaded[name] = scene;
    if (makeActive || _active == null) _active = name;
    return scene;
  }

  /// Destroys all objects of a loaded scene and forgets it. If it was the
  /// active scene, the last loaded one becomes active.
  bool unload(String name) {
    final s = _loaded.remove(name);
    if (s == null) return false;
    s.clear();
    if (_active == name) {
      _active = _loaded.isEmpty ? null : _loaded.keys.last;
    }
    return true;
  }

  void unloadAll() {
    for (final name in List<String>.of(_loaded.keys)) {
      unload(name);
    }
  }

  void update(double dt) {
    for (final s in List<Scene>.of(_loaded.values)) {
      s.update(dt);
    }
  }

  void lateUpdate(double dt) {
    for (final s in List<Scene>.of(_loaded.values)) {
      s.lateUpdate(dt);
    }
  }

  void fixedUpdate(double dt) {
    for (final s in List<Scene>.of(_loaded.values)) {
      s.fixedUpdate(dt);
    }
  }

  /// Visits every active object in every loaded scene.
  void forEachActive(void Function(GameObject go) visit) {
    for (final s in _loaded.values) {
      s.forEachActive(visit);
    }
  }
}
