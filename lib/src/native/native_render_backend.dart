import 'dart:math' as math;
import 'dart:ui' as ui;

import '../engine/render/render_backend.dart';
import '../engine/render/render_frame.dart';
import 'native_scene_sync.dart';
import 'native_world.dart';

/// Draws a Dart scene with the C++ CPU renderer. It is faster than the
/// Dart renderer, and it also does per pixel PBR lighting, clearcoat, alpha,
/// SSAO, FXAA, mip mapped textures and a depth buffer (no sorting errors).
///
/// For headless / CI rendering without `dart:ui`, use [NativeSceneSync] directly.
class NativeRenderBackend extends RenderBackend {
  NativeRenderBackend(this.world, {this.resolutionScale = 0.6}) : sync = NativeSceneSync(world);

  /// The native world used for drawing. It may be the same one that
  /// [NativePhysics] uses.
  final NativeWorld world;

  /// Pure-Dart scene-to-native synchronizer (shared with headless rendering).
  final NativeSceneSync sync;

  /// 1.0 draws one pixel per screen pixel. Smaller is faster and softer.
  double resolutionScale;

  ui.Image? _image;
  bool _decoding = false;

  @override
  String get name => 'native CPU (C++)';

  @override
  void render(RenderFrame frame, ui.Canvas canvas, ui.Size size) {
    final w = math.max(2, (size.width * resolutionScale).round());
    final h = math.max(2, (size.height * resolutionScale).round());
    final rgba = sync.renderFrame(frame, w, h);
    if (!_decoding) {
      _decoding = true;
      ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, (img) {
        _image?.dispose();
        _image = img;
        _decoding = false;
      });
    }
    final img = _image;
    if (img == null) {
      final c = frame.clearColor;
      canvas.drawRect(
        ui.Offset.zero & size,
        ui.Paint()..color = ui.Color.fromARGB(255, (c.x * 255).round().clamp(0, 255), (c.y * 255).round().clamp(0, 255), (c.z * 255).round().clamp(0, 255)),
      );
      return;
    }
    canvas.drawImageRect(
      img,
      ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      ui.Offset.zero & size,
      ui.Paint()..filterQuality = ui.FilterQuality.low,
    );
  }

  @override
  void dispose() {
    _image?.dispose();
    _image = null;
  }
}
