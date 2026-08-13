// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// ignore_for_file: implementation_imports
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;

import 'scatter_texture_bakes.dart';

/// Procedurally-generated textures for scattered props: one opaque BARK tile
/// and one alpha-cut FOLIAGE atlas.
///
/// Same reasoning as [TerrainTextures] — generated at startup, so there are no
/// asset files to license or to bloat the web bundle — but with one critical
/// difference: the foliage atlas carries a real alpha channel. Every leaf,
/// needle, frond and blade in the scene is a flat quad whose SHAPE lives
/// entirely in that alpha, so the atlas is not decoration, it is the geometry
/// the eye actually sees.
///
/// Only two textures, because two textures is two materials is two instanced
/// draws for an entire forest.
class ScatterTextures {
  ScatterTextures._();

  /// Bark tile side in texels. Bark is sampled along a trunk at roughly half a
  /// metre per repeat, so 256 gives visible grain without a megabyte per tile.
  static const int barkSize = 256;

  /// Foliage atlas side in texels. The atlas holds [FoliageAtlas.grid] squared
  /// cells, so 512 leaves each cell at 256 — the resolution a leaf clump needs
  /// once it fills the screen on a close approach.
  static const int foliageSize = 512;

  /// Opaque bark/wood. Held as [Object] like the other texture holders here —
  /// the concrete gpu type belongs to flutter_scene's backend shim.
  static Object? bark;

  /// RGBA foliage atlas. Alpha is the leaf mask; see [FoliageCell].
  static Object? foliage;

  /// Stone. Rocks could share the terrain's rock tile, but props are lit and
  /// scaled very differently from a terrain chunk, and a dedicated tile lets
  /// the grain track prop size (see the rock generator's `uScale`).
  static Object? stone;

  static Future<void>? _loading;
  static bool get ready => bark != null && foliage != null && stone != null;

  /// Whether the uploads carry a mip chain.
  ///
  /// This matters far more for foliage than for terrain: an unmipped alpha-cut
  /// leaf card is the classic source of shimmering, crawling foliage at
  /// distance, because the alpha test samples a different texel every frame as
  /// the card sub-pixel-jitters.
  static bool mipmapped = false;

  /// Generate + upload every texture once. Idempotent.
  static Future<void> load() => _loading ??= () async {
        bark = _upload(ScatterTextureBakes.bark(barkSize), barkSize);
        stone = _upload(ScatterTextureBakes.stone(barkSize), barkSize);
        foliage =
            _upload(ScatterTextureBakes.foliageAtlas(foliageSize), foliageSize);
      }();

  // ---- Upload -------------------------------------------------------------

  static Object _upload(Uint8List base, int size) {
    final ctx = gpu.gpuContext;
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

  /// Box-downsample into a full mip chain.
  ///
  /// Colour is averaged WEIGHTED BY ALPHA. Averaging colour and alpha
  /// independently is the standard mistake: the transparent gaps between leaves
  /// hold whatever colour the baker happened to leave there, and at every mip
  /// that colour bleeds into the leaf, giving a dark halo around distant
  /// foliage. Weighting means fully transparent texels contribute nothing.
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
          final src = [
            (y0 * w + x0) * 4,
            (y0 * w + x1) * 4,
            (y1 * w + x0) * 4,
            (y1 * w + x1) * 4,
          ];
          var aSum = 0, r = 0, g = 0, b = 0;
          for (final i in src) {
            final a = cur[i + 3];
            aSum += a;
            r += cur[i] * a;
            g += cur[i + 1] * a;
            b += cur[i + 2] * a;
          }
          final o = (y * nw + x) * 4;
          if (aSum == 0) {
            // Fully transparent block: keep an unweighted colour average so the
            // texel is not black if something ever samples it regardless.
            for (var c = 0; c < 4; c++) {
              next[o + c] =
                  (cur[src[0] + c] + cur[src[1] + c] + cur[src[2] + c] +
                          cur[src[3] + c]) >>
                      2;
            }
          } else {
            next[o] = r ~/ aSum;
            next[o + 1] = g ~/ aSum;
            next[o + 2] = b ~/ aSum;
            next[o + 3] = aSum >> 2;
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

}
