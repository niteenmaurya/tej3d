// CPU reference renderer. Perspective-correct triangles, depth buffer,
// per-pixel lighting (directional + point + hemisphere ambient), textures, fog, skinning.
// This is the portable backend; GPU backends consume the same World data.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include "world.h"

namespace tej {
namespace {

struct Vtx {
  float cx, cy, cz, cw;  // clip space
  V3 wp, n;
  float u, v;
};
static Vtx mix(const Vtx& a, const Vtx& b, float t) {
  Vtx r;
  r.cx = a.cx + (b.cx - a.cx) * t; r.cy = a.cy + (b.cy - a.cy) * t;
  r.cz = a.cz + (b.cz - a.cz) * t; r.cw = a.cw + (b.cw - a.cw) * t;
  r.wp = lerp(a.wp, b.wp, t); r.n = lerp(a.n, b.n, t);
  r.u = a.u + (b.u - a.u) * t; r.v = a.v + (b.v - a.v) * t;
  return r;
}

struct Target {
  int w, h;
  uint8_t* rgba;
  std::vector<float> depth;
};

// Depth seen from the sun (orthographic, looking along [dir]). Covers a square
// of side 2 * radius around [center].
struct ShadowMap {
  int size = 0;
  float radius = 1;
  V3 center, dir, right, up;
  std::vector<float> depth;  // distance from the plane through [center], smaller = closer to the sun
  float texel() const { return 2.0f * radius / size; }
  // x, y in texels, d = distance along dir
  void project(const V3& p, float& x, float& y, float& d) const {
    V3 q = p - center;
    x = (dot(q, right) / radius * 0.5f + 0.5f) * size;
    y = (dot(q, up) / radius * 0.5f + 0.5f) * size;
    d = dot(q, dir);
  }
  void splat(const V3& a, const V3& b, const V3& c) {
    float ax, ay, ad, bx, by, bd, cx, cy, cd;
    project(a, ax, ay, ad); project(b, bx, by, bd); project(c, cx, cy, cd);
    int x0 = std::max(0, (int)std::floor(std::min(ax, std::min(bx, cx)) - 0.5f));
    int x1 = std::min(size - 1, (int)std::ceil(std::max(ax, std::max(bx, cx)) + 0.5f));
    int y0 = std::max(0, (int)std::floor(std::min(ay, std::min(by, cy)) - 0.5f));
    int y1 = std::min(size - 1, (int)std::ceil(std::max(ay, std::max(by, cy)) + 0.5f));
    if (x0 > x1 || y0 > y1) return;
    float den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy);
    if (std::fabs(den) < 1e-9f) return;
    const float eps = -0.02f;  // slightly generous edges: no pin holes
    for (int y = y0; y <= y1; y++) {
      for (int x = x0; x <= x1; x++) {
        float px = x + 0.5f, py = y + 0.5f;
        float w0 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / den;
        float w1 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / den;
        float w2 = 1.0f - w0 - w1;
        if (w0 < eps || w1 < eps || w2 < eps) continue;
        float d = w0 * ad + w1 * bd + w2 * cd;
        float& s = depth[(size_t)y * size + x];
        if (d < s) s = d;
      }
    }
  }
  // 0 = fully in shadow, 1 = lit. [nl] is the surface normal times light direction.
  float lit(const V3& wp, const V3& n, float ndl) const {
    float t = texel();
    V3 p = wp + n * (t * 1.5f);   // push off the surface (normal offset)
    float x, y, d;
    project(p, x, y, d);
    float bias = t * (1.0f + 2.0f * (1.0f - std::min(1.0f, ndl)));
    float sum = 0;
    int cnt = 0;
    for (int j = -1; j <= 1; j++) {
      for (int i = -1; i <= 1; i++) {
        int sx = (int)std::floor(x) + i, sy = (int)std::floor(y) + j;
        if (sx < 0 || sy < 0 || sx >= size || sy >= size) { sum += 1; cnt++; continue; }  // outside the map: lit
        sum += (d - bias <= depth[(size_t)sy * size + sx]) ? 1.0f : 0.0f;
        cnt++;
      }
    }
    return sum / cnt;
  }
};

struct Shading {
  const World* world;
  const Instance* inst;
  const Texture* tex;
  const Texture* normalTex = nullptr;
  const Texture* mrTex = nullptr;
  V3 eye;
  const ShadowMap* shadow = nullptr;     // null: no shadows this frame
  const Light* shadowLight = nullptr;    // the light that casts them (and sun for PBR IBL)
  V3 triT{1, 0, 0}, triB{0, 0, 1};
  bool hasTangent = false;
};

inline float toSrgb(float c) {
  c = std::max(0.0f, std::min(1.0f, c));
  return std::pow(c, 1.0f / 2.2f);
}

// Reads one texel of a mip level as linear color (wraps around).
inline void texel(const Texture& t, int level, int w, int h, int x, int y, float* out) {
  static const std::array<float, 256> lut = []() {
    std::array<float, 256> a{};
    for (int i = 0; i < 256; i++) a[i] = std::pow(i / 255.0f, 2.2f);
    return a;
  }();
  x = ((x % w) + w) % w;
  y = ((y % h) + h) % h;
  const std::vector<uint8_t>& d = level == 0 ? t.rgba : t.mips[level - 1];
  const uint8_t* p = &d[((size_t)y * w + x) * 4];
  out[0] = lut[p[0]]; out[1] = lut[p[1]]; out[2] = lut[p[2]];
}

// Bilinear sample of the mip level that matches `lod`.
void sampleTexture(const Texture& t, float lod, float u, float v, float* rgb) {
  int level = std::min(t.levels() - 1, std::max(0, (int)(lod + 0.5f)));
  int w = std::max(1, t.w >> level), h = std::max(1, t.h >> level);
  float fx = u * w - 0.5f, fy = v * h - 0.5f;
  int x0 = (int)std::floor(fx), y0 = (int)std::floor(fy);
  float tx = fx - x0, ty = fy - y0;
  float a[3], b[3], c[3], d[3];
  texel(t, level, w, h, x0, y0, a); texel(t, level, w, h, x0 + 1, y0, b);
  texel(t, level, w, h, x0, y0 + 1, c); texel(t, level, w, h, x0 + 1, y0 + 1, d);
  for (int k = 0; k < 3; k++)
    rgb[k] = (a[k] * (1 - tx) + b[k] * tx) * (1 - ty) + (c[k] * (1 - tx) + d[k] * tx) * ty;
}



// Bilinear raw [0..1] sampler for data textures (normal maps, metallic/roughness/AO maps).
void sampleTextureRaw(const Texture& t, float lod, float u, float v, float* rgb) {
  int level = std::min(t.levels() - 1, std::max(0, (int)(lod + 0.5f)));
  int w = std::max(1, t.w >> level), h = std::max(1, t.h >> level);
  float fx = u * w - 0.5f, fy = v * h - 0.5f;
  int x0 = (int)std::floor(fx), y0 = (int)std::floor(fy);
  float tx = fx - x0, ty = fy - y0;
  auto px = [&](int x, int y, float* o) {
    x = ((x % w) + w) % w;
    y = ((y % h) + h) % h;
    const std::vector<uint8_t>& d = level == 0 ? t.rgba : t.mips[level - 1];
    const uint8_t* p = &d[((size_t)y * w + x) * 4];
    o[0] = p[0] / 255.0f; o[1] = p[1] / 255.0f; o[2] = p[2] / 255.0f;
  };
  float a[3], b[3], c[3], d[3];
  px(x0, y0, a); px(x0 + 1, y0, b); px(x0, y0 + 1, c); px(x0 + 1, y0 + 1, d);
  for (int k = 0; k < 3; k++)
    rgb[k] = (a[k] * (1 - tx) + b[k] * tx) * (1 - ty) + (c[k] * (1 - tx) + d[k] * tx) * ty;
}

V3 sampleCubemap(const Environment& e, const V3& d) {
  int S = e.cubemapSize;
  float ax = std::fabs(d.x), ay = std::fabs(d.y), az = std::fabs(d.z);
  int face = 0;
  float u = 0, v = 0, ma = 1;
  if (ax >= ay && ax >= az) {
    ma = std::max(1e-5f, ax);
    if (d.x > 0) { face = 0; u = -d.z / ma; v = -d.y / ma; }
    else         { face = 1; u =  d.z / ma; v = -d.y / ma; }
  } else if (ay >= ax && ay >= az) {
    ma = std::max(1e-5f, ay);
    if (d.y > 0) { face = 2; u =  d.x / ma; v =  d.z / ma; }
    else         { face = 3; u =  d.x / ma; v = -d.z / ma; }
  } else {
    ma = std::max(1e-5f, az);
    if (d.z > 0) { face = 4; u =  d.x / ma; v = -d.y / ma; }
    else         { face = 5; u = -d.x / ma; v = -d.y / ma; }
  }
  int x = std::max(0, std::min(S - 1, (int)((u * 0.5f + 0.5f) * S)));
  int y = std::max(0, std::min(S - 1, (int)((v * 0.5f + 0.5f) * S)));
  size_t off = ((size_t)face * S * S + (size_t)y * S + x) * 4;
  const uint8_t* p = &e.cubemapRgba[off];
  return V3(std::pow(p[0] / 255.0f, 2.2f), std::pow(p[1] / 255.0f, 2.2f), std::pow(p[2] / 255.0f, 2.2f));
}

// Procedural environment reflection lookup (sky gradient + ground bounce + sun disc) for PBR IBL.
V3 sampleEnvIbl(const Environment& e, const Light* sun, const V3& dir, float roughness) {
  if (e.cubemapSize > 0 && e.cubemapRgba.size() >= (size_t)e.cubemapSize * e.cubemapSize * 4 * 6) {
    V3 cm = sampleCubemap(e, dir);
    V3 avg = lerp(e.ground, e.skyHorizon, 0.5f);
    return lerp(cm, avg, roughness * roughness * 0.55f);
  }
  float y = std::max(-1.0f, std::min(1.0f, dir.y));
  V3 sky;
  if (y >= 0.0f) {
    float t = std::pow(y, 0.55f);
    sky = lerp(e.skyHorizon, e.skyTop, t);
  } else {
    float t = std::pow(-y, 0.6f);
    sky = lerp(e.skyHorizon * 0.65f, e.ground, t);
  }
  // Rough surfaces blur toward average hemisphere light
  V3 avg = lerp(e.ground, e.skyHorizon, 0.5f);
  sky = lerp(sky, avg, roughness * roughness * 0.65f);
  if (sun && sun->alive && sun->type == 0) {
    V3 toSun = -norm(sun->vec);
    float sd = std::max(0.0f, dot(dir, toSun));
    float expPow = 16.0f + (1.0f - roughness) * (1.0f - roughness) * 240.0f;
    float sunGlow = std::pow(sd, expPow) * (1.2f - 0.8f * roughness);
    sky += sun->color * (sun->intensity * sunGlow);
  }
  return sky;
}

V3 shadePbr(const Shading& s, const V3& albedo, const V3& wp, const V3& n, const V3& view,
            float metallic, float roughness, float ao) {
  const Instance& in = *s.inst;
  const Environment& e = s.world->env;
  metallic = std::max(0.0f, std::min(1.0f, metallic));
  roughness = std::max(0.04f, std::min(1.0f, roughness));
  ao = std::max(0.0f, std::min(1.0f, ao));
  float cc = in.clearcoat;
  float ccRough = in.clearcoatRoughness;
  float ccA = ccRough * ccRough;
  float ccA2 = ccA * ccA;
  float a = roughness * roughness;
  float a2 = a * a;
  float ndv = std::max(0.001f, dot(n, view));

  V3 f0 = lerp(V3(0.04f, 0.04f, 0.04f), albedo, metallic);
  const float kPi = 3.14159265f;

  V3 Lo(0, 0, 0);
  for (const Light& L : s.world->lights) {
    if (!L.alive) continue;
    V3 l;
    float att = 1.0f;
    if (L.type == 0) {
      l = -norm(L.vec);
    } else {
      if (L.range <= 1e-4f) continue;
      V3 d = L.vec - wp;
      float dist = len(d);
      l = d * (1.0f / std::max(dist, 1e-4f));
      float q = std::max(0.0f, 1.0f - dist / L.range);
      att = q * q;
    }
    float ndl = std::max(0.0f, dot(n, l));
    if (ndl <= 0.0f) continue;
    if (s.shadow && &L == s.shadowLight && in.receiveShadow) {
      float lit = s.shadow->lit(wp, n, ndl);
      att *= 1.0f - (1.0f - lit) * e.shadowStrength;
    }
    V3 radiance = L.color * (L.intensity * att);
    V3 h = norm(l + view);
    float ndh = std::max(0.0f, dot(n, h));
    float hdv = std::max(0.0f, dot(h, view));

    // GGX normal distribution
    float denom = ndh * ndh * (a2 - 1.0f) + 1.0f;
    float D = a2 / (kPi * denom * denom + 1e-6f);
    // Smith Schlick-GGX geometry
    float k = (roughness + 1.0f) * (roughness + 1.0f) * 0.125f;
    float gv = ndv / (ndv * (1.0f - k) + k);
    float gl = ndl / (ndl * (1.0f - k) + k);
    float G = gv * gl;
    // Schlick Fresnel
    float fPow = std::pow(1.0f - hdv, 5.0f);
    V3 F(f0.x + (1.0f - f0.x) * fPow, f0.y + (1.0f - f0.y) * fPow, f0.z + (1.0f - f0.z) * fPow);

    V3 spec = F * (D * G / (4.0f * ndv * ndl + 1e-4f));
    V3 kD = V3(1.0f - F.x, 1.0f - F.y, 1.0f - F.z) * (1.0f - metallic);
    V3 diff(kD.x * albedo.x / kPi, kD.y * albedo.y / kPi, kD.z * albedo.z / kPi);
    V3 baseL((diff.x + spec.x) * radiance.x * ndl,
             (diff.y + spec.y) * radiance.y * ndl,
             (diff.z + spec.z) * radiance.z * ndl);
    if (cc > 0.001f) {
      float ccDen = ndh * ndh * (ccA2 - 1.0f) + 1.0f;
      float Dc = ccA2 / (kPi * ccDen * ccDen + 1e-6f);
      float Fc = 0.04f + 0.96f * fPow;
      float Gc = 0.25f / std::max(0.05f, hdv * hdv);
      float ccSpec = Dc * Gc * Fc * cc;
      baseL = baseL * (1.0f - Fc * cc) + radiance * (ccSpec * ndl);
    }
    Lo += baseL;
  }

  // Hemisphere diffuse IBL + Fresnel specular sky reflection IBL
  float hemi = n.y * 0.5f + 0.5f;
  V3 irr = e.useAmbientColor ? e.ambientColor : lerp(e.ground, e.skyTop, hemi) * (e.ambient * 1.6f);
  float fViewPow = std::pow(1.0f - ndv, 5.0f);
  V3 fView(
    f0.x + (std::max(1.0f - roughness, f0.x) - f0.x) * fViewPow,
    f0.y + (std::max(1.0f - roughness, f0.y) - f0.y) * fViewPow,
    f0.z + (std::max(1.0f - roughness, f0.z) - f0.z) * fViewPow
  );
  V3 kDAmb = V3(1.0f - fView.x, 1.0f - fView.y, 1.0f - fView.z) * (1.0f - metallic);
  V3 ambDiff(kDAmb.x * albedo.x * irr.x, kDAmb.y * albedo.y * irr.y, kDAmb.z * albedo.z * irr.z);

  V3 refl = norm(n * (2.0f * dot(n, view)) - view);
  V3 envRefl = sampleEnvIbl(e, s.shadowLight, refl, roughness);
  float reflScale = (1.0f - roughness * 0.65f);
  V3 ambSpec(fView.x * envRefl.x * reflScale, fView.y * envRefl.y * reflScale, fView.z * envRefl.z * reflScale);
  V3 ambTotal = ambDiff + ambSpec;
  if (cc > 0.001f) {
    float fcView = 0.04f + 0.96f * fViewPow;
    V3 ccEnv = sampleEnvIbl(e, s.shadowLight, refl, ccRough);
    ambTotal = ambTotal * (1.0f - fcView * cc) + ccEnv * (fcView * cc * 1.15f);
  }

  V3 col = ambTotal * ao + Lo + albedo * in.emissive;
  if (e.fogDensity > 0) {
    float d = len(wp - s.eye);
    float f = 1.0f - std::exp(-e.fogDensity * e.fogDensity * d * d);
    col = lerp(col, e.fogColor, f);
  }
  return col;
}

V3 shade(const Shading& s, const V3& wp, V3 n, float u, float v, float lod) {
  const Instance& in = *s.inst;
  float r = in.color[0], g = in.color[1], b = in.color[2];
  if (s.tex && s.tex->w > 0) {
    float tc[3];
    sampleTexture(*s.tex, lod, u, v, tc);
    r *= tc[0]; g *= tc[1]; b *= tc[2];
  }
  V3 albedo(r, g, b);
  if (in.unlit) return albedo;
  n = norm(n);
  if (s.normalTex && s.normalTex->w > 0 && s.hasTangent) {
    float nm[3];
    sampleTextureRaw(*s.normalTex, lod, u, v, nm);
    float nx = nm[0] * 2.0f - 1.0f, ny = nm[1] * 2.0f - 1.0f, nz = nm[2] * 2.0f - 1.0f;
    V3 T = norm(s.triT - n * dot(s.triT, n));
    V3 B = cross(n, T);
    if (dot(B, s.triB) < 0.0f) B = -B;
    n = norm(T * nx + B * ny + n * nz);
  }
  V3 view = norm(s.eye - wp);
  if (in.pbr) {
    float met = in.metallic, rough = in.roughness, aoVal = in.ao;
    if (s.mrTex && s.mrTex->w > 0) {
      float mr[3];
      sampleTextureRaw(*s.mrTex, lod, u, v, mr);
      aoVal *= mr[0]; rough *= mr[1]; met *= mr[2];
    }
    return shadePbr(s, albedo, wp, n, view, met, rough, aoVal);
  }
  const Environment& e = s.world->env;
  float hemi = n.y * 0.5f + 0.5f;
  V3 amb = e.useAmbientColor ? e.ambientColor : lerp(e.ground, e.skyTop, hemi) * e.ambient * 1.6f;
  V3 diff = amb, spec;
  for (const Light& L : s.world->lights) {
    if (!L.alive) continue;
    V3 l;
    float att = 1;
    if (L.type == 0) l = -norm(L.vec);
    else {
      if (L.range <= 1e-4f) continue;
      V3 d = L.vec - wp;
      float dist = len(d);
      l = d * (1.0f / std::max(dist, 1e-4f));
      float q = std::max(0.0f, 1.0f - dist / L.range);
      att = q * q;
    }
    float ndl = std::max(0.0f, dot(n, l));
    if (ndl <= 0) continue;
    if (s.shadow && &L == s.shadowLight && in.receiveShadow) {
      float lit = s.shadow->lit(wp, n, ndl);
      att *= 1.0f - (1.0f - lit) * s.world->env.shadowStrength;
    }
    V3 lc = L.color * (L.intensity * att);
    diff += lc * ndl;
    if (in.specular > 0) {
      V3 h = norm(l + view);
      spec += lc * (in.specular * std::pow(std::max(0.0f, dot(n, h)), 48.0f));
    }
  }
  V3 col(albedo.x * diff.x + spec.x + in.emissive * albedo.x, albedo.y * diff.y + spec.y + in.emissive * albedo.y,
         albedo.z * diff.z + spec.z + in.emissive * albedo.z);
  if (e.fogDensity > 0) {
    float d = len(wp - s.eye);
    float f = 1.0f - std::exp(-e.fogDensity * e.fogDensity * d * d);
    col = lerp(col, e.fogColor, f);
  }
  return col;
}

void drawTri(Target& T, Shading sh, const Vtx& a0, const Vtx& b0, const Vtx& c0, bool doubleSided, bool transparent = false) {
  // near plane clip (z >= -w)
  Vtx in[3] = {a0, b0, c0};
  Vtx poly[4];
  int n = 0;
  for (int i = 0; i < 3; i++) {
    const Vtx& p = in[i];
    const Vtx& q = in[(i + 1) % 3];
    float dp = p.cz + p.cw - 1e-4f, dq = q.cz + q.cw - 1e-4f;
    if (dp >= 0) poly[n++] = p;
    if ((dp >= 0) != (dq >= 0)) poly[n++] = mix(p, q, dp / (dp - dq));
  }
  if (n < 3) return;
  for (int k = 1; k + 1 < n; k++) {
    const Vtx* tv[3] = {&poly[0], &poly[k], &poly[k + 1]};
    float sx[3], sy[3], sz[3], iw[3];
    for (int i = 0; i < 3; i++) {
      iw[i] = 1.0f / tv[i]->cw;
      sx[i] = (tv[i]->cx * iw[i] * 0.5f + 0.5f) * T.w;
      sy[i] = (1.0f - (tv[i]->cy * iw[i] * 0.5f + 0.5f)) * T.h;
      sz[i] = tv[i]->cz * iw[i];
    }
    float area = (sx[1] - sx[0]) * (sy[2] - sy[0]) - (sx[2] - sx[0]) * (sy[1] - sy[0]);
    // screen y is down, so CCW in NDC gives negative area here.
    if (area == 0) continue;
    bool back = area > 0;
    if (back && !doubleSided) continue;
    float invArea = 1.0f / area;
    if (sh.normalTex && sh.normalTex->w > 0) {
      V3 e1 = tv[1]->wp - tv[0]->wp, e2 = tv[2]->wp - tv[0]->wp;
      float du1 = tv[1]->u - tv[0]->u, dv1 = tv[1]->v - tv[0]->v;
      float du2 = tv[2]->u - tv[0]->u, dv2 = tv[2]->v - tv[0]->v;
      float det = du1 * dv2 - du2 * dv1;
      if (std::fabs(det) > 1e-8f) {
        float invD = 1.0f / det;
        sh.triT = norm((e1 * dv2 - e2 * dv1) * invD);
        sh.triB = norm((e2 * du1 - e1 * du2) * invD);
        sh.hasTangent = true;
      } else { sh.hasTangent = false; }
    }
    // Which mip level fits this triangle: texels per pixel (one value per triangle).
    float lod = 0;
    if (sh.tex && sh.tex->w > 0) {
      float uvArea = std::fabs((tv[1]->u - tv[0]->u) * (tv[2]->v - tv[0]->v) - (tv[2]->u - tv[0]->u) * (tv[1]->v - tv[0]->v));
      float texels = uvArea * (float)sh.tex->w * (float)sh.tex->h;
      float px = std::fabs(area);
      if (texels > 0 && px > 1e-6f) lod = std::max(0.0f, 0.5f * std::log2(texels / px));
    }
    int x0 = std::max(0, (int)std::floor(std::min({sx[0], sx[1], sx[2]})));
    int x1 = std::min(T.w - 1, (int)std::ceil(std::max({sx[0], sx[1], sx[2]})));
    int y0 = std::max(0, (int)std::floor(std::min({sy[0], sy[1], sy[2]})));
    int y1 = std::min(T.h - 1, (int)std::ceil(std::max({sy[0], sy[1], sy[2]})));
    for (int y = y0; y <= y1; y++) {
      for (int x = x0; x <= x1; x++) {
        float px = x + 0.5f, py = y + 0.5f;
        float w0 = ((sx[1] - px) * (sy[2] - py) - (sx[2] - px) * (sy[1] - py)) * invArea;
        float w1 = ((sx[2] - px) * (sy[0] - py) - (sx[0] - px) * (sy[2] - py)) * invArea;
        float w2 = 1.0f - w0 - w1;
        if (w0 < 0 || w1 < 0 || w2 < 0) continue;
        float z = w0 * sz[0] + w1 * sz[1] + w2 * sz[2];
        if (z < -1 || z > 1) continue;
        float& d = T.depth[y * T.w + x];
        if (z >= d) continue;
        if (!transparent) d = z;
        float p0 = w0 * iw[0], p1 = w1 * iw[1], p2 = w2 * iw[2];
        float ps = 1.0f / (p0 + p1 + p2);
        p0 *= ps; p1 *= ps; p2 *= ps;
        V3 wp = tv[0]->wp * p0 + tv[1]->wp * p1 + tv[2]->wp * p2;
        V3 nn = tv[0]->n * p0 + tv[1]->n * p1 + tv[2]->n * p2;
        if (back) nn = -nn;
        float u = tv[0]->u * p0 + tv[1]->u * p1 + tv[2]->u * p2;
        float v = tv[0]->v * p0 + tv[1]->v * p1 + tv[2]->v * p2;
        V3 c = shade(sh, wp, nn, u, v, lod);
        uint8_t* o = &T.rgba[(y * T.w + x) * 4];
        if (!transparent) {
          o[0] = (uint8_t)(toSrgb(c.x) * 255.0f + 0.5f);
          o[1] = (uint8_t)(toSrgb(c.y) * 255.0f + 0.5f);
          o[2] = (uint8_t)(toSrgb(c.z) * 255.0f + 0.5f);
          o[3] = 255;
        } else {
          V3 vn = norm(sh.eye - wp);
          float ndv = std::max(0.0f, dot(norm(nn), vn));
          float fresnel = 0.04f + 0.96f * std::pow(1.0f - ndv, 5.0f);
          float effAlpha = std::clamp(sh.inst->alpha * sh.inst->color[3], 0.0f, 1.0f);
          float a = std::min(1.0f, effAlpha + (1.0f - effAlpha) * fresnel);
          float sr = toSrgb(c.x) * 255.0f, sg = toSrgb(c.y) * 255.0f, sb = toSrgb(c.z) * 255.0f;
          o[0] = (uint8_t)(o[0] * (1.0f - a) + sr * a + 0.5f);
          o[1] = (uint8_t)(o[1] * (1.0f - a) + sg * a + 0.5f);
          o[2] = (uint8_t)(o[2] * (1.0f - a) + sb * a + 0.5f);
          o[3] = 255;
        }
      }
    }
  }
}

}  // namespace

