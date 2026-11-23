/// The door an editor program uses to look at and change a running game.
///
/// The editor is a separate program (desktop or web). It connects to the game with the networking
/// core (a [NetHost] in the game, a `NetClient` in the editor) and makes calls:
///
/// ```dart
/// // in the game
/// final host = NetHost();
/// final bridge = EditorBridge(host, scene, registry);
/// await NetWebSocketServer.bind(host, port: 7778);        // from `package:tej3d/net_io.dart`
/// // every frame, instead of scene.update(dt):
/// bridge.update(dt, (dt) { scene.update(dt); scene.lateUpdate(dt); });
///
/// // in the editor
/// final tree = await client.callHost('editor.tree');
/// await client.callHost('editor.setObject', {'id': 3, 'props': {'position': [0, 1, 0]}});
/// ```
///
/// All values are plain JSON. Objects have a number (`id`) that stays the same while the game
/// lives, also after play mode is stopped (the scene is restored in the same order, so the
/// numbers match again). The bridge does no login: bind the server to this computer only
/// (the default of `NetWebSocketServer`) or use its `authorize` option.
///
/// Calls (arguments in braces, `?` = optional):
///
/// | call | what it does |
/// |---|---|
/// | `editor.hello` | `{version, playing, paused, selected}` |
/// | `editor.types` | `{components: [...], meshes: [...]}` the names you can add |
/// | `editor.tree` | `{roots: [{id, name, active, children: [...]}]}` |
/// | `editor.get {id}` | one object with its components and their fields (see [Inspector]) |
/// | `editor.setObject {id, props}` | name, tag, layer, active, position, rotation (degrees), scale |
/// | `editor.setComponent {id, index, fields?, enabled?}` | write fields of one component |
/// | `editor.addComponent {id, type, data?}` | `type` is a registered name; returns `{index}` |
/// | `editor.removeComponent {id, index}` | |
/// | `editor.create {name?, parent?, position?, components?}` | returns `{id}` |
/// | `editor.delete {id}`, `editor.duplicate {id}`, `editor.reparent {id, parent?, keepWorld?}` | |
/// | `editor.select {id?}` | outline (drawn with `scene.debug`) |
/// | `editor.pick {x, y, width, height, select?}` | object under a screen point (mesh bounds): `{id, distance, point}`, `id` is null for nothing |
/// | `editor.setScene {ambient?, clear?}` | background light and color |
/// | `editor.save` / `editor.load {scene}` | whole scene as JSON (`SceneIO`) |
/// | `editor.play`, `editor.pause {paused?}`, `editor.step`, `editor.stop` | play mode |
/// | `editor.undo`, `editor.redo`, `editor.history`, `editor.clearHistory` | undo and redo of edits made in edit mode (see below) |
///
/// Undo and redo: every edit made while the game is **not** playing (set object or component, add or
/// remove a component, create, delete, duplicate, reparent) is remembered, up to [maxHistory] steps.
/// Edits made during play are not remembered (they are lost at stop anyway). Loading a scene clears
/// the history. Undo brings deleted objects back with the same numbers and the same place in the tree.
///
/// A failed call ends with a `NetRpcError` that says why. When something about the scene
/// shape changes, all connected editors get the message `editor.changed` (`{what: 'tree'}` or
/// `{what: 'state'}`) and can ask again.
library;

import 'dart:convert';

import '../engine/camera.dart';
import '../engine/debug_draw.dart';
import '../engine/game_object.dart';
import '../engine/mesh_renderer.dart';
import '../math/vec.dart';
import '../net/net_core.dart';
import '../serialization/component_registry.dart';
import '../serialization/prefab.dart';
import '../serialization/scene_io.dart';
import 'inspector.dart';

/// Serves the `editor.*` calls for one [Scene]. See the library comment.
class EditorBridge {
  EditorBridge(this.host, this.scene, this.registry, {this.stepSeconds = 1.0 / 60.0}) {
    _register();
  }

  final NetHost host;
  final Scene scene;
  final ComponentRegistry registry;

  /// Time given to the game for one `editor.step`.
  double stepSeconds;

