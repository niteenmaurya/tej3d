import 'dart:math' as math;
import 'dart:typed_data';

import '../math/vec.dart';

/// Draws simple lines and shapes on top of the scene, for finding bugs: where
/// a ray goes, how big a trigger is, the path of an agent, the shapes of the
/// physics bodies. Every scene has one: `scene.debug`.
///
/// ```dart
/// scene.debug.line(a, b, color: DebugColors.red);
/// scene.debug.box(center, Vector3(1, 2, 1));
/// scene.debug.sphere(hit, 0.2, duration: 2);   // stays 2 seconds
/// ```
///
/// Shapes drawn without a [duration] last one frame: draw them again every
/// frame (from `update`). The native renderer draws them; the plain Dart
/// renderer ignores them.
class DebugDraw {
  /// Hides lines behind solid objects. Switch off to see through everything.
  bool depthTest = true;

  /// Turns all drawing off (calls still cost almost nothing).
  bool enabled = true;

  /// Most lines kept; more are dropped (a safety net against a loop drawing forever).
  int maxLines = 20000;

  final List<_Line> _lines = [];

  /// Number of lines that will be drawn.
  int get lineCount => _lines.length;

  void line(Vector3 a, Vector3 b, {Vector4? color, double duration = 0}) {
    if (!enabled || _lines.length >= maxLines) return;
    _lines.add(_Line(a.clone(), b.clone(), color ?? DebugColors.white, duration));
  }

  void ray(Vector3 origin, Vector3 direction, {double length = 10, Vector4? color, double duration = 0}) {
    final d = direction.length == 0 ? direction : direction.normalized();
    line(origin, origin + d * length, color: color ?? DebugColors.yellow, duration: duration);
  }

  /// A line with a small arrow head at [to].
  void arrow(Vector3 from, Vector3 to, {Vector4? color, double duration = 0, double headSize = 0.2}) {
    line(from, to, color: color, duration: duration);
    final d = to - from;
    final len = d.length;
    if (len < 1e-6) return;
    final dir = d / len;
    final ref = dir.y.abs() < 0.9 ? Vector3(0, 1, 0) : Vector3(1, 0, 0);
    final side = dir.cross(ref).normalized() * (headSize * 0.5);
    final up = dir.cross(side).normalized() * (headSize * 0.5);
    final base = to - dir * headSize;
    for (final o in [side, -side, up, -up]) {
      line(to, base + o, color: color, duration: duration);
    }
  }

  /// A box with [halfExtents] around [center], turned by [rotation].
  void box(Vector3 center, Vector3 halfExtents, {Quaternion? rotation, Vector4? color, double duration = 0}) {
    final r = rotation ?? Quaternion.identity();
    final m = r.asRotationMatrix();
    Vector3 corner(int i) {
      final p = Vector3((i & 1) == 0 ? -halfExtents.x : halfExtents.x, (i & 2) == 0 ? -halfExtents.y : halfExtents.y,
          (i & 4) == 0 ? -halfExtents.z : halfExtents.z);
      return center + m.transformed(p);
    }

    const edges = [
      [0, 1], [2, 3], [4, 5], [6, 7], // along x
      [0, 2], [1, 3], [4, 6], [5, 7], // along y
      [0, 4], [1, 5], [2, 6], [3, 7], // along z
    ];
    for (final e in edges) {
      line(corner(e[0]), corner(e[1]), color: color, duration: duration);
    }
  }

  /// Box from the lowest and highest corner.
  void aabb(Vector3 min, Vector3 max, {Vector4? color, double duration = 0}) =>
      box((min + max) * 0.5, (max - min) * 0.5, color: color, duration: duration);

  /// A circle in the plane with the given [normal].
  void circle(Vector3 center, double radius, {Vector3? normal, Vector4? color, double duration = 0, int segments = 24}) {
    final n = (normal ?? Vector3(0, 1, 0)).normalized();
    final ref = n.y.abs() < 0.9 ? Vector3(0, 1, 0) : Vector3(1, 0, 0);
    final u = n.cross(ref).normalized();
    final v = n.cross(u);
    Vector3? prev;
    for (var i = 0; i <= segments; i++) {
      final a = i * 2 * math.pi / segments;
      final p = center + (u * math.cos(a) + v * math.sin(a)) * radius;
      if (prev != null) line(prev, p, color: color, duration: duration);
      prev = p;
    }
  }

  /// A sphere drawn as three circles.
  void sphere(Vector3 center, double radius, {Vector4? color, double duration = 0, int segments = 24}) {
    circle(center, radius, normal: Vector3(1, 0, 0), color: color, duration: duration, segments: segments);
    circle(center, radius, normal: Vector3(0, 1, 0), color: color, duration: duration, segments: segments);
    circle(center, radius, normal: Vector3(0, 0, 1), color: color, duration: duration, segments: segments);
  }