// World positions of every vertex of an instance (with skinning).
static void worldPositions(const World& w, const Instance& in, const Mesh& m, std::vector<V3>& out) {
  const float* skin = nullptr;
  int nSkin = 0;
  if (in.animator >= 0 && in.animator < (int)w.animators.size() &&
      w.animators[in.animator].alive && !w.animators[in.animator].skin.empty() && m.skinned()) {
    skin = w.animators[in.animator].skin.data();
    nSkin = (int)(w.animators[in.animator].skin.size() / 16);
  }
  int nv = m.vertexCount();
  out.resize(nv);
  for (int i = 0; i < nv; i++) {
    const float* f = &m.verts[i * 8];
    V3 p(f[0], f[1], f[2]);
    if (skin) {
      V3 sp;
      for (int k = 0; k < 4; k++) {
        float wt = m.weights[i * 4 + k];
        int j = m.joints[i * 4 + k];
        if (wt <= 0 || j >= nSkin) continue;
        M4 sm;
        std::memcpy(sm.m, skin + j * 16, 64);
        sp += transformPoint(sm, p) * wt;
      }
      p = sp;
    }
    out[i] = transformPoint(in.xf, p);
  }
}


// ---------------------------------------------------------------- picture effects

namespace {
inline float srgbToLin(float c) { return c <= 0.04045f ? c / 12.92f : std::pow((c + 0.055f) / 1.055f, 2.4f); }
inline float linToSrgb(float c) { c = std::max(0.0f, c); return c <= 0.0031308f ? c * 12.92f : 1.055f * std::pow(c, 1.0f / 2.4f) - 0.055f; }
inline float acesFilm(float x) { return std::min(1.0f, std::max(0.0f, (x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f))); }

// Blurs a w*h float rgb image in place with a box blur done twice (looks like a soft glow).
void blurRgb(std::vector<float>& img, int w, int h, int radius) {
  if (radius < 1) return;
  std::vector<float> tmp(img.size());
  for (int pass = 0; pass < 2; pass++) {
    for (int y = 0; y < h; y++)       // horizontal
      for (int c = 0; c < 3; c++) {
        float sum = 0;
        for (int x = -radius; x <= radius; x++) sum += img[((size_t)y * w + std::min(w - 1, std::max(0, x))) * 3 + c];
        for (int x = 0; x < w; x++) {
          tmp[((size_t)y * w + x) * 3 + c] = sum / (2 * radius + 1);
          int add = std::min(w - 1, x + radius + 1), sub = std::max(0, x - radius);
          sum += img[((size_t)y * w + add) * 3 + c] - img[((size_t)y * w + sub) * 3 + c];
        }
      }
    for (int x = 0; x < w; x++)       // vertical
      for (int c = 0; c < 3; c++) {
        float sum = 0;
        for (int y = -radius; y <= radius; y++) sum += tmp[((size_t)std::min(h - 1, std::max(0, y)) * w + x) * 3 + c];
        for (int y = 0; y < h; y++) {
          img[((size_t)y * w + x) * 3 + c] = sum / (2 * radius + 1);
          int add = std::min(h - 1, y + radius + 1), sub = std::max(0, y - radius);
          sum += tmp[((size_t)add * w + x) * 3 + c] - tmp[((size_t)sub * w + x) * 3 + c];
        }
      }
  }
}
}  // namespace

