/// Runs game logic in equal time steps, like Unity `FixedUpdate`.
///
/// Note: in this engine physics is stepped by `scene.update(dt)`. Use this
/// for gameplay logic that must be the same on every device (AI, timers,
/// replays), not to step physics a second time.
class FixedStepper {
  FixedStepper({this.step = 1.0 / 60.0, this.maxSteps = 5});

  /// Length of one step in seconds.
  final double step;

  /// Most steps in one frame. Extra time is dropped, so a slow frame cannot
  /// make the next frame even slower.
  final int maxSteps;

  double _acc = 0.0;

  /// How far we are between two steps, 0 to 1. Use it to smooth drawing.
  double get alpha => step <= 0.0 ? 0.0 : _acc / step;

  /// Adds [dt] and calls [fixedUpdate] for each full step. Returns the count.
  int advance(double dt, void Function(double step) fixedUpdate) {
    if (step <= 0.0 || dt <= 0.0 || !dt.isFinite) return 0;
    _acc += dt;
    var n = 0;
    while (_acc >= step && n < maxSteps) {
      fixedUpdate(step);
      _acc -= step;
      n++;
    }
    if (_acc >= step) _acc = _acc % step;
    return n;
  }

  void reset() => _acc = 0.0;
}
