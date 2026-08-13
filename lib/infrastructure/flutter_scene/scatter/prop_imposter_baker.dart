// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;

import '../../../domain/scatter/prop_imposter.dart';

/// Paints a [PropImposter] into a texture for the distant billboard LOD.
///
/// The alternative — rendering the real mesh to an offscreen target and reading
/// it back — needs a second render pass, a GPU readback, and a fallback for the
/// web build. Painting is deterministic, runs anywhere `dart:ui` does, and is
/// accurate enough precisely BECAUSE the props are procedural: the domain hands
/// us the actual canopy masses and limb positions the mesh was grown from (see
/// [ImposterBuilder]), so the painted silhouette is the mesh's silhouette
/// rather than an artist's impression of it.
class PropImposterBaker {
  PropImposterBaker._();

  /// Texture side in texels. An imposter takes over below ~34 px of screen
  /// height ([PropLodSet.billboardBelowPx]), so 128 is already several times
  /// the resolution it is ever sampled at; the surplus is what keeps the mip
  /// chain clean as it recedes further.
  static const int size = 128;

  /// Paint [imposter] and upload it. Returns null if the description is empty
  /// or the upload fails — callers fall back to simply not drawing the
  /// billboard LOD, which is far better than a white square.
  static Future<Object?> bake(PropImposter imposter) async {
    if (imposter.isEmpty) return null;
    try {
      final image = await _paint(imposter);
      // Both awaits matter: gpuTextureFromImage is asynchronous, so returning
      // its Future unawaited handed the material a Future where it wanted a
      // texture, and disposing the image before that Future had read it pulled
      // the pixels out from under the upload.
      final tex = await fs.gpuTextureFromImage(image);
      image.dispose();
      return tex as Object;
    } catch (_) {
      return null;
    }
  }

  static Future<ui.Image> _paint(PropImposter imposter) {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // Card space -> texel space. The card is widthM x heightM but the texture
    // is square, so anything measured as a fraction of the card WIDTH (every
    // radius and stroke width in PropImposter) becomes an ELLIPSE in texel
    // space. Skipping this stretched every canopy vertically on tall props.
    final aspect = imposter.widthM / math.max(imposter.heightM, 1e-6);
    double px(double x) => (x + 0.5) * size;
    double py(double y) => (1.0 - y) * size;
    double rx(double r) => r * size;
    double ry(double r) => r * size * aspect;

    // Limbs first: canopy masses paint over them, which is the correct depth
    // order for anything with leaves and harmless for anything without.
    for (final s in imposter.strokes) {
      _stroke(canvas, s, px, py, rx);
    }
    for (var i = 0; i < imposter.blobs.length; i++) {
      _blob(canvas, imposter.blobs[i], i, px, py, rx, ry);
    }

    return recorder.endRecording().toImage(size, size);
  }

  /// A limb: a quad tapering from one end width to the other.
  static void _stroke(
    ui.Canvas canvas,
    ImposterStroke s,
    double Function(double) px,
    double Function(double) py,
    double Function(double) rx,
  ) {
    final x0 = px(s.x0), y0 = py(s.y0), x1 = px(s.x1), y1 = py(s.y1);
    final dx = x1 - x0, dy = y1 - y0;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 0.5) return;
    // Perpendicular in texel space. Widths are a fraction of card width, so
    // they scale by rx on both axes — a limb is a physical thickness, not a
    // card-space one, and stretching it by the aspect would fatten trunks.
    final nx = -dy / len, ny = dx / len;
    // Sub-texel limbs vanish under antialiasing; a distant tree with no visible
    // trunk reads as a floating bush, so keep every limb at least a texel wide.
    final h0 = math.max(rx(s.width0) * 0.5, 0.5);
    final h1 = math.max(rx(s.width1) * 0.5, 0.5);
    final path = ui.Path()
      ..moveTo(x0 + nx * h0, y0 + ny * h0)
      ..lineTo(x1 + nx * h1, y1 + ny * h1)
      ..lineTo(x1 - nx * h1, y1 - ny * h1)
      ..lineTo(x0 - nx * h0, y0 - ny * h0)
      ..close();
    canvas.drawPath(path, ui.Paint()..color = _inkColor(s.ink));
  }

  /// A canopy or stone mass.
  ///
  /// Drawn as a cluster of overlapping lobes rather than one circle: the
  /// billboard is composited with an alpha test, so a single circle would give
  /// the tree a perfectly round hard edge and read as a lollipop. The lobes are
  /// hashed off the blob's index, so the outline is irregular but stable.
  static void _blob(
    ui.Canvas canvas,
    ImposterBlob blob,
    int index,
    double Function(double) px,
    double Function(double) py,
    double Function(double) rx,
    double Function(double) ry,
  ) {
    final cx = px(blob.x), cy = py(blob.y);
    final baseRx = rx(blob.radius), baseRy = ry(blob.radius);
    if (baseRx < 0.4 || baseRy < 0.4) return;

    final colour = _inkColor(blob.ink);
    final shadow = _inkColor(
      blob.ink == ImposterInk.rock ? ImposterInk.rock : ImposterInk.foliageShadow,
    );

    const lobes = 7;
    for (var i = 0; i < lobes; i++) {
      final h1 = _hash(index, i, 11), h2 = _hash(index, i, 12);
      final h3 = _hash(index, i, 13);
      final ang = 2 * math.pi * (i / lobes) + (h1 - 0.5) * 0.7;
      final off = (i == 0 ? 0.0 : 0.34 + 0.30 * h2);
      final lr = (i == 0 ? 1.0 : 0.44 + 0.34 * h3);
      final ox = cx + math.cos(ang) * baseRx * off;
      final oy = cy - math.sin(ang) * baseRy * off;
      // Lower lobes sit deeper in the canopy and catch less light.
      final lit = 0.5 + 0.5 * math.sin(ang);
      canvas.drawOval(
        ui.Rect.fromCenter(
          center: ui.Offset(ox, oy),
          width: baseRx * 2 * lr,
          height: baseRy * 2 * lr,
        ),
        ui.Paint()..color = ui.Color.lerp(shadow, colour, lit)!,
      );
    }
  }

  /// Flat colours matching the average of the procedural textures the meshes
  /// wear, so a prop does not change hue as it crosses into its imposter.
  static ui.Color _inkColor(ImposterInk ink) => switch (ink) {
        ImposterInk.bark => const ui.Color(0xFF6E5F4F),
        ImposterInk.foliage => const ui.Color(0xFF44703A),
        ImposterInk.foliageShadow => const ui.Color(0xFF223A1E),
        ImposterInk.rock => const ui.Color(0xFF6B6763),
      };

  static double _hash(int a, int b, int seed) {
    var h = a * 374761393 + b * 668265263 + seed * 2246822519;
    h = (h ^ (h >> 13)) * 1274126177;
    h ^= h >> 16;
    return (h & 0x7fffffff) / 0x7fffffff;
  }
}
