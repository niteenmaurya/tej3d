import '../math/mathf.dart';
import 'animation_curve.dart';

/// The result of animation: a number for each named channel.
///
/// A channel name is any string your game understands, for example
/// `Door.angle` or `Arm.swing`. A small adapter in your game copies the
/// values to nodes. Rotation channels are Euler angles in degrees.
///
/// Several samples can be added to one channel with weights. The value is the
/// weighted average. A channel with total weight 0 counts as missing.
class Pose {
  final Map<String, double> _sum = {};
  final Map<String, double> _w = {};

  void add(String channel, double value, double weight) {
    _sum[channel] = (_sum[channel] ?? 0.0) + value * weight;
    _w[channel] = (_w[channel] ?? 0.0) + weight;
  }

  /// The value, or null if nothing was written to the channel.
  double? operator [](String channel) {
    final w = _w[channel];
    if (w == null || w <= 0.0) return null;
    return _sum[channel]! / w;
  }

  Iterable<String> get channels => _w.keys;

  void clear() {
    _sum.clear();
    _w.clear();
  }

  /// Puts [other] on top of this pose. 1 replaces, 0.5 mixes half.
  /// With a [mask], only those channels are touched (animation layer mask).
  void overlay(Pose other, double weight, [Set<String>? mask]) {
    final k = Mathf.clamp01(weight);
    for (final ch in other._w.keys.toList()) {
      if (mask != null && !mask.contains(ch)) continue;
      final ov = other[ch];
      if (ov == null) continue;
      final cur = this[ch];
      final value = cur == null ? ov : cur + (ov - cur) * k;
      _sum[ch] = value;
      _w[ch] = 1.0;
    }
  }
}

/// A named moment in a clip, for footstep sounds, hit frames and so on.
class AnimationEvent {
  const AnimationEvent(this.time, this.name);
  final double time;
  final String name;
}

/// A recorded animation: one curve per channel. Like Unity `AnimationClip`.
class AnimationClip {
  AnimationClip(
    this.name,
    this.curves, {
    double? length,
    this.wrap = WrapMode.loop,
    List<AnimationEvent>? events,
  }) : length = length ?? _maxLength(curves),
       events = (events == null ? <AnimationEvent>[] : List.of(events))
         ..sort((a, b) => a.time.compareTo(b.time));

  final String name;
  final Map<String, AnimationCurve> curves;
  final double length;
  final WrapMode wrap;
  final List<AnimationEvent> events;

  static double _maxLength(Map<String, AnimationCurve> curves) {
    var m = 0.0;
    for (final c in curves.values) {
      if (c.length > m) m = c.length;
    }
    return m;
  }

  double _clipTime(double time) {
    if (length <= 0.0) return 0.0;
    switch (wrap) {
      case WrapMode.clamp:
        return Mathf.clamp(time, 0.0, length);
      case WrapMode.loop:
        return Mathf.repeat(time, length);
      case WrapMode.pingPong:
        return Mathf.pingPong(time, length);
    }
  }

  void sample(double time, Pose pose, double weight) {
    final t = _clipTime(time);
    curves.forEach((channel, curve) {
      pose.add(channel, curve.evaluate(t), weight);
    });
  }

  /// Calls [emit] for each event passed while time went from [from] to [to].
  /// Times are not wrapped: they only grow while the clip plays.
  void collectEvents(double from, double to, void Function(String name) emit) {
    if (events.isEmpty || to <= from) return;
    if (wrap == WrapMode.loop && length > 0.0) {
      final firstLap = (from / length).floor();
      final lastLap = (to / length).floor();
      for (var lap = firstLap; lap <= lastLap; lap++) {
        for (final e in events) {
          final et = lap * length + e.time;
          if (et > from && et <= to) emit(e.name);
        }
      }
    } else {
      for (final e in events) {
        if (e.time > from && e.time <= to) emit(e.name);
      }
    }
  }
}

/// The numbers that drive an [Animator]: floats, ints, bools and triggers.
class AnimatorParams {
  final Map<String, double> _values = {};
  final Set<String> _triggers = {};

  void setFloat(String name, double v) => _values[name] = v;
  double getFloat(String name) => _values[name] ?? 0.0;

  void setInt(String name, int v) => _values[name] = v.toDouble();
  int getInt(String name) => getFloat(name).round();

  void setBool(String name, bool v) => _values[name] = v ? 1.0 : 0.0;
  bool getBool(String name) => getFloat(name) != 0.0;

  /// A trigger stays on until a transition uses it.
  void setTrigger(String name) => _triggers.add(name);
  void resetTrigger(String name) => _triggers.remove(name);
  bool isTriggered(String name) => _triggers.contains(name);
}

