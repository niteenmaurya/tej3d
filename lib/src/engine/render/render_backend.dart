import 'dart:ui' as ui;

import 'render_frame.dart';

/// Draws a [RenderFrame] onto a canvas. The software backend works today.
/// A GPU backend (Flutter GPU) will implement the same interface and draw its
/// result onto the canvas as an image.
abstract class RenderBackend {
  String get name;

  void render(RenderFrame frame, ui.Canvas canvas, ui.Size size);

  void dispose() {}
}
