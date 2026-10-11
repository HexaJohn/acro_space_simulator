// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/combat/live/battle_raster.dart';
import 'package:acro_space_simulator/domain/terrain/ground_sample_pool.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:flutter_test/flutter_test.dart';

/// The battle raster: combat.md §7G.
void main() {
  test('a raster centred between the LZ and the goal keeps the LZ\'s ring inside', () {
    final (ce, cn) = BattleRaster.centreFor(800, 0, -800, 0);
    expect(ce, closeTo(800 - (600 - kRasterLzMarginM), 1e-9));
    expect(cn, 0);
    final r = BattleRaster(ce, cn);
    expect(r.contains(800 + kRasterLzMarginM, 0), isTrue);
  });

  test('bilinear between baked cells; null where a cell is not baked', () {
    final r = BattleRaster(0, 0, sideM: 32, cellM: 8);
    expect(r.n, 4);
    expect(r.radiusAt(0, 0), isNull);
    for (var k = 0; k < r.radii.length; k++) {
      final (e, _) = r.cellCentre(k);
      r.put(k, 1000 + e); // ground rising eastward, 1 m a metre
    }
    expect(r.complete, isTrue);
    expect(r.radiusAt(0, 0), closeTo(1000, 1e-9));
    expect(r.radiusAt(3, 5), closeTo(1003, 1e-9));
    expect(r.radiusAt(40, 0), isNull, reason: 'outside the square');
  });

  test('objectives bake first', () {
    final r = BattleRaster(0, 0, sideM: 400, cellM: 8);
    final order = r.bakeOrder([(150, 150)]);
    final (e, n) = r.cellCentre(order.first);
    expect((e - 150).abs() < 120 && (n - 150).abs() < 120, isTrue);
    expect(order.toSet().length, r.radii.length);
  });

  test('the sync pool samples the field', () async {
    final field = TerrainField(radius: 1000, amplitude: 10, featureScale: 100, seed: 3);
    final out = await SyncGroundSamplePool().sample(field, Float64List.fromList([1, 0, 0, 0, 1, 0]));
    expect(out, hasLength(2));
    expect(out[0], closeTo(field.surfaceRadiusAt(1, 0, 0), 1e-9));
  });
}
