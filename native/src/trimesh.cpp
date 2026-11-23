#include "trimesh.h"

#include <algorithm>
#include <cmath>

namespace tej {

V3 closestPointOnTriangle(const V3& p, const V3& a, const V3& b, const V3& c) {
  V3 ab = b - a, ac = c - a, ap = p - a;
  float d1 = dot(ab, ap), d2 = dot(ac, ap);
  if (d1 <= 0 && d2 <= 0) return a;
  V3 bp = p - b;
  float d3 = dot(ab, bp), d4 = dot(ac, bp);
  if (d3 >= 0 && d4 <= d3) return b;
  float vc = d1 * d4 - d3 * d2;
  if (vc <= 0 && d1 >= 0 && d3 <= 0) {
    float den = d1 - d3;
    return den > 1e-12f ? a + ab * (d1 / den) : a;
  }
  V3 cp = p - c;
  float d5 = dot(ab, cp), d6 = dot(ac, cp);
  if (d6 >= 0 && d5 <= d6) return c;
  float vb = d5 * d2 - d1 * d6;
  if (vb <= 0 && d2 >= 0 && d6 <= 0) {
    float den = d2 - d6;
    return den > 1e-12f ? a + ac * (d2 / den) : a;
  }
  float va = d3 * d6 - d5 * d4;
  if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0) {
    float den = (d4 - d3) + (d5 - d6);
    float w = den > 1e-12f ? (d4 - d3) / den : 0.0f;
    return b + (c - b) * w;
  }
  float sum = va + vb + vc;
  if (sum <= 1e-12f) return a;
  float denom = 1.0f / sum;
  return a + ab * (vb * denom) + ac * (vc * denom);
}

namespace {
void boundsOf(const TriMesh& m, int first, int count, V3& lo, V3& hi) {
  lo = V3(1e30f, 1e30f, 1e30f);
  hi = V3(-1e30f, -1e30f, -1e30f);
  for (int i = first; i < first + count; i++) {
    int t = m.order[i];
    for (int k = 0; k < 3; k++) {
      const V3& p = m.v[m.idx[t * 3 + k]];
      for (int a = 0; a < 3; a++) { lo[a] = std::min(lo[a], p[a]); hi[a] = std::max(hi[a], p[a]); }
    }
  }
}
}  // namespace

void TriMesh::build() {
  int n = triCount();
  order.resize(n);
  for (int i = 0; i < n; i++) order[i] = i;
  nodes.clear();
  if (n == 0) { lo = hi = V3(); return; }
  std::vector<V3> cen(n);
  for (int t = 0; t < n; t++) {
    V3 a, b, c; tri(t, a, b, c);
    cen[t] = (a + b + c) * (1.0f / 3.0f);
  }
  struct Task { int node, first, count; };
  nodes.emplace_back();
  std::vector<Task> stack{{0, 0, n}};
  while (!stack.empty()) {
    Task k = stack.back(); stack.pop_back();
    V3 l, h;
    boundsOf(*this, k.first, k.count, l, h);
    nodes[k.node].lo = l; nodes[k.node].hi = h;
    if (k.count <= 4) { nodes[k.node].first = k.first; nodes[k.node].count = k.count; continue; }
    V3 clo(1e30f, 1e30f, 1e30f), chi(-1e30f, -1e30f, -1e30f);
    for (int i = k.first; i < k.first + k.count; i++)
      for (int a = 0; a < 3; a++) { clo[a] = std::min(clo[a], cen[order[i]][a]); chi[a] = std::max(chi[a], cen[order[i]][a]); }
    int axis = 0;
    float best = chi[0] - clo[0];
    for (int a = 1; a < 3; a++) if (chi[a] - clo[a] > best) { best = chi[a] - clo[a]; axis = a; }
    int mid = k.count / 2;
    std::nth_element(order.begin() + k.first, order.begin() + k.first + mid, order.begin() + k.first + k.count,
                     [&](int x, int y) { return cen[x][axis] < cen[y][axis]; });
    int li = (int)nodes.size();
    nodes.emplace_back();
    int ri = (int)nodes.size();
    nodes.emplace_back();
    nodes[k.node].left = li; nodes[k.node].right = ri;
    stack.push_back({li, k.first, mid});
    stack.push_back({ri, k.first + mid, k.count - mid});
  }
  lo = nodes[0].lo; hi = nodes[0].hi;
}

void TriMesh::query(const V3& qlo, const V3& qhi, std::vector<int>& out) const {
  if (nodes.empty()) return;
  std::vector<int> stack{0};
  while (!stack.empty()) {
    int ni = stack.back(); stack.pop_back();
    const Node& nd = nodes[ni];
    if (nd.lo.x > qhi.x || nd.hi.x < qlo.x || nd.lo.y > qhi.y || nd.hi.y < qlo.y || nd.lo.z > qhi.z || nd.hi.z < qlo.z) continue;
    if (nd.left < 0) {
      for (int i = nd.first; i < nd.first + nd.count; i++) {
        int t = order[i];
        V3 a, b, c; tri(t, a, b, c);
        V3 tl(std::min({a.x, b.x, c.x}), std::min({a.y, b.y, c.y}), std::min({a.z, b.z, c.z}));
        V3 th(std::max({a.x, b.x, c.x}), std::max({a.y, b.y, c.y}), std::max({a.z, b.z, c.z}));
        if (tl.x > qhi.x || th.x < qlo.x || tl.y > qhi.y || th.y < qlo.y || tl.z > qhi.z || th.z < qlo.z) continue;
        out.push_back(t);
      }
    } else { stack.push_back(nd.left); stack.push_back(nd.right); }
  }
}

bool TriMesh::raycast(const V3& o, const V3& d, float maxT, float& tOut, V3& nOut) const {
  if (nodes.empty()) return false;
  float best = maxT;
  bool hit = false;
  std::vector<int> stack{0};
  while (!stack.empty()) {
    int ni = stack.back(); stack.pop_back();
    const Node& nd = nodes[ni];
    float t0 = 0, t1 = best;
    bool ok = true;
    for (int k = 0; k < 3 && ok; k++) {
      if (std::fabs(d[k]) < 1e-9f) { if (o[k] < nd.lo[k] || o[k] > nd.hi[k]) ok = false; }
      else {
        float a = (nd.lo[k] - o[k]) / d[k], c = (nd.hi[k] - o[k]) / d[k];
        if (a > c) std::swap(a, c);
        t0 = std::max(t0, a); t1 = std::min(t1, c);
        if (t0 > t1) ok = false;
      }
    }
    if (!ok) continue;
    if (nd.left >= 0) { stack.push_back(nd.left); stack.push_back(nd.right); continue; }
    for (int i = nd.first; i < nd.first + nd.count; i++) {
      V3 a, b, c; tri(order[i], a, b, c);
      V3 e1 = b - a, e2 = c - a, pv = cross(d, e2);
      float det = dot(e1, pv);
      if (std::fabs(det) < 1e-12f) continue;
      float inv = 1.0f / det;
      V3 tv = o - a;
      float u = dot(tv, pv) * inv;
      if (u < 0 || u > 1) continue;
      V3 qv = cross(tv, e1);
      float v2 = dot(d, qv) * inv;
      if (v2 < 0 || u + v2 > 1) continue;
      float t = dot(e2, qv) * inv;
      if (t < 0 || t > best) continue;
      best = t; hit = true;
      V3 n = norm(cross(e1, e2));
      nOut = dot(n, d) > 0 ? -n : n;
    }
  }
  if (hit) tOut = best;
  return hit;
}

}  // namespace tej
