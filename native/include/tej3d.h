/* tej3d native core: plain C ABI so Dart (dart:ffi), C#, Swift, Kotlin or anything else can call it.
 * All objects are small integer handles. Heavy data stays inside the core.
 * Coordinates: right handed, +Y up, -Z forward for cameras. Matrices: column major float[16]. */
#ifndef TEJ3D_H
#define TEJ3D_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#if defined(_WIN32)
#define TEJ_API __declspec(dllexport)
#else
#define TEJ_API __attribute__((visibility("default")))
#endif

typedef struct TejWorld TejWorld;

typedef struct TejBodyDesc {
  int32_t shape;            /* 0 sphere, 1 box */
  float hx, hy, hz;         /* box half extents; sphere radius = hx */
  float mass;               /* 0 = static */
  int32_t kinematic, sensor;
  float px, py, pz;
  float qx, qy, qz, qw;
  float friction, restitution, linearDamping, angularDamping;
  uint32_t layer, mask;
  float gravityScale;
  int32_t trimesh;          /* shape 2 (mesh, static only): id from tej_trimesh_create */
} TejBodyDesc;

TEJ_API int32_t tej_version(void);
/* Memory helpers so every language allocates and frees with the same allocator. */
TEJ_API void* tej_alloc(size_t bytes);
TEJ_API void tej_free(void* p);
TEJ_API TejWorld* tej_world_create(void);
TEJ_API void tej_world_destroy(TejWorld*);
/* Steps physics, animation and body->instance sync. Call with a fixed dt (1/60). */
TEJ_API void tej_world_update(TejWorld*, float dt);

/* ---- meshes and textures. Vertex = 8 floats: pos3 normal3 uv2. Returns id or -1. */
TEJ_API int32_t tej_mesh_create(TejWorld*, const float* verts, int32_t vcount, const uint32_t* idx, int32_t icount);
TEJ_API int32_t tej_mesh_box(TejWorld*, float hx, float hy, float hz);
TEJ_API int32_t tej_mesh_sphere(TejWorld*, float r, int32_t segments, int32_t rings);
TEJ_API int32_t tej_mesh_cylinder(TejWorld*, float r, float halfHeight, int32_t segments);
TEJ_API int32_t tej_mesh_plane(TejWorld*, float hx, float hz, int32_t div, float uvScale);
/* joints: 4 bytes per vertex, weights: 4 floats per vertex. */
TEJ_API void tej_mesh_set_skin(TejWorld*, int32_t mesh, const uint8_t* joints, const float* weights);
/* Decodes a PNG or JPEG file. Call once with rgbaOut = NULL to learn the size (outW, outH), then again with a
   buffer of outW * outH * 4 bytes. Returns 1 on success, 0 on failure (the reason is written to err). */
TEJ_API int32_t tej_decode_image(const uint8_t* data, int32_t size, int32_t* outW, int32_t* outH, uint8_t* rgbaOut, char* err, int32_t errCapacity);
TEJ_API int32_t tej_texture_create(TejWorld*, int32_t w, int32_t h, const uint8_t* rgba);

/* ---- models. Loads a binary glTF (.glb, from Blender: File > Export > glTF 2.0, format glb).
 * Creates one instance per mesh piece and remembers the pieces. Returns the piece count, or -1
 * (read the reason with tej_model_error). Pieces of the last load come first in the list. */
