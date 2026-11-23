import '../math/vec.dart';

import '../core/layers.dart';
import '../engine/camera.dart';
import '../engine/game_object.dart';
import '../engine/light.dart';
import '../engine/mesh_renderer.dart';
import '../engine/post_effects.dart';
import '../engine/render/material.dart';
import '../engine/render/mesh.dart';

/// Writes the settings of a component to plain data (maps, lists, numbers,
/// strings, bools).
typedef ComponentToJson = Map<String, Object?> Function(Component c);

/// Makes a new component from data written by a [ComponentToJson].
typedef ComponentFromJson = Component Function(Map<String, Object?> json);

/// Tells prefabs and scene files how to save and load each kind of component.
///
/// `Light`, `Camera` and `MeshRenderer` are known from the start. Register
/// your own scripts:
///
/// ```dart
/// registry.register<Spinner>('Spinner',
///   toJson: (c) => {'speed': (c as Spinner).speed},
///   fromJson: (j) => Spinner(speed: (j['speed'] as num).toDouble()));
/// ```
///
/// Meshes are saved by name. Give each mesh a name with [registerMesh].
class ComponentRegistry {
  ComponentRegistry({bool builtIns = true}) {
    if (builtIns) _registerBuiltIns();
  }

  final Map<String, _Entry> _byName = {};
  final Map<Type, String> _nameByType = {};
  final Map<String, Mesh> _meshes = {};
  final Map<Mesh, String> _meshNames = Map.identity();

  /// Remembers how to save and load components of type [T].
  void register<T extends Component>(
    String type, {
    required ComponentToJson toJson,
    required ComponentFromJson fromJson,
  }) {
    if (_byName.containsKey(type)) {
      throw ArgumentError('Component type "$type" is already registered.');
    }
    _byName[type] = _Entry(toJson, fromJson);
    _nameByType[T] = type;
  }

  bool isRegistered(String type) => _byName.containsKey(type);

  /// Names of all registered component types (an editor shows them in its "add component" list).
  Iterable<String> get typeNames => _byName.keys;

  /// Names of all registered meshes.
  Iterable<String> get meshNames => _meshes.keys;

  /// Gives [mesh] a [name] so `MeshRenderer` can be saved and loaded.
  void registerMesh(String name, Mesh mesh) {
    if (_meshes.containsKey(name)) {
      throw ArgumentError('Mesh name "$name" is already registered.');
    }
    _meshes[name] = mesh;
    _meshNames[mesh] = name;
  }

  Mesh? meshNamed(String name) => _meshes[name];

  /// Type name of [c], or null if its class is not registered.
  String? typeNameOf(Component c) => _nameByType[c.runtimeType];

  Map<String, Object?>? write(Component c) =>
      _byName[typeNameOf(c)]?.toJson(c);

  Component read(String type, Map<String, Object?> json) {
    final e = _byName[type];
    if (e == null) {
      throw StateError('Unknown component type "$type". Register it first.');
    }
    return e.fromJson(json);
  }

