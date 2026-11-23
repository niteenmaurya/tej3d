import 'dart:typed_data';

import '../../math/vec.dart';

import '../camera.dart';
import '../lod_group.dart';
import '../particles.dart';
import '../post_effects.dart';
import '../game_object.dart';
import '../light.dart';
import '../mesh_renderer.dart';
import 'material.dart';
import 'mesh.dart';

/// One mesh to draw this frame.
class DrawItem {
  DrawItem(
    this.mesh,
    this.material,
    this.world, {
    this.castShadows = true,
    this.receiveShadows = true,
    this.shadowOnly = false,
    this.animatorId = -1,
  });

  final Mesh mesh;
  final StandardMaterial material;
  final Matrix4 world;
  final bool castShadows, receiveShadows;

  /// Native animator of a skinned mesh, or -1.
  final int animatorId;

  /// Outside the camera view: not drawn, but its shadow may fall into the view.
  final bool shadowOnly;
}

/// A light in world space, ready for shading.
class LightData {
  LightData({
    required this.type,
    required this.direction,
    required this.position,
    required this.color,
    required this.range,
    this.castShadows = false,
    this.shadowDistance = 30.0,
    this.shadowStrength = 1.0,
    this.shadowMapSize = 1024,
  });

  final LightType type;

  /// Directional light that throws shadows (see `Light.castShadows`).
  final bool castShadows;
  final double shadowDistance, shadowStrength;
  final int shadowMapSize;

  /// Direction the light travels (directional only). Unit length.
  final Vector3 direction;
  final Vector3 position;

  /// Color times intensity.
  final Vector3 color;
  final double range;
}

class RenderStats {
  int objects = 0;
  int drawn = 0;
  int culled = 0;
}

/// Everything a render backend needs for one picture.
class RenderFrame {
  RenderFrame({
    required this.view,
    required this.projection,
    required this.viewProjection,
    required this.cameraPosition,
    required this.items,
    required this.lights,
    required this.ambient,
    required this.clearColor,
    required this.stats,
    this.post,
    Float32List? debugLines,
    this.debugDepthTest = true,
    Float32List? particles,
  })  : debugLines = debugLines ?? Float32List(0),
        particles = particles ?? Float32List(0);

  /// Debug lines (10 numbers each: a, b, rgba) from `scene.debug`.
  final Float32List debugLines;
  final bool debugDepthTest;

  /// Particle sprites (9 numbers each: position, size, rgba, flags).
  final Float32List particles;

  /// Picture effects of the camera, or null.
  final PostEffects? post;

  final Matrix4 view;
  final Matrix4 projection;
  final Matrix4 viewProjection;
  final Vector3 cameraPosition;
  final List<DrawItem> items;
  final List<LightData> lights;
  final Vector3 ambient;
  final Vector4 clearColor;
  final RenderStats stats;

