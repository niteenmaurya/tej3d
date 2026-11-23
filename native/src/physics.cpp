#include "physics.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace tej {

namespace {

struct OBB {
  V3 c, u[3], h;
};
OBB makeObb(const Body& b) {
  OBB o;
  o.c = b.pos;
  axes(b.rot, o.u);
  o.h = b.d.half;
  return o;
}

// Clip polygon against plane dot(p, n) <= off. Returns new count.
int clipPoly(const V3* in, int n, const V3& pn, float off, V3* out) {
  int m = 0;
  for (int i = 0; i < n; i++) {
    const V3& a = in[i];
    const V3& b = in[(i + 1) % n];
    float da = dot(a, pn) - off, db = dot(b, pn) - off;
    if (da <= 0) out[m++] = a;
    if ((da < 0 && db > 0) || (da > 0 && db < 0)) {
      float t = da / (da - db);
      out[m++] = a + (b - a) * t;
    }
    if (m > 12) break;
  }
  return m;
}

}  // namespace


// Inverse inertia of a capsule (axis Y): a cylinder and two half spheres of the same density.
static V3 capsuleInvInertia(float m, float r, float hh) {
  r = std::max(1e-4f, r);
  hh = std::max(0.0f, hh);
  float h = 2 * hh;
  float vc = 3.14159265f * r * r * h, vs = 4.0f / 3.0f * 3.14159265f * r * r * r;
  float mc = m * vc / std::max(1e-9f, vc + vs), ms = m - mc, mh = ms * 0.5f;
  float iy = 0.5f * mc * r * r + 0.4f * ms * r * r;
  float off = hh + 3.0f * r / 8.0f;
  float ix = mc * (r * r / 4.0f + h * h / 12.0f) + 2.0f * (mh * (83.0f / 320.0f) * r * r + mh * off * off);
  ix = std::max(ix, 1e-9f); iy = std::max(iy, 1e-9f);
  return V3(1 / ix, 1 / iy, 1 / ix);
}

static float childVolume(const ChildShape& c) {
  if (c.shape == ShapeType::Sphere) return 4.0f / 3.0f * 3.14159265f * c.half.x * c.half.x * c.half.x;
  if (c.shape == ShapeType::Capsule) return 3.14159265f * c.half.x * c.half.x * 2 * c.half.y + 4.0f / 3.0f * 3.14159265f * c.half.x * c.half.x * c.half.x;
  return 8.0f * c.half.x * c.half.y * c.half.z;
}

// Inertia of a compound: every part as a box-like block (a good estimate), moved to the body center.
static V3 compoundInvInertia(float m, const std::vector<ChildShape>& parts) {
  if (parts.empty()) return V3(1 / std::max(1e-6f, m), 1 / std::max(1e-6f, m), 1 / std::max(1e-6f, m));
  float vol = 0;
  for (auto& c : parts) vol += childVolume(c);
  if (vol <= 1e-12f) vol = 1;
  float ix = 0, iy = 0, iz = 0;
  for (auto& c : parts) {
    float mi = m * childVolume(c) / vol;
    V3 h = c.half;
    if (c.shape == ShapeType::Sphere) h = V3(c.half.x, c.half.x, c.half.x);
    else if (c.shape == ShapeType::Capsule) h = V3(c.half.x, c.half.y + c.half.x, c.half.x);
    // inertia of a box with these half sizes, in the part frame
    V3 il(mi * (h.y * h.y + h.z * h.z) / 3.0f, mi * (h.x * h.x + h.z * h.z) / 3.0f, mi * (h.x * h.x + h.y * h.y) / 3.0f);
    // turn to the body frame (diagonal approximation) and add the parallel axis term
    V3 ex = rotate(c.rot, V3(1, 0, 0)), ey = rotate(c.rot, V3(0, 1, 0)), ez = rotate(c.rot, V3(0, 0, 1));
    float dxx = il.x * ex.x * ex.x + il.y * ey.x * ey.x + il.z * ez.x * ez.x;
    float dyy = il.x * ex.y * ex.y + il.y * ey.y * ey.y + il.z * ez.y * ez.y;
    float dzz = il.x * ex.z * ex.z + il.y * ey.z * ey.z + il.z * ez.z * ez.z;
    ix += dxx + mi * (c.pos.y * c.pos.y + c.pos.z * c.pos.z);
    iy += dyy + mi * (c.pos.x * c.pos.x + c.pos.z * c.pos.z);
    iz += dzz + mi * (c.pos.x * c.pos.x + c.pos.y * c.pos.y);
  }
  ix = std::max(ix, 1e-9f); iy = std::max(iy, 1e-9f); iz = std::max(iz, 1e-9f);
  return V3(1 / ix, 1 / iy, 1 / iz);
}

int PhysicsWorld::createBody(const BodyDesc& d) {
  int id;
  if (!freeList_.empty()) {
    id = freeList_.back();
    freeList_.pop_back();
  } else {
    id = (int)bodies_.size();
    bodies_.emplace_back();
  }
  Body& b = bodies_[id];
  b = Body();
  b.alive = true;
  b.d = d;
  if (d.shape == ShapeType::Mesh) { b.d.mass = 0; b.d.kinematic = false; }
  b.pos = d.pos;
  b.rot = normalize(d.rot);
  if (b.d.mass > 0 && !b.d.kinematic) {
    b.invMass = 1.0f / std::max(1e-4f, d.mass);
    if (d.shape == ShapeType::Sphere) {
      float r = std::max(1e-4f, d.half.x);
      float i = std::max(1e-9f, 0.4f * d.mass * r * r);
      b.invInertiaLocal = V3(1.0f / i, 1.0f / i, 1.0f / i);
    } else if (d.shape == ShapeType::Capsule) {
      b.invInertiaLocal = capsuleInvInertia(d.mass, std::max(1e-4f, d.half.x), std::max(0.0f, d.half.y));
    } else if (d.shape == ShapeType::Compound) {
      b.invInertiaLocal = compoundInvInertia(d.mass, d.children);
    } else {
      float hx = std::max(1e-4f, d.half.x);
      float hy = std::max(1e-4f, d.half.y);
      float hz = std::max(1e-4f, d.half.z);
      float m = std::max(1e-4f, d.mass);
      float ix = std::max(1e-9f, m * (hy * hy + hz * hz) / 3.0f);
      float iy = std::max(1e-9f, m * (hx * hx + hz * hz) / 3.0f);
      float iz = std::max(1e-9f, m * (hx * hx + hy * hy) / 3.0f);
      b.invInertiaLocal = V3(1.0f / ix, 1.0f / iy, 1.0f / iz);
    }
  }
  aliveCount_++;
  return id;
}

void PhysicsWorld::destroyBody(int id) {
  Body* b = body(id);
  if (!b) return;
  b->alive = false;
  freeList_.push_back(id);
  aliveCount_--;
  for (auto& J : joints_) {
    if (J.alive && (J.bodyA == id || J.bodyB == id)) {
      J.alive = false;
      if (!J.d.collideConnected) removeNoCollide(J.bodyA, J.bodyB);
    }
  }
  for (auto it = touching_.begin(); it != touching_.end(); ) {
    int a = (int)(*it >> 32), c = (int)(*it & 0xffffffffu);
    if (a == id || c == id) it = touching_.erase(it);
    else ++it;
  }
  for (auto it = noCollide_.begin(); it != noCollide_.end(); ) {
    int a = (int)(it->first >> 32), c = (int)(it->first & 0xffffffffu);
    if (a == id || c == id) it = noCollide_.erase(it);
    else ++it;
  }
}

bool PhysicsWorld::setChildren(int id, const std::vector<ChildShape>& parts) {
  Body* b = body(id);
  if (!b || b->d.shape != ShapeType::Compound) return false;
  for (auto& c : parts) if (c.shape != ShapeType::Sphere && c.shape != ShapeType::Box && c.shape != ShapeType::Capsule) return false;
  b->d.children = parts;
  for (auto& c : b->d.children) c.rot = normalize(c.rot);
  if (b->d.mass > 0 && !b->d.kinematic) b->invInertiaLocal = compoundInvInertia(b->d.mass, b->d.children);
  wake(id);
  return true;
}

bool PhysicsWorld::setConvexHull(int id, const V3* verts, int count) {
  Body* b = body(id);
  if (!b || b->d.shape != ShapeType::ConvexHull || !verts || count < 4) return false;
  b->d.hullVerts.assign(verts, verts + count);
  V3 mn = verts[0], mx = verts[0];
  for (int i = 1; i < count; i++) {
    mn.x = std::min(mn.x, verts[i].x); mn.y = std::min(mn.y, verts[i].y); mn.z = std::min(mn.z, verts[i].z);
    mx.x = std::max(mx.x, verts[i].x); mx.y = std::max(mx.y, verts[i].y); mx.z = std::max(mx.z, verts[i].z);
  }
  b->d.half = V3(
    std::max(0.01f, std::max(std::fabs(mn.x), std::fabs(mx.x))),
    std::max(0.01f, std::max(std::fabs(mn.y), std::fabs(mx.y))),
    std::max(0.01f, std::max(std::fabs(mn.z), std::fabs(mx.z)))
  );
  if (b->d.mass > 0 && !b->d.kinematic) {
    float sx = std::max(0.02f, mx.x - mn.x);
    float sy = std::max(0.02f, mx.y - mn.y);
    float sz = std::max(0.02f, mx.z - mn.z);
    float c = b->d.mass / 12.0f;
    b->invInertiaLocal = V3(1.0f / (c * (sy * sy + sz * sz)), 1.0f / (c * (sx * sx + sz * sz)), 1.0f / (c * (sx * sx + sy * sy)));
  }
  wake(id);
  return true;
}

