// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import '../../../domain/scatter/foliage_atlas.dart';

/// The PIXELS of the scattered props' textures: bark, stone, and the alpha-cut
/// foliage atlas.
///
/// Split from [ScatterTextures] — which uploads them — purely so it can be
/// tested. The upload half must import flutter_gpu and therefore needs a live
/// GPU context, while this half is arithmetic over a byte array. The foliage
/// atlas is the highest-risk code in the whole scatter system (every leaf,
/// needle and blade in the world is a shape that exists ONLY in its alpha
/// channel, and a subtly wrong mask is invisible in a triangle count but
/// glaring on screen), so being able to bake it in a plain unit test and write
/// it out as a PNG is worth the extra file.
class ScatterTextureBakes {
  ScatterTextureBakes._();

  // ---- Bark ---------------------------------------------------------------

  /// Vertical fissured bark. Tileable in both axes: the trunk tube's U wraps
  /// and its V repeats along the length.
  static Uint8List bark(int size) {
    final px = Uint8List(size * size * 4);
    for (var y = 0; y < size; y++) {
      final v = y / size;
      for (var x = 0; x < size; x++) {
        final u = x / size;
        // Fissures run ALONG the trunk, so the noise is stretched hard in v.
        final ridge = 1.0 -
            (2.0 * _fbm(u, v * 0.22, 41, octaves: 4, basePeriod: 10) - 1.0).abs();
        final crack = _smooth(0.62, 1.0, ridge);
        final grain = _fbm(u, v, 42, octaves: 3, basePeriod: 48);
        final patch = _fbm(u, v, 43, octaves: 3, basePeriod: 5);

        var k = 0.42 * (0.82 + 0.36 * patch) * (0.9 + 0.2 * grain);
        k *= 1.0 - 0.62 * crack; // dark fissures
        final i = (y * size + x) * 4;
        // Warm grey-brown; bark is far less saturated than intuition suggests,
        // and an over-brown trunk reads as plastic under a white sun.
        px[i] = _b(k * 1.06);
        px[i + 1] = _b(k * 0.92);
        px[i + 2] = _b(k * 0.78);
        px[i + 3] = 255;
      }
    }
    return px;
  }

  /// Mottled stone with darker pitting — the rock props' surface.
  static Uint8List stone(int size) {
    final px = Uint8List(size * size * 4);
    for (var y = 0; y < size; y++) {
      final v = y / size;
      for (var x = 0; x < size; x++) {
        final u = x / size;
        final broad = _fbm(u, v, 51, octaves: 5, basePeriod: 6);
        final grain = _fbm(u, v, 52, octaves: 3, basePeriod: 40);
        final pit = _noise(u, v, 56, 53);
        var k = 0.40 * (0.80 + 0.40 * broad) * (0.92 + 0.16 * grain);
        if (pit > 0.88) k *= 0.66;
        final i = (y * size + x) * 4;
        px[i] = _b(k * 1.02);
        px[i + 1] = _b(k * 1.0);
        px[i + 2] = _b(k * 0.96);
        px[i + 3] = 255;
      }
    }
    return px;
  }

  // ---- Foliage atlas ------------------------------------------------------

  /// Bake all four [FoliageCell]s into one RGBA texture.
  ///
  /// Every cell is drawn with a transparent MARGIN around its artwork. Without
  /// it a leaf clump would butt against the cell edge, and the atlas inset in
  /// [FoliageAtlas] plus bilinear filtering would clip the outermost leaves —
  /// leaving cards with suspiciously straight edges.
  static Uint8List foliageAtlas(int size) {
    final px = Uint8List(size * size * 4);
    final cellPx = size ~/ FoliageAtlas.grid;
    for (final cell in FoliageCell.values) {
      final ox = FoliageAtlas.columnOf(cell) * cellPx;
      final oy = FoliageAtlas.rowOf(cell) * cellPx;
      for (var y = 0; y < cellPx; y++) {
        for (var x = 0; x < cellPx; x++) {
          // Cell-local coords: u across, v DOWN from the top of the cell. The
          // card's v=0 edge is its top, matching MeshBuilder.card.
          final u = (x + 0.5) / cellPx;
          final v = (y + 0.5) / cellPx;
          final s = switch (cell) {
            FoliageCell.broadleaf => _broadleafSample(u, v),
            FoliageCell.needle => _needleSample(u, v),
            FoliageCell.frond => _frondSample(u, v),
            FoliageCell.blade => _bladeSample(u, v),
          };
          final i = ((oy + y) * size + (ox + x)) * 4;
          px[i] = _b(s.r);
          px[i + 1] = _b(s.g);
          px[i + 2] = _b(s.b);
          px[i + 3] = _b(s.a);
        }
      }
    }
    return px;
  }