  /// The camera used by `editor.pick`. When null, the first camera in the scene is used.
  Camera? camera;

  /// True from `editor.play` until `editor.stop`. The scene is saved when play starts and
  /// restored when it stops.
  bool get playing => _playing;

  /// True while play mode is paused.
  bool get paused => _paused;

  /// The selected object (outlined by [update]), or null.
  GameObject? get selected => _validObject(_selectedId);

  /// Most edits kept for undo.
  int maxHistory = 200;

  /// True when [undo] has something to undo.
  bool get canUndo => _undo.isNotEmpty;

  /// True when [redo] has something to redo.
  bool get canRedo => _redo.isNotEmpty;

  final List<_Command> _undo = [];
  final List<_Command> _redo = [];

  bool _playing = false;
  bool _paused = false;
  int _steps = 0;
  int? _selectedId;
  Map<String, Object?>? _snapshot;
  List<int> _snapshotIds = const [];

  final Map<GameObject, int> _ids = Map.identity();
  final Map<int, GameObject> _objects = {};
  final List<String> _registeredCalls = [];
  int _nextId = 1;

  /// Unregisters all `editor.*` RPC handlers from [host].
  void dispose() {
    for (final name in _registeredCalls) {
      host.removeCallHandler(name);
    }
    _registeredCalls.clear();
  }

  /// The number of [go] (it gets one when asked for the first time).
  int idOf(GameObject go) {
    final known = _ids[go];
    if (known != null) return known;
    final id = _nextId++;
    _ids[go] = id;
    _objects[id] = go;
    return id;
  }

  /// The object with this number, or null if there is none (any more).
  GameObject? find(int id) => _validObject(id);

  GameObject? _validObject(int? id) {
    if (id == null) return null;
    final go = _objects[id];
    if (go == null || go.isDestroyed || go.scene != scene) return null;
    return go;
  }

  /// Call this every frame **instead of** your own `scene.update`. It runs [runGame] (your update
  /// and late update) when the game is playing and not paused, or once per `editor.step`. In edit
  /// mode the scene stands still. It also draws the outline of the selected object.
  void update(double dt, void Function(double dt) runGame) {
    var ran = false;
    if (_playing && !_paused) {
      runGame(dt);
      ran = true;
    } else if (_playing && _steps > 0) {
      final n = _steps > 10 ? 10 : _steps; // never a long freeze from many step calls
      _steps = 0;
      for (var i = 0; i < n; i++) {
        runGame(stepSeconds);
      }
      ran = true;
    }
    if (!ran) scene.debug.beginFrame(dt); // Scene.update does this itself
    _drawSelection();
  }

  // ===================================================================
  // calls
  // ===================================================================

