// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_texture_bakes.dart';
import 'package:flutter_test/flutter_test.dart';

/// The window grid lives in the TEXTURE, not in geometry — at ten thousand
/// buildings a per-pane quad is the difference between a frame and a
/// slideshow — so these check the tiles actually carry what the shader needs.
void main() {
  const size = 64;

  ({int r, int g, int b, int a}) texel(List<int> px, int x, int y) {
    final i = (y * size + x) * 4;
    return (r: px[i], g: px[i + 1], b: px[i + 2], a: px[i + 3]);
  }

  test('the facade is opaque and varied, not a flat swatch', () {
    final t = CityTextureBakes.facade(size);
    expect(t.length, size * size * 4);

    final tones = <int>{};
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final c = texel(t, x, y);
        expect(c.a, 255, reason: 'a wall must be opaque');
        tones.add(c.r);
      }
    }
    expect(tones.length, greaterThan(20), reason: 'grain and panel variation');
  });

  test('glazing has opaque mullions and translucent panes', () {
    final t = CityTextureBakes.glazing(size, panesPerTile: 4);
    // Cell is 16 texels; the frame is the first two.
    expect(texel(t, 0, 0).a, 255, reason: 'mullion');
    expect(texel(t, 8, 8).a, lessThan(255), reason: 'pane lets light through');
    // The pane is tinted, not white.
    final pane = texel(t, 8, 8);
    expect(pane.b, greaterThan(pane.r));
  });

  test('only some windows are lit, and lit ones vary in warmth', () {
    final t = CityTextureBakes.windowEmissive(size, panesPerTile: 4);
    var lit = 0, dark = 0;
    final warmths = <int>{};
    for (var cy = 0; cy < 4; cy++) {
      for (var cx = 0; cx < 4; cx++) {
        final c = texel(t, cx * 16 + 8, cy * 16 + 8);
        if (c.r > 10) {
          lit++;
          warmths.add(c.b);
        } else {
          dark++;
        }
      }
    }
    expect(lit, greaterThan(0));
    expect(dark, greaterThan(0),
        reason: 'a fully lit facade reads as a texture, not a building');
    expect(warmths.length, greaterThan(1),
        reason: 'tungsten through to fluorescent');
  });

  test('mullions never glow', () {
    final t = CityTextureBakes.windowEmissive(size, panesPerTile: 4);
    for (var cy = 0; cy < 4; cy++) {
      for (var cx = 0; cx < 4; cx++) {
        final frame = texel(t, cx * 16, cy * 16);
        expect(frame.r, 0);
        expect(frame.g, 0);
        expect(frame.b, 0);
      }
    }
  });

  test('the bake is deterministic — a colony must not reshuffle its windows', () {
    final a = CityTextureBakes.windowEmissive(size);
    final b = CityTextureBakes.windowEmissive(size);
    expect(a, equals(b));
  });

  test('the road swatch is a painted tile, not a flat colour', () {
    // A road cell maps its whole quad across this swatch, so the swatch has to
    // carry the pavement: markings, curbs and aggregate. Flat grey reads as a
    // hole in the ground rather than as a road.
    const s = 96;
    const swatches = 6;
    final t = CityTextureBakes.groundPalette(s, swatches: swatches);
    final band = s ~/ swatches;

    ({int r, int g, int b}) at(int x, int y) {
      final i = (y * s + x) * 4;
      return (r: t[i], g: t[i + 1], b: t[i + 2]);
    }

    // Centre line: markings are markedly brighter and warmer than tarmac.
    final line = at(band ~/ 2, band ~/ 12);
    final tarmac = at(band ~/ 4, band ~/ 3);
    expect(line.r, greaterThan(tarmac.r + 40));
    expect(line.b, lessThan(line.r), reason: 'road paint is warm, not blue');

    // The tile is not uniform — aggregate speckle plus curbs.
    final tones = <int>{};
    for (var y = 0; y < band; y++) {
      for (var x = 0; x < band; x++) {
        tones.add(at(x, y).r);
      }
    }
    expect(tones.length, greaterThan(15));
  });

  test('a flat-colour swatch stays flat, so its centre never bleeds', () {
    const s = 96;
    const swatches = 6;
    final t = CityTextureBakes.groundPalette(s, swatches: swatches);
    final band = s ~/ swatches;
    // Residential is swatch 1: sampled at its centre by every zone patch.
    int red(int x, int y) => t[(y * s + x) * 4];
    final a = red(band + band ~/ 2, s ~/ 2);
    final b = red(band + band ~/ 2, s ~/ 2 + 1);
    expect((a - b).abs(), lessThan(14), reason: 'grain only, no structure');
  });

  test('the road strip runs its markings ALONG the tile, not across it', () {
    const s = 96;
    final t = CityTextureBakes.roadStrip(s);
    ({int r, int g, int b}) at(int x, int y) {
      final i = (y * s + x) * 4;
      return (r: t[i], g: t[i + 1], b: t[i + 2]);
    }

    // Centre line at u=0.5: painted on some v (dash), tarmac on others.
    final dashOn = at(s ~/ 2, s ~/ 8); // first dash band
    final dashOff = at(s ~/ 2, (s * 3) ~/ 8); // first gap band
    expect(dashOn.r, greaterThan(160));
    expect(dashOn.b, lessThan(dashOn.r), reason: 'road paint is warm');
    expect(dashOff.r, lessThan(140), reason: 'the line is dashed');

    // Curbs at both edges, lighter than the mid-lane tarmac.
    final curb = at(1, s ~/ 2);
    final lane = at(s ~/ 4, s ~/ 2);
    expect(curb.r, greaterThan(lane.r + 10));

    // And NO transverse stripe: mid-lane tarmac is tarmac at every v.
    for (var y = 0; y < s; y += 4) {
      expect(at(s ~/ 4, y).r, lessThan(150),
          reason: 'a cross-tile stripe would band the carriageway');
    }
  });
}
