import '../math/vec.dart';

import 'transform.dart';

import 'debug_draw.dart';

part 'scene.dart';

/// A part of a [GameObject] that gives it behavior or looks. Extend it and
/// override the methods you need, like `MonoBehaviour` in Unity.
///
/// Order: [awake] once, [onEnable], [start] once before the first update,
/// then every frame [update] and [lateUpdate]. [onDisable] and [onDestroy]
/// when it goes away.
abstract class Component {
  GameObject? _gameObject;
  bool _enabled = true;
  bool _awoken = false;
  bool _enableCalled = false;
  bool _started = false;

  /// The object this component is on.
  bool get isAttached => _gameObject != null;

  GameObject get gameObject {
    final g = _gameObject;
    if (g == null) throw StateError('Component is not on a GameObject yet.');
    return g;
  }

  Transform get transform => gameObject.transform;

  /// A disabled component gets no updates.
  bool get enabled => _enabled;
  set enabled(bool v) => _enabled = v;

  void awake() {}
  void onEnable() {}
  void start() {}
  void update(double dt) {}
  void lateUpdate(double dt) {}

  /// Called by [Scene.fixedUpdate] with equal time steps.
  void fixedUpdate(double dt) {}
  void onDisable() {}
  void onDestroy() {}

  /// Physics callbacks. Called by a physics system (see `NativePhysics`).
  void onCollisionEnter(GameObject other) {}
  void onCollisionExit(GameObject other) {}
  void onTriggerEnter(GameObject other) {}
  void onTriggerExit(GameObject other) {}
}

/// Something in the world. It holds a [Transform], a tag, a layer and
/// components. Like Unity `GameObject`.
class GameObject {
  GameObject(
    this.name, {
    this.tag = 'Untagged',
    this.layer = 0,
    Vector3? position,
    Quaternion? rotation,
    Vector3? scale,
  }) : transform = Transform(
         position: position,
         rotation: rotation,
         scale: scale,
       ) {
    transform.owner = this;
  }

  String name;
  String tag;

  /// Layer number 0..31. See `Layers` and `LayerMask`.
  int layer;

  final Transform transform;

  final List<Component> _components = [];
  Scene? _scene;
  bool _activeSelf = true;
  bool _destroyed = false;

  /// The scene this object is in, or null.
  Scene? get scene => _scene;

  bool get isDestroyed => _destroyed;

  /// The switch of this object alone.
  bool get activeSelf => _activeSelf;
  set active(bool v) => _activeSelf = v;

  /// False if this object or any parent is off.
  bool get activeInHierarchy {
    if (_destroyed || !_activeSelf) return false;
    final p = parent;
    return p == null || p.activeInHierarchy;
  }

  GameObject? get parent {
    final o = transform.parent?.owner;
    return o is GameObject ? o : null;
  }

  List<GameObject> get children => [
    for (final t in transform.children)
      if (t.owner is GameObject) t.owner as GameObject,
  ];

  /// Makes [child] a child of this object. If this object is in a scene,
  /// the child joins the scene too.
  void addChild(GameObject child, {bool keepWorld = false}) {
    child._scene?._removeRoot(child);
    child.transform.setParent(transform, keepWorld: keepWorld);
    final s = _scene;
    if (s == null) {
      child._detachFromScene();
    } else {
      child._attachTo(s);
    }
  }

  /// Place among the brothers and sisters (children of the same parent, or the top level objects of the scene).
  int get siblingIndex {
    final p = transform.parent;
    if (p != null) return transform.siblingIndex;
    final s = _scene;
    return s == null ? 0 : s._roots.indexOf(this);
  }

  /// Moves this object to place [index] among its brothers and sisters (0 = first, drawn and updated first).
  void setSiblingIndex(int index) {
    if (transform.parent != null) {
      transform.setSiblingIndex(index);
      return;
    }
    final s = _scene;
    if (s == null) return;
    s._roots.remove(this);
    s._roots.insert(index.clamp(0, s._roots.length), this);
  }

  /// Takes this object out of its parent and makes it a top level object of its scene.
  /// Does nothing when it has no parent.
  void detachFromParent({bool keepWorld = false}) {
    if (transform.parent == null) return;
    transform.setParent(null, keepWorld: keepWorld);
    _scene?._roots.add(this);
  }

  void _attachTo(Scene s) {
    _scene = s;
    for (final c in children) {
      c._attachTo(s);
    }
  }

  void _detachFromScene() {
    for (final c in List<Component>.of(_components)) {
      if (c._enableCalled) {
        c._enableCalled = false;
        c.onDisable();
      }
    }
    _scene = null;
    for (final c in children) {
      c._detachFromScene();
    }
  }

  T addComponent<T extends Component>(T component) {
    if (component._gameObject != null) {
      throw StateError('This component is already on an object.');
    }
    component._gameObject = this;
    _components.add(component);
    return component;
  }

  /// Like [addComponent] but puts the component at [index] in the list (an editor uses it to undo a removal).
  T insertComponent<T extends Component>(int index, T component) {
    addComponent(component);
    _components
      ..removeLast()
      ..insert(index.clamp(0, _components.length), component);
    return component;
  }

  T? getComponent<T extends Component>() {
    for (final c in _components) {
      if (c is T) return c;
    }
    return null;
  }

  List<T> getComponents<T extends Component>() => [
    for (final c in _components)
      if (c is T) c,
  ];

  T? getComponentInChildren<T extends Component>() {
    final own = getComponent<T>();
    if (own != null) return own;
    for (final child in children) {
      final f = child.getComponentInChildren<T>();
      if (f != null) return f;
    }
    return null;
  }

  T? getComponentInParent<T extends Component>() {
    final own = getComponent<T>();
    if (own != null) return own;
    return parent?.getComponentInParent<T>();
  }

  /// All components, read only (makes a copy; use [componentCount] and
  /// [componentAt] inside per-frame loops).
  List<Component> get components => List.unmodifiable(_components);

  int get componentCount => _components.length;

  Component componentAt(int index) => _components[index];

  /// Removes a component at once (calls onDisable and onDestroy).
  bool removeComponent(Component c) {
    if (!_components.remove(c)) return false;
    c._endLife();
    c._gameObject = null;
    return true;
  }

  /// Marks this object (and children) to be removed at the end of the frame.
  void destroy() {
    final s = _scene;
    if (s != null) {
      s.destroy(this);
    } else {
      _finishDestroy();
    }
  }

  void _finishDestroy() {
    if (_destroyed) return;
    for (final c in children) {
      c._finishDestroy();
    }
    _destroyed = true;
    final comps = List<Component>.of(_components);
    _components.clear();
    for (final c in comps) {
      c._endLife();
      c._gameObject = null;
    }
    transform.setParent(null);
    _scene = null;
  }
}

extension on Component {
  void _endLife() {
    if (_enableCalled) {
      _enableCalled = false;
      onDisable();
    }
    if (_awoken) onDestroy();
  }
}