  void _register() {
    void on(String name, Object? Function(Map<String, Object?> a) f) {
      final full = 'editor.$name';
      _registeredCalls.add(full);
      host.handleCall(full, (from, args) => f(_map(args)));
    }

    on('hello', (_) => {'version': 1, 'playing': _playing, 'paused': _paused, 'selected': selected == null ? null : _selectedId});
    on('types', (_) => {
          'components': registry.typeNames.toList()..sort(),
          'meshes': registry.meshNames.toList()..sort(),
        });
    on('tree', (_) => _tree());
    on('get', (a) => _describe(_need(a['id'])));
    on('setObject', (a) {
      final go = _need(a['id']);
      final id = idOf(go);
      final before = _ObjState.of(go);
      final errors = Inspector.setObject(go, _map(a['props']));
      final after = _ObjState.of(go);
      if (!before.same(after)) {
        _record('Edit ${after.name}', () => _withObject(id, before.applyTo), () => _withObject(id, after.applyTo));
      }
      return {'errors': errors};
    });
    on('setComponent', (a) {
      final go = _need(a['id']);
      final c = _component(go, a['index']);
      final id = idOf(go), index = (a['index'] as num).toInt();
      final names = _map(a['fields']).keys.toSet();
      Map<String, Object?> read() => {
            for (final f in Inspector.fieldsOf(c))
              if (names.contains(f.name) && !f.readOnly) f.name: f.value,
          };
      final before = read(), enBefore = c.enabled;
      final errors = Inspector.setFields(c, _map(a['fields']));
      final en = a['enabled'];
      if (en != null) {
        if (en is bool) {
          c.enabled = en;
        } else {
          errors.add('enabled needs true or false');
        }
      }
      final after = read(), enAfter = c.enabled;
      if (!_valuesEqual(before, after) || enBefore != enAfter) {
        void apply(Map<String, Object?> values, bool enabled) => _withObject(id, (go) {
              if (index >= go.componentCount) return;
              final comp = go.componentAt(index);
              Inspector.setFields(comp, values);
              comp.enabled = enabled;
            });
        _record('Edit ${c.runtimeType}', () => apply(before, enBefore), () => apply(after, enAfter));
      }
      return {'errors': errors};
    });
    on('addComponent', (a) {
      final go = _need(a['id']);
      final c = _makeComponent(a['type'], a['data']);
      go.addComponent(c);
      final index = go.componentCount - 1;
      final id = idOf(go);
      final snap = _componentSnapshot(c);
      _record('Add ${c.runtimeType}', () => _withObject(id, (g) => _removeAt(g, index)),
          () => _withObject(id, (g) => _insertSnapshot(g, index, snap)));
      return {'index': index};
    });
    on('removeComponent', (a) {
      final go = _need(a['id']);
      final c = _component(go, a['index']);
      final index = (a['index'] as num).toInt();
      final id = idOf(go);
      final snap = _componentSnapshot(c); // null when this kind of component cannot be saved: then no undo
      go.removeComponent(c);
      if (snap != null) {
        _record('Remove ${c.runtimeType}', () => _withObject(id, (g) => _insertSnapshot(g, index, snap)),
            () => _withObject(id, (g) => _removeAt(g, index)));
      }
      return {};
    });
    on('create', _create);
    on('delete', (a) {
      final go = _need(a['id']);
      final tomb = _playing ? null : _Subtree.capture(this, go); // null: cannot be saved, so no undo
      _forget(go); // while the children are still linked
      go.destroy();
      if (!_playing) scene.flushDestroy(); // the game is not updating, so nobody else would
      if (tomb != null) _record('Delete ${tomb.name}', () => tomb.restore(this), () => _removeSubtree(tomb.ids.first));
      _changed('tree');
      return {};
    });
    on('duplicate', (a) {
      final go = _need(a['id']);
      final copy = Prefab.fromObject(go, registry).instantiate(registry);
      copy.name = '${go.name} (copy)';
      final parent = go.parent;
      if (parent != null) {
        parent.addChild(copy);
      } else {
        scene.add(copy);
      }
      final cid = idOf(copy);
      final tomb = _playing ? null : _Subtree.capture(this, copy);
      if (tomb != null) _record('Duplicate ${go.name}', () => _removeSubtree(cid), () => tomb.restore(this));
      _changed('tree');
      return {'id': cid};
    });
    on('reparent', (a) {
      final go = _need(a['id']);
      final id = idOf(go);
      final pid = a['parent'];
      final keep = a['keepWorld'] == true;
      final before = _Place.of(this, go);
      if (pid == null) {
        go.detachFromParent(keepWorld: keep);
      } else {
        final parent = _need(pid);
        if (identical(parent, go)) throw ArgumentError('An object cannot be its own parent.');
        parent.addChild(go, keepWorld: keep); // throws if parent is inside go
      }
      final after = _Place.of(this, go);
      _record('Reparent ${go.name}', () => _withObject(id, (g) => before.applyTo(this, g)),
          () => _withObject(id, (g) => after.applyTo(this, g)));
      _changed('tree');
      return {};
    });
    on('select', (a) {
      final id = a['id'];
      if (id == null) {
        _selectedId = null;
      } else {
        _need(id);
        _selectedId = (id as num).toInt();
      }
      return {'selected': _selectedId};
    });
    on('pick', _pick);
    on('setScene', (a) {
      final errors = <String>[];
      final amb = a['ambient'], clr = a['clear'];
      if (amb != null) {
        if (_isNums(amb, 3)) {
          scene.ambientColor = Vector3(_d(amb, 0), _d(amb, 1), _d(amb, 2));
        } else {
          errors.add('ambient needs 3 numbers');
        }
      }
      if (clr != null) {
        if (_isNums(clr, 4)) {
          scene.clearColor = Vector4(_d(clr, 0), _d(clr, 1), _d(clr, 2), _d(clr, 3));
        } else {
          errors.add('clear needs 4 numbers');
        }
      }
      return {'errors': errors};
    });
    on('save', (_) => {'scene': SceneIO.toJson(scene, registry)});
    on('load', (a) {
      if (_playing) throw StateError('Stop the game before loading a scene.');
      final json = a['scene'];
      if (json is! Map) throw ArgumentError('load needs {scene: ...}');
      final data = json.cast<String, Object?>();
      final backup = SceneIO.toJson(scene, registry, unknown: UnknownComponents.skip);
      scene.clear();
      try {
        SceneIO.loadInto(scene, data, registry);
      } catch (e) {
        scene.clear(); // a half loaded scene is worse than the old one: put the old one back
        SceneIO.loadInto(scene, backup, registry);
        _resetIds();
        _changed('tree');
        throw StateError('Could not load the scene: $e');
      }
      _resetIds();
      _undo.clear();
      _redo.clear();
      _changed('tree');
      return {};
    });
    on('undo', (_) => _step(_undo, _redo, 'undo'));
    on('redo', (_) => _step(_redo, _undo, 'redo'));
    on('history', (_) => _history());
    on('clearHistory', (_) {
      _undo.clear();
      _redo.clear();
      return _history();
    });
    on('play', (_) {
      if (!_playing) {
        _snapshot = SceneIO.toJson(scene, registry, unknown: UnknownComponents.skip);
        _snapshotIds = [for (final go in _depthFirst()) idOf(go)];
        _playing = true;
        _paused = false;
        _steps = 0;
        _changed('state');
      }
      return {'playing': _playing, 'paused': _paused};
    });
    on('pause', (a) {
      if (!_playing) throw StateError('The game is not playing.');
      final want = a['paused'];
      _paused = want is bool ? want : !_paused;
      _changed('state');
      return {'paused': _paused};
    });
    on('step', (_) {
      if (!_playing) throw StateError('The game is not playing.');
      _paused = true;
      _steps++;
      _changed('state');
      return {};
    });
    on('stop', (_) {
      if (_playing) {
        final snap = _snapshot!;
        final ids = _snapshotIds;
        scene.clear();
        SceneIO.loadInto(scene, snap, registry);
        _ids.clear();
        _objects.clear();
        final now = _depthFirst();
        for (var i = 0; i < now.length && i < ids.length; i++) {
          _ids[now[i]] = ids[i];
          _objects[ids[i]] = now[i];
        }
        _playing = false;
        _paused = false;
        _steps = 0;
        _snapshot = null;
        _snapshotIds = const [];
        _changed('tree');
        _changed('state');
      }
      return {'playing': _playing};
    });
  }

