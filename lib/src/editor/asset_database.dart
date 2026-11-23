/// Project asset database: scans files, assigns stable GUIDs, persists `.meta`
/// import settings, and detects added/modified/deleted assets for hot reload.
library;

import 'dart:convert';
import 'dart:io';

/// Broad asset category inferred from file extension.
enum AssetType {
  model,
  texture,
  scene,
  prefab,
  audio,
  shader,
  script,
  unknown,
}

/// Per-asset import settings stored alongside an asset in `<file>.meta`.
class AssetImportSettings {
  AssetImportSettings({
    this.scale = 1.0,
    this.generateNormals = false,
    this.flipUv = false,
    this.generateMipmaps = true,
    this.maxTextureSize = 2048,
    Map<String, Object?>? extra,
  }) : extra = extra != null ? Map<String, Object?>.from(extra) : {};

  double scale;
  bool generateNormals;
  bool flipUv;
  bool generateMipmaps;
  int maxTextureSize;
  final Map<String, Object?> extra;

  Map<String, Object?> toJson() => {
        'scale': scale,
        'generateNormals': generateNormals,
        'flipUv': flipUv,
        'generateMipmaps': generateMipmaps,
        'maxTextureSize': maxTextureSize,
        if (extra.isNotEmpty) 'extra': extra,
      };

  factory AssetImportSettings.fromJson(Map<String, Object?> json) {
    return AssetImportSettings(
      scale: (json['scale'] as num?)?.toDouble() ?? 1.0,
      generateNormals: json['generateNormals'] as bool? ?? false,
      flipUv: json['flipUv'] as bool? ?? false,
      generateMipmaps: json['generateMipmaps'] as bool? ?? true,
      maxTextureSize: (json['maxTextureSize'] as num?)?.toInt() ?? 2048,
      extra: (json['extra'] as Map?)?.cast<String, Object?>(),
    );
  }
}

/// Metadata record for one indexed project asset.
class AssetRecord {
  AssetRecord({
    required this.guid,
    required this.relativePath,
    required this.type,
    required this.sizeBytes,
    required this.modifiedMs,
    required this.settings,
  });

  final String guid;
  final String relativePath;
  final AssetType type;
  int sizeBytes;
  int modifiedMs;
  AssetImportSettings settings;

  String get fileName {
    final i = relativePath.lastIndexOf('/');
    return i < 0 ? relativePath : relativePath.substring(i + 1);
  }

  String get directory {
    final i = relativePath.lastIndexOf('/');
    return i < 0 ? '' : relativePath.substring(0, i);
  }
}

/// Summary of changes detected by [AssetDatabase.refresh].
class AssetChangeSet {
  const AssetChangeSet({
    required this.added,
    required this.modified,
    required this.removed,
  });

  final List<String> added;
  final List<String> modified;
  final List<String> removed;

  bool get isEmpty => added.isEmpty && modified.isEmpty && removed.isEmpty;
}

/// Indexes assets under a project folder, reads/writes `.meta` sidecar files
/// with stable GUIDs and import settings, and tracks changes for hot reload.
class AssetDatabase {
  AssetDatabase(this.rootPath);

  final String rootPath;
  final Map<String, AssetRecord> _byPath = {};
  final Map<String, AssetRecord> _byGuid = {};
  int _nextId = 1;

  List<AssetRecord> get all {
    final list = _byPath.values.toList()
      ..sort((a, b) => a.relativePath.compareTo(b.relativePath));
    return list;
  }

  int get count => _byPath.length;

  AssetRecord? byPath(String relativePath) => _byPath[_normPath(relativePath)];
  AssetRecord? byGuid(String guid) => _byGuid[guid];

  List<AssetRecord> byType(AssetType type) =>
      all.where((a) => a.type == type).toList();

  List<AssetRecord> search(String query, {AssetType? type}) {
    final q = query.trim().toLowerCase();
    return all.where((a) {
      if (type != null && a.type != type) return false;
      if (q.isEmpty) return true;
      return a.relativePath.toLowerCase().contains(q);
    }).toList();
  }