void applyPost(const Environment& e, int width, int height, uint8_t* rgba) {
  if (!e.post || width < 2 || height < 2) return;
  const size_t n = (size_t)width * height;
  std::vector<float> lin(n * 3);
  float lut[256];
  for (int i = 0; i < 256; i++) lut[i] = srgbToLin(i / 255.0f);
  for (size_t i = 0; i < n; i++) for (int c = 0; c < 3; c++) lin[i * 3 + c] = lut[rgba[i * 4 + c]];

  if (e.bloom > 0) {   // glow: keep the bright parts, shrink, blur, add back
    const int f = 4, bw = std::max(1, width / f), bh = std::max(1, height / f);
    std::vector<float> small((size_t)bw * bh * 3, 0.0f);
    float thr = srgbToLin(std::min(0.999f, std::max(0.0f, e.bloomThreshold)));
    for (int y = 0; y < bh; y++) for (int x = 0; x < bw; x++) {
      float acc[3] = {0, 0, 0}; int cnt = 0;
      for (int dy = 0; dy < f; dy++) for (int dx = 0; dx < f; dx++) {
        int sx = std::min(width - 1, x * f + dx), sy = std::min(height - 1, y * f + dy);
        const float* p = &lin[((size_t)sy * width + sx) * 3];
        float l = 0.2126f * p[0] + 0.7152f * p[1] + 0.0722f * p[2];
        if (l > thr) { float k = (l - thr) / std::max(1e-4f, 1.0f - thr); for (int c = 0; c < 3; c++) acc[c] += p[c] * std::min(1.0f, k * 2.0f); }
        cnt++;
      }
      for (int c = 0; c < 3; c++) small[((size_t)y * bw + x) * 3 + c] = acc[c] / cnt;
    }
    blurRgb(small, bw, bh, std::max(2, width / 64));
    for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
      float fx = std::min((float)(bw - 1), (x + 0.5f) / f - 0.5f), fy = std::min((float)(bh - 1), (y + 0.5f) / f - 0.5f);
      fx = std::max(0.0f, fx); fy = std::max(0.0f, fy);
      int x0 = (int)fx, y0 = (int)fy, x1 = std::min(bw - 1, x0 + 1), y1 = std::min(bh - 1, y0 + 1);
      float ax = fx - x0, ay = fy - y0;
      for (int c = 0; c < 3; c++) {
        float v = (small[((size_t)y0 * bw + x0) * 3 + c] * (1 - ax) + small[((size_t)y0 * bw + x1) * 3 + c] * ax) * (1 - ay) +
                  (small[((size_t)y1 * bw + x0) * 3 + c] * (1 - ax) + small[((size_t)y1 * bw + x1) * 3 + c] * ax) * ay;
        lin[((size_t)y * width + x) * 3 + c] += v * e.bloom;
      }
    }
  }

  const float cx = (width - 1) * 0.5f, cy = (height - 1) * 0.5f;
  for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
    float* p = &lin[((size_t)y * width + x) * 3];
    for (int c = 0; c < 3; c++) p[c] *= e.exposure;
    if (e.tonemap == 1) for (int c = 0; c < 3; c++) p[c] = p[c] / (1.0f + p[c]) * 1.0f;
    else if (e.tonemap == 2) for (int c = 0; c < 3; c++) p[c] = acesFilm(p[c]);
    float g[3];
    for (int c = 0; c < 3; c++) g[c] = linToSrgb(p[c]);
    float l = 0.2126f * g[0] + 0.7152f * g[1] + 0.0722f * g[2];
    for (int c = 0; c < 3; c++) {
      float v = l + (g[c] - l) * e.saturation;          // saturation
      v = (v - 0.5f) * e.contrast + 0.5f;              // contrast around middle gray
      if (e.vignette > 0) {                            // round vignette, 0 in the middle
        float dx = (x - cx) / cx, dy = (y - cy) / cy;
        float d = std::min(1.0f, std::sqrt(dx * dx + dy * dy) / 1.4142f);
        v *= 1.0f - e.vignette * d * d;
      }
      rgba[((size_t)y * width + x) * 4 + c] = (uint8_t)std::lround(std::min(1.0f, std::max(0.0f, v)) * 255.0f);
    }
  }
}


