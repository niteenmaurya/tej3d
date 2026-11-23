import 'dart:math' as math;

import '../math/vec.dart';


/// Position, rotation and scale of an object, with a parent and children.
///
/// Axes (right-handed, like glTF and OpenGL): +X is right, +Y is up, and the
/// object looks along -Z ([forward]).
///
/// The vectors returned by [localPosition], [localRotation] and [localScale]
/// are the real stored values. If you change one in place, call [touch].
/// Setters copy the value and update everything for you.
class Transform {
  Transform({Vector3? position, Quaternion? rotation, Vector3? scale})
    : _position = position?.clone() ?? Vector3.zero(),
      _rotation = rotation?.clone() ?? Quaternion.identity(),
      _scale = scale?.clone() ?? Vector3(1.0, 1.0, 1.0);

  Vector3 _position;
  Quaternion _rotation;
  Vector3 _scale;

  Transform? _parent;
  final List<Transform> _children = [];

  Matrix4 _world = Matrix4.identity();
  bool _dirty = true;

  /// Who owns this transform (a `GameObject`). Set by the owner.
  Object? owner;

  Transform? get parent => _parent;

  List<Transform> get children => List.unmodifiable(_children);

  int get childCount => _children.length;

  /// Place among the brothers and sisters (0 = first). Setting it moves this transform in the parent's list.
  /// For a top level object use `GameObject.setSiblingIndex`.
  int get siblingIndex => _parent == null ? 0 : _parent!._children.indexOf(this);

  void setSiblingIndex(int index) {
    final p = _parent;
    if (p == null) return;
    p._children.remove(this);
    p._children.insert(index.clamp(0, p._children.length), this);
  }

  /// A child by index, without making a new list.
  Transform childAt(int index) => _children[index];

  Vector3 get localPosition => _position;
  set localPosition(Vector3 v) {
    _position.setFrom(v);
    touch();
  }

  Quaternion get localRotation => _rotation;
  set localRotation(Quaternion q) {
    _rotation.setFrom(q);
    touch();
  }

  Vector3 get localScale => _scale;
  set localScale(Vector3 v) {
    _scale.setFrom(v);
    touch();
  }

  /// Call after changing a local vector or quaternion in place.
  void touch() {
    if (_dirty && _children.isEmpty) return;
    _dirty = true;
    for (final c in _children) {
      c._invalidateWorld();
    }
  }

  void _invalidateWorld() {
    _dirty = true;
    for (final c in _children) {
      c._invalidateWorld();
    }
  }

  /// Local to world matrix. Cached until something changes.
  Matrix4 get worldMatrix {
    if (_dirty) {
      final local = Matrix4.identity()
        ..setFromTranslationRotationScale(_position, _rotation, _scale);
      final p = _parent;
      _world = p == null ? local : p.worldMatrix * local;
      _dirty = false;
    }
    return _world;
  }

  Vector3 get worldPosition => worldMatrix.getTranslation();

  Quaternion get worldRotation {
    final p = _parent;
    return p == null ? _rotation.clone() : (p.worldRotation * _rotation).normalized();
  }

  Vector3 get forward => worldRotation.rotateVector(Vector3(0.0, 0.0, -1.0));
  Vector3 get right => worldRotation.rotateVector(Vector3(1.0, 0.0, 0.0));
  Vector3 get up => worldRotation.rotateVector(Vector3(0.0, 1.0, 0.0));

  set worldPosition(Vector3 p) {
    final par = _parent;
    if (par == null) {
      localPosition = p;
    } else {
      final inv = Matrix4.copy(par.worldMatrix);
      if (inv.invert() == 0.0) return;
      localPosition = inv.transformed3(p);
    }
  }

  set worldRotation(Quaternion q) {
    final par = _parent;
    localRotation = par == null
        ? q.normalized()
        : (par.worldRotation.inverted() * q).normalized();
  }

  /// Turns so that [forward] points at [target] (a world position).
  void lookAt(Vector3 target, [Vector3? up]) {
    final f = target - worldPosition;
    if (f.length2 < 1e-12) return;
    f.normalize();
    var upv = up ?? Vector3(0.0, 1.0, 0.0);
    var r = f.cross(upv);
    if (r.length2 < 1e-10) {
      upv = f.z.abs() > 0.9 ? Vector3(1.0, 0.0, 0.0) : Vector3(0.0, 0.0, 1.0);
      r = f.cross(upv);
    }
    r.normalize();
    final u = r.cross(f);
    worldRotation = Quaternion.fromRotation(
      Matrix3.columns(r, u, f.scaled(-1.0)),
    );
  }

  /// Rotation from angles in degrees. Applied in the order Y, X, Z.
  static Quaternion eulerDegrees(double x, double y, double z) {
    const d = math.pi / 180.0;
    final qy = Quaternion.axisAngle(Vector3(0.0, 1.0, 0.0), y * d);
    final qx = Quaternion.axisAngle(Vector3(1.0, 0.0, 0.0), x * d);
    final qz = Quaternion.axisAngle(Vector3(0.0, 0.0, 1.0), z * d);
    return qy * qx * qz;
  }

  void setEulerDegrees(double x, double y, double z) {
    localRotation = eulerDegrees(x, y, z);
  }

  /// Sets position, rotation and scale (local) from a matrix.
  void setFromMatrix(Matrix4 m) {
    final t = Vector3.zero();
    final r = Quaternion.identity();
    final sc = Vector3(1.0, 1.0, 1.0);
    m.decompose(t, r, sc);
    _position.setFrom(t);
    _rotation.setFrom(r);
    _scale.setFrom(sc);
    touch();
  }

  /// Changes the parent. With [keepWorld] the object stays where it is in
  /// the world (position and rotation; scale is not kept).
  void setParent(Transform? newParent, {bool keepWorld = false}) {
    if (identical(newParent, _parent)) return;
    for (Transform? t = newParent; t != null; t = t._parent) {
      if (identical(t, this)) {
        throw ArgumentError('An object cannot be its own parent.');
      }
    }
    final wp = keepWorld ? worldPosition : null;
    final wr = keepWorld ? worldRotation : null;
    _parent?._children.remove(this);
    _parent = newParent;
    newParent?._children.add(this);
    _invalidateWorld();
    if (wp != null && wr != null) {
      worldPosition = wp;
      worldRotation = wr;
    }
  }
}
