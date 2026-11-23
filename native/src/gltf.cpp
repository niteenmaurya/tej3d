#include "gltf.h"

#include "jpeg.h"
#include "png.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>

namespace tej {
namespace {

// ---------------------------------------------------------------- tiny JSON

struct J {
  enum Type { Null, Bool, Num, Str, Arr, Obj } type = Null;
  double num = 0;
  bool b = false;
  std::string str;
  std::vector<J> arr;
  std::vector<std::pair<std::string, J>> obj;

  const J* get(const char* key) const {
    if (type != Obj) return nullptr;
    for (auto& kv : obj) if (kv.first == key) return &kv.second;
    return nullptr;
  }
  const J* at(size_t i) const { return (type == Arr && i < arr.size()) ? &arr[i] : nullptr; }
  size_t size() const { return type == Arr ? arr.size() : 0; }
  double number(double def = 0) const { return type == Num ? num : def; }
  int integer(int def = -1) const { return type == Num ? (int)num : def; }
};

struct Parser {
  const char* p;
  const char* end;
  bool ok = true;

  void ws() { while (p < end && (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t')) p++; }
  bool lit(const char* s) {
    size_t n = std::strlen(s);
    if ((size_t)(end - p) >= n && std::strncmp(p, s, n) == 0) { p += n; return true; }
    return false;
  }
  std::string parseString() {
    std::string out;
    if (p >= end || *p != '"') { ok = false; return out; }
    p++;
    while (p < end && *p != '"') {
      if (*p == '\\' && p + 1 < end) {
        p++;
        switch (*p) {
          case 'n': out += '\n'; break;
          case 't': out += '\t'; break;
          case 'r': out += '\r'; break;
          case 'u': {
            if (end - p >= 5) {
              unsigned v = (unsigned)std::strtoul(std::string(p + 1, 4).c_str(), nullptr, 16);
              out += v < 128 ? (char)v : '?';
              p += 4;
            }
            break;
          }
          default: out += *p;
        }
        p++;
      } else out += *p++;
    }
    if (p >= end) { ok = false; return out; }
    p++;
    return out;
  }
  J value(int depth) {
    J v;
    if (depth > 64) { ok = false; return v; }
    ws();
    if (p >= end) { ok = false; return v; }
    if (*p == '{') {
      p++; v.type = J::Obj; ws();
      if (p < end && *p == '}') { p++; return v; }
      while (ok) {
        ws();
        std::string k = parseString();
        ws();
        if (p >= end || *p != ':') { ok = false; break; }
        p++;
        J val = value(depth + 1);
        v.obj.emplace_back(std::move(k), std::move(val));
        ws();
        if (p < end && *p == ',') { p++; continue; }
        if (p < end && *p == '}') { p++; break; }
        ok = false;
      }
    } else if (*p == '[') {
      p++; v.type = J::Arr; ws();
      if (p < end && *p == ']') { p++; return v; }
      while (ok) {
        v.arr.push_back(value(depth + 1));
        ws();
        if (p < end && *p == ',') { p++; continue; }
        if (p < end && *p == ']') { p++; break; }
        ok = false;
      }
    } else if (*p == '"') {
      v.type = J::Str; v.str = parseString();
    } else if (lit("true")) { v.type = J::Bool; v.b = true; }
    else if (lit("false")) { v.type = J::Bool; v.b = false; }
    else if (lit("null")) { v.type = J::Null; }
    else {
      char* e = nullptr;
      v.num = std::strtod(p, &e);
      if (e == p || e > end) { ok = false; return v; }
      v.type = J::Num;
      p = e;
    }
    return v;
  }
};

// ---------------------------------------------------------------- accessors

struct Ctx {
  const J* root;
  const uint8_t* bin;
  size_t binSize;
  std::string err;
};

int compBytes(int ct) {
  switch (ct) { case 5120: case 5121: return 1; case 5122: case 5123: return 2; case 5125: case 5126: return 4; }
  return 0;
}
int typeCount(const std::string& t) {
  if (t == "SCALAR") return 1;
  if (t == "VEC2") return 2;
  if (t == "VEC3") return 3;
  if (t == "VEC4") return 4;
  if (t == "MAT2") return 4;
  if (t == "MAT3") return 9;
  if (t == "MAT4") return 16;
  return 0;
}

// Reads accessor `index` into floats (count * components). Integer types are
// decoded as normalized floats when "normalized": true.
bool readAccessor(Ctx& c, int index, std::vector<float>& out, int& comps, int& count) {
  const J* accs = c.root->get("accessors");
  const J* a = (accs && index >= 0) ? accs->at((size_t)index) : nullptr;
  if (!a) { c.err = "bad accessor index"; return false; }
  if (a->get("sparse")) { c.err = "sparse accessors are not supported"; return false; }
  int ct = a->get("componentType") ? a->get("componentType")->integer() : 0;
  const J* tj = a->get("type");
  comps = tj ? typeCount(tj->str) : 0;
  count = a->get("count") ? a->get("count")->integer(0) : 0;
  int cb = compBytes(ct);
  if (!cb || !comps || count < 0) { c.err = "bad accessor"; return false; }
  int bv = a->get("bufferView") ? a->get("bufferView")->integer() : -1;
  const J* views = c.root->get("bufferViews");
  const J* v = (views && bv >= 0) ? views->at((size_t)bv) : nullptr;
  if (!v) { c.err = "accessor without bufferView"; return false; }

  double bvOffD = v->get("byteOffset") ? v->get("byteOffset")->number() : 0.0;
  double accOffD = a->get("byteOffset") ? a->get("byteOffset")->number() : 0.0;
  double strideD = v->get("byteStride") ? v->get("byteStride")->number() : 0.0;
  if (!std::isfinite(bvOffD) || !std::isfinite(accOffD) || !std::isfinite(strideD) ||
      bvOffD < 0.0 || accOffD < 0.0 || strideD < 0.0) {
    c.err = "negative accessor offset or stride"; return false;
  }
  if (bvOffD > (double)c.binSize || accOffD > (double)c.binSize || strideD > (double)c.binSize) {
    c.err = "accessor outside buffer"; return false;
  }
  size_t bvOff = (size_t)bvOffD;
  size_t accOff = (size_t)accOffD;
  if (bvOff > c.binSize || accOff > c.binSize - bvOff) { c.err = "accessor outside buffer"; return false; }
  size_t off = bvOff + accOff;
  size_t elem = (size_t)cb * (size_t)comps;
  size_t stride = strideD == 0.0 ? elem : (size_t)strideD;
  if (stride < elem) { c.err = "accessor stride smaller than element"; return false; }
  if (count > 0) {
    if (!c.bin || elem > c.binSize - off) { c.err = "accessor outside buffer"; return false; }
    if ((size_t)(count - 1) > (c.binSize - off - elem) / stride) { c.err = "accessor outside buffer"; return false; }
  }

  bool normalized = a->get("normalized") && a->get("normalized")->b;
  out.resize((size_t)count * (size_t)comps);
  for (int i = 0; i < count; i++) {
    const uint8_t* src = c.bin + off + stride * (size_t)i;
    for (int k = 0; k < comps; k++) {
      float f = 0;
      const uint8_t* q = src + (size_t)k * (size_t)cb;
      switch (ct) {
        case 5126: { float t; std::memcpy(&t, q, 4); f = t; break; }
        case 5125: {
          uint32_t t; std::memcpy(&t, q, 4);
          f = normalized ? (float)((double)t / 4294967295.0) : (float)t;
          break;
        }
        case 5123: {
          uint16_t t; std::memcpy(&t, q, 2);
          f = normalized ? (float)t / 65535.0f : (float)t;
          break;
        }
        case 5121: {
          f = normalized ? (float)(*q) / 255.0f : (float)(*q);
          break;
        }
        case 5122: {
          int16_t t; std::memcpy(&t, q, 2);
          f = normalized ? std::max(-1.0f, (float)t / 32767.0f) : (float)t;
          break;
        }
        case 5120: {
          int8_t t = (int8_t)*q;
          f = normalized ? std::max(-1.0f, (float)t / 127.0f) : (float)t;
          break;
        }
      }
      out[(size_t)i * (size_t)comps + (size_t)k] = f;
    }
  }
  return true;
}

M4 nodeLocal(const J& n) {
  if (const J* m = n.get("matrix")) {
    M4 r;
    if (m->size() == 16) for (int i = 0; i < 16; i++) r.m[i] = (float)m->at(i)->number();
    return r;
  }
  V3 t(0, 0, 0), s(1, 1, 1);
  Q q;
  if (const J* a = n.get("translation")) if (a->size() == 3) t = V3((float)a->at(0)->number(), (float)a->at(1)->number(), (float)a->at(2)->number());
  if (const J* a = n.get("scale")) if (a->size() == 3) s = V3((float)a->at(0)->number(1), (float)a->at(1)->number(1), (float)a->at(2)->number(1));
  if (const J* a = n.get("rotation")) if (a->size() == 4) q = normalize(Q((float)a->at(0)->number(), (float)a->at(1)->number(), (float)a->at(2)->number(), (float)a->at(3)->number(1)));
  return trs(t, q, s);
}

struct SkinRes {
  int skeleton = -1;
  int jointCount = 0;
  std::vector<int> newIndexOfSlot;  // slot in skin.joints -> joint index in the engine skeleton
  std::map<int, int> jointOfNode;   // glTF node -> engine joint index
  M4 arm, armInv;                   // space the skeleton lives in (parent of the root joint) and its inverse
};

bool buildPrimitive(Ctx& c, const J& prim, Mesh& out, const SkinRes* skin = nullptr) {
  const J* attrs = prim.get("attributes");
  if (!attrs || !attrs->get("POSITION")) { c.err = "primitive without POSITION"; return false; }
  int mode = prim.get("mode") ? prim.get("mode")->integer(4) : 4;
  if (mode != 4) { c.err = "only triangle meshes are supported"; return false; }
  std::vector<float> pos, nor, uv, idxf;
  int pc = 0, n = 0, nc = 0, nn = 0, uc = 0, un = 0, ic = 0, in = 0;
  if (!readAccessor(c, attrs->get("POSITION")->integer(), pos, pc, n) || pc != 3) { if (c.err.empty()) c.err = "bad POSITION"; return false; }
  bool hasN = false, hasUv = false;
  if (const J* a = attrs->get("NORMAL")) hasN = readAccessor(c, a->integer(), nor, nc, nn) && nc == 3 && nn == n;
  if (const J* a = attrs->get("TEXCOORD_0")) hasUv = readAccessor(c, a->integer(), uv, uc, un) && uc == 2 && un == n;
  c.err.clear();
  std::vector<uint32_t> idx;
  if (const J* a = prim.get("indices")) {
    if (!readAccessor(c, a->integer(), idxf, ic, in) || ic != 1) { if (c.err.empty()) c.err = "bad indices"; return false; }
    idx.resize((size_t)in);
    for (int i = 0; i < in; i++) idx[(size_t)i] = (uint32_t)idxf[(size_t)i];
  } else {
    idx.resize((size_t)n);
    for (int i = 0; i < n; i++) idx[(size_t)i] = (uint32_t)i;
  }
  for (uint32_t i : idx) if (i >= (uint32_t)n) { c.err = "index out of range"; return false; }
  if (idx.size() % 3 != 0) idx.resize(idx.size() - idx.size() % 3);
  if (!hasN) {  // smooth normals from the faces
    nor.assign((size_t)n * 3, 0.0f);
    for (size_t t = 0; t + 2 < idx.size(); t += 3) {
      V3 p[3];
      for (int k = 0; k < 3; k++) p[k] = V3(pos[idx[t + k] * 3], pos[idx[t + k] * 3 + 1], pos[idx[t + k] * 3 + 2]);
      V3 fn = cross(p[1] - p[0], p[2] - p[0]);
      for (int k = 0; k < 3; k++) { nor[idx[t + k] * 3] += fn.x; nor[idx[t + k] * 3 + 1] += fn.y; nor[idx[t + k] * 3 + 2] += fn.z; }
    }
  }
  out.verts.resize((size_t)n * 8);
  for (int i = 0; i < n; i++) {
    float* f = &out.verts[(size_t)i * 8];
    f[0] = pos[i * 3]; f[1] = pos[i * 3 + 1]; f[2] = pos[i * 3 + 2];
    V3 nv = norm(V3(nor[i * 3], nor[i * 3 + 1], nor[i * 3 + 2]));
    f[3] = nv.x; f[4] = nv.y; f[5] = nv.z;
    f[6] = hasUv ? uv[i * 2] : 0.0f; f[7] = hasUv ? uv[i * 2 + 1] : 0.0f;
  }
  out.idx = std::move(idx);
  if (skin) {
    // Skinned: read joints and weights, and move the vertices into the skeleton's space.
    std::vector<float> jf, wf;
    int jc = 0, jn = 0, wc = 0, wn = 0;
    const J* ja = attrs->get("JOINTS_0");
    const J* wa = attrs->get("WEIGHTS_0");
    if (ja && wa && readAccessor(c, ja->integer(), jf, jc, jn) && jc == 4 && jn == n &&
        readAccessor(c, wa->integer(), wf, wc, wn) && wc == 4 && wn == n) {
      const J* accs = c.root->get("accessors");
      int widx = wa->integer();
      const J* wacc = (accs && widx >= 0) ? accs->at((size_t)widx) : nullptr;
      int wct = (wacc && wacc->get("componentType")) ? wacc->get("componentType")->integer() : 5126;
      bool wnorm = wacc && wacc->get("normalized") && wacc->get("normalized")->b;
      float wdiv = wnorm ? 1.0f : (wct == 5121 ? 255.0f : (wct == 5123 ? 65535.0f : 1.0f));
      out.joints.assign((size_t)n * 4, 0);
      out.weights.assign((size_t)n * 4, 0.0f);
      for (int i = 0; i < n; i++) {
        float sum = 0;
        for (int k = 0; k < 4; k++) {
          int slot = (int)jf[i * 4 + k];
          float wt = wf[i * 4 + k] / wdiv;
          if (wt <= 0 || slot < 0 || slot >= (int)skin->newIndexOfSlot.size()) continue;
          out.joints[i * 4 + k] = (uint8_t)skin->newIndexOfSlot[slot];
          out.weights[i * 4 + k] = wt;
          sum += wt;
        }
        if (sum > 1e-6f) for (int k = 0; k < 4; k++) out.weights[i * 4 + k] /= sum;
        else { out.joints[i * 4] = 0; out.weights[i * 4] = 1.0f; }
      }
    } else {
      c.err.clear();
    }
    for (int i = 0; i < n; i++) {
      float* f = &out.verts[(size_t)i * 8];
      V3 p = transformPoint(skin->armInv, V3(f[0], f[1], f[2]));
      V3 nn = norm(transformDir(skin->armInv, V3(f[3], f[4], f[5])));
      f[0] = p.x; f[1] = p.y; f[2] = p.z; f[3] = nn.x; f[4] = nn.y; f[5] = nn.z;
    }
  }
  return true;
}

// Local transform of a node as translation, rotation and scale.
Xform nodeXform(const J& n) {
  Xform x;
  if (const J* m = n.get("matrix")) {
    M4 r = nodeLocal(n);
    (void)m;
    x.t = V3(r.m[12], r.m[13], r.m[14]);
    V3 c0(r.m[0], r.m[1], r.m[2]), c1(r.m[4], r.m[5], r.m[6]), c2(r.m[8], r.m[9], r.m[10]);
    x.s = V3(len(c0), len(c1), len(c2));
    if (x.s.x > 1e-8f) c0 = c0 * (1.0f / x.s.x);
    if (x.s.y > 1e-8f) c1 = c1 * (1.0f / x.s.y);
    if (x.s.z > 1e-8f) c2 = c2 * (1.0f / x.s.z);
    if (dot(cross(c0, c1), c2) < 0.0f) {
      x.s.x = -x.s.x;
      c0 = -c0;
    }
    float tr = c0.x + c1.y + c2.z;
    Q q;
    if (tr > 0) {
      float s2 = std::sqrt(std::max(0.0f, tr + 1.0f)) * 2.0f;
      if (s2 > 1e-8f) q = Q((c1.z - c2.y) / s2, (c2.x - c0.z) / s2, (c0.y - c1.x) / s2, 0.25f * s2);
    } else if (c0.x > c1.y && c0.x > c2.z) {
      float s2 = std::sqrt(std::max(0.0f, 1.0f + c0.x - c1.y - c2.z)) * 2.0f;
      if (s2 > 1e-8f) q = Q(0.25f * s2, (c1.x + c0.y) / s2, (c2.x + c0.z) / s2, (c1.z - c2.y) / s2);
    } else if (c1.y > c2.z) {
      float s2 = std::sqrt(std::max(0.0f, 1.0f + c1.y - c0.x - c2.z)) * 2.0f;
      if (s2 > 1e-8f) q = Q((c1.x + c0.y) / s2, 0.25f * s2, (c2.y + c1.z) / s2, (c2.x - c0.z) / s2);
    } else {
      float s2 = std::sqrt(std::max(0.0f, 1.0f + c2.z - c0.x - c1.y)) * 2.0f;
      if (s2 > 1e-8f) q = Q((c2.x + c0.z) / s2, (c2.y + c1.z) / s2, 0.25f * s2, (c0.y - c1.x) / s2);
    }
    x.r = normalize(q);
    return x;
  }
  if (const J* a = n.get("translation")) if (a->size() == 3) x.t = V3((float)a->at(0)->number(), (float)a->at(1)->number(), (float)a->at(2)->number());
  if (const J* a = n.get("scale")) if (a->size() == 3) x.s = V3((float)a->at(0)->number(1), (float)a->at(1)->number(1), (float)a->at(2)->number(1));
  if (const J* a = n.get("rotation")) if (a->size() == 4) x.r = normalize(Q((float)a->at(0)->number(), (float)a->at(1)->number(), (float)a->at(2)->number(), (float)a->at(3)->number(1)));
  return x;
}

}  // namespace

int loadGlb(World& w, const uint8_t* data, size_t size) {
  w.modelError.clear();
  w.modelWarning.clear();
  auto fail = [&](const std::string& m) { w.modelError = m; return -1; };
  if (!data || size < 20) return fail("file too small");
  uint32_t magic, version, total;
  std::memcpy(&magic, data, 4); std::memcpy(&version, data + 4, 4); std::memcpy(&total, data + 8, 4);
  if (magic != 0x46546C67u) return fail("not a .glb file (bad magic)");
  if (version != 2) return fail("only glTF 2.0 is supported");
  if ((size_t)total > size) return fail("file is cut short");
  const uint8_t* json = nullptr; size_t jsonSize = 0;
  const uint8_t* bin = nullptr; size_t binSize = 0;
  size_t off = 12;
  while (off + 8 <= (size_t)total) {
    uint32_t len, type;
    std::memcpy(&len, data + off, 4); std::memcpy(&type, data + off + 4, 4);
    off += 8;
    if ((size_t)len > (size_t)total - off) return fail("bad chunk size");
    if (type == 0x4E4F534Au && !json) { json = data + off; jsonSize = len; }
    else if (type == 0x004E4942u && !bin) { bin = data + off; binSize = len; }
    size_t aligned = ((size_t)len + 3u) & ~size_t(3u);
    if (aligned > (size_t)total - off) break;
    off += aligned;
  }
  if (!json) return fail("no JSON chunk");
  std::string jsonStr((const char*)json, jsonSize);
  Parser ps{jsonStr.data(), jsonStr.data() + jsonStr.size()};
  J root = ps.value(0);
  if (!ps.ok || root.type != J::Obj) return fail("invalid JSON");
  Ctx c{&root, bin, binSize, ""};

  const J* nodes = root.get("nodes");
  const J* meshes = root.get("meshes");
  const J* materials = root.get("materials");
  const J* scenes = root.get("scenes");
  if (!nodes || !meshes) return fail("file has no nodes or meshes");
  std::vector<int> roots;
  if (scenes && scenes->size() > 0) {
    int si = root.get("scene") ? root.get("scene")->integer(0) : 0;
    const J* sc = scenes->at(si < 0 ? 0 : (size_t)si);
    if (sc) if (const J* rn = sc->get("nodes")) for (size_t i = 0; i < rn->size(); i++) roots.push_back(rn->at(i)->integer());
  }
  if (roots.empty()) for (size_t i = 0; i < nodes->size(); i++) roots.push_back((int)i);  // no scene: take all

  // ---- skins: parent map, node world matrices, and the engine skeleton for each skin
  std::vector<int> parentOf(nodes->size(), -1);
  for (size_t i = 0; i < nodes->size(); i++)
    if (const J* ch = nodes->at(i)->get("children"))
      for (size_t k = 0; k < ch->size(); k++) { int cI = ch->at(k)->integer(); if (cI >= 0 && cI < (int)nodes->size()) parentOf[cI] = (int)i; }
  auto nodeWorld = [&](int node) {
    std::vector<int> chain;
    for (int n = node; n >= 0 && n < (int)nodes->size() && chain.size() < 200; n = parentOf[n]) chain.push_back(n);
    M4 m;
    for (size_t k = chain.size(); k-- > 0;) m = m * nodeLocal(*nodes->at((size_t)chain[k]));
    return m;
  };
  std::map<int, SkinRes> skinCache;
  const J* skinsJ = root.get("skins");
  auto skinFor = [&](int si) -> const SkinRes* {
    auto it = skinCache.find(si);
    if (it != skinCache.end()) return it->second.skeleton >= 0 ? &it->second : nullptr;
    SkinRes& R = skinCache[si];
    const J* s = (skinsJ && si >= 0) ? skinsJ->at((size_t)si) : nullptr;
    const J* js = s ? s->get("joints") : nullptr;
    int nj = js ? (int)js->size() : 0;
    if (nj == 0) { w.modelWarning += "skin " + std::to_string(si) + " has no joints; "; return nullptr; }
    if (nj > 255) { w.modelWarning += "skin " + std::to_string(si) + " has more than 255 joints and was skipped; "; return nullptr; }
    std::map<int, int> slotOfNode;
    for (int k = 0; k < nj; k++) {
      int nd = js->at((size_t)k)->integer();
      if (nd < 0 || nd >= (int)nodes->size()) {
        w.modelWarning += "skin " + std::to_string(si) + " has an out-of-range joint node and was skipped; ";
        return nullptr;
      }
      slotOfNode[nd] = k;
    }
    std::vector<int> parentSlot(nj, -1);
    for (int k = 0; k < nj; k++) {
      int nd = js->at((size_t)k)->integer();
      int p = parentOf[nd];
      int guard = 0;
      bool skippedNonJoint = false;
      while (p >= 0 && !slotOfNode.count(p) && guard++ < 200) { skippedNonJoint = true; p = parentOf[p]; }
      if (p >= 0 && slotOfNode.count(p)) {
        parentSlot[k] = slotOfNode[p];
        if (skippedNonJoint) w.modelWarning += "a bone has a non-bone node between it and its parent (its own transform is used); ";
      }
    }
    std::vector<int> order;
    std::vector<char> placed(nj, 0);
    for (int pass = 0; pass < nj + 1 && (int)order.size() < nj; pass++) {
      for (int k = 0; k < nj; k++) {
        if (placed[k]) continue;
        if (parentSlot[k] < 0 || placed[parentSlot[k]]) { order.push_back(k); placed[k] = 1; }
      }
    }
    if ((int)order.size() != nj) { w.modelWarning += "skin " + std::to_string(si) + " has a loop in its bones and was skipped; "; return nullptr; }
    R.newIndexOfSlot.assign(nj, 0);
    for (int i = 0; i < nj; i++) R.newIndexOfSlot[order[i]] = i;
    auto sk = std::make_unique<SkeletonRes>();
    sk->sk.parent.resize(nj);
    sk->sk.bind.resize(nj);
    sk->names.assign(nj, "");
    int firstRootNode = -1;
    for (int i = 0; i < nj; i++) {
      int slot = order[i];
      int nd = js->at((size_t)slot)->integer();
      sk->sk.parent[i] = parentSlot[slot] >= 0 ? R.newIndexOfSlot[parentSlot[slot]] : -1;
      sk->sk.bind[i] = nodeXform(*nodes->at((size_t)nd));
      if (const J* nm = nodes->at((size_t)nd)->get("name")) sk->names[i] = nm->str;
      R.jointOfNode[nd] = i;
      if (parentSlot[slot] < 0 && firstRootNode < 0) firstRootNode = nd;
    }
    sk->sk.finalize();
    R.arm = firstRootNode >= 0 && parentOf[firstRootNode] >= 0 ? nodeWorld(parentOf[firstRootNode]) : M4();
    R.armInv = inverseAffine(R.arm);
    // The file's inverse bind matrices should match the bind pose of the bones.
    if (const J* ib = s->get("inverseBindMatrices")) {
      std::vector<float> f; int comps = 0, cnt = 0;
      Ctx cc{&root, bin, binSize, ""};
      if (readAccessor(cc, ib->integer(), f, comps, cnt) && comps == 16 && cnt == nj) {
        float worst = 0;
        for (int i = 0; i < nj; i++) {
          int slot = order[i];
          M4 expect = sk->sk.invBindModel[i] * R.armInv;
          for (int e = 0; e < 16; e++) worst = std::fmax(worst, std::fabs(expect.m[e] - f[slot * 16 + e]));
        }
        if (worst > 1e-2f) w.modelWarning += "the file's inverse bind matrices differ from the bone pose (the bone pose is used); ";
      }
    }
    R.jointCount = nj;
    w.skeletons.push_back(std::move(sk));
    R.skeleton = (int)w.skeletons.size() - 1;
    return &R;
  };

  const J* texturesJ = root.get("textures");
  const J* imagesJ = root.get("images");
  const J* viewsJ = root.get("bufferViews");
  std::map<int, int> imageCache;  // glTF image index -> engine texture id (-1 = failed)
  auto textureFor = [&](int texIndex) -> int {
    const J* t = (texturesJ && texIndex >= 0) ? texturesJ->at((size_t)texIndex) : nullptr;
    int src = (t && t->get("source")) ? t->get("source")->integer() : -1;
    if (src < 0) return -1;
    auto it = imageCache.find(src);
    if (it != imageCache.end()) return it->second;
    int id = -1;
    const J* img = imagesJ ? imagesJ->at((size_t)src) : nullptr;
    int bv = (img && img->get("bufferView")) ? img->get("bufferView")->integer() : -1;
    const J* v = (viewsJ && bv >= 0) ? viewsJ->at((size_t)bv) : nullptr;
    if (!v) w.modelWarning += "image " + std::to_string(src) + " is not inside the file (use File > Export with glb and embedded images); ";
    else {
      double offD = v->get("byteOffset") ? v->get("byteOffset")->number() : 0.0;
      double lenD = v->get("byteLength") ? v->get("byteLength")->number() : 0.0;
      if (!std::isfinite(offD) || !std::isfinite(lenD) || offD < 0.0 || lenD < 0.0 ||
          offD > (double)binSize || lenD > (double)binSize ||
          (size_t)offD > binSize || (size_t)lenD > binSize - (size_t)offD || !bin) {
        w.modelWarning += "image " + std::to_string(src) + " is outside the file; ";
      } else {
        size_t imgOff = (size_t)offD;
        size_t imgLen = (size_t)lenD;
        Texture tex;
        std::string perr;
        const bool isJpeg = imgLen >= 3 && bin[imgOff] == 0xFF && bin[imgOff + 1] == 0xD8 && bin[imgOff + 2] == 0xFF;
        if (isJpeg ? decodeJpeg(bin + imgOff, imgLen, tex.w, tex.h, tex.rgba, perr) : decodePng(bin + imgOff, imgLen, tex.w, tex.h, tex.rgba, perr)) {
          buildMips(tex);
          w.textures.push_back(std::move(tex));
          id = (int)w.textures.size() - 1;
        } else w.modelWarning += "image " + std::to_string(src) + " skipped: " + perr + "; ";
      }
    }
    imageCache[src] = id;
    return id;
  };

  std::map<std::pair<int, int>, std::vector<int>> meshCache;  // (glTF mesh index, skin index or -1) -> engine mesh ids per primitive
  int created = 0;
  size_t firstPart = w.modelParts.size();

  struct Item { int node; M4 parent; int depth; };
  std::vector<Item> stack;
  for (auto it = roots.rbegin(); it != roots.rend(); ++it) stack.push_back({*it, M4(), 0});
  int visited = 0;
  while (!stack.empty()) {
    Item it = stack.back(); stack.pop_back();
    if (++visited > 100000 || it.depth > 64) return fail("node tree too deep or has a loop");
    const J* n = it.node >= 0 ? nodes->at((size_t)it.node) : nullptr;
    if (!n) return fail("bad node index");
    M4 world = it.parent * nodeLocal(*n);
    std::string name = n->get("name") ? n->get("name")->str : "";
    if (const J* mj = n->get("mesh")) {
      int mi = mj->integer();
      const J* mesh = mi >= 0 ? meshes->at((size_t)mi) : nullptr;
      if (!mesh) return fail("bad mesh index");
      const J* prims = mesh->get("primitives");
      if (!prims) return fail("mesh without primitives");
      int skinIndex = n->get("skin") ? n->get("skin")->integer() : -1;
      const SkinRes* skin = skinIndex >= 0 ? skinFor(skinIndex) : nullptr;
      auto cached = meshCache.find({mi, skin ? skinIndex : -1});
      if (cached == meshCache.end()) {
        std::vector<int> ids;
        for (size_t pi = 0; pi < prims->size(); pi++) {
          Mesh m;
          if (!buildPrimitive(c, *prims->at(pi), m, skin)) return fail(c.err.empty() ? "bad primitive" : c.err);
          w.meshes.push_back(std::move(m));
          ids.push_back((int)w.meshes.size() - 1);
        }
        cached = meshCache.emplace(std::make_pair(mi, skin ? skinIndex : -1), ids).first;
      }
      for (size_t pi = 0; pi < prims->size(); pi++) {
        Instance inst;
        inst.alive = true;
        inst.mesh = cached->second[pi];
        inst.xf = skin ? skin->arm : world;
        float rough = 1.0f;
        int mat = prims->at(pi)->get("material") ? prims->at(pi)->get("material")->integer() : -1;
        const J* mj2 = (materials && mat >= 0) ? materials->at((size_t)mat) : nullptr;
        if (mj2) {
          if (const J* pbr = mj2->get("pbrMetallicRoughness")) {
            if (const J* bc = pbr->get("baseColorFactor")) if (bc->size() == 4)
              for (int k = 0; k < 4; k++) inst.color[k] = (float)bc->at(k)->number(1);
            if (const J* r = pbr->get("roughnessFactor")) rough = (float)r->number(1);
            if (const J* bt = pbr->get("baseColorTexture")) if (bt->get("index")) inst.texture = textureFor(bt->get("index")->integer());
          }
          if (const J* ds = mj2->get("doubleSided")) inst.doubleSided = ds->b;
          if (const J* em = mj2->get("emissiveFactor")) if (em->size() == 3)
            inst.emissive = (float)std::fmax(em->at(0)->number(), std::fmax(em->at(1)->number(), em->at(2)->number()));
        }
        inst.specular = 0.1f + 0.4f * (1.0f - rough);
        w.instances.push_back(inst);
        ModelPart part;
        part.name = name;
        part.instance = (int)w.instances.size() - 1;
        part.world = inst.xf;
        part.skeleton = skin ? skin->skeleton : -1;
        w.modelParts.push_back(part);
        created++;
      }
    }
    if (const J* ch = n->get("children"))
      for (size_t i = ch->size(); i-- > 0;) stack.push_back({ch->at(i)->integer(), world, it.depth + 1});
  }
  (void)firstPart;

  // ---- animations: one clip per animation for every skin it moves
  if (const J* anims = root.get("animations")) {
    for (size_t ai = 0; ai < anims->size(); ai++) {
      const J* an = anims->at(ai);
      const J* chans = an->get("channels");
      const J* samps = an->get("samplers");
      if (!chans || !samps) continue;
      std::string aname = an->get("name") && !an->get("name")->str.empty() ? an->get("name")->str : "clip" + std::to_string(ai);
      for (auto& kv : skinCache) {
        const SkinRes& R = kv.second;
        if (R.skeleton < 0) continue;
        auto cr = std::make_unique<ClipRes>();
        cr->clip.tracks.resize(R.jointCount);
        float duration = 0;
        bool any = false;
        for (size_t ci = 0; ci < chans->size(); ci++) {
          const J* ch = chans->at(ci);
          const J* tg = ch->get("target");
          if (!tg || !tg->get("node") || !tg->get("path")) continue;
          auto jn = R.jointOfNode.find(tg->get("node")->integer());
          if (jn == R.jointOfNode.end()) continue;
          const std::string path = tg->get("path")->str;
          int spIdx = ch->get("sampler") ? ch->get("sampler")->integer() : -1;
          const J* sp = spIdx >= 0 ? samps->at((size_t)spIdx) : nullptr;
          if (!sp || !sp->get("input") || !sp->get("output")) continue;
          std::string interp = sp->get("interpolation") ? sp->get("interpolation")->str : "LINEAR";
          std::vector<float> tin, vout; int c1 = 0, n1 = 0, c2 = 0, n2 = 0;
          Ctx cc{&root, bin, binSize, ""};
          if (!readAccessor(cc, sp->get("input")->integer(), tin, c1, n1) || c1 != 1 ||
              !readAccessor(cc, sp->get("output")->integer(), vout, c2, n2)) { w.modelWarning += "animation " + aname + ": bad sampler skipped; "; continue; }
          int want = path == "rotation" ? 4 : 3;
          if (path != "rotation" && path != "translation" && path != "scale") { w.modelWarning += "animation path " + path + " is not supported; "; continue; }
          bool cubic = interp == "CUBICSPLINE";
          if (cubic) w.modelWarning += "animation " + aname + ": CUBICSPLINE is played as LINEAR; ";
          if (c2 != want || n1 < 1 || n2 != (cubic ? n1 * 3 : n1)) { w.modelWarning += "animation " + aname + ": sampler size mismatch, skipped; "; continue; }
          auto valueAt = [&](int k, float* out) { const float* src = &vout[((size_t)(cubic ? k * 3 + 1 : k)) * want]; for (int e = 0; e < want; e++) out[e] = src[e]; };
          JointTrack& tr = cr->clip.tracks[jn->second];
          std::vector<float> times; std::vector<std::array<float, 4>> vals;
          for (int k = 0; k < n1; k++) {
            std::array<float, 4> v{0, 0, 0, 1};
            valueAt(k, v.data());
            if (interp == "STEP" && k > 0) { times.push_back(std::fmax(tin[k] - 1e-4f, tin[k - 1])); vals.push_back(vals.back()); }
            times.push_back(tin[k]); vals.push_back(v);
          }
          for (size_t k = 0; k < times.size(); k++) {
            if (path == "rotation") { tr.r.times.push_back(times[k]); tr.r.values.push_back(normalize(Q(vals[k][0], vals[k][1], vals[k][2], vals[k][3]))); }
            else if (path == "translation") { tr.t.times.push_back(times[k]); tr.t.values.push_back(V3(vals[k][0], vals[k][1], vals[k][2])); }
            else { tr.s.times.push_back(times[k]); tr.s.values.push_back(V3(vals[k][0], vals[k][1], vals[k][2])); }
          }
          duration = std::fmax(duration, tin[n1 - 1]);
          any = true;
        }
        if (!any) continue;
        cr->clip.duration = duration > 1e-4f ? duration : 1e-4f;
        w.clips.push_back(std::move(cr));
        ModelClip mc;
        mc.name = aname;
        mc.clip = (int)w.clips.size() - 1;
        mc.skeleton = R.skeleton;
        w.modelClips.push_back(mc);
      }
    }
  }
  return created;
}

}  // namespace tej