void PhysicsWorld::setTransform(int id, const V3& p, const Q& q) {
  if (Body* b = body(id)) {
    b->pos = p;
    b->rot = normalize(q);
    wake(id);
  }
}
void PhysicsWorld::applyForce(int id, const V3& f) {
  if (Body* b = body(id)) { if (b->isDynamic()) { b->force += f; wake(id); } }
}
void PhysicsWorld::applyImpulse(int id, const V3& imp, const V3& wp) {
  Body* b = body(id);
  if (!b || !b->isDynamic()) return;
  b->linVel += imp * b->invMass;
  b->angVel += mulInvI(*b, cross(wp - b->pos, imp));
  wake(id);
}
void PhysicsWorld::wake(int id) {
  if (Body* b = body(id)) { b->sleeping = false; b->sleepTimer = 0; }
}
int PhysicsWorld::awakeCount() const {
  int n = 0;
  for (auto& b : bodies_) if (b.alive && b.isDynamic() && !b.sleeping) n++;
  return n;
}

V3 PhysicsWorld::mulInvI(const Body& b, const V3& v) const {
  V3 l = rotate(conj(b.rot), v);
  l = V3(l.x * b.invInertiaLocal.x, l.y * b.invInertiaLocal.y, l.z * b.invInertiaLocal.z);
  return rotate(b.rot, l);
}

int PhysicsWorld::createTriMesh(const float* xyz, int vc, const uint32_t* idx, int ic) {
  if (!xyz || !idx || vc <= 0 || ic < 3) return -1;
  TriMesh m;
  m.v.resize(vc);
  for (int i = 0; i < vc; i++) m.v[i] = V3(xyz[i * 3], xyz[i * 3 + 1], xyz[i * 3 + 2]);
  m.idx.assign(idx, idx + ic - ic % 3);
  for (uint32_t i : m.idx) if (i >= (uint32_t)vc) return -1;
  m.build();
  triMeshes_.push_back(std::move(m));
  return (int)triMeshes_.size() - 1;
}

void PhysicsWorld::aabb(const Body& b, V3& lo, V3& hi) const {
  if (b.d.shape == ShapeType::Mesh) {
    if (b.d.triMesh < 0 || b.d.triMesh >= (int)triMeshes_.size() || triMeshes_[b.d.triMesh].nodes.empty()) { lo = hi = b.pos; return; }
    const TriMesh& tm = triMeshes_[b.d.triMesh];
    lo = V3(1e30f, 1e30f, 1e30f); hi = V3(-1e30f, -1e30f, -1e30f);
    for (int i = 0; i < 8; i++) {
      V3 c((i & 1) ? tm.hi.x : tm.lo.x, (i & 2) ? tm.hi.y : tm.lo.y, (i & 4) ? tm.hi.z : tm.lo.z);
      V3 w = b.pos + rotate(b.rot, c);
      for (int a = 0; a < 3; a++) { lo[a] = std::min(lo[a], w[a]); hi[a] = std::max(hi[a], w[a]); }
    }
    return;
  }
  if (b.d.shape == ShapeType::Capsule || b.d.shape == ShapeType::Compound) {
    std::vector<Prim> prims;
    primitivesOfBody(b, prims);
    if (prims.empty()) { lo = hi = b.pos; return; }
    lo = V3(1e30f, 1e30f, 1e30f); hi = V3(-1e30f, -1e30f, -1e30f);
    for (const Prim& p : prims) {
      V3 e;
      if (p.shape == ShapeType::Sphere) e = V3(p.half.x, p.half.x, p.half.x);
      else {
        V3 u[3]; axes(p.rot, u);
        for (int i = 0; i < 3; i++) e[i] = std::fabs(u[0][i]) * p.half.x + std::fabs(u[1][i]) * p.half.y + std::fabs(u[2][i]) * p.half.z;
      }
      for (int a = 0; a < 3; a++) { lo[a] = std::min(lo[a], p.pos[a] - e[a]); hi[a] = std::max(hi[a], p.pos[a] + e[a]); }
    }
    return;
  }
  if (b.d.shape == ShapeType::Sphere) {
    V3 r(b.d.half.x, b.d.half.x, b.d.half.x);
    lo = b.pos - r; hi = b.pos + r;
    return;
  }
  V3 u[3];
  axes(b.rot, u);
  V3 e;
  for (int i = 0; i < 3; i++)
    e[i] = std::fabs(u[0][i]) * b.d.half.x + std::fabs(u[1][i]) * b.d.half.y + std::fabs(u[2][i]) * b.d.half.z;
  lo = b.pos - e; hi = b.pos + e;
}

// ---------------------------------------------------------------- narrow phase

static bool sphereSphere(const V3& ca, float ra, const V3& cb, float rb, V3& n, V3& p, float& depth) {
  V3 d = cb - ca;
  float l2 = len2(d), rs = ra + rb;
  if (l2 > rs * rs) return false;
  float l = std::sqrt(l2);
  n = l > 1e-6f ? d * (1 / l) : V3(0, 1, 0);
  depth = rs - l;
  p = ca + n * (ra - depth * 0.5f);
  return true;
}

// Normal points from the sphere toward the box.
static bool sphereBox(const V3& sc, float r, const OBB& b, V3& n, V3& p, float& depth) {
  V3 d = sc - b.c;
  V3 loc(dot(d, b.u[0]), dot(d, b.u[1]), dot(d, b.u[2]));
  V3 cl;
  bool inside = true;
  for (int i = 0; i < 3; i++) {
    cl[i] = std::max(-b.h[i], std::min(b.h[i], loc[i]));
    if (cl[i] != loc[i]) inside = false;
  }
  if (!inside) {
    V3 w = b.c + b.u[0] * cl.x + b.u[1] * cl.y + b.u[2] * cl.z;
    V3 diff = w - sc;
    float l2 = len2(diff);
    if (l2 > r * r) return false;
    float l = std::sqrt(l2);
    n = l > 1e-7f ? diff * (1 / l) : V3(0, -1, 0);
    depth = r - l;
    p = w;
    return true;
  }
  int ax = 0;
  float best = 1e30f;
  for (int i = 0; i < 3; i++) {
    float pen = b.h[i] - std::fabs(loc[i]);
    if (pen < best) { best = pen; ax = i; }
  }
  float s = loc[ax] >= 0 ? 1.0f : -1.0f;
  n = b.u[ax] * (-s);
  depth = r + best;
  p = sc + n * (r - depth * 0.5f);
  return true;
}

static int genFaceContacts(const OBB& ref, int ri, const V3& nRef, const OBB& inc, V3* outP, float* outDepth) {
  int ij = 0;
  float md = -1;
  for (int j = 0; j < 3; j++) {
    float dd = std::fabs(dot(inc.u[j], nRef));
    if (dd > md) { md = dd; ij = j; }
  }
  float sg = dot(inc.u[ij], nRef) > 0 ? -1.0f : 1.0f;
  int k = (ij + 1) % 3, l = (ij + 2) % 3;
  V3 fc = inc.c + inc.u[ij] * (sg * inc.h[ij]);
  V3 e1 = inc.u[k] * inc.h[k], e2 = inc.u[l] * inc.h[l];
  V3 bufA[16], bufB[16];
  bufA[0] = fc + e1 + e2; bufA[1] = fc - e1 + e2; bufA[2] = fc - e1 - e2; bufA[3] = fc + e1 - e2;
  int n = 4;
  V3* cur = bufA;
  V3* nxt = bufB;
  for (int s = 1; s <= 2; s++) {
    int ax = (ri + s) % 3;
    for (int sign = -1; sign <= 1; sign += 2) {
      V3 pn = ref.u[ax] * (float)sign;
      float off = dot(ref.c, pn) + ref.h[ax];
      n = clipPoly(cur, n, pn, off, nxt);
      std::swap(cur, nxt);
      if (n == 0) return 0;
    }
  }
  V3 faceP = ref.c + nRef * ref.h[ri];
  int cnt = 0;
  for (int i = 0; i < n && cnt < 8; i++) {
    float sep = dot(cur[i] - faceP, nRef);
    if (sep <= 0.0f) {
      outP[cnt] = cur[i] - nRef * (sep * 0.5f);
      outDepth[cnt] = -sep;
      cnt++;
    }
  }
  return cnt;
}