TEJ_API int32_t tej_model_load_glb(TejWorld*, const uint8_t* data, int32_t size);
TEJ_API int32_t tej_model_error(TejWorld*, char* out, int32_t capacity);
/* things in the file that were skipped (for example a JPEG texture); empty if none */
TEJ_API int32_t tej_model_warning(TejWorld*, char* out, int32_t capacity);
TEJ_API int32_t tej_model_part_count(TejWorld*);
/* render mesh id of piece i, and its size (out2 = vertexCount, indexCount) */
TEJ_API int32_t tej_model_part_mesh(TejWorld*, int32_t i);
TEJ_API void tej_mesh_info(TejWorld*, int32_t mesh, int32_t* out2);
/* copies vertices (8 floats each: pos3 normal3 uv2) and indices out. Buffers must be big enough. */
TEJ_API void tej_mesh_copy(TejWorld*, int32_t mesh, float* verts, uint32_t* indices);
/* base color rgba of piece i, and the texture id it uses or -1 */
TEJ_API void tej_model_part_color(TejWorld*, int32_t i, float* out4);
TEJ_API int32_t tej_model_part_texture(TejWorld*, int32_t i);
/* instance id of piece i, or -1 */
TEJ_API int32_t tej_model_part_instance(TejWorld*, int32_t i);
/* node world matrix of piece i at load time (column major float[16]) */
TEJ_API void tej_model_part_matrix(TejWorld*, int32_t i, float* out16);
/* node name of piece i, written as UTF-8 and zero ended. Returns the full length. */
/* Skeleton id of a bone animated piece (create an animator for it, bind the piece's instance), or -1. */
TEJ_API int32_t tej_model_part_skeleton(TejWorld*, int32_t i);
/* Animations of the model files loaded so far (play them on an animator of the same skeleton). */
TEJ_API int32_t tej_model_clip_count(TejWorld*);
TEJ_API int32_t tej_model_clip_name(TejWorld*, int32_t i, char* out, int32_t capacity);
TEJ_API int32_t tej_model_clip_id(TejWorld*, int32_t i);
TEJ_API int32_t tej_model_clip_skeleton(TejWorld*, int32_t i);
TEJ_API float tej_clip_duration(TejWorld*, int32_t clip);
TEJ_API int32_t tej_skeleton_joint_count(TejWorld*, int32_t skeleton);
/* Bone name from the model file (empty if none). Returns the full length. */
TEJ_API int32_t tej_skeleton_joint_name(TejWorld*, int32_t skeleton, int32_t joint, char* out, int32_t capacity);
/* Copies joints and weights out (vertexCount * 4 each). Returns 0 if the mesh has no skin. */
TEJ_API int32_t tej_mesh_skin_copy(TejWorld*, int32_t mesh, uint8_t* joints, float* weights);
TEJ_API int32_t tej_model_part_name(TejWorld*, int32_t i, char* out, int32_t capacity);

/* ---- instances (things you see) */
TEJ_API int32_t tej_instance_create(TejWorld*, int32_t mesh);
TEJ_API void tej_instance_destroy(TejWorld*, int32_t id);
TEJ_API void tej_instance_set_transform(TejWorld*, int32_t id, const float* m16);
/* Many instances in one call: m16s holds 16 floats per id. */
TEJ_API void tej_instance_batch_set_transform(TejWorld*, const int32_t* ids, int32_t count, const float* m16s);
TEJ_API void tej_instance_set_mesh(TejWorld*, int32_t id, int32_t mesh);
TEJ_API void tej_instance_set_color(TejWorld*, int32_t id, float r, float g, float b, float a);
TEJ_API void tej_instance_set_texture(TejWorld*, int32_t id, int32_t texture);
TEJ_API void tej_instance_set_visible(TejWorld*, int32_t id, int32_t visible);
TEJ_API void tej_instance_set_material(TejWorld*, int32_t id, int32_t unlit, int32_t doubleSided, float specular, float emissive);
/* Enables PBR Cook-Torrance metallic/roughness shading + sky IBL reflections on an instance. */
TEJ_API void tej_instance_set_pbr(TejWorld*, int32_t id, float metallic, float roughness, float ao);
/* After binding, the core copies the body pose to the instance every update. No Dart round trip. */
TEJ_API void tej_instance_bind_body(TejWorld*, int32_t id, int32_t body, float sx, float sy, float sz);
TEJ_API void tej_instance_bind_animator(TejWorld*, int32_t id, int32_t animator);

/* ---- lights, camera, environment. type: 0 directional (x,y,z = direction), 1 point (x,y,z = position) */
TEJ_API int32_t tej_light_create(TejWorld*, int32_t type, float x, float y, float z, float r, float g, float b, float intensity, float range);
TEJ_API void tej_light_set(TejWorld*, int32_t id, float x, float y, float z, float r, float g, float b, float intensity, float range);
TEJ_API void tej_light_destroy(TejWorld*, int32_t id);
TEJ_API void tej_camera_set(TejWorld*, float px, float py, float pz, float tx, float ty, float tz, float fovY, float nearZ, float farZ);
/* colors are float[3] each (linear). */
TEJ_API void tej_env_set(TejWorld*, float ambient, float fogDensity, const float* skyTop, const float* skyHorizon, const float* ground, const float* fog);

