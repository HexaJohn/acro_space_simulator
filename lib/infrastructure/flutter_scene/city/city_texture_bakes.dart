// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Procedural tiles for colony buildings: a concrete facade, a glazing sheet,
/// and the emissive mask that lights its panes at night.
///
/// Pure byte generators — no GPU, no `dart:ui` — for the same reason the
/// scatter bakes are: they can be unit tested, and they cost no asset files to
/// ship or license.
///
/// The mullions live HERE rather than in geometry. At ten thousand buildings a
/// per-pane quad is the difference between a frame and a slideshow, so the
/// window grid is drawn into the texture once and every tower in the colony
/// samples it.
library;

import 'dart:math' as math;
import 'dart:typed_data';

class CityTextureBakes {
  CityTextureBakes._();

  /// Opaque wall: precast concrete panels with a seam grid and enough grain
  /// that a flat facade does not read as plastic.
  static Uint8List facade(int size) {
    final out = Uint8List(size * size * 4);
    final rnd = math.Random(0xFACADE);
    // One panel per eighth of the tile; the UVs are laid out so a tile spans
    // roughly one storey by four metres, which puts panels near human scale.
    final panel = size ~/ 8;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final i = (y * size + x) * 4;
        // Base tone, varied per panel so the wall is not one flat grey.
        final px = x ~/ panel, py = y ~/ panel;
        final panelShade =
            0.86 + ((px * 7 + py * 13) % 5) * 0.028; // deterministic per panel
        var v = 168.0 * panelShade;
        // Grain.
        v += (rnd.nextDouble() - 0.5) * 14;
        // Seams: darker gutters on the panel boundaries, with the horizontal
        // ones heavier — that asymmetry is what reads as stacked precast
        // rather than as tiling.
        final ex = x % panel, ey = y % panel;
        if (ey <= 1) v *= 0.72;
        if (ex <= 1) v *= 0.84;
        // Weathering streaks below each horizontal seam.
        if (ey > 1 && ey < panel ~/ 3) {
          final streak = math.sin(x * 0.7) * math.sin(x * 0.13);
          if (streak > 0.55) v *= 0.93;
        }
        final c = v.clamp(0.0, 255.0).round();
        out[i] = c;
        out[i + 1] = c;
        out[i + 2] = (c * 0.99).round();
        out[i + 3] = 255;
      }
    }
    return out;
  }

  /// Glazing sheet: RGBA, alpha 0 in the mullions so the wall behind shows
  /// through and the band reads as separate panes rather than a ribbon.
  static Uint8List glazing(int size, {int panesPerTile = 6}) {
    final out = Uint8List(size * size * 4);
    final cell = math.max(2, size ~/ panesPerTile);
    const frame = 2; // mullion half-width in texels
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final i = (y * size + x) * 4;
        final ex = x % cell, ey = y % cell;
        final isMullion =
            ex < frame || ey < frame || ex >= cell - frame || ey >= cell - frame;
        if (isMullion) {
          out[i] = 46;
          out[i + 1] = 48;
          out[i + 2] = 52;
          out[i + 3] = 255; // opaque frame
        } else {
          // Cool tinted glass, slightly darker toward the pane bottom so it
          // catches a gradient instead of reading as a flat swatch.
          final t = ey / cell;
          final shade = 1.0 - t * 0.25;
          out[i] = (78 * shade).round();
          out[i + 1] = (104 * shade).round();
          out[i + 2] = (128 * shade).round();
          out[i + 3] = 235;
        }
      }
    }
    return out;
  }

  /// Emissive mask for [glazing]: which panes are lit, and how warmly.
  ///
  /// A deterministic subset is lit rather than all of them — a fully lit
  /// facade reads as a texture, not a building — and the lit ones vary in
  /// colour temperature so a tower at night has some life in it. The renderer
  /// scales the whole thing by the night factor, so this is the pattern, not
  /// the brightness.
  static Uint8List windowEmissive(
    int size, {
    int panesPerTile = 6,
    double litFraction = 0.45,
    int seed = 0x11FE,
  }) {
    final out = Uint8List(size * size * 4);
    final cell = math.max(2, size ~/ panesPerTile);
    const frame = 2;
    final rnd = math.Random(seed);
    final cells = math.max(1, size ~/ cell);
    // Decide each pane up front so every texel of a pane agrees.
    final lit = List<double>.generate(cells * cells, (_) {
      if (rnd.nextDouble() > litFraction) return 0.0;
      return 0.55 + rnd.nextDouble() * 0.45;
    });
    final warm = List<double>.generate(cells * cells, (_) => rnd.nextDouble());

    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final i = (y * size + x) * 4;
        final cx = (x ~/ cell).clamp(0, cells - 1);
        final cy = (y ~/ cell).clamp(0, cells - 1);
        final ex = x % cell, ey = y % cell;
        final isMullion =
            ex < frame || ey < frame || ex >= cell - frame || ey >= cell - frame;
        final level = isMullion ? 0.0 : lit[cy * cells + cx];
        if (level <= 0) {
          out[i] = 0;
          out[i + 1] = 0;
          out[i + 2] = 0;
          out[i + 3] = 255;
          continue;
        }
        // Warm tungsten through to cool office fluorescent.
        final w = warm[cy * cells + cx];
        out[i] = (255 * level).round();
        out[i + 1] = (255 * level * (0.82 + w * 0.16)).round();
        out[i + 2] = (255 * level * (0.58 + w * 0.40)).round();
        out[i + 3] = 255;
      }
    }
    return out;
  }

  /// Ground-patch palette: one vertical swatch per patch kind.
  ///
  /// A palette rather than a per-patch colour because the mesh format carries
  /// position, normal and UV only — no vertex colour — and one material per
  /// colour would be five draws for what is a single sheet of ground. Every
  /// vertex of a patch samples the CENTRE of its swatch, so no filtering or
  /// mip level can bleed one kind's colour into its neighbour.
  static Uint8List groundPalette(int size, {int swatches = 6}) {
    // road, residential, commercial, industrial, support, CURSOR
    const colours = [
      [56, 58, 62],
      [86, 128, 96],
      [72, 108, 138],
      [138, 116, 74],
      [96, 102, 112],
      [120, 240, 255],
    ];
    final out = Uint8List(size * size * 4);
    final band = math.max(1, size ~/ swatches);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final i = (y * size + x) * 4;
        final c = colours[math.min(x ~/ band, colours.length - 1)];
        // A little vertical grain so a big zoned block is not a flat slab.
        final n = ((y * 37) % 11) - 5;
        out[i] = (c[0] + n).clamp(0, 255);
        out[i + 1] = (c[1] + n).clamp(0, 255);
        out[i + 2] = (c[2] + n).clamp(0, 255);
        out[i + 3] = 255;
      }
    }
    return out;
  }
}
