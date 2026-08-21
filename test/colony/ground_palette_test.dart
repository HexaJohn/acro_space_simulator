// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_texture_bakes.dart';
import 'package:flutter_test/flutter_test.dart';

/// The ground palette and the things that sample it must agree on how many
/// bands there are.
///
/// This has now drifted twice. The palette gained a cursor and a refusal
/// swatch, then the two the placement heatmap paints with, while the patch
/// pass kept dividing by its own count of patch KINDS — so every lot read the
/// wrong band: residential sampled commercial blue, industrial sampled refusal
/// red, support sampled heatmap amber, and nothing in the city was green.
///
/// `kGroundSwatches` exists to be the single answer. These check that the bake
/// and the samplers actually use it.
void main() {
  /// Which band a `u` coordinate lands in, the way the sampler does.
  int bandAt(double u, int size) {
    final band = size ~/ kGroundSwatches;
    return (u * size) ~/ band;
  }

  test('the bake has exactly kGroundSwatches distinct bands', () {
    const size = 288; // divisible by 9, so bands are exact
    final px = CityTextureBakes.groundPalette(size);
    final seen = <String>{};
    for (var i = 0; i < kGroundSwatches; i++) {
      // Sample the CENTRE of each band, away from any edge blending.
      final x = (i + 0.5) * size ~/ kGroundSwatches;
      const y = 4;
      final o = (y * size + x) * 4;
      seen.add('${px[o]},${px[o + 1]},${px[o + 2]}');
    }
    expect(seen.length, kGroundSwatches,
        reason: 'two swatches bake to the same colour');
  });

  test('the palette has room for every patch kind', () {
    // The failure was a LOCAL divisor in the patch pass that did not grow with
    // the palette. This cannot catch that — a test that re-derives the
    // formula it is checking always agrees with itself, which is exactly the
    // trap I fell into writing the first version of this file.
    //
    // What it CAN pin is the precondition: the palette must have at least as
    // many bands as there are patch kinds, and the kinds must be the first
    // ones, so `(kind + 0.5) / kGroundSwatches` is a meaningful thing for the
    // renderer to compute at all.
    expect(kGroundSwatches, greaterThan(CityPatchSnapshot.kindSupport));
    const size = 288;
    for (var kind = 0; kind <= CityPatchSnapshot.kindSupport; kind++) {
      expect(bandAt((kind + 0.5) / kGroundSwatches, size), kind);
    }
  });

  test('the zone bands are the colours they are meant to be', () {
    // Residential green, commercial blue, industrial tan. Checked on the BAKE,
    // which is a real output — if a swatch is reordered or recoloured, the
    // colonies change colour and this says so.
    const size = 288;
    final px = CityTextureBakes.groundPalette(size);
    ({int r, int g, int b}) bandColour(int kind) {
      final x = ((kind + 0.5) * size ~/ kGroundSwatches);
      final o = (4 * size + x) * 4;
      return (r: px[o], g: px[o + 1], b: px[o + 2]);
    }

    final res = bandColour(CityPatchSnapshot.kindResidential);
    expect(res.g, greaterThan(res.r), reason: 'residential is not green');
    expect(res.g, greaterThan(res.b), reason: 'residential is not green');

    final com = bandColour(CityPatchSnapshot.kindCommercial);
    expect(com.b, greaterThan(com.r), reason: 'commercial is not blue');
    expect(com.b, greaterThan(com.g), reason: 'commercial is not blue');

    final ind = bandColour(CityPatchSnapshot.kindIndustrial);
    expect(ind.r, greaterThan(ind.b), reason: 'industrial is not tan');
  });
}

// NOT TESTED HERE: that the patch pass divides by `kGroundSwatches` rather
// than by a local count of its own. That was the actual bug — every lot read
// the wrong band, residential sampled commercial blue and nothing in the city
// was green — but it lives inside a renderer method that needs a live scene to
// call. Guarded by review: search for divisors near a UV computation.