static bool boxBox(const OBB& A, const OBB& B, V3& nOut, V3* ps, float* ds, int& cnt) {
  V3 d = B.c - A.c;
  float bestScore = 1e30f, bestOv = 0;
  int bestIdx = -1;
  V3 bestAxis;
  auto test = [&](const V3& raw, int idx, bool edge) -> bool {
    float l = len(raw);
    if (l < 1e-5f) return true;
    V3 a = raw * (1 / l);
    float rA = std::fabs(dot(A.u[0], a)) * A.h.x + std::fabs(dot(A.u[1], a)) * A.h.y + std::fabs(dot(A.u[2], a)) * A.h.z;
    float rB = std::fabs(dot(B.u[0], a)) * B.h.x + std::fabs(dot(B.u[1], a)) * B.h.y + std::fabs(dot(B.u[2], a)) * B.h.z;
    float dd = dot(d, a);
    float ov = rA + rB - std::fabs(dd);
    if (ov < 0) return false;
    float score = edge ? ov * 1.05f + 0.002f : ov;
    if (score < bestScore) {
      bestScore = score; bestOv = ov; bestIdx = idx;
      bestAxis = dd < 0 ? -a : a;
    }
    return true;
  };
  for (int i = 0; i < 3; i++) if (!test(A.u[i], i, false)) return false;
  for (int i = 0; i < 3; i++) if (!test(B.u[i], 3 + i, false)) return false;
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++)
      if (!test(cross(A.u[i], B.u[j]), 6 + i * 3 + j, true)) return false;
  if (bestIdx < 0) return false;
  nOut = bestAxis;
  if (bestIdx < 6) {
    if (bestIdx < 3) cnt = genFaceContacts(A, bestIdx, bestAxis, B, ps, ds);
    else cnt = genFaceContacts(B, bestIdx - 3, -bestAxis, A, ps, ds);
    if (cnt == 0) {  // numerical corner case: single contact at box centers midpoint
      ps[0] = (A.c + B.c) * 0.5f; ds[0] = bestOv; cnt = 1;
    }
    return true;
  }
  int i = (bestIdx - 6) / 3, j = (bestIdx - 6) % 3;
  V3 pA = A.c, pB = B.c;
  for (int k = 0; k < 3; k++) {
    if (k != i) pA += A.u[k] * ((dot(A.u[k], bestAxis) > 0 ? 1.0f : -1.0f) * A.h[k]);
    if (k != j) pB += B.u[k] * ((dot(B.u[k], bestAxis) > 0 ? -1.0f : 1.0f) * B.h[k]);
  }
  const V3& dA = A.u[i];
  const V3& dB = B.u[j];
  V3 r = pA - pB;
  float b = dot(dA, dB), dd = dot(dA, r), e = dot(dB, r);
  float den = 1 - b * b;
  float s = den > 1e-6f ? (b * e - dd) / den : 0.0f;
  float t = den > 1e-6f ? (e - b * dd) / den : 0.0f;
  ps[0] = (pA + dA * s + pB + dB * t) * 0.5f;
  ds[0] = bestOv;
  cnt = 1;
  return true;
}

bool PhysicsWorld::collideMeshBodies(const Body& A, const Body& B, int ia, int ib, Manifold& m) const {
  bool aMesh = A.d.shape == ShapeType::Mesh;
  const Body& M = aMesh ? A : B;
  const Body& X = aMesh ? B : A;
  if (X.d.shape == ShapeType::Mesh) return false;
  if (M.d.triMesh < 0 || M.d.triMesh >= (int)triMeshes_.size()) return false;
  const TriMesh& tm = triMeshes_[M.d.triMesh];
  Q inv = conj(M.rot);
  auto toLocal = [&](const V3& p) { return rotate(inv, p - M.pos); };

  // Fast bodies would jump through a thin surface in one step. So also report
  // surfaces that are a little way off (a "gap", as a negative depth); the
  // solver lets the body close that gap but not more.
  float spd = len(X.linVel) + len(X.angVel) * std::max({X.d.half.x, X.d.half.y, X.d.half.z});
  float margin = std::min(1.0f, spd * stepDt_ + 0.02f);

  // triangles near the other body (its world box, moved into mesh space)
  V3 wlo, whi;
  aabb(X, wlo, whi);
  V3 qlo(1e30f, 1e30f, 1e30f), qhi(-1e30f, -1e30f, -1e30f);
  for (int i = 0; i < 8; i++) {
    V3 c((i & 1) ? whi.x : wlo.x, (i & 2) ? whi.y : wlo.y, (i & 4) ? whi.z : wlo.z);
    V3 l = toLocal(c);
    for (int a = 0; a < 3; a++) { qlo[a] = std::min(qlo[a], l[a]); qhi[a] = std::max(qhi[a], l[a]); }
  }
  float grow = margin + 0.05f;
  qlo = qlo - V3(grow, grow, grow);
  qhi = qhi + V3(grow, grow, grow);
  std::vector<int> tris;
  tm.query(qlo, qhi, tris);
  if (tris.empty()) return false;

  struct C { V3 p, n; float depth; };
  std::vector<C> found;
  V3 centerLocal = toLocal(X.pos);
  auto probe = [&](const V3& pw, float radius) {
    V3 pl = toLocal(pw);
    for (int t : tris) {
      V3 a, b, c; tm.tri(t, a, b, c);
      V3 cp = closestPointOnTriangle(pl, a, b, c);
      V3 d = pl - cp;
      float l2 = len2(d);
      if (l2 > (radius + margin) * (radius + margin)) continue;
      float l = std::sqrt(l2);
      V3 n;
      if (l > 1e-5f) n = d * (1.0f / l);
      else {
        n = norm(cross(b - a, c - a));
        if (dot(n, centerLocal - cp) < 0) n = -n;
      }
      found.push_back({M.pos + rotate(M.rot, cp), rotate(M.rot, n), radius - l});
    }
  };
  if (X.d.shape == ShapeType::Sphere) {
    probe(X.pos, X.d.half.x);
  } else {
    // A box touches a mesh with its corners, edge middles and face centers.
    // Each is a small ball (a skin of 2 cm). This is an approximation.
    V3 u[3];
    axes(X.rot, u);
    for (int sx = -1; sx <= 1; sx++)
      for (int sy = -1; sy <= 1; sy++)
        for (int sz = -1; sz <= 1; sz++) {
          if (sx == 0 && sy == 0 && sz == 0) continue;
          V3 p = X.pos + u[0] * (X.d.half.x * sx) + u[1] * (X.d.half.y * sy) + u[2] * (X.d.half.z * sz);
          probe(p, 0.02f);
        }
  }
  if (found.empty()) return false;
  std::sort(found.begin(), found.end(), [](const C& x, const C& y) { return x.depth > y.depth; });
  int cnt = std::min<int>(8, (int)found.size());
  V3 nsum;
  for (int i = 0; i < cnt; i++) nsum += found[i].n * (std::max(found[i].depth, 0.0f) + 0.001f);
  V3 n = len2(nsum) > 1e-12f ? norm(nsum) : found[0].n;  // from mesh toward the other body
  m.a = ia; m.b = ib; m.n = cnt;
  m.normal = aMesh ? n : -n;                              // solver wants a -> b
  for (int i = 0; i < cnt; i++) m.c[i] = {found[i].p, found[i].depth};
  return true;
}

bool PhysicsWorld::rayTriMesh(const Body& b, const V3& o, const V3& d, float maxT, float& t, V3& n) const {
  if (b.d.triMesh < 0 || b.d.triMesh >= (int)triMeshes_.size()) return false;
  Q inv = conj(b.rot);
  V3 nl;
  if (!triMeshes_[b.d.triMesh].raycast(rotate(inv, o - b.pos), rotate(inv, d), maxT, t, nl)) return false;
  n = rotate(b.rot, nl);
  return true;
}


void PhysicsWorld::primitivesOfBody(const Body& b, std::vector<Prim>& out) const {
  auto addCapsule = [&](V3 half, V3 p, Q q) {
    float r = half.x, hh = half.y;
    int n = hh <= 1e-6f ? 1 : std::min(32, std::max(2, (int)std::ceil(2 * hh / (0.5f * std::max(r, 1e-4f))) + 1));
    for (int i = 0; i < n; i++) {
      float t = n == 1 ? 0.0f : -hh + 2 * hh * i / (n - 1);
      out.push_back({ShapeType::Sphere, V3(r, r, r), p + rotate(q, V3(0, t, 0)), q});
    }
  };
  if (b.d.shape == ShapeType::Capsule) { addCapsule(b.d.half, b.pos, b.rot); return; }
  if (b.d.shape == ShapeType::Compound) {
    for (const ChildShape& c : b.d.children) {
      V3 wp = b.pos + rotate(b.rot, c.pos); Q wq = b.rot * c.rot;
      if (c.shape == ShapeType::Capsule) addCapsule(c.half, wp, wq);
      else out.push_back({c.shape, c.half, wp, wq});
    }
    return;
  }
  out.push_back({b.d.shape, b.d.half, b.pos, b.rot});
}

