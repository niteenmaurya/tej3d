import 'dart:ui' as ui;

import 'render_backend.dart';
import 'render_frame.dart';
import 'software_rasterizer.dart';

/// Draws with `Canvas.drawVertices`. Works on every Flutter platform without
/// Flutter GPU. Made for low poly scenes. See [SoftwareRasterizer].
class SoftwareRenderBackend extends RenderBackend {
  final SoftwareRasterizer rasterizer = SoftwareRasterizer();

  @override
  String get name => 'software (Canvas)';

  final ui.Paint _white = ui.Paint()..color = const ui.Color(0xFFFFFFFF);

  @override
  void render(RenderFrame frame, ui.Canvas canvas, ui.Size size) {
    final c = frame.clearColor;
    canvas.drawRect(
      ui.Offset.zero & size,
      ui.Paint()
        ..color = ui.Color.fromARGB(
          (c.w * 255).round().clamp(0, 255),
          (c.x * 255).round().clamp(0, 255),
          (c.y * 255).round().clamp(0, 255),
          (c.z * 255).round().clamp(0, 255),
        ),
    );
    final r = rasterizer.rasterize(frame, size.width, size.height);
    if (r.triangleCount == 0) return;
    final v = ui.Vertices.raw(
      ui.VertexMode.triangles,
      r.positions,
      colors: r.colors,
    );
    // modulate with white keeps the vertex colors whichever side is "source".
    canvas.drawVertices(v, ui.BlendMode.modulate, _white);
  }
}
