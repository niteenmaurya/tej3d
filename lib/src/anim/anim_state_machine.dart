import '../editor/inspector.dart';
import '../engine/game_object.dart';
import '../math/vec.dart';

/// A single animation state inside [AnimationStateMachine] (e.g. Idle, Run, Aim, Shoot, Reload).
class AnimStateNode {
  AnimStateNode({
    required this.name,
    required this.clipName,
    this.loop = true,
    this.speed = 1.0,
    this.duration = 1.0,
  });

  final String name;
  final String clipName;
  final bool loop;
  final double speed;
  final double duration;

  Map<String, Object?> toJson() => {
        'name': name,
        'clipName': clipName,
        'loop': loop,
        'speed': speed,
        'duration': duration,
      };

  factory AnimStateNode.fromJson(Map<String, Object?> j) => AnimStateNode(
        name: j['name'] as String? ?? 'Idle',
        clipName: j['clipName'] as String? ?? 'Idle',
        loop: j['loop'] != false,
        speed: (j['speed'] as num?)?.toDouble() ?? 1.0,
        duration: (j['duration'] as num?)?.toDouble() ?? 1.0,
      );
}

/// Conditional transition between two [AnimStateNode] states.
class AnimStateTransition {
  AnimStateTransition({
    required this.from,
    required this.to,
    required this.parameter,
    this.operator = '>',
    this.threshold = 0.5,
    this.crossfadeSeconds = 0.15,
  });

  /// Source state name, or `'*'` for Any State.
  final String from;
  final String to;
  final String parameter;

  /// One of `'>'`, `'<'`, `'=='`, `'!='`, `'trigger'`.
  final String operator;
  final double threshold;
  final double crossfadeSeconds;

  bool matches(Map<String, double> params, Set<String> triggers) {
    if (operator == 'trigger') return triggers.contains(parameter);
    final v = params[parameter] ?? 0.0;
    return switch (operator) {
      '>' => v > threshold,
      '<' => v < threshold,
      '==' => (v - threshold).abs() < 1e-4,
      '!=' => (v - threshold).abs() >= 1e-4,
      _ => false,
    };
  }
}

/// Unity Animator-style state machine component driving skeletal clips or
/// procedural character animation states (`Idle -> Run -> Jump -> Aim -> Shoot -> Reload`).
class AnimationStateMachine extends Component implements Inspectable {
  AnimationStateMachine({
    List<AnimStateNode>? states,
    List<AnimStateTransition>? transitions,
    String? initialState,
  }) : states = states ?? defaultCharacterStates(),
       transitions = transitions ?? defaultCharacterTransitions() {
    currentState = initialState ?? (this.states.isNotEmpty ? this.states.first.name : 'Idle');
  }

  final List<AnimStateNode> states;
  final List<AnimStateTransition> transitions;
  final Map<String, double> parameters = {'speed': 0.0, 'grounded': 1.0, 'aiming': 0.0};
  final Set<String> _triggers = {};

  String currentState = 'Idle';
  String? previousState;
  double stateTime = 0.0;
  double crossfadeRemaining = 0.0;
  double crossfadeDuration = 0.0;

  /// Optional callback fired whenever the active state changes (e.g. to call `NativeModelAnimator.crossfade`).
  void Function(String clipName, double crossfadeSeconds, bool loop, double speed)? onStateChanged;

  static List<AnimStateNode> defaultCharacterStates() => [
        AnimStateNode(name: 'Idle', clipName: 'Idle', loop: true),
        AnimStateNode(name: 'Run', clipName: 'Run', loop: true),
        AnimStateNode(name: 'Jump', clipName: 'Jump', loop: false, duration: 0.6),
        AnimStateNode(name: 'Aim', clipName: 'Aim', loop: true),
        AnimStateNode(name: 'Shoot', clipName: 'Shoot', loop: false, duration: 0.25),
        AnimStateNode(name: 'Reload', clipName: 'Reload', loop: false, duration: 1.4),
      ];