// Capsules are rows of overlapping spheres and compounds are several shapes: collide every part of one with
// every part of the other (using local temporary Body objects without mutating bodies_) and merge contacts.
bool PhysicsWorld::collideCompositeBodies(const Body& A, const Body& B, int ia, int ib, Manifold& m) const {
  std::vector<Body> tempA, tempB;
  std::vector<const Body*> la, lb;
  auto expand = [&](const Body& b, std::vector<Body>& storage, std::vector<const Body*>& out) {
    if (b.d.shape != ShapeType::Capsule && b.d.shape != ShapeType::Compound) {
      out.push_back(&b);
      return;
    }
    std::vector<Prim> prims;
    primitivesOfBody(b, prims);
    storage.reserve(prims.size());
    for (const Prim& p : prims) {
      Body t;
      t.alive = true;
      t.d.shape = p.shape; t.d.half = p.half; t.d.mass = 0;
      t.pos = p.pos; t.rot = p.rot;
      storage.push_back(t);
    }
    for (const Body& t : storage) out.push_back(&t);
  };
  expand(A, tempA, la);
  expand(B, tempB, lb);
  struct Hit { V3 n; V3 p; float d; };
  std::vector<Hit> hits;
  float bestDepth = 0; V3 bestN;
  for (const Body* x : la) for (const Body* y : lb) {
    Manifold mm;
    if (!collideBodies(*x, *y, ia, ib, mm) || mm.n == 0) continue;
    for (int k = 0; k < mm.n; k++) {
      hits.push_back({mm.normal, mm.c[k].p, mm.c[k].depth});
      if (mm.c[k].depth > bestDepth) { bestDepth = mm.c[k].depth; bestN = mm.normal; }
    }
  }
  if (hits.empty() || bestDepth <= 0) return false;
  std::vector<Hit> use;
  for (const Hit& h : hits) if (dot(h.n, bestN) > 0.8f) use.push_back(h);
  std::sort(use.begin(), use.end(), [](const Hit& a, const Hit& b) { return a.d > b.d; });
  m.a = ia; m.b = ib; m.normal = bestN; m.n = 0;
  for (const Hit& h : use) {
    if (m.n >= 8) break;
    bool near = false;   // skip contacts that sit almost on top of one we already have
    for (int k = 0; k < m.n; k++) if (len2(m.c[k].p - h.p) < 1e-4f) near = true;
    if (near) continue;
    m.c[m.n++] = {h.p, h.d};
  }
  return m.n > 0;
}


// ---- ConvexHull GJK + EPA collision ----
namespace {
struct GjkSup {
  V3 p;   // Minkowski difference point (a - b)
  V3 a;   // support on A
  V3 b;   // support on B
};

V3 supportBodyWorld(const Body& b, const V3& dir) {
  V3 localDir = rotate(conj(b.rot), dir);
  V3 localP;
  if (b.d.shape == ShapeType::ConvexHull && !b.d.hullVerts.empty()) {
    float best = -1e30f;
    localP = b.d.hullVerts[0];
    for (const V3& v : b.d.hullVerts) {
      float d = dot(v, localDir);
      if (d > best) { best = d; localP = v; }
    }
  } else if (b.d.shape == ShapeType::Sphere) {
    float l = len(localDir);
    localP = l > 1e-8f ? localDir * (b.d.half.x / l) : V3(b.d.half.x, 0, 0);
  } else if (b.d.shape == ShapeType::Capsule) {
    float l = len(localDir);
    V3 s = l > 1e-8f ? localDir * (b.d.half.x / l) : V3(b.d.half.x, 0, 0);
    s.y += (localDir.y >= 0 ? b.d.half.y : -b.d.half.y);
    localP = s;
  } else {
    localP = V3(
      localDir.x >= 0 ? b.d.half.x : -b.d.half.x,
      localDir.y >= 0 ? b.d.half.y : -b.d.half.y,
      localDir.z >= 0 ? b.d.half.z : -b.d.half.z
    );
  }
  return b.pos + rotate(b.rot, localP);
}

GjkSup gjkSupport(const Body& A, const Body& B, const V3& dir) {
  V3 d = len2(dir) > 1e-12f ? norm(dir) : V3(1, 0, 0);
  V3 sa = supportBodyWorld(A, d);
  V3 sb = supportBodyWorld(B, -d);
  return {sa - sb, sa, sb};
}

bool handleSimplex(GjkSup s[4], int& n, V3& dir) {
  if (n == 2) {
    V3 a = s[1].p, b = s[0].p;
    V3 ab = b - a, ao = -a;
    if (dot(ab, ao) > 0) {
      dir = cross(cross(ab, ao), ab);
      if (len2(dir) < 1e-12f) dir = cross(ab, std::fabs(ab.x) < 0.9f ? V3(1,0,0) : V3(0,1,0));
    } else {
      s[0] = s[1]; n = 1; dir = ao;
    }
    return false;
  }
  if (n == 3) {
    V3 a = s[2].p, b = s[1].p, c = s[0].p;
    V3 ab = b - a, ac = c - a, ao = -a;
    V3 abc = cross(ab, ac);
    if (dot(cross(abc, ac), ao) > 0) {
      if (dot(ac, ao) > 0) { s[1] = s[2]; n = 2; dir = cross(cross(ac, ao), ac); }
      else { s[0] = s[2]; n = 1; dir = ao; }
    } else if (dot(cross(ab, abc), ao) > 0) {
      if (dot(ab, ao) > 0) { s[0] = s[1]; s[1] = s[2]; n = 2; dir = cross(cross(ab, ao), ab); }
      else { s[0] = s[2]; n = 1; dir = ao; }
    } else {
      if (dot(abc, ao) > 0) { dir = abc; }
      else { std::swap(s[0], s[1]); dir = -abc; }
    }
    return false;
  }
  // n == 4: tetrahedron
  V3 a = s[3].p, b = s[2].p, c = s[1].p, d = s[0].p;
  V3 ab = b - a, ac = c - a, ad = d - a, ao = -a;
  V3 abc = cross(ab, ac);
  V3 acd = cross(ac, ad);
  V3 adb = cross(ad, ab);
  if (dot(abc, ao) > 0) { s[0] = s[1]; s[1] = s[2]; s[2] = s[3]; n = 3; dir = abc; return false; }
  if (dot(acd, ao) > 0) { s[2] = s[3]; n = 3; dir = acd; return false; }
  if (dot(adb, ao) > 0) { s[1] = s[0]; s[0] = s[2]; s[2] = s[3]; n = 3; dir = adb; return false; }
  return true;
}

bool gjkEpaCollide(const Body& A, const Body& B, V3& outNormal, V3& outPoint, float& outDepth) {
  V3 dir = B.pos - A.pos;
  if (len2(dir) < 1e-10f) dir = V3(0, 1, 0);
  GjkSup simp[4];
  simp[0] = gjkSupport(A, B, dir);
  int n = 1;
  dir = -simp[0].p;
  bool hit = false;
  for (int it = 0; it < 32; it++) {
    if (len2(dir) < 1e-12f) { hit = true; break; }
    GjkSup sup = gjkSupport(A, B, dir);
    if (dot(sup.p, dir) < 0) return false;
    simp[n++] = sup;
    if (handleSimplex(simp, n, dir)) { hit = true; break; }
  }
  if (!hit) return false;

  // Ensure 4-point simplex for EPA
  static const V3 kDirs[6] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
  for (int k = 0; k < 6 && n < 4; k++) {
    GjkSup sup = gjkSupport(A, B, kDirs[k]);
    bool dup = false;
    for (int j = 0; j < n; j++) if (len2(sup.p - simp[j].p) < 1e-6f) dup = true;
    if (!dup) simp[n++] = sup;
  }
  if (n < 4) return false;

  struct Face { int i0, i1, i2; V3 n; float d; };
  std::vector<GjkSup> verts(simp, simp + 4);
  std::vector<Face> faces;
  auto makeFace = [&](int i0, int i1, int i2) {
    V3 a = verts[i0].p, b = verts[i1].p, c = verts[i2].p;
    V3 fn = cross(b - a, c - a);
    float l = len(fn);
    if (l < 1e-9f) return;
    fn = fn * (1.0f / l);
    float fd = dot(fn, a);
    if (fd < 0) { std::swap(i1, i2); fn = -fn; fd = -fd; }
    faces.push_back({i0, i1, i2, fn, fd});
  };
  makeFace(0, 1, 2); makeFace(0, 2, 3); makeFace(0, 3, 1); makeFace(1, 3, 2);
  if (faces.empty()) return false;

  int bestIdx = 0;
  for (int it = 0; it < 32; it++) {
    bestIdx = 0;
    for (int i = 1; i < (int)faces.size(); i++) {
      if (faces[i].d < faces[bestIdx].d) bestIdx = i;
    }
    Face best = faces[bestIdx];
    GjkSup sup = gjkSupport(A, B, best.n);
    float sd = dot(sup.p, best.n);
    if (sd - best.d < 1e-4f || verts.size() >= 64) {
      outNormal = best.n;
      outDepth = std::max(0.0f, best.d);
      // Barycentric contact point estimate on face
      V3 p = best.n * best.d;
      V3 a = verts[best.i0].p, b = verts[best.i1].p, c = verts[best.i2].p;
      V3 v0 = b - a, v1 = c - a, v2 = p - a;
      float d00 = dot(v0, v0), d01 = dot(v0, v1), d11 = dot(v1, v1);
      float d20 = dot(v2, v0), d21 = dot(v2, v1);
      float denom = d00 * d11 - d01 * d01;
      float v = 1.0f / 3.0f, w = 1.0f / 3.0f;
      if (std::fabs(denom) > 1e-9f) {
        v = (d11 * d20 - d01 * d21) / denom;
        w = (d00 * d21 - d01 * d20) / denom;
      }
      float u = 1.0f - v - w;
      V3 ptA = verts[best.i0].a * u + verts[best.i1].a * v + verts[best.i2].a * w;
      V3 ptB = verts[best.i0].b * u + verts[best.i1].b * v + verts[best.i2].b * w;
      outPoint = (ptA + ptB) * 0.5f;
      return outDepth > 0.0f;
    }
    int newIdx = (int)verts.size();
    verts.push_back(sup);
    std::vector<std::pair<int,int>> edges;
    auto addEdge = [&](int u, int v) {
      for (auto itE = edges.begin(); itE != edges.end(); ++itE) {
        if (itE->first == v && itE->second == u) { edges.erase(itE); return; }
      }
      edges.push_back({u, v});
    };
    std::vector<Face> kept;
    for (const Face& f : faces) {
      if (dot(f.n, sup.p - verts[f.i0].p) > 0) {
        addEdge(f.i0, f.i1); addEdge(f.i1, f.i2); addEdge(f.i2, f.i0);
      } else {
        kept.push_back(f);
      }
    }
    faces.swap(kept);
    for (auto& e : edges) makeFace(e.first, e.second, newIdx);
    if (faces.empty()) return false;
  }
  if (faces.empty()) return false;
  bestIdx = 0;
  for (int i = 1; i < (int)faces.size(); i++) {
    if (faces[i].d < faces[bestIdx].d) bestIdx = i;
  }
  Face best = faces[bestIdx];
  outNormal = best.n;
  outDepth = std::max(0.0f, best.d);
  outPoint = (A.pos + B.pos) * 0.5f;
  return outDepth > 0.0f;
}
}  // namespace

