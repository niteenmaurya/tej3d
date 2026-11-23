/// Hardware-agnostic GPU driver interface and [RenderBackend] adapter.
///
/// The pure-Dart frame compiler lives in `gpu_frame.dart`. Platform GPU
/// backends (Flutter GPU, Metal, Vulkan, WebGPU) implement [GpuDriver] and plug
/// into [GpuRenderBackend].
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'gpu_frame.dart';
import 'mesh.dart';
import 'render_backend.dart';
import 'render_frame.dart';

/// Low-level GPU command sink implemented by a platform graphics backend.
abstract class GpuDriver {
  String get driverName;

  /// Uploads or returns a cached handle for [mesh].
  int uploadMesh(Mesh mesh, GpuMeshBuffer buffer);

  /// Executes one compiled [GpuFramePacket] at [width]x[height] pixels.
  void submitFrame(GpuFramePacket packet, int width, int height);

  /// Optional RGBA readback for canvas presentation or visual regression tests.
  Uint8List? readbackRgba(int width, int height) => null;

  void dispose() {}
}

/// Headless [GpuDriver] that caches uploaded meshes and records submitted
/// packets for testing without a physical GPU.
class RecordingGpuDriver implements GpuDriver {
  @override
  String get driverName => 'RecordingGpuDriver';

  final Map<Mesh, int> uploadedMeshes = {};
  final List<GpuFramePacket> submittedPackets = [];
  int lastWidth = 0;
  int lastHeight = 0;
  bool disposed = false;

  @override
  int uploadMesh(Mesh mesh, GpuMeshBuffer buffer) {
    return uploadedMeshes.putIfAbsent(mesh, () => uploadedMeshes.length + 1);
  }

  @override
  void submitFrame(GpuFramePacket packet, int width, int height) {
    lastWidth = width;
    lastHeight = height;
    for (final d in packet.shadowDraws) {
      if (!uploadedMeshes.containsKey(d.mesh)) {
        uploadMesh(d.mesh, GpuMeshBuffer.fromMesh(d.mesh));
      }
    }
    for (final d in packet.opaqueDraws) {
      if (!uploadedMeshes.containsKey(d.mesh)) {
        uploadMesh(d.mesh, GpuMeshBuffer.fromMesh(d.mesh));
      }
    }
    for (final d in packet.transparentDraws) {
      if (!uploadedMeshes.containsKey(d.mesh)) {
        uploadMesh(d.mesh, GpuMeshBuffer.fromMesh(d.mesh));
      }
    }
    submittedPackets.add(packet);
  }

  @override
  Uint8List? readbackRgba(int width, int height) => null;

  @override
  void dispose() {
    disposed = true;
    uploadedMeshes.clear();
    submittedPackets.clear();
  }
}

/// [RenderBackend] that compiles each [RenderFrame] into a [GpuFramePacket]
/// and submits it to a [GpuDriver].
class GpuRenderBackend extends RenderBackend {
  GpuRenderBackend(this.driver);

  final GpuDriver driver;
  ui.Image? _lastImage;
  bool _decoding = false;
  bool _disposed = false;

  @override
  String get name => 'GPU (${driver.driverName})';

  @override
  void render(RenderFrame frame, ui.Canvas canvas, ui.Size size) {
    if (_disposed) return;
    final w = size.width.round();
    final h = size.height.round();
    if (w <= 0 || h <= 0) return;

    final packet = GpuFrameBuilder.build(frame);
    driver.submitFrame(packet, w, h);

    final img = _lastImage;
    if (img != null) {
      canvas.drawImageRect(
        img,
        ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        ui.Offset.zero & size,
        ui.Paint(),
      );
    }

    // If the driver provides a software/readback RGBA buffer, decode asynchronously
    // into _lastImage so it is drawn synchronously on the next paint pass.
    if (!_decoding) {
      final rgba = driver.readbackRgba(w, h);
      if (rgba != null && rgba.length >= w * h * 4) {
        _decoding = true;
        final copy = Uint8List.fromList(rgba.sublist(0, w * h * 4));
        ui.decodeImageFromPixels(
          copy,
          w,
          h,
          ui.PixelFormat.rgba8888,
          (image) {
            _decoding = false;
            if (_disposed) {
              image.dispose();
              return;
            }
            final old = _lastImage;
            _lastImage = image;
            old?.dispose();
          },
        );
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lastImage?.dispose();
    _lastImage = null;
    driver.dispose();
  }
}