/// Something an animation state plays: one clip or a blend tree.
abstract class Motion {
  double get length;

  void sample(double time, Pose pose, double weight, AnimatorParams params);

  void collectEvents(
    double from,
    double to,
    AnimatorParams params,
    void Function(String name) emit,
  ) {}
}

class ClipMotion extends Motion {
  ClipMotion(this.clip);

  final AnimationClip clip;

  @override
  double get length => clip.length;

  @override
  void sample(double time, Pose pose, double weight, AnimatorParams params) =>
      clip.sample(time, pose, weight);

  @override
  void collectEvents(
    double from,
    double to,
    AnimatorParams params,
    void Function(String name) emit,
  ) => clip.collectEvents(from, to, emit);
}

class BlendChild {
  BlendChild(this.threshold, this.motion);
  final double threshold;
  final Motion motion;
}

/// Mixes motions by one float parameter, for example idle, walk, run by
/// `speed`. Clips are played at the same normalized time. Clip events of
/// children are not fired.
class BlendTree1D extends Motion {
  BlendTree1D(this.parameter, List<BlendChild> children)
    : children = List.of(children)
        ..sort((a, b) => a.threshold.compareTo(b.threshold));

  final String parameter;
  final List<BlendChild> children;

  @override
  double get length {
    var m = 0.0;
    for (final c in children) {
      if (c.motion.length > m) m = c.motion.length;
    }
    return m;
  }

  /// Weight of each child for a parameter value. They add up to 1.
  List<double> weightsFor(double v) {
    final n = children.length;
    final w = List<double>.filled(n, 0.0);
    if (n == 0) return w;
    if (n == 1 || v <= children.first.threshold) {
      w[0] = 1.0;
      return w;
    }
    if (v >= children.last.threshold) {
      w[n - 1] = 1.0;
      return w;
    }
    for (var i = 0; i < n - 1; i++) {
      final a = children[i].threshold;
      final b = children[i + 1].threshold;
      if (v >= a && v <= b) {
        final u = b == a ? 0.0 : (v - a) / (b - a);
        w[i] = 1.0 - u;
        w[i + 1] = u;
        break;
      }
    }
    return w;
  }

  @override
  void sample(double time, Pose pose, double weight, AnimatorParams params) {
    final w = weightsFor(params.getFloat(parameter));
    final len = length;
    final tn = len > 0.0 ? time / len : 0.0;
    for (var i = 0; i < children.length; i++) {
      if (w[i] <= 0.0) continue;
      final m = children[i].motion;
      m.sample(tn * m.length, pose, weight * w[i], params);
    }
  }
}

/// One child of a [BlendTree2D]: a motion that is full strength at [x], [y] of the two parameters.
class BlendChild2D {
  BlendChild2D(this.x, this.y, this.motion);
  final double x, y;
  final Motion motion;
}

/// Mixes motions by two float parameters, for example walk forward, back, left, right by `moveX` and
/// `moveY` (like Unity "2D Freeform Cartesian"). Each child is strongest at its own place and fades
/// out towards the others. Clips are played at the same normalized time. Clip events of children are
/// not fired.
class BlendTree2D extends Motion {
  BlendTree2D(this.parameterX, this.parameterY, List<BlendChild2D> children) : children = List.of(children);

  final String parameterX, parameterY;
  final List<BlendChild2D> children;

  @override
  double get length {
    var m = 0.0;
    for (final c in children) {
      if (c.motion.length > m) m = c.motion.length;
    }
    return m;
  }

  /// Weight of each child at the point ([x], [y]). They add up to 1. At the place of a child its
  /// weight is 1 and the others are 0.
  List<double> weightsFor(double x, double y) {
    final n = children.length;
    final w = List<double>.filled(n, 0.0);
    if (n == 0) return w;
    if (n == 1) {
      w[0] = 1.0;
      return w;
    }
    for (var i = 0; i < n; i++) {
      final pix = x - children[i].x, piy = y - children[i].y;
      var wi = 1.0;
      for (var j = 0; j < n && wi > 0.0; j++) {
        if (j == i) continue;
        final dx = children[j].x - children[i].x, dy = children[j].y - children[i].y;
        final len2 = dx * dx + dy * dy;
        if (len2 < 1e-18) continue; // two children at the same place share it
        final h = (1.0 - (pix * dx + piy * dy) / len2).clamp(0.0, 1.0).toDouble();
        if (h < wi) wi = h;
      }
      w[i] = wi;
    }
    var sum = 0.0;
    for (final v in w) {
      sum += v;
    }
    if (sum <= 1e-12) {
      // cannot happen for different places; be safe and use the nearest child
      var best = 0;
      var bd = double.infinity;
      for (var i = 0; i < n; i++) {
        final d = (x - children[i].x) * (x - children[i].x) + (y - children[i].y) * (y - children[i].y);
        if (d < bd) {
          bd = d;
          best = i;
        }
      }
      w[best] = 1.0;
      return w;
    }
    for (var i = 0; i < n; i++) {
      w[i] /= sum;
    }
    return w;
  }