bool PhysicsWorld::collide(int ia, int ib, Manifold& m) {
  return collideBodies(bodies_[ia], bodies_[ib], ia, ib, m);
}

bool PhysicsWorld::collideBodies(const Body& A, const Body& B, int ia, int ib, Manifold& m) const {
  if (A.d.shape == ShapeType::Capsule || A.d.shape == ShapeType::Compound ||
      B.d.shape == ShapeType::Capsule || B.d.shape == ShapeType::Compound) {
    return collideCompositeBodies(A, B, ia, ib, m);
  }
  if (A.d.shape == ShapeType::Mesh || B.d.shape == ShapeType::Mesh) return collideMeshBodies(A, B, ia, ib, m);
  m.a = ia; m.b = ib; m.n = 0;
  if (A.d.shape == ShapeType::ConvexHull || B.d.shape == ShapeType::ConvexHull) {
    V3 n, p; float dp;
    if (!gjkEpaCollide(A, B, n, p, dp)) return false;
    m.normal = n;
    // Build a stable multi-point (up to 4) face-face contact manifold so stacked hulls do not wobble/sink!
    V3 t1 = std::fabs(n.y) < 0.9f ? norm(cross(n, V3(0, 1, 0))) : norm(cross(n, V3(1, 0, 0)));
    V3 t2 = cross(n, t1);
    auto collectFacePts = [](const Body& Bdy, const V3& dir, std::vector<V3>& out) {
      auto getVerts = [&](std::vector<V3>& localV) {
        if (Bdy.d.shape == ShapeType::ConvexHull && !Bdy.d.hullVerts.empty()) {
          localV = Bdy.d.hullVerts;
        } else if (Bdy.d.shape == ShapeType::Box) {
          V3 h = Bdy.d.half;
          for (int sx = -1; sx <= 1; sx += 2)
            for (int sy = -1; sy <= 1; sy += 2)
              for (int sz = -1; sz <= 1; sz += 2)
                localV.push_back(V3(sx * h.x, sy * h.y, sz * h.z));
        }
      };
      std::vector<V3> lv;
      getVerts(lv);
      if (lv.empty()) return;
      float maxD = -1e30f;
      std::vector<V3> wv; wv.reserve(lv.size());
      for (const V3& v : lv) {
        V3 wp = Bdy.pos + rotate(Bdy.rot, v);
        wv.push_back(wp);
        float d = dot(wp, dir);
        if (d > maxD) maxD = d;
      }
      for (const V3& wp : wv) {
        if (dot(wp, dir) >= maxD - 0.025f) out.push_back(wp);
      }
    };
    std::vector<V3> fA, fB;
    collectFacePts(A, n, fA);
    collectFacePts(B, -n, fB);
    auto bounds2 = [&](const std::vector<V3>& pts, float& uMin, float& uMax, float& vMin, float& vMax) {
      uMin = vMin = 1e30f; uMax = vMax = -1e30f;
      for (const V3& q : pts) {
        float u = dot(q, t1), v = dot(q, t2);
        if (u < uMin) uMin = u;
        if (u > uMax) uMax = u;
        if (v < vMin) vMin = v;
        if (v > vMax) vMax = v;
      }
    };
    if (!fA.empty() && !fB.empty()) {
      float au0, au1, av0, av1, bu0, bu1, bv0, bv1;
      bounds2(fA, au0, au1, av0, av1);
      bounds2(fB, bu0, bu1, bv0, bv1);
      float ou0 = std::max(au0, bu0) - 0.02f, ou1 = std::min(au1, bu1) + 0.02f;
      float ov0 = std::max(av0, bv0) - 0.02f, ov1 = std::min(av1, bv1) + 0.02f;
      auto tryAdd = [&](const V3& pt) {
        if (m.n >= 4) return;
        float u = dot(pt, t1), v = dot(pt, t2);
        if (u < ou0 || u > ou1 || v < ov0 || v > ov1) return;
        for (int k = 0; k < m.n; k++) if (len2(m.c[k].p - pt) < 0.01f) return;
        m.c[m.n++] = {pt, dp};
      };
      for (const V3& q : fA) tryAdd(q);
      for (const V3& q : fB) tryAdd(q);
    }
    if (m.n == 0) { m.c[0] = {p, dp}; m.n = 1; }
    return true;
  }
  bool sa = A.d.shape == ShapeType::Sphere, sb = B.d.shape == ShapeType::Sphere;
  if (sa && sb) {
    V3 n, p; float dp;
    if (!sphereSphere(A.pos, A.d.half.x, B.pos, B.d.half.x, n, p, dp)) return false;
    m.normal = n; m.c[0] = {p, dp}; m.n = 1;
    return true;
  }
  if (sa != sb) {
    const Body& S = sa ? A : B;
    const Body& X = sa ? B : A;
    OBB ob = makeObb(X);
    V3 n, p; float dp;
    if (!sphereBox(S.pos, S.d.half.x, ob, n, p, dp)) return false;
    m.normal = sa ? n : -n;
    m.c[0] = {p, dp}; m.n = 1;
    return true;
  }
  OBB oa = makeObb(A), ob = makeObb(B);
  V3 ps[16]; float ds[16]; int cnt = 0; V3 n;
  if (!boxBox(oa, ob, n, ps, ds, cnt)) return false;
  m.normal = n;
  m.n = std::min(cnt, 8);
  for (int i = 0; i < m.n; i++) m.c[i] = {ps[i], ds[i]};
  return true;
}

// ---------------------------------------------------------------- raycast

static bool rayBody(const Body& b, const V3& o, const V3& d, float maxT, float& t, V3& n) {
  if (b.d.shape == ShapeType::Sphere) {
    V3 m = o - b.pos;
    float r = b.d.half.x;
    float bb = dot(m, d), c = dot(m, m) - r * r;
    if (c > 0 && bb > 0) return false;
    float disc = bb * bb - c;
    if (disc < 0) return false;
    float tt = -bb - std::sqrt(disc);
    if (tt < 0) return false;
    if (tt > maxT) return false;
    t = tt;
    n = norm(o + d * tt - b.pos);
    return true;
  }
  V3 u[3];
  axes(b.rot, u);
  V3 rel = o - b.pos;
  float tmin = 0, tmax = maxT;
  int hitAxis = -1;
  float hitSign = 1;
  for (int i = 0; i < 3; i++) {
    float po = dot(rel, u[i]), pd = dot(d, u[i]), h = b.d.half[i];
    if (std::fabs(pd) < 1e-9f) {
      if (po < -h || po > h) return false;
      continue;
    }
    float t1 = (-h - po) / pd, t2 = (h - po) / pd;
    float sgn = -1;
    if (t1 > t2) { std::swap(t1, t2); sgn = 1; }
    if (t1 > tmin) { tmin = t1; hitAxis = i; hitSign = sgn; }
    tmax = std::min(tmax, t2);
    if (tmin > tmax) return false;
  }
  if (hitAxis < 0) return false;  // origin inside
  t = tmin;
  n = u[hitAxis] * hitSign;
  return true;
}

bool PhysicsWorld::raycast(const V3& o, const V3& dirIn, float maxDist, uint32_t mask, int ignore, RayHit& hit) {
  V3 d = norm(dirIn);
  bool any = false;
  float best = maxDist;
  for (int i = 0; i < (int)bodies_.size(); i++) {
    const Body& b = bodies_[i];
    if (!b.alive || i == ignore || i == worldBody_ || b.d.sensor) continue;
    if (!(mask & (1u << b.d.layer))) continue;
    V3 lo, hi;
    aabb(b, lo, hi);
    // slab test on the AABB first
    float t0 = 0, t1 = best;
    bool ok = true;
    for (int k = 0; k < 3 && ok; k++) {
      if (std::fabs(d[k]) < 1e-9f) { if (o[k] < lo[k] || o[k] > hi[k]) ok = false; }
      else {
        float a = (lo[k] - o[k]) / d[k], c = (hi[k] - o[k]) / d[k];
        if (a > c) std::swap(a, c);
        t0 = std::max(t0, a); t1 = std::min(t1, c);
        if (t0 > t1) ok = false;
      }
    }
    if (!ok) continue;
    float t; V3 n;
    bool got;
    if (b.d.shape == ShapeType::Capsule || b.d.shape == ShapeType::Compound) {
      got = false;
      std::vector<Prim> prims;
      primitivesOfBody(b, prims);
      for (const Prim& p : prims) {
        Body tmp; tmp.alive = true; tmp.d.shape = p.shape; tmp.d.half = p.half; tmp.pos = p.pos; tmp.rot = p.rot;
        float tt; V3 nn;
        if (rayBody(tmp, o, d, best, tt, nn) && (!got || tt < t)) { t = tt; n = nn; got = true; }
      }
    } else {
      got = b.d.shape == ShapeType::Mesh ? rayTriMesh(b, o, d, best, t, n) : rayBody(b, o, d, best, t, n);
    }
    if (got && t <= best) {
      best = t; any = true;
      hit.body = i; hit.t = t; hit.normal = n; hit.point = o + d * t;
    }
  }
  return any;
}

