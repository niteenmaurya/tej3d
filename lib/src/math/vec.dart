/// Our own vectors, matrices and quaternions (no third party package).
///
/// Conventions (same as most engines and as OpenGL):
/// - Right handed, +Y up, a camera looks along -Z.
/// - Matrices are column major (`storage[column * 4 + row]`) and are used with column vectors:
///   `world = parent * local`, `point' = M * point`.
/// - Quaternions are `(x, y, z, w)` and are applied by [Quaternion.rotateVector].
/// - Numbers are 64 bit `double`. Everything is mutable; operators make new objects, methods named
///   like a verb (`normalize`, `scale`, `add`) change the object itself.
///
/// Flutter also has a `Matrix4`. If you import Flutter and this library together, write
/// `import 'package:flutter/widgets.dart' hide Matrix4;`.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Multiply degrees by this to get radians.
const double degrees2Radians = math.pi / 180.0;

/// Multiply radians by this to get degrees.
const double radians2Degrees = 180.0 / math.pi;

// ======================================================================
// Vector2
// ======================================================================

class Vector2 {
  Vector2(this.x, this.y);
  Vector2.zero() : x = 0, y = 0;
  Vector2.all(double v) : x = v, y = v;
  Vector2.copy(Vector2 o) : x = o.x, y = o.y;

  double x, y;

  double get length2 => x * x + y * y;
  double get length => math.sqrt(length2);

  Vector2 clone() => Vector2(x, y);
  Vector2 normalized() {
    final l = length;
    return l == 0 ? Vector2.zero() : Vector2(x / l, y / l);
  }

  double normalize() {
    final l = length;
    if (l != 0) {
      x /= l;
      y /= l;
    }
    return l;
  }

  double dot(Vector2 o) => x * o.x + y * o.y;
  double distanceTo(Vector2 o) => (this - o).length;
  void setValues(double nx, double ny) {
    x = nx;
    y = ny;
  }

  void setFrom(Vector2 o) {
    x = o.x;
    y = o.y;
  }

  Vector2 operator +(Vector2 o) => Vector2(x + o.x, y + o.y);
  Vector2 operator -(Vector2 o) => Vector2(x - o.x, y - o.y);
  Vector2 operator -() => Vector2(-x, -y);
  Vector2 operator *(Object o) => o is Vector2 ? Vector2(x * o.x, y * o.y) : Vector2(x * (o as num), y * o);
  Vector2 operator /(Object o) => o is Vector2 ? Vector2(x / o.x, y / o.y) : Vector2(x / (o as num), y / o);
  double operator [](int i) => i == 0 ? x : (i == 1 ? y : throw RangeError.index(i, this, 'i', null, 2));
  void operator []=(int i, double v) {
    if (i == 0) {
      x = v;
    } else if (i == 1) {
      y = v;
    } else {
      throw RangeError.index(i, this, 'i', null, 2);
    }
  }

  @override
  bool operator ==(Object other) => other is Vector2 && x == other.x && y == other.y;
  @override
  int get hashCode => Object.hash(x, y);
  @override
  String toString() => '[$x,$y]';
}

// ======================================================================
// Vector3
// ======================================================================

class Vector3 {
  Vector3(this.x, this.y, this.z);
  Vector3.zero() : x = 0, y = 0, z = 0;
  Vector3.all(double v) : x = v, y = v, z = v;
  Vector3.copy(Vector3 o) : x = o.x, y = o.y, z = o.z;

  double x, y, z;

  double get length2 => x * x + y * y + z * z;
  double get length => math.sqrt(length2);
  bool get isNaN => x.isNaN || y.isNaN || z.isNaN;
  bool get isInfinite => x.isInfinite || y.isInfinite || z.isInfinite;

  double get r => x;
  double get g => y;
  double get b => z;
  Vector2 get xy => Vector2(x, y);
  Vector2 get xz => Vector2(x, z);

  Vector3 clone() => Vector3(x, y, z);
  void copyInto(Vector3 o) => o.setValues(x, y, z);

  void setValues(double nx, double ny, double nz) {
    x = nx;
    y = ny;
    z = nz;
  }

  void setFrom(Vector3 o) => setValues(o.x, o.y, o.z);
  void setZero() => setValues(0, 0, 0);

  /// Makes the length 1 (in place). Returns the old length. A zero vector stays zero.
  double normalize() {
    final l = length;
    if (l == 0) return 0;
    x /= l;
    y /= l;
    z /= l;
    return l;
  }

  /// A copy with length 1 (a zero vector gives a zero vector).
  Vector3 normalized() => clone()..normalize();

  double dot(Vector3 o) => x * o.x + y * o.y + z * o.z;

