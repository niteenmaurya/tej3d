/// Pure-Dart GPU frame preparation: packs meshes into interleaved vertex/index
/// buffers, builds uniform blocks (camera, directional shadow matrix, lights,
/// material, post effects), and sorts draw calls for GPU submission.
///
/// Kept free of `dart:ui` and Flutter imports so it compiles and tests on the
/// plain Dart VM without a GPU.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../math/vec.dart';
import '../light.dart';
import 'material.dart';
import 'mesh.dart';
import 'render_frame.dart';

/// Vertex buffer layout: 8 floats (32 bytes) per vertex:
/// `pos.xyz (3) + normal.xyz (3) + uv.xy (2)`.
class GpuVertexLayout {
  static const int floatsPerVertex = 8;
  static const int bytesPerVertex = 32;
}

/// Packed GPU-ready vertex and index buffers for one [Mesh].
class GpuMeshBuffer {
  GpuMeshBuffer({
    required this.vertices,
    required this.indices,
    required this.vertexCount,
    required this.indexCount,
  });

  /// Interleaved `pos3, normal3, uv2` float buffer.
  final Float32List vertices;

  /// Triangle index buffer.
  final Uint32List indices;
  final int vertexCount;
  final int indexCount;

  /// Packs a [Mesh] into an interleaved [GpuMeshBuffer].
  factory GpuMeshBuffer.fromMesh(Mesh mesh) {
    final a = mesh.arrays;
    final vc = a.vertexCount;
    final uvs = a.uvs;
    final verts = Float32List(vc * GpuVertexLayout.floatsPerVertex);
    for (var i = 0; i < vc; i++) {
      final base = i * 8;
      verts[base] = a.positions[i * 3];
      verts[base + 1] = a.positions[i * 3 + 1];
      verts[base + 2] = a.positions[i * 3 + 2];
      verts[base + 3] = a.normals[i * 3];
      verts[base + 4] = a.normals[i * 3 + 1];
      verts[base + 5] = a.normals[i * 3 + 2];
      if (uvs != null && i * 2 + 1 < uvs.length) {
        verts[base + 6] = uvs[i * 2];
        verts[base + 7] = uvs[i * 2 + 1];
      } else {
        verts[base + 6] = 0.0;
        verts[base + 7] = 0.0;
      }
    }
    return GpuMeshBuffer(
      vertices: verts,
      indices: Uint32List.fromList(a.indices),
      vertexCount: vc,
      indexCount: a.indices.length,
    );
  }
}

/// Packed per-draw-call uniform block (model matrix + material parameters).
class GpuDrawCall {
  GpuDrawCall({
    required this.mesh,
    required this.modelMatrix,
    required this.color,
    required this.emissive,
    required this.unlit,
    required this.specular,
    required this.shininess,
    required this.cull,
    required this.castShadows,
    required this.receiveShadows,
    required this.shadowOnly,
    required this.animatorId,
    required this.cameraDistanceSq,
  });

  final Mesh mesh;

  /// Column-major 4x4 model matrix (16 floats).
  final Float32List modelMatrix;

  /// Material base RGBA.
  final Float32List color;

  /// Material emissive RGB.
  final Float32List emissive;
  final bool unlit;
  final double specular;
  final double shininess;
  final CullMode cull;
  final bool castShadows;
  final bool receiveShadows;
  final bool shadowOnly;
  final int animatorId;
  final double cameraDistanceSq;

  bool get isTransparent => color[3] < 0.999;

  /// Packs material uniforms into a std140-friendly 12-float block:
  /// `[r, g, b, a, er, eg, eb, unlit, specular, shininess, receiveShadows, cull]`.
  Float32List packMaterialUniforms() {
    return Float32List.fromList([
      color[0], color[1], color[2], color[3],
      emissive[0], emissive[1], emissive[2], unlit ? 1.0 : 0.0,
      specular, shininess, receiveShadows ? 1.0 : 0.0, cull.index.toDouble(),
    ]);
  }
}

/// Packed frame-level uniform buffer data.
class GpuFrameUniforms {
  GpuFrameUniforms({
    required this.view,
    required this.projection,
    required this.viewProjection,
    required this.lightSpaceMatrix,
    required this.cameraPosition,
    required this.ambient,
    required this.clearColor,
    required this.lightsPacked,
    required this.lightCount,
    required this.shadowsEnabled,
    required this.shadowMapSize,
    required this.shadowStrength,
  });

