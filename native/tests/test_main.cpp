// Native tests for the tej3d core. Build and run: see native/README.md
#include <cstdlib>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "../include/tej3d.h"
#include "character.h"
#include "physics.h"
#include "jpeg.h"
#include "png.h"
#include "world.h"

struct TejWorld : tej::World {};  // same as in capi.cpp, so the tests can look inside

// Set TEJ3D_SKIP_PERF=1 for slow builds (sanitizers): speed checks are skipped.
static bool skip_perf() { return std::getenv("TEJ3D_SKIP_PERF") != nullptr; }

using namespace tej;
static int fails = 0;
#define CHECK(c, msg) do { if (!(c)) { printf("FAIL: %s\n", msg); fails++; } else printf("ok:   %s\n", msg); } while (0)

static BodyDesc ground() {
  BodyDesc g; g.mass = 0; g.half = {50, 0.5f, 50}; g.pos = {0, -0.5f, 0};
  return g;
}

static void physicsTests() {
  { PhysicsWorld w; w.createBody(ground());
    BodyDesc b; b.pos = {0, 3, 0}; int id = w.createBody(b);
    for (int i = 0; i < 240; i++) w.step(1 / 60.f);
    Body* bb = w.body(id);
    CHECK(std::fabs(bb->pos.y - 0.5f) < 0.02f, "box rests on ground at y=0.5");
    CHECK(bb->sleeping, "box falls asleep"); }
  { PhysicsWorld w; w.createBody(ground());
    int ids[4];
    for (int i = 0; i < 4; i++) { BodyDesc b; b.pos = {0.02f * i, 0.5f + 1.02f * i, 0}; ids[i] = w.createBody(b); }
    for (int i = 0; i < 600; i++) w.step(1 / 60.f);
    Body* top = w.body(ids[3]);
    CHECK(std::fabs(top->pos.y - 3.5f) < 0.15f && std::fabs(top->pos.x) < 0.3f, "4-box stack stays stacked"); }
  { PhysicsWorld w; BodyDesc g = ground(); g.restitution = 0.8f; w.createBody(g);
    BodyDesc s; s.shape = ShapeType::Sphere; s.half = {0.5f, 0, 0}; s.pos = {0, 5, 0}; s.restitution = 0.8f;
    int id = w.createBody(s);
    float peak = 0; bool hit = false;
    for (int i = 0; i < 200; i++) { w.step(1 / 60.f); float y = w.body(id)->pos.y; if (y < 0.6f) hit = true; if (hit) peak = std::max(peak, y); }
    CHECK(peak > 1.5f && peak < 4.5f, "sphere bounces with restitution"); }
  { PhysicsWorld w; w.createBody(ground());
    BodyDesc b; b.pos = {0, 0.5f, 0}; int id = w.createBody(b);
    w.body(id)->linVel = {8, 0, 0};
    for (int i = 0; i < 300; i++) w.step(1 / 60.f);
    CHECK(w.body(id)->pos.x > 5 && w.body(id)->pos.x < 9.5f && std::fabs(w.body(id)->linVel.x) < 0.1f, "friction stops a sliding box"); }
  { PhysicsWorld w; BodyDesc t; t.mass = 0; t.sensor = true; t.half = {2, 2, 2}; t.pos = {0, 2, 0};
    int tid = w.createBody(t);
    BodyDesc b; b.pos = {0, 6, 0}; w.createBody(b);
    bool began = false, ended = false;
    for (int i = 0; i < 200; i++) { w.step(1 / 60.f);
      for (auto& e : w.events()) if (e.sensor) { if (e.type == 0 && (e.a == tid || e.b == tid)) began = true; if (e.type == 1) ended = true; } }
    CHECK(began && ended, "trigger begin and end events"); }
  { PhysicsWorld w; int gid = w.createBody(ground()); RayHit h;
    bool r = w.raycast({3, 10, 3}, {0, -1, 0}, 100, ~0u, -1, h);
    CHECK(r && h.body == gid && std::fabs(h.t - 10) < 1e-3f && h.normal.y > 0.99f, "raycast hits ground"); }
}

static void animTests() {
  TejWorld* w = tej_world_create();
  int32_t parents[3] = {-1, 0, 1};
  float bind[30];
  for (int i = 0; i < 3; i++) {
    float* f = bind + i * 10;
    f[0] = 0; f[1] = i == 0 ? 0.f : 1.f; f[2] = 0; f[3] = f[4] = f[5] = 0; f[6] = 1; f[7] = f[8] = f[9] = 1;
  }
  int sk = tej_skeleton_create(w, 3, parents, bind);
  int clip = tej_clip_create(w, 1.0f, 3);
  float times[3] = {0, 0.5f, 1.0f};
  Q q1 = axisAngle(V3(0, 0, 1), 1.0f);
  float rot[12] = {0, 0, 0, 1, q1.x, q1.y, q1.z, q1.w, 0, 0, 0, 1};
  tej_clip_set_channel(w, clip, 1, 1, 3, times, rot);
  int an = tej_animator_create(w, sk);
  float m[16];
  tej_animator_joint_matrix(w, an, 2, m);
  CHECK(std::fabs(m[13] - 2.0f) < 1e-4f, "bind pose: joint 2 sits at y=2");
  tej_animator_play(w, an, clip, 0, 1.0f);
  tej_world_update(w, 0.5f);
  tej_animator_joint_matrix(w, an, 2, m);
  CHECK(std::fabs(m[12] + std::sin(1.0f)) < 1e-3f && std::fabs(m[13] - (1 + std::cos(1.0f))) < 1e-3f, "keyframes rotate the joint chain correctly");
  tej_world_update(w, 0.6f);
  CHECK(tej_animator_finished(w, an) == 1, "non looping clip reports finished");
  int idle = tej_clip_create(w, 1.0f, 3);
  tej_animator_play(w, an, clip, 1, 1.0f);
  tej_animator_crossfade(w, an, idle, 0.5f, 1, 1.0f);
  tej_world_update(w, 0.25f);
  tej_animator_joint_matrix(w, an, 2, m);
  CHECK(m[13] > 1.0f && m[13] < 2.0f, "crossfade blends two clips");
  tej_world_destroy(w);
}

static void sceneTest() {
  TejWorld* w = tej_world_create();
  TejBodyDesc g; std::memset(&g, 0, sizeof g);
  g.shape = 1; g.hx = 60; g.hy = 0.5f; g.hz = 60; g.py = -0.5f; g.qw = 1; g.friction = 0.8f; g.mask = ~0u;
  tej_body_create(w, &g);
  int gi = tej_instance_create(w, tej_mesh_plane(w, 60, 60, 1, 30));
  float id[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
  tej_instance_set_transform(w, gi, id);
  int boxMesh = tej_mesh_box(w, 0.5f, 0.5f, 0.5f);
  for (int i = 0; i < 5; i++) {
    TejBodyDesc b; std::memset(&b, 0, sizeof b);
    b.shape = 1; b.hx = b.hy = b.hz = 0.5f; b.mass = 10; b.px = 2.0f + 0.05f * i; b.py = 0.5f + 1.2f * i; b.pz = -2; b.qw = 1;
    b.friction = 0.6f; b.linearDamping = 0.01f; b.angularDamping = 0.05f; b.mask = ~0u; b.gravityScale = 1;
    int body = tej_body_create(w, &b);
    int inst = tej_instance_create(w, boxMesh);
    tej_instance_bind_body(w, inst, body, 1, 1, 1);
    tej_instance_set_color(w, inst, 0.9f, 0.3f + 0.12f * i, 0.2f, 1);
  }
  tej_light_create(w, 0, -0.4f, -1.0f, -0.5f, 1.0f, 0.95f, 0.85f, 1.0f, 0);
  for (int i = 0; i < 150; i++) tej_world_update(w, 1.0f / 60);
  tej_camera_set(w, 6.0f, 5.0f, 12.0f, 2.0f, 1.0f, -2.0f, 0.85f, 0.1f, 200);
  const int W_ = 320, H_ = 180;
  std::vector<uint8_t> img(W_ * H_ * 4);
  tej_render_software(w, W_, H_, img.data());
  int reddish = 0;  // the boxes are orange/red, the ground is white, the sky is blue
  for (int i = 0; i < W_ * H_; i++) {
    const uint8_t* p = &img[i * 4];
    if (p[0] > p[2] + 40) reddish++;
  }
  CHECK(reddish > 100, "software render draws the lit boxes");
  FILE* f = fopen("tej3d_demo.ppm", "wb");
  if (f) { fprintf(f, "P6\n%d %d\n255\n", W_, H_); for (int i = 0; i < W_ * H_; i++) fwrite(&img[i * 4], 1, 3, f); fclose(f); }
  tej_world_destroy(w);
}

static std::vector<uint8_t> readFile(const char* path) {
  std::vector<uint8_t> d;
  FILE* f = fopen(path, "rb");
  if (!f) return d;
  uint8_t buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, f)) > 0) d.insert(d.end(), buf, buf + n);
  fclose(f);
  return d;
}

static void modelTests(const char* path) {
  std::vector<uint8_t> glb = readFile(path);
  CHECK(!glb.empty(), "test_model.glb can be read (run from the native folder)");
  if (glb.empty()) return;
  TejWorld* w = tej_world_create();
  int n = tej_model_load_glb(w, glb.data(), (int)glb.size());
  CHECK(n == 6, "glb: base, top and four pillars give 6 parts");
  int pillars = 0;
  bool placed = false;
  char name[64];
  for (int i = 0; i < tej_model_part_count(w); i++) {
    tej_model_part_name(w, i, name, sizeof name);
    if (std::strncmp(name, "Pillar.", 7) == 0) {
      pillars++;
      float m[16];
      tej_model_part_matrix(w, i, m);
      if (std::strcmp(name, "Pillar.1") == 0 && std::fabs(m[12] + 0.95f) < 1e-4f && std::fabs(m[13] + 0.3f) < 1e-4f && std::fabs(m[14] - 1.3f) < 1e-4f) placed = true;
    }
  }
  CHECK(pillars == 4, "glb: four nodes are named Pillar.*");
  CHECK(placed, "glb: node transform of Pillar.1 is read correctly");
  CHECK(tej_model_part_instance(w, 0) >= 0 && tej_model_part_instance(w, 5) >= 0, "glb: every part has an instance");
  // broken input must fail with a reason, not crash
  uint8_t junk[40] = {1, 2, 3};
  CHECK(tej_model_load_glb(w, junk, sizeof junk) == -1, "glb: junk bytes are rejected");
  char err[128];
  tej_model_error(w, err, sizeof err);
  CHECK(std::strlen(err) > 0, "glb: a reason is given for the error");
  std::vector<uint8_t> cut(glb.begin(), glb.begin() + glb.size() / 2);
  CHECK(tej_model_load_glb(w, cut.data(), (int)cut.size()) == -1, "glb: a cut file is rejected");
  std::vector<uint8_t> bad = glb;
  for (size_t i = 100; i < 400 && i < bad.size(); i++) bad[i] = 0x7B;  // corrupt the JSON
  CHECK(tej_model_load_glb(w, bad.data(), (int)bad.size()) == -1, "glb: corrupt JSON is rejected");
  tej_world_destroy(w);
}

static int quadMesh(PhysicsWorld& w, float half) {
  float v[12] = {-half, 0, -half, half, 0, -half, half, 0, half, -half, 0, half};
  uint32_t idx[6] = {0, 2, 1, 0, 3, 2};
  return w.createTriMesh(v, 4, idx, 6);
}

static void meshColliderTests() {
  { PhysicsWorld w; BodyDesc g; g.shape = ShapeType::Mesh; g.mass = 0; g.triMesh = quadMesh(w, 20); w.createBody(g);
    BodyDesc b; b.pos = {0, 3, 0}; int id = w.createBody(b);
    for (int i = 0; i < 240; i++) w.step(1 / 60.f);
    CHECK(std::fabs(w.body(id)->pos.y - 0.5f) < 0.08f, "box rests on a mesh floor");
    CHECK(w.body(id)->sleeping, "box on a mesh floor falls asleep"); }
  { PhysicsWorld w; BodyDesc g; g.shape = ShapeType::Mesh; g.mass = 0; g.triMesh = quadMesh(w, 30);
    g.rot = axisAngle(V3(0, 0, 1), 0.35f); w.createBody(g);   // a slope rising toward +X
    BodyDesc s; s.shape = ShapeType::Sphere; s.half = {0.5f, 0, 0}; s.pos = {0, 2, 0}; s.friction = 0.3f;
    int id = w.createBody(s);
    for (int i = 0; i < 150; i++) w.step(1 / 60.f);
    const Body* b = w.body(id);
    float dist = -std::sin(0.35f) * b->pos.x + std::cos(0.35f) * b->pos.y;   // distance above the slope plane
    CHECK(dist > 0.4f && dist < 0.65f, "sphere stays on top of a rotated mesh slope (no tunneling)");
    CHECK(b->linVel.x < -1.0f, "sphere rolls downhill on the mesh slope"); }
  { PhysicsWorld w; BodyDesc g; g.shape = ShapeType::Mesh; g.mass = 0; g.triMesh = quadMesh(w, 20); int gid = w.createBody(g);
    RayHit h;
    bool r = w.raycast({2, 5, 3}, {0, -1, 0}, 100, ~0u, -1, h);
    CHECK(r && h.body == gid && std::fabs(h.t - 5) < 1e-3f && h.normal.y > 0.99f, "raycast hits a triangle mesh"); }
  { PhysicsWorld w; BodyDesc g; g.shape = ShapeType::Mesh; g.mass = 0; g.triMesh = quadMesh(w, 20); w.createBody(g);
    BodyDesc b; b.pos = {0, 3, 0}; b.half = {0.4f, 0.4f, 0.4f};
    int n = 0;
    for (int x = 0; x < 6; x++) for (int y = 0; y < 6; y++) for (int z = 0; z < 6; z++) { b.pos = {x * 0.9f - 2, 0.5f + y * 0.9f, z * 0.9f - 2}; w.createBody(b); n++; }
    auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < 60; i++) w.step(1 / 60.f);
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count() / 60;
    printf("  %d boxes on a mesh floor: %.2f ms per step\n", n, ms);
    CHECK(skip_perf() || ms < 80.0, "216 boxes on a mesh floor step in under 80 ms (this machine)"); }
}

