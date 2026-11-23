// Static triangle meshes for levels: tracks, terrain, buildings.
#pragma once
#include <vector>
#include "tmath.h"

namespace tej {

V3 closestPointOnTriangle(const V3& p, const V3& a, const V3& b, const V3& c);

struct TriMesh {
  std::vector<V3> v;
  std::vector<uint32_t> idx;  // 3 per triangle
  struct Node {
    V3 lo, hi;
    int left = -1, right = -1;  // children, or -1 for a leaf
    int first = 0, count = 0;   // leaf: range in `order`
  };
  std::vector<Node> nodes;
  std::vector<int> order;
  V3 lo, hi;

  void build();  // bounding volume tree over the triangles
  int triCount() const { return (int)idx.size() / 3; }
  void tri(int t, V3& a, V3& b, V3& c) const {
    a = v[idx[t * 3]]; b = v[idx[t * 3 + 1]]; c = v[idx[t * 3 + 2]];
  }
  // Triangles whose box touches [lo, hi].
  void query(const V3& qlo, const V3& qhi, std::vector<int>& out) const;
  // Closest hit along a ray (both sides of a triangle count). n faces the ray.
  bool raycast(const V3& o, const V3& d, float maxT, float& t, V3& n) const;
};

}  // namespace tej
