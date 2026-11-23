import 'dart:math' as math;
import 'dart:typed_data';

import '../engine/camera.dart';
import '../engine/light.dart';
import '../engine/render/material.dart';
import '../engine/render/mesh.dart';
import '../engine/render/render_frame.dart';
import '../engine/game_object.dart';
import '../math/vec.dart';
import 'native_world.dart';

/// Pure-Dart (ZERO `dart:ui` imports!) synchronizer between a [Scene] / [RenderFrame]
/// and a C++ [NativeWorld].
///
/// Works identically in Flutter apps (used internally by `NativeRenderBackend`)
/// AND in headless Dart VM / CI scripts without Flutter SDK:
///
/// ```dart
/// final world = NativeWorld();
/// final sync = NativeSceneSync(world);
/// final rgba = sync.renderScene(scene, camera, 640, 360);
/// final png = sync.renderScenePng(scene, camera, 640, 360);
/// ```
class NativeSceneSync {
  NativeSceneSync(this.world);

  final NativeWorld world;

  final Map<Mesh, int> _meshIds = {};
  final List<int> _instances = [];
  final List<int> _lights = [];
  final List<int> _lightTypes = [];

  int _meshId(Mesh m) => _meshIds[m] ??= _upload(m);

  int _upload(Mesh m) {
    final a = m.arrays;
    final n = a.vertexCount;
    final uvs = a.uvs;
    final v = Float32List(n * 8);
    for (var i = 0; i < n; i++) {
      final o = i * 8;
      v[o] = a.positions[i * 3];
      v[o + 1] = a.positions[i * 3 + 1];
      v[o + 2] = a.positions[i * 3 + 2];
      v[o + 3] = a.normals[i * 3];
      v[o + 4] = a.normals[i * 3 + 1];
      v[o + 5] = a.normals[i * 3 + 2];
      if (uvs != null) {
        v[o + 6] = uvs[i * 2];
        v[o + 7] = uvs[i * 2 + 1];
      }
    }
    final id = world.createMesh(v, a.indices);
    if (a.isSkinned) world.setMeshSkin(id, a.joints!, a.weights!);
    return id;
  }

  /// Synchronizes all meshes (with UVs), PBR materials (metallic, roughness, AO,
  /// clearcoat, alpha, diffuse/normal/MR textures), lights, shadows, SSAO, FXAA,
  /// post-processing, debug lines, particles, and environment into [world].
  void sync(RenderFrame frame) {
    for (var i = 0; i < frame.items.length; i++) {
      final item = frame.items[i];
      final mesh = _meshId(item.mesh);
      if (i >= _instances.length) {
        _instances.add(world.createInstance(mesh));
      } else {
        world.setInstanceMesh(_instances[i], mesh);
      }
      final id = _instances[i];
      final mat = item.material;
      final effectiveAlpha = (mat.alpha * mat.color.w).clamp(0.0, 1.0);
      world.setInstanceVisible(id, true);
      world.setInstanceTransform(id, item.world);
      world.setInstanceColor(id, mat.color.x, mat.color.y, mat.color.z, effectiveAlpha);
      world.setInstanceMaterial(
        id,
        unlit: mat.unlit,
        doubleSided: mat.cull == CullMode.none,
        specular: mat.specular,
        emissive: math.max(mat.emissive.x, math.max(mat.emissive.y, mat.emissive.z)),
      );
      world.setInstancePbr(id, metallic: mat.metallic, roughness: mat.roughness, ao: mat.ao);
      world.setInstanceClearcoat(id, clearcoat: mat.clearcoat, roughness: mat.clearcoatRoughness);
      world.setInstanceAlpha(id, effectiveAlpha);
      world.setInstanceTexture(id, mat.textureId);
      world.setInstancePbrMaps(id, normalTex: mat.normalTextureId, mrTex: mat.mrTextureId);
      world.setInstanceShadow(id, cast: item.castShadows, receive: item.receiveShadows, shadowOnly: item.shadowOnly);
      world.bindInstanceAnimator(id, item.animatorId);
    }
    for (var i = frame.items.length; i < _instances.length; i++) {
      world.setInstanceVisible(_instances[i], false);
    }

    // Put the shadow-casting directional light first (native shadows use light 0).
    final lights = List<LightData>.of(frame.lights);
    final sunAt = lights.indexWhere((l) => l.castShadows);
    if (sunAt > 0) lights.insert(0, lights.removeAt(sunAt));
    final sun = sunAt >= 0 ? lights.first : null;

    final post = frame.post;
    world.setPostEffects(post);
    world.setSsao(
      post?.ssao ?? false,
      strength: post?.ssaoStrength ?? 0.55,
      radius: post?.ssaoRadius ?? 4,
    );
    world.setAntiAliasing(post?.antiAliasing ?? false);

    world.setDebugLines(frame.debugLines, depthTest: frame.debugDepthTest);
    world.setParticles(frame.particles);
    world.setShadows(
      enabled: sun != null,
      mapSize: sun?.shadowMapSize ?? 1024,
      distance: sun?.shadowDistance ?? 30,
      strength: sun?.shadowStrength ?? 1,
    );
    for (var i = 0; i < lights.length; i++) {
      final l = lights[i];
      final type = l.type == LightType.point ? 1 : 0;
      final vec = type == 1 ? l.position : l.direction;
      if (i >= _lights.length) {
        _lights.add(world.createLight(type, vec, l.color, 1.0, l.range));
        _lightTypes.add(type);
      } else if (_lightTypes[i] != type) {
        world.destroyLight(_lights[i]);
        _lights[i] = world.createLight(type, vec, l.color, 1.0, l.range);
        _lightTypes[i] = type;
      } else {
        world.setLight(_lights[i], vec, l.color, 1.0, l.range);
      }
    }
    for (var i = lights.length; i < _lights.length; i++) {
      world.setLight(_lights[i], Vector3(0, -1, 0), Vector3.zero(), 0.0);
    }
    world.setAmbientColor(frame.ambient);
    final c = frame.clearColor;
    final sky = Vector3(c.x, c.y, c.z);
    world.setEnvironment(skyTop: sky, skyHorizon: sky, ground: sky * 0.7);
  }

  /// Syncs [frame] and renders an RGBA8888 pixel buffer of `[width] x [height]`.
  Uint8List renderFrame(RenderFrame frame, int width, int height) {
    sync(frame);
    return world.renderRgba(
      width,
      height,
      view: frame.view,
      projection: frame.projection,
      eye: frame.cameraPosition,
    );
  }

  /// Builds a [RenderFrame] from [scene] + [camera], syncs it, and renders RGBA8888 pixels.
  Uint8List renderScene(Scene scene, Camera camera, int width, int height) {
    final frame = RenderFrame.build(scene, camera, width / math.max(1, height));
    return renderFrame(frame, width, height);
  }

  /// Headless one-liner: renders [scene] from [camera] and returns lossless PNG bytes.
  Uint8List renderScenePng(Scene scene, Camera camera, int width, int height) {
    final rgba = renderScene(scene, camera, width, height);
    return world.encodePng(width, height, rgba);
  }

  /// Destroys all owned native instances and lights and clears caches.
  void dispose() {
    if (!world.isDisposed) {
      for (final id in _instances) {
        world.destroyInstance(id);
      }
      for (final id in _lights) {
        world.destroyLight(id);
      }
    }
    _instances.clear();
    _lights.clear();
    _lightTypes.clear();
    _meshIds.clear();
  }
}
