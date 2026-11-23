import '../math/vec.dart';

import '../core/layers.dart';
import '../editor/inspector.dart';
import 'game_object.dart';
import 'post_effects.dart';

/// A camera on an object. It looks along the object's forward (-Z).
class Camera extends Component implements Inspectable {
  Camera({
    this.fovYDegrees = 60.0,
    this.near = 0.1,
    this.far = 500.0,
    this.orthographic = false,
    this.orthoSize = 5.0,
    this.cullingMask = LayerMask.everything,
    this.post,
  });

  /// Vertical field of view in degrees (perspective).
  double fovYDegrees;
  double near;
  double far;

  /// If true, no perspective. [orthoSize] is half the visible height.
  bool orthographic;
  double orthoSize;

  /// Only objects on these layers are drawn.
  LayerMask cullingMask;

  /// Picture effects (bloom, vignette, tonemap...). Null: none.
  PostEffects? post;

  /// World to camera matrix (rigid transform, immune to non-unit camera scale).
  Matrix4 get viewMatrix {
    final rotInv = transform.worldRotation.normalized().conjugated();
    final r = rotInv.asRotationMatrix().storage;
    final p = transform.worldPosition;
    final tx = -(r[0] * p.x + r[3] * p.y + r[6] * p.z);
    final ty = -(r[1] * p.x + r[4] * p.y + r[7] * p.z);
    final tz = -(r[2] * p.x + r[5] * p.y + r[8] * p.z);
    final m = Matrix4.identity();
    final s = m.storage;
    s[0] = r[0];
    s[1] = r[1];
    s[2] = r[2];
    s[3] = 0.0;
    s[4] = r[3];
    s[5] = r[4];
    s[6] = r[5];
    s[7] = 0.0;
    s[8] = r[6];
    s[9] = r[7];
    s[10] = r[8];
    s[11] = 0.0;
    s[12] = tx;
    s[13] = ty;
    s[14] = tz;
    s[15] = 1.0;
    return m;
  }

  Matrix4 projectionMatrix(double aspect) {
    final m = Matrix4.zero();
    if (orthographic) {
      final h = orthoSize;
      final w = orthoSize * aspect;
      setOrthographicMatrix(m, -w, w, -h, h, near, far);
    } else {
      setPerspectiveMatrix(m, fovYDegrees * degrees2Radians, aspect, near, far);
    }
    return m;
  }

  Matrix4 viewProjection(double aspect) => projectionMatrix(aspect) * viewMatrix;

  /// Screen pixel of a world point, or null if it is behind the camera.
  /// z of the result is depth (-1 near, 1 far).
  Vector3? worldToScreen(Vector3 world, double width, double height) {
    if (width <= 0.0 || height <= 0.0) return null;
    final vp = viewProjection(width / height);
    final c = vp.transform(Vector4(world.x, world.y, world.z, 1.0));
    if (c.w <= 1e-9 || c.w.abs() < 1e-9) return null;
    final x = c.x / c.w;
    final y = c.y / c.w;
    return Vector3(
      (x * 0.5 + 0.5) * width,
      (1.0 - (y * 0.5 + 0.5)) * height,
      c.z / c.w,
    );
  }

  /// A ray from the camera through a screen pixel, for mouse and touch
  /// picking. Direction has length 1.
  Ray screenRay(double px, double py, double width, double height) {
    if (width <= 0.0 || height <= 0.0) {
      return Ray.originDirection(transform.worldPosition, transform.forward);
    }
    final inv = Matrix4.copy(viewProjection(width / height));
    if (inv.invert() == 0.0) {
      return Ray.originDirection(transform.worldPosition, transform.forward);
    }
    final nx = px / width * 2.0 - 1.0;
    final ny = 1.0 - py / height * 2.0;
    final a = inv.transform(Vector4(nx, ny, -1.0, 1.0));
    final b = inv.transform(Vector4(nx, ny, 1.0, 1.0));
    if (a.w.abs() < 1e-9 || b.w.abs() < 1e-9) {
      return Ray.originDirection(transform.worldPosition, transform.forward);
    }
    final p0 = Vector3(a.x / a.w, a.y / a.w, a.z / a.w);
    final p1 = Vector3(b.x / b.w, b.y / b.w, b.z / b.w);
    return Ray.originDirection(p0, (p1 - p0).normalized());
  }

  /// Puts the camera at [position] looking at [target].
  void lookFrom(Vector3 position, Vector3 target) {
    transform.worldPosition = position;
    transform.lookAt(target);
  }

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.float('fovYDegrees', () => fovYDegrees, (v) => fovYDegrees = v, min: 1, max: 179),
        InspectorField.float('near', () => near, (v) => near = v, min: 0.001),
        InspectorField.float('far', () => far, (v) => far = v, min: 0.01),
        InspectorField.boolean('orthographic', () => orthographic, (v) => orthographic = v),
        InspectorField.float('orthoSize', () => orthoSize, (v) => orthoSize = v, min: 0.01),
      ];
}