  @override
  void sample(double time, Pose pose, double weight, AnimatorParams params) {
    final w = weightsFor(params.getFloat(parameterX), params.getFloat(parameterY));
    final len = length;
    final tn = len > 0.0 ? time / len : 0.0;
    for (var i = 0; i < children.length; i++) {
      if (w[i] <= 0.0) continue;
      final m = children[i].motion;
      m.sample(tn * m.length, pose, weight * w[i], params);
    }
  }
}

enum CondOp { greater, less, equals, notEquals, isTrue, isFalse, trigger }

/// One rule of a transition, for example `Cond.greater('speed', 0.1)`.
class Cond {
  const Cond(this.param, this.op, [this.value = 0.0]);
  const Cond.greater(String param, double value)
    : this(param, CondOp.greater, value);
  const Cond.less(String param, double value) : this(param, CondOp.less, value);
  const Cond.equals(String param, double value)
    : this(param, CondOp.equals, value);
  const Cond.notEquals(String param, double value)
    : this(param, CondOp.notEquals, value);
  const Cond.isTrue(String param) : this(param, CondOp.isTrue);
  const Cond.isFalse(String param) : this(param, CondOp.isFalse);
  const Cond.trigger(String param) : this(param, CondOp.trigger);

  final String param;
  final CondOp op;
  final double value;

  bool check(AnimatorParams p) {
    switch (op) {
      case CondOp.greater:
        return p.getFloat(param) > value;
      case CondOp.less:
        return p.getFloat(param) < value;
      case CondOp.equals:
        return (p.getFloat(param) - value).abs() < 1e-6;
      case CondOp.notEquals:
        return (p.getFloat(param) - value).abs() >= 1e-6;
      case CondOp.isTrue:
        return p.getBool(param);
      case CondOp.isFalse:
        return !p.getBool(param);
      case CondOp.trigger:
        return p.isTriggered(param);
    }
  }
}

class AnimTransition {
  AnimTransition(
    this.to, {
    List<Cond>? conditions,
    this.duration = 0.15,
    this.hasExitTime = false,
    this.exitTime = 0.9,
    this.canTransitionToSelf = false,
  }) : conditions = conditions ?? <Cond>[];

  final AnimState to;
  final List<Cond> conditions;

  /// Cross fade length in seconds. 0 switches at once.
  final double duration;

  /// If true, the transition waits until the state is at [exitTime]
  /// (1.0 = one full play of the motion).
  final bool hasExitTime;
  final double exitTime;
  final bool canTransitionToSelf;
}

class AnimState {
  AnimState(this.name, this.motion, {this.speed = 1.0, this.speedParam});

  final String name;
  final Motion motion;

  /// Play speed. 1 is normal.
  double speed;

  /// If set, the float parameter with this name multiplies the speed.
  String? speedParam;

  final List<AnimTransition> transitions = [];

  /// Seconds since the state started.
  double time = 0.0;

  double get normalizedTime =>
      motion.length > 0.0 ? time / motion.length : 0.0;

  AnimTransition transitionTo(
    AnimState to, {
    List<Cond>? conditions,
    double duration = 0.15,
    bool hasExitTime = false,
    double exitTime = 0.9,
  }) {
    final t = AnimTransition(
      to,
      conditions: conditions,
      duration: duration,
      hasExitTime: hasExitTime,
      exitTime: exitTime,
    );
    transitions.add(t);
    return t;
  }
}

/// One state machine. A layer with a [mask] only moves those channels
/// (for example an upper-body layer).
class AnimatorLayer {
  AnimatorLayer(this.name, {this.weight = 1.0, this.mask});

  final String name;

  /// 0 to 1. How strongly this layer overrides the layers below.
  double weight;

  /// Channels this layer may change. Null means all.
  final Set<String>? mask;

  final List<AnimState> states = [];

  /// Transitions that can start from any state.
  final List<AnimTransition> anyStateTransitions = [];

  AnimState? defaultState;
  AnimState? current;
  AnimState? _next;
  double _fade = 0.0;
  double _fadeLen = 0.0;