  Vector3 cross(Vector3 o) => Vector3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);

  double distanceTo(Vector3 o) => math.sqrt(distanceToSquared(o));
  double distanceToSquared(Vector3 o) {
    final dx = x - o.x, dy = y - o.y, dz = z - o.z;
    return dx * dx + dy * dy + dz * dz;
  }

  double angleTo(Vector3 o) {
    final d = length * o.length;
    if (d == 0) return 0;
    return math.acos((dot(o) / d).clamp(-1.0, 1.0));
  }

  /// In place: this += o.
  void add(Vector3 o) => setValues(x + o.x, y + o.y, z + o.z);

  /// In place: this += o * s.
  void addScaled(Vector3 o, double s) => setValues(x + o.x * s, y + o.y * s, z + o.z * s);

  /// In place: this -= o.
  void sub(Vector3 o) => setValues(x - o.x, y - o.y, z - o.z);

  /// In place: this *= s.
  void scale(double s) => setValues(x * s, y * s, z * s);

  Vector3 scaled(double s) => Vector3(x * s, y * s, z * s);
  void negate() => setValues(-x, -y, -z);
  void absolute() => setValues(x.abs(), y.abs(), z.abs());

  /// In place: each part limited to [lo]..[hi] (per part).
  void clamp(Vector3 lo, Vector3 hi) {
    x = x.clamp(lo.x, hi.x).toDouble();
    y = y.clamp(lo.y, hi.y).toDouble();
    z = z.clamp(lo.z, hi.z).toDouble();
  }

  void clampScalar(double lo, double hi) {
    x = x.clamp(lo, hi).toDouble();
    y = y.clamp(lo, hi).toDouble();
    z = z.clamp(lo, hi).toDouble();
  }

  void floor() => setValues(x.floorToDouble(), y.floorToDouble(), z.floorToDouble());
  void ceil() => setValues(x.ceilToDouble(), y.ceilToDouble(), z.ceilToDouble());
  void round() => setValues(x.roundToDouble(), y.roundToDouble(), z.roundToDouble());

  /// In place: transform as a point by [m] (with the perspective divide).
  void applyMatrix4(Matrix4 m) {
    final e = m.storage;
    final wDenom = e[3] * x + e[7] * y + e[11] * z + e[15];
    if (wDenom.abs() < 1e-12) {
      setValues(
        e[0] * x + e[4] * y + e[8] * z + e[12],
        e[1] * x + e[5] * y + e[9] * z + e[13],
        e[2] * x + e[6] * y + e[10] * z + e[14],
      );
      return;
    }
    final w = 1.0 / wDenom;
    setValues(
      (e[0] * x + e[4] * y + e[8] * z + e[12]) * w,
      (e[1] * x + e[5] * y + e[9] * z + e[13]) * w,
      (e[2] * x + e[6] * y + e[10] * z + e[14]) * w,
    );
  }

  /// In place: turned by [q].
  void applyQuaternion(Quaternion q) => setFrom(q.rotateVector(this));

  /// Mirror of this vector at a surface with the unit [normal].
  Vector3 reflected(Vector3 normal) => this - normal * (2.0 * normal.dot(this));

  static Vector3 min(Vector3 a, Vector3 b) => Vector3(math.min(a.x, b.x), math.min(a.y, b.y), math.min(a.z, b.z));
  static Vector3 max(Vector3 a, Vector3 b) => Vector3(math.max(a.x, b.x), math.max(a.y, b.y), math.max(a.z, b.z));

  Vector3 operator +(Vector3 o) => Vector3(x + o.x, y + o.y, z + o.z);
  Vector3 operator -(Vector3 o) => Vector3(x - o.x, y - o.y, z - o.z);
  Vector3 operator -() => Vector3(-x, -y, -z);

  /// A number scales it; a [Vector3] multiplies part by part.
  Vector3 operator *(Object o) => o is Vector3 ? Vector3(x * o.x, y * o.y, z * o.z) : Vector3(x * (o as num), y * o, z * o);
  Vector3 operator /(Object o) => o is Vector3 ? Vector3(x / o.x, y / o.y, z / o.z) : Vector3(x / (o as num), y / o, z / o);

  double operator [](int i) {
    switch (i) {
      case 0:
        return x;
      case 1:
        return y;
      case 2:
        return z;
    }
    throw RangeError.index(i, this, 'i', null, 3);
  }

  void operator []=(int i, double v) {
    switch (i) {
      case 0:
        x = v;
      case 1:
        y = v;
      case 2:
        z = v;
      default:
        throw RangeError.index(i, this, 'i', null, 3);
    }
  }

  @override
  bool operator ==(Object other) => other is Vector3 && x == other.x && y == other.y && z == other.z;
  @override
  int get hashCode => Object.hash(x, y, z);
  @override
  String toString() => '[$x,$y,$z]';
}

// ======================================================================
// Vector4
// ======================================================================

class Vector4 {
  Vector4(this.x, this.y, this.z, this.w);
  Vector4.zero() : x = 0, y = 0, z = 0, w = 0;
  Vector4.all(double v) : x = v, y = v, z = v, w = v;
  Vector4.copy(Vector4 o) : x = o.x, y = o.y, z = o.z, w = o.w;