static void textureTests(const char* dir) {
  auto path = [&](const char* name) { return std::string(dir) + "/" + name; };
  int w = 0, h = 0; std::vector<uint8_t> px; std::string err;
  std::vector<uint8_t> f = readFile(path("checker.png").c_str());
  bool ok = !f.empty() && decodePng(f.data(), f.size(), w, h, px, err);
  CHECK(ok && w == 16 && h == 16, "png: RGB image with all filters decodes (16x16)");
  if (ok) {
    CHECK(px[0] == 220 && px[1] == 30 && px[2] == 30, "png: first cell is red");
    size_t i = (size_t)(5 * 16 + 4) * 4;  // row 5 uses filter 0 again; cell (1,1) is red, (x=4,y=0) is blue
    (void)i;
    size_t b = (size_t)(0 * 16 + 4) * 4;
    CHECK(px[b] == 30 && px[b + 2] == 220, "png: next cell is blue");
    size_t last = (size_t)(15 * 16 + 15) * 4;
    CHECK(px[last] == 220 && px[last + 2] == 30, "png: last pixel is right after the paeth/sub/up/average rows");
  }
  f = readFile(path("tiny_rgba.png").c_str());
  ok = !f.empty() && decodePng(f.data(), f.size(), w, h, px, err);
  CHECK(ok && w == 4 && h == 4 && px[(size_t)(2 * 4 + 3) * 4 + 0] == 180 && px[(size_t)(2 * 4 + 3) * 4 + 3] == 225, "png: RGBA with stored zlib blocks");
  f = readFile(path("gradient64.png").c_str());
  ok = !f.empty() && decodePng(f.data(), f.size(), w, h, px, err);
  bool grad = ok && w == 64 && h == 64;
  for (int y = 0; grad && y < 64; y += 7)
    for (int x = 0; x < 64; x += 5) {
      const uint8_t* p = &px[((size_t)y * 64 + x) * 4];
      if (p[0] != x * 4 || p[1] != y * 4 || p[2] != (x * y) % 256) grad = false;
    }
  CHECK(grad, "png: 64x64 image with compressed (Huffman) data decodes exactly");
  std::vector<uint8_t> bad = readFile(path("checker.png").c_str());
  bad.resize(bad.size() / 2);
  CHECK(!decodePng(bad.data(), bad.size(), w, h, px, err) && !err.empty(), "png: a cut file is rejected with a reason");
  bad[40] ^= 0xFF; bad.resize(bad.size());
  uint8_t junk[64] = {1, 2, 3};
  CHECK(!decodePng(junk, sizeof junk, w, h, px, err), "png: junk is rejected");

  // a model with a texture inside
  std::vector<uint8_t> glb = readFile(path("test_textured.glb").c_str());
  TejWorld* wd = tej_world_create();
  int n = tej_model_load_glb(wd, glb.data(), (int)glb.size());
  CHECK(n == 1, "glb: textured quad loads");
  World& world = *reinterpret_cast<World*>(wd);
  CHECK(!world.textures.empty() && world.textures[0].w == 16 && world.textures[0].levels() == 5, "glb: PNG inside the file became a texture with 5 mip levels");
  CHECK(world.instances.back().texture == 0, "glb: the instance uses that texture");
  tej_light_create(wd, 0, 0.0f, 0.0f, -1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 0);
  tej_camera_set(wd, 0, 0, 3.0f, 0, 0, 0, 0.9f, 0.1f, 50);
  const int W_ = 128, H_ = 128;
  std::vector<uint8_t> img(W_ * H_ * 4);
  tej_render_software(wd, W_, H_, img.data());
  int reds = 0, blues = 0;
  for (int i = 0; i < W_ * H_; i++) {
    const uint8_t* p = &img[i * 4];
    if (p[0] > p[2] + 60 && p[0] > 100) reds++;
    if (p[2] > p[0] + 60 && p[2] > 100) blues++;
  }
  CHECK(reds > 300 && blues > 300, "render: the quad shows both red and blue checker cells");
  tej_world_destroy(wd);
}

static void perfTest() {
  PhysicsWorld w; w.createBody(ground());
  int n = 0;
  for (int x = 0; x < 12; x++) for (int y = 0; y < 12; y++) for (int z = 0; z < 8; z++) {
    BodyDesc b; b.half = {0.4f, 0.4f, 0.4f}; b.pos = {x * 1.0f - 6, 0.5f + y * 0.95f, z * 1.0f - 4}; w.createBody(b); n++;
  }
  auto t0 = std::chrono::steady_clock::now();
  for (int i = 0; i < 60; i++) w.step(1 / 60.f);
  double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count() / 60;
  printf("  %d boxes: %.2f ms per step\n", n, ms);
  CHECK(skip_perf() || ms < 60.0, "physics: 1152 stacked boxes step in under 60 ms (this machine)");
}

// ---------------------------------------------------------------- character controller

// One frame of a simple game loop for the controller: gravity, walking, jumping.
static void charFrame(PhysicsWorld& w, Character& c, float& vy, V3 walk, bool snap = true, float dt = 1 / 60.f) {
  vy -= 20.0f * dt;
  if (c.grounded && vy < 0) vy = -1.0f;
  c.move(w, V3(walk.x * dt, vy * dt, walk.z * dt), snap);
  if (c.grounded && vy < 0) vy = 0;
  if (c.hitCeiling && vy > 0) vy = 0;
}
static void charRun(PhysicsWorld& w, Character& c, float& vy, V3 walk, float seconds, bool snap = true) {
  int n = (int)(seconds * 60);
  for (int i = 0; i < n; i++) charFrame(w, c, vy, walk, snap);
}
static Character makeChar(float x = 0, float y = 0.5f, float z = 0) {
  Character c; c.alive = true; c.pos = {x, y, z};
  return c;
}
static BodyDesc wallBox(V3 center, V3 half) {
  BodyDesc b; b.mass = 0; b.half = half; b.pos = center; return b;
}
static Q rotZ(float a) { return Q(0, 0, std::sin(a / 2), std::cos(a / 2)); }

static void characterTests() {
  { PhysicsWorld w; w.createBody(ground()); Character c = makeChar(0, 2.0f, 0); float vy = 0;
    charRun(w, c, vy, {0, 0, 0}, 1.5f);
    CHECK(c.grounded && std::fabs(c.pos.y) < 0.03f, "character falls and stands on the ground");
    CHECK(std::fabs(c.pos.x) < 1e-3f && std::fabs(c.pos.z) < 1e-3f, "character standing does not drift");
    charRun(w, c, vy, {4, 0, 0}, 1.0f);
    CHECK(std::fabs(c.pos.x - 4.0f) < 0.2f && c.grounded, "character walks at the speed it is told"); }
  { PhysicsWorld w; w.createBody(ground()); w.createBody(wallBox({3, 2, 0}, {0.5f, 2, 20})); Character c = makeChar(); float vy = 0;
    charRun(w, c, vy, {4, 0, 0}, 3.0f);
    CHECK(c.pos.x > 2.0f && c.pos.x < 2.2f, "character stops at a wall (radius 0.4)");
    CHECK(c.hitWall, "character reports it touched a wall");
    float z0 = c.pos.z; charRun(w, c, vy, {4, 0, 4}, 1.0f);
    CHECK(c.pos.z > z0 + 2.5f && c.pos.x < 2.2f, "character slides along a wall instead of sticking"); }
  { PhysicsWorld w; w.createBody(ground()); w.createBody(wallBox({7, 0.15f, 0}, {5.0f, 0.15f, 20})); Character c = makeChar(); float vy = 0;
    charRun(w, c, vy, {3, 0, 0}, 2.0f);
    CHECK(c.pos.x > 3.5f && std::fabs(c.pos.y - 0.3f) < 0.05f && c.grounded, "character steps up a 0.3 m step"); }
  { PhysicsWorld w; w.createBody(ground()); w.createBody(wallBox({3, 0.3f, 0}, {1.0f, 0.3f, 20})); Character c = makeChar(); float vy = 0;
    charRun(w, c, vy, {3, 0, 0}, 2.0f);
    CHECK(c.pos.x < 2.2f && c.pos.y < 0.1f, "character does not climb a 0.6 m wall"); }
  { PhysicsWorld w; w.createBody(ground()); w.createBody(wallBox({0, 2.2f + 0.5f, 0}, {20, 0.5f, 20})); Character c = makeChar(); float vy = 0;
    charRun(w, c, vy, {0, 0, 0}, 0.5f);
    bool bumped = false; vy = 12.0f;
    for (int i = 0; i < 30; i++) { charFrame(w, c, vy, {0, 0, 0}, false); if (c.hitCeiling) bumped = true; }
    CHECK(bumped && c.pos.y + 1.8f <= 2.2f + 0.03f, "character hits its head on a ceiling and stays below it"); }
  { PhysicsWorld w; w.createBody(ground()); Character c = makeChar(); float vy = 0;
    charRun(w, c, vy, {0, 0, 0}, 0.5f);
    vy = 7.0f; float top = 0; bool leftGround = false;
    for (int i = 0; i < 120; i++) { charFrame(w, c, vy, {0, 0, 0}, !(vy > 0)); top = std::max(top, c.pos.y); if (!c.grounded) leftGround = true; }
    CHECK(leftGround && top > 0.9f && top < 1.4f, "jump goes up about v*v/2g (1.2 m)");
    CHECK(c.grounded && std::fabs(c.pos.y) < 0.03f, "character lands again"); }
  { PhysicsWorld w; w.createBody(ground());
    BodyDesc s = wallBox({0, 20, 0}, {40, 0.5f, 40}); s.rot = rotZ(0.52f); s.pos = {0, 20 - 0.5f, 0};   // placeholder, replaced below
    PhysicsWorld w2; BodyDesc r = wallBox({0, -0.5f, 0}, {30, 0.5f, 10}); r.rot = rotZ(0.52f);          // 30 degree ramp
    w2.createBody(r); Character c = makeChar(0, 2.0f, 0); float vy = 0;
    charRun(w2, c, vy, {0, 0, 0}, 1.0f); float y0 = c.pos.y;
    charRun(w2, c, vy, {3, 0, 0}, 2.0f);
    CHECK(c.grounded && c.pos.y > y0 + 2.0f, "character walks up a 30 degree ramp"); }
  { PhysicsWorld w; BodyDesc r = wallBox({0, -0.5f, 0}, {30, 0.5f, 10}); r.rot = rotZ(1.15f);           // 66 degree ramp
    w.createBody(r); Character c = makeChar(-1.0f, 3.0f, 0); float vy = 0;
    charRun(w, c, vy, {0, 0, 0}, 1.5f); float y0 = c.pos.y;
    charRun(w, c, vy, {3, 0, 0}, 2.0f);
    CHECK(c.pos.y < y0 + 1.0f, "character does not walk up a 66 degree ramp (slope limit)"); }
  { PhysicsWorld w; w.createBody(ground()); w.createBody(wallBox({-2.5f, 0.15f, 0}, {3.0f, 0.15f, 20}));   // platform 0.3 high, edge at x = 0.5
    Character c = makeChar(-3.0f, 0.3f, 0); float vy = 0;
    charRun(w, c, vy, {0, 0, 0}, 0.3f);
    int airFrames = 0;
    for (int i = 0; i < 120; i++) { charFrame(w, c, vy, {2, 0, 0}, true); if (!c.grounded) airFrames++; }
    CHECK(c.pos.x > 0.8f && std::fabs(c.pos.y) < 0.05f, "character walks off a 0.3 m ledge down to the floor");
    CHECK(airFrames == 0, "ground snap keeps the character grounded going down a small ledge"); }
  { PhysicsWorld w; BodyDesc g; g.shape = ShapeType::Mesh; g.mass = 0; g.triMesh = quadMesh(w, 40); w.createBody(g);
    Character c = makeChar(0, 2.0f, 0); float vy = 0;
    charRun(w, c, vy, {2, 0, 2}, 2.0f);
    CHECK(c.grounded && std::fabs(c.pos.y) < 0.05f && c.pos.x > 3.0f, "character walks on a triangle mesh floor"); }
  { PhysicsWorld w; w.createBody(ground()); BodyDesc t = wallBox({3, 1, 0}, {0.5f, 1, 5}); t.sensor = true; w.createBody(t);
    Character c = makeChar(); float vy = 0;
    charRun(w, c, vy, {4, 0, 0}, 2.0f);
    CHECK(c.pos.x > 4.5f, "character walks through a trigger (sensor)"); }
  { PhysicsWorld w; w.createBody(ground()); BodyDesc b = wallBox({3, 1, 0}, {0.5f, 1, 5}); b.layer = 5; w.createBody(b);
    Character c = makeChar(); c.d.mask = ~(1u << 5); float vy = 0;
    charRun(w, c, vy, {4, 0, 0}, 2.0f);
    CHECK(c.pos.x > 4.5f, "character ignores layers that are not in its mask"); }
  { PhysicsWorld w; w.createBody(ground()); int wallId = w.createBody(wallBox({3, 1, 0}, {0.5f, 1, 5}));
    Character c = makeChar(); c.d.ignoreBody = wallId; float vy = 0;
    charRun(w, c, vy, {4, 0, 0}, 2.0f);
    CHECK(c.pos.x > 4.5f, "character can ignore one body"); }
  { PhysicsWorld w; w.createBody(ground()); Character c = makeChar(); float vy = 0;
    for (int i = 0; i < 200; i++) charFrame(w, c, vy, {0, 0, 0});
    c.move(w, V3(50, 0, 0), true);   // a huge move in one call must not tunnel through a thin wall
    PhysicsWorld w3; w3.createBody(ground()); w3.createBody(wallBox({5, 1, 0}, {0.05f, 1, 5}));
    Character c3 = makeChar(); float vy3 = 0;
    for (int i = 0; i < 30; i++) charFrame(w3, c3, vy3, {0, 0, 0});
    c3.move(w3, V3(20, 0, 0), true);
    CHECK(c3.pos.x < 5.0f, "a huge single move does not tunnel through a thin wall"); }
  if (!skip_perf()) {
    PhysicsWorld w; w.createBody(ground());
    BodyDesc b; b.half = {0.4f, 0.4f, 0.4f};
    for (int x = 0; x < 12; x++) for (int y = 0; y < 8; y++) for (int z = 0; z < 12; z++) { b.pos = {x * 1.0f - 6 + 20, 0.5f + y * 0.9f, z * 1.0f - 6}; w.createBody(b); }
    Character c = makeChar(0, 0.5f, 0); float vy = 0;
    auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < 300; i++) charFrame(w, c, vy, {3, 0, 0});
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count() / 300;
    printf("  character move with %d bodies: %.3f ms per frame\n", w.bodyCount(), ms);
    CHECK(ms < 2.0, "character move stays under 2 ms with ~1100 bodies in the world"); }
}

// ---------------------------------------------------------------- shadows

static float pixelLum(const std::vector<uint8_t>& img, int W_, int H_, const M4& vp, V3 p) {
  float cx = vp.at(0, 0) * p.x + vp.at(0, 1) * p.y + vp.at(0, 2) * p.z + vp.at(0, 3);
  float cy = vp.at(1, 0) * p.x + vp.at(1, 1) * p.y + vp.at(1, 2) * p.z + vp.at(1, 3);
  float cw = vp.at(3, 0) * p.x + vp.at(3, 1) * p.y + vp.at(3, 2) * p.z + vp.at(3, 3);
  int px = (int)((cx / cw * 0.5f + 0.5f) * W_), py = (int)((1.0f - (cy / cw * 0.5f + 0.5f)) * H_);
  float sum = 0; int n = 0;
  for (int dy = -2; dy <= 2; dy++) for (int dx = -2; dx <= 2; dx++) {
    int x = px + dx, y = py + dy;
    if (x < 0 || y < 0 || x >= W_ || y >= H_) continue;
    const uint8_t* q = &img[(y * W_ + x) * 4];
    sum += (q[0] + q[1] + q[2]) / 3.0f; n++;
  }
  return n ? sum / n : -1;
}

