// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Subdivision the way a plat map actually looks: even fronts, ragged backs.
/// Lots run back to the block midline against a facing street, fill the open
/// depth where there is none, and corner lots are clipped at the crossing
/// street's setback instead of poking into the junction.
void main() {
  test('facing streets split their block at the midline, no dead ground', () {
    // Two parallel streets 60 m apart; the default lot depth (32 m) would
    // OVERLAP across the block if both sides took it.
    final layout = CityLayout(
      settings:
          const ParcelSettings(frontageM: 24, depthM: 32, cornerClearM: 0),
    );
    layout.commitRoad(controls: const [Vec2(0, -150), Vec2(0, 150)]);
    layout.commitRoad(controls: const [Vec2(60, -150), Vec2(60, 150)]);

    // The lots facing INTO the block stop near the midline (x = 30):
    final inner = layout.autoParcels.where((p) {
      final c = p.centroid;
      return c.e > 5 && c.e < 55;
    }).toList();
    expect(inner, isNotEmpty);
    for (final lot in inner) {
      for (final v in lot.polygon) {
        expect(v.e, inInclusiveRange(-1.0, 61.0));
      }
      // Depth is the HALF GAP, not the configured 32 m.
      final extent = lot.buildableExtent;
      expect(extent.depth, lessThan(24),
          reason: 'a 60 m block minus two carriageways leaves ~20 m a side');
    }
    // No overlaps anywhere across the block.
    final lots = layout.autoParcels;
    for (var i = 0; i < lots.length; i++) {
      for (var j = i + 1; j < lots.length; j++) {
        expect(lots[i].overlaps(lots[j]), isFalse,
            reason: 'lot $i overlaps lot $j across the midline');
      }
    }
  });

  test('an open block edge runs to the configured depth', () {
    final layout = CityLayout(
      settings:
          const ParcelSettings(frontageM: 24, depthM: 32, cornerClearM: 0),
    );
    layout.commitRoad(controls: const [Vec2(0, -150), Vec2(0, 150)]);
    // Nothing east or west of the lone street: full depth both sides.
    for (final lot in layout.autoParcels) {
      expect(lot.buildableExtent.depth, closeTo(32, 1));
    }
  });

  test('lots go irregular against a slanted facing road', () {
    final layout = CityLayout(
      settings:
          const ParcelSettings(frontageM: 24, depthM: 40, cornerClearM: 0),
    );
    layout.commitRoad(controls: const [Vec2(0, -150), Vec2(0, 150)]);
    // A road converging at an angle: the gap narrows from south to north.
    layout.commitRoad(controls: const [Vec2(130, -150), Vec2(35, 150)]);

    // Some lot between them must have a SLANTED back: unequal corner depths.
    var slanted = 0;
    for (final lot in layout.autoParcels.where((p) => p.roadId != null)) {
      if (lot.polygon.length < 4) continue;
      final f = lot.frontage;
      if (f == null) continue;
      final away = (f.$2 - f.$1).normalized.perp;
      final depths = [
        for (final v in lot.polygon) (v - f.$1).dot(away).abs()
      ]..sort();
      final backSpread = (depths.last - depths[depths.length - 2]).abs();
      if (depths.last > 5 && backSpread > 2.5) slanted++;
    }
    expect(slanted, greaterThan(0),
        reason: 'a converging block should produce trapezoid lots');
  });

  test('corner lots are clipped at the crossing street, not dropped square', () {
    final layout = CityLayout(
      settings:
          const ParcelSettings(frontageM: 24, depthM: 32, cornerClearM: 6),
    );
    layout.commitRoad(controls: const [Vec2(0, -200), Vec2(0, 200)]);
    layout.commitRoad(controls: const [Vec2(-200, 0), Vec2(200, 0)]);

    // No lot vertex may sit inside any carriageway.
    for (final lot in layout.autoParcels) {
      final road = layout.roads
          .firstWhere((r) => r.id == lot.roadId);
      for (final other in layout.roads) {
        if (other.id == road.id) continue;
        for (final v in lot.polygon) {
          expect(other.distanceTo(v),
              greaterThanOrEqualTo(other.halfWidth - 0.5),
              reason: 'lot corner inside the crossing carriageway');
        }
      }
    }
  });

  test('buildable extent is the SAFE core, never past a clipped corner', () {
    final layout = CityLayout(
      settings:
          const ParcelSettings(frontageM: 24, depthM: 32, cornerClearM: 0),
    );
    layout.commitRoad(controls: const [Vec2(0, -150), Vec2(0, 150)]);
    layout.commitRoad(controls: const [Vec2(50, -150), Vec2(50, 150)]);
    for (final lot in layout.autoParcels) {
      final f = lot.frontage;
      if (f == null) continue;
      final away = (f.$2 - f.$1).normalized.perp;
      var minBack = double.infinity;
      for (final v in lot.polygon) {
        final d = (v - f.$1).dot(away).abs();
        if (d > 1) minBack = minBack > d ? d : minBack;
      }
      expect(lot.buildableExtent.depth, lessThanOrEqualTo(minBack + 0.5),
          reason: 'a building sized to the extent must fit the polygon');
    }
  });
}