  double x, y, z, w;

  double get r => x;
  double get g => y;
  double get b => z;
  double get a => w;
  set r(double v) => x = v;
  set g(double v) => y = v;
  set b(double v) => z = v;
  set a(double v) => w = v;
  Vector3 get xyz => Vector3(x, y, z);

  double get length2 => x * x + y * y + z * z + w * w;
  double get length => math.sqrt(length2);

  Vector4 clone() => Vector4(x, y, z, w);
  void setValues(double nx, double ny, double nz, double nw) {
    x = nx;
    y = ny;
    z = nz;
    w = nw;
  }

  void setFrom(Vector4 o) => setValues(o.x, o.y, o.z, o.w);
  void setZero() => setValues(0, 0, 0, 0);
  double dot(Vector4 o) => x * o.x + y * o.y + z * o.z + w * o.w;
  void add(Vector4 o) => setValues(x + o.x, y + o.y, z + o.z, w + o.w);
  void sub(Vector4 o) => setValues(x - o.x, y - o.y, z - o.z, w - o.w);
  void scale(double s) => setValues(x * s, y * s, z * s, w * s);
  Vector4 scaled(double s) => Vector4(x * s, y * s, z * s, w * s);

  void clamp(Vector4 lo, Vector4 hi) {
    x = x.clamp(lo.x, hi.x).toDouble();
    y = y.clamp(lo.y, hi.y).toDouble();
    z = z.clamp(lo.z, hi.z).toDouble();
    w = w.clamp(lo.w, hi.w).toDouble();
  }

  Vector4 operator +(Vector4 o) => Vector4(x + o.x, y + o.y, z + o.z, w + o.w);
  Vector4 operator -(Vector4 o) => Vector4(x - o.x, y - o.y, z - o.z, w - o.w);
  Vector4 operator -() => Vector4(-x, -y, -z, -w);
  Vector4 operator *(Object o) =>
      o is Vector4 ? Vector4(x * o.x, y * o.y, z * o.z, w * o.w) : Vector4(x * (o as num), y * o, z * o, w * o);
  Vector4 operator /(Object o) =>
      o is Vector4 ? Vector4(x / o.x, y / o.y, z / o.z, w / o.w) : Vector4(x / (o as num), y / o, z / o, w / o);

  double operator [](int i) {
    switch (i) {
      case 0:
        return x;
      case 1:
        return y;
      case 2:
        return z;
      case 3:
        return w;
    }
    throw RangeError.index(i, this, 'i', null, 4);
  }

  void operator []=(int i, double v) {
    switch (i) {
      case 0:
        x = v;
      case 1:
        y = v;
      case 2:
        z = v;
      case 3:
        w = v;
      default:
        throw RangeError.index(i, this, 'i', null, 4);
    }
  }

  @override
  bool operator ==(Object other) => other is Vector4 && x == other.x && y == other.y && z == other.z && w == other.w;
  @override
  int get hashCode => Object.hash(x, y, z, w);
  @override
  String toString() => '[$x,$y,$z,$w]';
}

// ======================================================================
// Matrix3
// ======================================================================

/// 3x3 matrix, column major.
class Matrix3 {
  Matrix3.zero() : storage = Float64List(9);
  Matrix3.identity() : storage = Float64List(9) {
    storage[0] = storage[4] = storage[8] = 1.0;
  }
  Matrix3.copy(Matrix3 o) : storage = Float64List.fromList(o.storage);

  /// The three columns.
  Matrix3.columns(Vector3 a, Vector3 b, Vector3 c) : storage = Float64List(9) {
    storage[0] = a.x;
    storage[1] = a.y;
    storage[2] = a.z;
    storage[3] = b.x;
    storage[4] = b.y;
    storage[5] = b.z;
    storage[6] = c.x;
    storage[7] = c.y;
    storage[8] = c.z;
  }

  /// `storage[column * 3 + row]`.
  final Float64List storage;

  int index(int row, int col) => col * 3 + row;
  double entry(int row, int col) => storage[col * 3 + row];
  void setEntry(int row, int col, double v) => storage[col * 3 + row] = v;
  double trace() => storage[0] + storage[4] + storage[8];
  Matrix3 clone() => Matrix3.copy(this);

  /// Fills the nine numbers column by column (first three = first column).
  void setValues(double a0, double a1, double a2, double a3, double a4, double a5, double a6, double a7, double a8) {
    storage[0] = a0;
    storage[1] = a1;
    storage[2] = a2;
    storage[3] = a3;
    storage[4] = a4;
    storage[5] = a5;
    storage[6] = a6;
    storage[7] = a7;
    storage[8] = a8;
  }

  Vector3 getColumn(int c) => Vector3(storage[c * 3], storage[c * 3 + 1], storage[c * 3 + 2]);

