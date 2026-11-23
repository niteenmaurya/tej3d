/// Reflection for an editor: components tell which settings they have, with names, types and limits,
/// and an editor (or any tool) can read and write them as plain JSON values.
///
/// ```dart
/// class Door extends Component implements Inspectable {
///   double openAngle = 90;
///   bool locked = false;
///   @override
///   List<InspectorField> get inspectorFields => [
///     InspectorField.float('openAngle', () => openAngle, (v) => openAngle = v, min: 0, max: 180),
///     InspectorField.boolean('locked', () => locked, (v) => locked = v),
///   ];
/// }
/// ```
/// Built in: [Light], [Camera], [MeshRenderer] (with its material) and [ParticleSystem].
/// Components that do not implement [Inspectable] still show up in the editor (name and on/off switch).
library;

import 'dart:math' as math;

import '../math/vec.dart';

import '../engine/game_object.dart';
import '../engine/transform.dart';

/// What kind of value a field holds. Values travel as JSON: `float` and `integer` are numbers,
/// `boolean` is true/false, `text` is a string, `vector3` and `color3` are `[x, y, z]` / `[r, g, b]`,
/// `color4` is `[r, g, b, a]`, `choice` is the name of one of the options.
enum FieldType { float, integer, boolean, text, vector3, color3, color4, choice }

/// A component that lists its settings for an editor.
abstract interface class Inspectable {
  List<InspectorField> get inspectorFields;
}

/// One setting of a component: a name, a type, limits, a way to read it and (unless read only) to write it.
class InspectorField {
  InspectorField._(
    this.name,
    this.type,
    this._get,
    this._set, {
    this.min,
    this.max,
    this.choices,
    this.help,
  });

  /// A number. Values written are limited to [min]..[max] when given.
  factory InspectorField.float(String name, double Function() get, void Function(double)? set, {double? min, double? max, String? help}) =>
      InspectorField._(name, FieldType.float, get, set == null ? null : (o) => set((o as num).toDouble()), min: min, max: max, help: help);

  /// A whole number.
  factory InspectorField.integer(String name, int Function() get, void Function(int)? set, {int? min, int? max, String? help}) =>
      InspectorField._(name, FieldType.integer, get, set == null ? null : (o) => set((o as num).toInt()),
          min: min?.toDouble(), max: max?.toDouble(), help: help);

  factory InspectorField.boolean(String name, bool Function() get, void Function(bool)? set, {String? help}) =>
      InspectorField._(name, FieldType.boolean, get, set == null ? null : (o) => set(o as bool), help: help);

  factory InspectorField.text(String name, String Function() get, void Function(String)? set, {String? help}) =>
      InspectorField._(name, FieldType.text, get, set == null ? null : (o) => set(o as String), help: help);

  /// Three numbers (a position, a direction...). The [get] value is copied, so changing the result changes nothing.
  factory InspectorField.vector3(String name, Vector3 Function() get, void Function(Vector3)? set, {String? help}) =>
      InspectorField._(name, FieldType.vector3, () => _list3(get()), set == null ? null : (o) => set(_vec3(o as List)), help: help);

  /// Red, green, blue, each 0..1 (values written are limited to that).
  factory InspectorField.color3(String name, Vector3 Function() get, void Function(Vector3)? set, {String? help}) =>
      InspectorField._(name, FieldType.color3, () => _list3(get()), set == null ? null : (o) => set(_vec3(o as List)..clamp(Vector3.zero(), Vector3.all(1))),
          min: 0, max: 1, help: help);

  /// Red, green, blue, alpha, each 0..1.
  factory InspectorField.color4(String name, Vector4 Function() get, void Function(Vector4)? set, {String? help}) => InspectorField._(
      name, FieldType.color4, () { final v = get(); return [v.x, v.y, v.z, v.w]; },
      set == null ? null : (o) { final l = o as List; set(Vector4(_num(l[0]), _num(l[1]), _num(l[2]), _num(l[3]))..clamp(Vector4.zero(), Vector4.all(1))); },
      min: 0, max: 1, help: help);

  /// One of the values of an enum. Shown by name.
  static InspectorField choice<T extends Enum>(String name, List<T> values, T Function() get, void Function(T)? set, {String? help}) {
    T byName(Object? o) => values.firstWhere((v) => v.name == o);
    return InspectorField._(name, FieldType.choice, () => get().name, set == null ? null : (o) => set(byName(o)),
        choices: [for (final v in values) v.name], help: help);
  }

  final String name;
  final FieldType type;
  final double? min, max;

  /// For [FieldType.choice]: the allowed names.
  final List<String>? choices;
  final String? help;
  final Object? Function() _get;
  final void Function(Object?)? _set;

  bool get readOnly => _set == null;

  /// The value as JSON.
  Object? get value => _get();

  /// Writes a JSON value. Returns null when it worked, or a short message when the value is wrong
  /// (nothing is changed then). Numbers are limited to [min]..[max].
  String? write(Object? json) {
    final set = _set;
    if (set == null) return '$name is read only';
    try {
      switch (type) {
        case FieldType.float:
        case FieldType.integer:
          if (json is! num || !json.isFinite) return '$name needs a number';
          if (type == FieldType.integer && json != json.roundToDouble()) return '$name needs a whole number';
          set(_limit(json));
        case FieldType.boolean:
          if (json is! bool) return '$name needs true or false';
          set(json);
        case FieldType.text:
          if (json is! String) return '$name needs text';
          set(json);
        case FieldType.vector3:
        case FieldType.color3:
          if (json is! List || json.length != 3 || json.any((e) => e is! num || !e.isFinite)) return '$name needs 3 numbers';
          set(json);
        case FieldType.color4:
          if (json is! List || json.length != 4 || json.any((e) => e is! num || !e.isFinite)) return '$name needs 4 numbers';
          set(json);
        case FieldType.choice:
          if (json is! String || !choices!.contains(json)) return '$name must be one of ${choices!.join(', ')}';
          set(json);
      }
    } catch (e) {
      return '$name: could not set ($e)';
    }
    return null;
  }