static void shadowTests() {
  const int W_ = 320, H_ = 180;
  auto render = [&](bool shadows, bool cast, bool receive, float strength, double* ms, std::vector<uint8_t>& img) {
    TejWorld* w = tej_world_create();
    int ground = tej_instance_create(w, tej_mesh_plane(w, 60, 60, 1, 30));
    float id[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
    tej_instance_set_transform(w, ground, id);
    tej_instance_set_shadow(w, ground, receive ? 2 : 0);
    int cube = tej_instance_create(w, tej_mesh_box(w, 1, 1, 1));
    float m[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 4,1.5f,0,1};
    tej_instance_set_transform(w, cube, m);
    tej_instance_set_shadow(w, cube, (cast ? 1 : 0) | 2);
    tej_light_create(w, 0, -1.0f, -1.0f, 0.0f, 1, 1, 1, 1.0f, 0);   // sun travels towards -x and down
    tej_camera_set(w, 0, 9, 9, 0, 0, 0, 0.9f, 0.1f, 200);
    tej_env_set_shadows(w, shadows ? 1 : 0, 1024, 40, strength);
    img.assign(W_ * H_ * 4, 0);
    auto t0 = std::chrono::steady_clock::now();
    tej_render_software(w, W_, H_, img.data());
    *ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    tej_world_destroy(w);
  };
  M4 vp = perspective(0.9f, (float)W_ / H_, 0.1f, 200) * lookAt(V3(0, 9, 9), V3(0, 0, 0), V3(0, 1, 0));
  V3 inShadow(2.5f, 0, 0), inLight(-3, 0, 0);   // the cube at x = 4, y = 1.5 throws its shadow towards -x
  std::vector<uint8_t> img;
  double ms = 0;

  render(true, true, true, 1.0f, &ms, img);
  float s = pixelLum(img, W_, H_, vp, inShadow), l = pixelLum(img, W_, H_, vp, inLight);
  printf("  shadow render: %.1f ms (shadowed %.0f, lit %.0f)\n", ms, s, l);
  CHECK(l > 0 && s >= 0 && s < l * 0.7f, "shadow: ground under the cube's shadow is darker than lit ground");
  { FILE* f = fopen("tej3d_shadow.ppm", "wb");
    if (f) { fprintf(f, "P6\n%d %d\n255\n", W_, H_); for (int i = 0; i < W_ * H_; i++) fwrite(&img[i * 4], 1, 3, f); fclose(f); } }

  render(false, true, true, 1.0f, &ms, img);
  float s0 = pixelLum(img, W_, H_, vp, inShadow), l0 = pixelLum(img, W_, H_, vp, inLight);
  CHECK(std::fabs(s0 - l0) < l0 * 0.15f, "shadow: with shadows off both places are equally bright");

  render(true, false, true, 1.0f, &ms, img);
  float s1 = pixelLum(img, W_, H_, vp, inShadow), l1 = pixelLum(img, W_, H_, vp, inLight);
  CHECK(std::fabs(s1 - l1) < l1 * 0.15f, "shadow: an object with castShadow off throws no shadow");

  render(true, true, false, 1.0f, &ms, img);
  float s2 = pixelLum(img, W_, H_, vp, inShadow), l2 = pixelLum(img, W_, H_, vp, inLight);
  CHECK(std::fabs(s2 - l2) < l2 * 0.15f, "shadow: an object with receiveShadow off stays lit");

  render(true, true, true, 0.5f, &ms, img);
  float s3 = pixelLum(img, W_, H_, vp, inShadow), l3 = pixelLum(img, W_, H_, vp, inLight);
  CHECK(s3 > s && s3 < l3 * 0.95f, "shadow: strength 0.5 gives a lighter shadow");

  render(true, true, true, 1.0f, &ms, img);
  // The sun's own side of the cube must not be speckled by its own shadow (no acne): the lit ground far away is flat.
  float a = pixelLum(img, W_, H_, vp, V3(-6, 0, 3)), b = pixelLum(img, W_, H_, vp, V3(-6, 0, -3));
  CHECK(std::fabs(a - b) < l * 0.1f, "shadow: far lit ground has no self shadow acne");
  if (!skip_perf()) CHECK(ms < 400.0, "shadow: a 320x180 frame with a 1024 shadow map renders in under 400 ms");
}

// ---------------------------------------------------------------- skinned models

static void skinnedModelTests(const char* path) {
  std::vector<uint8_t> glb = readFile(path);
  CHECK(!glb.empty(), "test_skinned.glb can be read");
  if (glb.empty()) return;
  TejWorld* w = tej_world_create();
  int n = tej_model_load_glb(w, glb.data(), (int)glb.size());
  char warn[512] = {0};
  tej_model_warning(w, warn, sizeof warn);
  CHECK(n == 1, "skinned glb: one piece");
  CHECK(warn[0] == 0, "skinned glb: loads without warnings (inverse bind matrices agree with the bones)");
  int sk = tej_model_part_skeleton(w, 0);
  CHECK(sk >= 0 && tej_skeleton_joint_count(w, sk) == 3, "skinned glb: the piece has a skeleton with 3 bones");
  CHECK(tej_model_clip_count(w) == 2, "skinned glb: two animations");
  char name[64];
  tej_model_clip_name(w, 0, name, sizeof name);
  CHECK(std::strcmp(name, "Bend") == 0, "skinned glb: first animation is Bend");
  tej_model_clip_name(w, 1, name, sizeof name);
  CHECK(std::strcmp(name, "Hop") == 0, "skinned glb: second animation is Hop");
  int bend = tej_model_clip_id(w, 0), hop = tej_model_clip_id(w, 1);
  CHECK(tej_model_clip_skeleton(w, 0) == sk && std::fabs(tej_clip_duration(w, bend) - 1.0f) < 1e-5f, "skinned glb: clip belongs to the skeleton and lasts 1 s");

  char bone[32];
  tej_skeleton_joint_name(w, sk, 0, bone, sizeof bone);
  CHECK(std::strcmp(bone, "Root") == 0, "skinned glb: bone names are kept (joint 0 is Root)");
  tej_skeleton_joint_name(w, sk, 2, bone, sizeof bone);
  CHECK(std::strcmp(bone, "Tip") == 0, "skinned glb: bone names follow the reordering (joint 2 is Tip)");

  float pm[16];
  tej_model_part_matrix(w, 0, pm);
  CHECK(std::fabs(pm[12] - 1.0f) < 1e-4f && std::fabs(pm[13]) < 1e-4f && std::fabs(pm[14]) < 1e-4f,
        "skinned glb: the piece sits in the armature space, the mesh node's own transform is ignored");

  tej::World& W_ = *w;
  const tej::Mesh& mesh = W_.meshes[tej_model_part_mesh(w, 0)];
  CHECK(mesh.skinned() && mesh.vertexCount() == 20, "skinned glb: mesh has bone data");
  bool weightsOk = true, jointsOk = true;
  for (int i = 0; i < mesh.vertexCount(); i++) {
    float sum = 0;
    for (int k = 0; k < 4; k++) { sum += mesh.weights[i * 4 + k]; if (mesh.weights[i * 4 + k] > 0 && mesh.joints[i * 4 + k] > 2) jointsOk = false; }
    if (std::fabs(sum - 1.0f) > 1e-4f) weightsOk = false;
  }
  CHECK(weightsOk && jointsOk, "skinned glb: weights add up to 1 and joint numbers are in range");
  // vertices are moved into the armature space: the top ring is at y = 2, x and z = +-0.1
  float topY = -1e9f, topX = 0;
  for (int i = 0; i < mesh.vertexCount(); i++) if (mesh.verts[i * 8 + 1] > topY) { topY = mesh.verts[i * 8 + 1]; topX = std::fabs(mesh.verts[i * 8]); }
  CHECK(std::fabs(topY - 2.0f) < 1e-4f && std::fabs(topX - 0.1f) < 1e-4f, "skinned glb: vertices are in the skeleton's own space");

  int an = tej_animator_create(w, sk);
  tej_instance_bind_animator(w, tej_model_part_instance(w, 0), an);
  auto jointPos = [&](int j, float* o) { float m[16]; tej_animator_joint_matrix(w, an, j, m); o[0] = m[12]; o[1] = m[13]; o[2] = m[14]; };
  float p[3];
  tej_world_update(w, 0.0f);
  jointPos(0, p); CHECK(std::fabs(p[1]) < 1e-4f, "skinned glb: bones are in parent first order (Root is joint 0)");
  jointPos(1, p); CHECK(std::fabs(p[1] - 1.0f) < 1e-4f, "skinned glb: Mid starts at y = 1");
  jointPos(2, p); CHECK(std::fabs(p[1] - 2.0f) < 1e-4f, "skinned glb: Tip starts at y = 2");

  // Bind pose: every vertex stays where it is.
  auto skinned = [&](int vi, float* o) {
    const std::vector<float>& skin = W_.animators[an].skin;
    tej::V3 pv(mesh.verts[vi * 8], mesh.verts[vi * 8 + 1], mesh.verts[vi * 8 + 2]), acc;
    for (int k = 0; k < 4; k++) {
      float wt = mesh.weights[vi * 4 + k];
      if (wt <= 0) continue;
      tej::M4 m;
      std::memcpy(m.m, &skin[mesh.joints[vi * 4 + k] * 16], 64);
      acc = acc + tej::transformPoint(m, pv) * wt;
    }
    o[0] = acc.x; o[1] = acc.y; o[2] = acc.z;
  };
  float maxMove = 0;
  for (int i = 0; i < mesh.vertexCount(); i++) {
    float q[3]; skinned(i, q);
    for (int k = 0; k < 3; k++) maxMove = std::fmax(maxMove, std::fabs(q[k] - mesh.verts[i * 8 + k]));
  }
  CHECK(maxMove < 1e-4f, "skinned glb: with no animation the skinned vertices equal the bind pose");

  // Bend: Mid turns 90 degrees about Z, so Tip goes to (-1, 1, 0).
  tej_animator_play(w, an, bend, 0, 1.0f);
  tej_world_update(w, 0.5f);
  jointPos(2, p);
  CHECK(std::fabs(p[0] + 0.70710678f) < 1e-3f && std::fabs(p[1] - 1.70710678f) < 1e-3f, "skinned glb: halfway through Bend the tip is at (-0.71, 1.71)");
  tej_world_update(w, 0.5f);
  jointPos(2, p);
  CHECK(std::fabs(p[0] + 1.0f) < 1e-3f && std::fabs(p[1] - 1.0f) < 1e-3f && std::fabs(p[2]) < 1e-3f, "skinned glb: at the end of Bend the tip is at (-1, 1, 0)");
  CHECK(tej_animator_finished(w, an) == 1, "skinned glb: a clip that is not looping reports it finished");
  // a vertex on the top ring (weight 1 on Tip) follows the Tip bone
  int top = -1;
  for (int i = 0; i < mesh.vertexCount(); i++) if (mesh.verts[i * 8 + 1] > 1.99f && mesh.verts[i * 8] > 0 && mesh.verts[i * 8 + 2] > 0) top = i;
  float q[3]; skinned(top, q);
  CHECK(std::fabs(q[0] + 1.0f) < 1e-3f && std::fabs(q[1] - 1.1f) < 1e-3f && std::fabs(q[2] - 0.1f) < 1e-3f, "skinned glb: a tip vertex is carried to (-1, 1.1, 0.1)");
  // a vertex in the lower ring (weight 1 on Root) does not move
  int low = -1;
  for (int i = 0; i < mesh.vertexCount(); i++) if (mesh.verts[i * 8 + 1] < 0.01f) low = i;
  float lo[3]; skinned(low, lo);
  CHECK(std::fabs(lo[0] - mesh.verts[low * 8]) < 1e-4f && std::fabs(lo[1]) < 1e-4f, "skinned glb: a root vertex stays");

  // Hop: STEP interpolation holds the value until the next key.
  tej_animator_play(w, an, hop, 0, 1.0f);
  tej_world_update(w, 0.25f); jointPos(0, p);
  CHECK(std::fabs(p[1]) < 1e-3f, "skinned glb: STEP holds the first value before the next key");
  tej_world_update(w, 0.26f); jointPos(0, p);
  CHECK(std::fabs(p[1] - 2.0f) < 1e-3f, "skinned glb: STEP jumps at the key");
  tej_world_update(w, 0.4f); jointPos(0, p);
  CHECK(std::fabs(p[1] - 2.0f) < 1e-3f, "skinned glb: STEP keeps the value until the next key");
  tej_world_update(w, 0.2f); jointPos(0, p);
  CHECK(std::fabs(p[1]) < 1e-3f, "skinned glb: STEP ends on the last key");

  // Crossfade mixes two clips.
  tej_animator_play(w, an, bend, 1, 1.0f);
  tej_world_update(w, 0.5f);
  tej_animator_crossfade(w, an, hop, 1.0f, 1, 1.0f);
  tej_world_update(w, 0.25f);
  jointPos(2, p);
  // Bend alone would be at -sin(67.5 deg) = -0.92 now; the blend is less bent but not straight.
  CHECK(p[0] < -0.3f && p[0] > -0.92f, "skinned glb: during a crossfade the pose is between the two clips");

  // Drawing: the bent arm looks different from the straight one.
  const int W2 = 160, H2 = 120;
  std::vector<uint8_t> a(W2 * H2 * 4), b(W2 * H2 * 4);
  tej_light_create(w, 0, -0.3f, -1.0f, -0.4f, 1, 1, 1, 1.0f, 0);
  tej_camera_set(w, 0, 1.5f, 6, 0, 1.5f, 0, 0.9f, 0.1f, 50);
  tej_animator_play(w, an, bend, 0, 1.0f);
  tej_world_update(w, 0.0f);
  tej_render_software(w, W2, H2, a.data());
  tej_world_update(w, 1.0f);
  tej_render_software(w, W2, H2, b.data());
  int diff = 0;
  for (int i = 0; i < W2 * H2; i++) if (std::abs(a[i * 4] - b[i * 4]) + std::abs(a[i * 4 + 1] - b[i * 4 + 1]) + std::abs(a[i * 4 + 2] - b[i * 4 + 2]) > 30) diff++;
  CHECK(diff > 150, "skinned glb: the renderer draws the bent arm differently from the straight one");
  tej_world_destroy(w);

  // A model without bones has no skeleton and no animations.
  TejWorld* w2 = tej_world_create();
  std::vector<uint8_t> plain = readFile("tests/data/test_model.glb");
  if (!plain.empty()) {
    tej_model_load_glb(w2, plain.data(), (int)plain.size());
    CHECK(tej_model_clip_count(w2) == 0 && tej_model_part_skeleton(w2, 0) == -1, "plain glb: no skeleton and no animations");
  }
  tej_world_destroy(w2);
}

// Damaged model files must give an error or a partial result, never a crash.
static void modelFuzzTests(const char* skinnedPath, const char* plainPath) {
  const char* paths[2] = {skinnedPath, plainPath};
  unsigned seed = 12345;
  auto rnd = [&]() { seed = seed * 1664525u + 1013904223u; return seed >> 8; };
  int runs = 0;
  for (const char* pth : paths) {
    std::vector<uint8_t> base = readFile(pth);
    if (base.empty()) continue;
    for (int iter = 0; iter < 400; iter++) {
      std::vector<uint8_t> f = base;
      int kind = iter % 4;
      if (kind == 0) f.resize(rnd() % f.size());                                   // cut short
      else if (kind == 1) { for (int k = 0; k < 8; k++) f[rnd() % f.size()] = (uint8_t)rnd(); }   // random bytes
      else if (kind == 2) { size_t at = 20 + rnd() % (f.size() - 20); for (int k = 0; k < 4 && at + k < f.size(); k++) f[at + k] = 0xFF; }   // huge numbers
      else { size_t at = 20 + rnd() % std::min<size_t>(f.size() - 20, 900); f[at] ^= (uint8_t)(1u << (rnd() % 8)); }   // one flipped bit in the JSON
      TejWorld* w = tej_world_create();
      int n = tej_model_load_glb(w, f.data(), (int)f.size());
      if (n > 0) {   // if something loaded, using it must be safe too
        int sk = tej_model_part_skeleton(w, 0);
        if (sk >= 0) {
          int an = tej_animator_create(w, sk);
          if (tej_model_clip_count(w) > 0) tej_animator_play(w, an, tej_model_clip_id(w, 0), 1, 1.0f);
          tej_instance_bind_animator(w, tej_model_part_instance(w, 0), an);
          tej_world_update(w, 0.3f);
          std::vector<uint8_t> img(64 * 48 * 4);
          tej_render_software(w, 64, 48, img.data());
        }
      }
      tej_world_destroy(w);
      runs++;
    }
  }
  CHECK(runs >= 400, "model loader survives 800 damaged files without crashing");
}

// ---------------------------------------------------------------- picture effects

static void postTests() {
  const int W_ = 200, H_ = 120;
  auto render = [&](bool post, float exposure, int tonemap, float contrast, float saturation, float vignette, float bloom, std::vector<uint8_t>& img) {
    TejWorld* w = tej_world_create();
    float id[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
    int ground = tej_instance_create(w, tej_mesh_plane(w, 60, 60, 1, 30));
    tej_instance_set_transform(w, ground, id);
    tej_instance_set_color(w, ground, 0.5f, 0.5f, 0.5f, 1);
    int red = tej_instance_create(w, tej_mesh_box(w, 0.5f, 0.5f, 0.5f));      // a red cube on the left
    float mr[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, -2.0f, 0.5f, 0, 1};
    tej_instance_set_transform(w, red, mr);
    tej_instance_set_color(w, red, 0.9f, 0.1f, 0.1f, 1);
    int lamp = tej_instance_create(w, tej_mesh_box(w, 0.4f, 0.4f, 0.4f));     // a bright lamp on the right
    float ml[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 2.0f, 1.0f, 0, 1};
    tej_instance_set_transform(w, lamp, ml);
    tej_instance_set_color(w, lamp, 1, 1, 1, 1);
    tej_instance_set_material(w, lamp, 1, 0, 0, 0);                            // unlit: always full bright
    tej_light_create(w, 0, -0.3f, -1.0f, -0.4f, 1, 1, 1, 1.0f, 0);
    tej_camera_set(w, 0, 3, 8, 0, 0.8f, 0, 0.9f, 0.1f, 100);
    tej_env_set_post(w, post ? 1 : 0, exposure, tonemap, contrast, saturation, vignette, bloom, 0.97f);   // only really bright things glow
    img.assign(W_ * H_ * 4, 0);
    tej_render_software(w, W_, H_, img.data());
    tej_world_destroy(w);
  };
  auto lum = [&](const std::vector<uint8_t>& im, int x, int y) { const uint8_t* q = &im[(y * W_ + x) * 4]; return (q[0] + q[1] + q[2]) / 3.0f; };
  std::vector<uint8_t> base, img;
  render(false, 1, 0, 1, 1, 0, 0, base);

  render(true, 1, 0, 1, 1, 0, 0, img);   // everything neutral
  int maxd = 0;
  for (size_t i = 0; i < base.size(); i++) maxd = std::max(maxd, std::abs((int)base[i] - (int)img[i]));
  CHECK(maxd <= 1, "post: neutral settings leave the picture the same (within 1 of 255)");

  render(true, 1, 0, 1, 1, 0.9f, 0, img);
  float cornerB = lum(base, 3, 3), cornerV = lum(img, 3, 3), midB = lum(base, W_ / 2, H_ / 2), midV = lum(img, W_ / 2, H_ / 2);
  CHECK(cornerV < cornerB * 0.55f && std::fabs(midV - midB) < 6.0f, "post: vignette darkens the corners and keeps the middle");

  render(true, 1, 0, 1, 0.0f, 0, 0, img);
  // find a red pixel in the base picture (the cube) and look at the same place
  int rx = -1, ry = -1;
  for (int y = 0; y < H_ && rx < 0; y++) for (int x = 0; x < W_; x++) { const uint8_t* q = &base[(y * W_ + x) * 4]; if (q[0] > q[1] + 60 && q[0] > q[2] + 60) { rx = x; ry = y; break; } }
  CHECK(rx >= 0, "post: test scene shows a red cube");
  if (rx >= 0) {
    const uint8_t* q = &img[(ry * W_ + rx) * 4];
    CHECK(std::abs(q[0] - q[1]) <= 2 && std::abs(q[1] - q[2]) <= 2, "post: saturation 0 makes it gray");
  }

  render(true, 0.5f, 0, 1, 1, 0, 0, img);
  CHECK(lum(img, W_ / 2, H_ - 10) < lum(base, W_ / 2, H_ - 10) * 0.85f, "post: exposure 0.5 is darker");
  render(true, 2.0f, 0, 1, 1, 0, 0, img);
  CHECK(lum(img, W_ / 2, H_ - 10) > lum(base, W_ / 2, H_ - 10) * 1.1f, "post: exposure 2 is brighter");

  render(true, 1, 2, 1, 1, 0, 0, img);
  CHECK(lum(img, W_ / 2, H_ - 10) != lum(base, W_ / 2, H_ - 10), "post: ACES tonemap changes the picture");
  int mx = 0;
  for (size_t i = 0; i < img.size(); i++) mx = std::max(mx, (int)img[i]);
  CHECK(mx <= 255, "post: values stay in range");

  render(true, 1, 0, 2.0f, 1, 0, 0, img);
  float dark = std::min(lum(base, 5, 5), 255.0f);
  (void)dark;
  CHECK(std::fabs(lum(img, W_ / 2, H_ - 10) - lum(base, W_ / 2, H_ - 10)) > 3.0f, "post: contrast changes mid gray values");

  // Bloom: find the lamp (pure white pixels) and look just outside its edge.
  render(true, 1, 0, 1, 1, 0, 1.0f, img);
  int lx0 = W_, lx1 = -1, ly = -1;
  for (int y = 0; y < H_; y++) for (int x = W_ / 2; x < W_; x++) { if (base[(y * W_ + x) * 4] > 250 && base[(y * W_ + x) * 4 + 1] > 250 && base[(y * W_ + x) * 4 + 2] > 250) { lx0 = std::min(lx0, x); lx1 = std::max(lx1, x); ly = y; } }
  CHECK(lx1 > lx0, "post: test scene shows a bright lamp");
  if (lx1 > lx0) {
    int ox = std::min(W_ - 1, lx1 + 3);
    CHECK(lum(img, ox, ly) > lum(base, ox, ly) + 8.0f, "post: bloom makes a glow next to the bright lamp");
    CHECK(std::fabs(lum(img, 3, H_ - 3) - lum(base, 3, H_ - 3)) <= 2.0f, "post: bloom does not change faraway pixels");
  }
}

// ---------------------------------------------------------------- joints

static BodyDesc ballBody(V3 pos, float r = 0.1f, float mass = 1.0f) {
  BodyDesc b; b.shape = ShapeType::Sphere; b.half = V3(r, r, r); b.pos = pos; b.mass = mass; b.linearDamping = 0; b.angularDamping = 0; b.mask = 0; return b;
}

static void jointTests() {
  const float dt = 1.0f / 120.0f;
  { // pendulum: ball joint to the world, period 2*pi*sqrt(L/g) for small swings
    PhysicsWorld w; const float L = 2.0f, th0 = 0.2f;
    V3 pivot(0, 5, 0), pos = pivot + V3(std::sin(th0) * L, -std::cos(th0) * L, 0);
    int bob = w.createBody(ballBody(pos));
    JointDesc j; j.type = JointType::Ball; j.a = bob; j.b = -1; j.anchorA = pivot - pos; j.anchorB = pivot;
    int jid = w.createJoint(j);
    CHECK(jid >= 0 && w.jointAlive(jid) && w.jointCount() == 1, "joint: created");
    CHECK(w.bodyCount() == 1, "joint: the hidden world body is not counted as one of your bodies");
    int crossings = 0; float firstT = -1, lastT = -1, prevX = pos.x - pivot.x, maxDist = 0, maxAng = 0;
    for (int i = 0; i < (int)(6.0f / dt); i++) {
      w.step(dt);
      V3 p = w.body(bob)->pos; float x = p.x - pivot.x;
      if ((prevX > 0) != (x > 0)) { crossings++; float t = i * dt; if (firstT < 0) firstT = t; lastT = t; }
      prevX = x;
      maxDist = std::fmax(maxDist, std::fabs(len(p - pivot) - L));
      maxAng = std::fmax(maxAng, std::fabs(std::atan2(x, pivot.y - p.y)));
    }
    float period = crossings > 2 ? 2.0f * (lastT - firstT) / (crossings - 1) : 0;
    float expect = 2.0f * 3.14159265f * std::sqrt(L / 9.81f) * (1 + th0 * th0 / 16.0f);
    printf("  pendulum period %.3f s (expected %.3f s), rope error %.4f m\n", period, expect, maxDist);
    CHECK(std::fabs(period - expect) < expect * 0.04f, "joint: a ball-joint pendulum swings with the right period (within 4%)");
    CHECK(maxDist < 0.03f, "joint: the pendulum stays at its length");
    CHECK(maxAng < th0 * 1.08f, "joint: the pendulum does not gain energy"); }
  { // chain of five links hanging from the world
    PhysicsWorld w; int prev = -1; const float link = 0.5f; int ids[5];
    for (int i = 0; i < 5; i++) {
      V3 pos(i * link + link, 5, 0);
      ids[i] = w.createBody(ballBody(pos, 0.08f));
      JointDesc j; j.type = JointType::Ball; j.a = prev; j.b = ids[i];
      V3 pivot(i * link + 0.0f, 5, 0);
      j.anchorA = prev >= 0 ? pivot - w.body(prev)->pos : pivot; j.anchorB = pivot - pos;
      w.createJoint(j); prev = ids[i];
    }
    float lowest = 99;
    for (int i = 0; i < 360; i++) { w.step(dt); lowest = std::fmin(lowest, w.body(ids[4])->pos.y); }
    float worst = 0;
    V3 last(0, 5, 0);
    for (int i = 0; i < 5; i++) { V3 p = w.body(ids[i])->pos; worst = std::fmax(worst, std::fabs(len(p - last) - link)); last = p; }
    printf("  chain link length error %.4f m\n", worst);
    CHECK(worst < 0.06f, "joint: a hanging chain of five links keeps its links together");
    CHECK(lowest < 5 - 1.5f && lowest > 5 - 5 * link - 0.1f, "joint: the chain falls down and swings below its start (but not below its length)"); }
  { // door: hinge with limits
    PhysicsWorld w; w.gravity = V3(0, 0, 0);
    BodyDesc d; d.half = V3(0.5f, 1.0f, 0.05f); d.pos = V3(0.5f, 1.0f, 0); d.mass = 5; d.linearDamping = 0; d.angularDamping = 0; d.mask = 0;
    int door = w.createBody(d);
    JointDesc j; j.type = JointType::Hinge; j.a = door; j.b = -1; j.anchorA = V3(-0.5f, 0, 0); j.anchorB = V3(0, 1.0f, 0); j.axis = V3(0, 1, 0);
    j.limit = true; j.lower = 0.0f; j.upper = 1.5707963f;
    int jid = w.createJoint(j);
    CHECK(std::fabs(w.jointAngle(jid)) < 1e-4f, "hinge: angle is 0 at creation");
    w.body(door)->angVel = V3(0, 3.0f, 0);   // swing it open hard
    float maxAng = -1, maxOff = 0, maxLeanY = 0;
    for (int i = 0; i < 240; i++) {
      w.step(dt);
      maxAng = std::fmax(maxAng, w.jointAngle(jid));
      Body* b = w.body(door);
      V3 hinge = b->pos + rotate(b->rot, V3(-0.5f, 0, 0));
      maxOff = std::fmax(maxOff, len(hinge - V3(0, 1.0f, 0)));
      maxLeanY = std::fmax(maxLeanY, std::fabs(b->pos.y - 1.0f));
    }
    printf("  door: max angle %.3f rad, hinge drift %.4f m\n", maxAng, maxOff);
    CHECK(maxOff < 0.02f, "hinge: the hinge point stays where it is");
    CHECK(maxLeanY < 0.02f, "hinge: the door only turns around its axis (does not tilt or rise)");
    CHECK(maxAng > 1.45f && maxAng < 1.65f, "hinge: the upper limit stops the door at 90 degrees");
    w.body(door)->angVel = V3(0, -3.0f, 0);
    float minAng = 9;
    for (int i = 0; i < 240; i++) { w.step(dt); minAng = std::fmin(minAng, w.jointAngle(jid)); }
    CHECK(minAng > -0.12f, "hinge: the lower limit stops it at 0"); }
  { // hinge motor: a wheel turns at the wanted speed
    PhysicsWorld w; w.gravity = V3(0, 0, 0);
    BodyDesc d; d.half = V3(0.5f, 0.5f, 0.1f); d.pos = V3(0, 2, 0); d.mass = 2; d.linearDamping = 0; d.angularDamping = 0; d.mask = 0;
    int wheel = w.createBody(d);
    JointDesc j; j.type = JointType::Hinge; j.a = wheel; j.b = -1; j.anchorA = V3(0, 0, 0); j.anchorB = V3(0, 2, 0); j.axis = V3(0, 0, 1);
    j.motorSpeed = 3.0f; j.motorMaxTorque = 50.0f;
    w.createJoint(j);
    for (int i = 0; i < 240; i++) w.step(dt);
    CHECK(std::fabs(w.body(wheel)->angVel.z - 3.0f) < 0.15f, "hinge motor: the wheel turns at 3 rad/s");
    CHECK(std::fabs(w.body(wheel)->angVel.x) < 0.05f && std::fabs(w.body(wheel)->angVel.y) < 0.05f && len(w.body(wheel)->pos - V3(0, 2, 0)) < 0.02f, "hinge motor: it turns only around its axle and stays in place"); }
  { // weak motor cannot reach the speed against a heavy load
    PhysicsWorld w; w.gravity = V3(0, 0, 0);
    BodyDesc d; d.half = V3(0.5f, 0.5f, 0.5f); d.pos = V3(0, 2, 0); d.mass = 100; d.linearDamping = 0; d.angularDamping = 0; d.mask = 0;
    int wheel = w.createBody(d);
    JointDesc j; j.type = JointType::Hinge; j.a = wheel; j.b = -1; j.anchorB = V3(0, 2, 0); j.axis = V3(0, 0, 1); j.motorSpeed = 10.0f; j.motorMaxTorque = 1.0f;
    w.createJoint(j);
    for (int i = 0; i < 120; i++) w.step(dt);
    // inertia = 100 * (1+1)/12 = 16.7, torque 1 -> 0.06 rad/s^2 -> 0.06 rad/s after 1 s
    CHECK(w.body(wheel)->angVel.z > 0.03f && w.body(wheel)->angVel.z < 0.12f, "hinge motor: a weak motor is limited by its maximum torque"); }
  { // fixed joint: two boxes move as one
    PhysicsWorld w;
    BodyDesc a; a.half = V3(0.5f, 0.5f, 0.5f); a.pos = V3(0, 10, 0); a.mass = 1; a.mask = 0;
    BodyDesc b = a; b.pos = V3(1.2f, 10, 0);
    int ia = w.createBody(a), ib = w.createBody(b);
    JointDesc j; j.type = JointType::Fixed; j.a = ia; j.b = ib; j.anchorA = V3(0.6f, 0, 0); j.anchorB = V3(-0.6f, 0, 0);
    w.createJoint(j);
    w.body(ia)->linVel = V3(2, 4, 1); w.body(ia)->angVel = V3(0, 0, 2);   // thrown with a spin
    for (int i = 0; i < 180; i++) w.step(dt);
    Body* A = w.body(ia); Body* B = w.body(ib);
    V3 rel = rotate(conj(A->rot), B->pos - A->pos);
    Q dq = conj(A->rot) * B->rot;
    printf("  fixed joint: offset error %.4f m, rotation error %.4f\n", len(rel - V3(1.2f, 0, 0)), 2 * std::sqrt(dq.x * dq.x + dq.y * dq.y + dq.z * dq.z));
    CHECK(len(rel - V3(1.2f, 0, 0)) < 0.05f, "fixed joint: the two boxes keep their offset while flying and spinning");
    CHECK(std::sqrt(dq.x * dq.x + dq.y * dq.y + dq.z * dq.z) < 0.03f, "fixed joint: and their orientation to each other"); }
  { // rope: never longer than maxLen, but slack when closer
    PhysicsWorld w;
    int bob = w.createBody(ballBody(V3(0, 7, 0)));
    JointDesc j; j.type = JointType::Rope; j.a = bob; j.b = -1; j.anchorB = V3(0, 10, 0); j.minLen = 0; j.maxLen = 3.0f;
    w.createJoint(j);
    // slack: free fall while the rope is not tight (distance 3 now; shorten first)
    w.body(bob)->pos = V3(0, 9, 0);
    for (int i = 0; i < 30; i++) w.step(dt);
    float fell = 9.0f - w.body(bob)->pos.y;
    CHECK(fell > 0.5f * 9.81f * 0.25f * 0.25f * 0.9f && fell < 0.5f * 9.81f * 0.25f * 0.25f * 1.1f, "rope: slack rope does not hold (free fall)");
    float maxLen = 0;
    for (int i = 0; i < 360; i++) { w.step(dt); maxLen = std::fmax(maxLen, len(w.body(bob)->pos - V3(0, 10, 0))); }
    printf("  rope: longest %.4f m (limit 3)\n", maxLen);
    CHECK(maxLen < 3.06f, "rope: a falling body is caught at the rope length");
    CHECK(std::fabs(len(w.body(bob)->pos - V3(0, 10, 0)) - 3.0f) < 0.05f, "rope: and hangs from it"); }
  { // spring: frequency
    PhysicsWorld w; w.gravity = V3(0, 0, 0);
    int bob = w.createBody(ballBody(V3(0, 5, 0), 0.1f, 2.0f));
    JointDesc j; j.type = JointType::Spring; j.a = bob; j.b = -1; j.anchorA = V3(0, 0, 0); j.anchorB = V3(0, 8, 0); j.restLen = 2.0f; j.hz = 2.0f; j.damping = 0.0f;
    w.createJoint(j);
    int crossings = 0; float first = -1, last = -1; float prev = 3.0f - 2.0f;
    for (int i = 0; i < 480; i++) {
      w.step(dt);
      float e = len(w.body(bob)->pos - V3(0, 8, 0)) - 2.0f;
      if ((prev > 0) != (e > 0)) { crossings++; float t = i * dt; if (first < 0) first = t; last = t; }
      prev = e;
    }
    float period = crossings > 2 ? 2.0f * (last - first) / (crossings - 1) : 0;
    printf("  spring period %.3f s (expected 0.500 s)\n", period);
    CHECK(std::fabs(period - 0.5f) < 0.05f, "spring: oscillates at the wanted frequency (2 Hz)"); }
  { // damped spring comes to rest at the rest length
    PhysicsWorld w; w.gravity = V3(0, 0, 0);
    int bob = w.createBody(ballBody(V3(0, 5, 0), 0.1f, 2.0f));
    JointDesc j; j.type = JointType::Spring; j.a = bob; j.b = -1; j.anchorB = V3(0, 8, 0); j.restLen = 2.0f; j.hz = 3.0f; j.damping = 0.8f;
    w.createJoint(j);
    for (int i = 0; i < 600; i++) w.step(dt);
    CHECK(std::fabs(len(w.body(bob)->pos - V3(0, 8, 0)) - 2.0f) < 0.03f && len(w.body(bob)->linVel) < 0.05f, "spring: with damping it settles at the rest length"); }
  { // breaking
    for (int weak = 0; weak < 2; weak++) {
      PhysicsWorld w;
      int bob = w.createBody(ballBody(V3(0, 3, 0), 0.1f, 1.0f));
      JointDesc j; j.type = JointType::Ball; j.a = bob; j.b = -1; j.anchorB = V3(0, 5, 0); j.anchorA = V3(0, 2, 0);
      j.breakForce = weak ? 5.0f : 50.0f;     // the weight is 9.81 N
      int jid = w.createJoint(j);
      for (int i = 0; i < 240; i++) w.step(dt);
      if (weak) CHECK(w.jointBroken(jid) && !w.jointAlive(jid) && w.body(bob)->pos.y < 0.0f, "joint: 5 N cannot hold a 9.8 N weight, it breaks and the body falls");
      else CHECK(!w.jointBroken(jid) && w.jointAlive(jid) && w.body(bob)->pos.y > 2.9f, "joint: 50 N holds a 9.8 N weight");
      if (!weak) CHECK(std::fabs(w.jointForce(jid) - 9.81f) < 1.0f, "joint: reports the force it carries (about the weight)");
    } }
  { // collideConnected
    for (int cc = 0; cc < 2; cc++) {
      PhysicsWorld w; w.gravity = V3(0, 0, 0);
      BodyDesc a; a.half = V3(0.5f, 0.5f, 0.5f); a.pos = V3(0, 3, 0); a.mass = 1; a.linearDamping = 0;
      BodyDesc b = a; b.pos = V3(0.6f, 3, 0);     // overlapping
      int ia = w.createBody(a), ib = w.createBody(b);
      JointDesc j; j.type = JointType::Ball; j.a = ia; j.b = ib; j.anchorA = V3(0.3f, 0, 0); j.anchorB = V3(-0.3f, 0, 0); j.collideConnected = cc == 1;
      w.createJoint(j);
      for (int i = 0; i < 60; i++) w.step(dt);
      float d = len(w.body(ib)->pos - w.body(ia)->pos);
      if (cc == 0) CHECK(std::fabs(d - 0.6f) < 0.05f, "joint: connected bodies do not push each other apart by default");
      else CHECK(d > 0.8f, "joint: with collideConnected they push apart");
    } }
  { // destroy a joint, destroy a body
    PhysicsWorld w;
    int bob = w.createBody(ballBody(V3(0, 3, 0)));
    JointDesc j; j.type = JointType::Ball; j.a = bob; j.b = -1; j.anchorB = V3(0, 3, 0);
    int jid = w.createJoint(j);
    for (int i = 0; i < 60; i++) w.step(dt);
    CHECK(std::fabs(w.body(bob)->pos.y - 3.0f) < 0.02f, "joint: a body pinned to a point stays there");
    w.destroyJoint(jid);
    CHECK(!w.jointAlive(jid) && w.jointCount() == 0, "joint: destroyed");
    for (int i = 0; i < 60; i++) w.step(dt);
    CHECK(w.body(bob)->pos.y < 2.0f, "joint: after destroying it the body falls");
    int a = w.createBody(ballBody(V3(0, 9, 0))), b = w.createBody(ballBody(V3(1, 9, 0)));
    JointDesc k; k.type = JointType::Ball; k.a = a; k.b = b; k.anchorA = V3(0.5f, 0, 0); k.anchorB = V3(-0.5f, 0, 0);
    int kid = w.createJoint(k);
    w.destroyBody(b);
    for (int i = 0; i < 10; i++) w.step(dt);
    CHECK(!w.jointAlive(kid), "joint: dies when one of its bodies is destroyed (no crash)");
    CHECK(w.createJoint(k) == -1, "joint: refuses bodies that do not exist");
    JointDesc bad; bad.a = -1; bad.b = -1;
    CHECK(w.createJoint(bad) == -1, "joint: refuses two worlds"); }
}

// ---------------------------------------------------------------- JPEG

static void jpegTests() {
  auto path = [&](const char* name) { return std::string("tests/data/") + name; };
  struct Case { const char* name; float maxMean; int maxMax; };
  const Case cases[] = {{"j444.jpg", 1.0f, 8}, {"jgray.jpg", 1.0f, 8}, {"j420.jpg", 2.0f, 40}, {"j422.jpg", 2.0f, 40}, {"jodd.jpg", 2.0f, 40}, {"jrestart.jpg", 2.0f, 40}};
  for (const Case& c : cases) {
    std::vector<uint8_t> jpg = readFile(path(c.name).c_str());
    std::vector<uint8_t> ref = readFile((path(c.name) + ".rgb").c_str());
    CHECK(!jpg.empty() && ref.size() > 8, (std::string("jpeg: test file ") + c.name + " can be read").c_str());
    if (jpg.empty() || ref.size() <= 8) continue;
    int rw = 0, rh = 0; std::memcpy(&rw, &ref[0], 4); std::memcpy(&rh, &ref[4], 4);
    int w = 0, h = 0; std::string err; std::vector<uint8_t> rgba;
    bool ok = tej::decodeJpeg(jpg.data(), jpg.size(), w, h, rgba, err);
    CHECK(ok && w == rw && h == rh, (std::string("jpeg: ") + c.name + " decodes with the right size " + err).c_str());
    if (!ok || w != rw || h != rh) continue;
    double sum = 0; int mx = 0;
    for (int i = 0; i < w * h; i++) for (int k = 0; k < 3; k++) { int d = std::abs((int)rgba[i * 4 + k] - (int)ref[8 + i * 3 + k]); sum += d; mx = std::max(mx, d); }
    double mean = sum / (w * h * 3.0);
    printf("  %s: mean difference to libjpeg %.3f, largest %d\n", c.name, mean, mx);
    CHECK(mean < c.maxMean && mx <= c.maxMax, (std::string("jpeg: ") + c.name + " matches libjpeg").c_str());
    CHECK(rgba[3] == 255, (std::string("jpeg: ") + c.name + " is opaque").c_str());
  }
  { // progressive JPEG: libjpeg's own picture of each file, and exactly the same pixels as the baseline twin
    struct P { const char* name; const char* twin; bool hasRef; };
    const P progs[] = {
      {"jprog.jpg", nullptr, true},
      {"prog_420.jpg", "pbase_420.jpg", true}, {"prog_420_a.jpg", "pbase_420.jpg", false}, {"prog_420_b.jpg", "pbase_420.jpg", true},
      {"prog_420_restart.jpg", "pbase_420.jpg", false}, {"prog_420_b_restart.jpg", "pbase_420.jpg", false},
      {"prog_444.jpg", "pbase_444.jpg", true}, {"prog_422.jpg", "pbase_422.jpg", true}, {"prog_422_b.jpg", "pbase_422.jpg", false},
      {"prog_gray.jpg", "pbase_gray.jpg", true}, {"prog_tiny.jpg", "pbase_tiny.jpg", true}, {"prog_wide.jpg", "pbase_wide.jpg", true}};
    for (const P& p : progs) {
      std::vector<uint8_t> jpg = readFile(path(p.name).c_str());
      int w = 0, h = 0; std::string err; std::vector<uint8_t> rgba;
      bool ok = !jpg.empty() && tej::decodeJpeg(jpg.data(), jpg.size(), w, h, rgba, err);
      CHECK(ok, (std::string("jpeg progressive: ") + p.name + " decodes " + err).c_str());
      if (!ok) continue;
      if (p.twin) {   // same coefficients, other scan order: the pixels must be identical
        std::vector<uint8_t> bj = readFile(path(p.twin).c_str());
        int bw = 0, bh = 0; std::string e2; std::vector<uint8_t> brgba;
        bool bok = !bj.empty() && tej::decodeJpeg(bj.data(), bj.size(), bw, bh, brgba, e2);
        CHECK(bok && bw == w && bh == h && brgba == rgba, (std::string("jpeg progressive: ") + p.name + " gives exactly the pixels of " + p.twin).c_str());
      }
      if (p.hasRef) {
        std::vector<uint8_t> ref = readFile((path(p.name) + ".rgb").c_str());
        int rw = 0, rh = 0; if (ref.size() > 8) { std::memcpy(&rw, &ref[0], 4); std::memcpy(&rh, &ref[4], 4); }
        CHECK(ref.size() == 8 + (size_t)rw * rh * 3 && rw == w && rh == h, (std::string("jpeg progressive: ") + p.name + " has the size libjpeg reports").c_str());
        if (ref.size() != 8 + (size_t)rw * rh * 3 || rw != w || rh != h) continue;
        double sum = 0; int mx = 0;
        for (int i = 0; i < w * h; i++) for (int k = 0; k < 3; k++) { int d = std::abs((int)rgba[i * 4 + k] - (int)ref[8 + i * 3 + k]); sum += d; mx = std::max(mx, d); }
        double mean = sum / (w * h * 3.0);
        printf("  %s: mean difference to libjpeg %.3f, largest %d\n", p.name, mean, mx);
        CHECK(mean < 2.0 && mx <= 40, (std::string("jpeg progressive: ") + p.name + " matches libjpeg").c_str());
      }
    }
  }
  { // progressive files that are cut or damaged: an error or a blurry picture, never a crash
    std::vector<uint8_t> prog = readFile(path("prog_420_b.jpg").c_str());
    int w, h; std::string err; std::vector<uint8_t> rgba;
    // cut after the first scans: the picture is still there (blurry), like a download that stopped
    size_t cut = 0;
    for (size_t i = 2; i + 1 < prog.size(); i++) if (prog[i] == 0xFF && prog[i + 1] == 0xDA) { cut = i; }   // last SOS
    std::vector<uint8_t> part(prog.begin(), prog.begin() + cut);
    bool ok = tej::decodeJpeg(part.data(), part.size(), w, h, rgba, err);
    CHECK(ok && w == 70 && h == 50, "jpeg progressive: a file cut before its last scans still gives a picture");
    unsigned seed = 7;
    auto rnd = [&]() { seed = seed * 1664525u + 1013904223u; return seed >> 8; };
    const char* files[] = {"prog_420_b.jpg", "prog_420_a.jpg", "prog_420_b_restart.jpg", "prog_gray.jpg", "prog_422_b.jpg"};
    int runs = 0;
    for (int it = 0; it < 1000; it++) {
      std::vector<uint8_t> base = readFile(path(files[it % 5]).c_str());
      std::vector<uint8_t> f = base;
      int kind = (it / 5) % 5;
      if (kind == 0) f.resize(rnd() % f.size());
      else if (kind == 1) for (int k = 0; k < 8; k++) f[rnd() % f.size()] = (uint8_t)rnd();
      else if (kind == 2) { size_t at = 2 + rnd() % (f.size() - 2); f[at] = 0xFF; }
      else if (kind == 3) f[2 + rnd() % 600] ^= (uint8_t)(1u << (rnd() % 8));
      else { size_t at = 600 + rnd() % (f.size() - 600); f[at] ^= (uint8_t)(1u << (rnd() % 8)); f[at / 2 + 300] = (uint8_t)rnd(); }   // inside the scan data
      int fw, fh; std::string e; std::vector<uint8_t> px;
      tej::decodeJpeg(f.data(), f.size(), fw, fh, px, e);
      runs++;
    }
    CHECK(runs == 1000, "jpeg progressive: 1000 damaged progressive files do not crash the decoder"); }
  { // a scan header with a range that makes no sense is refused with a message
    std::vector<uint8_t> prog = readFile(path("prog_420_b.jpg").c_str());
    // find the second scan header (AC first pass of luma, Ss=1) and break its range: Se < Ss
    size_t at = 0; int seen = 0;
    for (size_t i = 2; i + 1 < prog.size(); i++) if (prog[i] == 0xFF && prog[i + 1] == 0xDA && ++seen == 2) { at = i; break; }
    std::vector<uint8_t> bad = prog;
    int ns = bad[at + 4];
    bad[at + 5 + 2 * ns] = 40; bad[at + 6 + 2 * ns] = 10;   // Ss = 40, Se = 10
    int w, h; std::string err; std::vector<uint8_t> rgba;
    bool ok = tej::decodeJpeg(bad.data(), bad.size(), w, h, rgba, err);
    CHECK(!ok && err.find("progressive scan") != std::string::npos, "jpeg progressive: a broken scan range is reported");
  }
  { // C API: PNG and JPEG through one function
    std::vector<uint8_t> jpg = readFile(path("j444.jpg").c_str()), pngFile = readFile(path("checker.png").c_str());
    int32_t w = 0, h = 0; char err[128] = {0};
    CHECK(tej_decode_image(jpg.data(), (int)jpg.size(), &w, &h, nullptr, err, sizeof err) == 1 && w == 64 && h == 48, "jpeg: tej_decode_image reports the size of a JPEG");
    std::vector<uint8_t> px(w * h * 4);
    CHECK(tej_decode_image(jpg.data(), (int)jpg.size(), &w, &h, px.data(), err, sizeof err) == 1, "jpeg: tej_decode_image decodes it");
    CHECK(tej_decode_image(pngFile.data(), (int)pngFile.size(), &w, &h, nullptr, err, sizeof err) == 1, "jpeg: and a PNG with the same call");
    uint8_t junk[16] = {1, 2, 3};
    CHECK(tej_decode_image(junk, 16, &w, &h, nullptr, err, sizeof err) == 0 && err[0] != 0, "jpeg: junk gives an error message"); }
  { // JPEG texture inside a glb
    std::vector<uint8_t> glb = readFile(path("test_textured_jpeg.glb").c_str());
    TejWorld* w = tej_world_create();
    int n = tej_model_load_glb(w, glb.data(), (int)glb.size());
    char warn[256] = {0}; tej_model_warning(w, warn, sizeof warn);
    CHECK(n == 1 && warn[0] == 0, "jpeg: a glb with a JPEG texture loads without warnings");
    tej::World& W_ = *w;
    CHECK(!W_.textures.empty() && W_.textures[0].w == 64 && W_.textures[0].h == 48, "jpeg: the texture inside the glb has the JPEG's size");
    tej_world_destroy(w); }
  { // damaged JPEGs: errors or garbage, never a crash
    std::vector<uint8_t> base = readFile(path("j420.jpg").c_str());
    unsigned seed = 99;
    auto rnd = [&]() { seed = seed * 1664525u + 1013904223u; return seed >> 8; };
    int runs = 0;
    for (int it = 0; it < 600; it++) {
      std::vector<uint8_t> f = base;
      int kind = it % 4;
      if (kind == 0) f.resize(rnd() % f.size());
      else if (kind == 1) for (int k = 0; k < 6; k++) f[rnd() % f.size()] = (uint8_t)rnd();
      else if (kind == 2) { size_t at = 2 + rnd() % (f.size() - 2); f[at] = 0xFF; }
      else f[2 + rnd() % 400] ^= (uint8_t)(1u << (rnd() % 8));
      int w, h; std::string err; std::vector<uint8_t> px;
      tej::decodeJpeg(f.data(), f.size(), w, h, px, err);
      runs++;
    }
    CHECK(runs == 600, "jpeg: 600 damaged files do not crash the decoder"); }
}

// ---------------------------------------------------------------- debug lines and particles

static void debugDrawTests() {
  const int W_ = 240, H_ = 160;
  struct Scene {
    TejWorld* w;
    M4 vp;
    Scene(bool box) {
      w = tej_world_create();
      float id[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
      int ground = tej_instance_create(w, tej_mesh_plane(w, 60, 60, 1, 30));
      tej_instance_set_transform(w, ground, id);
      tej_instance_set_color(w, ground, 0.3f, 0.3f, 0.3f, 1);
      if (box) {   // a box between the camera and the point (0, 0.5, 0)
        int b = tej_instance_create(w, tej_mesh_box(w, 1.0f, 1.0f, 0.2f));
        float m[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0, 1.0f, 3.0f, 1};
        tej_instance_set_transform(w, b, m);
      }
      tej_light_create(w, 0, -0.3f, -1.0f, -0.4f, 1, 1, 1, 1.0f, 0);
      tej_camera_set(w, 0, 3, 9, 0, 0.5f, 0, 0.9f, 0.1f, 100);
      vp = perspective(0.9f, (float)W_ / H_, 0.1f, 100) * lookAt(V3(0, 3, 9), V3(0, 0.5f, 0), V3(0, 1, 0));
    }
    ~Scene() { tej_world_destroy(w); }
    void px(V3 p, int& x, int& y) const {
      float cx = vp.at(0,0)*p.x + vp.at(0,1)*p.y + vp.at(0,2)*p.z + vp.at(0,3);
      float cy = vp.at(1,0)*p.x + vp.at(1,1)*p.y + vp.at(1,2)*p.z + vp.at(1,3);
      float cw = vp.at(3,0)*p.x + vp.at(3,1)*p.y + vp.at(3,2)*p.z + vp.at(3,3);
      x = (int)((cx / cw * 0.5f + 0.5f) * W_); y = (int)((1.0f - (cy / cw * 0.5f + 0.5f)) * H_);
    }
    std::vector<uint8_t> render() { std::vector<uint8_t> im(W_ * H_ * 4, 0); tej_render_software(w, W_, H_, im.data()); return im; }
  };
  auto at = [&](const std::vector<uint8_t>& im, int x, int y) { return &im[(y * W_ + x) * 4]; };

  { Scene sc(false); auto base = sc.render();
    float line[10] = {-3, 0.01f, 0, 3, 0.01f, 0, 1, 0, 0, 1};
    tej_debug_set_lines(sc.w, line, 1, 1);
    auto im = sc.render(); int x, y; sc.px(V3(0, 0.01f, 0), x, y);
    CHECK(at(im, x, y)[0] > 230 && at(im, x, y)[1] < 30 && at(im, x, y)[2] < 30, "debug: a red line is drawn where it should be");
    int changed = 0; for (size_t i = 0; i < im.size(); i++) if (im[i] != base[i]) changed++;
    CHECK(changed > 30 && changed < 3 * 4 * 400, "debug: and only the line changes");
    tej_debug_set_lines(sc.w, nullptr, 0, 1);
    auto cleared = sc.render();
    CHECK(cleared == base, "debug: count 0 clears the lines");
    float half[10] = {-3, 0.01f, 0, 3, 0.01f, 0, 1, 0, 0, 0.5f};
    tej_debug_set_lines(sc.w, half, 1, 1);
    auto im2 = sc.render();
    CHECK(at(im2, x, y)[0] > at(base, x, y)[0] + 20 && at(im2, x, y)[0] < 235, "debug: alpha 0.5 mixes with the picture"); }
  { Scene sc(true); auto base = sc.render();
    float line[10] = {-3, 0.5f, 0, 3, 0.5f, 0, 0, 1, 0, 1};   // behind the box seen from the camera
    tej_debug_set_lines(sc.w, line, 1, 1);
    auto hidden = sc.render(); int x, y; sc.px(V3(0, 0.5f, 0), x, y);
    CHECK(!(at(hidden, x, y)[1] > 200 && at(hidden, x, y)[0] < 60), "debug: a line behind a box is hidden when depth test is on");
    tej_debug_set_lines(sc.w, line, 1, 0);
    auto shown = sc.render();
    CHECK(at(shown, x, y)[1] > 200 && at(shown, x, y)[0] < 60, "debug: and visible on top without the depth test"); }
  { Scene sc(false);
    float line[10] = {0, 1, 5, 0, 1, 40, 1, 1, 0, 1};      // runs through the camera (z = 9 is behind the start...)
    float behind[10] = {0, 1, 4, 0, 1, 30, 1, 1, 0, 1};    // one end far behind the camera
    tej_debug_set_lines(sc.w, behind, 1, 1);
    auto im = sc.render();
    (void)line;
    CHECK(im.size() == (size_t)W_ * H_ * 4, "debug: a line with one end behind the camera is clipped and does not crash");
    float huge[10] = {-1e7f, 0, 0, 1e7f, 0, 0, 1, 1, 1, 1};
    tej_debug_set_lines(sc.w, huge, 1, 1);
    auto im2 = sc.render();
    CHECK(im2.size() > 0, "debug: an enormous line does not hang or crash"); }

  // ---- particles
  { Scene sc(false); auto base = sc.render();
    float p[9] = {0, 1, 0, 1.0f, 1, 1, 1, 1, 1};   // additive, soft, white
    tej_particles_set(sc.w, p, 1);
    auto im = sc.render(); int x, y; sc.px(V3(0, 1, 0), x, y);
    CHECK(at(im, x, y)[0] > at(base, x, y)[0] + 40, "particles: an additive particle makes its spot brighter");
    CHECK(at(im, 3, 3)[0] == at(base, 3, 3)[0] && at(im, W_ - 4, H_ - 4)[1] == at(base, W_ - 4, H_ - 4)[1], "particles: and far away pixels stay the same");
    tej_particles_set(sc.w, nullptr, 0);
    CHECK(sc.render() == base, "particles: count 0 clears them"); }
  { // size shrinks with distance: area about 1/4 when twice as far
    int counts[2];
    for (int k = 0; k < 2; k++) {
      Scene sc(false); auto base = sc.render();
      float p[9] = {0, 1, k == 0 ? 4.0f : -1.0f, 1.0f, 1, 1, 1, 1, 2 | 1};   // hard round, additive; distances from the camera at z = 9: 5 and 10
      tej_particles_set(sc.w, p, 1);
      auto im = sc.render();
      int n = 0; for (int i = 0; i < W_ * H_; i++) if (im[i * 4] != base[i * 4]) n++;
      counts[k] = n;
    }
    float ratio = (float)counts[0] / std::max(1, counts[1]);
    printf("  particle area near %d, far %d (ratio %.2f, expected about 4)\n", counts[0], counts[1], ratio);
    CHECK(ratio > 3.0f && ratio < 5.2f, "particles: twice as far looks four times smaller in area"); }
  { // alpha blend, order does not matter, depth test
    for (int order = 0; order < 2; order++) {
      Scene sc(false);
      float red[9] = {0, 1, -2, 1.5f, 1, 0, 0, 1, 2};      // far, hard round, opaque
      float green[9] = {0, 1, 2, 1.5f, 0, 1, 0, 1, 2};     // near
      float both[18];
      std::memcpy(order == 0 ? both : both + 9, red, 36);
      std::memcpy(order == 0 ? both + 9 : both, green, 36);
      tej_particles_set(sc.w, both, 2);
      auto im = sc.render(); int x, y; sc.px(V3(0, 1, 2), x, y);
      CHECK(at(im, x, y)[1] > 200 && at(im, x, y)[0] < 60, order == 0 ? "particles: the near one covers the far one (far submitted first)" : "particles: ...and when it is submitted first (sorted back to front)");
    } }
  { Scene sc(true); auto base = sc.render();
    float p[9] = {0, 1, -1, 2.0f, 1, 0, 0, 1, 2};         // behind the box
    tej_particles_set(sc.w, p, 1);
    auto im = sc.render(); int x, y; sc.px(V3(0, 1, 3.3f), x, y);   // the box front, where the particle would be seen through it
    CHECK(!(at(im, x, y)[0] > 200 && at(im, x, y)[1] < 60), "particles: a particle behind a solid object is hidden"); }
  { Scene sc(false);
    float p[9] = {0, 1, 20, 1.0f, 1, 1, 1, 1, 1};          // behind the camera
    tej_particles_set(sc.w, p, 1);
    auto im = sc.render(); auto base = Scene(false).render();
    CHECK(im == base, "particles: one behind the camera is skipped");
    float tiny[9] = {0, 1, 0, 1e-9f, 1, 1, 1, 1, 1}, nan[9] = {0, 1, 0, 1.0f, 1, 1, 1, 1, 1};
    nan[0] = std::nanf("");
    float both[18]; std::memcpy(both, tiny, 36); std::memcpy(both + 9, nan, 36);
    tej_particles_set(sc.w, both, 2);
    auto im2 = sc.render();
    CHECK(im2.size() > 0, "particles: tiny and NaN particles do not crash"); }
  { Scene sc(false); auto base = sc.render();
    for (int shape = 1; shape <= 2; shape++) {   // 1 = hard round, 2 = square
      float p[9] = {0, 1, 0, 1.0f, 1, 1, 1, 1, (float)(shape * 2)};
      tej_particles_set(sc.w, p, 1);
      auto im = sc.render(); int x, y; sc.px(V3(0, 1, 0), x, y);
      float rad = 0.5f * 1.0f * (H_ * 0.5f / std::tan(0.45f)) / 9.2f;      // pixel radius at the distance of 9.2 m
      int cx = x + (int)(rad * 0.9f), cy = y - (int)(rad * 0.9f);        // near the corner of the sprite square
      bool changed = at(im, cx, cy)[0] != at(base, cx, cy)[0];
      if (shape == 1) CHECK(!changed, "particles: a round particle leaves the corner of its square alone");
      else CHECK(changed, "particles: a square particle fills its corner");
    } }
}

// ---------------------------------------------------------------- capsules and compound shapes

static BodyDesc groundBox() { BodyDesc g; g.mass = 0; g.half = V3(60, 0.5f, 60); g.pos = V3(0, -0.5f, 0); return g; }
static Q rotAxis(V3 axis, float a) { float s = std::sin(a / 2); return Q(axis.x * s, axis.y * s, axis.z * s, std::cos(a / 2)); }

static void capsuleTests() {
  const float dt = 1.0f / 60.0f;
  auto settle = [&](PhysicsWorld& w, int secs) { for (int i = 0; i < secs * 60; i++) w.step(dt); };
  { // a capsule lying on the ground rests at its radius, and goes to sleep
    PhysicsWorld w; w.createBody(groundBox());
    BodyDesc c; c.shape = ShapeType::Capsule; c.half = V3(0.3f, 0.5f, 0); c.pos = V3(0, 2, 0); c.rot = rotAxis(V3(0, 0, 1), 1.5707963f);
    int id = w.createBody(c);
    settle(w, 4);
    Body* b = w.body(id);
    CHECK(std::fabs(b->pos.y - 0.3f) < 0.03f, "capsule: lies on the ground at its radius height");
    V3 axis = rotate(b->rot, V3(0, 1, 0));
    CHECK(std::fabs(axis.y) < 0.1f, "capsule: and stays lying down");
    settle(w, 4);
    CHECK(b->sleeping, "capsule: comes to rest and sleeps"); }
  { // standing capsule dropped slightly tilted falls over and ends up lying
    PhysicsWorld w; w.createBody(groundBox());
    BodyDesc c; c.shape = ShapeType::Capsule; c.half = V3(0.3f, 0.5f, 0); c.pos = V3(0, 1.5f, 0); c.rot = rotAxis(V3(0, 0, 1), 0.2f);
    int id = w.createBody(c);
    settle(w, 6);
    V3 axis = rotate(w.body(id)->rot, V3(0, 1, 0));
    CHECK(std::fabs(axis.y) < 0.2f && std::fabs(w.body(id)->pos.y - 0.3f) < 0.05f, "capsule: a tilted standing capsule topples and lies down"); }
  { // two capsules crossed: the upper one rests 2 radii above the lower one
    PhysicsWorld w; w.createBody(groundBox());
    BodyDesc a; a.shape = ShapeType::Capsule; a.half = V3(0.3f, 1.0f, 0); a.pos = V3(0, 0.31f, 0); a.rot = rotAxis(V3(0, 0, 1), 1.5707963f);   // along X
    BodyDesc b = a; b.pos = V3(0, 2.0f, 0); b.rot = rotAxis(V3(1, 0, 0), 1.5707963f);                                                           // along Z
    int ia = w.createBody(a), ib = w.createBody(b);
    settle(w, 5);
    printf("  crossed capsules: top at %.3f (expected %.3f)\n", w.body(ib)->pos.y, 0.9f);
    CHECK(std::fabs(w.body(ib)->pos.y - 0.9f) < 0.06f && std::fabs(w.body(ia)->pos.y - 0.3f) < 0.04f, "capsule: two crossed capsules stack (rest 2 radii apart)"); }
  { // capsule against a wall
    PhysicsWorld w; w.createBody(groundBox());
    BodyDesc wall; wall.mass = 0; wall.half = V3(0.5f, 2, 5); wall.pos = V3(3, 2, 0); w.createBody(wall);
    BodyDesc c; c.shape = ShapeType::Capsule; c.half = V3(0.3f, 0.5f, 0); c.pos = V3(0, 0.31f, 0); c.rot = rotAxis(V3(0, 0, 1), 1.5707963f);
    int id = w.createBody(c);
    w.body(id)->linVel = V3(5, 0, 0);   // reaches the wall at about 3 m/s (friction slows it on the way)
    settle(w, 3);
    CHECK(w.body(id)->pos.x > 2.5f - 0.8f - 0.08f && w.body(id)->pos.x < 2.5f - 0.8f + 0.02f, "capsule: a capsule sliding into a wall stops with its end touching it"); }
  { // a sphere on a capsule
    PhysicsWorld w; w.createBody(groundBox());
    BodyDesc c; c.shape = ShapeType::Capsule; c.half = V3(0.3f, 0.5f, 0); c.pos = V3(0, 0.31f, 0); c.rot = rotAxis(V3(0, 0, 1), 1.5707963f); c.mass = 0;
    w.createBody(c);
    BodyDesc s; s.shape = ShapeType::Sphere; s.half = V3(0.2f, 0, 0); s.pos = V3(0.1f, 3, 0);
    int sid = w.createBody(s);
    settle(w, 3);
    CHECK(std::fabs(w.body(sid)->pos.y - (0.31f + 0.3f + 0.2f)) < 0.08f || std::fabs(w.body(sid)->pos.y - 0.2f) < 0.04f, "capsule: a ball lands on a capsule and rests on it or rolls off to the floor"); }
  { // capsule on a triangle mesh floor
    PhysicsWorld w;
    float v[12] = {-20, 0, -20, 20, 0, -20, 20, 0, 20, -20, 0, 20}; uint32_t idx[6] = {0, 2, 1, 0, 3, 2};
    int tm = w.createTriMesh(v, 4, idx, 6);
    BodyDesc g; g.shape = ShapeType::Mesh; g.mass = 0; g.triMesh = tm; w.createBody(g);
    BodyDesc c; c.shape = ShapeType::Capsule; c.half = V3(0.3f, 0.5f, 0); c.pos = V3(0, 2, 0); c.rot = rotAxis(V3(0, 0, 1), 1.5707963f);
    int id = w.createBody(c);
    settle(w, 4);
    CHECK(std::fabs(w.body(id)->pos.y - 0.3f) < 0.05f, "capsule: lies on a triangle mesh floor"); }
  { // raycasts
    PhysicsWorld w;
    BodyDesc c; c.shape = ShapeType::Capsule; c.half = V3(0.3f, 0.5f, 0); c.pos = V3(0, 0.3f, 0); c.rot = rotAxis(V3(0, 0, 1), 1.5707963f); c.mass = 0;
    int id = w.createBody(c);
    RayHit h;
    bool a = w.raycast(V3(0, 5, 0), V3(0, -1, 0), 20, ~0u, -1, h);
    CHECK(a && h.body == id && std::fabs(h.t - (5 - 0.6f)) < 1e-2f, "capsule: a ray hits the side");
    bool b = w.raycast(V3(0.7f, 5, 0), V3(0, -1, 0), 20, ~0u, -1, h);
    CHECK(b && std::fabs(h.t - (5 - (0.3f + std::sqrt(0.09f - 0.04f)))) < 0.02f, "capsule: a ray hits the round end");
    CHECK(!w.raycast(V3(1.2f, 5, 0), V3(0, -1, 0), 20, ~0u, -1, h), "capsule: and misses beyond the end"); }
  { // inertia: a thin long capsule is harder to spin around its short axis than along its length
    PhysicsWorld w; w.gravity = V3(0, 0, 0);
    BodyDesc c; c.shape = ShapeType::Capsule; c.half = V3(0.1f, 1.0f, 0); c.pos = V3(0, 5, 0); c.mass = 2;
    int id = w.createBody(c);
    Body* b = w.body(id);
    CHECK(b->invInertiaLocal.y > b->invInertiaLocal.x * 5.0f, "capsule: easy to spin along its length, harder around the short axes"); }
  { // many capsules in a heap: speed, and everything ends up resting on the ground
    PhysicsWorld w; w.createBody(groundBox());
    for (int i = 0; i < 100; i++) {
      BodyDesc c; c.shape = ShapeType::Capsule; c.half = V3(0.25f, 0.4f, 0);
      c.pos = V3((i % 5) * 0.8f - 1.6f, 1 + (i / 5) * 0.9f, ((i / 25) % 2) * 0.6f);
      c.rot = rotAxis(norm(V3(1, 0.3f, 0.2f)), 0.4f * (i % 7));
      w.createBody(c);
    }
    auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < 360; i++) w.step(dt);
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count() / 360;
    int below = 0, resting = 0;
    for (int i = 1; i <= 100; i++) { Body* b = w.body(i); if (b->pos.y < -0.2f) below++; if (b->pos.y < 4.0f) resting++; }
    printf("  100 capsules: %.2f ms per step\n", ms);
    CHECK(below == 0, "capsule: no capsule falls through the ground in a heap of 100");
    CHECK(resting == 100, "capsule: all of them end up low (not shot into the air)");
    if (!skip_perf()) CHECK(ms < 25.0, "capsule: 100 capsules step in under 25 ms"); }
}

static void compoundTests() {
  const float dt = 1.0f / 60.0f;
  auto settle = [&](PhysicsWorld& w, int secs) { for (int i = 0; i < secs * 60; i++) w.step(dt); };
  auto table = [&](V3 pos) {
    BodyDesc t; t.shape = ShapeType::Compound; t.pos = pos; t.mass = 8;
    return t;
  };
  auto tableParts = []() {
    std::vector<ChildShape> p;
    ChildShape top; top.shape = ShapeType::Box; top.half = V3(1, 0.1f, 1); top.pos = V3(0, 1.0f, 0); p.push_back(top);
    for (int sx = -1; sx <= 1; sx += 2) for (int sz = -1; sz <= 1; sz += 2) {
      ChildShape leg; leg.shape = ShapeType::Box; leg.half = V3(0.1f, 0.5f, 0.1f); leg.pos = V3(sx * 0.85f, 0.4f, sz * 0.85f); p.push_back(leg);
    }
    return p;
  };
  { // a table with four legs: bottom of the legs at local y = -0.1, so it rests with the origin at 0.1
    PhysicsWorld w; w.createBody(groundBox());
    int id = w.createBody(table(V3(0, 3, 0)));
    CHECK(w.setChildren(id, tableParts()), "compound: parts can be set");
    settle(w, 4);
    Body* b = w.body(id);
    V3 up = rotate(b->rot, V3(0, 1, 0));
    printf("  compound table rests at y = %.3f (expected 0.100), up.y %.3f\n", b->pos.y, up.y);
    CHECK(std::fabs(b->pos.y - 0.1f) < 0.04f && up.y > 0.99f, "compound: a table on four legs stands on the ground"); }
  { // a ball rolls onto a table top and stays
    PhysicsWorld w; w.createBody(groundBox());
    BodyDesc t = table(V3(0, 0.1f, 0)); t.mass = 0;
    int tid = w.createBody(t);
    w.setChildren(tid, tableParts());
    BodyDesc s; s.shape = ShapeType::Sphere; s.half = V3(0.2f, 0, 0); s.pos = V3(0.2f, 4, 0.1f);
    int sid = w.createBody(s);
    settle(w, 3);
    // table top surface: origin 0.1 + 1.0 + 0.1 = 1.2
    CHECK(std::fabs(w.body(sid)->pos.y - (1.2f + 0.2f)) < 0.05f, "compound: a ball dropped on a static table top rests on it"); }
  { // box dropped onto a dynamic compound pushes it
    PhysicsWorld w; w.createBody(groundBox());
    int tid = w.createBody(table(V3(0, 0.1f, 0)));
    w.setChildren(tid, tableParts());
    BodyDesc b; b.half = V3(0.3f, 0.3f, 0.3f); b.pos = V3(0, 3, 0); b.mass = 1;
    int bid = w.createBody(b);
    settle(w, 4);
    CHECK(std::fabs(w.body(bid)->pos.y - (1.2f + 0.3f)) < 0.06f && std::fabs(w.body(tid)->pos.y - 0.1f) < 0.05f, "compound: a box on a table: the table keeps standing and the box rests on it"); }
  { // dumbbell inertia (parallel axis): two spheres far apart on the X axis
    PhysicsWorld w; w.gravity = V3(0, 0, 0);
    BodyDesc d; d.shape = ShapeType::Compound; d.pos = V3(0, 5, 0); d.mass = 1; d.angularDamping = 0; d.linearDamping = 0;
    int id = w.createBody(d);
    std::vector<ChildShape> p;
    for (int s = -1; s <= 1; s += 2) { ChildShape c; c.shape = ShapeType::Sphere; c.half = V3(0.2f, 0.2f, 0.2f); c.pos = V3(s * 1.0f, 0, 0); p.push_back(c); }
    w.setChildren(id, p);
    // spin about Y: impulse (1,0,0) at (0,0,1): torque impulse (0,1,0)
    w.applyImpulse(id, V3(1, 0, 0), V3(0, 5, 1));
    float wy = w.body(id)->angVel.y;
    printf("  dumbbell spin %.3f rad/s (expected about 1.0)\n", wy);
    CHECK(wy > 0.8f && wy < 1.1f, "compound: the inertia of two far apart parts follows the parallel axis rule"); }
  { // a capsule part in a compound, raycast, AABB for the broadphase
    PhysicsWorld w;
    BodyDesc d; d.shape = ShapeType::Compound; d.pos = V3(0, 1, 0); d.mass = 0;
    int id = w.createBody(d);
    ChildShape cap; cap.shape = ShapeType::Capsule; cap.half = V3(0.2f, 0.5f, 0); cap.pos = V3(3, 0, 0); cap.rot = rotAxis(V3(0, 0, 1), 1.5707963f);
    ChildShape box; box.shape = ShapeType::Box; box.half = V3(0.5f, 0.5f, 0.5f); box.pos = V3(-3, 0, 0);
    w.setChildren(id, {cap, box});
    RayHit h;
    CHECK(w.raycast(V3(3, 5, 0), V3(0, -1, 0), 20, ~0u, -1, h) && std::fabs(h.t - (5 - 1.2f)) < 0.02f, "compound: a ray finds the capsule part");
    CHECK(w.raycast(V3(-3, 5, 0), V3(0, -1, 0), 20, ~0u, -1, h) && std::fabs(h.t - (5 - 1.5f)) < 0.02f, "compound: and the box part");
    CHECK(!w.raycast(V3(0, 5, 0), V3(0, -1, 0), 20, ~0u, -1, h), "compound: and nothing between them");
    // a falling sphere is caught by the far part (broadphase must cover both parts)
    BodyDesc s; s.shape = ShapeType::Sphere; s.half = V3(0.2f, 0, 0); s.pos = V3(-3, 4, 0);
    int sid = w.createBody(s);
    settle(w, 2);
    CHECK(std::fabs(w.body(sid)->pos.y - (1.5f + 0.2f)) < 0.05f, "compound: the broadphase box covers the parts that are far from the origin"); }
  { // bad parts are refused
    PhysicsWorld w;
    BodyDesc d; d.shape = ShapeType::Compound; d.mass = 1;
    int id = w.createBody(d);
    ChildShape bad; bad.shape = ShapeType::Mesh;
    CHECK(!w.setChildren(id, {bad}), "compound: a mesh part is refused");
    int box = w.createBody(BodyDesc());
    CHECK(!w.setChildren(box, {}), "compound: set parts on a body that is not a compound is refused"); }
  { // through the C API
    TejWorld* w = tej_world_create();
    TejBodyDesc d; std::memset(&d, 0, sizeof d);
    d.shape = 4; d.mass = 2; d.qw = 1; d.mask = 0xFFFFFFFFu; d.friction = 0.5f; d.hx = d.hy = d.hz = 0.5f; d.py = 3; d.gravityScale = 1;
    int id = tej_body_create(w, &d);
    float parts[22] = {1, 0.5f, 0.5f, 0.5f, 0, 0, 0, 0, 0, 0, 1,    3, 0.2f, 0.5f, 0, 1.5f, 0, 0, 0, 0, 0, 1};
    CHECK(tej_body_set_children(w, id, parts, 2) == 1, "compound: through the C API");
    tej_world_destroy(w); }
}




static void testPbrAndFxaa() {
  TejWorld* w = tej_world_create();
  int32_t sphere = tej_mesh_sphere(w, 1.0f, 16, 12);
  int32_t inst = tej_instance_create(w, sphere);
  tej_instance_set_color(w, inst, 0.85f, 0.12f, 0.12f, 1.0f);
  tej_instance_set_pbr(w, inst, 0.85f, 0.18f, 1.0f);
  tej_light_create(w, 0, -0.5f, -0.8f, -0.4f, 1.0f, 0.96f, 0.9f, 2.2f, 0.0f);
  tej_camera_set(w, 0, 0.5f, 3.2f, 0, 0, 0, 1.0f, 0.1f, 100.0f);
  tej_env_set_post(w, 1, 1.1f, 2, 1.05f, 1.1f, 0.15f, 0.25f, 0.8f);
  tej_env_set_aa(w, 1);

  std::vector<uint8_t> rgba(64 * 64 * 4, 0);
  tej_render_software(w, 64, 64, rgba.data());
  // Center pixel hits the metallic red PBR sphere (non-zero red highlight)
  const uint8_t* mid = &rgba[(32 * 64 + 32) * 4];
  CHECK(mid[0] > 40 && mid[3] == 255, "pbr: metallic sphere renders with IBL + ACES + FXAA");
  tej_world_destroy(w);
}

static void testCcdAndProJoints() {
  // 1. CCD prevents a fast bullet from tunneling through a thin wall
  {
    PhysicsWorld w;
    w.gravity = V3(0, 0, 0);
    BodyDesc wall; wall.shape = ShapeType::Box; wall.half = V3(0.05f, 5.0f, 5.0f); wall.mass = 0; wall.pos = V3(2.0f, 0, 0);
    w.createBody(wall);
    BodyDesc bullet; bullet.shape = ShapeType::Sphere; bullet.half = V3(0.1f, 0.1f, 0.1f); bullet.mass = 1.0f;
    bullet.pos = V3(0, 0, 0); bullet.ccd = true; bullet.restitution = 0.0f;
    int bid = w.createBody(bullet);
    w.body(bid)->linVel = V3(120.0f, 0, 0);  // 2.0 meters per single 1/60s frame!
    for (int i = 0; i < 10; i++) w.step(1.0f / 60.0f);
    CHECK(w.body(bid)->pos.x < 2.0f, "ccd: fast bullet stopped by thin wall without tunneling");
  }
  // 2. Slider joint constrains motion to X axis within [0, 2]
  {
    PhysicsWorld w;
    w.gravity = V3(0, 0, 0);
    BodyDesc b; b.shape = ShapeType::Box; b.half = V3(0.2f, 0.2f, 0.2f); b.mass = 1.0f; b.pos = V3(0.5f, 0, 0);
    int bid = w.createBody(b);
    JointDesc jd; jd.type = JointType::Slider; jd.a = -1; jd.b = bid;
    jd.anchorA = V3(0, 0, 0); jd.anchorB = V3(0, 0, 0); jd.axis = V3(1, 0, 0);
    jd.limit = true; jd.lower = 0.0f; jd.upper = 2.0f;
    int jid = w.createJoint(jd);
    CHECK(jid >= 0, "slider joint: created");
    w.applyForce(bid, V3(50.0f, 20.0f, 15.0f));
    for (int i = 0; i < 60; i++) {
      w.applyForce(bid, V3(30.0f, 10.0f, 0.0f));
      w.step(1.0f / 60.0f);
    }
    V3 p = w.body(bid)->pos;
    CHECK(std::fabs(p.y) < 0.08f && std::fabs(p.z) < 0.08f, "slider joint: stays on slide axis");
    CHECK(p.x <= 2.15f && p.x >= -0.1f, "slider joint: respects upper limit");
  }
  // 3. ConeTwist joint limits swing angle
  {
    PhysicsWorld w;
    BodyDesc b; b.shape = ShapeType::Box; b.half = V3(0.2f, 0.5f, 0.2f); b.mass = 1.0f; b.pos = V3(0, -1.0f, 0);
    int bid = w.createBody(b);
    JointDesc jd; jd.type = JointType::ConeTwist; jd.a = -1; jd.b = bid;
    jd.anchorA = V3(0, 0, 0); jd.anchorB = V3(0, 1.0f, 0); jd.axis = V3(0, -1, 0);
    jd.limit = true; jd.upper = 0.5f;
    int jid = w.createJoint(jd);
    CHECK(jid >= 0, "coneTwist joint: created");
    for (int i = 0; i < 30; i++) {
      w.applyForce(bid, V3(15.0f, 0, 0));
      w.step(1.0f / 60.0f);
    }
    CHECK(w.jointAlive(jid), "coneTwist joint: stays intact under side load");
  }
}

static void testConvexHullAndCharacterExtras() {
  // 1. Convex hull pyramid resting on static box floor via GJK + EPA
  {
    PhysicsWorld w;
    BodyDesc g; g.shape = ShapeType::Box; g.half = V3(10, 0.5f, 10); g.mass = 0; g.pos = V3(0, -0.5f, 0);
    w.createBody(g);

    BodyDesc h; h.shape = ShapeType::ConvexHull; h.mass = 1.0f; h.pos = V3(0, 1.5f, 0);
    int hid = w.createBody(h);
    V3 pyr[5] = {
      V3(-0.5f, -0.5f, -0.5f),
      V3( 0.5f, -0.5f, -0.5f),
      V3( 0.5f, -0.5f,  0.5f),
      V3(-0.5f, -0.5f,  0.5f),
      V3( 0.0f,  0.5f,  0.0f)
    };
    CHECK(w.setConvexHull(hid, pyr, 5), "convex hull: vertices accepted");
    for (int i = 0; i < 120; i++) w.step(1.0f / 60.0f);
    Body* hb = w.body(hid);
    CHECK(hb != nullptr && hb->pos.y > 0.25f && hb->pos.y < 0.85f, "convex hull: pyramid rests on floor via GJK+EPA");
  }

  // 2. Character extras: moving platform, push dynamic body, crouch + ceiling clearance, climbing
  {
    TejWorld* tw = tej_world_create();
    TejBodyDesc plat{};
    plat.shape = 1; plat.hx = 4; plat.hy = 0.5f; plat.hz = 4; plat.mass = 0; plat.kinematic = 1;
    plat.py = -0.5f; plat.qw = 1; plat.mask = 0xFFFFFFFFu;
    int32_t platId = tej_body_create(tw, &plat);

    int32_t cid = tej_character_create(tw, 0.4f, 1.8f, 0.35f, 50.0f, 0xFFFFFFFFu, -1, 0, 0.05f, 0);
    tej_character_move(tw, cid, 0, -0.2f, 0, 1);
    float st[10];
    tej_character_state(tw, cid, st);
    CHECK(st[3] > 0.5f, "char extras: grounded on moving platform");

    float np[3] = {2.0f, -0.5f, 0.0f}, nq[4] = {0, 0, 0, 1};
    tej_body_set_transform(tw, platId, np, nq);
    tej_character_move(tw, cid, 0, -0.05f, 0, 1);
    tej_character_state(tw, cid, st);
    CHECK(st[0] > 1.8f && st[0] < 2.2f, "char extras: rides moving platform");

    TejBodyDesc box{};
    box.shape = 1; box.hx = 0.5f; box.hy = 0.5f; box.hz = 0.5f; box.mass = 1.0f;
    box.px = 3.1f; box.py = 0.5f; box.pz = 0.0f; box.qw = 1; box.mask = 0xFFFFFFFFu; box.gravityScale = 1.0f;
    int32_t boxId = tej_body_create(tw, &box);
    tej_character_set_push_force(tw, cid, 8.0f);
    for (int i = 0; i < 10; i++) {
      tej_character_move(tw, cid, 0.15f, -0.05f, 0, 1);
      tej_world_update(tw, 1.0f / 60.0f);
    }
    float bxf[7];
    tej_body_get_transform(tw, boxId, bxf);
    CHECK(bxf[0] > 3.25f, "char extras: pushes dynamic body");

    TejBodyDesc ceilB{};
    ceilB.shape = 1; ceilB.hx = 2.0f; ceilB.hy = 0.2f; ceilB.hz = 2.0f; ceilB.mass = 0;
    ceilB.px = 0.0f; ceilB.py = 1.55f; ceilB.pz = 0.0f; ceilB.qw = 1; ceilB.mask = 0xFFFFFFFFu;
    tej_body_create(tw, &ceilB);
    tej_character_teleport(tw, cid, 0.0f, 0.0f, 0.0f);
    CHECK(tej_character_set_crouch(tw, cid, 1, 1.0f) == 1, "char extras: crouch succeeds");
    CHECK(tej_character_is_crouched(tw, cid) == 1, "char extras: is_crouched reports 1");
    CHECK(tej_character_set_crouch(tw, cid, 0, 1.0f) == 0, "char extras: cannot stand up under low ceiling");

    tej_character_teleport(tw, cid, 5.0f, 0.0f, 0.0f);
    tej_character_set_climbing(tw, cid, 1);
    tej_character_move(tw, cid, 0, 1.5f, 0, 1);
    tej_character_state(tw, cid, st);
    CHECK(st[1] > 1.4f, "char extras: climbs vertically in climbing mode");

    tej_world_destroy(tw);
  }
}


static void testCustomMediaEncoders() {
  TejWorld* w = tej_world_create();
  const int W = 32, H = 24;
  std::vector<uint8_t> rgba((size_t)W * H * 4);
  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      uint8_t* p = &rgba[((size_t)y * W + x) * 4];
      p[0] = (uint8_t)(x * 8);
      p[1] = (uint8_t)(y * 10);
      p[2] = (uint8_t)((x + y) * 4);
      p[3] = 255;
    }
  }

  // 1. Custom PNG round-trip through our own decodePng
  int32_t pngSize = tej_encode_png(w, W, H, rgba.data());
  CHECK(pngSize > 64, "media_enc: custom PNG encodes non-empty stream");
  std::vector<uint8_t> png((size_t)pngSize);
  CHECK(tej_media_copy(w, png.data(), pngSize) == pngSize, "media_enc: PNG bytes copied");
  int dw = 0, dh = 0;
  std::vector<uint8_t> dec;
  std::string err;
  CHECK(tej::decodePng(png.data(), png.size(), dw, dh, dec, err) && dw == W && dh == H,
        "media_enc: custom PNG decodes cleanly");
  CHECK(dec == rgba, "media_enc: custom PNG is 100% pixel-exact lossless");

  // 2. Custom JPEG round-trip through our own decodeJpeg
  int32_t jpgSize = tej_encode_jpeg(w, W, H, rgba.data(), 88);
  CHECK(jpgSize > 100, "media_enc: custom JPEG encodes non-empty stream");
  std::vector<uint8_t> jpg((size_t)jpgSize);
  tej_media_copy(w, jpg.data(), jpgSize);
  std::vector<uint8_t> jdec;
  CHECK(tej::decodeJpeg(jpg.data(), jpg.size(), dw, dh, jdec, err) && dw == W && dh == H,
        "media_enc: custom JPEG decodes cleanly with our decoder");
  int maxDiff = 0;
  for (size_t i = 0; i < rgba.size(); i += 4) {
    for (int c = 0; c < 3; c++) {
      int d = std::abs((int)jdec[i + c] - (int)rgba[i + c]);
      if (d > maxDiff) maxDiff = d;
    }
  }
  CHECK(maxDiff < 25, "media_enc: custom JPEG closely matches source pixels");

  // 3. Custom MJPEG-AVI video recorder (zero ffmpeg)
  CHECK(tej_video_begin(w, W, H, 30, 82) == 1, "media_enc: video recorder starts");
  for (int f = 0; f < 5; f++) {
    CHECK(tej_video_add_frame(w, rgba.data()) == 1, "media_enc: video frame encoded");
  }
  int32_t aviSize = tej_video_finish(w);
  CHECK(aviSize > 500, "media_enc: MJPEG-AVI container finalized");
  std::vector<uint8_t> avi((size_t)aviSize);
  tej_media_copy(w, avi.data(), aviSize);
  CHECK(std::memcmp(avi.data(), "RIFF", 4) == 0 && std::memcmp(avi.data() + 8, "AVI ", 4) == 0,
        "media_enc: valid RIFF/AVI header");
  tej_world_destroy(w);
}