  /// A new vector: this * v.
  Vector3 transformed(Vector3 v) => Vector3(
        storage[0] * v.x + storage[3] * v.y + storage[6] * v.z,
        storage[1] * v.x + storage[4] * v.y + storage[7] * v.z,
        storage[2] * v.x + storage[5] * v.y + storage[8] * v.z,
      );

  /// In place: v = this * v. Returns v.
  Vector3 transform(Vector3 v) => v..setFrom(transformed(v));

  Matrix3 operator *(Matrix3 o) {
    final r = Matrix3.zero();
    for (var c = 0; c < 3; c++) {
      for (var row = 0; row < 3; row++) {
        var s = 0.0;
        for (var k = 0; k < 3; k++) {
          s += storage[k * 3 + row] * o.storage[c * 3 + k];
        }
        r.storage[c * 3 + row] = s;
      }
    }
    return r;
  }

  Matrix3 transposed() {
    final r = Matrix3.zero();
    for (var c = 0; c < 3; c++) {
      for (var row = 0; row < 3; row++) {
        r.storage[row * 3 + c] = storage[c * 3 + row];
      }
    }
    return r;
  }

  double determinant() {
    final s = storage;
    return s[0] * (s[4] * s[8] - s[5] * s[7]) - s[3] * (s[1] * s[8] - s[2] * s[7]) + s[6] * (s[1] * s[5] - s[2] * s[4]);
  }

  @override
  String toString() => 'Matrix3($storage)';
}

// ======================================================================
// Quaternion
// ======================================================================

class Quaternion {
  Quaternion(this.x, this.y, this.z, this.w);
  Quaternion.identity() : x = 0, y = 0, z = 0, w = 1;
  Quaternion.copy(Quaternion o) : x = o.x, y = o.y, z = o.z, w = o.w;

  /// A turn of [radians] around [axis] (the axis is normalized for you).
  factory Quaternion.axisAngle(Vector3 axis, double radians) {
    final len = axis.length;
    if (len == 0) return Quaternion.identity();
    final s = math.sin(radians * 0.5) / len;
    return Quaternion(axis.x * s, axis.y * s, axis.z * s, math.cos(radians * 0.5));
  }

  /// From a rotation matrix (no scale in it).
  factory Quaternion.fromRotation(Matrix3 m) => Quaternion.identity()..setFromRotation(m);

  double x, y, z, w;

  double get length2 => x * x + y * y + z * z + w * w;
  double get length => math.sqrt(length2);

  Quaternion clone() => Quaternion.copy(this);
  void setValues(double nx, double ny, double nz, double nw) {
    x = nx;
    y = ny;
    z = nz;
    w = nw;
  }

  void setFrom(Quaternion o) => setValues(o.x, o.y, o.z, o.w);

  void normalize() {
    final l = length;
    if (l == 0) return;
    x /= l;
    y /= l;
    z /= l;
    w /= l;
  }

  Quaternion normalized() => clone()..normalize();

  /// The opposite turn (for a unit quaternion).
  Quaternion conjugated() => Quaternion(-x, -y, -z, w);

  /// The opposite turn (also for a quaternion that is not exactly length 1).
  Quaternion inverted() {
    final l2 = length2;
    return l2 == 0 ? Quaternion.identity() : Quaternion(-x / l2, -y / l2, -z / l2, w / l2);
  }

  double dot(Quaternion o) => x * o.x + y * o.y + z * o.z + w * o.w;

  /// First [o], then this (like matrices: `a * b` applies b first).
  Quaternion operator *(Quaternion o) => Quaternion(
        w * o.x + x * o.w + y * o.z - z * o.y,
        w * o.y + y * o.w + z * o.x - x * o.z,
        w * o.z + z * o.w + x * o.y - y * o.x,
        w * o.w - x * o.x - y * o.y - z * o.z,
      );

  /// Returns [v] turned by this quaternion (same direction as [asRotationMatrix]). Does not change [v].
  /// The quaternion must have length 1 (call [normalize] after many multiplications).
  Vector3 rotateVector(Vector3 v) {
    // v' = v + 2w(q x v) + 2 q x (q x v), with q = (x, y, z)
    final tx = 2.0 * (y * v.z - z * v.y);
    final ty = 2.0 * (z * v.x - x * v.z);
    final tz = 2.0 * (x * v.y - y * v.x);
    return Vector3(
      v.x + w * tx + (y * tz - z * ty),
      v.y + w * ty + (z * tx - x * tz),
      v.z + w * tz + (x * ty - y * tx),
    );
  }

