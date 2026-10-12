// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Silo salvos on the HUD (docs/plans/combat.md §7O): where each will come
/// down — a ring the size of its 30 m scatter, crosshairs and its countdown —
/// and, while a strike is being aimed, the arc it would fly. The salvo's own
/// trajectory line is the craft line, drawn by the scene.
library;

import 'package:flutter/material.dart';

import '../app_theme.dart';

/// One impact point as drawn.
class MissileMark {
  const MissileMark(this.at, this.radiusPx, this.label, {this.preview = false, this.craft = false});
  final Offset at;
  final double radiusPx;
  final String label;

  /// Aimed, not yet launched.
  final bool preview;

  /// The salvo in the air, not where it lands: a pip, not a ring.
  final bool craft;
}

class MissileOverlayPainter extends CustomPainter {
  MissileOverlayPainter(this.marks, this.arcs);

  final List<MissileMark> marks;

  /// Screen polylines: the arcs a strike being aimed would fly.
  final List<List<Offset>> arcs;

  @override
  void paint(Canvas canvas, Size size) {
    for (final a in arcs) {
      final path = Path()..moveTo(a.first.dx, a.first.dy);
      for (final p in a.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = AppTheme.warn.withValues(alpha: 0.85));
    }
    for (final m in marks) {
      if (m.craft) {
        canvas
          ..drawCircle(m.at, m.radiusPx, Paint()..color = AppTheme.warn)
          ..drawCircle(
              m.at,
              m.radiusPx + 3,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.5
                ..color = AppTheme.danger);
        final t = TextPainter(
          textDirection: TextDirection.ltr,
          text: TextSpan(
              text: m.label,
              style: const TextStyle(
                  color: AppTheme.warn,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  shadows: [Shadow(color: Color(0xCC000000), blurRadius: 3)])),
        )..layout();
        t.paint(canvas, m.at + Offset(m.radiusPx + 6, -t.height / 2));
        continue;
      }
      final c = m.preview ? AppTheme.warn : AppTheme.danger;
      final r = m.radiusPx.clamp(8.0, 400.0);
      canvas.drawCircle(m.at, r, Paint()..color = c.withValues(alpha: 0.12));
      canvas.drawCircle(
          m.at,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = c);
      final cross = Paint()
        ..strokeWidth = 1.5
        ..color = c;
      canvas
        ..drawLine(m.at - Offset(r + 6, 0), m.at - Offset(r - 4, 0), cross)
        ..drawLine(m.at + Offset(r - 4, 0), m.at + Offset(r + 6, 0), cross)
        ..drawLine(m.at - Offset(0, r + 6), m.at - Offset(0, r - 4), cross)
        ..drawLine(m.at + Offset(0, r - 4), m.at + Offset(0, r + 6), cross);
      final text = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: m.label,
          style: TextStyle(
            color: c,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            shadows: const [Shadow(color: Color(0xCC000000), blurRadius: 3)],
          ),
        ),
      )..layout();
      text.paint(canvas, m.at + Offset(r + 8, -text.height / 2));
    }
  }

  @override
  bool shouldRepaint(MissileOverlayPainter old) => true;
}
