import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../adapters/presenters/atmosphere_halo.dart';
import '../../adapters/presenters/body_shading.dart';
import '../../adapters/presenters/top_down_snapshot.dart';
import '../../domain/shared/vector3.dart';

/// Renders a [TopDownSnapshot] in a top-down XY view with primitive shapes.
/// No 3D rendering this pass — bodies are circles, vessels are triangles, the
/// vessel's orbit-plane heading is the triangle's point.
///
/// Coordinates arrive as metres relative to the camera focus (already small),
/// so projection is just: screen = centre + (worldXY / metresPerPixel), with Y
/// flipped so +Y is up on screen.
class TopDownPainter extends CustomPainter {
  final TopDownSnapshot snapshot;
  TopDownPainter(this.snapshot);

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final mpp = snapshot.metresPerPixel;

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF05070D),
    );

    Offset project(double xMetres, double yMetres) => Offset(
          centre.dx + xMetres / mpp,
          centre.dy - yMetres / mpp, // flip Y: up on screen
        );

    // Bodies: lit disc (ultra-basic shading) + atmosphere halo.
    const shading = BodyShading();
    for (final b in snapshot.bodies) {
      final c = project(b.x, b.y);
      final rPx = math.max(2.0, b.radius / mpp);
      final base = b.isStar ? const Color(0xFFFFD66B) : const Color(0xFF4A90D9);

      if (b.isStar || rPx < 6) {
        // Tiny or self-luminous: flat fill (shading not worth it).
        canvas.drawCircle(c, rPx, Paint()..color = base);
      } else {
        // Atmosphere halo first (drawn under the disc edge).
        if (b.hasAtmosphere) {
          final halo = AtmosphereHalo(bodyRadiusPx: rPx, thicknessFraction: 0.18);
          for (var r = halo.outerRadius; r > halo.innerRadius; r -= 1.5) {
            final a = halo.alphaAt(r).clamp(0.0, 1.0);
            canvas.drawCircle(
              c,
              r,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.5
                ..color = const Color(0xFF6FA8FF).withValues(alpha: a * 0.5),
            );
          }
        }
        // Shaded disc: sample brightness over a coarse grid, draw lit cells.
        final sun = Vector3(b.sunX, b.sunY, 0);
        _drawShadedDisc(canvas, c, rPx, base, sun, shading);
      }

      _label(canvas, b.name, c + Offset(rPx + 4, -6), const Color(0xFF9FB4CC));
    }

    // Predicted orbit paths (faint polylines), drawn under the ships.
    for (final v in snapshot.vessels) {
      if (v.path.length < 2) continue;
      final path = Path();
      final first = project(v.path.first.x, v.path.first.y);
      path.moveTo(first.dx, first.dy);
      for (final pt in v.path.skip(1)) {
        final o = project(pt.x, pt.y);
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = (v.onRails ? const Color(0xFF7FE0A0) : const Color(0xFFFF8C66))
              .withValues(alpha: 0.35),
      );
    }

    // Vessels: small triangle pointing along heading.
    for (final v in snapshot.vessels) {
      final c = project(v.x, v.y);
      _drawShip(canvas, c, v.headingRad, v.onRails);
      _label(canvas, v.name, c + const Offset(8, -4),
          v.onRails ? const Color(0xFF7FE0A0) : const Color(0xFFFF8C66));
    }

    _hud(canvas, size);
  }

  void _drawShip(Canvas canvas, Offset c, double heading, bool onRails) {
    const len = 9.0;
    const wid = 5.0;
    // Heading: +X is right, but screen Y is flipped, so negate the angle.
    final a = -heading;
    final cosA = math.cos(a), sinA = math.sin(a);
    Offset rot(double x, double y) =>
        c + Offset(x * cosA - y * sinA, x * sinA + y * cosA);

    final path = Path()
      ..moveTo(rot(len, 0).dx, rot(len, 0).dy)
      ..lineTo(rot(-len * 0.6, wid).dx, rot(-len * 0.6, wid).dy)
      ..lineTo(rot(-len * 0.6, -wid).dx, rot(-len * 0.6, -wid).dy)
      ..close();

    canvas.drawPath(
      path,
      Paint()..color = onRails ? const Color(0xFF7FE0A0) : const Color(0xFFFF8C66),
    );
  }

  /// Ultra-basic shaded disc: clip to the body circle, fill dark, then paint a
  /// coarse grid of cells tinted by Lambert brightness (lit toward the sun).
  void _drawShadedDisc(Canvas canvas, Offset c, double rPx, Color base,
      Vector3 sun, BodyShading shading) {
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: rPx)));
    // Night side.
    canvas.drawCircle(c, rPx, Paint()..color = _scale(base, 0.12));

    final step = math.max(2.0, rPx / 10); // ~10 cells across
    for (var py = -rPx; py <= rPx; py += step) {
      for (var px = -rPx; px <= rPx; px += step) {
        final dx = px / rPx;
        final dy = py / rPx;
        if (dx * dx + dy * dy > 1) continue;
        // Screen Y is flipped vs world; sun is in world XY, so flip dy.
        final bright = shading.brightnessAt(dx, -dy, sun);
        if (bright <= 0.02) continue;
        canvas.drawRect(
          Rect.fromLTWH(c.dx + px, c.dy + py, step + 0.6, step + 0.6),
          Paint()..color = _scale(base, 0.15 + 0.85 * bright),
        );
      }
    }
    canvas.restore();
  }

  Color _scale(Color base, double f) => Color.fromARGB(
        255,
        (base.r * 255 * f).clamp(0, 255).round(),
        (base.g * 255 * f).clamp(0, 255).round(),
        (base.b * 255 * f).clamp(0, 255).round(),
      );

  void _label(Canvas canvas, String text, Offset at, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  void _hud(Canvas canvas, Size size) {
    final mpp = snapshot.metresPerPixel;
    final scaleKm = (mpp * 100 / 1000).toStringAsFixed(1);
    _label(canvas, 'top-down XY  |  100px = $scaleKm km',
        const Offset(8, 8), const Color(0xFF6E8299));

    // Readout lines from the presenter's HUD view.
    var y = 26.0;
    for (final line in snapshot.hud.lines) {
      _label(canvas, line, Offset(8, y), const Color(0xFFB9C9DC));
      y += 14;
    }
  }

  @override
  bool shouldRepaint(covariant TopDownPainter old) =>
      old.snapshot != snapshot;
}
