// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// ignore_for_file: implementation_imports
import 'dart:typed_data';

import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;

import 'city_texture_bakes.dart';

/// GPU residency for the colony's three tiles: facade, glazing, and the
/// emissive mask that lights the glazing at night.
///
/// Three textures is three materials is a handful of instanced draws for an
/// entire city — the same budget the scatter system holds a whole forest to.
class CityTextures {
  CityTextures._();

  /// The facade is an ATLAS now — eight masonries banded along U — so it needs
  /// the resolution to give each band something to show. 1024 leaves 128 px a
  /// band, which is about 50 px per metre of wall at the scale a segment maps.
  static const int facadeSize = 1024;
  static const int glassSize = 256;

  static Object? facade;
  static Object? glazing;
  static Object? windowEmissive;
  static Object? groundPalette;
  static Object? roadStrip;
  static Object? alleyStrip;
  static Object? dirtStrip;

  static Future<void>? _loading;

  static bool get ready =>
      facade != null &&
      glazing != null &&
      windowEmissive != null &&
      groundPalette != null &&
      roadStrip != null &&
      alleyStrip != null &&
      dirtStrip != null;

  static Future<void> load() => _loading ??= () async {
        facade = _upload(CityTextureBakes.facade(facadeSize), facadeSize);
        glazing = _upload(CityTextureBakes.glazing(glassSize), glassSize);
        // The emissive mask must NOT be mipped down to grey: averaging a lit
        // pane with its dark neighbour turns a distant tower into a uniform
        // glow instead of a scatter of windows. The mip chain here is built
        // from the same box filter, but the pattern is deliberately coarse
        // (a few panes per tile) so the first few levels still resolve panes.
        windowEmissive =
            _upload(CityTextureBakes.windowEmissive(glassSize), glassSize);
        groundPalette =
            _upload(CityTextureBakes.groundPalette(glassSize), glassSize);
        roadStrip = _upload(CityTextureBakes.roadStrip(glassSize), glassSize);
        alleyStrip =
            _upload(CityTextureBakes.alleyStrip(glassSize), glassSize);
        dirtStrip = _upload(CityTextureBakes.dirtStrip(glassSize), glassSize);
      }();

  static bool mipmapped = false;

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

  /// Box-downsample, weighting colour by alpha — the same rule the scatter
  /// atlas uses, and for the same reason: the mullion gaps in the glazing tile
  /// would otherwise bleed their dark frame colour across the panes.
  static List<Uint8List> _mipChain(Uint8List base, int size) {
    final chain = <Uint8List>[base];
    var cur = base, w = size, h = size;
    while (w > 1 || h > 1) {
      final nw = w > 1 ? w >> 1 : 1;
      final nh = h > 1 ? h >> 1 : 1;
      final next = Uint8List(nw * nh * 4);
      for (var y = 0; y < nh; y++) {
        for (var x = 0; x < nw; x++) {
          var r = 0.0, g = 0.0, b = 0.0, a = 0.0, wsum = 0.0;
          for (var dy = 0; dy < 2; dy++) {
            for (var dx = 0; dx < 2; dx++) {
              final sx = (x * 2 + dx).clamp(0, w - 1);
              final sy = (y * 2 + dy).clamp(0, h - 1);
              final i = (sy * w + sx) * 4;
              final av = cur[i + 3] / 255.0;
              r += cur[i] * av;
              g += cur[i + 1] * av;
              b += cur[i + 2] * av;
              a += cur[i + 3];
              wsum += av;
            }
          }
          final o = (y * nw + x) * 4;
          final inv = wsum > 0 ? 1.0 / wsum : 0.0;
          next[o] = (r * inv).clamp(0, 255).round();
          next[o + 1] = (g * inv).clamp(0, 255).round();
          next[o + 2] = (b * inv).clamp(0, 255).round();
          next[o + 3] = (a / 4).clamp(0, 255).round();
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