// ---------------------------------------------------------------- debug lines and particles

static void drawDebugLines(const World& w, Target& T, const M4& vp) {
  auto clipOf = [&](const V3& p, float* c) {
    c[0] = vp.m[0] * p.x + vp.m[4] * p.y + vp.m[8] * p.z + vp.m[12];
    c[1] = vp.m[1] * p.x + vp.m[5] * p.y + vp.m[9] * p.z + vp.m[13];
    c[2] = vp.m[2] * p.x + vp.m[6] * p.y + vp.m[10] * p.z + vp.m[14];
    c[3] = vp.m[3] * p.x + vp.m[7] * p.y + vp.m[11] * p.z + vp.m[15];
  };
  for (const DebugLine& L : w.debugLines) {
    float a[4], b[4];
    clipOf(L.a, a); clipOf(L.b, b);
    float da = a[2] + a[3] - 1e-4f, db = b[2] + b[3] - 1e-4f;   // inside the near plane when >= 0
    if (da < 0 && db < 0) continue;
    if (da < 0) { float t = da / (da - db); for (int i = 0; i < 4; i++) a[i] += (b[i] - a[i]) * t; }
    else if (db < 0) { float t = db / (db - da); for (int i = 0; i < 4; i++) b[i] += (a[i] - b[i]) * t; }
    if (a[3] <= 1e-6f || b[3] <= 1e-6f) continue;
    float x0 = (a[0] / a[3] * 0.5f + 0.5f) * T.w, y0 = (1.0f - (a[1] / a[3] * 0.5f + 0.5f)) * T.h, z0 = a[2] / a[3];
    float x1 = (b[0] / b[3] * 0.5f + 0.5f) * T.w, y1 = (1.0f - (b[1] / b[3] * 0.5f + 0.5f)) * T.h, z1 = b[2] / b[3];
    float dx = x1 - x0, dy = y1 - y0;
    int steps = (int)std::ceil(std::max(std::fabs(dx), std::fabs(dy)));
    if (steps > 20000) continue;                 // far off screen
    steps = std::max(1, steps);
    float al = std::clamp(L.al, 0.0f, 1.0f);
    float lr = std::clamp(L.r, 0.0f, 1.0f);
    float lg = std::clamp(L.g, 0.0f, 1.0f);
    float lb = std::clamp(L.bl, 0.0f, 1.0f);
    for (int i = 0; i <= steps; i++) {
      float t = (float)i / steps;
      int x = (int)std::floor(x0 + dx * t), y = (int)std::floor(y0 + dy * t);
      if (x < 0 || y < 0 || x >= T.w || y >= T.h) continue;
      float z = z0 + (z1 - z0) * t;
      if (z < -1 || z > 1) continue;
      if (w.debugDepthTest && z > T.depth[(size_t)y * T.w + x] + 2e-4f) continue;
      uint8_t* o = &T.rgba[((size_t)y * T.w + x) * 4];
      o[0] = (uint8_t)(o[0] * (1 - al) + lr * 255.0f * al + 0.5f);
      o[1] = (uint8_t)(o[1] * (1 - al) + lg * 255.0f * al + 0.5f);
      o[2] = (uint8_t)(o[2] * (1 - al) + lb * 255.0f * al + 0.5f);
    }
  }
}

