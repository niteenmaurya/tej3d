/// Something a coroutine waits for. Make a new one each time you yield
/// (it keeps its own count), like `new WaitForSeconds(1)` in Unity.
abstract class Wait {
  const Wait();

  factory Wait.seconds(double seconds) = WaitForSeconds;
  factory Wait.frames(int frames) = WaitFrames;
  factory Wait.until(bool Function() condition) = WaitUntil;
  factory Wait.whileTrue(bool Function() condition) = WaitWhile;
  factory Wait.coroutine(Coroutine other) = WaitForCoroutine;

  /// Called every frame while waiting. Return true when the wait is over.
  bool tick(double dt);
}

class WaitForSeconds extends Wait {
  WaitForSeconds(this.seconds) : _left = seconds;

  final double seconds;
  double _left;

  @override
  bool tick(double dt) {
    _left -= dt;
    return _left <= 0.0;
  }
}

class WaitFrames extends Wait {
  WaitFrames(this.frames) : _left = frames;

  final int frames;
  int _left;

  @override
  bool tick(double dt) {
    _left -= 1;
    return _left <= 0;
  }
}

class WaitUntil extends Wait {
  WaitUntil(this.condition);

  final bool Function() condition;

  @override
  bool tick(double dt) => condition();
}

class WaitWhile extends Wait {
  WaitWhile(this.condition);

  final bool Function() condition;

  @override
  bool tick(double dt) => !condition();
}

class WaitForCoroutine extends Wait {
  WaitForCoroutine(this.other);

  final Coroutine other;

  @override
  bool tick(double dt) => other.isDone;
}

/// A running coroutine. Get it from [CoroutineRunner.start].
class Coroutine {
  Coroutine._(this._it);

  final Iterator<Wait?> _it;
  Wait? _wait;
  bool _done = false;

  bool get isDone => _done;

  void stop() => _done = true;

  void _advance() {
    if (!_it.moveNext()) {
      _done = true;
      return;
    }
    _wait = _it.current;
  }

  void _update(double dt) {
    if (_done) return;
    final w = _wait;
    if (w != null && !w.tick(dt)) return;
    _wait = null;
    _advance();
  }
}

/// Runs coroutines written as `sync*` functions. Needs `update(dt)` every
/// frame (`Tej3DGame` does it for you, and it stops while paused).
///
/// ```dart
/// Iterable<Wait?> countdown() sync* {
///   for (var i = 3; i > 0; i--) {
///     print(i);
///     yield Wait.seconds(1);
///   }
///   print('Go!');
/// }
/// game.coroutines.start(countdown);
/// ```
/// `yield null` waits one frame.
class CoroutineRunner {
  final List<Coroutine> _active = [];

  int get count => _active.length;

  /// Starts the coroutine and runs it up to its first `yield` at once.
  Coroutine start(Iterable<Wait?> Function() body) {
    final c = Coroutine._(body().iterator);
    c._advance();
    if (!c._done) _active.add(c);
    return c;
  }

  void stop(Coroutine c) => c.stop();

  void stopAll() {
    for (final c in _active) {
      c.stop();
    }
    _active.clear();
  }

  void update(double dt) {
    for (final c in List<Coroutine>.of(_active)) {
      c._update(dt);
    }
    _active.removeWhere((c) => c._done);
  }
}
