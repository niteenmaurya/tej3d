import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import '../math/vec.dart' hide Matrix4; // Flutter has its own Matrix4

import 'minimap_projection.dart';

export 'minimap_projection.dart';

/// One dot on the minimap.
class MinimapMarker {
  const MinimapMarker(this.position, this.color, {this.size = 4.0});
  final Vector3 position;
  final Color color;
  final double size;
}

/// A round minimap widget. Repaints when [repaint] notifies (use the game
/// loop notifier you already have, or a `ValueNotifier` you bump each frame).
class Minimap extends StatelessWidget {
  const Minimap({
    super.key,
    required this.projection,
    required this.center,
    required this.heading,
    required this.markers,
    this.outlinePoints,
    this.repaint,
    this.diameter = 140,
  });

  final MinimapProjection projection;
  final Vector3 Function() center;
  final double Function() heading;
  final List<MinimapMarker> Function() markers;
  /// Optional closed loop to draw as an outline (a border, a path).
  final List<Vector3>? outlinePoints;
  final Listenable? repaint;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: diameter,
      height: diameter,
      child: CustomPaint(
        painter: _MinimapPainter(this),
      ),
    );
  }
}

class _MinimapPainter extends CustomPainter {
  _MinimapPainter(this.map) : super(repaint: map.repaint);

  final Minimap map;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);
    canvas.drawCircle(c, r, Paint()..color = const Color(0x99000000));
    canvas.drawCircle(
      c,
      r - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xCCFFFFFF),
    );
    final center = map.center();
    final heading = map.heading();
    final loop = map.outlinePoints;
    if (loop != null && loop.length > 2) {
      canvas.save();
      canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r - 2)));
      final path = Path();
      for (var i = 0; i < loop.length; i++) {
        final (x, y) = map.projection.project(loop[i], center, heading);
        final o = Offset(r + x * r, r + y * r);
        if (i == 0) {
          path.moveTo(o.dx, o.dy);
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeJoin = StrokeJoin.round
          ..color = const Color(0x88FFFFFF),
      );
      canvas.restore();
    }
    for (final m in map.markers()) {
      final (x, y) = map.projection.project(m.position, center, heading);
      final len = math.sqrt(x * x + y * y);
      // Dots outside the map stick to the edge.
      final k = len > 0.95 ? 0.95 / len : 1.0;
      canvas.drawCircle(
        Offset(r + x * k * r, r + y * k * r),
        m.size,
        Paint()..color = m.color,
      );
    }
    // The player is always in the middle.
    canvas.drawCircle(c, 5, Paint()..color = const Color(0xFFFFFFFF));
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter old) => true;
}
