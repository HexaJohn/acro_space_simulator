// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// ignore_for_file: implementation_imports
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;

/// Procedurally-generated, SEAMLESSLY TILEABLE material textures for the voxel
/// terrain — regolith, rock, sand, grass. Generated once at startup (no asset
/// files, so nothing to license or bloat the web bundle) and uploaded to GPU
/// textures the terrain shader samples TRIPLANAR (per world axis, blended by the
/// surface normal) so slopes and future caves don't stretch.
///
/// Tileability: every octave samples an integer lattice whose coordinates wrap
/// `mod period`, and every period divides the tile size, so the pattern is
/// continuous across the 0<->1 seam and repeats without a visible edge.
class TerrainTextures {
  TerrainTextures._();

  /// Tile side in texels. 256 keeps ~1 MB/tile on the CPU while giving enough
  /// grain that the ~6 m world tiling reads as surface detail, not blur.
  static const int size = 256;

  // The uploaded GPU textures (flutter_scene's backend-shim type, held as
  // Object like SceneTextures — the concrete gpu type isn't ours to name).
  static Object? regolith;
  static Object? rock;
  static Object? sand;
  static Object? grass;

  static Future<void>? _loading;
  static bool get ready => regolith != null;

  /// Whether the uploaded tiles carry a mip chain (so the sampler can trilinear-
  /// filter them). False when the backend can't take manually-mipped textures.
  static bool mipmapped = false;

  /// Generate + upload all four tiles once. Idempotent.
  static Future<void> load() => _loading ??= () async {
        regolith = _upload(_regolith);
        rock = _upload(_rock);
        sand = _upload(_sand);
        grass = _upload(_grass);
      }();

  /// Bake the base tile, build its mip chain, and upload every level to a GPU
  /// texture. Manual mips (no hardware generate on this shim) let the sampler
  /// trilinear-filter the tiles so distant/grazing terrain doesn't shimmer;
  /// falls back to a single level where the backend can't take mipped uploads.
  static Object _upload(_Fill fill) {
    final ctx = gpu.gpuContext;
    final base = _bake(fill);
    // The backend caps the level count (e.g. 8 for 256^2 — it stops at 2x2, not
    // 1x1). fullMipCount reports its limit; truncate the chain to it.
    final wantMips = ctx.doesSupportManuallyMippedTextures;
    final maxLevels = wantMips ? gpu.Texture.fullMipCount(size, size) : 1;
    var levels = maxLevels > 1 ? _mipChain(base, size) : [base];
    if (levels.length > maxLevels) levels = levels.sublist(0, maxLevels);
    final tex = ctx.createTexture(
      gpu.StorageMode.hostVisible,
      size,
      size,
      mipLevelCount: levels.length,
    );
    for (var i = 0; i < levels.length; i++) {
      tex.overwrite(ByteData.sublistView(levels[i]), mipLevel: i);
    }
    mipmapped = levels.length > 1;
    return tex as Object;
  }

  /// Box-downsample [base] (RGBA, [size]x[size], power-of-two) into the full mip
  /// chain, level 0 = base down to 1x1.
  static List<Uint8List> _mipChain(Uint8List base, int size) {
    final chain = <Uint8List>[base];
    var cur = base, w = size, h = size;
    while (w > 1 || h > 1) {
      final nw = w > 1 ? w >> 1 : 1, nh = h > 1 ? h >> 1 : 1;
      final next = Uint8List(nw * nh * 4);
      for (var y = 0; y < nh; y++) {
        final y0 = y * 2, y1 = math.min(y * 2 + 1, h - 1);
        for (var x = 0; x < nw; x++) {
          final x0 = x * 2, x1 = math.min(x * 2 + 1, w - 1);
          final i00 = (y0 * w + x0) * 4, i01 = (y0 * w + x1) * 4;
          final i10 = (y1 * w + x0) * 4, i11 = (y1 * w + x1) * 4;
          final o = (y * nw + x) * 4;
          for (var c = 0; c < 4; c++) {
            next[o + c] =
                (cur[i00 + c] + cur[i01 + c] + cur[i10 + c] + cur[i11 + c]) >> 2;
          }
        }
      }
      chain.add(next);
      cur = next;
      w = nw;
      h = nh;
    }
    return chain;
  }

