// tej3d world: everything the engine owns on the native side.
// Dart holds small integer handles; heavy data (meshes, bodies, poses) stays here.
#pragma once
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
#include "anim.h"
#include "media_enc.h"
#include "gpu_gl.h"
#include "character.h"
#include "physics.h"
#include "tmath.h"

namespace tej {

struct Mesh {
  std::vector<float> verts;     // 8 floats per vertex: pos3 normal3 uv2
  std::vector<uint32_t> idx;
  std::vector<uint8_t> joints;  // 4 per vertex (optional)
  std::vector<float> weights;   // 4 per vertex (optional)
  bool skinned() const { return !joints.empty(); }
  int vertexCount() const { return (int)(verts.size() / 8); }
};
struct Texture {
  int w = 0, h = 0;
  std::vector<uint8_t> rgba;                // level 0
  std::vector<std::vector<uint8_t>> mips;   // levels 1.. (half size each)
  int levels() const { return 1 + (int)mips.size(); }
};
void buildMips(Texture& t);  // call after filling w, h, rgba
struct Instance {
  bool alive = false, visible = true, unlit = false, doubleSided = false;
  bool castShadow = true, receiveShadow = true;
  bool shadowOnly = false;  // not drawn in the camera view, only casts a shadow (off screen casters)
  int mesh = -1, texture = -1, body = -1, animator = -1;
  V3 scale{1, 1, 1};
  M4 xf;
  float color[4] = {1, 1, 1, 1};
  float emissive = 0;
  float specular = 0.2f;
  bool pbr = false;
  float metallic = 0.0f;
  float roughness = 0.5f;
  float ao = 1.0f;
  int normalTex = -1;
  int mrTex = -1;
  float clearcoat = 0.0f;
  float clearcoatRoughness = 0.06f;
  float alpha = 1.0f;
};
struct Light {
  bool alive = false;
  int type = 0;  // 0 directional, 1 point
  V3 vec{0, -1, 0};  // direction light travels (directional) or position (point)
  V3 color{1, 1, 1};
  float intensity = 1, range = 20;
};
struct Camera {
  bool useMatrices = false;  // true: draw with view and proj below (from Dart)
  M4 view, proj;
  V3 pos{0, 3, 8}, target{0, 0, 0}, up{0, 1, 0};
  float fovY = 1.0f, nearZ = 0.1f, farZ = 500.0f;
};
struct Environment {
  V3 skyTop{0.25f, 0.50f, 0.85f}, skyHorizon{0.75f, 0.85f, 0.95f}, ground{0.25f, 0.22f, 0.20f};
  float ambient = 0.35f;
  bool useAmbientColor = false;  // true: use ambientColor as it is (no sky tint)
  V3 ambientColor{0.35f, 0.37f, 0.42f};
  float fogDensity = 0.0f;
  V3 fogColor{0.75f, 0.85f, 0.95f};
  // Shadows of the first directional light (CPU renderer).
  bool shadows = false;
  int shadowMapSize = 1024;     // texels per side (256..4096)
  float shadowDistance = 30.0f; // how far from the camera shadows are drawn, in meters
  float shadowStrength = 1.0f;  // 0 = none, 1 = fully dark
  // Picture effects after drawing (CPU renderer). All off by default: the picture is not touched.
  bool post = false;
  float exposure = 1.0f;        // brightness multiplier (linear light)
  int tonemap = 0;              // 0 none, 1 Reinhard, 2 ACES-like
  float contrast = 1.0f;        // 1 = unchanged
  float saturation = 1.0f;      // 0 = gray, 1 = unchanged
  float vignette = 0.0f;        // 0..1, darkens the corners
  float bloom = 0.0f;           // glow strength around bright parts, 0 = off
  float bloomThreshold = 0.7f;  // how bright (0..1) before it glows
  bool fxaa = false;            // edge anti-aliasing in post pass
  bool ssao = false;            // screen-space ambient occlusion
  float ssaoStrength = 0.55f;
  int ssaoRadius = 4;
  int cubemapSize = 0;          // 6 faces (+X,-X,+Y,-Y,+Z,-Z), faceSize^2 * 4 * 6
  std::vector<uint8_t> cubemapRgba;
};
struct SkeletonRes {
  Skeleton sk;
  std::vector<std::string> names;  // bone names (from a model file), may be empty
};
struct ClipRes {
  Clip clip;
};
struct AnimatorRes {
  bool alive = false;
  Animator anim;
  int skeleton = -1;
  std::vector<float> skin;  // cached skin matrices
};

/// One drawable piece loaded from a model file (a mesh primitive on a node).
struct ModelPart {
  std::string name;  // node name from the file
  int instance = -1;
  M4 world;          // node world matrix at load time
  int skeleton = -1; // skeleton id if the piece is skinned (bone animated), else -1
};

/// A line drawn on top of the scene for debugging (physics shapes, paths, rays).
struct DebugLine {
  V3 a, b;
  float r = 1, g = 1, bl = 1, al = 1;
};

/// One camera facing sprite (a particle). flags: bit 0 additive blend, bits 1-2 shape (0 soft round,
/// 1 hard round, 2 square).
struct ParticleSprite {
  V3 pos;
  float size = 0.1f;            // width in meters
  float r = 1, g = 1, b = 1, a = 1;
  int flags = 0;
};

/// One animation from a model file, ready to play on an animator of [skeleton].
struct ModelClip {
  std::string name;
  int clip = -1;      // index in World::clips
  int skeleton = -1;  // index in World::skeletons
};

struct World {
  PhysicsWorld physics;
  std::vector<Character> characters;
  std::vector<Mesh> meshes;
  std::vector<Texture> textures;
  std::vector<Instance> instances;
  std::vector<Light> lights;
  std::vector<std::unique_ptr<SkeletonRes>> skeletons;
  std::vector<std::unique_ptr<ClipRes>> clips;
  std::vector<AnimatorRes> animators;
  Camera camera;
  Environment env;
  double time = 0;
  std::vector<ModelPart> modelParts;  // filled by loadGlb
  std::vector<ModelClip> modelClips;  // filled by loadGlb
  std::vector<DebugLine> debugLines;  // replaced by the game every frame
  bool debugDepthTest = true;         // hide lines behind objects
  std::vector<ParticleSprite> particles;  // replaced by the game every frame
  std::string modelError;
  std::string modelWarning;  // things in a model file that were skipped

  std::vector<uint8_t> mediaBuf;
  VideoRecorder recorder;
  GpuGlBackend gpu;
  void update(float dt);  // physics, animation, body->instance sync
};

// Primitive mesh builders (CCW winding, outward normals).
Mesh makeBox(float hx, float hy, float hz);
Mesh makeSphere(float r, int segments, int rings);
Mesh makeCylinder(float r, float halfHeight, int segments);  // axis = Y
Mesh makePlane(float hx, float hz, int div, float uvScale);

// CPU reference renderer. rgba must hold w*h*4 bytes.
void renderSoftware(const World& w, int width, int height, uint8_t* rgba);
void applyPost(const Environment& e, int width, int height, uint8_t* rgba);  // picture effects, used by renderSoftware

}  // namespace tej
