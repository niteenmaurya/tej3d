import 'dart:math' as math;

import '../math/vec.dart';

import '../editor/inspector.dart';
import '../engine/game_object.dart';
import 'navmesh.dart';

/// Walks an object along a path on a [NavMesh] (an enemy, a pet, a villager).
///
/// ```dart
/// final agent = npc.addComponent(NavAgent(nav, speed: 3));
/// agent.setDestination(player.transform.worldPosition);   // false if there is no way
/// agent.onArrive = () => print('there');
/// ```
///
/// The agent turns to face where it walks (around the up axis) and keeps its
/// feet on the navmesh surface. For physics based bodies use the path from
/// [NavMesh.findPath] with your own movement code instead.
class NavAgent extends Component implements Inspectable {
  NavAgent(
    this.navMesh, {
    this.speed = 3.5,
    this.stoppingDistance = 0.1,
    this.turnSpeedDegrees = 540,
    this.snapToGround = true,
    this.repathSeconds = 0,
  });

  NavMesh navMesh;

  /// Walking speed in meters per second.
  double speed;

  /// It counts as arrived when this close to the end.
  double stoppingDistance;

  /// How fast it turns, degrees per second (0 = never turns).
  double turnSpeedDegrees;

  /// Put the feet on the navmesh surface.
  bool snapToGround;

  /// If above 0, the path is made again every so many seconds towards the
  /// same destination (for destinations that move, like a player).
  double repathSeconds;

  /// Called once when the destination is reached.
  void Function()? onArrive;

  List<Vector3> _path = [];
  int _next = 0;
  Vector3? _destination;
  bool _arrived = false;
  double _sinceRepath = 0;

  /// The points it is walking through (empty if none).
  List<Vector3> get path => List.unmodifiable(_path);

  bool get hasPath => _path.isNotEmpty && !_arrived;
  bool get hasArrived => _arrived;
  Vector3? get destination => _destination?.clone();

  /// Distance left along the path.
  double get remainingDistance {
    if (_path.isEmpty || _arrived) return 0;
    var d = (_path[math.min(_next, _path.length - 1)] - transform.worldPosition).length;
    for (var i = _next; i + 1 < _path.length; i++) {
      d += (_path[i + 1] - _path[i]).length;
    }
    return d;
  }

  /// Walk to [target]. Returns false (and stays where it is) if there is no way.
  bool setDestination(Vector3 target, {double maxSnap = double.infinity}) {
    final p = navMesh.findPath(transform.worldPosition, target, maxSnap: maxSnap);
    if (p == null) return false;
    _path = p;
    _next = p.length > 1 ? 1 : 0;
    _destination = target.clone();
    _arrived = false;
    _sinceRepath = 0;
    return true;
  }

  /// Forget the path and stop.
  void stop() {
    _path = [];
    _destination = null;
    _arrived = false;
  }

  @override
  void update(double dt) {
    if (dt <= 0) return;
    if (!hasPath) {
      return;
    }
    if (repathSeconds > 0 && _destination != null) {
      _sinceRepath += dt;
      if (_sinceRepath >= repathSeconds) {
        final d = _destination!;
        final ok = setDestination(d);
        if (!ok) {
          stop();
          return;
        }
      }
    }
    final t = transform;
    var pos = t.worldPosition;
    var budget = speed * dt;
    Vector3? lastDir;
    while (budget > 1e-9 && _next < _path.length) {
      final target = _path[_next];
      final to = target - pos;
      final dist = to.length;
      final isLast = _next == _path.length - 1;
      if (isLast && dist <= stoppingDistance) {
        _arrive(pos);
        break;
      }
      if (dist <= budget) {
        pos = target.clone();
        budget -= dist;
        if (dist > 1e-9) lastDir = to / dist;
        if (isLast) {
          _arrive(pos);
          break;
        }
        _next++;
      } else {
        lastDir = to / dist;
        pos += lastDir * budget;
        budget = 0;
      }
    }
    if (snapToGround) {
      final h = navMesh.heightAt(pos.x, pos.z, nearY: pos.y);
      if (h != null) pos = Vector3(pos.x, h, pos.z);
    }
    t.worldPosition = pos;
    if (lastDir != null && turnSpeedDegrees > 0) {
      final flat = Vector3(lastDir.x, 0, lastDir.z);
      if (flat.length > 1e-6) {
        // objects look along -Z
        final want = math.atan2(-flat.x, -flat.z);
        final cur = _yawOf(t.worldRotation);
        var diff = want - cur;
        while (diff > math.pi) {
          diff -= 2 * math.pi;
        }
        while (diff < -math.pi) {
          diff += 2 * math.pi;
        }
        final maxStep = turnSpeedDegrees * math.pi / 180.0 * dt;
        final step = diff.clamp(-maxStep, maxStep);
        t.worldRotation = Quaternion.axisAngle(Vector3(0, 1, 0), cur + step);
      }
    }
  }

  static double _yawOf(Quaternion q) {
    // yaw of the forward (-Z) direction: forward = rotate(q, (0,0,-1))
    final x = -2 * (q.x * q.z + q.w * q.y);
    final z = -(1 - 2 * (q.x * q.x + q.y * q.y));
    return math.atan2(-x, -z);
  }

  void _arrive(Vector3 pos) {
    _arrived = true;
    final cb = onArrive;
    if (cb != null) cb();
  }

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.float('speed', () => speed, (v) => speed = v, min: 0, max: 1000),
        InspectorField.float('stoppingDistance', () => stoppingDistance, (v) => stoppingDistance = v, min: 0),
        InspectorField.float('turnSpeedDegrees', () => turnSpeedDegrees, (v) => turnSpeedDegrees = v, min: 0),
        InspectorField.boolean('snapToGround', () => snapToGround, (v) => snapToGround = v),
        InspectorField.float('repathSeconds', () => repathSeconds, (v) => repathSeconds = v, min: 0),
        InspectorField.boolean('hasPath', () => hasPath, null),
        InspectorField.float('remainingDistance', () => remainingDistance, null),
      ];
}