  /// The rotation matrix of this quaternion.
  Matrix3 asRotationMatrix() {
    final l2 = length2;
    final s = l2 == 0 ? 0.0 : 2.0 / l2;
    final xs = x * s, ys = y * s, zs = z * s;
    final wx = w * xs, wy = w * ys, wz = w * zs;
    final xx = x * xs, xy = x * ys, xz = x * zs;
    final yy = y * ys, yz = y * zs, zz = z * zs;
    return Matrix3.zero()
      ..setValues(
        1.0 - (yy + zz), xy + wz, xz - wy, // column 0
        xy - wz, 1.0 - (xx + zz), yz + wx, // column 1
        xz + wy, yz - wx, 1.0 - (xx + yy), // column 2
      );
  }

  void setFromRotation(Matrix3 m) {
    final s = m.storage;
    final trace = m.trace();
    if (trace > 0.0) {
      final rad = trace + 1.0;
      if (rad <= 1e-12 || !rad.isFinite) {
        setValues(0.0, 0.0, 0.0, 1.0);
        return;
      }
      var t = math.sqrt(rad);
      w = t * 0.5;
      t = 0.5 / t;
      x = (s[5] - s[7]) * t;
      y = (s[6] - s[2]) * t;
      z = (s[1] - s[3]) * t;
    } else {
      final i = s[0] < s[4] ? (s[4] < s[8] ? 2 : 1) : (s[0] < s[8] ? 2 : 0);
      final j = (i + 1) % 3, k = (i + 2) % 3;
      final rad = m.entry(i, i) - m.entry(j, j) - m.entry(k, k) + 1.0;
      if (rad <= 1e-12 || !rad.isFinite) {
        setValues(0.0, 0.0, 0.0, 1.0);
        return;
      }
      var t = math.sqrt(rad);
      final q = [0.0, 0.0, 0.0, 0.0];
      q[i] = t * 0.5;
      t = 0.5 / t;
      q[3] = (m.entry(k, j) - m.entry(j, k)) * t;
      q[j] = (m.entry(j, i) + m.entry(i, j)) * t;
      q[k] = (m.entry(k, i) + m.entry(i, k)) * t;
      setValues(q[0], q[1], q[2], q[3]);
    }
  }

  @override
  bool operator ==(Object other) => other is Quaternion && x == other.x && y == other.y && z == other.z && w == other.w;
  @override
  int get hashCode => Object.hash(x, y, z, w);
  @override
  String toString() => '[$x,$y,$z | $w]';
}

// ======================================================================
// Matrix4
// ======================================================================

/// 4x4 matrix, column major (`storage[column * 4 + row]`), for column vectors.
class Matrix4 {
  Matrix4.zero() : storage = Float64List(16);
  Matrix4.identity() : storage = Float64List(16) {
    storage[0] = storage[5] = storage[10] = storage[15] = 1.0;
  }
  Matrix4.copy(Matrix4 o) : storage = Float64List.fromList(o.storage);

  /// Reads 16 numbers (column major).
  Matrix4.fromFloat32List(Float32List list) : storage = Float64List(16) {
    for (var i = 0; i < 16; i++) {
      storage[i] = list[i];
    }
  }

  /// A move by [t].
  Matrix4.translation(Vector3 t) : storage = Float64List(16) {
    storage[0] = storage[5] = storage[10] = storage[15] = 1.0;
    storage[12] = t.x;
    storage[13] = t.y;
    storage[14] = t.z;
  }

  /// Position, rotation and scale in one matrix (scale first, then rotation, then move).
  factory Matrix4.compose(Vector3 t, Quaternion r, Vector3 s) => Matrix4.zero()..setFromTranslationRotationScale(t, r, s);

  final Float64List storage;

  double operator [](int i) => storage[i];
  void operator []=(int i, double v) => storage[i] = v;
  double entry(int row, int col) => storage[col * 4 + row];
  void setEntry(int row, int col, double v) => storage[col * 4 + row] = v;

  Matrix4 clone() => Matrix4.copy(this);
  void setFrom(Matrix4 o) => storage.setAll(0, o.storage);
  void copyInto(Matrix4 o) => o.storage.setAll(0, storage);
  void setZero() => storage.fillRange(0, 16, 0.0);
  void setIdentity() {
    setZero();
    storage[0] = storage[5] = storage[10] = storage[15] = 1.0;
  }

  Vector3 getTranslation() => Vector3(storage[12], storage[13], storage[14]);
  void setTranslation(Vector3 t) {
    storage[12] = t.x;
    storage[13] = t.y;
    storage[14] = t.z;
  }

  /// The upper left 3x3 part, as it is (a scale stays in it).
  Matrix3 getRotation() => Matrix3.zero()
    ..setValues(storage[0], storage[1], storage[2], storage[4], storage[5], storage[6], storage[8], storage[9], storage[10]);

  void setRotation(Matrix3 r) {
    final s = r.storage;
    storage[0] = s[0];
    storage[1] = s[1];
    storage[2] = s[2];
    storage[4] = s[3];
    storage[5] = s[4];
    storage[6] = s[5];
    storage[8] = s[6];
    storage[9] = s[7];
    storage[10] = s[8];
  }

