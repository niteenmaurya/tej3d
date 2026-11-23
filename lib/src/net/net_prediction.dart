/// Production multiplayer networking helpers: client-side prediction with
/// server reconciliation, lag compensation (hitbox history rewind), and
/// key-value delta compression for bandwidth savings.
library;

import '../math/vec.dart';

/// One timestamped player input sent from client to server.
class InputCommand {
  const InputCommand({
    required this.sequence,
    required this.dt,
    required this.moveDir,
  });

  final int sequence;
  final double dt;
  final Vector3 moveDir;
}

/// Client-side predictor that applies inputs immediately and reconciles
/// cleanly when an authoritative server state arrives for an older sequence.
class PredictedMover {
  PredictedMover({Vector3? startPosition, this.speed = 6.0})
      : position = startPosition?.clone() ?? Vector3.zero();

  Vector3 position;
  double speed;
  final List<InputCommand> _pending = [];
  int _nextSeq = 1;

  int get pendingCount => _pending.length;

  /// Applies a local input immediately and buffers it for reconciliation.
  InputCommand applyLocalInput(Vector3 moveDir, double dt) {
    final cmd = InputCommand(sequence: _nextSeq++, dt: dt, moveDir: moveDir.clone());
    _pending.add(cmd);
    _integrate(cmd);
    return cmd;
  }

  /// Accepts an authoritative server position for [lastProcessedSequence] and
  /// replays any unacknowledged local inputs on top of it.
  void reconcile(Vector3 serverPosition, int lastProcessedSequence) {
    position = serverPosition.clone();
    _pending.removeWhere((c) => c.sequence <= lastProcessedSequence);
    for (final cmd in _pending) {
      _integrate(cmd);
    }
  }

  void _integrate(InputCommand cmd) {
    position += cmd.moveDir * (speed * cmd.dt);
  }
}

class _HistorySample {
  _HistorySample(this.time, this.positions);
  final double time;
  final Map<int, Vector3> positions;
}

/// Records historical entity positions so a server can rewind hitboxes to a
/// shooter's perceived timestamp (lag compensation).
class LagCompensator {
  LagCompensator({this.maxHistorySeconds = 1.0});

  final double maxHistorySeconds;
  final List<_HistorySample> _samples = [];

  void record(double serverTime, Map<int, Vector3> entityPositions) {
    _samples.add(_HistorySample(
      serverTime,
      {for (final e in entityPositions.entries) e.key: e.value.clone()},
    ));
    final cutoff = serverTime - maxHistorySeconds;
    while (_samples.length > 2 && _samples.first.time < cutoff) {
      _samples.removeAt(0);
    }
  }

  /// Returns interpolated position of [entityId] at [targetTime], or null.
  Vector3? sampleAt(int entityId, double targetTime) {
    if (_samples.isEmpty) return null;
    if (targetTime <= _samples.first.time) return _samples.first.positions[entityId]?.clone();
    if (targetTime >= _samples.last.time) return _samples.last.positions[entityId]?.clone();
    for (var i = 0; i < _samples.length - 1; i++) {
      final a = _samples[i], b = _samples[i + 1];
      if (targetTime >= a.time && targetTime <= b.time) {
        final pa = a.positions[entityId];
        final pb = b.positions[entityId];
        if (pa == null || pb == null) return pa?.clone() ?? pb?.clone();
        final t = (targetTime - a.time) / (b.time - a.time);
        return pa * (1.0 - t) + pb * t;
      }
    }
    return null;
  }
}

/// Encodes only changed fields between consecutive state maps to cut bandwidth.
class DeltaEncoder {
  final Map<String, Object?> _last = {};

  /// Returns a map containing only keys whose values changed since the last call.
  Map<String, Object?> encode(Map<String, Object?> fullState) {
    final diff = <String, Object?>{};
    for (final e in fullState.entries) {
      if (!_last.containsKey(e.key) || _last[e.key] != e.value) {
        diff[e.key] = e.value;
        _last[e.key] = e.value;
      }
    }
    return diff;
  }

  void reset() => _last.clear();
}
