#include "world.h"

namespace tej {

void buildMips(Texture& t) {
  t.mips.clear();
  int w = t.w, h = t.h;
  const std::vector<uint8_t>* prev = &t.rgba;
  while (w > 1 || h > 1) {
    int nw = std::max(1, w / 2), nh = std::max(1, h / 2);
    std::vector<uint8_t> next((size_t)nw * nh * 4);
    for (int y = 0; y < nh; y++)
      for (int x = 0; x < nw; x++)
        for (int c = 0; c < 4; c++) {
          int x0 = std::min(w - 1, x * 2), x1 = std::min(w - 1, x * 2 + 1);
          int y0 = std::min(h - 1, y * 2), y1 = std::min(h - 1, y * 2 + 1);
          int sum = (*prev)[((size_t)y0 * w + x0) * 4 + c] + (*prev)[((size_t)y0 * w + x1) * 4 + c] +
                    (*prev)[((size_t)y1 * w + x0) * 4 + c] + (*prev)[((size_t)y1 * w + x1) * 4 + c];
          next[((size_t)y * nw + x) * 4 + c] = (uint8_t)((sum + 2) / 4);
        }
    t.mips.push_back(std::move(next));
    prev = &t.mips.back();
    w = nw; h = nh;
  }
}

void World::update(float dt) {
  physics.step(dt);
  time += dt;
  for (auto& a : animators) {
    if (!a.alive) continue;
    a.anim.update(dt);
    a.anim.skinMatrices(a.skin);
  }
  for (auto& in : instances) {
    if (!in.alive || in.body < 0) continue;
    if (Body* b = physics.body(in.body)) in.xf = trs(b->pos, b->rot, in.scale);
  }
}

static void addV(Mesh& m, V3 p, V3 n, float u, float v) {
  float f[8] = {p.x, p.y, p.z, n.x, n.y, n.z, u, v};
  m.verts.insert(m.verts.end(), f, f + 8);
}
static void addQuad(Mesh& m, V3 a, V3 b, V3 c, V3 d, V3 n) {  // a,b,c,d CCW seen from outside
  uint32_t i = (uint32_t)m.vertexCount();
  addV(m, a, n, 0, 0); addV(m, b, n, 1, 0); addV(m, c, n, 1, 1); addV(m, d, n, 0, 1);
  uint32_t t[6] = {i, i + 1, i + 2, i, i + 2, i + 3};
  m.idx.insert(m.idx.end(), t, t + 6);
}

Mesh makeBox(float x, float y, float z) {
  Mesh m;
  addQuad(m, {x, -y, z}, {x, -y, -z}, {x, y, -z}, {x, y, z}, {1, 0, 0});
  addQuad(m, {-x, -y, -z}, {-x, -y, z}, {-x, y, z}, {-x, y, -z}, {-1, 0, 0});
  addQuad(m, {-x, y, z}, {x, y, z}, {x, y, -z}, {-x, y, -z}, {0, 1, 0});
  addQuad(m, {-x, -y, -z}, {x, -y, -z}, {x, -y, z}, {-x, -y, z}, {0, -1, 0});
  addQuad(m, {-x, -y, z}, {x, -y, z}, {x, y, z}, {-x, y, z}, {0, 0, 1});
  addQuad(m, {x, -y, -z}, {-x, -y, -z}, {-x, y, -z}, {x, y, -z}, {0, 0, -1});
  return m;
}

Mesh makeSphere(float r, int seg, int rings) {
  Mesh m;
  for (int j = 0; j <= rings; j++) {
    float v = (float)j / rings, phi = v * 3.14159265f;
    for (int i = 0; i <= seg; i++) {
      float u = (float)i / seg, th = u * 6.2831853f;
      V3 n(std::sin(phi) * std::cos(th), std::cos(phi), std::sin(phi) * std::sin(th));
      addV(m, n * r, n, u, v);
    }
  }
  for (int j = 0; j < rings; j++)
    for (int i = 0; i < seg; i++) {
      uint32_t a = j * (seg + 1) + i, b = a + seg + 1;
      m.idx.insert(m.idx.end(), {a, a + 1, b, a + 1, b + 1, b});
    }
  return m;
}

Mesh makeCylinder(float r, float hh, int seg) {
  Mesh m;
  for (int i = 0; i <= seg; i++) {
    float u = (float)i / seg, th = u * 6.2831853f;
    V3 n(std::cos(th), 0, std::sin(th));
    addV(m, V3(n.x * r, -hh, n.z * r), n, u, 0);
    addV(m, V3(n.x * r, hh, n.z * r), n, u, 1);
  }
  for (int i = 0; i < seg; i++) {
    uint32_t a = i * 2;
    m.idx.insert(m.idx.end(), {a, a + 1, a + 2, a + 1, a + 3, a + 2});
  }
  for (int cap = 0; cap < 2; cap++) {
    float y = cap ? hh : -hh;
    V3 n(0, cap ? 1.0f : -1.0f, 0);
    uint32_t c = (uint32_t)m.vertexCount();
    addV(m, V3(0, y, 0), n, 0.5f, 0.5f);
    for (int i = 0; i <= seg; i++) {
      float th = (float)i / seg * 6.2831853f;
      addV(m, V3(std::cos(th) * r, y, std::sin(th) * r), n, 0.5f + 0.5f * std::cos(th), 0.5f + 0.5f * std::sin(th));
    }
    for (int i = 0; i < seg; i++) {
      if (cap) m.idx.insert(m.idx.end(), {c, c + 2 + (uint32_t)i, c + 1 + (uint32_t)i});
      else m.idx.insert(m.idx.end(), {c, c + 1 + (uint32_t)i, c + 2 + (uint32_t)i});
    }
  }
  return m;
}

Mesh makePlane(float hx, float hz, int div, float uvScale) {
  Mesh m;
  for (int j = 0; j <= div; j++)
    for (int i = 0; i <= div; i++) {
      float u = (float)i / div, v = (float)j / div;
      addV(m, V3(-hx + 2 * hx * u, 0, -hz + 2 * hz * v), V3(0, 1, 0), u * uvScale, v * uvScale);
    }
  for (int j = 0; j < div; j++)
    for (int i = 0; i < div; i++) {
      uint32_t a = j * (div + 1) + i, b = a + div + 1;
      m.idx.insert(m.idx.end(), {a, b, a + 1, a + 1, b, b + 1});
    }
  return m;
}

}  // namespace tej
