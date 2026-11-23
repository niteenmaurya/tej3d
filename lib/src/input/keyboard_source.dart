import 'package:flutter/services.dart';

import 'input_actions.dart';

/// Copies the pressed keys of the keyboard into a [RawInput] as
/// `key:<name>` = 1. Letters are lower case (`key:w`). Special names:
/// `space`, `left`, `right`, `up`, `down`, `shift`, `ctrl`, `alt`, `enter`,
/// `escape`, `tab`.
///
/// Gamepad is not included. It needs a plugin; write a second source that
/// sets `pad:*` controls.
class KeyboardSource {
  static final Map<LogicalKeyboardKey, String> _special = {
    LogicalKeyboardKey.space: 'space',
    LogicalKeyboardKey.arrowLeft: 'left',
    LogicalKeyboardKey.arrowRight: 'right',
    LogicalKeyboardKey.arrowUp: 'up',
    LogicalKeyboardKey.arrowDown: 'down',
    LogicalKeyboardKey.shiftLeft: 'shift',
    LogicalKeyboardKey.shiftRight: 'shift',
    LogicalKeyboardKey.controlLeft: 'ctrl',
    LogicalKeyboardKey.controlRight: 'ctrl',
    LogicalKeyboardKey.altLeft: 'alt',
    LogicalKeyboardKey.altRight: 'alt',
    LogicalKeyboardKey.enter: 'enter',
    LogicalKeyboardKey.escape: 'escape',
    LogicalKeyboardKey.tab: 'tab',
  };

  void poll(RawInput raw) {
    raw.clearPrefix('key:');
    for (final k in HardwareKeyboard.instance.logicalKeysPressed) {
      final name = _special[k] ?? k.keyLabel.toLowerCase();
      if (name.isNotEmpty) raw.set('key:$name', 1.0);
    }
  }
}
