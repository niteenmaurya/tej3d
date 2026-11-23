/// A countdown timer driven by the game loop. Call [update] every frame.
class GameTimer {
  GameTimer(this.duration, {this.repeat = false, this.onTick});

  /// Length in seconds.
  final double duration;

  /// If true the timer restarts after it fires and keeps the extra time.
  final bool repeat;

  /// Called each time the timer completes.
  final void Function()? onTick;

  double _elapsed = 0.0;
  bool _running = false;
  bool _done = false;

  bool get isRunning => _running;
  bool get isDone => _done;
  double get elapsed => _elapsed;

  /// 0 to 1.
  double get progress => duration <= 0 ? 1.0 : (_elapsed / duration).clamp(0.0, 1.0);

  void start() {
    _elapsed = 0.0;
    _running = true;
    _done = false;
  }

  void stop() => _running = false;

  void update(double dt) {
    if (!_running || dt <= 0.0 || !dt.isFinite) return;
    _elapsed += dt;
    while (_running && _elapsed >= duration) {
      if (repeat && duration > 0) {
        _elapsed -= duration;
        onTick?.call();
      } else {
        _elapsed = duration;
        _running = false;
        _done = true;
        onTick?.call();
        return;
      }
    }
  }
}