  /// Reads the scene and makes the list of things to draw. Objects outside
  /// the camera view, on hidden layers or hidden are left out.
  static RenderFrame build(Scene scene, Camera camera, double aspect) {
    final view = camera.viewMatrix;
    final proj = camera.projectionMatrix(aspect);
    final vp = proj * view;
    final frustum = Frustum.matrix(vp);
    final items = <DrawItem>[];
    final lights = <LightData>[];
    final offscreen = <DrawItem>[]; // casters outside the view
    final stats = RenderStats();
    final sprites = ParticleBatch();
    final mask = camera.cullingMask;
    final eye = camera.transform.worldPosition;

    scene.forEachActive((go) {
      if (!mask.contains(go.layer)) return;
      final lodComp = go.getComponent<LODGroup>();
      final hasActiveLod = lodComp != null && lodComp.enabled;
      for (var ci = 0; ci < go.componentCount; ci++) {
        final c = go.componentAt(ci);
        if (!c.enabled) continue;
        if (c is MeshRenderer) {
          if (hasActiveLod || !c.visible) continue;
          stats.objects++;
          final world = go.transform.worldMatrix;
          final box = Aabb3.copy(c.mesh.bounds)..transform(world);
          if (!frustum.intersectsWithAabb3(box)) {
            stats.culled++;
            if (c.castShadows) {
              offscreen.add(
                DrawItem(
                  c.mesh,
                  c.material,
                  world,
                  castShadows: true,
                  receiveShadows: false,
                  shadowOnly: true,
                  animatorId: c.animatorId,
                ),
              );
            }
            continue;
          }
          stats.drawn++;
          items.add(
            DrawItem(
              c.mesh,
              c.material,
              world,
              castShadows: c.castShadows,
              receiveShadows: c.receiveShadows,
              animatorId: c.animatorId,
            ),
          );
        } else if (c is LODGroup) {
          final mr = go.getComponent<MeshRenderer>();
          if (mr != null && !mr.visible) continue;
          stats.objects++;
          final lvl = c.selectForCamera(eye);
          if (lvl == null) {
            stats.culled++;
            continue;
          }
          final world = go.transform.worldMatrix;
          final mesh = lvl.mesh;
          final mat = lvl.material ?? mr?.material ?? StandardMaterial();
          final castSh = mr?.castShadows ?? true;
          final recvSh = mr?.receiveShadows ?? true;
          final animId = mr?.animatorId ?? -1;
          final box = Aabb3.copy(mesh.bounds)..transform(world);
          if (!frustum.intersectsWithAabb3(box)) {
            stats.culled++;
            if (castSh) {
              offscreen.add(
                DrawItem(
                  mesh,
                  mat,
                  world,
                  castShadows: true,
                  receiveShadows: false,
                  shadowOnly: true,
                  animatorId: animId,
                ),
              );
            }
            continue;
          }
          stats.drawn++;
          items.add(
            DrawItem(
              mesh,
              mat,
              world,
              castShadows: castSh,
              receiveShadows: recvSh,
              animatorId: animId,
            ),
          );
        } else if (c is InstancedMeshRenderer) {
          final baseMat = c.material;
          for (final inst in c.instances) {
            stats.objects++;
            final world = inst.transform;
            final box = Aabb3.copy(c.mesh.bounds)..transform(world);
            final tinted = (inst.color.x == 1.0 &&
                    inst.color.y == 1.0 &&
                    inst.color.z == 1.0 &&
                    inst.color.w == 1.0)
                ? baseMat
                : StandardMaterial(
                    color: Vector4(
                      baseMat.color.x * inst.color.x,
                      baseMat.color.y * inst.color.y,
                      baseMat.color.z * inst.color.z,
                      baseMat.color.w * inst.color.w,
                    ),
                    emissive: baseMat.emissive.clone(),
                    unlit: baseMat.unlit,
                    cull: baseMat.cull,
                    specular: baseMat.specular,
                    shininess: baseMat.shininess,
                    metallic: baseMat.metallic,
                    roughness: baseMat.roughness,
                    ao: baseMat.ao,
                    clearcoat: baseMat.clearcoat,
                    clearcoatRoughness: baseMat.clearcoatRoughness,
                    alpha: baseMat.alpha,
                    textureId: baseMat.textureId,
                    normalTextureId: baseMat.normalTextureId,
                    mrTextureId: baseMat.mrTextureId,
                  );
            if (!frustum.intersectsWithAabb3(box)) {
              stats.culled++;
              if (c.castShadows) {
                offscreen.add(
                  DrawItem(
                    c.mesh,
                    tinted,
                    world,
                    castShadows: true,
                    receiveShadows: false,
                    shadowOnly: true,
                  ),
                );
              }
              continue;
            }
            stats.drawn++;
            items.add(
              DrawItem(
                c.mesh,
                tinted,
                world,
                castShadows: c.castShadows,
                receiveShadows: c.receiveShadows,
              ),
            );
          }
        } else if (c is ParticleSystem) {
          c.writeSprites(sprites);
        } else if (c is Light) {
          final t = go.transform;
          lights.add(
            LightData(
              type: c.type,
              direction: t.forward,
              position: t.worldPosition,
              color: c.color.scaled(c.intensity),
              range: c.range,
              castShadows: c.castShadows && c.type == LightType.directional,
              shadowDistance: c.shadowDistance,
              shadowStrength: c.shadowStrength,
              shadowMapSize: c.shadowMapSize,
            ),
          );
        }
      }
    });

    // Off screen objects only matter for shadows, and only near the camera.
    LightData? sun;
    for (final l in lights) {
      if (l.castShadows) {
        sun = l;
        break;
      }
    }
    if (sun != null) {
      final reach = sun.shadowDistance * 1.5;
      for (final it in offscreen) {
        if ((it.world.getTranslation() - eye).length <= reach) items.add(it);
      }
    }

    return RenderFrame(
      view: view,
      projection: proj,
      viewProjection: vp,
      cameraPosition: eye,
      items: items,
      lights: lights,
      ambient: scene.ambientColor.clone(),
      clearColor: scene.clearColor.clone(),
      stats: stats,
      post: camera.post,
      debugLines: scene.debug.enabled ? scene.debug.toFloats() : null,
      debugDepthTest: scene.debug.depthTest,
      particles: sprites.toFloats(),
    );
  }
}
