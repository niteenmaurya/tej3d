import '../math/vec.dart';

import '../anim/tween.dart';
import '../math/mathf.dart';

/// Where a camera is and what it looks at. Pure data.
class CameraState {
  CameraState(this.position, this.target, {this.fovDegrees = 60.0});

  Vector3 position;
  Vector3 target;
  double fovDegrees;

  CameraState clone() =>
      CameraState(position.clone(), target.clone(), fovDegrees: fovDegrees);

  static CameraState blend(CameraState a, CameraState b, double t) =>
      CameraState(
        Mathf.lerpV(a.position, b.position, t),
        Mathf.lerpV(a.target, b.target, t),
        fovDegrees: Mathf.lerp(a.fovDegrees, b.fovDegrees, t),
      );
}

/// One camera "shot", like a Cinemachine virtual camera. It makes its state
/// by calling [source] every frame.
class VirtualCamera {
  VirtualCamera(
    this.name,
    this.source, {
    this.priority = 0,
    this.blendIn = 0.6,
    this.enabled = true,
  });

  final String name;
  final CameraState Function() source;

  /// The enabled camera with the highest priority is live.
  int priority;

  /// Seconds to blend from the old camera to this one.
  double blendIn;
  bool enabled;
}

/// Picks the live virtual camera and blends when it changes.
class CameraBrain {
  final List<VirtualCamera> cameras = [];

  EaseFn blendEase = Easing.sineInOut;

  VirtualCamera? _live;
  CameraState? _from;
  double _t = 1.0;
  double _dur = 0.0;
  CameraState? _out;

  VirtualCamera? get live => _live;

  /// The state to give to the real camera.
  CameraState? get output => _out;

  CameraState? update(double dt) {
    VirtualCamera? best;
    for (final c in cameras) {
      if (!c.enabled) continue;
      if (best == null || c.priority > best.priority) best = c;
    }
    if (best == null) return _out;
    if (!identical(best, _live)) {
      _from = _out?.clone();
      _live = best;
      _t = 0.0;
      _dur = _from == null ? 0.0 : best.blendIn;
    }
    final target = best.source();
    final from = _from;
    if (from == null || _dur <= 0.0 || _t >= 1.0) {
      _out = target;
      _t = 1.0;
    } else {
      _t = Mathf.clamp01(_t + dt / _dur);
      _out = CameraState.blend(from, target, blendEase(_t));
    }
    return _out;
  }
}

/// Trauma based camera shake. Call [addTrauma] on a hit (0..1), read
/// [update] each frame and add the offset to the camera position.
class CameraShake {
  CameraShake({
    this.maxOffset = 0.35,
    this.decay = 1.2,
    this.frequency = 18.0,
    int seed = 1,
  }) : _noise = PerlinNoise(seed);

  final double maxOffset;

  /// Trauma lost per second.
  final double decay;
  final double frequency;
  final PerlinNoise _noise;

  double _trauma = 0.0;
  double _time = 0.0;

  double get trauma => _trauma;

  void addTrauma(double amount) => _trauma = Mathf.clamp01(_trauma + amount);

  Vector3 update(double dt) {
    _trauma = (_trauma - decay * dt).clamp(0.0, 1.0).toDouble();
    _time += dt * frequency;
    final k = _trauma * _trauma * maxOffset;
    return Vector3(
      _noise.noise2(_time, 0.0) * k,
      _noise.noise2(_time, 10.0) * k,
      _noise.noise2(_time, 20.0) * k,
    );
  }
}
