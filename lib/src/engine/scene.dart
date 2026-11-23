part of 'game_object.dart';

/// All objects of a level. Call [update] and [lateUpdate] every frame.
/// Objects are drawn by the render system, which reads the scene with
/// [forEachActive].
class Scene {
  final List<GameObject> _roots = [];
  final List<GameObject> _pendingDestroy = [];

  /// Light that comes from everywhere (rgb 0..1).
  Vector3 ambientColor = Vector3(0.35, 0.37, 0.42);

  /// Background color (rgba 0..1).
  Vector4 clearColor = Vector4(0.53, 0.70, 0.90, 1.0);

  /// Lines and shapes drawn on top for finding bugs. See [DebugDraw].
  final DebugDraw debug = DebugDraw();

  List<GameObject> get roots => List.unmodifiable(_roots);

  int get rootCount => _roots.length;

  /// Puts a top level object in the scene (its children come with it).
  GameObject add(GameObject go) {
    if (go.isDestroyed) {
      throw StateError('"${go.name}" has been destroyed and cannot be added to a scene.');
    }
    if (go._scene != null) {
      throw StateError('"${go.name}" is already in a scene.');
    }
    if (go.transform.parent != null) {
      throw StateError('"${go.name}" has a parent. Add the parent instead.');
    }
    _roots.add(go);
    go._attachTo(this);
    return go;
  }

  void _removeRoot(GameObject go) => _roots.remove(go);

  /// Removes the object at the end of the frame.
  void destroy(GameObject go) {
    if (go._destroyed || _pendingDestroy.contains(go)) return;
    _pendingDestroy.add(go);
  }

  /// Visits every object that is active, parents before children.
  void forEachActive(void Function(GameObject go) visit) {
    final roots = List<GameObject>.of(_roots);
    for (var i = 0; i < roots.length; i++) {
      _visit(roots[i], visit, true);
    }
  }

  /// Visits every object, also the inactive ones.
  void forEachAll(void Function(GameObject go) visit) {
    final roots = List<GameObject>.of(_roots);
    for (var i = 0; i < roots.length; i++) {
      _visit(roots[i], visit, false);
    }
  }

  static void _visit(
    GameObject g,
    void Function(GameObject go) visit,
    bool activeOnly,
  ) {
    if (g._destroyed) return;
    if (activeOnly && !g._activeSelf) return;
    visit(g);
    if (g._destroyed) return;
    final kids = List<Transform>.of(g.transform.children);
    for (var i = 0; i < kids.length; i++) {
      final o = kids[i].owner;
      if (o is GameObject) _visit(o, visit, activeOnly);
    }
  }

  GameObject? find(String name) {
    GameObject? found;
    forEachAll((g) {
      if (found == null && g.name == name) found = g;
    });
    return found;
  }

  GameObject? findWithTag(String tag) {
    GameObject? found;
    forEachActive((g) {
      if (found == null && g.tag == tag) found = g;
    });
    return found;
  }

  List<GameObject> findAllWithTag(String tag) {
    final out = <GameObject>[];
    forEachActive((g) {
      if (g.tag == tag) out.add(g);
    });
    return out;
  }

  /// First active component of type [T] in the scene.
  T? findComponent<T extends Component>() {
    T? found;
    forEachActive((g) {
      if (found == null) found = g.getComponent<T>();
    });
    return found;
  }

  List<T> findComponents<T extends Component>() {
    final out = <T>[];
    forEachActive((g) => out.addAll(g.getComponents<T>()));
    return out;
  }

  void _syncLifecycle() {
    forEachAll((g) {
      final list = List<Component>.of(g._components);
      for (var i = 0; i < list.length; i++) {
        final c = list[i];
        if (!c.isAttached || g.isDestroyed) continue;
        final active = g.activeInHierarchy;
        if (!c._awoken && active) {
          c._awoken = true;
          c.awake();
          if (!c.isAttached || g.isDestroyed) continue;
        }
        final should = g.activeInHierarchy && c._enabled && c._awoken;
        if (should && !c._enableCalled) {
          c._enableCalled = true;
          c.onEnable();
        } else if (!should && c._enableCalled) {
          c._enableCalled = false;
          c.onDisable();
        }
      }
    });
  }

  /// Runs awake, onEnable, start and update of all components.
  void update(double dt) {
    debug.beginFrame(dt);
    _syncLifecycle();
    forEachActive((g) {
      final list = List<Component>.of(g._components);
      for (var i = 0; i < list.length; i++) {
        final c = list[i];
        if (!c.isAttached || g.isDestroyed) continue;
        if (!c._enableCalled) continue;
        if (!c._started) {
          c._started = true;
          c.start();
          if (!c.isAttached || g.isDestroyed || !c._enableCalled) continue;
        }
        c.update(dt);
      }
    });
  }

  void lateUpdate(double dt) {
    forEachActive((g) {
      final list = List<Component>.of(g._components);
      for (var i = 0; i < list.length; i++) {
        final c = list[i];
        if (!c.isAttached || g.isDestroyed) continue;
        if (c._enableCalled && c._started) c.lateUpdate(dt);
      }
    });
    _flushDestroy();
  }

  void fixedUpdate(double dt) {
    forEachActive((g) {
      final list = List<Component>.of(g._components);
      for (var i = 0; i < list.length; i++) {
        final c = list[i];
        if (!c.isAttached || g.isDestroyed) continue;
        if (c._enableCalled && c._started) c.fixedUpdate(dt);
      }
    });
  }

  /// Removes the objects marked with `destroy()` right now. Normally this happens at the end of
  /// [lateUpdate]; an editor calls it when the game is not running.
  void flushDestroy() => _flushDestroy();

  void _flushDestroy() {
    if (_pendingDestroy.isEmpty) return;
    final pending = List<GameObject>.of(_pendingDestroy);
    _pendingDestroy.clear();
    for (final g in pending) {
      g._finishDestroy();
      _roots.remove(g);
    }
  }

  /// Removes everything at once (calls onDestroy).
  void clear() {
    for (final g in List<GameObject>.of(_roots)) {
      g._finishDestroy();
    }
    _roots.clear();
    _pendingDestroy.clear();
  }
}
