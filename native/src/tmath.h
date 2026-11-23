// tej3d math: small, dependency free. Right handed, +Y up, column major matrices.
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <utility>

namespace tej {

struct V3 {
  float x = 0, y = 0, z = 0;
  V3() = default;
  V3(float a, float b, float c) : x(a), y(b), z(c) {}
  float& operator[](int i) { return i == 0 ? x : (i == 1 ? y : z); }
  const float& operator[](int i) const { return i == 0 ? x : (i == 1 ? y : z); }
  V3 operator-() const { return V3(-x, -y, -z); }
  V3& operator+=(const V3& o) { x += o.x; y += o.y; z += o.z; return *this; }
  V3& operator-=(const V3& o) { x -= o.x; y -= o.y; z -= o.z; return *this; }
  V3& operator*=(float s) { x *= s; y *= s; z *= s; return *this; }
};
inline V3 operator+(const V3& a, const V3& b) { return V3(a.x + b.x, a.y + b.y, a.z + b.z); }
inline V3 operator-(const V3& a, const V3& b) { return V3(a.x - b.x, a.y - b.y, a.z - b.z); }
inline V3 operator*(const V3& a, float s) { return V3(a.x * s, a.y * s, a.z * s); }
inline V3 operator*(float s, const V3& a) { return a * s; }
inline float dot(const V3& a, const V3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline float len2(const V3& a) { return dot(a, a); }
inline float len(const V3& a) { return std::sqrt(dot(a, a)); }
inline V3 cross(const V3& a, const V3& b) {
  return V3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}
inline V3 norm(const V3& v) {
  float l = len(v);
  return l > 1e-12f ? v * (1.0f / l) : V3();
}
inline V3 lerp(const V3& a, const V3& b, float t) { return a + (b - a) * t; }

struct Q {
  float x = 0, y = 0, z = 0, w = 1;
  Q() = default;
  Q(float a, float b, float c, float d) : x(a), y(b), z(c), w(d) {}
};
inline Q operator*(const Q& a, const Q& b) {
  return Q(a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
           a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
           a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
           a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z);
}
inline Q conj(const Q& q) { return Q(-q.x, -q.y, -q.z, q.w); }
inline Q normalize(const Q& q) {
  float l = std::sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
  if (l < 1e-12f) return Q();
  float i = 1.0f / l;
  return Q(q.x * i, q.y * i, q.z * i, q.w * i);
}
inline V3 rotate(const Q& q, const V3& v) {
  V3 u(q.x, q.y, q.z);
  V3 t = cross(u, v) * 2.0f;
  return v + t * q.w + cross(u, t);
}
inline void axes(const Q& q, V3 out[3]) {
  out[0] = rotate(q, V3(1, 0, 0));
  out[1] = rotate(q, V3(0, 1, 0));
  out[2] = rotate(q, V3(0, 0, 1));
}
inline Q axisAngle(const V3& axis, float a) {
  V3 n = norm(axis);
  float s = std::sin(a * 0.5f);
  return Q(n.x * s, n.y * s, n.z * s, std::cos(a * 0.5f));
}
inline Q slerp(const Q& a, const Q& b0, float t) {
  Q b = b0;
  float d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
  if (d < 0) { b = Q(-b.x, -b.y, -b.z, -b.w); d = -d; }
  if (d > 0.9995f) {
    return normalize(Q(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, a.w + (b.w - a.w) * t));
  }
  float th = std::acos(d), s = std::sin(th);
  float wa = std::sin((1 - t) * th) / s, wb = std::sin(t * th) / s;
  return Q(a.x * wa + b.x * wb, a.y * wa + b.y * wb, a.z * wa + b.z * wb, a.w * wa + b.w * wb);
}

// Column major 4x4: element (row r, col c) = m[c * 4 + r].
struct M4 {
  float m[16];
  M4() { for (int i = 0; i < 16; i++) m[i] = 0; m[0] = m[5] = m[10] = m[15] = 1; }
  float at(int r, int c) const { return m[c * 4 + r]; }
};
inline M4 operator*(const M4& a, const M4& b) {
  M4 r;
  for (int c = 0; c < 4; c++)
    for (int row = 0; row < 4; row++) {
      float s = 0;
      for (int k = 0; k < 4; k++) s += a.m[k * 4 + row] * b.m[c * 4 + k];
      r.m[c * 4 + row] = s;
    }
  return r;
}
inline M4 trs(const V3& t, const Q& q, const V3& s) {
  V3 ax[3];
  axes(q, ax);
  M4 r;
  r.m[0] = ax[0].x * s.x; r.m[1] = ax[0].y * s.x; r.m[2] = ax[0].z * s.x; r.m[3] = 0;
  r.m[4] = ax[1].x * s.y; r.m[5] = ax[1].y * s.y; r.m[6] = ax[1].z * s.y; r.m[7] = 0;
  r.m[8] = ax[2].x * s.z; r.m[9] = ax[2].y * s.z; r.m[10] = ax[2].z * s.z; r.m[11] = 0;
  r.m[12] = t.x; r.m[13] = t.y; r.m[14] = t.z; r.m[15] = 1;
  return r;
}
inline M4 inverseAffine(const M4& s) {
  auto A = [&](int r, int c) { return s.m[c * 4 + r]; };
  float C00 = A(1, 1) * A(2, 2) - A(1, 2) * A(2, 1);
  float C01 = -(A(1, 0) * A(2, 2) - A(1, 2) * A(2, 0));
  float C02 = A(1, 0) * A(2, 1) - A(1, 1) * A(2, 0);
  float C10 = -(A(0, 1) * A(2, 2) - A(0, 2) * A(2, 1));
  float C11 = A(0, 0) * A(2, 2) - A(0, 2) * A(2, 0);
  float C12 = -(A(0, 0) * A(2, 1) - A(0, 1) * A(2, 0));
  float C20 = A(0, 1) * A(1, 2) - A(0, 2) * A(1, 1);
  float C21 = -(A(0, 0) * A(1, 2) - A(0, 2) * A(1, 0));
  float C22 = A(0, 0) * A(1, 1) - A(0, 1) * A(1, 0);
  float det = A(0, 0) * C00 + A(0, 1) * C01 + A(0, 2) * C02;
  float id = std::fabs(det) > 1e-20f ? 1.0f / det : 0.0f;
  float inv[3][3] = {{C00 * id, C10 * id, C20 * id}, {C01 * id, C11 * id, C21 * id}, {C02 * id, C12 * id, C22 * id}};
  M4 r;
  for (int row = 0; row < 3; row++)
    for (int c = 0; c < 3; c++) r.m[c * 4 + row] = inv[row][c];
  float tx = s.m[12], ty = s.m[13], tz = s.m[14];
  for (int row = 0; row < 3; row++) r.m[12 + row] = -(inv[row][0] * tx + inv[row][1] * ty + inv[row][2] * tz);
  return r;
}
inline M4 lookAt(const V3& eye, const V3& target, const V3& up) {
  V3 f = norm(target - eye);
  V3 s = norm(cross(f, up));
  if (len2(s) < 1e-12f) s = norm(cross(f, V3(0, 0, 1)));
  V3 u = cross(s, f);
  M4 r;
  r.m[0] = s.x; r.m[4] = s.y; r.m[8] = s.z; r.m[12] = -dot(s, eye);
  r.m[1] = u.x; r.m[5] = u.y; r.m[9] = u.z; r.m[13] = -dot(u, eye);
  r.m[2] = -f.x; r.m[6] = -f.y; r.m[10] = -f.z; r.m[14] = dot(f, eye);
  r.m[3] = 0; r.m[7] = 0; r.m[11] = 0; r.m[15] = 1;
  return r;
}
inline M4 perspective(float fovY, float aspect, float n, float f) {
  float t = std::tan(fovY * 0.5f);
  M4 r;
  for (int i = 0; i < 16; i++) r.m[i] = 0;
  r.m[0] = 1.0f / (aspect * t);
  r.m[5] = 1.0f / t;
  r.m[10] = (f + n) / (n - f);
  r.m[11] = -1.0f;
  r.m[14] = 2.0f * f * n / (n - f);
  return r;
}
inline V3 transformPoint(const M4& a, const V3& p) {
  return V3(a.m[0] * p.x + a.m[4] * p.y + a.m[8] * p.z + a.m[12],
            a.m[1] * p.x + a.m[5] * p.y + a.m[9] * p.z + a.m[13],
            a.m[2] * p.x + a.m[6] * p.y + a.m[10] * p.z + a.m[14]);
}
inline V3 transformDir(const M4& a, const V3& p) {
  return V3(a.m[0] * p.x + a.m[4] * p.y + a.m[8] * p.z,
            a.m[1] * p.x + a.m[5] * p.y + a.m[9] * p.z,
            a.m[2] * p.x + a.m[6] * p.y + a.m[10] * p.z);
}

}  // namespace tej