static void drawParticles(const World& w, Target& T, const M4& view, const M4& vp, const M4& proj) {
  if (w.particles.empty()) return;
  struct Item { float viewZ; const ParticleSprite* p; };
  std::vector<Item> order;
  order.reserve(w.particles.size());
  for (const ParticleSprite& p : w.particles) {
    float vz = view.m[2] * p.pos.x + view.m[6] * p.pos.y + view.m[10] * p.pos.z + view.m[14];   // negative in front of the camera
    if (vz >= -1e-3f) continue;
    order.push_back({vz, &p});
  }
  std::sort(order.begin(), order.end(), [](const Item& a, const Item& b) { return a.viewZ < b.viewZ; });   // far first
  const float focal = proj.m[5] * T.h * 0.5f;
  for (const Item& it : order) {
    const ParticleSprite& p = *it.p;
    float cx = vp.m[0] * p.pos.x + vp.m[4] * p.pos.y + vp.m[8] * p.pos.z + vp.m[12];
    float cy = vp.m[1] * p.pos.x + vp.m[5] * p.pos.y + vp.m[9] * p.pos.z + vp.m[13];
    float cz = vp.m[2] * p.pos.x + vp.m[6] * p.pos.y + vp.m[10] * p.pos.z + vp.m[14];
    float cw = vp.m[3] * p.pos.x + vp.m[7] * p.pos.y + vp.m[11] * p.pos.z + vp.m[15];
    if (cw <= 1e-4f) continue;
    float zn = cz / cw;
    if (zn < -1 || zn > 1) continue;
    float sx = (cx / cw * 0.5f + 0.5f) * T.w, sy = (1.0f - (cy / cw * 0.5f + 0.5f)) * T.h;
    float rad = 0.5f * p.size * focal / cw;
    if (rad < 0.3f || rad > 4000) continue;
    int x0 = std::max(0, (int)std::floor(sx - rad)), x1 = std::min(T.w - 1, (int)std::ceil(sx + rad));
    int y0 = std::max(0, (int)std::floor(sy - rad)), y1 = std::min(T.h - 1, (int)std::ceil(sy + rad));
    const bool additive = (p.flags & 1) != 0;
    const int shape = (p.flags >> 1) & 3;
    float pr = std::clamp(p.r, 0.0f, 1.0f);
    float pg = std::clamp(p.g, 0.0f, 1.0f);
    float pb = std::clamp(p.b, 0.0f, 1.0f);
    for (int y = y0; y <= y1; y++) for (int x = x0; x <= x1; x++) {
      if (zn >= T.depth[(size_t)y * T.w + x]) continue;      // behind something solid
      float dx = (x + 0.5f - sx) / rad, dy = (y + 0.5f - sy) / rad;
      float cov;
      if (shape == 2) cov = 1.0f;                           // square
      else {
        float r2 = dx * dx + dy * dy;
        if (r2 >= 1.0f) continue;
        cov = shape == 1 ? std::min(1.0f, (1.0f - std::sqrt(r2)) * rad) : (1.0f - r2) * (1.0f - r2);
      }
      float a = std::clamp(p.a, 0.0f, 1.0f) * cov;
      uint8_t* o = &T.rgba[((size_t)y * T.w + x) * 4];
      if (additive) {
        o[0] = (uint8_t)std::min(255.0f, o[0] + pr * 255.0f * a + 0.5f);
        o[1] = (uint8_t)std::min(255.0f, o[1] + pg * 255.0f * a + 0.5f);
        o[2] = (uint8_t)std::min(255.0f, o[2] + pb * 255.0f * a + 0.5f);
      } else {
        o[0] = (uint8_t)(o[0] * (1 - a) + pr * 255.0f * a + 0.5f);
        o[1] = (uint8_t)(o[1] * (1 - a) + pg * 255.0f * a + 0.5f);
        o[2] = (uint8_t)(o[2] * (1 - a) + pb * 255.0f * a + 0.5f);
      }
    }
  }
}