  /// A clump of rounded leaves scattered over the cell.
  static _Rgba _broadleafSample(double u, double v) {
    // Leaf centres on a jittered lattice; a handful of overlapping ellipses is
    // all a cross-card needs to read as "mass of leaves".
    const lattice = 5;
    var cover = 0.0;
    var shade = 0.0;
    for (var gy = -1; gy <= lattice; gy++) {
      for (var gx = -1; gx <= lattice; gx++) {
        final h1 = _hash(gx, gy, 61), h2 = _hash(gx, gy, 62);
        final h3 = _hash(gx, gy, 63), h4 = _hash(gx, gy, 64);
        final cx = (gx + 0.15 + 0.7 * h1) / lattice;
        final cy = (gy + 0.15 + 0.7 * h2) / lattice;
        // Leaves shrink toward the cell edge so the clump has a soft outline
        // rather than a square one.
        final edge = _falloff(cx, cy);
        if (edge <= 0.0) continue;
        final rx = (0.055 + 0.055 * h3) * edge;
        final ry = rx * (1.25 + 0.6 * h4);
        // Rotate the ellipse so leaves are not all axis-aligned.
        final ang = h4 * math.pi;
        final dx = u - cx, dy = v - cy;
        final lx = dx * math.cos(ang) + dy * math.sin(ang);
        final ly = -dx * math.sin(ang) + dy * math.cos(ang);
        final d = math.sqrt((lx / rx) * (lx / rx) + (ly / ry) * (ly / ry));
        if (d < 1.0) {
          cover = 1.0;
          // Leaves lower in the cell sit deeper in the canopy: darken them so
          // the flat card carries some internal depth.
          shade = math.max(shade, (1.0 - d) * (0.35 + 0.65 * (1.0 - v)));
        }
      }
    }
    if (cover <= 0.0) return const _Rgba(0, 0, 0, 0);
    final k = 0.42 + 0.58 * shade;
    final tint = _fbm(u, v, 65, octaves: 2, basePeriod: 6);
    return _Rgba(
      (0.16 + 0.20 * tint) * k,
      (0.34 + 0.26 * tint) * k,
      (0.11 + 0.10 * tint) * k,
      1.0,
    );
  }

  /// A spray of fine needles radiating from the cell's bottom centre.
  static _Rgba _needleSample(double u, double v) {
    // Polar around the base of the card: needles are straight lines from the
    // stem, so an angular test is both exact and cheap.
    final dx = u - 0.5, dy = (1.0 - v) - 0.02;
    final r = math.sqrt(dx * dx + dy * dy);
    if (r < 0.02 || r > 0.52) return const _Rgba(0, 0, 0, 0);
    final ang = math.atan2(dx, dy); // 0 = straight up
    if (ang.abs() > 1.32) return const _Rgba(0, 0, 0, 0);
    const needles = 34;
    final slot = (ang / 1.32 * needles / 2).roundToDouble();
    final centre = slot / (needles / 2) * 1.32;
    final jitterLen = 0.30 + 0.22 * _hash(slot.toInt(), 0, 71);
    if (r > jitterLen) return const _Rgba(0, 0, 0, 0);
    // Needle half-width in radians, tapering to a point at the tip.
    final halfWidth = 0.020 * (1.0 - r / jitterLen) + 0.004;
    if ((ang - centre).abs() > halfWidth) return const _Rgba(0, 0, 0, 0);
    final k = 0.55 + 0.45 * (1.0 - r / jitterLen);
    return _Rgba(0.13 * k, 0.27 * k, 0.15 * k, 1.0);
  }

