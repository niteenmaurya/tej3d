import 'dart:math' as math;

import 'input_actions.dart';

/// One reading of a gamepad, in the "standard" layout (the one browsers and
/// most game pad plugins use):
///
/// - [axes]: 0 left stick X, 1 left stick Y, 2 right stick X, 3 right stick Y
///   (-1..1, stick **down** is +1 here, like the W3C Gamepad API).
/// - [buttons]: 0 south (A), 1 east (B), 2 west (X), 3 north (Y), 4 left
///   shoulder, 5 right shoulder, 6 left trigger, 7 right trigger, 8 select,
///   9 start, 10 left stick press, 11 right stick press, 12 d-pad up,
///   13 down, 14 left, 15 right, 16 home. Values 0..1 (triggers are analog).
///
/// Your game pad plugin reads the hardware; you copy its numbers in here.
class GamepadSnapshot {
  const GamepadSnapshot({this.axes = const [], this.buttons = const [], this.connected = true});

  final List<double> axes;
  final List<double> buttons;
  final bool connected;

  double axis(int i) => i < axes.length ? axes[i] : 0.0;
  double button(int i) => i < buttons.length ? buttons[i] : 0.0;
}

/// Anything that can tell the current state of the connected game pads.
abstract class GamepadProvider {
  /// One snapshot per pad (index 0 is the first player). Not connected pads
  /// may be missing or have `connected: false`.
  List<GamepadSnapshot> poll();
}

/// Turns [GamepadSnapshot]s into [RawInput] controls, so [InputAction]s can
/// use game pads like keys.
///
/// Controls written for pad `n` (prefix `pad:` for the first pad, `pad2:`,
/// `pad3:`... for the others):
/// `leftStickX`, `leftStickY`, `rightStickX`, `rightStickY` (**up and right are
/// positive**), `leftTrigger`, `rightTrigger`, `south`, `east`, `west`,
/// `north`, `leftShoulder`, `rightShoulder`, `select`, `start`,
/// `leftStickPress`, `rightStickPress`, `dpadUp`, `dpadDown`, `dpadLeft`,
/// `dpadRight`, `home`, and `connected` (1 or 0).
///
/// ```dart
/// final moveX = InputAction('MoveX', bindings: [
///   ControlBinding('pad:leftStickX'),
///   AxisCompositeBinding(negative: ['key:a'], positive: ['key:d']),
/// ]);
/// // every frame:
/// pads.update(raw);        // writes pad:* into raw
/// map.update(raw);
/// ```
class GamepadSource {
  GamepadSource(this.provider, {this.stickDeadZone = 0.15, this.triggerDeadZone = 0.05, this.maxPads = 4});

  final GamepadProvider provider;

  /// Sticks inside this circle count as centered. The rest is stretched so
  /// the output still reaches 1 at the edge (no jump when leaving the zone).
  double stickDeadZone;
  double triggerDeadZone;
  final int maxPads;

  static String prefixFor(int pad) => pad == 0 ? 'pad:' : 'pad${pad + 1}:';

  static const List<String> _buttonNames = [
    'south', 'east', 'west', 'north', 'leftShoulder', 'rightShoulder', 'leftTrigger', 'rightTrigger',
    'select', 'start', 'leftStickPress', 'rightStickPress', 'dpadUp', 'dpadDown', 'dpadLeft', 'dpadRight', 'home',
  ];

  /// Reads all pads and writes their controls into [raw].
  void update(RawInput raw) {
    final pads = provider.poll();
    for (var i = 0; i < maxPads; i++) {
      final prefix = prefixFor(i);
      raw.clearPrefix(prefix);
      if (i >= pads.length || !pads[i].connected) {
        raw.set('${prefix}connected', 0);
        continue;
      }
      write(raw, pads[i], prefix);
    }
  }

  /// Writes one pad with the given [prefix] (for example `pad:`).
  void write(RawInput raw, GamepadSnapshot s, String prefix) {
    raw.set('${prefix}connected', 1);
    final l = radial(s.axis(0), s.axis(1), stickDeadZone);
    final r = radial(s.axis(2), s.axis(3), stickDeadZone);
    raw.set('${prefix}leftStickX', l.$1);
    raw.set('${prefix}leftStickY', -l.$2); // up is positive
    raw.set('${prefix}rightStickX', r.$1);
    raw.set('${prefix}rightStickY', -r.$2);
    for (var b = 0; b < _buttonNames.length; b++) {
      var v = s.button(b).clamp(0.0, 1.0);
      if (b == 6 || b == 7) v = v < triggerDeadZone ? 0.0 : v;
      raw.set('$prefix${_buttonNames[b]}', v);
    }
    // Some pads report the d-pad as an axis pair instead of buttons.
    if (s.buttons.length <= 12 && s.axes.length >= 6) {
      final dx = s.axis(4), dy = s.axis(5);
      raw.set('${prefix}dpadLeft', dx < -0.5 ? 1.0 : 0.0);
      raw.set('${prefix}dpadRight', dx > 0.5 ? 1.0 : 0.0);
      raw.set('${prefix}dpadUp', dy < -0.5 ? 1.0 : 0.0);
      raw.set('${prefix}dpadDown', dy > 0.5 ? 1.0 : 0.0);
    }
  }

  /// Round dead zone: inside [zone] gives (0, 0); outside it the length is
  /// stretched so that the edge of the stick still gives 1. Not more than 1.
  static (double, double) radial(double x, double y, double zone) {
    final len = math.sqrt(x * x + y * y);
    if (len <= zone || len == 0) return (0.0, 0.0);
    final scaled = math.min(1.0, (len - zone) / (1.0 - zone));
    return (x / len * scaled, y / len * scaled);
  }
}

/// A [GamepadProvider] that you fill by hand. For tests, replays, and for
/// plugins that give you events instead of a state to poll.
class ManualGamepadProvider implements GamepadProvider {
  final List<GamepadSnapshot> pads = [];

  @override
  List<GamepadSnapshot> poll() => List.of(pads);
}