void renderSoftware(const World& w, int width, int height, uint8_t* rgba) {
  Target T{width, height, rgba, std::vector<float>((size_t)width * height, 2.0f)};
  const Environment& e = w.env;
  const Camera& cam = w.camera;
  M4 view = cam.useMatrices ? cam.view : lookAt(cam.pos, cam.target, cam.up);
  M4 proj = cam.useMatrices ? cam.proj : perspective(cam.fovY, (float)width / height, cam.nearZ, cam.farZ);
  M4 vp = proj * view;
  // Always find directional sunLight for PBR IBL & sky; only build shadow map when e.shadows is enabled.
  ShadowMap sm;
  const ShadowMap* smp = nullptr;
  const Light* sunLight = nullptr;
  for (const Light& L : w.lights) {
    if (L.alive && L.type == 0 && len(L.vec) > 1e-6f && L.intensity > 0) { sunLight = &L; break; }
  }
  if (e.shadows && sunLight) {
    sm.size = std::max(256, std::min(4096, e.shadowMapSize));
    sm.radius = std::max(1.0f, e.shadowDistance);
    V3 fwd = cam.useMatrices ? norm(V3(-view.m[2], -view.m[6], -view.m[10])) : norm(cam.target - cam.pos);
    sm.center = cam.pos + fwd * (sm.radius * 0.5f);
    sm.dir = norm(sunLight->vec);
    V3 upRef = std::fabs(sm.dir.y) > 0.99f ? V3(1, 0, 0) : V3(0, 1, 0);
    sm.right = norm(cross(sm.dir, upRef));
    sm.up = cross(sm.right, sm.dir);
    sm.depth.assign((size_t)sm.size * sm.size, 1e30f);
    std::vector<V3> wpos;
    for (const Instance& in : w.instances) {
      if (!in.alive || !in.visible || !in.castShadow || in.mesh < 0 || in.mesh >= (int)w.meshes.size()) continue;
      const Mesh& m = w.meshes[in.mesh];
      worldPositions(w, in, m, wpos);
      for (size_t t = 0; t + 2 < m.idx.size(); t += 3) sm.splat(wpos[m.idx[t]], wpos[m.idx[t + 1]], wpos[m.idx[t + 2]]);
    }
    smp = &sm;
  }
  // Physical 3D ray-projected sky gradient + directional sun disc & atmospheric Mie halo
  {
    V3 camFwd = cam.useMatrices ? norm(V3(-view.m[2], -view.m[6], -view.m[10])) : norm(cam.target - cam.pos);
    V3 camRight = cam.useMatrices ? norm(V3(view.m[0], view.m[4], view.m[8])) : norm(cross(camFwd, cam.up));
    V3 camUp = cross(camRight, camFwd);
    float tanHalfY = (proj.m[5] > 1e-4f) ? (1.0f / proj.m[5]) : std::tan(cam.fovY * 0.5f);
    float tanHalfX = (proj.m[0] > 1e-4f) ? (1.0f / proj.m[0]) : (tanHalfY * (float)width / std::max(1, height));
    const Light* skySun = sunLight;
    V3 sunDir = skySun ? norm(skySun->vec * -1.0f) : V3(0, 1, 0);
    V3 sunCol = skySun ? skySun->color : V3(1.0f, 0.95f, 0.85f);
    for (int y = 0; y < height; y++) {
      float ndcY = 1.0f - 2.0f * ((y + 0.5f) / (float)height);
      for (int x = 0; x < width; x++) {
        float ndcX = 2.0f * ((x + 0.5f) / (float)width) - 1.0f;
        V3 rd = norm(camFwd + camRight * (ndcX * tanHalfX) + camUp * (ndcY * tanHalfY));
        V3 c;
        if (rd.y >= 0.0f) {
          float h = std::pow(std::min(1.0f, rd.y), 0.55f);
          c = lerp(e.skyHorizon, e.skyTop, h);
        } else {
          float h = std::min(1.0f, -rd.y * 2.5f);
          c = lerp(e.skyHorizon, e.ground, h);
        }
        if (skySun && rd.y > -0.08f) {
          float sd = std::max(0.0f, dot(rd, sunDir));
          float halo = std::pow(sd, 10.0f) * 0.42f + std::pow(sd, 160.0f) * 1.15f;
          float disc = sd > 0.9986f ? 2.4f : (sd > 0.9972f ? (sd - 0.9972f) / 0.0014f * 2.4f : 0.0f);
          float fade = std::min(1.0f, std::max(0.0f, (rd.y + 0.06f) / 0.12f));
          c += sunCol * ((halo + disc) * fade);
        }
        uint8_t* o = &rgba[((size_t)y * width + x) * 4];
        o[0] = (uint8_t)(toSrgb(std::min(1.0f, c.x)) * 255);
        o[1] = (uint8_t)(toSrgb(std::min(1.0f, c.y)) * 255);
        o[2] = (uint8_t)(toSrgb(std::min(1.0f, c.z)) * 255);
        o[3] = 255;
      }
    }
  }
  std::vector<Vtx> vtx;
  auto drawInstance = [&](const Instance& in, bool isTransparent) {
    const Mesh& m = w.meshes[in.mesh];
    Shading sh;
    sh.world = &w;
    sh.inst = &in;
    sh.tex = (in.texture >= 0 && in.texture < (int)w.textures.size()) ? &w.textures[in.texture] : nullptr;
    sh.normalTex = (in.normalTex >= 0 && in.normalTex < (int)w.textures.size()) ? &w.textures[in.normalTex] : nullptr;
    sh.mrTex = (in.mrTex >= 0 && in.mrTex < (int)w.textures.size()) ? &w.textures[in.mrTex] : nullptr;
    sh.eye = cam.pos;
    sh.shadow = smp;
    sh.shadowLight = sunLight;
    const float* skin = nullptr;
    int nSkin = 0;
    if (in.animator >= 0 && in.animator < (int)w.animators.size() &&
        w.animators[in.animator].alive && !w.animators[in.animator].skin.empty() && m.skinned()) {
      skin = w.animators[in.animator].skin.data();
      nSkin = (int)(w.animators[in.animator].skin.size() / 16);
    }
    // Inverse-transpose of upper-left 3x3 of in.xf for correct normal transformation under non-uniform scale.
    float nm[9];
    {
      auto A = [&](int r, int c) { return in.xf.m[c * 4 + r]; };
      float c00 = A(1, 1) * A(2, 2) - A(1, 2) * A(2, 1);
      float c01 = -(A(1, 0) * A(2, 2) - A(1, 2) * A(2, 0));
      float c02 = A(1, 0) * A(2, 1) - A(1, 1) * A(2, 0);
      float c10 = -(A(0, 1) * A(2, 2) - A(0, 2) * A(2, 1));
      float c11 = A(0, 0) * A(2, 2) - A(0, 2) * A(2, 0);
      float c12 = -(A(0, 0) * A(2, 1) - A(0, 1) * A(2, 0));
      float c20 = A(0, 1) * A(1, 2) - A(0, 2) * A(1, 1);
      float c21 = -(A(0, 0) * A(1, 2) - A(0, 2) * A(1, 0));
      float c22 = A(0, 0) * A(1, 1) - A(0, 1) * A(1, 0);
      float det = A(0, 0) * c00 + A(0, 1) * c01 + A(0, 2) * c02;
      if (std::fabs(det) > 1e-20f) {
        float id = 1.0f / det;
        nm[0] = c00 * id; nm[1] = c01 * id; nm[2] = c02 * id;
        nm[3] = c10 * id; nm[4] = c11 * id; nm[5] = c12 * id;
        nm[6] = c20 * id; nm[7] = c21 * id; nm[8] = c22 * id;
      } else {
        nm[0] = A(0, 0); nm[1] = A(0, 1); nm[2] = A(0, 2);
        nm[3] = A(1, 0); nm[4] = A(1, 1); nm[5] = A(1, 2);
        nm[6] = A(2, 0); nm[7] = A(2, 1); nm[8] = A(2, 2);
      }
    }
    int nv = m.vertexCount();
    vtx.resize(nv);
    for (int i = 0; i < nv; i++) {
      const float* f = &m.verts[i * 8];
      V3 p(f[0], f[1], f[2]), nrm(f[3], f[4], f[5]);
      if (skin) {
        V3 sp, sn;
        for (int k = 0; k < 4; k++) {
          float wt = m.weights[i * 4 + k];
          int j = m.joints[i * 4 + k];
          if (wt <= 0 || j >= nSkin) continue;
          M4 sm;
          std::memcpy(sm.m, skin + j * 16, 64);
          sp += transformPoint(sm, p) * wt;
          sn += transformDir(sm, nrm) * wt;
        }
        p = sp; nrm = sn;
      }
      V3 wp = transformPoint(in.xf, p);
      V3 wn = norm(V3(nm[0] * nrm.x + nm[1] * nrm.y + nm[2] * nrm.z,
                      nm[3] * nrm.x + nm[4] * nrm.y + nm[5] * nrm.z,
                      nm[6] * nrm.x + nm[7] * nrm.y + nm[8] * nrm.z));
      Vtx& v = vtx[i];
      v.wp = wp; v.n = wn; v.u = f[6]; v.v = f[7];
      v.cx = vp.at(0, 0) * wp.x + vp.at(0, 1) * wp.y + vp.at(0, 2) * wp.z + vp.at(0, 3);
      v.cy = vp.at(1, 0) * wp.x + vp.at(1, 1) * wp.y + vp.at(1, 2) * wp.z + vp.at(1, 3);
      v.cz = vp.at(2, 0) * wp.x + vp.at(2, 1) * wp.y + vp.at(2, 2) * wp.z + vp.at(2, 3);
      v.cw = vp.at(3, 0) * wp.x + vp.at(3, 1) * wp.y + vp.at(3, 2) * wp.z + vp.at(3, 3);
    }
    for (size_t t = 0; t + 2 < m.idx.size(); t += 3)
      drawTri(T, sh, vtx[m.idx[t]], vtx[m.idx[t + 1]], vtx[m.idx[t + 2]], in.doubleSided, isTransparent);
  };

  std::vector<std::pair<float, const Instance*>> transparents;
  for (const Instance& in : w.instances) {
    if (!in.alive || !in.visible || in.shadowOnly || in.mesh < 0 || in.mesh >= (int)w.meshes.size()) continue;
    float effAlpha = in.alpha * in.color[3];
    if (effAlpha < 0.999f) {
      V3 center(in.xf.m[12], in.xf.m[13], in.xf.m[14]);
      transparents.push_back({len(center - cam.pos), &in});
    } else {
      drawInstance(in, false);
    }
  }

  if (e.ssao && e.ssaoStrength > 0.001f && width >= 8 && height >= 8) {
    const int rad = e.ssaoRadius;
    static const int kOff[8][2] = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{-1,1},{1,-1},{-1,-1}};
    for (int y = rad; y < height - rad; y++) {
      for (int x = rad; x < width - rad; x++) {
        float dz = T.depth[(size_t)y * width + x];
        if (dz >= 1.5f) continue;
        int occ = 0;
        for (int k = 0; k < 8; k++) {
          float nz = T.depth[(size_t)(y + kOff[k][1] * rad) * width + (x + kOff[k][0] * rad)];
          float diff = dz - nz;
          if (diff > 0.00035f && diff < 0.018f) occ++;
        }
        if (occ > 1) {
          float factor = 1.0f - (float)(occ - 1) / 7.0f * e.ssaoStrength;
          uint8_t* o = &rgba[((size_t)y * width + x) * 4];
          o[0] = (uint8_t)(o[0] * factor + 0.5f);
          o[1] = (uint8_t)(o[1] * factor + 0.5f);
          o[2] = (uint8_t)(o[2] * factor + 0.5f);
        }
      }
    }
  }

  if (!transparents.empty()) {
    std::sort(transparents.begin(), transparents.end(),
              [](const auto& a, const auto& b) { return a.first > b.first; });
    for (const auto& pair : transparents) drawInstance(*pair.second, true);
  }
  drawDebugLines(w, T, vp);
  drawParticles(w, T, view, vp, proj);
  applyPost(w.env, width, height, rgba);
  if (e.fxaa && width >= 3 && height >= 3) {
    std::vector<uint8_t> src(rgba, rgba + (size_t)width * height * 4);
    auto luma = [&](int x, int y) -> float {
      const uint8_t* p = &src[((size_t)y * width + x) * 4];
      return 0.299f * p[0] + 0.587f * p[1] + 0.114f * p[2];
    };
    for (int y = 1; y < height - 1; y++) {
      for (int x = 1; x < width - 1; x++) {
        float lM = luma(x, y);
        float lN = luma(x, y - 1), lS = luma(x, y + 1);
        float lW = luma(x - 1, y), lE = luma(x + 1, y);
        float lMin = std::min({lM, lN, lS, lW, lE});
        float lMax = std::max({lM, lN, lS, lW, lE});
        float contrast = lMax - lMin;
        if (contrast < 22.0f) continue;
        float blend = std::min(0.45f, (contrast - 22.0f) / 140.0f);
        const uint8_t* pM = &src[((size_t)y * width + x) * 4];
        const uint8_t* pN = &src[((size_t)(y - 1) * width + x) * 4];
        const uint8_t* pS = &src[((size_t)(y + 1) * width + x) * 4];
        const uint8_t* pW = &src[((size_t)y * width + (x - 1)) * 4];
        const uint8_t* pE = &src[((size_t)y * width + (x + 1)) * 4];
        uint8_t* o = &rgba[((size_t)y * width + x) * 4];
        for (int c = 0; c < 3; c++) {
          float avg = 0.25f * (pN[c] + pS[c] + pW[c] + pE[c]);
          o[c] = (uint8_t)(pM[c] * (1.0f - blend) + avg * blend + 0.5f);
        }
      }
    }
  }
}

}  // namespace tej