  // ===================================================================
  // parts
  // ===================================================================

  // ===================================================================
  // undo and redo
  // ===================================================================

  void _record(String name, void Function() undo, void Function() redo) {
    if (_playing) return;
    _undo.add(_Command(name, undo, redo));
    if (_undo.length > maxHistory) _undo.removeAt(0);
    _redo.clear();
  }

  Map<String, Object?> _step(List<_Command> from, List<_Command> to, String what) {
    if (_playing) throw StateError('Stop the game before $what.');
    if (from.isEmpty) return {'ok': false, ...(_history())};
    final c = from.removeLast();
    if (what == 'undo') {
      c.undo();
    } else {
      c.redo();
    }
    to.add(c);
    _changed('tree');
    return {'ok': true, 'name': c.name, ...(_history())};
  }

  Map<String, Object?> _history() => {
        'canUndo': _undo.isNotEmpty,
        'canRedo': _redo.isNotEmpty,
        'undoName': _undo.isEmpty ? null : _undo.last.name,
        'redoName': _redo.isEmpty ? null : _redo.last.name,
        'undoCount': _undo.length,
        'redoCount': _redo.length,
      };

  void _withObject(int id, void Function(GameObject go) f) {
    final go = _validObject(id);
    if (go != null) f(go);
  }