  Vector4 getColumn(int c) => Vector4(storage[c * 4], storage[c * 4 + 1], storage[c * 4 + 2], storage[c * 4 + 3]);
  Vector4 getRow(int r) => Vector4(storage[r], storage[4 + r], storage[8 + r], storage[12 + r]);

  void setFromTranslationRotationScale(Vector3 t, Quaternion q, Vector3 s) {
    final r = q.asRotationMatrix().storage;
    storage[0] = r[0] * s.x;
    storage[1] = r[1] * s.x;
    storage[2] = r[2] * s.x;
    storage[3] = 0;
    storage[4] = r[3] * s.y;
    storage[5] = r[4] * s.y;
    storage[6] = r[5] * s.y;
    storage[7] = 0;
    storage[8] = r[6] * s.z;
    storage[9] = r[7] * s.z;
    storage[10] = r[8] * s.z;
    storage[11] = 0;
    storage[12] = t.x;
    storage[13] = t.y;
    storage[14] = t.z;
    storage[15] = 1.0;
  }

  /// Splits this matrix into position, rotation and scale (the opposite of [setFromTranslationRotationScale]).
  /// A mirrored matrix gets a negative x scale.
  void decompose(Vector3 translation, Quaternion rotation, Vector3 scale) {
    var sx = math.sqrt(storage[0] * storage[0] + storage[1] * storage[1] + storage[2] * storage[2]);
    final sy = math.sqrt(storage[4] * storage[4] + storage[5] * storage[5] + storage[6] * storage[6]);
    final sz = math.sqrt(storage[8] * storage[8] + storage[9] * storage[9] + storage[10] * storage[10]);
    if (determinant() < 0) sx = -sx;
    translation.setValues(storage[12], storage[13], storage[14]);
    final ix = sx == 0 ? 0.0 : 1.0 / sx, iy = sy == 0 ? 0.0 : 1.0 / sy, iz = sz == 0 ? 0.0 : 1.0 / sz;
    final r = Matrix3.zero()
      ..setValues(storage[0] * ix, storage[1] * ix, storage[2] * ix, storage[4] * iy, storage[5] * iy, storage[6] * iy,
          storage[8] * iz, storage[9] * iz, storage[10] * iz);
    rotation.setFromRotation(r);
    scale.setValues(sx, sy, sz);
  }

  /// A new matrix: this * [o] (o is applied first).
  Matrix4 operator *(Matrix4 o) {
    final r = Matrix4.zero();
    final a = storage, b = o.storage, c = r.storage;
    for (var col = 0; col < 4; col++) {
      for (var row = 0; row < 4; row++) {
        c[col * 4 + row] = a[row] * b[col * 4] + a[4 + row] * b[col * 4 + 1] + a[8 + row] * b[col * 4 + 2] + a[12 + row] * b[col * 4 + 3];
      }
    }
    return r;
  }

  /// In place: this = this * [o].
  void multiply(Matrix4 o) => setFrom(this * o);

  /// A new matrix: this * [o] (same as the `*` operator).
  Matrix4 multiplied(Matrix4 o) => this * o;

  double determinant() {
    final m = storage;
    final a00 = m[0], a01 = m[1], a02 = m[2], a03 = m[3];
    final a10 = m[4], a11 = m[5], a12 = m[6], a13 = m[7];
    final a20 = m[8], a21 = m[9], a22 = m[10], a23 = m[11];
    final a30 = m[12], a31 = m[13], a32 = m[14], a33 = m[15];
    final b00 = a00 * a11 - a01 * a10, b01 = a00 * a12 - a02 * a10, b02 = a00 * a13 - a03 * a10;
    final b03 = a01 * a12 - a02 * a11, b04 = a01 * a13 - a03 * a11, b05 = a02 * a13 - a03 * a12;
    final b06 = a20 * a31 - a21 * a30, b07 = a20 * a32 - a22 * a30, b08 = a20 * a33 - a23 * a30;
    final b09 = a21 * a32 - a22 * a31, b10 = a21 * a33 - a23 * a31, b11 = a22 * a33 - a23 * a32;
    return b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
  }