  num _limit(num v) {
    var r = v;
    if (min != null && r < min!) r = min!;
    if (max != null && r > max!) r = max!;
    return r;
  }

  /// A description an editor can draw a control from (name, type, limits, options, read only, value).
  Map<String, Object?> describe() => {
        'name': name,
        'type': type.name,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
        if (choices != null) 'choices': choices,
        if (help != null) 'help': help,
        'readOnly': readOnly,
        'value': value,
      };

  static List<double> _list3(Vector3 v) => [v.x, v.y, v.z];
  static double _num(Object? o) => (o as num).toDouble();
  static Vector3 _vec3(List l) => Vector3(_num(l[0]), _num(l[1]), _num(l[2]));
}

/// Reads and writes objects, components and transforms as JSON (what an editor program needs).
class Inspector {
  const Inspector._();

  /// Rotation as angles in degrees `[x, y, z]`, the inverse of `Transform.eulerDegrees` (order Y, X, Z).
  /// One rotation has several angle triples; this gives x in -90..90.
  static List<double> eulerOf(Quaternion q) {
    final m = q.normalized().asRotationMatrix();
    const d = 180.0 / math.pi;
    final sx = (-m.entry(1, 2)).clamp(-1.0, 1.0);
    final x = math.asin(sx);
    double y, z;
    if (sx.abs() > 0.999999) {
      y = math.atan2(-m.entry(2, 0), m.entry(0, 0)); // looking straight up or down: put it all into y
      z = 0;
    } else {
      y = math.atan2(m.entry(0, 2), m.entry(2, 2));
      z = math.atan2(m.entry(1, 0), m.entry(1, 1));
    }
    return [x * d, y * d, z * d];
  }

  /// The settings of a component, or an empty list when it is not [Inspectable].
  static List<InspectorField> fieldsOf(Component c) => c is Inspectable ? (c as Inspectable).inspectorFields : const [];

  /// One component as JSON: index, type name, on/off switch, and its fields.
  static Map<String, Object?> describeComponent(Component c, int index) => {
        'index': index,
        'type': c.runtimeType.toString(),
        'enabled': c.enabled,
        'inspectable': c is Inspectable,
        'fields': [for (final f in fieldsOf(c)) f.describe()],
      };

  /// One object as JSON: name, tag, layer, on/off, local position / rotation (degrees) / scale, components.
  static Map<String, Object?> describeObject(GameObject go) {
    final t = go.transform;
    final comps = go.components;
    return {
      'name': go.name,
      'tag': go.tag,
      'layer': go.layer,
      'active': go.activeSelf,
      'position': [t.localPosition.x, t.localPosition.y, t.localPosition.z],
      'rotation': eulerOf(t.localRotation),
      'scale': [t.localScale.x, t.localScale.y, t.localScale.z],
      'components': [for (var i = 0; i < comps.length; i++) describeComponent(comps[i], i)],
    };
  }

  /// Writes fields by name. Unknown names and wrong values give a message each; the good ones are still applied.
  static List<String> setFields(Component c, Map<String, Object?> values) {
    final fields = {for (final f in fieldsOf(c)) f.name: f};
    final errors = <String>[];
    values.forEach((name, v) {
      final f = fields[name];
      if (f == null) {
        errors.add('no field "$name" on ${c.runtimeType}');
        return;
      }
      final e = f.write(v);
      if (e != null) errors.add(e);
    });
    return errors;
  }

  /// Writes `name`, `tag`, `layer`, `active`, `position`, `rotation` (degrees) and `scale` of an object.
  /// Same rules as [setFields].
  static List<String> setObject(GameObject go, Map<String, Object?> props) {
    final errors = <String>[];
    List<double>? three(String key, Object? v) {
      if (v is List && v.length == 3 && v.every((e) => e is num && e.isFinite)) return [for (final e in v) (e as num).toDouble()];
      errors.add('$key needs 3 numbers');
      return null;
    }

    props.forEach((key, v) {
      switch (key) {
        case 'name':
          v is String && v.isNotEmpty ? go.name = v : errors.add('name needs text that is not empty');
        case 'tag':
          v is String ? go.tag = v : errors.add('tag needs text');
        case 'layer':
          v is num && v == v.roundToDouble() && v >= 0 && v <= 31 ? go.layer = v.toInt() : errors.add('layer needs a whole number 0..31');
        case 'active':
          v is bool ? go.active = v : errors.add('active needs true or false');
        case 'position':
          final l = three(key, v);
          if (l != null) go.transform.localPosition = Vector3(l[0], l[1], l[2]);
        case 'rotation':
          final l = three(key, v);
          if (l != null) go.transform.localRotation = Transform.eulerDegrees(l[0], l[1], l[2]);
        case 'scale':
          final l = three(key, v);
          if (l != null) go.transform.localScale = Vector3(l[0], l[1], l[2]);
        default:
          errors.add('no property "$key"');
      }
    });
    return errors;
  }
}
