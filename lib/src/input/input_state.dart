import 'package:flutter/services.dart';

/// Reads the keyboard without needing a focus widget.
///
/// It asks Flutter's `HardwareKeyboard` which keys are down right now, so it
/// works on desktop, web and Android with a keyboard.
class KeyboardState {
  const KeyboardState();

  bool isDown(LogicalKeyboardKey key) =>
      HardwareKeyboard.instance.isLogicalKeyPressed(key);

  bool get shift => HardwareKeyboard.instance.isShiftPressed;

  /// -1 for left (A or left arrow), +1 for right (D or right arrow).
  double get horizontal =>
      (_any(_right) ? 1.0 : 0.0) - (_any(_left) ? 1.0 : 0.0);

  /// +1 for forward (W or up arrow), -1 for back (S or down arrow).
  double get vertical => (_any(_up) ? 1.0 : 0.0) - (_any(_down) ? 1.0 : 0.0);

  bool get space => isDown(LogicalKeyboardKey.space);

  bool _any(List<LogicalKeyboardKey> keys) => keys.any(isDown);

  static final _left = [LogicalKeyboardKey.keyA, LogicalKeyboardKey.arrowLeft];
  static final _right = [
    LogicalKeyboardKey.keyD,
    LogicalKeyboardKey.arrowRight,
  ];
  static final _up = [LogicalKeyboardKey.keyW, LogicalKeyboardKey.arrowUp];
  static final _down = [LogicalKeyboardKey.keyS, LogicalKeyboardKey.arrowDown];
}