  /// In place. Returns the determinant (0 means it cannot be inverted: the matrix is then left as it was).
  double invert() {
    final m = storage;
    final a00 = m[0], a01 = m[1], a02 = m[2], a03 = m[3];
    final a10 = m[4], a11 = m[5], a12 = m[6], a13 = m[7];
    final a20 = m[8], a21 = m[9], a22 = m[10], a23 = m[11];
    final a30 = m[12], a31 = m[13], a32 = m[14], a33 = m[15];
    final b00 = a00 * a11 - a01 * a10, b01 = a00 * a12 - a02 * a10, b02 = a00 * a13 - a03 * a10;
    final b03 = a01 * a12 - a02 * a11, b04 = a01 * a13 - a03 * a11, b05 = a02 * a13 - a03 * a12;
    final b06 = a20 * a31 - a21 * a30, b07 = a20 * a32 - a22 * a30, b08 = a20 * a33 - a23 * a30;
    final b09 = a21 * a32 - a22 * a31, b10 = a21 * a33 - a23 * a31, b11 = a22 * a33 - a23 * a32;
    final det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
    if (det == 0.0) return 0.0;
    final id = 1.0 / det;
    m[0] = (a11 * b11 - a12 * b10 + a13 * b09) * id;
    m[1] = (a02 * b10 - a01 * b11 - a03 * b09) * id;
    m[2] = (a31 * b05 - a32 * b04 + a33 * b03) * id;
    m[3] = (a22 * b04 - a21 * b05 - a23 * b03) * id;
    m[4] = (a12 * b08 - a10 * b11 - a13 * b07) * id;
    m[5] = (a00 * b11 - a02 * b08 + a03 * b07) * id;
    m[6] = (a32 * b02 - a30 * b05 - a33 * b01) * id;
    m[7] = (a20 * b05 - a22 * b02 + a23 * b01) * id;
    m[8] = (a10 * b10 - a11 * b08 + a13 * b06) * id;
    m[9] = (a01 * b08 - a00 * b10 - a03 * b06) * id;
    m[10] = (a30 * b04 - a31 * b02 + a33 * b00) * id;
    m[11] = (a21 * b02 - a20 * b04 - a23 * b00) * id;
    m[12] = (a11 * b07 - a10 * b09 - a12 * b06) * id;
    m[13] = (a00 * b09 - a01 * b07 + a02 * b06) * id;
    m[14] = (a31 * b01 - a30 * b03 - a32 * b00) * id;
    m[15] = (a20 * b03 - a21 * b01 + a22 * b00) * id;
    return det;
  }

  void transpose() {
    final m = storage;
    void swap(int a, int b) {
      final t = m[a];
      m[a] = m[b];
      m[b] = t;
    }

    swap(1, 4);
    swap(2, 8);
    swap(3, 12);
    swap(6, 9);
    swap(7, 13);
    swap(11, 14);
  }

  /// In place: this = this * translation(x, y, z).
  void translate(double x, [double y = 0.0, double z = 0.0]) {
    final m = storage;
    m[12] += m[0] * x + m[4] * y + m[8] * z;
    m[13] += m[1] * x + m[5] * y + m[9] * z;
    m[14] += m[2] * x + m[6] * y + m[10] * z;
    m[15] += m[3] * x + m[7] * y + m[11] * z;
  }

  /// In place: this = this * scale(x, y, z). With only [x] it scales all three the same.
  void scale(double x, [double? y, double? z]) {
    final sy = y ?? x, sz = z ?? x;
    final m = storage;
    for (var i = 0; i < 4; i++) {
      m[i] *= x;
      m[4 + i] *= sy;
      m[8 + i] *= sz;
    }
  }

  /// In place: [v] as a point (w = 1) is changed by this matrix, no perspective divide. Returns [v].
  Vector3 transform3(Vector3 v) => v..setFrom(transformed3(v));

  /// A new point: this * (v, 1), no perspective divide.
  Vector3 transformed3(Vector3 v, [Vector3? out]) {
    final m = storage;
    final x = m[0] * v.x + m[4] * v.y + m[8] * v.z + m[12];
    final y = m[1] * v.x + m[5] * v.y + m[9] * v.z + m[13];
    final z = m[2] * v.x + m[6] * v.y + m[10] * v.z + m[14];
    return (out ?? Vector3.zero())..setValues(x, y, z);
  }

  /// In place: [v] as a direction (w = 0): only rotation and scale act. Returns [v].
  Vector3 rotate3(Vector3 v) {
    final m = storage;
    final x = m[0] * v.x + m[4] * v.y + m[8] * v.z;
    final y = m[1] * v.x + m[5] * v.y + m[9] * v.z;
    final z = m[2] * v.x + m[6] * v.y + m[10] * v.z;
    return v..setValues(x, y, z);
  }

  /// In place: this * v for a 4 part vector. Returns [v].
  Vector4 transform(Vector4 v) {
    final m = storage;
    final x = m[0] * v.x + m[4] * v.y + m[8] * v.z + m[12] * v.w;
    final y = m[1] * v.x + m[5] * v.y + m[9] * v.z + m[13] * v.w;
    final z = m[2] * v.x + m[6] * v.y + m[10] * v.z + m[14] * v.w;
    final w = m[3] * v.x + m[7] * v.y + m[11] * v.z + m[15] * v.w;
    return v..setValues(x, y, z, w);
  }

  @override
  String toString() => 'Matrix4($storage)';
}

