import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'tej3d_game.dart';

/// Builds an overlay widget for a game.
typedef Tej3DOverlayBuilder<T extends Tej3DGame> =
    Widget Function(BuildContext context, T game);

/// Shows a [Tej3DGame] in a Flutter app. Like `GameWidget` in Flame.
///
/// ```dart
/// Tej3DGameWidget<MyGame>(
///   game: MyGame(),
///   overlayBuilderMap: {
///     'hud': (context, game) => MyHud(game),
///   },
///   initialActiveOverlays: const ['hud'],
/// )
/// ```
class Tej3DGameWidget<T extends Tej3DGame> extends StatefulWidget {
  const Tej3DGameWidget({
    super.key,
    required this.game,
    Map<String, Tej3DOverlayBuilder<T>>? overlayBuilderMap,
    this.initialActiveOverlays = const [],
    this.loadingBuilder,
    this.errorBuilder,
  }) : overlayBuilderMap = overlayBuilderMap ?? const <String, Never>{};

  final T game;

  /// Overlay name to builder.
  final Map<String, Tej3DOverlayBuilder<T>> overlayBuilderMap;

  /// Overlays shown from the start.
  final List<String> initialActiveOverlays;

  /// Shown while the game loads.
  final WidgetBuilder? loadingBuilder;

  /// Shown if loading fails.
  final Widget Function(BuildContext context, Object error)? errorBuilder;

  @override
  State<Tej3DGameWidget<T>> createState() => _Tej3DGameWidgetState<T>();
}

class _Tej3DGameWidgetState<T extends Tej3DGame>
    extends State<Tej3DGameWidget<T>>
    with SingleTickerProviderStateMixin {
  Object? _error;
  bool _ready = false;
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _bootGame(widget.game);
  }

  void _bootGame(T game) {
    for (final name in widget.initialActiveOverlays) {
      game.overlays.add(name);
    }
    game.boot().then((_) {
      if (!mounted || widget.game != game) return;
      setState(() => _ready = true);
      if (!_ticker.isActive) {
        _last = Duration.zero;
        _ticker.start();
      }
    }).catchError((Object e) {
      if (mounted && widget.game == game) setState(() => _error = e);
    });
  }

  @override
  void didUpdateWidget(covariant Tej3DGameWidget<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.game != widget.game) {
      if (_ticker.isActive) _ticker.stop();
      oldWidget.game.dispose();
      _error = null;
      _ready = false;
      _last = Duration.zero;
      _bootGame(widget.game);
    }
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1000000.0;
    _last = elapsed;
    widget.game.tick(dt);
    _frame.value++;
  }

  @override
  void dispose() {
    _ticker.dispose();
    widget.game.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    if (_error != null) {
      return widget.errorBuilder?.call(context, _error!) ??
          Center(child: Text('Game failed to load:\n$_error'));
    }
    if (!_ready) {
      return widget.loadingBuilder?.call(context) ??
          const Center(child: SizedBox(width: 24, height: 24));
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            painter: _GamePainter(game, _frame),
            size: Size.infinite,
          ),
        ),
        ListenableBuilder(
          listenable: game.overlays,
          builder: (context, _) {
            return Stack(
              fit: StackFit.expand,
              children: [
                for (final name in game.overlays.names)
                  if (widget.overlayBuilderMap[name] case final builder?)
                    builder(context, game),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _GamePainter extends CustomPainter {
  _GamePainter(this.game, Listenable repaint) : super(repaint: repaint);

  final Tej3DGame game;

  @override
  void paint(Canvas canvas, Size size) => game.render(canvas, size);

  @override
  bool shouldRepaint(covariant _GamePainter oldDelegate) => true;
}
