import 'dart:ui' as ui;

import '../anim/tween.dart';
import '../core/coroutine.dart';
import '../core/fixed_stepper.dart';
import '../core/profiler.dart';
import '../engine/camera.dart';
import '../engine/game_object.dart';
import '../engine/render/render_backend.dart';
import '../engine/render/render_frame.dart';
import '../engine/render/software_backend.dart';
import '../input/input_actions.dart';
import '../input/input_state.dart';
import '../input/keyboard_source.dart';
import '../math/mathf.dart';
import 'active_overlays.dart';

/// Base class of every game. Extend it, like `FlameGame` in Flame or a scene
/// with scripts in Unity.
///
/// ```dart
/// class MyGame extends Tej3DGame {
///   @override
///   Future<void> onLoad() async {
///     final cam = GameObject('Camera')..addComponent(Camera());
///     cam.transform.worldPosition = Vector3(0, 3, 8);
///     scene.add(cam);
///   }
///
///   @override
///   void onUpdate(double dt) {}
/// }
/// ```
///
/// Show it with `Tej3DGameWidget(game: MyGame())`.
abstract class Tej3DGame {
  Tej3DGame({RenderBackend? backend})
    : backend = backend ?? SoftwareRenderBackend();

  /// All objects of the level.
  final Scene scene = Scene();

  /// Overlays are normal Flutter widgets drawn above the game.
  final ActiveOverlays overlays = ActiveOverlays();

  /// Draws the picture. Software today, GPU later.
  RenderBackend backend;

  /// Quick keyboard reader (WASD, arrows, space).
  final KeyboardState keyboard = const KeyboardState();

  /// Raw controls (keys, later pads). Read through [input].
  final RawInput rawInput = RawInput();

  /// Your named actions (Jump, Steer, ...). Add actions in [onLoad].
  final InputActionMap input = InputActionMap('Game');

  final KeyboardSource keyboardSource = KeyboardSource();

  /// Coroutines (`sync*` functions with `yield Wait.seconds(1)`).
  final CoroutineRunner coroutines = CoroutineRunner();

  /// Number tweens (fades, moves).
  final TweenRunner tweens = TweenRunner();

  /// Equal time steps for gameplay logic. See [onFixedUpdate].
  final FixedStepper fixedStepper = FixedStepper();

  /// Frame time and section timing.
  final FrameProfiler profiler = FrameProfiler();

  /// The camera to draw with. If null, the first active [Camera] in the
  /// scene is used.
  Camera? camera;

  /// What the last picture showed (objects drawn and culled).
  RenderStats? lastStats;

  bool _loaded = false;
  bool _disposed = false;

  /// True after [onLoad] has finished.
  bool get isLoaded => _loaded;

  Future<void>? _booting;

  /// Called once. Load models and build the world here.
  Future<void> onLoad() async {}

  /// Called every frame before components update. [dt] is in seconds.
  void onUpdate(double dt) {}

  /// Called with equal time steps ([fixedStepper]).
  void onFixedUpdate(double step) {}

  /// Called every frame after all components updated.
  void onPostUpdate(double dt) {}

  /// Called when the game widget is removed.
  void onRemove() {}

  /// Called by the game widget. You do not call this yourself.
  Future<void> boot() => _booting ??= _boot();

  Future<void> _boot() async {
    await onLoad();
    if (_disposed) return;
    _loaded = true;
  }

  /// Largest frame time used, in seconds. Stops big jumps after a pause.
  static const double maxDelta = 0.05;

  double _timeScale = 1.0;

  /// Game speed. 1 is normal, 0.5 is slow motion. Clamped to >= 0.0.
  double get timeScale => _timeScale;
  set timeScale(double v) => _timeScale = (v.isFinite && v > 0.0) ? v : 0.0;

  bool _paused = false;

  /// True while paused. The scene still draws, but nothing moves.
  bool get paused => _paused;

  /// Total game time in seconds, not counting pauses.
  double get time => _time;
  double _time = 0.0;

  void pause() => _paused = true;
  void resume() => _paused = false;

  /// Called by the game widget every frame.
  void tick(double deltaSeconds) {
    if (!_loaded || _disposed || !deltaSeconds.isFinite) return;
    profiler.frame(deltaSeconds);
    if (_paused) return;
    final dt = Mathf.clamp(deltaSeconds, 0.0, maxDelta) * _timeScale;
    _time += dt;
    keyboardSource.poll(rawInput);
    input.update(rawInput);
    tweens.update(dt);
    coroutines.update(dt);
    onUpdate(dt);
    fixedStepper.advance(dt, (step) {
      onFixedUpdate(step);
      scene.fixedUpdate(step);
    });
    scene.update(dt);
    scene.lateUpdate(dt);
    onPostUpdate(dt);
  }

  /// Called by the game widget to draw.
  void render(ui.Canvas canvas, ui.Size size) {
    if (!_loaded || _disposed || size.isEmpty) return;
    final cam = camera ?? scene.findComponent<Camera>();
    if (cam == null) {
      final c = scene.clearColor;
      canvas.drawRect(
        ui.Offset.zero & size,
        ui.Paint()
          ..color = ui.Color.fromARGB(
            255,
            (c.x * 255).round().clamp(0, 255),
            (c.y * 255).round().clamp(0, 255),
            (c.z * 255).round().clamp(0, 255),
          ),
      );
      return;
    }
    profiler.begin('render');
    final frame = RenderFrame.build(scene, cam, size.width / size.height);
    lastStats = frame.stats;
    backend.render(frame, canvas, size);
    profiler.end('render');
  }

  /// Called by the game widget when it is disposed.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _loaded = false;
    onRemove();
    coroutines.stopAll();
    tweens.cancelAll();
    scene.clear();
    backend.dispose();
    overlays.dispose();
  }
}