  /// A capsule from [a] to [b] (centers of the two round ends).
  void capsule(Vector3 a, Vector3 b, double radius, {Vector4? color, double duration = 0}) {
    final axis = b - a;
    final len = axis.length;
    final dir = len < 1e-9 ? Vector3(0, 1, 0) : axis / len;
    final ref = dir.y.abs() < 0.9 ? Vector3(0, 1, 0) : Vector3(1, 0, 0);
    final u = dir.cross(ref).normalized() * radius;
    final v = dir.cross(u).normalized() * radius;
    circle(a, radius, normal: dir, color: color, duration: duration);
    circle(b, radius, normal: dir, color: color, duration: duration);
    for (final o in [u, -u, v, -v]) {
      line(a + o, b + o, color: color, duration: duration);
    }
    // round caps: two half circles per end
    void cap(Vector3 c, Vector3 side, double sign) {
      Vector3? prev;
      for (var i = 0; i <= 8; i++) {
        final t = i * math.pi / 8;
        final p = c + side * math.cos(t) + dir * (math.sin(t) * radius * sign);
        if (prev != null) line(prev, p, color: color, duration: duration);
        prev = p;
      }
    }

    cap(a, u, -1);
    cap(a, v, -1);
    cap(b, u, 1);
    cap(b, v, 1);
  }

  /// Three short lines for the axes of a transform: red x, green y, blue z.
  void axes(Matrix4 transform, {double size = 1, double duration = 0}) {
    final o = transform.getTranslation();
    final r = transform.getRotation();
    line(o, o + r.transformed(Vector3(size, 0, 0)), color: DebugColors.red, duration: duration);
    line(o, o + r.transformed(Vector3(0, size, 0)), color: DebugColors.green, duration: duration);
    line(o, o + r.transformed(Vector3(0, 0, size)), color: DebugColors.blue, duration: duration);
  }

  /// A line through all [points] (a path), optionally closed.
  void path(List<Vector3> points, {Vector4? color, double duration = 0, bool closed = false}) {
    for (var i = 0; i + 1 < points.length; i++) {
      line(points[i], points[i + 1], color: color, duration: duration);
    }
    if (closed && points.length > 2) line(points.last, points.first, color: color, duration: duration);
  }

  /// A flat grid on the XZ plane.
  void grid(Vector3 center, double size, int divisions, {Vector4? color, double duration = 0}) {
    final half = size / 2;
    final c = color ?? Vector4(0.5, 0.5, 0.5, 0.6);
    for (var i = 0; i <= divisions; i++) {
      final t = -half + size * i / divisions;
      line(center + Vector3(t, 0, -half), center + Vector3(t, 0, half), color: c, duration: duration);
      line(center + Vector3(-half, 0, t), center + Vector3(half, 0, t), color: c, duration: duration);
    }
  }

  /// A small cross at [p].
  void point(Vector3 p, {double size = 0.1, Vector4? color, double duration = 0}) {
    line(p - Vector3(size, 0, 0), p + Vector3(size, 0, 0), color: color, duration: duration);
    line(p - Vector3(0, size, 0), p + Vector3(0, size, 0), color: color, duration: duration);
    line(p - Vector3(0, 0, size), p + Vector3(0, 0, size), color: color, duration: duration);
  }

  /// Called by `Scene.update` at the start of every frame: lines from the last
  /// frame (no duration) are removed, the others get older and are removed when
  /// their time is over. Draw from `update` or `lateUpdate`; from a fixed
  /// step give a `duration` of at least one step.
  void beginFrame(double dt) {
    _lines.removeWhere((l) {
      if (l.duration <= 0) return true;
      l.duration -= dt;
      return l.duration <= 0;
    });
  }

  void clear() => _lines.clear();

  /// The lines for the native renderer: 10 numbers per line
  /// (ax ay az bx by bz r g b a).
  Float32List toFloats() {
    final out = Float32List(_lines.length * 10);
    var i = 0;
    for (final l in _lines) {
      out[i++] = l.a.x;
      out[i++] = l.a.y;
      out[i++] = l.a.z;
      out[i++] = l.b.x;
      out[i++] = l.b.y;
      out[i++] = l.b.z;
      out[i++] = l.color.x;
      out[i++] = l.color.y;
      out[i++] = l.color.z;
      out[i++] = l.color.w;
    }
    return out;
  }
}

class _Line {
  _Line(this.a, this.b, this.color, this.duration);
  final Vector3 a, b;
  final Vector4 color;
  double duration;
}

/// Some ready colors (red, green, blue, ...), all fully opaque.
class DebugColors {
  const DebugColors._();
  static final Vector4 white = Vector4(1, 1, 1, 1);
  static final Vector4 red = Vector4(1, 0.15, 0.15, 1);
  static final Vector4 green = Vector4(0.2, 1, 0.2, 1);
  static final Vector4 blue = Vector4(0.3, 0.45, 1, 1);
  static final Vector4 yellow = Vector4(1, 0.9, 0.2, 1);
  static final Vector4 cyan = Vector4(0.2, 0.95, 1, 1);
  static final Vector4 magenta = Vector4(1, 0.3, 1, 1);
  static final Vector4 orange = Vector4(1, 0.55, 0.1, 1);
}
