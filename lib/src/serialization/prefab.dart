import 'dart:convert';

import '../math/vec.dart';

import '../engine/game_object.dart';
import 'component_registry.dart';

/// What to do with a component whose class is not in the [ComponentRegistry]
/// when saving.
enum UnknownComponents {
  /// Stop with a [StateError] that names the class (default, so nothing is
  /// lost without notice).
  error,

  /// Leave that component out.
  skip,
}

/// A saved copy of an object tree (like a Unity prefab). Make one from a
/// ready object, then call [instantiate] as often as you like.
///
/// A prefab is plain data, so it can be written to JSON with [toJsonString]
/// and read back with [Prefab.fromJsonString].
class Prefab {
  Prefab._(this._data);

  final Map<String, Object?> _data;

  /// Copies [root] and all its children.
  factory Prefab.fromObject(
    GameObject root,
    ComponentRegistry registry, {
    UnknownComponents unknown = UnknownComponents.error,
  }) => Prefab._(writeObject(root, registry, unknown));

  factory Prefab.fromJson(Map<String, Object?> json) =>
      Prefab._(_deepCopy(json) as Map<String, Object?>);

  factory Prefab.fromJsonString(String text) =>
      Prefab.fromJson((jsonDecode(text) as Map).cast<String, Object?>());

  Map<String, Object?> toJson() => _deepCopy(_data) as Map<String, Object?>;

  String toJsonString() => jsonEncode(_data);

  /// Name of the root object.
  String get name => _data['name'] as String? ?? 'GameObject';

  /// Builds a new object tree. It is put in [parent] (as a child) or in
  /// [scene] (as a root) when given; otherwise you add it yourself.
  /// [position] and [rotation] replace the saved local values of the root.
  GameObject instantiate(
    ComponentRegistry registry, {
    Scene? scene,
    GameObject? parent,
    Vector3? position,
    Quaternion? rotation,
  }) {
    final go = readObject(_data, registry);
    if (position != null) go.transform.localPosition = position;
    if (rotation != null) go.transform.localRotation = rotation;
    if (parent != null) {
      parent.addChild(go);
    } else if (scene != null) {
      scene.add(go);
    }
    return go;
  }
}

/// Writes [go] and its children to plain data.
Map<String, Object?> writeObject(
  GameObject go,
  ComponentRegistry registry,
  UnknownComponents unknown,
) {
  final comps = <Map<String, Object?>>[];
  for (var i = 0; i < go.componentCount; i++) {
    final c = go.componentAt(i);
    final type = registry.typeNameOf(c);
    if (type == null) {
      if (unknown == UnknownComponents.skip) continue;
      throw StateError(
        'Component class ${c.runtimeType} on "${go.name}" is not registered. '
        'Call registry.register<${c.runtimeType}>(...) or save with '
        'UnknownComponents.skip.',
      );
    }
    comps.add({
      'type': type,
      'enabled': c.enabled,
      'data': registry.write(c),
    });
  }
  final t = go.transform;
  return {
    'name': go.name,
    'tag': go.tag,
    'layer': go.layer,
    'active': go.activeSelf,
    'position': [t.localPosition.x, t.localPosition.y, t.localPosition.z],
    'rotation': [
      t.localRotation.x,
      t.localRotation.y,
      t.localRotation.z,
      t.localRotation.w,
    ],
    'scale': [t.localScale.x, t.localScale.y, t.localScale.z],
    'components': comps,
    'children': [
      for (final c in go.children) writeObject(c, registry, unknown),
    ],
  };
}

/// Builds an object tree from data written by [writeObject].
GameObject readObject(Map<String, Object?> json, ComponentRegistry registry) {
  final p = _list(json['position'], 3);
  final r = _list(json['rotation'], 4);
  final s = _list(json['scale'], 3);
  final rawLayer = json['layer'];
  final go = GameObject(
    json['name'] as String? ?? 'GameObject',
    tag: json['tag'] as String? ?? 'Untagged',
    layer: rawLayer is num ? rawLayer.toInt() : 0,
    position: p == null ? null : Vector3(p[0], p[1], p[2]),
    rotation: r == null ? null : Quaternion(r[0], r[1], r[2], r[3]).normalized(),
    scale: s == null ? null : Vector3(s[0], s[1], s[2]),
  );
  go.active = json['active'] != false;
  for (final raw in (json['components'] as List? ?? const [])) {
    if (raw is! Map) continue;
    final cj = raw.cast<String, Object?>();
    final type = cj['type'];
    if (type is! String) continue;
    final data = (cj['data'] as Map?)?.cast<String, Object?>() ?? const {};
    final comp = registry.read(type, data);
    comp.enabled = cj['enabled'] != false;
    go.addComponent(comp);
  }
  for (final raw in (json['children'] as List? ?? const [])) {
    if (raw is! Map) continue;
    go.addChild(readObject(raw.cast<String, Object?>(), registry));
  }
  return go;
}

List<double>? _list(Object? o, int n) {
  if (o is! List || o.length != n) return null;
  final out = <double>[];
  for (final e in o) {
    if (e is! num || !e.isFinite) return null;
    out.add(e.toDouble());
  }
  return out;
}

Object? _deepCopy(Object? o) {
  if (o is Map) {
    return <String, Object?>{
      for (final e in o.entries) e.key as String: _deepCopy(e.value),
    };
  }
  if (o is List) return [for (final e in o) _deepCopy(e)];
  return o;
}