  /// A component as data (null if its class cannot be saved).
  _CompSnap? _componentSnapshot(Component c) {
    final type = registry.typeNameOf(c);
    if (type == null) return null;
    final data = registry.write(c);
    return data == null ? null : _CompSnap(type, jsonDecode(jsonEncode(data)) as Map<String, Object?>, c.enabled);
  }

  void _insertSnapshot(GameObject go, int index, _CompSnap? snap) {
    if (snap == null) return;
    go.insertComponent(index, registry.read(snap.type, snap.data)..enabled = snap.enabled);
  }

  void _removeAt(GameObject go, int index) {
    if (index < go.componentCount) go.removeComponent(go.componentAt(index));
  }

  void _removeSubtree(int rootId) {
    final go = _validObject(rootId);
    if (go == null) return;
    if (_selectedId != null && _objects[_selectedId] != null) {
      // keep the selection only if it is outside the removed tree
      for (final g in _dfsOf(go)) {
        if (identical(g, _objects[_selectedId])) _selectedId = null;
      }
    }
    _forget(go);
    go.destroy();
    scene.flushDestroy();
  }

  List<GameObject> _dfsOf(GameObject root) {
    final out = <GameObject>[];
    void visit(GameObject g) {
      out.add(g);
      for (final c in g.children) {
        visit(c);
      }
    }

    visit(root);
    return out;
  }

  Map<String, Object?> _tree() {
    final seen = <int>{};
    Map<String, Object?> node(GameObject go) {
      final id = idOf(go);
      seen.add(id);
      return {
        'id': id,
        'name': go.name,
        'active': go.activeSelf,
        'children': [for (final c in go.children) node(c)],
      };
    }

    final roots = [for (final r in scene.roots) node(r)];
    // forget objects that are gone, so the tables do not grow for ever
    for (final id in _objects.keys.toList()) {
      if (!seen.contains(id)) {
        final go = _objects.remove(id);
        if (go != null) _ids.remove(go);
      }
    }
    return {'roots': roots};
  }

  Map<String, Object?> _describe(GameObject go) {
    final d = Inspector.describeObject(go);
    final comps = d['components'] as List;
    for (var i = 0; i < comps.length; i++) {
      (comps[i] as Map<String, Object?>)['registered'] = registry.typeNameOf(go.componentAt(i));
    }
    d['id'] = idOf(go);
    d['parent'] = go.parent == null ? null : idOf(go.parent!);
    return d;
  }

  Object? _create(Map<String, Object?> a) {
    final name = a['name'];
    final go = GameObject(name is String && name.isNotEmpty ? name : 'GameObject');
    final pos = a['position'];
    if (pos != null) {
      if (!_isNums(pos, 3)) throw ArgumentError('position needs 3 numbers');
      go.transform.localPosition = Vector3(_d(pos, 0), _d(pos, 1), _d(pos, 2));
    }
    final comps = a['components'];
    if (comps != null && comps is! List) throw ArgumentError('components needs a list');
    final made = <Component>[];
    for (final raw in (comps as List? ?? const [])) {
      final m = _map(raw);
      made.add(_makeComponent(m['type'], m['data'])); // fails before anything is added to the scene
    }
    final parent = a['parent'] == null ? null : _need(a['parent']);
    for (final c in made) {
      go.addComponent(c);
    }
    if (parent != null) {
      parent.addChild(go);
    } else {
      scene.add(go);
    }
    final id = idOf(go);
    final tomb = _playing ? null : _Subtree.capture(this, go);
    if (tomb != null) _record('Create ${go.name}', () => _removeSubtree(id), () => tomb.restore(this));
    _changed('tree');
    return {'id': id};
  }

  Component _makeComponent(Object? type, Object? data) {
    if (type is! String) throw ArgumentError('a component needs a type name');
    if (!registry.isRegistered(type)) throw ArgumentError('component type "$type" is not registered');
    try {
      return registry.read(type, _map(data));
    } catch (e) {
      throw StateError('Could not make a "$type": $e');
    }
  }