// ---------------------------------------------------------------- step

void PhysicsWorld::step(float dt) {
  if (dt <= 0) return;
  stepDt_ = dt;
  events_.clear();
  const int N = (int)bodies_.size();

  // 1. forces -> velocities
  for (auto& b : bodies_) {
    if (!b.alive || !b.isDynamic() || b.sleeping) continue;
    b.linVel += (gravity * b.d.gravityScale + b.force * b.invMass) * dt;
    b.angVel += mulInvI(b, b.torque) * dt;
    b.linVel *= 1.0f / (1.0f + b.d.linearDamping * dt);
    b.angVel *= 1.0f / (1.0f + b.d.angularDamping * dt);
    b.force = V3(); b.torque = V3();
  }

  // 2. broad phase: sweep and prune on X
  sap_.clear();
  for (int i = 0; i < N; i++) {
    if (!bodies_[i].alive) continue;
    V3 lo, hi; aabb(bodies_[i], lo, hi);
    sap_.push_back({lo.x, i});
  }
  std::sort(sap_.begin(), sap_.end());

  std::vector<Manifold> manifolds;
  std::unordered_set<uint64_t> nowTouching;
  for (size_t si = 0; si < sap_.size(); si++) {
    int ia = sap_[si].second;
    Body& A = bodies_[ia];
    V3 alo, ahi; aabb(A, alo, ahi);
    for (size_t sj = si + 1; sj < sap_.size(); sj++) {
      if (sap_[sj].first > ahi.x + 1.0f) break;
      int ib = sap_[sj].second;
      Body& B = bodies_[ib];
      bool aActive = A.isDynamic() && !A.sleeping, bActive = B.isDynamic() && !B.sleeping;
      bool aMove = aActive || A.d.kinematic, bMove = bActive || B.d.kinematic;
      if (!aMove && !bMove) continue;
      if (!(A.d.mask & (1u << B.d.layer)) || !(B.d.mask & (1u << A.d.layer))) continue;
      if (!noCollide_.empty() && noCollide_.count(pairKey(ia, ib))) continue;
      V3 blo, bhi; aabb(B, blo, bhi);
      // A mesh has no thickness: let bodies near it count as touching, so that
      // fast bodies are caught before they go through (see collideMeshBodies).
      float fat = 0.0f;
      if (A.d.shape == ShapeType::Mesh || B.d.shape == ShapeType::Mesh) {
        const Body& X = A.d.shape == ShapeType::Mesh ? B : A;
        float sp = len(X.linVel) + len(X.angVel) * std::max({X.d.half.x, X.d.half.y, X.d.half.z});
        fat = std::min(1.0f, sp * dt + 0.1f);
      }
      if (alo.y > bhi.y + fat || ahi.y < blo.y - fat || alo.z > bhi.z + fat || ahi.z < blo.z - fat || blo.x > ahi.x + fat) continue;
      Manifold m;
      if (!collide(ia, ib, m)) continue;
      int lo = std::min(ia, ib), hi = std::max(ia, ib);
      uint64_t key = pairKey(lo, hi);
      nowTouching.insert(key);
      bool sensor = A.d.sensor || B.d.sensor;
      if (!touching_.count(key)) events_.push_back({lo, hi, 0, sensor ? 1 : 0});
      if (sensor) continue;
      const float kWakeLin2 = 0.04f, kWakeAng2 = 0.06f;
      if (A.sleeping && B.isDynamic() && bActive && (len2(B.linVel) > kWakeLin2 || len2(B.angVel) > kWakeAng2)) wake(ia);
      if (B.sleeping && A.isDynamic() && aActive && (len2(A.linVel) > kWakeLin2 || len2(A.angVel) > kWakeAng2)) wake(ib);
      manifolds.push_back(m);
    }
  }
  for (uint64_t key : touching_) {
    if (!nowTouching.count(key)) {
      int a = (int)(key >> 32), b = (int)(key & 0xffffffffu);
      bool sensor = (body(a) && body(a)->d.sensor) || (body(b) && body(b)->d.sensor);
      events_.push_back({a, b, 1, sensor ? 1 : 0});
    }
  }
  touching_.swap(nowTouching);

  // 3. prepare contact constraints
  std::vector<Solved> cs;
  for (auto& m : manifolds) {
    Body& A = bodies_[m.a];
    Body& B = bodies_[m.b];
    float mu = std::sqrt(A.d.friction * B.d.friction);
    float e = std::max(A.d.restitution, B.d.restitution);
    V3 n = m.normal;
    V3 t1 = std::fabs(n.x) > 0.57735f ? norm(cross(n, V3(0, 1, 0))) : norm(cross(n, V3(1, 0, 0)));
    V3 t2 = cross(n, t1);
    for (int i = 0; i < m.n; i++) {
      Solved s;
      s.a = m.a; s.b = m.b; s.n = n; s.t1 = t1; s.t2 = t2; s.mu = mu;
      s.rA = m.c[i].p - A.pos; s.rB = m.c[i].p - B.pos;
      auto eff = [&](const V3& dir) {
        V3 ra = cross(s.rA, dir), rb = cross(s.rB, dir);
        float k = A.invMass + B.invMass + dot(ra, mulInvI(A, ra)) + dot(rb, mulInvI(B, rb));
        return k > 1e-12f ? 1.0f / k : 0.0f;
      };
      s.mN = eff(n); s.mT1 = eff(t1); s.mT2 = eff(t2);
      V3 vr = velAt(B, m.c[i].p) - velAt(A, m.c[i].p);
      float vn = dot(vr, n);
      float bias = 0.2f / dt * std::max(m.c[i].depth - 0.005f, 0.0f);
      bias = std::min(bias, 6.0f);
      float rest = vn < -1.0f ? -e * vn : 0.0f;
      s.target = std::max(bias, rest);
      if (m.c[i].depth < 0) s.target = m.c[i].depth / dt;  // gap: may close it, no more
      cs.push_back(s);
    }
  }
  lastContacts_ = (int)cs.size();

  // 3b. joints
  std::vector<JointRow> jrows;
  prepareJoints(dt, jrows);

  // 4. solve
  auto applyImp = [&](Solved& s, const V3& P) {
    Body& A = bodies_[s.a];
    Body& B = bodies_[s.b];
    A.linVel -= P * A.invMass; A.angVel -= mulInvI(A, cross(s.rA, P));
    B.linVel += P * B.invMass; B.angVel += mulInvI(B, cross(s.rB, P));
  };
  for (int it = 0; it < solverIterations; it++) {
    for (auto& r : jrows) solveRow(r);
    for (auto& s : cs) {
      Body& A = bodies_[s.a];
      Body& B = bodies_[s.b];
      // friction first, then normal (normal has priority)
      V3 vr = (B.linVel + cross(B.angVel, s.rB)) - (A.linVel + cross(A.angVel, s.rA));
      float maxF = s.mu * s.jn;
      float l1 = -dot(vr, s.t1) * s.mT1;
      float n1 = std::max(-maxF, std::min(maxF, s.jt1 + l1));
      l1 = n1 - s.jt1; s.jt1 = n1;
      float l2 = -dot(vr, s.t2) * s.mT2;
      float n2 = std::max(-maxF, std::min(maxF, s.jt2 + l2));
      l2 = n2 - s.jt2; s.jt2 = n2;
      applyImp(s, s.t1 * l1 + s.t2 * l2);
      vr = (B.linVel + cross(B.angVel, s.rB)) - (A.linVel + cross(A.angVel, s.rA));
      float vn = dot(vr, s.n);
      float l = (s.target - vn) * s.mN;
      float nj = std::max(0.0f, s.jn + l);
      l = nj - s.jn; s.jn = nj;
      applyImp(s, s.n * l);
    }
  }

  // joint forces and breaking
  if (!jrows.empty()) {
    std::vector<float> sq(joints_.size(), 0.0f);
    for (auto& r : jrows) if (r.isForce) sq[r.joint] += r.block ? len2(r.impV) : r.imp * r.imp;
    for (size_t j = 0; j < joints_.size(); j++) {
      Joint& J = joints_[j];
      if (!J.alive) continue;
      J.lastForce = std::sqrt(sq[j]) / dt;
      if (J.d.breakForce > 0 && J.lastForce > J.d.breakForce) {
        J.alive = false;
        J.broken = true;
        if (!J.d.collideConnected) removeNoCollide(J.bodyA, J.bodyB);
      }
    }
  }

  // 5. integrate
  for (auto& b : bodies_) {
    if (!b.alive) continue;
    if (b.d.kinematic) {
      b.pos += b.linVel * dt;
      V3 w = b.angVel;
      if (len2(w) > 0.0f) {
        Q dq = Q(w.x, w.y, w.z, 0) * b.rot;
        b.rot = normalize(Q(b.rot.x + 0.5f * dt * dq.x, b.rot.y + 0.5f * dt * dq.y, b.rot.z + 0.5f * dt * dq.z, b.rot.w + 0.5f * dt * dq.w));
      }
      continue;
    }
    if (!b.isDynamic() || b.sleeping) continue;
    V3 stepDisp = b.linVel * dt;
    if (b.d.ccd) {
      float moveLen = len(stepDisp);
      float minExtent = (b.d.shape == ShapeType::Sphere || b.d.shape == ShapeType::Capsule)
                            ? b.d.half.x
                            : std::min(b.d.half.x, std::min(b.d.half.y, b.d.half.z));
      minExtent = std::max(1e-4f, minExtent);
      if (moveLen > std::max(0.05f, minExtent * 0.5f)) {
        RayHit rh;
        int selfId = (int)(&b - bodies_.data());
        if (raycast(b.pos, stepDisp * (1.0f / moveLen), moveLen + minExtent, b.d.mask, selfId, rh)) {
          float safeT = std::max(0.0f, rh.t - minExtent * 0.95f);
          stepDisp = stepDisp * (safeT / moveLen);
          float vn = dot(b.linVel, rh.normal);
          if (vn < 0) b.linVel -= rh.normal * ((1.0f + b.d.restitution) * vn);
        }
      }
    }
    b.pos += stepDisp;
    V3 w = b.angVel;
    Q dq = Q(w.x, w.y, w.z, 0) * b.rot;
    b.rot = normalize(Q(b.rot.x + 0.5f * dt * dq.x, b.rot.y + 0.5f * dt * dq.y, b.rot.z + 0.5f * dt * dq.z, b.rot.w + 0.5f * dt * dq.w));
    if (sleepingEnabled) {
      if (len2(b.linVel) < 0.0144f && len2(b.angVel) < 0.0225f) {
        b.sleepTimer += dt;
        if (b.sleepTimer > 0.55f) { b.sleeping = true; b.linVel = V3(); b.angVel = V3(); }
      } else {
        b.sleepTimer = std::max(0.0f, b.sleepTimer - dt * 2.0f);
      }
    }
  }
}