  static const int maxLights = 8;

  /// Each light is packed as 12 floats (3 vec4s):
  /// `[type, range, castShadow, 0, posOrDir.xyz, 0, color.rgb, 0]`.
  static const int floatsPerLight = 12;

  final Float32List view;
  final Float32List projection;
  final Float32List viewProjection;
  final Float32List lightSpaceMatrix;
  final Float32List cameraPosition;
  final Float32List ambient;
  final Float32List clearColor;
  final Float32List lightsPacked;
  final int lightCount;
  final bool shadowsEnabled;
  final int shadowMapSize;
  final double shadowStrength;
}

/// Complete GPU submission packet generated from one [RenderFrame].
class GpuFramePacket {
  GpuFramePacket({
    required this.uniforms,
    required this.shadowDraws,
    required this.opaqueDraws,
    required this.transparentDraws,
    required this.particles,
    required this.debugLines,
    required this.debugDepthTest,
  });

  final GpuFrameUniforms uniforms;

  /// Draw calls for the directional shadow map pass.
  final List<GpuDrawCall> shadowDraws;

  /// Visible opaque draw calls sorted front-to-back to reduce overdraw.
  final List<GpuDrawCall> opaqueDraws;

  /// Visible transparent draw calls sorted back-to-front for alpha blending.
  final List<GpuDrawCall> transparentDraws;

  /// Raw particle sprite floats (9 floats per sprite).
  final Float32List particles;

  /// Raw debug line floats (10 floats per line).
  final Float32List debugLines;
  final bool debugDepthTest;

  int get totalMainDraws => opaqueDraws.length + transparentDraws.length;
}

/// Compiles a [RenderFrame] into a [GpuFramePacket] ready for GPU submission.
class GpuFrameBuilder {
  const GpuFrameBuilder._();

