// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The known colonies as HUD markers (`adapters/presenters/colony_markers.dart`):
/// a diamond on each, its name and distance beside it, coloured by what the
/// colony is to the player. Laid over the scene, not depth-tested — the
/// presenter has already hidden what a body stands in front of.
library;

import 'package:flutter/material.dart';

import '../../../adapters/presenters/colony_markers.dart';
import 'app_theme.dart';

/// A marker's colour by what its colony is to the player.
Color colonyMarkerColour(ColonyMarkerStatus s) => switch (s) {
      ColonyMarkerStatus.yours => AppTheme.accent,
      ColonyMarkerStatus.unrest => AppTheme.warn,
      ColonyMarkerStatus.occupied => const Color(0xFFFFC266),
      ColonyMarkerStatus.independent => AppTheme.danger,
      ColonyMarkerStatus.battle => AppTheme.danger,
    };

String? _statusWord(ColonyMarkerStatus s) => switch (s) {
      ColonyMarkerStatus.yours => null,
      ColonyMarkerStatus.unrest => 'unrest',
      ColonyMarkerStatus.occupied => 'occupied',
      ColonyMarkerStatus.independent => 'independent',
      ColonyMarkerStatus.battle => 'battle',
    };

class ColonyMarkersPainter extends CustomPainter {
  ColonyMarkersPainter(this.marks);

  /// Nearest first: the nearest keep their labels where labels would collide.
  final List<ColonyMark> marks;

  static const double _half = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final labels = <Rect>[];
    for (final m in marks) {
      final at = Offset(size.width / 2 + m.x, size.height / 2 - m.y);
      if (at.dx < -40 || at.dy < -40 || at.dx > size.width + 40 || at.dy > size.height + 40) continue;
      final c = colonyMarkerColour(m.status);
      final diamond = Path()
        ..moveTo(at.dx, at.dy - _half)
        ..lineTo(at.dx + _half, at.dy)
        ..lineTo(at.dx, at.dy + _half)
        ..lineTo(at.dx - _half, at.dy)
        ..close();
      canvas.drawPath(diamond, Paint()..color = c.withValues(alpha: 0.25));
      canvas.drawPath(
          diamond,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..color = c);
      canvas.drawCircle(at, 1.6, Paint()..color = c);

      final word = _statusWord(m.status);
      final text = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(children: [
          TextSpan(
            text: m.name,
            style: TextStyle(
              color: c,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              shadows: const [Shadow(color: Color(0xCC000000), blurRadius: 3)],
            ),
          ),
          TextSpan(
            text: '\n${colonyMarkerDistance(m.distanceM)}${word == null ? '' : ' · $word'}',
            style: const TextStyle(
              color: AppTheme.textDim,
              fontSize: 10,
              shadows: [Shadow(color: Color(0xCC000000), blurRadius: 3)],
            ),
          ),
        ]),
      )..layout();
      final box = Rect.fromLTWH(at.dx + _half + 4, at.dy - text.height / 2, text.width, text.height);
      if (labels.any((r) => r.overlaps(box))) continue;
      labels.add(box);
      text.paint(canvas, box.topLeft);
    }
  }

  @override
  bool shouldRepaint(ColonyMarkersPainter old) => true;
}