  final Pose pose = Pose();

  AnimState? get next => _next;
  bool get isTransitioning => _next != null;

  AnimState addState(AnimState s) {
    states.add(s);
    defaultState ??= s;
    return s;
  }

  /// Jumps to a state at once.
  void play(AnimState s) {
    current = s;
    s.time = 0.0;
    _next = null;
  }

  /// Blends to a state over [duration] seconds.
  void crossFadeTo(AnimState s, double duration) {
    if (duration <= 0.0) {
      play(s);
      return;
    }
    s.time = 0.0;
    _next = s;
    _fade = 0.0;
    _fadeLen = duration;
  }

  double _speedOf(AnimState s, AnimatorParams p) {
    final sp = s.speedParam;
    return s.speed * (sp == null ? 1.0 : p.getFloat(sp));
  }

  void update(double dt, AnimatorParams params, void Function(String) emit) {
    current ??= defaultState;
    final cur = current;
    if (cur == null) return;
    final before = cur.time;
    cur.time += dt * _speedOf(cur, params);
    cur.motion.collectEvents(before, cur.time, params, emit);
    final nxt = _next;
    if (nxt != null) {
      nxt.time += dt * _speedOf(nxt, params);
      _fade += dt;
      if (_fade >= _fadeLen) {
        current = nxt;
        _next = null;
      }
    } else {
      _evaluateTransitions(cur, params);
    }
  }

  void _evaluateTransitions(AnimState cur, AnimatorParams params) {
    for (final t in anyStateTransitions) {
      if (_canFire(cur, t, params)) {
        _begin(t, params);
        return;
      }
    }
    for (final t in cur.transitions) {
      if (_canFire(cur, t, params)) {
        _begin(t, params);
        return;
      }
    }
  }

  bool _canFire(AnimState cur, AnimTransition t, AnimatorParams p) {
    if (t.to == cur && !t.canTransitionToSelf) return false;
    if (t.hasExitTime && cur.normalizedTime < t.exitTime) return false;
    if (!t.hasExitTime && t.conditions.isEmpty) return false;
    for (final c in t.conditions) {
      if (!c.check(p)) return false;
    }
    return true;
  }

  void _begin(AnimTransition t, AnimatorParams p) {
    for (final c in t.conditions) {
      if (c.op == CondOp.trigger) p.resetTrigger(c.param);
    }
    crossFadeTo(t.to, t.duration);
  }

  /// Writes this layer's result into [pose].
  void sample(AnimatorParams params) {
    pose.clear();
    final cur = current;
    if (cur == null) return;
    final nxt = _next;
    if (nxt == null) {
      cur.motion.sample(cur.time, pose, 1.0, params);
      return;
    }
    final w = _fadeLen <= 0.0 ? 1.0 : Mathf.clamp01(_fade / _fadeLen);
    cur.motion.sample(cur.time, pose, 1.0 - w, params);
    nxt.motion.sample(nxt.time, pose, w, params);
  }
}

/// Plays state machines and gives a [Pose] each frame. Like Unity `Animator`
/// with an Animator Controller, but without the editor.
///
/// ```dart
/// final idle = AnimState('idle', ClipMotion(idleClip));
/// final run = AnimState('run', ClipMotion(runClip));
/// idle.transitionTo(run, conditions: [Cond.greater('speed', 0.1)]);
/// run.transitionTo(idle, conditions: [Cond.less('speed', 0.1)]);
/// final layer = AnimatorLayer('base')..addState(idle)..addState(run);
/// final animator = Animator(layers: [layer]);
/// animator.params.setFloat('speed', 5);
/// animator.update(dt);
/// final x = animator.pose['Door.angle'];
/// ```
class Animator {
  Animator({List<AnimatorLayer>? layers, this.onEvent})
    : layers = layers ?? <AnimatorLayer>[];

  final List<AnimatorLayer> layers;
  final AnimatorParams params = AnimatorParams();

  /// Called for each clip event that is passed.
  void Function(String name)? onEvent;

  /// The final mixed result after [update].
  final Pose pose = Pose();

  void update(double dt) {
    pose.clear();
    for (var i = 0; i < layers.length; i++) {
      final layer = layers[i];
      layer.update(dt, params, (n) => onEvent?.call(n));
      layer.sample(params);
      if (i == 0) {
        pose.overlay(layer.pose, 1.0);
      } else if (layer.weight > 0.0) {
        pose.overlay(layer.pose, layer.weight, layer.mask);
      }
    }
  }

  /// The state a layer is in now (null before the first update).
  AnimState? stateOf(int layerIndex) => layers[layerIndex].current;
}