/* Draw with matrices you give (column major float[16]) and the camera position (float[3], for shine
 * and fog). After this call tej_camera_set switches back to look-at mode. */
TEJ_API void tej_camera_set_matrices(TejWorld*, const float* view16, const float* proj16, const float* eye3);
/* Flat ambient light color (float[3], linear) instead of the sky tinted one. */
TEJ_API void tej_env_set_ambient_color(TejWorld*, float r, float g, float b);
/* ---- software renderer: fills width*height*4 RGBA bytes. */
/* Shadows of the first directional light (CPU renderer). mapSize 256..4096, distance in meters
   from the camera, strength 0..1. Turn it off with enabled = 0. */
TEJ_API void tej_env_set_shadows(TejWorld*, int32_t enabled, int32_t mapSize, float distance, float strength);
/* Debug lines drawn over the scene. data: 10 floats per line (ax ay az  bx by bz  r g b a). Replaces the
   lines of the last call; count 0 clears. depthTest 1: lines behind objects are hidden. */
TEJ_API void tej_debug_set_lines(TejWorld*, const float* data, int32_t count, int32_t depthTest);
/* Particles (camera facing sprites). data: 9 floats each (x y z  size  r g b a  flags). flags: bit 0 additive,
   bits 1-2 shape (0 soft round, 1 hard round, 2 square). Replaces the last call; count 0 clears. */
TEJ_API void tej_particles_set(TejWorld*, const float* data, int32_t count);

/* Picture effects after drawing (CPU renderer). enabled 0 leaves the picture untouched.
   tonemap: 0 none, 1 Reinhard, 2 ACES-like. contrast 1 and saturation 1 change nothing.
   vignette 0..1 darkens the corners. bloom is the glow strength (0 = off), bloomThreshold 0..1. */
/* Enables luminance edge anti-aliasing (FXAA-style) after rendering. */
TEJ_API void tej_env_set_aa(TejWorld*, int32_t enabled);
TEJ_API void tej_env_set_post(TejWorld*, int32_t enabled, float exposure, int32_t tonemap, float contrast, float saturation, float vignette, float bloom, float bloomThreshold);
/* Per object, flags: 1 = casts a shadow, 2 = receives one, 4 = shadow only (not drawn in the view). */
TEJ_API void tej_instance_set_shadow(TejWorld*, int32_t id, int32_t flags);

TEJ_API void tej_render_software(TejWorld*, int32_t width, int32_t height, uint8_t* rgba);

/* ---- physics */
TEJ_API void tej_physics_set_gravity(TejWorld*, float x, float y, float z);
/* Static triangle mesh collider (tracks, terrain, buildings). verts: 3 floats each.
 * Returns an id for TejBodyDesc.trimesh (use shape 2), or -1. */
TEJ_API int32_t tej_trimesh_create(TejWorld*, const float* verts, int32_t vertexCount, const uint32_t* indices, int32_t indexCount);
/* Same, from a render mesh, with a matrix baked in (column major float[16], may be NULL). */
TEJ_API int32_t tej_trimesh_from_mesh(TejWorld*, int32_t mesh, const float* m16);
TEJ_API int32_t tej_body_create(TejWorld*, const TejBodyDesc*);
/* Shapes (TejBodyDesc.shape): 0 sphere (hx = radius), 1 box, 2 mesh, 3 capsule (hx = radius, hy = half length of
   the straight part, axis Y), 4 compound (then call tej_body_set_children). */
/* Parts of a compound body, 11 floats each: shape (0 sphere, 1 box, 3 capsule), hx hy hz, px py pz, qx qy qz qw.
   Returns 1 on success. The body origin is taken as its center of mass. */