static void testAaaPbrFeatures() {
  TejWorld* w = tej_world_create();
  int32_t sph = tej_mesh_sphere(w, 1.0f, 16, 12);
  int32_t box = tej_mesh_box(w, 0.5f, 0.5f, 0.5f);

  std::vector<uint8_t> normPx(16 * 16 * 4), mrPx(16 * 16 * 4);
  for (int i = 0; i < 16 * 16; i++) {
    normPx[i * 4 + 0] = 140; normPx[i * 4 + 1] = 128; normPx[i * 4 + 2] = 250; normPx[i * 4 + 3] = 255;
    mrPx[i * 4 + 0] = 255;   mrPx[i * 4 + 1] = 52;    mrPx[i * 4 + 2] = 230;   mrPx[i * 4 + 3] = 255;
  }
  int32_t nTex = tej_texture_create(w, 16, 16, normPx.data());
  int32_t mrTex = tej_texture_create(w, 16, 16, mrPx.data());

  std::vector<uint8_t> cm(8 * 8 * 4 * 6, 180);
  CHECK(tej_env_set_cubemap(w, 8, cm.data()) == 1, "aaa_pbr: 360 cubemap uploads cleanly");
  tej_env_set_ssao(w, 1, 0.5f, 3);
  tej_light_create(w, 0, -0.5f, -0.7f, -0.5f, 1, 0.95f, 0.85f, 2.0f, 0);

  int32_t carInst = tej_instance_create(w, sph);
  tej_instance_set_color(w, carInst, 0.8f, 0.08f, 0.1f, 1.0f);
  tej_instance_set_pbr(w, carInst, 0.9f, 0.25f, 1.0f);
  tej_instance_set_pbr_maps(w, carInst, nTex, mrTex);
  tej_instance_set_clearcoat(w, carInst, 1.0f, 0.05f);

  int32_t glass = tej_instance_create(w, box);
  float gm[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,1.6f,1};
  tej_instance_set_transform(w, glass, gm);
  tej_instance_set_color(w, glass, 0.15f, 0.25f, 0.35f, 1.0f);
  tej_instance_set_pbr(w, glass, 0.1f, 0.05f, 1.0f);
  tej_instance_set_alpha(w, glass, 0.35f);

  tej_camera_set(w, 0, 0.5f, 4.5f, 0, 0, 0, 0.9f, 0.1f, 50.0f);
  std::vector<uint8_t> rgba(96 * 96 * 4);
  // GPU render automatically falls back to AAA PBR software renderer when headless!
  tej_gpu_render(w, 96, 96, rgba.data());
  const uint8_t* c = &rgba[(48 * 96 + 48) * 4];
  CHECK(c[0] > 30 && c[3] == 255, "aaa_pbr: clearcoat + normal/MR maps + Fresnel glass + SSAO + cubemap + GPU fallback works");
  tej_gpu_shutdown(w);
  tej_world_destroy(w);
}

int main(int argc, char** argv) {
  textureTests(argc > 2 ? argv[2] : "tests/data");
  physicsTests();
  meshColliderTests();
  characterTests();
  jointTests();
  capsuleTests();
  compoundTests();
  shadowTests();
  postTests();
  debugDrawTests();
  jpegTests();
  modelTests(argc > 1 ? argv[1] : "tests/data/test_model.glb");
  skinnedModelTests("tests/data/test_skinned.glb");
  modelFuzzTests("tests/data/test_skinned.glb", "tests/data/test_model.glb");
  animTests();
  sceneTest();
  perfTest();
  testConvexHullAndCharacterExtras();
  testCcdAndProJoints();
  testPbrAndFxaa();
  testCustomMediaEncoders();
  testAaaPbrFeatures();
  printf(fails ? "\n%d FAILED\n" : "\nALL PASSED\n", fails);
  return fails;
}