  /// Scans [rootPath], creates missing `.meta` files when [writeMeta] is true,
  /// and returns which paths were added, modified, or removed since last scan.
  AssetChangeSet refresh({bool writeMeta = true}) {
    final dir = Directory(rootPath);
    if (!dir.existsSync()) {
      final removed = _byPath.keys.toList();
      _byPath.clear();
      _byGuid.clear();
      return AssetChangeSet(added: const [], modified: const [], removed: removed);
    }

    final rootNorm = _normPath(dir.absolute.path);
    final seen = <String>{};
    final added = <String>[];
    final modified = <String>[];

    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final abs = _normPath(entity.absolute.path);
      if (abs.endsWith('.meta')) continue;
      final rel = abs.startsWith('$rootNorm/')
          ? abs.substring(rootNorm.length + 1)
          : abs;
      if (rel.startsWith('.') || rel.contains('/.')) continue;

      seen.add(rel);
      final stat = entity.statSync();
      final modMs = stat.modified.millisecondsSinceEpoch;
      final size = stat.size;

      final existing = _byPath[rel];
      if (existing != null) {
        if (existing.modifiedMs != modMs || existing.sizeBytes != size) {
          existing.modifiedMs = modMs;
          existing.sizeBytes = size;
          modified.add(rel);
        }
        continue;
      }

      // Load or create sidecar .meta file.
      final metaFile = File('${entity.path}.meta');
      String guid;
      AssetImportSettings settings;
      if (metaFile.existsSync()) {
        try {
          final json = jsonDecode(metaFile.readAsStringSync()) as Map<String, Object?>;
          guid = (json['guid'] as String?) ?? _makeGuid(rel);
          settings = json['settings'] is Map
              ? AssetImportSettings.fromJson((json['settings'] as Map).cast<String, Object?>())
              : AssetImportSettings();
        } catch (_) {
          guid = _makeGuid(rel);
          settings = AssetImportSettings();
        }
      } else {
        guid = _makeGuid(rel);
        settings = AssetImportSettings();
        if (writeMeta) {
          _writeMetaFile(metaFile, guid, settings);
        }
      }

      final rec = AssetRecord(
        guid: guid,
        relativePath: rel,
        type: inferType(rel),
        sizeBytes: size,
        modifiedMs: modMs,
        settings: settings,
      );
      _byPath[rel] = rec;
      _byGuid[guid] = rec;
      added.add(rel);
    }

    final removed = <String>[];
    for (final p in _byPath.keys.toList()) {
      if (!seen.contains(p)) {
        final rec = _byPath.remove(p)!;
        _byGuid.remove(rec.guid);
        removed.add(p);
      }
    }

    added.sort();
    modified.sort();
    removed.sort();
    return AssetChangeSet(added: added, modified: modified, removed: removed);
  }

  /// Updates import settings for [relativePath] and writes its `.meta` file.
  bool saveSettings(String relativePath, AssetImportSettings settings) {
    final norm = _normPath(relativePath);
    final rec = _byPath[norm];
    if (rec == null) return false;
    rec.settings = settings;
    final metaFile = File('$rootPath/$norm.meta');
    _writeMetaFile(metaFile, rec.guid, settings);
    return true;
  }

  static AssetType inferType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.glb') || lower.endsWith('.gltf') || lower.endsWith('.obj')) {
      return AssetType.model;
    }
    if (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return AssetType.texture;
    }
    if (lower.endsWith('.scene.json') || lower.endsWith('.scene')) {
      return AssetType.scene;
    }
    if (lower.endsWith('.prefab.json') || lower.endsWith('.prefab')) {
      return AssetType.prefab;
    }
    if (lower.endsWith('.wav') || lower.endsWith('.ogg') || lower.endsWith('.mp3')) {
      return AssetType.audio;
    }
    if (lower.endsWith('.vert') || lower.endsWith('.frag') || lower.endsWith('.glsl') || lower.endsWith('.wgsl')) {
      return AssetType.shader;
    }
    if (lower.endsWith('.dart')) return AssetType.script;
    return AssetType.unknown;
  }

  String _makeGuid(String rel) {
    // Deterministic-friendly unique ID per asset.
    final hash = _fnv1a(rel).toRadixString(16).padLeft(8, '0');
    final seq = (_nextId++).toRadixString(16).padLeft(4, '0');
    return 'tej-$hash-$seq';
  }

  static int _fnv1a(String s) {
    var h = 0x811c9dc5;
    for (var i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  static void _writeMetaFile(File f, String guid, AssetImportSettings settings) {
    final content = const JsonEncoder.withIndent('  ').convert({
      'guid': guid,
      'settings': settings.toJson(),
    });
    f.writeAsStringSync('$content\n');
  }

  static String _normPath(String p) => p.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
}