TEJ_API int32_t tej_body_set_children(TejWorld*, int32_t body, const float* data, int32_t count);
/* Vertices of a convex hull body (shape 5), 3 floats per vertex (at least 4 vertices). Returns 1 on success. */
TEJ_API int32_t tej_body_set_convex_hull(TejWorld*, int32_t body, const float* verts, int32_t vertexCount);
TEJ_API void tej_body_destroy(TejWorld*, int32_t body);
TEJ_API void tej_body_set_transform(TejWorld*, int32_t body, const float* pos3, const float* quat4);
TEJ_API void tej_body_get_transform(TejWorld*, int32_t body, float* out7); /* px py pz qx qy qz qw */
/* Many bodies in one call: out holds 7 floats per id (px py pz qx qy qz qw). */
TEJ_API void tej_body_batch_get_transform(TejWorld*, const int32_t* ids, int32_t count, float* out);
TEJ_API void tej_body_set_velocity(TejWorld*, int32_t body, const float* lin3, const float* ang3);
TEJ_API void tej_body_get_velocity(TejWorld*, int32_t body, float* out6);
TEJ_API void tej_body_apply_force(TejWorld*, int32_t body, float x, float y, float z);
TEJ_API void tej_body_apply_impulse(TejWorld*, int32_t body, float ix, float iy, float iz, float px, float py, float pz);
TEJ_API int32_t tej_body_is_sleeping(TejWorld*, int32_t body);
/* Enables continuous collision detection (CCD) so fast bodies do not tunnel through thin walls. */
TEJ_API void tej_body_set_ccd(TejWorld*, int32_t body, int32_t enabled);
/* out8 = body, t, point xyz, normal xyz. Returns 1 on hit. ignoreBody may be -1. */
TEJ_API int32_t tej_raycast(TejWorld*, float ox, float oy, float oz, float dx, float dy, float dz, float maxDist, uint32_t mask, int32_t ignoreBody, float* out8);
/* Events of the last update. 4 ints each: bodyA, bodyB, type (0 begin, 1 end), isTrigger. */
TEJ_API int32_t tej_events_count(TejWorld*);
TEJ_API void tej_events_copy(TejWorld*, int32_t* out);
TEJ_API void tej_physics_stats(TejWorld*, int32_t* out3); /* bodies, awake, contacts */

/* ---- joints. type: 0 ball, 1 fixed, 2 hinge, 3 rope, 4 spring, 5 slider, 6 coneTwist. a, b: body ids (-1 = the world; then
   the anchor on that side is a world position). anchors: local to each body. axis: hinge axis, local to a
   (world if a is -1). params (12 floats): limit(0/1), lower, upper (radians), motorSpeed (rad/s, speed of a
   relative to b), motorMaxTorque (0 = off), minLen, maxLen (rope), restLen, hz, damping (spring),
   breakForce (0 = never), collideConnected (0/1). Returns a joint id or -1. */
TEJ_API int32_t tej_joint_create(TejWorld*, int32_t type, int32_t a, int32_t b, const float* anchorA, const float* anchorB, const float* axis, const float* params);
TEJ_API void tej_joint_destroy(TejWorld*, int32_t id);
TEJ_API int32_t tej_joint_alive(TejWorld*, int32_t id);
TEJ_API int32_t tej_joint_broken(TejWorld*, int32_t id);
TEJ_API float tej_joint_angle(TejWorld*, int32_t id);
TEJ_API float tej_joint_force(TejWorld*, int32_t id);
TEJ_API void tej_joint_set_motor(TejWorld*, int32_t id, float speed, float maxTorque);
TEJ_API void tej_joint_set_limits(TejWorld*, int32_t id, int32_t enabled, float lower, float upper);

/* ---- character controller: a capsule you move by hand (walk, jump, steps, slopes).
   Position is the feet. mask: layers it collides with. ignoreBody: a body id to skip, or -1. */
TEJ_API int32_t tej_character_create(TejWorld*, float radius, float height, float stepHeight, float slopeLimitDeg, uint32_t mask, int32_t ignoreBody, float x, float y, float z);
TEJ_API void tej_character_destroy(TejWorld*, int32_t id);
/* delta is in world meters (include the vertical part). snapToGround: 0 or 1 */
TEJ_API void tej_character_move(TejWorld*, int32_t id, float dx, float dy, float dz, int32_t snapToGround);
TEJ_API void tej_character_teleport(TejWorld*, int32_t id, float x, float y, float z);
/* out10 = x, y, z, grounded, hitCeiling, hitWall, groundBody, groundNormal x, y, z */
TEJ_API void tej_character_state(TejWorld*, int32_t id, float* out10);
/* Extras: crouch (returns 1 if state matches crouch), pushForce for dynamic bodies, climbing mode (ladders). */
TEJ_API int32_t tej_character_set_crouch(TejWorld*, int32_t id, int32_t crouch, float crouchHeight);
TEJ_API int32_t tej_character_is_crouched(TejWorld*, int32_t id);
TEJ_API void tej_character_set_push_force(TejWorld*, int32_t id, float pushForce);
TEJ_API void tej_character_set_climbing(TejWorld*, int32_t id, int32_t climbing);

