// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../adapters/presenters/top_down_snapshot.dart';

/// Screen-space star bloom for the flutter_scene backend: a hot white core
/// blooming out to a warm falloff, added over the rendered 3D sun.
///
/// The scene backend draws the star as a bare [UnlitMaterial] sphere, and
/// flutter_scene exposes no post-process pass (no render-to-texture, so no HDR
/// threshold + blur + composite). A real bloom is therefore off the table; this
/// is the same trick [TopDownPainter._starGlow] already uses on the software
/// path — an additive radial gradient at the star's projected position — so the
/// two backends read alike.
///
/// Positions come from the SAME [TopDownSnapshot] the HUD overlay uses, whose
/// `x`/`y` are screen px relative to centre with +y up (see
/// `TopDownSnapshotPresenter.proj`). Drawing in that space (outside
/// [SceneRenderView]'s `Transform.flip`) means the bloom lands exactly where the
/// name labels do.
class SceneStarBloomPainter extends CustomPainter {
  SceneStarBloomPainter(this.snapshot);

  final TopDownSnapshot snapshot;

  /// Bloom radius as a multiple of the star's projected disc radius.
  static double scale = 9.0;

  /// Floor on the bloom radius, px. The sun is a ~0.5 deg disc from any inner
  /// planet — a few px across — so a pure multiple of [scale] would vanish.
  /// This keeps it reading as glare at any distance.
  static double minPx = 70.0;

  /// Ceiling, as a fraction of the viewport's min side. Stops the gradient from
  /// swallowing the frame when the camera is close enough for the disc to be
  /// large on its own.
  static double maxViewportFraction = 0.9;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    for (final b in snapshot.bodies) {
      if (!b.isStar) continue;
      final vis = _visibility(b);
      if (vis <= 0.001) continue;
      final c = centre + Offset(b.x, -b.y);
      final cap = math.min(size.width, size.height) * maxViewportFraction;
      final r = math.min(math.max(b.radiusPx * scale, minPx), cap);
      if (r <= 0) continue;
      canvas.drawCircle(
        c,
        r,
        Paint()
          // Additive: brightens whatever is behind it, and stacking the core
          // over the already-white sun sphere is what blows it out.
          ..blendMode = BlendMode.plus
          ..shader = RadialGradient(
            colors: [
              _fade(0xFFFFFFFF, vis), // blown-out white core
              _fade(0xFFFFFDF2, vis),
              _fade(0xCCFFF3C8, vis), // warm inner falloff
              _fade(0x66FFD98A, vis),
              _fade(0x1AFFB347, vis), // faint outer
              _fade(0x00FF8C1A, vis), // transparent
            ],
            stops: const [0.0, 0.08, 0.20, 0.42, 0.72, 1.0],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }
  }

  /// Scales a packed ARGB stop's alpha by [vis]. Under [BlendMode.plus] the
  /// shader's alpha sets how much light the stop adds, so this dims the whole
  /// bloom as the star slips behind an occluder.
  static Color _fade(int argb, double vis) {
    final a = ((argb >> 24) & 0xFF) * vis.clamp(0.0, 1.0);
    return Color((argb & 0x00FFFFFF) | (a.round().clamp(0, 255) << 24));
  }

  /// How much of the star the camera can actually see: 1 = clear, 0 = fully
  /// behind another body. The bloom is drawn OVER the finished 3D frame, so
  /// without this the sun would glare straight through an eclipsing planet.
  ///
  /// Ray-sphere against every non-star body: cast from the camera (the origin
  /// of the snapshot's `worldRel` frame) toward the star, and reject occluders
  /// that sit behind the camera or beyond the star. Fades across one body
  /// radius at the limb so the cutoff is not a pop.
  double _visibility(BodyView star) {
    final toStar = star.worldRel;
    final starDist = toStar.length;
    if (starDist <= 0) return 1.0;
    final dir = toStar / starDist;
    var vis = 1.0;
    for (final o in snapshot.bodies) {
      if (identical(o, star) || o.isStar || o.radius <= 0) continue;
      final oc = o.worldRel;
      final along = oc.dot(dir);
      // Behind the camera, or further than the star: cannot occlude it.
      if (along <= 0 || along >= starDist) continue;
      final perp = math.sqrt(math.max(oc.lengthSquared - along * along, 0.0));
      // Fade over the outer 25% of the disc: fully blocked inside 0.75r,
      // clear past the limb.
      final t = ((perp - o.radius * 0.75) / (o.radius * 0.25)).clamp(0.0, 1.0);
      vis = math.min(vis, t);
      if (vis <= 0.001) return 0.0;
    }
    return vis;
  }

  @override
  bool shouldRepaint(covariant SceneStarBloomPainter old) =>
      !identical(old.snapshot, snapshot);
}