  Component _component(GameObject go, Object? index) {
    if (index is! num || index != index.roundToDouble() || index < 0 || index >= go.componentCount) {
      throw ArgumentError('no component with index $index on "${go.name}"');
    }
    return go.componentAt(index.toInt());
  }

  Object? _pick(Map<String, Object?> a) {
    final x = a['x'], y = a['y'], w = a['width'], h = a['height'];
    if (x is! num || y is! num || w is! num || h is! num || w <= 0 || h <= 0) {
      throw ArgumentError('pick needs numbers x, y, width, height');
    }
    final cam = camera ?? scene.findComponent<Camera>();
    if (cam == null) throw StateError('There is no camera to pick with.');
    final ray = cam.screenRay(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());
    GameObject? best;
    var bestT = double.infinity;
    scene.forEachActive((go) {
      for (final r in go.getComponents<MeshRenderer>()) {
        if (!r.visible) continue;
        final t = _hitBounds(r, go, ray);
        if (t != null && t < bestT) {
          bestT = t;
          best = go;
        }
      }
    });
    final hit = best;
    if (hit == null) return {'id': null};
    if (a['select'] == true) _selectedId = idOf(hit);
    final p = ray.origin + ray.direction * bestT;
    return {
      'id': idOf(hit),
      'distance': (p - cam.transform.worldPosition).length, // from the camera, not from the near plane
      'point': [p.x, p.y, p.z],
    };
  }

  /// Distance along [ray] to the bounding box of a mesh (in the object's own space), or null.
  static double? _hitBounds(MeshRenderer r, GameObject go, Ray ray) {
    final b = r.mesh.bounds;
    final inv = Matrix4.copy(go.transform.worldMatrix);
    if (inv.invert() == 0.0) return null;
    final o = inv.transformed3(ray.origin);
    final d = inv.getRotation().transformed(ray.direction); // not normalized: t stays in world units
    var tmin = double.negativeInfinity, tmax = double.infinity;
    for (var i = 0; i < 3; i++) {
      final lo = b.min[i], hi = b.max[i];
      if (d[i].abs() < 1e-12) {
        if (o[i] < lo || o[i] > hi) return null;
      } else {
        var t1 = (lo - o[i]) / d[i], t2 = (hi - o[i]) / d[i];
        if (t1 > t2) {
          final s = t1;
          t1 = t2;
          t2 = s;
        }
        if (t1 > tmin) tmin = t1;
        if (t2 < tmax) tmax = t2;
        if (tmin > tmax) return null;
      }
    }
    if (tmax < 0) return null; // the box is behind the camera
    return tmin >= 0 ? tmin : 0.0;
  }

  void _drawSelection() {
    final go = selected;
    if (go == null) return;
    final d = scene.debug;
    for (final r in go.getComponents<MeshRenderer>()) {
      final b = r.mesh.bounds;
      final m = go.transform.worldMatrix;
      final c = <Vector3>[
        for (var i = 0; i < 8; i++)
          m.transformed3(Vector3(i & 1 == 0 ? b.min.x : b.max.x, i & 2 == 0 ? b.min.y : b.max.y, i & 4 == 0 ? b.min.z : b.max.z)),
      ];
      for (var i = 0; i < 8; i++) {
        for (final bit in [1, 2, 4]) {
          if (i & bit == 0) d.line(c[i], c[i | bit], color: DebugColors.orange);
        }
      }
    }
    d.axes(go.transform.worldMatrix, size: 0.5);
  }

  List<GameObject> _depthFirst() {
    final out = <GameObject>[];
    void visit(GameObject g) {
      out.add(g);
      for (final c in g.children) {
        visit(c);
      }
    }

    for (final r in scene.roots) {
      visit(r);
    }
    return out;
  }

  void _resetIds() {
    _ids.clear();
    _objects.clear();
    if (_validObject(_selectedId) == null) _selectedId = null;
  }

  void _forget(GameObject go) {
    void drop(GameObject g) {
      final id = _ids.remove(g);
      if (id != null) _objects.remove(id);
      for (final c in g.children) {
        drop(c);
      }
    }

    final sel = _selectedId;
    drop(go);
    if (sel != null && !_objects.containsKey(sel)) _selectedId = null;
  }