  static GpuFramePacket build(RenderFrame frame) {
    final shadowDraws = <GpuDrawCall>[];
    final opaqueDraws = <GpuDrawCall>[];
    final transparentDraws = <GpuDrawCall>[];
    final eye = frame.cameraPosition;

    for (final item in frame.items) {
      final pos = item.world.getTranslation();
      final distSq = (pos - eye).length2;
      final effectiveAlpha = (item.material.alpha * item.material.color.w).clamp(0.0, 1.0);
      final call = GpuDrawCall(
        mesh: item.mesh,
        modelMatrix: _mat4ToFloats(item.world),
        color: Float32List.fromList([
          item.material.color.x,
          item.material.color.y,
          item.material.color.z,
          effectiveAlpha,
        ]),
        emissive: Float32List.fromList([
          item.material.emissive.x,
          item.material.emissive.y,
          item.material.emissive.z,
        ]),
        unlit: item.material.unlit,
        specular: item.material.specular,
        shininess: item.material.shininess,
        cull: item.material.cull,
        castShadows: item.castShadows,
        receiveShadows: item.receiveShadows,
        shadowOnly: item.shadowOnly,
        animatorId: item.animatorId,
        cameraDistanceSq: distSq,
      );

      if (item.castShadows) {
        shadowDraws.add(call);
      }
      if (!item.shadowOnly) {
        if (call.isTransparent) {
          transparentDraws.add(call);
        } else {
          opaqueDraws.add(call);
        }
      }
    }

    // Opaque: front-to-back (smaller distance first).
    opaqueDraws.sort((a, b) => a.cameraDistanceSq.compareTo(b.cameraDistanceSq));
    // Transparent: back-to-front (larger distance first).
    transparentDraws.sort((a, b) => b.cameraDistanceSq.compareTo(a.cameraDistanceSq));

    // Find primary shadow-casting directional light.
    LightData? sun;
    for (final l in frame.lights) {
      if (l.castShadows && l.type == LightType.directional) {
        sun = l;
        break;
      }
    }

    final lightSpace = sun != null
        ? computeDirectionalShadowMatrix(
            lightDirection: sun.direction,
            focusPoint: eye,
            distance: sun.shadowDistance,
          )
        : Matrix4.identity();

    final count = math.min(frame.lights.length, GpuFrameUniforms.maxLights);
    final lightsPacked = Float32List(GpuFrameUniforms.maxLights * GpuFrameUniforms.floatsPerLight);
    for (var i = 0; i < count; i++) {
      final l = frame.lights[i];
      final b = i * GpuFrameUniforms.floatsPerLight;
      lightsPacked[b] = l.type == LightType.directional ? 0.0 : 1.0;
      lightsPacked[b + 1] = l.range;
      lightsPacked[b + 2] = l.castShadows ? 1.0 : 0.0;
      lightsPacked[b + 3] = 0.0;
      final v = l.type == LightType.directional ? l.direction : l.position;
      lightsPacked[b + 4] = v.x;
      lightsPacked[b + 5] = v.y;
      lightsPacked[b + 6] = v.z;
      lightsPacked[b + 7] = 0.0;
      lightsPacked[b + 8] = l.color.x;
      lightsPacked[b + 9] = l.color.y;
      lightsPacked[b + 10] = l.color.z;
      lightsPacked[b + 11] = 0.0;
    }

    final uniforms = GpuFrameUniforms(
      view: _mat4ToFloats(frame.view),
      projection: _mat4ToFloats(frame.projection),
      viewProjection: _mat4ToFloats(frame.viewProjection),
      lightSpaceMatrix: _mat4ToFloats(lightSpace),
      cameraPosition: Float32List.fromList([eye.x, eye.y, eye.z, 1.0]),
      ambient: Float32List.fromList([frame.ambient.x, frame.ambient.y, frame.ambient.z, 1.0]),
      clearColor: Float32List.fromList([
        frame.clearColor.x,
        frame.clearColor.y,
        frame.clearColor.z,
        frame.clearColor.w,
      ]),
      lightsPacked: lightsPacked,
      lightCount: count,
      shadowsEnabled: sun != null,
      shadowMapSize: sun?.shadowMapSize ?? 0,
      shadowStrength: sun?.shadowStrength ?? 0.0,
    );

    return GpuFramePacket(
      uniforms: uniforms,
      shadowDraws: shadowDraws,
      opaqueDraws: opaqueDraws,
      transparentDraws: transparentDraws,
      particles: frame.particles,
      debugLines: frame.debugLines,
      debugDepthTest: frame.debugDepthTest,
    );
  }

  /// Builds an orthographic light-space view-projection matrix centered around
  /// [focusPoint] for directional shadow mapping.
  static Matrix4 computeDirectionalShadowMatrix({
    required Vector3 lightDirection,
    required Vector3 focusPoint,
    required double distance,
  }) {
    final dir = lightDirection.length2 > 1e-12 ? lightDirection.normalized() : Vector3(0, -1, 0);
    final up = dir.y.abs() > 0.95 ? Vector3(0, 0, 1) : Vector3(0, 1, 0);
    final lightEye = focusPoint - dir * distance;

    final zAxis = (lightEye - focusPoint).normalized();
    final xAxis = up.cross(zAxis).normalized();
    final yAxis = zAxis.cross(xAxis);

    final view = Matrix4.identity();
    view.setEntry(0, 0, xAxis.x);
    view.setEntry(0, 1, xAxis.y);
    view.setEntry(0, 2, xAxis.z);
    view.setEntry(0, 3, -xAxis.dot(lightEye));

    view.setEntry(1, 0, yAxis.x);
    view.setEntry(1, 1, yAxis.y);
    view.setEntry(1, 2, yAxis.z);
    view.setEntry(1, 3, -yAxis.dot(lightEye));

    view.setEntry(2, 0, zAxis.x);
    view.setEntry(2, 1, zAxis.y);
    view.setEntry(2, 2, zAxis.z);
    view.setEntry(2, 3, -zAxis.dot(lightEye));

    final proj = Matrix4.zero();
    setOrthographicMatrix(proj, -distance, distance, -distance, distance, 0.1, distance * 3.0);
    return proj * view;
  }

  static Float32List _mat4ToFloats(Matrix4 m) {
    final s = m.storage;
    final out = Float32List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = s[i];
    }
    return out;
  }
}
