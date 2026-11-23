/// Skybox and ReflectionProbe environment data for physically plausible scenes.
library;

import '../math/vec.dart';
import 'game_object.dart';

/// Procedural gradient or 6-face cubemap skybox configuration.
class Skybox {
  Skybox.procedural({
    Vector3? zenithColor,
    Vector3? horizonColor,
    Vector3? groundColor,
    this.sunSize = 0.04,
    this.exposure = 1.0,
  })  : zenithColor = zenithColor?.clone() ?? Vector3(0.15, 0.35, 0.75),
        horizonColor = horizonColor?.clone() ?? Vector3(0.65, 0.78, 0.92),
        groundColor = groundColor?.clone() ?? Vector3(0.25, 0.22, 0.2),
        cubemapFaces = null;

  Skybox.cubemap(Map<String, String> faces, {this.exposure = 1.0})
      : cubemapFaces = Map.unmodifiable(faces),
        zenithColor = Vector3.all(1),
        horizonColor = Vector3.all(1),
        groundColor = Vector3.all(0.2),
        sunSize = 0.0;

  final Vector3 zenithColor;
  final Vector3 horizonColor;
  final Vector3 groundColor;
  final double sunSize;
  double exposure;

  /// Optional 6-face asset paths (`+x`, `-x`, `+y`, `-y`, `+z`, `-z`).
  final Map<String, String>? cubemapFaces;

  bool get isCubemap => cubemapFaces != null;

  /// Samples the procedural sky color along unit [direction].
  Vector3 sampleDirection(Vector3 direction) {
    final d = direction.normalized();
    if (d.y >= 0) {
      final t = d.y.clamp(0.0, 1.0).toDouble();
      return (horizonColor * (1.0 - t) + zenithColor * t) * exposure;
    } else {
      final t = (-d.y).clamp(0.0, 1.0).toDouble();
      return (horizonColor * (1.0 - t) + groundColor * t) * exposure;
    }
  }
}

/// Box-bounded reflection probe component for environment lighting / reflections.
class ReflectionProbe extends Component {
  ReflectionProbe({
    Vector3? boxHalfExtents,
    this.resolution = 256,
    this.intensity = 1.0,
    this.priority = 0,
    this.realtime = false,
  }) : boxHalfExtents = boxHalfExtents?.clone() ?? Vector3.all(10.0);

  Vector3 boxHalfExtents;
  int resolution;
  double intensity;
  int priority;
  bool realtime;

  bool containsPoint(Vector3 worldPoint) {
    final rel = worldPoint - transform.worldPosition;
    return rel.x.abs() <= boxHalfExtents.x &&
        rel.y.abs() <= boxHalfExtents.y &&
        rel.z.abs() <= boxHalfExtents.z;
  }

  /// Selects the highest-priority [ReflectionProbe] covering [point] in [scene].
  static ReflectionProbe? findBest(Scene scene, Vector3 point) {
    ReflectionProbe? best;
    scene.forEachActive((go) {
      final p = go.getComponent<ReflectionProbe>();
      if (p != null && p.enabled && p.containsPoint(point)) {
        if (best == null || p.priority > best!.priority) best = p;
      }
    });
    return best;
  }
}
