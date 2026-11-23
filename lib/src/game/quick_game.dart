import 'tej3d_game.dart';

/// Concrete [Tej3DGame] implementation with inline callbacks so developers can
/// create a playable 3D game in a few lines without subclassing boilerplate.
class QuickGame extends Tej3DGame {
  QuickGame({
    this.onSetup,
    this.onTick,
    super.backend,
  });

  final Future<void> Function(QuickGame game)? onSetup;
  final void Function(QuickGame game, double dt)? onTick;

  @override
  Future<void> onLoad() async {
    await onSetup?.call(this);
  }

  @override
  void onUpdate(double dt) {
    onTick?.call(this, dt);
  }
}