  // ---- Baking -------------------------------------------------------------

  static Uint8List _bake(_Fill fill) {
    final px = Uint8List(size * size * 4);
    for (var y = 0; y < size; y++) {
      final v = y / size;
      for (var x = 0; x < size; x++) {
        final u = x / size;
        final c = fill(u, v);
        final i = (y * size + x) * 4;
        px[i] = _b(c.r);
        px[i + 1] = _b(c.g);
        px[i + 2] = _b(c.b);
        px[i + 3] = 255;
      }
    }
    return px;
  }

  static int _b(double v) => (v.clamp(0.0, 1.0) * 255.0).round();

  // ---- Material recipes (u,v in [0,1), tileable) --------------------------

  static _Rgb _regolith(double u, double v) {
    final broad = _fbm(u, v, 1, octaves: 5, basePeriod: 8);
    final grain = _fbm(u, v, 2, octaves: 3, basePeriod: 32);
    final speck = _noise(u, v, 64, 3);
    // Brighter than physical lunar albedo (~0.12) so a lit patch reads as a grey
    // surface, not a black void — matches the previous flat palette's ~0.45.
    var c = 0.48 * (0.82 + 0.42 * broad) * (0.92 + 0.16 * grain);
    if (speck > 0.86) c *= 0.7; // dark pebble
    return _Rgb(c * 1.03, c * 0.98, c * 0.92); // warm grey dust
  }

  static _Rgb _rock(double u, double v) {
    final broad = _fbm(u, v, 11, octaves: 5, basePeriod: 6);
    final ridged = 1.0 - (2.0 * _fbm(u, v, 12, octaves: 3, basePeriod: 12) - 1.0).abs();
    final crack = _smooth(0.82, 1.0, ridged);
    var c = 0.38 * (0.78 + 0.44 * broad);
    c *= 1.0 - 0.55 * crack; // dark crevices
    return _Rgb(c, c * 0.97, c * 0.94);
  }

  static _Rgb _sand(double u, double v) {
    // Wind ripples: integer-period sines wrap seamlessly; a tileable noise phase
    // breaks up the regularity without losing tiling.
    final phase = _fbm(u, v, 22, octaves: 2, basePeriod: 8) * 4.0;
    final ripple = 0.5 + 0.5 * math.sin(2.0 * math.pi * 22.0 * v + phase);
    final grain = _fbm(u, v, 23, octaves: 3, basePeriod: 32);
    final base = _Rgb(0.76, 0.66, 0.44);
    final k = (0.9 + 0.14 * ripple) * (0.92 + 0.16 * grain);
    return _Rgb(base.r * k, base.g * k, base.b * k);
  }

  static _Rgb _grass(double u, double v) {
    final patch = _fbm(u, v, 31, octaves: 4, basePeriod: 6);
    final blade = _fbm(u, v, 32, octaves: 3, basePeriod: 40);
    final dry = _noise(u, v, 80, 33);
    const dark = _Rgb(0.18, 0.30, 0.11);
    const light = _Rgb(0.38, 0.52, 0.20);
    var c = _mix(dark, light, patch);
    final k = 0.86 + 0.26 * blade;
    c = _Rgb(c.r * k, c.g * k, c.b * k);
    if (dry > 0.9) c = _mix(c, const _Rgb(0.60, 0.58, 0.22), 0.5); // dry tuft
    return c;
  }

  // ---- Tileable value-noise -----------------------------------------------

  /// Periodic value noise: lattice coords wrap `mod period`, so sampling u,v in
  /// [0,1) gives a seam-free, repeatable pattern.
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

  static _Rgb _mix(_Rgb a, _Rgb b, double t) =>
      _Rgb(_lerp(a.r, b.r, t), _lerp(a.g, b.g, t), _lerp(a.b, b.b, t));
}

typedef _Fill = _Rgb Function(double u, double v);

class _Rgb {
  const _Rgb(this.r, this.g, this.b);
  final double r, g, b;
}