  void _changed(String what) => host.broadcast('editor.changed', {'what': what});

  GameObject _need(Object? id) {
    if (id is! num) throw ArgumentError('needs an object id (a number)');
    final go = _validObject(id.toInt());
    if (go == null) throw ArgumentError('no object with id ${id.toInt()}');
    return go;
  }

  static Map<String, Object?> _map(Object? o) => o is Map ? o.cast<String, Object?>() : <String, Object?>{};

  static bool _isNums(Object? o, int n) => o is List && o.length == n && o.every((e) => e is num && e.isFinite);

  static double _d(Object? list, int i) => ((list as List)[i] as num).toDouble();

  static bool _valuesEqual(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is double && b is double) {
      if (a.isNaN && b.isNaN) return true;
      return a == b;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_valuesEqual(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k) || !_valuesEqual(a[k], b[k])) return false;
      }
      return true;
    }
    return a == b;
  }
}

class _Command {
  _Command(this.name, this.undo, this.redo);
  final String name;
  final void Function() undo, redo;
}

class _CompSnap {
  _CompSnap(this.type, this.data, this.enabled);
  final String type;
  final Map<String, Object?> data;
  final bool enabled;
}

/// Name, tag, layer, switch and local transform of one object (copied, so it does not change later).
class _ObjState {
  _ObjState(this.name, this.tag, this.layer, this.active, this.pos, this.rot, this.scale);
  factory _ObjState.of(GameObject go) => _ObjState(go.name, go.tag, go.layer, go.activeSelf, go.transform.localPosition.clone(),
      go.transform.localRotation.clone(), go.transform.localScale.clone());

  final String name, tag;
  final int layer;
  final bool active;
  final Vector3 pos, scale;
  final Quaternion rot;

  bool same(_ObjState o) =>
      name == o.name && tag == o.tag && layer == o.layer && active == o.active && pos == o.pos && scale == o.scale && rot == o.rot;

  void applyTo(GameObject go) {
    go.name = name;
    go.tag = tag;
    go.layer = layer;
    go.active = active;
    go.transform.localPosition = pos;
    go.transform.localRotation = rot;
    go.transform.localScale = scale;
  }
}

/// Where an object hangs in the tree, and its local transform there.
class _Place {
  _Place(this.parentId, this.index, this.state);
  factory _Place.of(EditorBridge b, GameObject go) =>
      _Place(go.parent == null ? null : b.idOf(go.parent!), go.siblingIndex, _ObjState.of(go));

  final int? parentId;
  final int index;
  final _ObjState state;

  void applyTo(EditorBridge b, GameObject go) {
    final pid = parentId;
    if (pid == null) {
      go.detachFromParent();
    } else {
      final parent = b.find(pid);
      if (parent != null) parent.addChild(go);
    }
    go.setSiblingIndex(index);
    state.applyTo(go);
  }
}

/// A whole object tree as data, with the numbers of all its objects and its place in the tree.
class _Subtree {
  _Subtree(this.name, this.data, this.ids, this.parentId, this.index);

  static _Subtree? capture(EditorBridge b, GameObject go) {
    try {
      final data = jsonDecode(jsonEncode(writeObject(go, b.registry, UnknownComponents.error))) as Map<String, Object?>;
      return _Subtree(go.name, data, [for (final g in b._dfsOf(go)) b.idOf(g)], go.parent == null ? null : b.idOf(go.parent!), go.siblingIndex);
    } catch (_) {
      return null; // a component that cannot be saved: no undo for this one
    }
  }

  final String name;
  final Map<String, Object?> data;
  final List<int> ids;
  final int? parentId;
  final int index;

  void restore(EditorBridge b) {
    final go = readObject(data, b.registry);
    final pid = parentId;
    final parent = pid == null ? null : b.find(pid);
    if (parent != null) {
      parent.addChild(go);
    } else {
      b.scene.add(go);
    }
    go.setSiblingIndex(index);
    final now = b._dfsOf(go);
    for (var i = 0; i < now.length && i < ids.length; i++) {
      b._ids[now[i]] = ids[i];
      b._objects[ids[i]] = now[i];
    }
  }
}
