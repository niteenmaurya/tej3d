enum BtStatus { success, failure, running }

/// Shared memory of one AI agent.
class Blackboard {
  final Map<String, Object?> _d = {};

  void set(String key, Object? value) => _d[key] = value;

  T? get<T>(String key) {
    final v = _d[key];
    return v is T ? v : null;
  }

  bool has(String key) => _d.containsKey(key);
}

abstract class BtNode {
  BtStatus tick(Blackboard bb, double dt);

  /// Forget progress (when a parent aborts this node).
  void reset() {}
}

/// Runs a function. Return success, failure or running.
class BtAction extends BtNode {
  BtAction(this.fn);

  final BtStatus Function(Blackboard bb, double dt) fn;

  @override
  BtStatus tick(Blackboard bb, double dt) => fn(bb, dt);
}

/// Success if the test is true, failure if not.
class BtCondition extends BtNode {
  BtCondition(this.test);

  final bool Function(Blackboard bb) test;

  @override
  BtStatus tick(Blackboard bb, double dt) =>
      test(bb) ? BtStatus.success : BtStatus.failure;
}

/// Runs children in order. Fails at the first failure.
class BtSequence extends BtNode {
  BtSequence(this.children);

  final List<BtNode> children;
  int _i = 0;

  @override
  BtStatus tick(Blackboard bb, double dt) {
    while (_i < children.length) {
      final s = children[_i].tick(bb, dt);
      if (s == BtStatus.running) return s;
      if (s == BtStatus.failure) {
        _i = 0;
        return s;
      }
      _i++;
    }
    _i = 0;
    return BtStatus.success;
  }

  @override
  void reset() {
    _i = 0;
    for (final c in children) {
      c.reset();
    }
  }
}

/// Tries children in order. Succeeds at the first success.
class BtSelector extends BtNode {
  BtSelector(this.children);

  final List<BtNode> children;
  int _i = 0;

  @override
  BtStatus tick(Blackboard bb, double dt) {
    while (_i < children.length) {
      final s = children[_i].tick(bb, dt);
      if (s == BtStatus.running) return s;
      if (s == BtStatus.success) {
        _i = 0;
        return s;
      }
      _i++;
    }
    _i = 0;
    return BtStatus.failure;
  }

  @override
  void reset() {
    _i = 0;
    for (final c in children) {
      c.reset();
    }
  }
}

/// Success becomes failure and the other way round.
class BtInverter extends BtNode {
  BtInverter(this.child);

  final BtNode child;

  @override
  BtStatus tick(Blackboard bb, double dt) {
    final s = child.tick(bb, dt);
    if (s == BtStatus.success) return BtStatus.failure;
    if (s == BtStatus.failure) return BtStatus.success;
    return s;
  }

  @override
  void reset() => child.reset();
}

/// Runs the child [times] times (-1 forever).
class BtRepeat extends BtNode {
  BtRepeat(this.child, this.times);

  final BtNode child;
  final int times;
  int _n = 0;

  @override
  BtStatus tick(Blackboard bb, double dt) {
    final s = child.tick(bb, dt);
    if (s == BtStatus.running) return s;
    if (s == BtStatus.failure) {
      _n = 0;
      return s;
    }
    _n++;
    if (times >= 0 && _n >= times) {
      _n = 0;
      return BtStatus.success;
    }
    return BtStatus.running;
  }

  @override
  void reset() {
    _n = 0;
    child.reset();
  }
}

/// Running for [seconds], then success.
class BtWait extends BtNode {
  BtWait(this.seconds);

  final double seconds;
  double _t = 0.0;

  @override
  BtStatus tick(Blackboard bb, double dt) {
    _t += dt;
    if (_t >= seconds) {
      _t = 0.0;
      return BtStatus.success;
    }
    return BtStatus.running;
  }

  @override
  void reset() => _t = 0.0;
}