  void _registerBuiltIns() {
    register<Light>(
      'Light',
      toJson: (c) {
        final l = c as Light;
        return {
          'type': l.type.name,
          'color': _v3(l.color),
          'intensity': l.intensity,
          'range': l.range,
          'castShadows': l.castShadows,
          'shadowDistance': l.shadowDistance,
          'shadowStrength': l.shadowStrength,
          'shadowMapSize': l.shadowMapSize,
        };
      },
      fromJson: (j) => Light(
        type: j['type'] is String
            ? (LightType.values.asNameMap()[j['type'] as String] ?? LightType.directional)
            : LightType.directional,
        color: _readV3(j['color']),
        intensity: _num(j['intensity'], 1.0),
        range: _num(j['range'], 20.0),
        castShadows: j['castShadows'] == true,
        shadowDistance: _num(j['shadowDistance'], 30.0),
        shadowStrength: _num(j['shadowStrength'], 1.0),
        shadowMapSize: _int(j['shadowMapSize'], 1024),
      ),
    );
    register<Camera>(
      'Camera',
      toJson: (c) {
        final k = c as Camera;
        return {
          'fovYDegrees': k.fovYDegrees,
          'near': k.near,
          'far': k.far,
          'orthographic': k.orthographic,
          'orthoSize': k.orthoSize,
          'cullingMask': k.cullingMask.bits,
          if (k.post != null) 'post': k.post!.toJson(),
        };
      },
      fromJson: (j) => Camera(
        fovYDegrees: _num(j['fovYDegrees'], 60.0),
        near: _num(j['near'], 0.1),
        far: _num(j['far'], 500.0),
        orthographic: j['orthographic'] == true,
        orthoSize: _num(j['orthoSize'], 5.0),
        cullingMask: LayerMask(_int(j['cullingMask'], LayerMask.everything.bits)),
        post: j['post'] is Map ? PostEffects.fromJson((j['post'] as Map).cast<String, Object?>()) : null,
      ),
    );
    register<MeshRenderer>(
      'MeshRenderer',
      toJson: (c) {
        final r = c as MeshRenderer;
        final name = _meshNames[r.mesh];
        if (name == null) {
          throw StateError(
            'A MeshRenderer uses a mesh without a name. '
            'Call registry.registerMesh(name, mesh) first.',
          );
        }
        final m = r.material;
        return {
          'mesh': name,
          'visible': r.visible,
          'castShadows': r.castShadows,
          'receiveShadows': r.receiveShadows,
          'material': {
            'color': [m.color.x, m.color.y, m.color.z, m.color.w],
            'emissive': _v3(m.emissive),
            'unlit': m.unlit,
            'specular': m.specular,
            'shininess': m.shininess,
            'cull': m.cull.name,
            'metallic': m.metallic,
            'roughness': m.roughness,
            'ao': m.ao,
            'clearcoat': m.clearcoat,
            'clearcoatRoughness': m.clearcoatRoughness,
            'alpha': m.alpha,
            'textureId': m.textureId,
            'normalTextureId': m.normalTextureId,
            'mrTextureId': m.mrTextureId,
          },
        };
      },
      fromJson: (j) {
        final name = j['mesh'];
        if (name is! String) {
          throw StateError('MeshRenderer needs a "mesh" name. Registered meshes: ${_meshes.keys.join(', ')}.');
        }
        final mesh = _meshes[name];
        if (mesh == null) {
          throw StateError('Mesh "$name" is not registered.');
        }
        final mj = (j['material'] as Map?)?.cast<String, Object?>() ?? const {};
        final rawCol = mj['color'];
        final col = (rawCol is List && rawCol.length == 4 && rawCol.every((e) => e is num))
            ? [for (final e in rawCol) (e as num).toDouble()]
            : null;
        final mat = StandardMaterial(
          color: col == null ? null : Vector4(col[0], col[1], col[2], col[3]),
          emissive: _readV3(mj['emissive']),
          unlit: mj['unlit'] == true,
          specular: _num(mj['specular'], 0.0),
          shininess: _num(mj['shininess'], 32.0),
          cull: mj['cull'] is String
              ? (CullMode.values.asNameMap()[mj['cull'] as String] ?? CullMode.back)
              : CullMode.back,
          metallic: _num(mj['metallic'], 0.0),
          roughness: _num(mj['roughness'], 0.5),
          ao: _num(mj['ao'], 1.0),
          clearcoat: _num(mj['clearcoat'], 0.0),
          clearcoatRoughness: _num(mj['clearcoatRoughness'], 0.06),
          alpha: _num(mj['alpha'], 1.0),
          textureId: _int(mj['textureId'], -1),
          normalTextureId: _int(mj['normalTextureId'], -1),
          mrTextureId: _int(mj['mrTextureId'], -1),
        );
        return MeshRenderer(mesh, material: mat)
          ..visible = j['visible'] != false
          ..castShadows = j['castShadows'] != false
          ..receiveShadows = j['receiveShadows'] != false;
      },
    );
  }
}

class _Entry {
  _Entry(this.toJson, this.fromJson);
  final ComponentToJson toJson;
  final ComponentFromJson fromJson;
}

List<double> _v3(Vector3 v) => [v.x, v.y, v.z];

Vector3? _readV3(Object? o) {
  if (o is! List || o.length != 3 || !o.every((e) => e is num)) return null;
  return Vector3((o[0] as num).toDouble(), (o[1] as num).toDouble(), (o[2] as num).toDouble());
}

double _num(Object? o, double fallback) => o is num ? o.toDouble() : fallback;

int _int(Object? o, int fallback) => o is num ? o.toInt() : fallback;