/// Fills [out] with a perspective projection (OpenGL style: depth -1 at near, +1 at far).
void setPerspectiveMatrix(Matrix4 out, double fovYRadians, double aspect, double near, double far) {
  final h = math.tan(fovYRadians * 0.5);
  final w = h * aspect;
  final nf = near - far;
  out.setZero();
  out.storage[0] = 1.0 / w;
  out.storage[5] = 1.0 / h;
  out.storage[10] = (far + near) / nf;
  out.storage[11] = -1.0;
  out.storage[14] = (2.0 * near * far) / nf;
}

/// Fills [out] with an orthographic projection (depth -1 at near, +1 at far).
void setOrthographicMatrix(Matrix4 out, double left, double right, double bottom, double top, double near, double far) {
  final rl = right - left, tb = top - bottom, fn = far - near;
  out.setZero();
  out.storage[0] = 2.0 / rl;
  out.storage[5] = 2.0 / tb;
  out.storage[10] = -2.0 / fn;
  out.storage[12] = -(right + left) / rl;
  out.storage[13] = -(top + bottom) / tb;
  out.storage[14] = -(far + near) / fn;
  out.storage[15] = 1.0;
}

// ======================================================================
// Aabb3, Ray, Frustum
// ======================================================================

/// A box that stays parallel to the axes, from [min] to [max].
class Aabb3 {
  Aabb3() : min = Vector3.zero(), max = Vector3.zero();
  Aabb3.minMax(Vector3 a, Vector3 b) : min = a.clone(), max = b.clone();
  Aabb3.copy(Aabb3 o) : min = o.min.clone(), max = o.max.clone();

  final Vector3 min, max;

  Vector3 get center => (min + max) * 0.5;
  Vector3 get halfExtents => (max - min) * 0.5;

  /// In place: the box around this box after it is moved by [m]. Returns this.
  Aabb3 transform(Matrix4 m) {
    final c = center, h = halfExtents;
    final e = m.storage;
    final nc = m.transformed3(c);
    final hx = e[0].abs() * h.x + e[4].abs() * h.y + e[8].abs() * h.z;
    final hy = e[1].abs() * h.x + e[5].abs() * h.y + e[9].abs() * h.z;
    final hz = e[2].abs() * h.x + e[6].abs() * h.y + e[10].abs() * h.z;
    min.setValues(nc.x - hx, nc.y - hy, nc.z - hz);
    max.setValues(nc.x + hx, nc.y + hy, nc.z + hz);
    return this;
  }

  bool intersectsWith(Aabb3 o) =>
      min.x <= o.max.x && max.x >= o.min.x && min.y <= o.max.y && max.y >= o.min.y && min.z <= o.max.z && max.z >= o.min.z;

  bool containsVector3(Vector3 p) =>
      p.x >= min.x && p.x <= max.x && p.y >= min.y && p.y <= max.y && p.z >= min.z && p.z <= max.z;

  /// In place: grows to include [p].
  void hullPoint(Vector3 p) {
    min.setValues(math.min(min.x, p.x), math.min(min.y, p.y), math.min(min.z, p.z));
    max.setValues(math.max(max.x, p.x), math.max(max.y, p.y), math.max(max.z, p.z));
  }
}

/// A half line: `origin + direction * t`, t >= 0.
class Ray {
  Ray.originDirection(Vector3 o, Vector3 d)
      : origin = o.clone(),
        direction = d.clone();

  final Vector3 origin, direction;

  Vector3 at(double t) => origin + direction * t;
}

/// The six planes of a camera view. Made from a view-projection matrix.
class Frustum {
  /// Planes as (a, b, c, d) with the normal (a, b, c) pointing into the view: left, right, bottom, top, near, far.
  Frustum.matrix(Matrix4 vp) : _planes = List.generate(6, (_) => Vector4.zero()) {
    final r0 = vp.getRow(0), r1 = vp.getRow(1), r2 = vp.getRow(2), r3 = vp.getRow(3);
    _planes[0] = r3 + r0;
    _planes[1] = r3 - r0;
    _planes[2] = r3 + r1;
    _planes[3] = r3 - r1;
    _planes[4] = r3 + r2;
    _planes[5] = r3 - r2;
    for (final p in _planes) {
      final l = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z);
      if (l > 0) p.scale(1.0 / l);
    }
  }

  final List<Vector4> _planes;

  /// False only when the box is certainly outside. (A box near a corner may still say true.)
  bool intersectsWithAabb3(Aabb3 b) {
    for (final p in _planes) {
      final px = p.x >= 0 ? b.max.x : b.min.x;
      final py = p.y >= 0 ? b.max.y : b.min.y;
      final pz = p.z >= 0 ? b.max.z : b.min.z;
      if (p.x * px + p.y * py + p.z * pz + p.w < 0) return false;
    }
    return true;
  }

  bool containsPoint(Vector3 q) {
    for (final p in _planes) {
      if (p.x * q.x + p.y * q.y + p.z * q.z + p.w < 0) return false;
    }
    return true;
  }
}