int PhysicsWorld::overlapSphere(const V3& c, float r, uint32_t mask, int ignore, SphereHit* out, int maxOut) {
  Body pb;
  pb.alive = true;
  pb.d.shape = ShapeType::Sphere;
  pb.d.half = V3(r, r, r);
  pb.d.mass = 0;
  pb.pos = c;
  int n = 0;
  const int count = (int)bodies_.size();
  for (int i = 0; i < count && n < maxOut; i++) {
    const Body& B = bodies_[i];
    if (!B.alive || i == ignore || i == worldBody_ || B.d.sensor) continue;
    if (!(mask & (1u << B.d.layer))) continue;
    Manifold m;
    if (!collideBodies(pb, B, -1, i, m)) continue;
    float dep = 0;
    for (int k = 0; k < m.n; k++) dep = std::max(dep, m.c[k].depth);
    if (dep <= 0) continue;
    out[n++] = {m.normal * -1.0f, dep, i};  // normal points probe -> body
  }
  return n;
}

// ---------------------------------------------------------------- joints

int PhysicsWorld::createJoint(const JointDesc& d) {
  auto ok = [&](int id) { return id >= 0 && id < (int)bodies_.size() && bodies_[id].alive; };
  if ((d.a >= 0 && !ok(d.a)) || (d.b >= 0 && !ok(d.b)) || (d.a < 0 && d.b < 0)) return -1;
  if (d.a >= 0 && d.a == d.b) return -1;
  if (d.a < 0 || d.b < 0) {   // the world: a hidden static body that collides with nothing
    if (worldBody_ < 0 || !bodies_[worldBody_].alive) {
      BodyDesc w;
      w.mass = 0; w.mask = 0; w.sensor = true; w.shape = ShapeType::Box; w.half = V3(0.01f, 0.01f, 0.01f);
      worldBody_ = createBody(w);
      aliveCount_--;   // not counted as one of your bodies
    }
  }
  Joint J;
  J.alive = true;
  J.d = d;
  J.bodyA = d.a >= 0 ? d.a : worldBody_;
  J.bodyB = d.b >= 0 ? d.b : worldBody_;
  const Body& A = bodies_[J.bodyA];
  const Body& B = bodies_[J.bodyB];
  V3 axisW = norm(d.a >= 0 ? rotate(A.rot, d.axis) : d.axis);
  if (len2(axisW) < 1e-8f) axisW = V3(0, 1, 0);
  J.axisA = rotate(conj(A.rot), axisW);
  J.axisB = rotate(conj(B.rot), axisW);
  V3 perp = std::fabs(axisW.y) < 0.9f ? cross(axisW, V3(0, 1, 0)) : cross(axisW, V3(1, 0, 0));
  perp = norm(perp);
  J.refA = rotate(conj(A.rot), perp);
  J.refB = rotate(conj(B.rot), perp);
  J.rel = conj(A.rot) * B.rot;
  joints_.push_back(J);
  if (!d.collideConnected) addNoCollide(J.bodyA, J.bodyB);
  for (int id : {J.bodyA, J.bodyB}) wake(id);
  return (int)joints_.size() - 1;
}

void PhysicsWorld::destroyJoint(int id) {
  if (id < 0 || id >= (int)joints_.size() || !joints_[id].alive) return;
  Joint& J = joints_[id];
  J.alive = false;
  if (!J.d.collideConnected) removeNoCollide(J.bodyA, J.bodyB);
}

float PhysicsWorld::jointAngle(int id) const {
  if (id < 0 || id >= (int)joints_.size()) return 0;
  const Joint& J = joints_[id];
  const Body& A = bodies_[J.bodyA];
  const Body& B = bodies_[J.bodyB];
  V3 ax = norm(rotate(A.rot, J.axisA));
  V3 ra = rotate(A.rot, J.refA), rb = rotate(B.rot, J.refB);
  return std::atan2(dot(cross(rb, ra), ax), dot(ra, rb));   // how far A is turned relative to B
}

