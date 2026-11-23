import '../math/vec.dart';

/// Raw control values by name. Adapters (keyboard, gamepad, touch) write to
/// it, [InputAction]s read from it. Names look like `key:w`, `key:space`,
/// `pad:leftStickX`, `pad:south`, `touch:throttle`. Values are 0..1 for
/// buttons and -1..1 for axes.
class RawInput {
  final Map<String, double> _v = {};

  void set(String control, double value) => _v[control] = value;

  double get(String control) => _v[control] ?? 0.0;

  void clear() => _v.clear();

  /// Removes every control that starts with [prefix] (for example `key:`).
  void clearPrefix(String prefix) =>
      _v.removeWhere((k, _) => k.startsWith(prefix));
}

/// One way to produce a number for an action.
abstract class Binding {
  const Binding();
  double read(RawInput raw);
}

/// A single control, for example a key or a stick axis.
class ControlBinding extends Binding {
  const ControlBinding(
    this.control, {
    this.scale = 1.0,
    this.deadZone = 0.0,
  });

  final String control;

  /// Multiplies the value. -1 turns an axis around.
  final double scale;

  /// Values smaller than this count as 0.
  final double deadZone;

  @override
  double read(RawInput raw) {
    final v = raw.get(control);
    return v.abs() < deadZone ? 0.0 : v * scale;
  }
}

/// Two sets of controls make one axis, for example A/D or left/right keys.
class AxisCompositeBinding extends Binding {
  const AxisCompositeBinding({this.negative = const [], this.positive = const []});

  final List<String> negative;
  final List<String> positive;

  @override
  double read(RawInput raw) {
    var n = 0.0;
    var p = 0.0;
    for (final c in negative) {
      if (raw.get(c) > n) n = raw.get(c);
    }
    for (final c in positive) {
      if (raw.get(c) > p) p = raw.get(c);
    }
    return p - n;
  }
}

/// A named action like "Jump" or "Steer", like Unity's Input System.
/// Game code reads the action, never the key, so keys can be rebound.
class InputAction {
  InputAction(this.name, {List<Binding>? bindings, this.pressPoint = 0.5})
    // Copy, so a `const [...]` list passed in can still be rebound later.
    : bindings = List<Binding>.of(bindings ?? const <Binding>[]);

  final String name;
  final List<Binding> bindings;

  /// Absolute value at or above this counts as pressed.
  final double pressPoint;

  double _value = 0.0;
  bool _pressed = false;
  bool _wasPressed = false;
  bool _wasReleased = false;

  /// The strongest value of all bindings (keeps its sign).
  double get value => _value;

  bool get isPressed => _pressed;

  /// True only in the frame the action went down.
  bool get wasPressedThisFrame => _wasPressed;

  /// True only in the frame the action went up.
  bool get wasReleasedThisFrame => _wasReleased;

  void update(RawInput raw) {
    var best = 0.0;
    for (final b in bindings) {
      final v = b.read(raw);
      if (v.abs() > best.abs()) best = v;
    }
    _value = best;
    final now = best.abs() >= pressPoint;
    _wasPressed = now && !_pressed;
    _wasReleased = !now && _pressed;
    _pressed = now;
  }

  /// Replaces one binding, for a key rebinding screen.
  void rebind(int index, Binding binding) => bindings[index] = binding;
}

/// A group of actions, like an Action Map in Unity. Call [update] each frame.
class InputActionMap {
  InputActionMap(this.name);

  final String name;
  final Map<String, InputAction> _actions = {};

  InputAction add(InputAction a) {
    _actions[a.name] = a;
    return a;
  }

  InputAction operator [](String name) {
    final a = _actions[name];
    if (a == null) throw ArgumentError('No input action "$name".');
    return a;
  }

  bool has(String name) => _actions.containsKey(name);

  Iterable<InputAction> get actions => _actions.values;

  /// Two actions as one stick or pad value.
  Vector2 vector2(String xAction, String yAction) =>
      Vector2(this[xAction].value, this[yAction].value);

  void update(RawInput raw) {
    for (final a in _actions.values) {
      a.update(raw);
    }
  }

  /// Controls of every [ControlBinding], to save custom key settings.
  Map<String, List<String>> exportControls() => {
    for (final a in _actions.values)
      a.name: [
        for (final b in a.bindings)
          if (b is ControlBinding) b.control,
      ],
  };

  /// Applies saved controls from [exportControls]. Only changes bindings that
  /// are a [ControlBinding] and keeps their scale and dead zone.
  void applyControls(Map<String, List<String>> saved) {
    for (final entry in saved.entries) {
      final a = _actions[entry.key];
      if (a == null) continue;
      var k = 0;
      for (var i = 0; i < a.bindings.length && k < entry.value.length; i++) {
        final b = a.bindings[i];
        if (b is ControlBinding) {
          a.bindings[i] = ControlBinding(
            entry.value[k],
            scale: b.scale,
            deadZone: b.deadZone,
          );
          k++;
        }
      }
    }
  }
}
