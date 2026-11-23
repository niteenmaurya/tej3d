#include "png.h"
#include "jpeg.h"
#include "../include/tej3d.h"

#include <cstdlib>
#include <cstring>
#include "gltf.h"
#include "world.h"

using namespace tej;

struct TejWorld : tej::World {};
#define W(w) (*static_cast<tej::World*>(w))

template <typename T>
static T* at(std::vector<T>& v, int32_t i) { return (i >= 0 && i < (int32_t)v.size() && v[i].alive) ? &v[i] : nullptr; }

static int32_t addMesh(TejWorld* w, Mesh&& m) {
  if (!w) return -1;
  W(w).meshes.push_back(std::move(m));
  return (int32_t)W(w).meshes.size() - 1;
}

extern "C" {

int32_t tej_version(void) { return 100; }
void* tej_alloc(size_t n) { return std::calloc(1, n ? n : 1); }
void tej_free(void* p) { std::free(p); }
TejWorld* tej_world_create(void) { return new TejWorld(); }
void tej_world_destroy(TejWorld* w) { delete w; }
void tej_world_update(TejWorld* w, float dt) { if (w) W(w).update(dt); }

int32_t tej_mesh_create(TejWorld* w, const float* v, int32_t vc, const uint32_t* idx, int32_t ic) {
  if (!w || !v || !idx || vc <= 0 || ic < 3) return -1;
  Mesh m;
  m.verts.assign(v, v + (size_t)vc * 8);
  m.idx.assign(idx, idx + ic);
  for (uint32_t i : m.idx) if (i >= (uint32_t)vc) return -1;
  return addMesh(w, std::move(m));
}
int32_t tej_mesh_box(TejWorld* w, float x, float y, float z) { return w ? addMesh(w, makeBox(x, y, z)) : -1; }
int32_t tej_mesh_sphere(TejWorld* w, float r, int32_t s, int32_t g) { return w ? addMesh(w, makeSphere(r, std::max(3, s), std::max(2, g))) : -1; }
int32_t tej_mesh_cylinder(TejWorld* w, float r, float h, int32_t s) { return w ? addMesh(w, makeCylinder(r, h, std::max(3, s))) : -1; }
int32_t tej_mesh_plane(TejWorld* w, float x, float z, int32_t d, float uv) { return w ? addMesh(w, makePlane(x, z, std::max(1, d), uv)) : -1; }
void tej_mesh_set_skin(TejWorld* w, int32_t mesh, const uint8_t* j, const float* wt) {
  if (!w || mesh < 0 || mesh >= (int32_t)W(w).meshes.size() || !j || !wt) return;
  Mesh& m = W(w).meshes[mesh];
  size_t n = (size_t)m.vertexCount() * 4;
  m.joints.assign(j, j + n);
  m.weights.assign(wt, wt + n);
}
int32_t tej_texture_create(TejWorld* w, int32_t tw, int32_t th, const uint8_t* rgba) {
  if (!w || tw <= 0 || th <= 0 || !rgba) return -1;
  Texture t;
  t.w = tw; t.h = th;
  t.rgba.assign(rgba, rgba + (size_t)tw * th * 4);
  buildMips(t);
  W(w).textures.push_back(std::move(t));
  return (int32_t)W(w).textures.size() - 1;
}

int32_t tej_model_load_glb(TejWorld* w, const uint8_t* data, int32_t size) {
  if (!w || !data || size < 0) return -1;
  return loadGlb(W(w), data, (size_t)size);
}
int32_t tej_model_error(TejWorld* w, char* out, int32_t cap) {
  if (!w) return 0;
  const std::string& e = W(w).modelError;
  if (out && cap > 0) {
    size_t n = std::min((size_t)(cap - 1), e.size());
    std::memcpy(out, e.data(), n);
    out[n] = 0;
  }
  return (int32_t)e.size();
}
int32_t tej_model_warning(TejWorld* w, char* out, int32_t cap) {
  if (!w) return 0;
  const std::string& e = W(w).modelWarning;
  if (out && cap > 0) {
    size_t n = std::min((size_t)(cap - 1), e.size());
    std::memcpy(out, e.data(), n);
    out[n] = 0;
  }
  return (int32_t)e.size();
}
int32_t tej_model_part_mesh(TejWorld* w, int32_t i) {
  if (!w || i < 0 || i >= (int32_t)W(w).modelParts.size()) return -1;
  int inst = W(w).modelParts[i].instance;
  return (inst >= 0 && inst < (int32_t)W(w).instances.size()) ? W(w).instances[inst].mesh : -1;
}
void tej_mesh_info(TejWorld* w, int32_t mesh, int32_t* out) {
  if (!out) return;
  if (!w || mesh < 0 || mesh >= (int32_t)W(w).meshes.size()) { out[0] = out[1] = 0; return; }
  out[0] = W(w).meshes[mesh].vertexCount();
  out[1] = (int32_t)W(w).meshes[mesh].idx.size();
}
void tej_mesh_copy(TejWorld* w, int32_t mesh, float* verts, uint32_t* idx) {
  if (!w || !verts || !idx || mesh < 0 || mesh >= (int32_t)W(w).meshes.size()) return;
  const Mesh& m = W(w).meshes[mesh];
  if (!m.verts.empty()) std::memcpy(verts, m.verts.data(), m.verts.size() * sizeof(float));
  if (!m.idx.empty()) std::memcpy(idx, m.idx.data(), m.idx.size() * sizeof(uint32_t));
}
void tej_model_part_color(TejWorld* w, int32_t i, float* out) {
  if (!out) return;
  out[0] = out[1] = out[2] = out[3] = 1.0f;
  if (!w || i < 0 || i >= (int32_t)W(w).modelParts.size()) return;
  int inst = W(w).modelParts[i].instance;
  if (inst >= 0 && inst < (int32_t)W(w).instances.size()) std::memcpy(out, W(w).instances[inst].color, 16);
}
int32_t tej_model_part_texture(TejWorld* w, int32_t i) {
  if (!w || i < 0 || i >= (int32_t)W(w).modelParts.size()) return -1;
  int inst = W(w).modelParts[i].instance;
  return (inst >= 0 && inst < (int32_t)W(w).instances.size()) ? W(w).instances[inst].texture : -1;
}
int32_t tej_model_part_count(TejWorld* w) { return w ? (int32_t)W(w).modelParts.size() : 0; }
int32_t tej_model_part_instance(TejWorld* w, int32_t i) {
  return (w && i >= 0 && i < (int32_t)W(w).modelParts.size()) ? W(w).modelParts[i].instance : -1;
}
void tej_model_part_matrix(TejWorld* w, int32_t i, float* out) {
  if (w && out && i >= 0 && i < (int32_t)W(w).modelParts.size()) std::memcpy(out, W(w).modelParts[i].world.m, 64);
}
int32_t tej_model_part_name(TejWorld* w, int32_t i, char* out, int32_t cap) {
  if (!w || i < 0 || i >= (int32_t)W(w).modelParts.size()) return 0;
  const std::string& s = W(w).modelParts[i].name;
  if (out && cap > 0) {
    size_t n = std::min((size_t)(cap - 1), s.size());
    std::memcpy(out, s.data(), n);
    out[n] = 0;
  }
  return (int32_t)s.size();
}

int32_t tej_instance_create(TejWorld* w, int32_t mesh) {
  if (!w || mesh < 0 || mesh >= (int32_t)W(w).meshes.size()) return -1;
  auto& v = W(w).instances;
  for (size_t i = 0; i < v.size(); i++)
    if (!v[i].alive) { v[i] = Instance(); v[i].alive = true; v[i].mesh = mesh; return (int32_t)i; }
  v.emplace_back();
  v.back().alive = true; v.back().mesh = mesh;
  return (int32_t)v.size() - 1;
}
void tej_instance_destroy(TejWorld* w, int32_t id) { if (w) if (auto* i = at(W(w).instances, id)) i->alive = false; }
void tej_instance_set_transform(TejWorld* w, int32_t id, const float* m) {
  if (!w || !m) return;
  if (auto* i = at(W(w).instances, id)) { std::memcpy(i->xf.m, m, 64); i->body = -1; }
}
void tej_instance_batch_set_transform(TejWorld* w, const int32_t* ids, int32_t n, const float* m) {
  if (!w || !ids || !m || n <= 0) return;
  for (int32_t k = 0; k < n; k++)
    if (auto* i = at(W(w).instances, ids[k])) { std::memcpy(i->xf.m, m + (size_t)k * 16, 64); i->body = -1; }
}
void tej_instance_set_mesh(TejWorld* w, int32_t id, int32_t mesh) {
  if (!w) return;
  if (auto* i = at(W(w).instances, id)) if (mesh >= 0 && mesh < (int32_t)W(w).meshes.size()) i->mesh = mesh;
}
void tej_instance_set_color(TejWorld* w, int32_t id, float r, float g, float b, float a) {
  if (!w) return;
  if (auto* i = at(W(w).instances, id)) { i->color[0] = r; i->color[1] = g; i->color[2] = b; i->color[3] = a; }
}
void tej_instance_set_texture(TejWorld* w, int32_t id, int32_t t) { if (w) if (auto* i = at(W(w).instances, id)) i->texture = t; }
void tej_instance_set_visible(TejWorld* w, int32_t id, int32_t v) { if (w) if (auto* i = at(W(w).instances, id)) i->visible = v != 0; }
void tej_instance_set_pbr(TejWorld* w, int32_t id, float metallic, float roughness, float ao) {
  if (!w) return;
  if (Instance* i = at(W(w).instances, id)) { i->pbr = true; i->metallic = metallic; i->roughness = roughness; i->ao = ao; }
}
void tej_instance_set_material(TejWorld* w, int32_t id, int32_t unlit, int32_t ds, float spec, float emi) {
  if (!w) return;
  if (auto* i = at(W(w).instances, id)) { i->unlit = unlit != 0; i->doubleSided = ds != 0; i->specular = spec; i->emissive = emi; }
}
void tej_instance_bind_body(TejWorld* w, int32_t id, int32_t body, float sx, float sy, float sz) {
  if (!w) return;
  if (auto* i = at(W(w).instances, id)) { i->body = body; i->scale = V3(sx, sy, sz); }
}
void tej_instance_bind_animator(TejWorld* w, int32_t id, int32_t a) { if (w) if (auto* i = at(W(w).instances, id)) i->animator = a; }

int32_t tej_light_create(TejWorld* w, int32_t type, float x, float y, float z, float r, float g, float b, float in, float range) {
  if (!w) return -1;
  auto& v = W(w).lights;
  Light L; L.alive = true; L.type = type; L.vec = V3(x, y, z); L.color = V3(r, g, b); L.intensity = in; L.range = range;
  for (size_t i = 0; i < v.size(); i++) if (!v[i].alive) { v[i] = L; return (int32_t)i; }
  v.push_back(L);
  return (int32_t)v.size() - 1;
}
void tej_light_set(TejWorld* w, int32_t id, float x, float y, float z, float r, float g, float b, float in, float range) {
  if (!w) return;
  if (auto* l = at(W(w).lights, id)) { l->vec = V3(x, y, z); l->color = V3(r, g, b); l->intensity = in; l->range = range; }
}
void tej_light_destroy(TejWorld* w, int32_t id) { if (w) if (auto* l = at(W(w).lights, id)) l->alive = false; }
void tej_camera_set(TejWorld* w, float px, float py, float pz, float tx, float ty, float tz, float fov, float zn, float zf) {
  if (!w) return;
  Camera& c = W(w).camera;
  c.useMatrices = false;
  c.pos = V3(px, py, pz); c.target = V3(tx, ty, tz); c.fovY = fov; c.nearZ = zn; c.farZ = zf;
}
void tej_env_set(TejWorld* w, float amb, float fog, const float* top, const float* hor, const float* gr, const float* fc) {
  if (!w) return;
  Environment& e = W(w).env;
  e.ambient = amb; e.fogDensity = fog;
  if (top) e.skyTop = V3(top[0], top[1], top[2]);
  if (hor) e.skyHorizon = V3(hor[0], hor[1], hor[2]);
  if (gr) e.ground = V3(gr[0], gr[1], gr[2]);
  if (fc) e.fogColor = V3(fc[0], fc[1], fc[2]);
}

void tej_env_set_ambient_color(TejWorld* w, float r, float g, float b) {
  if (!w) return;
  Environment& e = W(w).env;
  e.useAmbientColor = true;
  e.ambientColor = V3(r, g, b);
}

void tej_camera_set_matrices(TejWorld* w, const float* v, const float* p, const float* e) {
  if (!w || !v || !p || !e) return;
  Camera& c = W(w).camera;
  std::memcpy(c.view.m, v, 64);
  std::memcpy(c.proj.m, p, 64);
  c.pos = V3(e[0], e[1], e[2]);
  c.useMatrices = true;
}

void tej_env_set_shadows(TejWorld* w, int32_t enabled, int32_t mapSize, float distance, float strength) {
  if (!w) return;
  Environment& e = W(w).env;
  e.shadows = enabled != 0;
  e.shadowMapSize = mapSize < 256 ? 256 : (mapSize > 4096 ? 4096 : mapSize);
  e.shadowDistance = distance > 1.0f ? distance : 1.0f;
  e.shadowStrength = strength < 0 ? 0 : (strength > 1 ? 1 : strength);
}
void tej_env_set_aa(TejWorld* w, int32_t enabled) { if (w) W(w).env.fxaa = enabled != 0; }
void tej_env_set_post(TejWorld* w, int32_t enabled, float exposure, int32_t tonemap, float contrast, float saturation, float vignette, float bloom, float bloomThreshold) {
  if (!w) return;
  Environment& e = W(w).env;
  e.post = enabled != 0;
  e.exposure = exposure < 0 ? 0 : exposure;
  e.tonemap = tonemap < 0 ? 0 : (tonemap > 2 ? 2 : tonemap);
  e.contrast = contrast;
  e.saturation = saturation < 0 ? 0 : saturation;
  e.vignette = vignette < 0 ? 0 : (vignette > 1 ? 1 : vignette);
  e.bloom = bloom < 0 ? 0 : bloom;
  e.bloomThreshold = bloomThreshold < 0 ? 0 : (bloomThreshold > 1 ? 1 : bloomThreshold);
}
void tej_instance_set_shadow(TejWorld* w, int32_t id, int32_t flags) {
  if (!w) return;
  if (Instance* i = at(W(w).instances, id)) { i->castShadow = (flags & 1) != 0; i->receiveShadow = (flags & 2) != 0; i->shadowOnly = (flags & 4) != 0; }
}

void tej_render_software(TejWorld* w, int32_t width, int32_t height, uint8_t* rgba) {
  if (w && width > 0 && height > 0 && rgba) renderSoftware(W(w), width, height, rgba);
}

void tej_physics_set_gravity(TejWorld* w, float x, float y, float z) { if (w) W(w).physics.gravity = V3(x, y, z); }
int32_t tej_trimesh_create(TejWorld* w, const float* v, int32_t vc, const uint32_t* idx, int32_t ic) {
  return w ? W(w).physics.createTriMesh(v, vc, idx, ic) : -1;
}
int32_t tej_trimesh_from_mesh(TejWorld* w, int32_t mesh, const float* m16) {
  if (!w || mesh < 0 || mesh >= (int32_t)W(w).meshes.size()) return -1;
  const Mesh& m = W(w).meshes[mesh];
  M4 xf;
  if (m16) std::memcpy(xf.m, m16, 64);
  std::vector<float> pos((size_t)m.vertexCount() * 3);
  for (int i = 0; i < m.vertexCount(); i++) {
    V3 p = transformPoint(xf, V3(m.verts[i * 8], m.verts[i * 8 + 1], m.verts[i * 8 + 2]));
    pos[i * 3] = p.x; pos[i * 3 + 1] = p.y; pos[i * 3 + 2] = p.z;
  }
  return W(w).physics.createTriMesh(pos.data(), m.vertexCount(), m.idx.data(), (int32_t)m.idx.size());
}
int32_t tej_body_create(TejWorld* w, const TejBodyDesc* d) {
  if (!w || !d) return -1;
  BodyDesc b;
  b.shape = d->shape == 0 ? ShapeType::Sphere : (d->shape == 2 ? ShapeType::Mesh : (d->shape == 3 ? ShapeType::Capsule : (d->shape == 4 ? ShapeType::Compound : (d->shape == 5 ? ShapeType::ConvexHull : ShapeType::Box))));
  b.triMesh = d->trimesh;
  b.half = V3(d->hx, d->hy, d->hz); b.mass = d->mass; b.kinematic = d->kinematic != 0; b.sensor = d->sensor != 0;
  b.pos = V3(d->px, d->py, d->pz); b.rot = Q(d->qx, d->qy, d->qz, d->qw);
  b.friction = d->friction; b.restitution = d->restitution; b.linearDamping = d->linearDamping; b.angularDamping = d->angularDamping;
  b.layer = d->layer & 31u; b.mask = d->mask; b.gravityScale = d->gravityScale;
  return W(w).physics.createBody(b);
}
int32_t tej_body_set_children(TejWorld* w, int32_t body, const float* d, int32_t count) {
  if (!w) return 0;
  std::vector<ChildShape> parts;
  if (d && count > 0) {
    parts.reserve((size_t)count);
    for (int32_t i = 0; i < count; i++) {
      const float* p = d + (size_t)i * 11;
      ChildShape c;
      int sh = (int)p[0];
      c.shape = sh == 0 ? ShapeType::Sphere : (sh == 3 ? ShapeType::Capsule : ShapeType::Box);
      c.half = V3(p[1], p[2], p[3]); c.pos = V3(p[4], p[5], p[6]); c.rot = Q(p[7], p[8], p[9], p[10]);
      parts.push_back(c);
    }
  }
  return W(w).physics.setChildren(body, parts) ? 1 : 0;
}
int32_t tej_body_set_convex_hull(TejWorld* w, int32_t body, const float* verts, int32_t vertexCount) {
  if (!w || !verts || vertexCount < 4) return 0;
  std::vector<V3> pts((size_t)vertexCount);
  for (int32_t i = 0; i < vertexCount; i++) {
    pts[i] = V3(verts[i * 3], verts[i * 3 + 1], verts[i * 3 + 2]);
  }
  return W(w).physics.setConvexHull(body, pts.data(), vertexCount) ? 1 : 0;
}
void tej_body_destroy(TejWorld* w, int32_t b) { if (w) W(w).physics.destroyBody(b); }
void tej_body_set_transform(TejWorld* w, int32_t b, const float* p, const float* q) {
  if (!w || !p || !q) return;
  W(w).physics.setTransform(b, V3(p[0], p[1], p[2]), Q(q[0], q[1], q[2], q[3]));
}
void tej_body_get_transform(TejWorld* w, int32_t id, float* o) {
  if (!w || !o) return;
  if (Body* b = W(w).physics.body(id)) {
    o[0] = b->pos.x; o[1] = b->pos.y; o[2] = b->pos.z; o[3] = b->rot.x; o[4] = b->rot.y; o[5] = b->rot.z; o[6] = b->rot.w;
  }
}
void tej_body_batch_get_transform(TejWorld* w, const int32_t* ids, int32_t n, float* o) {
  if (!w || !ids || !o || n <= 0) return;
  for (int32_t k = 0; k < n; k++) {
    Body* b = W(w).physics.body(ids[k]);
    float* f = o + (size_t)k * 7;
    if (!b) { f[0] = f[1] = f[2] = f[3] = f[4] = f[5] = 0; f[6] = 1; continue; }
    f[0] = b->pos.x; f[1] = b->pos.y; f[2] = b->pos.z; f[3] = b->rot.x; f[4] = b->rot.y; f[5] = b->rot.z; f[6] = b->rot.w;
  }
}
void tej_body_set_velocity(TejWorld* w, int32_t id, const float* l, const float* a) {
  if (!w || !l || !a) return;
  if (Body* b = W(w).physics.body(id)) { b->linVel = V3(l[0], l[1], l[2]); b->angVel = V3(a[0], a[1], a[2]); W(w).physics.wake(id); }
}
void tej_body_get_velocity(TejWorld* w, int32_t id, float* o) {
  if (!w || !o) return;
  if (Body* b = W(w).physics.body(id)) {
    o[0] = b->linVel.x; o[1] = b->linVel.y; o[2] = b->linVel.z; o[3] = b->angVel.x; o[4] = b->angVel.y; o[5] = b->angVel.z;
  }
}
void tej_body_apply_force(TejWorld* w, int32_t id, float x, float y, float z) { if (w) W(w).physics.applyForce(id, V3(x, y, z)); }
void tej_body_apply_impulse(TejWorld* w, int32_t id, float ix, float iy, float iz, float px, float py, float pz) {
  if (w) W(w).physics.applyImpulse(id, V3(ix, iy, iz), V3(px, py, pz));
}
void tej_body_set_ccd(TejWorld* w, int32_t body, int32_t enabled) { if (w) W(w).physics.setCcd(body, enabled != 0); }
int32_t tej_body_is_sleeping(TejWorld* w, int32_t id) { if (!w) return 0; Body* b = W(w).physics.body(id); return b && b->sleeping; }
int32_t tej_raycast(TejWorld* w, float ox, float oy, float oz, float dx, float dy, float dz, float md, uint32_t mask, int32_t ign, float* o) {
  if (!w) return 0;
  RayHit h;
  if (!W(w).physics.raycast(V3(ox, oy, oz), V3(dx, dy, dz), md, mask, ign, h)) return 0;
  if (o) {
    o[0] = (float)h.body; o[1] = h.t; o[2] = h.point.x; o[3] = h.point.y; o[4] = h.point.z; o[5] = h.normal.x; o[6] = h.normal.y; o[7] = h.normal.z;
  }
  return 1;
}
int32_t tej_events_count(TejWorld* w) { return w ? (int32_t)W(w).physics.events().size() : 0; }
void tej_events_copy(TejWorld* w, int32_t* out) {
  if (!w || !out) return;
  for (auto& e : W(w).physics.events()) { *out++ = e.a; *out++ = e.b; *out++ = e.type; *out++ = e.sensor; }
}
void tej_physics_stats(TejWorld* w, int32_t* o) {
  if (!o) return;
  if (!w) { o[0] = o[1] = o[2] = 0; return; }
  o[0] = W(w).physics.bodyCount(); o[1] = W(w).physics.awakeCount(); o[2] = W(w).physics.contactCount();
}

int32_t tej_skeleton_create(TejWorld* w, int32_t n, const int32_t* parents, const float* bind) {
  if (!w || !parents || !bind || n <= 0 || n > 255) return -1;
  auto r = std::make_unique<SkeletonRes>();
  for (int i = 0; i < n; i++) {
    if (parents[i] >= i) return -1;
    r->sk.parent.push_back(parents[i]);
    const float* f = bind + i * 10;
    Xform x;
    x.t = V3(f[0], f[1], f[2]); x.r = normalize(Q(f[3], f[4], f[5], f[6])); x.s = V3(f[7], f[8], f[9]);
    r->sk.bind.push_back(x);
  }
  r->sk.finalize();
  W(w).skeletons.push_back(std::move(r));
  return (int32_t)W(w).skeletons.size() - 1;
}
int32_t tej_clip_create(TejWorld* w, float duration, int32_t jointCount) {
  if (!w) return -1;
  auto r = std::make_unique<ClipRes>();
  r->clip.duration = duration;
  r->clip.tracks.resize(std::max(0, jointCount));
  W(w).clips.push_back(std::move(r));
  return (int32_t)W(w).clips.size() - 1;
}
void tej_clip_set_channel(TejWorld* w, int32_t clip, int32_t joint, int32_t ch, int32_t n, const float* times, const float* vals) {
  if (!w || !times || !vals || clip < 0 || clip >= (int32_t)W(w).clips.size()) return;
  Clip& c = W(w).clips[clip]->clip;
  if (joint < 0 || joint >= (int32_t)c.tracks.size() || n <= 0) return;
  JointTrack& t = c.tracks[joint];
  if (ch == 1) {
    t.r.times.assign(times, times + n);
    t.r.values.resize(n);
    for (int i = 0; i < n; i++) t.r.values[i] = normalize(Q(vals[i * 4], vals[i * 4 + 1], vals[i * 4 + 2], vals[i * 4 + 3]));
  } else {
    Channel<V3>& c3 = ch == 0 ? t.t : t.s;
    c3.times.assign(times, times + n);
    c3.values.resize(n);
    for (int i = 0; i < n; i++) c3.values[i] = V3(vals[i * 3], vals[i * 3 + 1], vals[i * 3 + 2]);
  }
}
int32_t tej_animator_create(TejWorld* w, int32_t sk) {
  if (!w || sk < 0 || sk >= (int32_t)W(w).skeletons.size()) return -1;
  auto& v = W(w).animators;
  AnimatorRes a;
  a.alive = true; a.skeleton = sk; a.anim.skeleton = &W(w).skeletons[sk]->sk;
  a.anim.update(0);
  a.anim.skinMatrices(a.skin);
  for (size_t i = 0; i < v.size(); i++) if (!v[i].alive) { v[i] = std::move(a); return (int32_t)i; }
  v.push_back(std::move(a));
  return (int32_t)v.size() - 1;
}
void tej_animator_destroy(TejWorld* w, int32_t id) { if (w) if (auto* a = at(W(w).animators, id)) a->alive = false; }
void tej_animator_play(TejWorld* w, int32_t id, int32_t clip, int32_t loop, float speed) {
  if (!w) return;
  auto* a = at(W(w).animators, id);
  if (a && clip >= 0 && clip < (int32_t)W(w).clips.size()) a->anim.play(&W(w).clips[clip]->clip, loop != 0, speed);
}
void tej_animator_crossfade(TejWorld* w, int32_t id, int32_t clip, float sec, int32_t loop, float speed) {
  if (!w) return;
  auto* a = at(W(w).animators, id);
  if (a && clip >= 0 && clip < (int32_t)W(w).clips.size()) a->anim.crossfade(&W(w).clips[clip]->clip, sec, loop != 0, speed);
}
float tej_animator_normalized_time(TejWorld* w, int32_t id) { if (!w) return 0.0f; auto* a = at(W(w).animators, id); return a ? a->anim.normalizedTime() : 0.0f; }
int32_t tej_animator_finished(TejWorld* w, int32_t id) { if (!w) return 0; auto* a = at(W(w).animators, id); return a && a->anim.finished(); }
void tej_animator_joint_matrix(TejWorld* w, int32_t id, int32_t j, float* out) {
  if (!w || !out) return;
  auto* a = at(W(w).animators, id);
  if (!a) return;
  std::vector<M4> m;
  a->anim.modelMatrices(m);
  if (j >= 0 && j < (int32_t)m.size()) std::memcpy(out, m[j].m, 64);
}


int32_t tej_character_create(TejWorld* w, float radius, float height, float stepHeight, float slopeLimitDeg, uint32_t mask, int32_t ignoreBody, float x, float y, float z) {
  if (!w) return -1;
  Character c;
  c.alive = true;
  c.d.radius = radius > 0.01f ? radius : 0.01f;
  c.d.height = height > 2 * c.d.radius ? height : 2 * c.d.radius;
  c.d.stepHeight = stepHeight > 0 ? stepHeight : 0;
  c.d.slopeLimitDeg = slopeLimitDeg;
  c.d.mask = mask;
  c.d.ignoreBody = ignoreBody;
  c.pos = V3(x, y, z);
  auto& v = W(w).characters;
  for (size_t i = 0; i < v.size(); i++) {
    if (!v[i].alive) { v[i] = c; return (int32_t)i; }
  }
  v.push_back(c);
  return (int32_t)v.size() - 1;
}
void tej_character_destroy(TejWorld* w, int32_t id) {
  if (w) if (Character* c = at(W(w).characters, id)) c->alive = false;
}
void tej_character_move(TejWorld* w, int32_t id, float dx, float dy, float dz, int32_t snap) {
  if (w) if (Character* c = at(W(w).characters, id)) c->move(W(w).physics, V3(dx, dy, dz), snap != 0);
}
void tej_character_teleport(TejWorld* w, int32_t id, float x, float y, float z) {
  if (w) if (Character* c = at(W(w).characters, id)) c->teleport(V3(x, y, z));
}
void tej_character_state(TejWorld* w, int32_t id, float* o) {
  if (!w || !o) return;
  Character* c = at(W(w).characters, id);
  if (!c) return;
  o[0] = c->pos.x; o[1] = c->pos.y; o[2] = c->pos.z;
  o[3] = c->grounded ? 1.f : 0.f; o[4] = c->hitCeiling ? 1.f : 0.f; o[5] = c->hitWall ? 1.f : 0.f;
  o[6] = (float)c->groundBody;
  o[7] = c->groundNormal.x; o[8] = c->groundNormal.y; o[9] = c->groundNormal.z;
}
int32_t tej_character_set_crouch(TejWorld* w, int32_t id, int32_t crouch, float crouchHeight) {
  if (!w) return 0;
  if (auto* c = at(W(w).characters, id)) return c->setCrouch(W(w).physics, crouch != 0, crouchHeight) ? 1 : 0;
  return 0;
}
int32_t tej_character_is_crouched(TejWorld* w, int32_t id) {
  if (!w) return 0;
  if (auto* c = at(W(w).characters, id)) return c->crouched ? 1 : 0;
  return 0;
}
void tej_character_set_push_force(TejWorld* w, int32_t id, float pushForce) {
  if (w) if (auto* c = at(W(w).characters, id)) c->pushForce = pushForce;
}
void tej_character_set_climbing(TejWorld* w, int32_t id, int32_t climbing) {
  if (w) if (auto* c = at(W(w).characters, id)) c->climbing = climbing != 0;
}

int32_t tej_model_part_skeleton(TejWorld* w, int32_t i) {
  if (!w) return -1;
  auto& p = W(w).modelParts;
  return (i >= 0 && i < (int32_t)p.size()) ? p[i].skeleton : -1;
}
int32_t tej_model_clip_count(TejWorld* w) { return w ? (int32_t)W(w).modelClips.size() : 0; }
int32_t tej_model_clip_name(TejWorld* w, int32_t i, char* out, int32_t cap) {
  if (!w) return 0;
  auto& c = W(w).modelClips;
  if (i < 0 || i >= (int32_t)c.size()) return 0;
  const std::string& e = c[i].name;
  if (out && cap > 0) {
    size_t n = std::min((size_t)(cap - 1), e.size());
    std::memcpy(out, e.data(), n);
    out[n] = 0;
  }
  return (int32_t)e.size();
}
int32_t tej_model_clip_id(TejWorld* w, int32_t i) {
  if (!w) return -1;
  auto& c = W(w).modelClips;
  return (i >= 0 && i < (int32_t)c.size()) ? c[i].clip : -1;
}
int32_t tej_model_clip_skeleton(TejWorld* w, int32_t i) {
  if (!w) return -1;
  auto& c = W(w).modelClips;
  return (i >= 0 && i < (int32_t)c.size()) ? c[i].skeleton : -1;
}
float tej_clip_duration(TejWorld* w, int32_t clip) {
  return (w && clip >= 0 && clip < (int32_t)W(w).clips.size()) ? W(w).clips[clip]->clip.duration : 0.0f;
}
int32_t tej_skeleton_joint_count(TejWorld* w, int32_t sk) {
  return (w && sk >= 0 && sk < (int32_t)W(w).skeletons.size()) ? W(w).skeletons[sk]->sk.count() : 0;
}
int32_t tej_skeleton_joint_name(TejWorld* w, int32_t sk, int32_t j, char* out, int32_t cap) {
  if (!w || sk < 0 || sk >= (int32_t)W(w).skeletons.size()) return 0;
  const auto& names = W(w).skeletons[sk]->names;
  if (j < 0 || j >= (int32_t)names.size()) return 0;
  const std::string& e = names[j];
  if (out && cap > 0) {
    size_t n = std::min((size_t)(cap - 1), e.size());
    std::memcpy(out, e.data(), n);
    out[n] = 0;
  }
  return (int32_t)e.size();
}
int32_t tej_mesh_skin_copy(TejWorld* w, int32_t mesh, uint8_t* joints, float* weights) {
  if (!w || !joints || !weights || mesh < 0 || mesh >= (int32_t)W(w).meshes.size()) return 0;
  Mesh* m = &W(w).meshes[mesh];
  if (!m->skinned()) return 0;
  std::memcpy(joints, m->joints.data(), m->joints.size());
  std::memcpy(weights, m->weights.data(), m->weights.size() * sizeof(float));
  return 1;
}

int32_t tej_joint_create(TejWorld* w, int32_t type, int32_t a, int32_t b, const float* anchorA, const float* anchorB, const float* axis, const float* p) {
  if (!w || !anchorA || !anchorB || !axis || !p) return -1;
  JointDesc d;
  switch (type) {
    case 1: d.type = JointType::Fixed; break;
    case 2: d.type = JointType::Hinge; break;
    case 3: d.type = JointType::Rope; break;
    case 4: d.type = JointType::Spring; break;
    case 5: d.type = JointType::Slider; break;
    case 6: d.type = JointType::ConeTwist; break;
    default: d.type = JointType::Ball; break;
  }
  d.a = a; d.b = b;
  d.anchorA = V3(anchorA[0], anchorA[1], anchorA[2]);
  d.anchorB = V3(anchorB[0], anchorB[1], anchorB[2]);
  d.axis = V3(axis[0], axis[1], axis[2]);
  d.limit = p[0] != 0; d.lower = p[1]; d.upper = p[2];
  d.motorSpeed = p[3]; d.motorMaxTorque = p[4];
  d.minLen = p[5]; d.maxLen = p[6];
  d.restLen = p[7]; d.hz = p[8]; d.damping = p[9];
  d.breakForce = p[10]; d.collideConnected = p[11] != 0;
  return W(w).physics.createJoint(d);
}
void tej_joint_destroy(TejWorld* w, int32_t id) { if (w) W(w).physics.destroyJoint(id); }
int32_t tej_joint_alive(TejWorld* w, int32_t id) { return (w && W(w).physics.jointAlive(id)) ? 1 : 0; }
int32_t tej_joint_broken(TejWorld* w, int32_t id) { return (w && W(w).physics.jointBroken(id)) ? 1 : 0; }
float tej_joint_angle(TejWorld* w, int32_t id) { return w ? W(w).physics.jointAngle(id) : 0.0f; }
float tej_joint_force(TejWorld* w, int32_t id) { return w ? W(w).physics.jointForce(id) : 0.0f; }
void tej_joint_set_motor(TejWorld* w, int32_t id, float speed, float maxTorque) { if (w) W(w).physics.setJointMotor(id, speed, maxTorque); }
void tej_joint_set_limits(TejWorld* w, int32_t id, int32_t on, float lo, float hi) { if (w) W(w).physics.setJointLimits(id, on != 0, lo, hi); }

int32_t tej_decode_image(const uint8_t* data, int32_t size, int32_t* outW, int32_t* outH, uint8_t* rgbaOut, char* err, int32_t errCap) {
  if (!data || size <= 0) {
    if (err && errCap > 0) {
      const char* msg = "empty image data";
      size_t n = std::min((size_t)(errCap - 1), std::strlen(msg));
      std::memcpy(err, msg, n);
      err[n] = 0;
    }
    return 0;
  }
  int iw = 0, ih = 0;
  std::vector<uint8_t> px;
  std::string e;
  bool jpeg = size >= 3 && data[0] == 0xFF && data[1] == 0xD8;
  bool ok = jpeg ? decodeJpeg(data, (size_t)size, iw, ih, px, e) : decodePng(data, (size_t)size, iw, ih, px, e);
  if (!ok) {
    if (err && errCap > 0) { size_t n = std::min((size_t)(errCap - 1), e.size()); std::memcpy(err, e.data(), n); err[n] = 0; }
    return 0;
  }
  if (outW) *outW = iw;
  if (outH) *outH = ih;
  if (rgbaOut) std::memcpy(rgbaOut, px.data(), px.size());
  return 1;
}

void tej_debug_set_lines(TejWorld* w, const float* d, int32_t count, int32_t depthTest) {
  if (!w) return;
  auto& v = W(w).debugLines;
  v.clear();
  W(w).debugDepthTest = depthTest != 0;
  if (!d || count <= 0) return;
  v.reserve((size_t)count);
  for (int32_t i = 0; i < count; i++) {
    const float* p = d + (size_t)i * 10;
    DebugLine l;
    l.a = V3(p[0], p[1], p[2]); l.b = V3(p[3], p[4], p[5]);
    l.r = p[6]; l.g = p[7]; l.bl = p[8]; l.al = p[9];
    v.push_back(l);
  }
}
void tej_particles_set(TejWorld* w, const float* d, int32_t count) {
  if (!w) return;
  auto& v = W(w).particles;
  v.clear();
  if (!d || count <= 0) return;
  v.reserve((size_t)count);
  for (int32_t i = 0; i < count; i++) {
    const float* p = d + (size_t)i * 9;
    ParticleSprite s;
    s.pos = V3(p[0], p[1], p[2]); s.size = p[3];
    s.r = p[4]; s.g = p[5]; s.b = p[6]; s.a = p[7]; s.flags = (int)p[8];
    v.push_back(s);
  }
}



void tej_instance_set_pbr_maps(TejWorld* w, int32_t id, int32_t normalTex, int32_t mrTex) {
  if (!w) return;
  if (Instance* in = at(W(w).instances, id)) {
    in->normalTex = normalTex;
    in->mrTex = mrTex;
    in->pbr = true;
  }
}

void tej_instance_set_clearcoat(TejWorld* w, int32_t id, float clearcoat, float clearcoatRoughness) {
  if (!w) return;
  if (Instance* in = at(W(w).instances, id)) {
    in->clearcoat = std::max(0.0f, std::min(1.0f, clearcoat));
    in->clearcoatRoughness = std::max(0.02f, std::min(1.0f, clearcoatRoughness));
    in->pbr = true;
  }
}

void tej_instance_set_alpha(TejWorld* w, int32_t id, float alpha) {
  if (!w) return;
  if (Instance* in = at(W(w).instances, id)) {
    in->alpha = std::max(0.0f, std::min(1.0f, alpha));
  }
}

void tej_env_set_ssao(TejWorld* w, int32_t enabled, float strength, int32_t radius) {
  if (!w) return;
  W(w).env.ssao = (enabled != 0);
  W(w).env.ssaoStrength = std::max(0.0f, std::min(1.0f, strength));
  W(w).env.ssaoRadius = std::max(1, std::min(12, radius));
}

int32_t tej_env_set_cubemap(TejWorld* w, int32_t faceSize, const uint8_t* rgba6Faces) {
  if (!w || faceSize <= 0 || faceSize > 1024 || !rgba6Faces) {
    if (w) { W(w).env.cubemapSize = 0; W(w).env.cubemapRgba.clear(); }
    return 0;
  }
  size_t total = (size_t)faceSize * faceSize * 4 * 6;
  W(w).env.cubemapSize = faceSize;
  W(w).env.cubemapRgba.assign(rgba6Faces, rgba6Faces + total);
  return 1;
}

int32_t tej_encode_png(TejWorld* w, int32_t width, int32_t height, const uint8_t* rgba) {
  if (!w || !rgba || width <= 0 || height <= 0) return 0;
  return encodePng(width, height, rgba, W(w).mediaBuf) ? (int32_t)W(w).mediaBuf.size() : 0;
}

int32_t tej_encode_jpeg(TejWorld* w, int32_t width, int32_t height, const uint8_t* rgba, int32_t quality) {
  if (!w || !rgba || width <= 0 || height <= 0) return 0;
  return encodeJpeg(width, height, rgba, quality, W(w).mediaBuf) ? (int32_t)W(w).mediaBuf.size() : 0;
}

int32_t tej_media_copy(TejWorld* w, uint8_t* out, int32_t capacity) {
  if (!w || !out || capacity <= 0) return 0;
  int32_t n = std::min<int32_t>((int32_t)W(w).mediaBuf.size(), capacity);
  if (n > 0) std::memcpy(out, W(w).mediaBuf.data(), (size_t)n);
  return n;
}

int32_t tej_video_begin(TejWorld* w, int32_t width, int32_t height, int32_t fps, int32_t quality) {
  if (!w || width <= 0 || height <= 0) return 0;
  W(w).recorder.begin(width, height, fps, quality);
  return W(w).recorder.active ? 1 : 0;
}

int32_t tej_video_add_frame(TejWorld* w, const uint8_t* rgba) {
  if (!w || !rgba) return 0;
  return W(w).recorder.addFrame(rgba) ? 1 : 0;
}

int32_t tej_video_finish(TejWorld* w) {
  if (!w) return 0;
  return W(w).recorder.finish(W(w).mediaBuf) ? (int32_t)W(w).mediaBuf.size() : 0;
}


int32_t tej_gpu_init(TejWorld* w) { return w ? (W(w).gpu.init() ? 1 : 0) : 0; }
int32_t tej_gpu_is_available(TejWorld* w) { return (w && W(w).gpu.available) ? 1 : 0; }
int32_t tej_gpu_render(TejWorld* w, int32_t width, int32_t height, uint8_t* readbackRgba) {
  if (!w || width <= 0 || height <= 0) return 0;
  if (W(w).gpu.render(W(w), width, height, readbackRgba)) return 1;
  if (readbackRgba) renderSoftware(W(w), width, height, readbackRgba);
  return 0;
}
void tej_gpu_shutdown(TejWorld* w) { if (w) W(w).gpu.shutdown(); }

}  // extern "C"