  /// A pinnate frond running the LENGTH of the cell: a central rachis with
  /// leaflets combing off it. Mapped onto a ribbon, so v runs tip-to-base.
  static _Rgba _frondSample(double u, double v) {
    final along = v; // 0 at the ribbon's v0 edge
    final across = u - 0.5;
    // Rachis: a thin tapering spine down the middle.
    final rachisHalf = 0.022 * (1.0 - 0.7 * along) + 0.004;
    final onRachis = across.abs() < rachisHalf;
    // Leaflet envelope: widest in the middle, pointed at both ends.
    final envelope = math.sin(math.pi * math.pow(along, 0.8).toDouble());
    final reach = 0.46 * envelope;
    if (!onRachis && (reach <= 0.01 || across.abs() > reach)) {
      return const _Rgba(0, 0, 0, 0);
    }
    if (!onRachis) {
      // Comb the leaflets: alternate slots along the rachis, swept toward the
      // tip so the frond reads as growing rather than as a fish skeleton.
      const leaflets = 26;
      final slot = (along * leaflets).floor();
      final phase = along * leaflets - slot;
      final sweep = 0.22 * across.abs() / math.max(reach, 1e-6);
      final band = (phase - 0.5 + sweep).abs();
      if (band > 0.30) return const _Rgba(0, 0, 0, 0);
    }
    final k = onRachis
        ? 0.5
        : 0.55 + 0.45 * (1.0 - across.abs() / math.max(reach, 1e-6));
    return _Rgba(
      (onRachis ? 0.24 : 0.15) * k * 1.3,
      (onRachis ? 0.28 : 0.36) * k * 1.3,
      (onRachis ? 0.14 : 0.13) * k * 1.3,
      1.0,
    );
  }

  /// A tuft of grass blades rising from the bottom of the cell.
  static _Rgba _bladeSample(double u, double v) {
    final up = 1.0 - v; // 0 at the ground edge
    const blades = 13;
    for (var i = 0; i < blades; i++) {
      final h1 = _hash(i, 0, 81), h2 = _hash(i, 0, 82), h3 = _hash(i, 0, 83);
      final rootX = 0.5 + (h1 - 0.5) * 0.34;
      final height = 0.45 + 0.55 * h2;
      if (up > height) continue;
      final t = up / height;
      // Blades arc outward: a parabola in t leans the tip away from the root.
      final lean = (h3 - 0.5) * 1.5;
      final x = rootX + lean * t * t * 0.30;
      final halfWidth = 0.017 * (1.0 - math.pow(t, 1.5).toDouble()) + 0.0015;
      if ((u - x).abs() < halfWidth) {
        // Darker at the base, sun-bleached toward the tip.
        final k = 0.55 + 0.45 * t;
        final dry = h2 > 0.82 ? 0.5 : 0.0;
        return _Rgba(
          (0.18 + 0.34 * dry) * k,
          (0.36 + 0.10 * dry) * k,
          (0.13 + 0.02 * dry) * k,
          1.0,
        );
      }
    }
    return const _Rgba(0, 0, 0, 0);
  }

  /// Radial falloff toward the cell's edges, so clump artwork fades out before
  /// it reaches the atlas gutter.
  static double _falloff(double u, double v) {
    final dx = (u - 0.5) * 2.0, dy = (v - 0.5) * 2.0;
    final d = math.sqrt(dx * dx + dy * dy);
    return d >= 1.0 ? 0.0 : _smooth(1.0, 0.55, d);
  }

  // ---- Tileable value noise (same construction as TerrainTextures) --------

  static double _noise(double u, double v, int period, int seed) {
    final fx = u * period, fy = v * period;
    final x0 = fx.floor(), y0 = fy.floor();
    final tx = fx - x0, ty = fy - y0;
    double corner(int cx, int cy) =>
        _hash((x0 + cx) % period, (y0 + cy) % period, seed);
    final sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty);
    final a = corner(0, 0), b = corner(1, 0);
    final c = corner(0, 1), d = corner(1, 1);
    return _lerp(_lerp(a, b, sx), _lerp(c, d, sx), sy);
  }

  static double _fbm(double u, double v, int seed,
      {int octaves = 4, int basePeriod = 8}) {
    var sum = 0.0, amp = 0.5, total = 0.0, p = basePeriod;
    for (var o = 0; o < octaves; o++) {
      sum += amp * _noise(u, v, p, seed + o * 101);
      total += amp;
      amp *= 0.5;
      p *= 2;
    }
    return sum / total;
  }

  static double _hash(int x, int y, int seed) {
    var h = x * 374761393 + y * 668265263 + seed * 2246822519;
    h = (h ^ (h >> 13)) * 1274126177;
    h ^= h >> 16;
    return (h & 0x7fffffff) / 0x7fffffff;
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  static double _smooth(double e0, double e1, double x) {
    final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  static int _b(double v) => (v.clamp(0.0, 1.0) * 255.0).round();
}

class _Rgba {
  const _Rgba(this.r, this.g, this.b, this.a);
  final double r, g, b, a;
}
