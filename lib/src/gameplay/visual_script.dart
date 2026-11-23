import '../editor/inspector.dart';
import '../engine/game_object.dart';
import '../math/vec.dart';
import 'shooter_br_kit.dart';

/// Events that can fire a [VisualRule] without writing Dart code.
enum VisualTrigger {
  onStart,
  onUpdate,
  onTriggerEnter,
  onHealthZero,
  onTimer,
  onCustomEvent,
}

/// Actions executed when a [VisualRule] triggers.
enum VisualAction {
  addScore,
  damageTarget,
  healTarget,
  teleportSelf,
  setVariable,
  toggleActive,
  logMessage,
}

/// A single node-style Trigger → Action rule inside [VisualScriptComponent].
class VisualRule {
  VisualRule({
    required this.name,
    required this.trigger,
    required this.action,
    this.targetName = '',
    this.value = 10.0,
    this.textParam = '',
    this.intervalSeconds = 1.0,
    this.enabled = true,
  });

  String name;
  VisualTrigger trigger;
  VisualAction action;
  String targetName;
  double value;
  String textParam;
  double intervalSeconds;
  bool enabled;

  double _timer = 0.0;
  bool _ranOnce = false;

  Map<String, Object?> toJson() => {
        'name': name,
        'trigger': trigger.name,
        'action': action.name,
        'targetName': targetName,
        'value': value,
        'textParam': textParam,
        'intervalSeconds': intervalSeconds,
        'enabled': enabled,
      };

  factory VisualRule.fromJson(Map<String, Object?> j) => VisualRule(
        name: j['name'] as String? ?? 'Rule',
        trigger: VisualTrigger.values.byName(j['trigger'] as String? ?? 'onStart'),
        action: VisualAction.values.byName(j['action'] as String? ?? 'addScore'),
        targetName: j['targetName'] as String? ?? '',
        value: (j['value'] as num?)?.toDouble() ?? 10.0,
        textParam: j['textParam'] as String? ?? '',
        intervalSeconds: (j['intervalSeconds'] as num?)?.toDouble() ?? 1.0,
        enabled: j['enabled'] != false,
      );
}

/// No-code Visual Event Scripting component that runs live in Editor Play Mode
/// and exported games (Trigger → Action rules + local blackboard variables).
class VisualScriptComponent extends Component implements Inspectable {
  VisualScriptComponent({List<VisualRule>? rules}) : rules = rules ?? [];

  final List<VisualRule> rules;
  final Map<String, double> variables = {};
  final List<String> executionLog = [];

  int scoreDelta = 0;

  void Function(int delta)? onScoreChanged;
  void Function(String message)? onLog;

  /// Fires all rules matching [VisualTrigger.onCustomEvent] with [eventName].
  void emitEvent(String eventName, {GameObject? other}) {
    for (final r in rules) {
      if (!r.enabled || r.trigger != VisualTrigger.onCustomEvent) continue;
      if (r.textParam.isEmpty || r.textParam == eventName) {
        _execute(r, other: other);
      }
    }
  }

  @override
  void start() {
    for (final r in rules) {
      if (r.enabled && r.trigger == VisualTrigger.onStart && !r._ranOnce) {
        r._ranOnce = true;
        _execute(r);
      }
    }
  }

  @override
  void onTriggerEnter(GameObject other) {
    for (final r in rules) {
      if (r.enabled && r.trigger == VisualTrigger.onTriggerEnter) {
        _execute(r, other: other);
      }
    }
  }

  @override
  void update(double dt) {
    final hp = gameObject.getComponent<HealthDamageComponent>();
    for (final r in rules) {
      if (!r.enabled) continue;
      if (r.trigger == VisualTrigger.onUpdate) {
        _execute(r);
      } else if (r.trigger == VisualTrigger.onTimer) {
        r._timer += dt;
        if (r._timer >= r.intervalSeconds) {
          r._timer = 0.0;
          _execute(r);
        }
      } else if (r.trigger == VisualTrigger.onHealthZero && hp != null && hp.isDead && !r._ranOnce) {
        r._ranOnce = true;
        _execute(r);
      }
    }
  }

  void _execute(VisualRule rule, {GameObject? other}) {
    final scene = gameObject.scene;
    final target = rule.targetName.isNotEmpty
        ? (scene?.find(rule.targetName) ?? other ?? gameObject)
        : (other ?? gameObject);

    switch (rule.action) {
      case VisualAction.addScore:
        final delta = rule.value.round();
        scoreDelta += delta;
        onScoreChanged?.call(delta);
      case VisualAction.damageTarget:
        target.getComponent<HealthDamageComponent>()?.takeDamage(rule.value, attacker: gameObject);
      case VisualAction.healTarget:
        target.getComponent<HealthDamageComponent>()?.heal(rule.value);
      case VisualAction.teleportSelf:
        transform.localPosition = Vector3(0, rule.value, 0);
      case VisualAction.setVariable:
        final key = rule.textParam.isEmpty ? 'var' : rule.textParam;
        variables[key] = rule.value;
      case VisualAction.toggleActive:
        target.active = !target.activeSelf;
      case VisualAction.logMessage:
        final msg = rule.textParam.isEmpty ? rule.name : rule.textParam;
        executionLog.add(msg);
        onLog?.call(msg);
    }
  }

  String get inspectorTitle => 'Visual Script (${rules.length} rules)';

  @override
  List<InspectorField> get inspectorFields => [
        InspectorField.float('Rule Count', () => rules.length.toDouble(), (_) {}, min: 0, max: 100),
      ];
}
