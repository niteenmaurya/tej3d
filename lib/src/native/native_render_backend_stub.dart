import 'native_scene_sync.dart';
import 'native_world.dart';

/// Stub for headless Dart VM environments where `dart:ui` is unavailable.
/// Use [NativeSceneSync] directly for headless rendering to RGBA/PNG/AVI.
class NativeRenderBackend {
  NativeRenderBackend(this.world, {this.resolutionScale = 0.6}) : sync = NativeSceneSync(world);

  final NativeWorld world;
  final NativeSceneSync sync;
  double resolutionScale;

  String get name => 'native CPU (C++, headless)';

  void dispose() {}
}