/* ---- animation */
/* bind: 10 floats per joint: t3, quat4 (xyzw), scale3. parents[i] < i or -1. */
TEJ_API int32_t tej_skeleton_create(TejWorld*, int32_t jointCount, const int32_t* parents, const float* bind);
TEJ_API int32_t tej_clip_create(TejWorld*, float duration, int32_t jointCount);
/* channel: 0 translation (3 floats/key), 1 rotation (4 floats/key xyzw), 2 scale (3 floats/key) */
TEJ_API void tej_clip_set_channel(TejWorld*, int32_t clip, int32_t joint, int32_t channel, int32_t keyCount, const float* times, const float* values);
TEJ_API int32_t tej_animator_create(TejWorld*, int32_t skeleton);
TEJ_API void tej_animator_destroy(TejWorld*, int32_t animator);
TEJ_API void tej_animator_play(TejWorld*, int32_t animator, int32_t clip, int32_t loop, float speed);
TEJ_API void tej_animator_crossfade(TejWorld*, int32_t animator, int32_t clip, float seconds, int32_t loop, float speed);
TEJ_API float tej_animator_normalized_time(TejWorld*, int32_t animator);
TEJ_API int32_t tej_animator_finished(TejWorld*, int32_t animator);
/* model space matrix of a joint (for attaching objects to hands, heads, etc). */
TEJ_API void tej_animator_joint_matrix(TejWorld*, int32_t animator, int32_t joint, float* out16);


/* ---- AAA PBR materials (normal/MR maps, clearcoat car paint, Fresnel glass, SSAO, 360 cubemap IBL) */
TEJ_API void tej_instance_set_pbr_maps(TejWorld*, int32_t id, int32_t normalTex, int32_t mrTex);
TEJ_API void tej_instance_set_clearcoat(TejWorld*, int32_t id, float clearcoat, float clearcoatRoughness);
TEJ_API void tej_instance_set_alpha(TejWorld*, int32_t id, float alpha);
TEJ_API void tej_env_set_ssao(TejWorld*, int32_t enabled, float strength, int32_t radius);
TEJ_API int32_t tej_env_set_cubemap(TejWorld*, int32_t faceSize, const uint8_t* rgba6Faces);

/* ---- custom zero-dependency media encoder (PNG, JPEG, MJPEG-AVI; no ffmpeg/libpng/libjpeg) */
TEJ_API int32_t tej_encode_png(TejWorld*, int32_t width, int32_t height, const uint8_t* rgba);
TEJ_API int32_t tej_encode_jpeg(TejWorld*, int32_t width, int32_t height, const uint8_t* rgba, int32_t quality);
TEJ_API int32_t tej_media_copy(TejWorld*, uint8_t* out, int32_t capacity);
TEJ_API int32_t tej_video_begin(TejWorld*, int32_t width, int32_t height, int32_t fps, int32_t quality);
TEJ_API int32_t tej_video_add_frame(TejWorld*, const uint8_t* rgba);
TEJ_API int32_t tej_video_finish(TejWorld*);

/* ---- zero-dependency hardware GPU bridge (OpenGL 3.3 / GLES 3.0; falls back cleanly to CPU PBR) */
TEJ_API int32_t tej_gpu_init(TejWorld*);
TEJ_API int32_t tej_gpu_is_available(TejWorld*);
TEJ_API int32_t tej_gpu_render(TejWorld*, int32_t width, int32_t height, uint8_t* readbackRgba);
TEJ_API void tej_gpu_shutdown(TejWorld*);

#ifdef __cplusplus
}
#endif
#endif
