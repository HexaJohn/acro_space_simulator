// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../adapters/presenters/top_down_snapshot.dart';
import '../flutter/debug_layers.dart';

/// Painter-parity HUD for the flutter_scene backend: the text readouts and
/// body/vessel name labels that [TopDownPainter] draws in-canvas (top-left
/// telemetry block, camera line, attribution, floating labels). Reuses the
/// SAME [TopDownSnapshot] the presenter already builds every frame, so the
/// two backends can never disagree about what the HUD says.
///
/// World rendering stays in the 3D scene — this draws only text plus the
/// screen-space debug overlays (the SOI rings) that have no 3D-scene node.
class SceneHudOverlayPainter extends CustomPainter {
  SceneHudOverlayPainter(this.snapshot, this.view,
      {this.layers = const DebugLayers()});

  final TopDownSnapshot snapshot;
  final SceneCamera view;
  final DebugLayers layers;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);

    // Sphere-of-influence circles (debug overlay) — parity with
    // [TopDownPainter]: a dashed ring at each body's SOI radius, same
    // sub-pixel / absurd-radius skip bounds so the two backends agree.
    if (layers.showSoi) {
      for (final b in snapshot.bodies) {
        final rPx = b.soiRadiusPx;
        if (rPx < 6 || rPx > 4000) continue;
        final c = centre + Offset(b.x, -b.y);
        if (!c.dx.isFinite || !c.dy.isFinite) continue;
        final onScreen = c.dx + rPx > -16 &&
            c.dx - rPx < size.width + 16 &&
            c.dy + rPx > -16 &&
            c.dy - rPx < size.height + 16;
        if (!onScreen) continue;
        _dashedCircle(canvas, c, rPx, const Color(0x55B0E0A0));
      }
    }

    // Floating name labels at the projected screen positions (screen px are
    // centre-relative with +y up; flip y like the painter does).
    for (final b in snapshot.bodies) {
      if (!b.showLabel) continue;
      // Moon labels only near their neighbourhood. Distance, NOT apparent
      // size: moons are tiny (Mimas is sub-2 px even from Saturn orbit),
      // but moon systems span <= ~4e9 m while interplanetary gaps start at
      // ~6e10 — a camera within 1e10 m is "visiting" that system.
      if (b.isMoon && b.worldRel.length > 1e10) continue;
      // Anchor: 10 px right of the sphere's edge, atmosphere included
      // (the scene shell extends ~6% past the surface), vertically
      // centred on the body.
      final edgePx =
          b.hasAtmosphere ? b.radiusPx * 1.06 : b.radiusPx;
      _label(canvas, b.name,
          centre + Offset(b.x + edgePx + 10, -b.y - 5),
          const Color(0xFF9FB4CC));
    }
    for (final v in snapshot.vessels) {
      _label(canvas, v.name, centre + Offset(v.x + 10, -v.y - 4),
          const Color(0xFF9FE0B0));
    }

    // Top-left telemetry block (mirrors TopDownPainter._hud).
    final az = (view.azimuth * 180 / math.pi).toStringAsFixed(0);
    final el = (view.elevation * 180 / math.pi).toStringAsFixed(0);
    _label(canvas, 'cam az$az el$el', const Offset(8, 8),
        const Color(0xFF6E8299));
    var y = 26.0;
    for (final line in snapshot.hud.lines) {
      _label(canvas, line, Offset(8, y), const Color(0xFFB9C9DC));
      y += 14;
    }

    _label(
      canvas,
      'Body maps: solarsystemscope.com (CC-BY 4.0)',
      Offset(size.width - 250, size.height - 16),
      const Color(0xFF4A5A6A),
    );
  }

  void _label(Canvas canvas, String text, Offset at, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  /// A dashed circle (segments around the circumference) for SOI boundaries —
  /// same look as [TopDownPainter._dashedCircle].
  void _dashedCircle(Canvas canvas, Offset c, double r, Color color) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    const dashes = 64;
    for (var i = 0; i < dashes; i += 2) {
      final a0 = (i / dashes) * 2 * math.pi;
      final a1 = ((i + 1) / dashes) * 2 * math.pi;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        a0,
        a1 - a0,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant SceneHudOverlayPainter old) =>
      old.snapshot != snapshot || old.view != view || old.layers != layers;
}
