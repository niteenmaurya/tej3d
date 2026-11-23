import 'dart:convert';

import '../math/vec.dart';

import '../engine/game_object.dart';
import 'component_registry.dart';
import 'prefab.dart';

/// Save and load a whole [Scene] as JSON (objects, components, ambient and
/// background color).
class SceneIO {
  const SceneIO._();

  /// Format number written to files. Loading a newer one throws.
  static const int version = 1;

  static Map<String, Object?> toJson(
    Scene scene,
    ComponentRegistry registry, {
    UnknownComponents unknown = UnknownComponents.error,
  }) => {
    'version': version,
    'ambient': [scene.ambientColor.x, scene.ambientColor.y, scene.ambientColor.z],
    'clear': [
      scene.clearColor.x,
      scene.clearColor.y,
      scene.clearColor.z,
      scene.clearColor.w,
    ],
    'objects': [
      for (final root in scene.roots) writeObject(root, registry, unknown),
    ],
  };

  static String toJsonString(
    Scene scene,
    ComponentRegistry registry, {
    UnknownComponents unknown = UnknownComponents.error,
  }) => jsonEncode(toJson(scene, registry, unknown: unknown));

  /// Adds the saved objects to [scene] (call `scene.clear()` first for a
  /// fresh level).
  static void loadInto(
    Scene scene,
    Map<String, Object?> json,
    ComponentRegistry registry,
  ) {
    final rawVersion = json['version'];
    final v = rawVersion is num ? rawVersion.toInt() : 0;
    if (v < 1 || v > version) {
      throw StateError('Scene file version $v is not supported (max $version).');
    }
    final a = json['ambient'];
    if (a is List && a.length == 3 && a.every((e) => e is num && e.isFinite)) {
      scene.ambientColor = Vector3(
        (a[0] as num).toDouble(),
        (a[1] as num).toDouble(),
        (a[2] as num).toDouble(),
      );
    }
    final c = json['clear'];
    if (c is List && c.length == 4 && c.every((e) => e is num && e.isFinite)) {
      scene.clearColor = Vector4(
        (c[0] as num).toDouble(),
        (c[1] as num).toDouble(),
        (c[2] as num).toDouble(),
        (c[3] as num).toDouble(),
      );
    }
    for (final raw in (json['objects'] as List? ?? const [])) {
      if (raw is! Map) continue;
      scene.add(readObject(raw.cast<String, Object?>(), registry));
    }
  }

  static void loadStringInto(
    Scene scene,
    String text,
    ComponentRegistry registry,
  ) => loadInto(scene, (jsonDecode(text) as Map).cast<String, Object?>(), registry);
}