void PhysicsWorld::prepareJoints(float dt, std::vector<JointRow>& rows) {
  const float beta = 0.2f, maxLin = 6.0f, maxAng = 6.0f;
  for (size_t ji = 0; ji < joints_.size(); ji++) {
    Joint& J = joints_[ji];
    if (!J.alive) continue;
    Body& A = bodies_[J.bodyA];
    Body& B = bodies_[J.bodyB];
    if (!A.alive || !B.alive) {
      J.alive = false;
      if (!J.d.collideConnected) removeNoCollide(J.bodyA, J.bodyB);
      continue;
    }
    // Joined bodies stay awake while the joint exists.
    if (A.isDynamic() && A.sleeping) wake(J.bodyA);
    if (B.isDynamic() && B.sleeping) wake(J.bodyB);
    if (A.isDynamic()) A.sleepTimer = 0;
    if (B.isDynamic()) B.sleepTimer = 0;
    const V3 rA = rotate(A.rot, J.d.anchorA), rB = rotate(B.rot, J.d.anchorB);
    const V3 pA = A.pos + rA, pB = B.pos + rB;
    auto addRow = [&](bool ang, const V3& dir, float target, float lo, float hi, bool isForce, float gamma = 0.0f) {
      JointRow r;
      r.a = J.bodyA; r.b = J.bodyB; r.joint = (int)ji; r.angular = ang; r.dir = dir; r.rA = rA; r.rB = rB;
      float k;
      if (ang) k = dot(dir, mulInvI(A, dir)) + dot(dir, mulInvI(B, dir));
      else {
        V3 ca = cross(rA, dir), cb = cross(rB, dir);
        k = A.invMass + B.invMass + dot(ca, mulInvI(A, ca)) + dot(cb, mulInvI(B, cb));
      }
      r.gamma = gamma;
      r.mass = (k + gamma) > 1e-12f ? 1.0f / (k + gamma) : 0.0f;
      r.target = target; r.lo = lo; r.hi = hi; r.isForce = isForce;
      rows.push_back(r);
    };
    auto clampT = [](float v, float m) { return std::max(-m, std::min(m, v)); };
    auto pointRows = [&]() {
      // The anchors must stay together: one block of three equations, solved exactly.
      JointRow r;
      r.a = J.bodyA; r.b = J.bodyB; r.joint = (int)ji; r.block = true; r.isForce = true; r.rA = rA; r.rB = rB;
      V3 C = pB - pA;
      r.targetV = V3(clampT(-beta / dt * C.x, maxLin), clampT(-beta / dt * C.y, maxLin), clampT(-beta / dt * C.z, maxLin));
      const V3 e[3] = {V3(1, 0, 0), V3(0, 1, 0), V3(0, 0, 1)};
      float K[3][3];
      for (int c = 0; c < 3; c++) {
        V3 col = e[c] * (A.invMass + B.invMass) + cross(mulInvI(A, cross(rA, e[c])), rA) + cross(mulInvI(B, cross(rB, e[c])), rB);
        K[0][c] = col.x; K[1][c] = col.y; K[2][c] = col.z;
      }
      float det = K[0][0] * (K[1][1] * K[2][2] - K[1][2] * K[2][1]) - K[0][1] * (K[1][0] * K[2][2] - K[1][2] * K[2][0]) + K[0][2] * (K[1][0] * K[2][1] - K[1][1] * K[2][0]);
      if (std::fabs(det) > 1e-14f) {
        float id = 1.0f / det;
        r.kinv[0] = (K[1][1] * K[2][2] - K[1][2] * K[2][1]) * id;
        r.kinv[1] = (K[0][2] * K[2][1] - K[0][1] * K[2][2]) * id;
        r.kinv[2] = (K[0][1] * K[1][2] - K[0][2] * K[1][1]) * id;
        r.kinv[3] = (K[1][2] * K[2][0] - K[1][0] * K[2][2]) * id;
        r.kinv[4] = (K[0][0] * K[2][2] - K[0][2] * K[2][0]) * id;
        r.kinv[5] = (K[0][2] * K[1][0] - K[0][0] * K[1][2]) * id;
        r.kinv[6] = (K[1][0] * K[2][1] - K[1][1] * K[2][0]) * id;
        r.kinv[7] = (K[0][1] * K[2][0] - K[0][0] * K[2][1]) * id;
        r.kinv[8] = (K[0][0] * K[1][1] - K[0][1] * K[1][0]) * id;
        rows.push_back(r);
      }
    };
    switch (J.d.type) {
      case JointType::Ball: pointRows(); break;
      case JointType::Fixed: {
        pointRows();
        Q target = A.rot * J.rel;
        Q e = B.rot * conj(target);
        if (e.w < 0) e = Q(-e.x, -e.y, -e.z, -e.w);
        V3 err(2 * e.x, 2 * e.y, 2 * e.z);
        const V3 axes[3] = {V3(1, 0, 0), V3(0, 1, 0), V3(0, 0, 1)};
        float c[3] = {err.x, err.y, err.z};
        for (int i = 0; i < 3; i++) addRow(true, axes[i], clampT(-beta / dt * c[i], maxAng), -1e30f, 1e30f, false);
        break;
      }
      case JointType::Hinge: {
        pointRows();
        V3 aA = norm(rotate(A.rot, J.axisA)), aB = norm(rotate(B.rot, J.axisB));
        V3 u = std::fabs(aA.y) < 0.9f ? norm(cross(aA, V3(0, 1, 0))) : norm(cross(aA, V3(1, 0, 0)));
        V3 v = cross(aA, u);
        V3 e = cross(aA, aB);
        addRow(true, u, clampT(-beta / dt * dot(e, u), maxAng), -1e30f, 1e30f, false);
        addRow(true, v, clampT(-beta / dt * dot(e, v), maxAng), -1e30f, 1e30f, false);
        if (J.d.limit) {
          float th = jointAngle((int)ji);
          if (th < J.d.lower) addRow(true, aA * -1.0f, clampT(-beta / dt * (th - J.d.lower), maxAng), 0.0f, 1e30f, false);
          else if (th > J.d.upper) addRow(true, aA, clampT(-beta / dt * (J.d.upper - th), maxAng), 0.0f, 1e30f, false);
        }
        if (J.d.motorMaxTorque > 0) addRow(true, aA, -J.d.motorSpeed, -J.d.motorMaxTorque * dt, J.d.motorMaxTorque * dt, false);   // speed of A relative to B
        break;
      }
      case JointType::Rope: {
        V3 dv = pB - pA;
        float L = len(dv);
        if (L < 1e-6f) break;
        V3 dn = dv * (1.0f / L);
        if (J.d.minLen >= J.d.maxLen) addRow(false, dn, clampT(-beta / dt * (L - J.d.maxLen), maxLin), -1e30f, 1e30f, true);   // rigid rod
        else if (L > J.d.maxLen) addRow(false, dn * -1.0f, clampT(-beta / dt * (J.d.maxLen - L), maxLin), 0.0f, 1e30f, true);
        else if (L < J.d.minLen) addRow(false, dn, clampT(-beta / dt * (L - J.d.minLen), maxLin), 0.0f, 1e30f, true);
        break;
      }
      case JointType::Spring: {
        V3 dv = pB - pA;
        float L = len(dv);
        if (L < 1e-6f) break;
        V3 dn = dv * (1.0f / L);
        V3 ca = cross(rA, dn), cb = cross(rB, dn);
        float k = A.invMass + B.invMass + dot(ca, mulInvI(A, ca)) + dot(cb, mulInvI(B, cb));
        if (k < 1e-12f) break;
        float m = 1.0f / k;
        float omega = 2.0f * 3.14159265f * std::max(0.01f, J.d.hz);
        float dampC = 2.0f * m * J.d.damping * omega, spring = m * omega * omega;
        float gamma = dt * (dampC + dt * spring);
        gamma = gamma > 1e-12f ? 1.0f / gamma : 0.0f;
        float bias = (L - J.d.restLen) * dt * spring * gamma;
        addRow(false, dn, -bias, -1e30f, 1e30f, true, gamma);
        break;
      }
      case JointType::Slider: {
        // Allows translation along J.axisA (with optional lower..upper limits) and locks perpendicular motion + rotation.
        V3 axisW = norm(rotate(A.rot, J.axisA));
        V3 u = std::fabs(axisW.y) < 0.9f ? norm(cross(axisW, V3(0, 1, 0))) : norm(cross(axisW, V3(1, 0, 0)));
        V3 v = cross(axisW, u);
        V3 dp = pB - pA;
        addRow(false, u, clampT(-beta / dt * dot(dp, u), maxLin), -1e30f, 1e30f, true);
        addRow(false, v, clampT(-beta / dt * dot(dp, v), maxLin), -1e30f, 1e30f, true);
        // Lock relative orientation like Fixed joint
        Q target = A.rot * J.rel;
        Q e = B.rot * conj(target);
        if (e.w < 0) e = Q(-e.x, -e.y, -e.z, -e.w);
        V3 err(2 * e.x, 2 * e.y, 2 * e.z);
        const V3 ax[3] = {V3(1, 0, 0), V3(0, 1, 0), V3(0, 0, 1)};
        float c[3] = {err.x, err.y, err.z};
        for (int i = 0; i < 3; i++) addRow(true, ax[i], clampT(-beta / dt * c[i], maxAng), -1e30f, 1e30f, false);
        // Linear slide limits along axisW
        if (J.d.limit) {
          float slide = dot(dp, axisW);
          if (slide < J.d.lower) addRow(false, axisW, clampT(-beta / dt * (slide - J.d.lower), maxLin), 0.0f, 1e30f, true);
          else if (slide > J.d.upper) addRow(false, axisW * -1.0f, clampT(-beta / dt * (J.d.upper - slide), maxLin), 0.0f, 1e30f, true);
        }
        if (J.d.motorMaxTorque > 0) addRow(false, axisW, -J.d.motorSpeed, -J.d.motorMaxTorque * dt, J.d.motorMaxTorque * dt, false);
        break;
      }
      case JointType::ConeTwist: {
        // Ball anchor + swing cone angle limit (upper = max swing radians)
        pointRows();
        V3 aA = norm(rotate(A.rot, J.axisA));
        V3 aB = norm(rotate(B.rot, J.axisB));
        float d = std::max(-1.0f, std::min(1.0f, dot(aA, aB)));
        float swing = std::acos(d);
        float maxSwing = J.d.limit ? std::max(0.01f, J.d.upper) : 1.0f;
        if (swing > maxSwing) {
          V3 swingAxis = cross(aA, aB);
          float sl = len(swingAxis);
          if (sl > 1e-5f) {
            swingAxis = swingAxis * (1.0f / sl);
            addRow(true, swingAxis, clampT(-beta / dt * (swing - maxSwing), maxAng), -1e30f, 0.0f, false);
          }
        }
        break;
      }
    }
  }
}

void PhysicsWorld::solveRow(JointRow& r) {
  Body& A = bodies_[r.a];
  Body& B = bodies_[r.b];
  if (r.block) {
    V3 cd = (B.linVel + cross(B.angVel, r.rB)) - (A.linVel + cross(A.angVel, r.rA));
    V3 rhs = r.targetV - cd;
    V3 lam(r.kinv[0] * rhs.x + r.kinv[1] * rhs.y + r.kinv[2] * rhs.z,
           r.kinv[3] * rhs.x + r.kinv[4] * rhs.y + r.kinv[5] * rhs.z,
           r.kinv[6] * rhs.x + r.kinv[7] * rhs.y + r.kinv[8] * rhs.z);
    r.impV += lam;
    A.linVel -= lam * A.invMass; A.angVel -= mulInvI(A, cross(r.rA, lam));
    B.linVel += lam * B.invMass; B.angVel += mulInvI(B, cross(r.rB, lam));
    return;
  }
  if (r.mass == 0) return;
  float cdot = r.angular ? dot(r.dir, B.angVel - A.angVel)
                         : dot(r.dir, (B.linVel + cross(B.angVel, r.rB)) - (A.linVel + cross(A.angVel, r.rA)));
  float lambda = r.mass * (r.target - cdot - r.gamma * r.imp);
  float ni = std::max(r.lo, std::min(r.hi, r.imp + lambda));
  lambda = ni - r.imp;
  r.imp = ni;
  if (r.angular) {
    V3 T = r.dir * lambda;
    A.angVel -= mulInvI(A, T);
    B.angVel += mulInvI(B, T);
  } else {
    V3 P = r.dir * lambda;
    A.linVel -= P * A.invMass; A.angVel -= mulInvI(A, cross(r.rA, P));
    B.linVel += P * B.invMass; B.angVel += mulInvI(B, cross(r.rB, P));
  }
}

}  // namespace tej