  static List<AnimStateTransition> defaultCharacterTransitions() => [
        AnimStateTransition(from: 'Idle', to: 'Run', parameter: 'speed', operator: '>', threshold: 0.2),
        AnimStateTransition(from: 'Run', to: 'Idle', parameter: 'speed', operator: '<', threshold: 0.15),
        AnimStateTransition(from: '*', to: 'Jump', parameter: 'grounded', operator: '<', threshold: 0.5, crossfadeSeconds: 0.08),
        AnimStateTransition(from: 'Jump', to: 'Idle', parameter: 'grounded', operator: '>', threshold: 0.5, crossfadeSeconds: 0.1),
        AnimStateTransition(from: '*', to: 'Shoot', parameter: 'fire', operator: 'trigger', crossfadeSeconds: 0.05),
        AnimStateTransition(from: '*', to: 'Reload', parameter: 'reload', operator: 'trigger', crossfadeSeconds: 0.1),
        AnimStateTransition(from: 'Idle', to: 'Aim', parameter: 'aiming', operator: '>', threshold: 0.5),
        AnimStateTransition(from: 'Aim', to: 'Idle', parameter: 'aiming', operator: '<', threshold: 0.5),
      ];

  void setFloat(String name, double value) => parameters[name] = value;
  void setBool(String name, bool value) => parameters[name] = value ? 1.0 : 0.0;
  void setTrigger(String name) => _triggers.add(name);

  AnimStateNode? get activeNode {
    for (final s in states) {
      if (s.name == currentState) return s;
    }
    return null;
  }

  @override
  void update(double dt) {
    stateTime += dt;
    if (crossfadeRemaining > 0) {
      crossfadeRemaining = (crossfadeRemaining - dt).clamp(0.0, double.infinity);
    }

    // Return non-looping states (e.g. Shoot, Reload) to Idle/Run when finished
    final cur = activeNode;
    if (cur != null && !cur.loop && stateTime >= cur.duration) {
      final next = (parameters['speed'] ?? 0.0) > 0.2 ? 'Run' : 'Idle';
      _switchTo(next, 0.12);
    }

    for (final tr in transitions) {
      if ((tr.from == currentState || tr.from == '*') && tr.to != currentState) {
        if (tr.matches(parameters, _triggers)) {
          _switchTo(tr.to, tr.crossfadeSeconds);
          break;
        }
      }
    }
    _triggers.clear();
  }

  void _switchTo(String target, double fade) {
    previousState = currentState;
    currentState = target;
    stateTime = 0.0;
    crossfadeDuration = fade;
    crossfadeRemaining = fade;
    final node = activeNode;
    if (node != null) {
      onStateChanged?.call(node.clipName, fade, node.loop, node.speed);
    }
  }

  String get inspectorTitle => 'Animation State Machine';

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.text('State', () => currentState, (v) => _switchTo(v, 0.1)),
        InspectorField.float('Speed Param', () => parameters['speed'] ?? 0.0, (v) => setFloat('speed', v), min: 0, max: 20),
        InspectorField.boolean('Aiming', () => (parameters['aiming'] ?? 0.0) > 0.5, (v) => setBool('aiming', v)),
      ];
}

/// Attaches this [GameObject] (e.g. a rifle, sword, or helmet) to a named bone/socket
/// on a target character with an adjustable local offset and rotation.
class BoneSocketComponent extends Component implements Inspectable {
  BoneSocketComponent({
    this.boneName = 'Hand.R',
    Vector3? localOffset,
    Vector3? localEulerDeg,
    this.resolveBoneMatrix,
  }) : localOffset = localOffset?.clone() ?? Vector3(0.32, 1.15, -0.35),
       localEulerDeg = localEulerDeg?.clone() ?? Vector3.zero();

  String boneName;
  Vector3 localOffset;
  Vector3 localEulerDeg;

  /// Optional resolver returning the world-space matrix of [boneName] (e.g. from `NativeModelAnimator.boneWorldMatrix`).
  Matrix4? Function(String boneName)? resolveBoneMatrix;

  @override
  void update(double dt) => _syncSocket();

  @override
  void lateUpdate(double dt) => _syncSocket();

  void _syncSocket() {
    final boneMat = resolveBoneMatrix?.call(boneName);
    if (boneMat != null) {
      final pos = Vector3(boneMat.storage[12], boneMat.storage[13], boneMat.storage[14]);
      transform.worldPosition = pos + localOffset;
    } else if (gameObject.parent != null) {
      transform.localPosition = localOffset.clone();
    }
  }

  String get inspectorTitle => 'Bone Socket';

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.text('Bone Name', () => boneName, (v) => boneName = v),
        InspectorField.vector3('Local Offset', () => localOffset, (v) => localOffset = v),
        InspectorField.vector3('Local Euler', () => localEulerDeg, (v) => localEulerDeg = v),
      ];
}
