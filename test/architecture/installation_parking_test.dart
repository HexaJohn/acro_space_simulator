// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/architecture/building_massing.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

/// An installation's car park is inside its plot, in front of its
/// buildings, and clear of them. They used to be laid a fixed distance
/// outside the front line — over whatever the plot fronted.
void main() {
  const rules = BuildingMassingRules();

  Parcel plotFor(CityBuildingSpec spec) {
    final site = spec.siteMetres();
    final w = site.width, d = site.depth;
    return Parcel(
      id: spec.type,
      polygon: [Vec2(-w / 2, 0), Vec2(w / 2, 0), Vec2(w / 2, d), Vec2(-w / 2, d)],
      frontage: (Vec2(-w / 2, 0), Vec2(w / 2, 0)),
      manual: true,
    );
  }

  test('every staked installation parks inside its own plot, clear of its '
      'buildings', () {
    var withLots = 0;
    for (final spec in kUtilCatalog.where((s) => s.claimsOwnSite)) {
      final parcel = plotFor(spec);
      final m = rules.massFor(spec, parcel);
      final lot = m.parking;
      if (lot == null) continue;
      withLots++;
      final extent = parcel.buildableExtent;
      final halfW = extent.width / 2, halfD = extent.depth / 2;
      final x0 = lot.x - lot.width / 2, x1 = lot.x + lot.width / 2;
      final y0 = lot.y - lot.depth / 2, y1 = lot.y + lot.depth / 2;
      expect(y0, greaterThanOrEqualTo(-halfD - 1e-6), reason: '${spec.type}: lot ahead of the front line');
      expect(y1, lessThanOrEqualTo(halfD + 1e-6), reason: '${spec.type}: lot past the back');
      expect(x0, greaterThanOrEqualTo(-halfW - 1e-6), reason: spec.type);
      expect(x1, lessThanOrEqualTo(halfW + 1e-6), reason: spec.type);
      // Clear of every volume: no volume's footprint reaches into the lot.
      for (final v in m.volumes) {
        final vf = v.y - v.depth / 2;
        final overlapsX = v.x + v.width / 2 > x0 && v.x - v.width / 2 < x1;
        if (!overlapsX) continue;
        expect(vf, greaterThanOrEqualTo(y1 - 1e-6),
            reason: '${spec.type}: a volume stands on the car park');
      }
      expect(lot.depth, greaterThanOrEqualTo(8));
    }
    expect(withLots, greaterThan(3), reason: 'the installations that park');
  });

  // R4 (docs/plans/site-access.md §6.2, §8.2): a PLAN-SERVED installation
  // has no car park of its own. The site access plan drew its car park, its
  // aisles and its stalls outside the envelope, and a massing lot laid over
  // them would be a second, disagreeing one — the fifth lot line the slice
  // exists to remove. The gate lane is the plan's drive, so nothing stands
  // in it either.
  test('a plan-served installation keeps no car park of its own, and nothing '
      'stands in its gate lane', () {
    const gate = SiteGate(xM: 0, widthM: 9);
    // A gate of zero width is a plan-served site with no drive of its own
    // (building_massing.dart:140), so it is the SAME massing with the lane
    // pass skipped — the probe that says whether the lane half of this test
    // has anything to bite on.
    const shut = SiteGate(xM: 0, widthM: 0);
    var served = 0, laneCleared = 0;
    for (final spec in kUtilCatalog.where((s) => s.claimsOwnSite)) {
      final parcel = plotFor(spec);
      final m = rules.massFor(spec, parcel, gate: gate);
      // The parking half: only the installations that park one themselves.
      if (rules.massFor(spec, parcel).parking != null) {
        served++;
        expect(m.parking, isNull, reason: '${spec.type}: the plan parks it');
      }
      // The lane half runs over EVERY staked installation, parking or not:
      // the specs that put a volume in the gate lane are exactly the ones
      // that park nothing, so filtering by the car park made this vacuous.
      final extent = parcel.buildableExtent;
      final front = -extent.depth / 2;
      bool inLane(MassBox v) {
        final overlapsX = v.x + v.width / 2 > gate.xM - gate.widthM / 2 &&
            v.x - v.width / 2 < gate.xM + gate.widthM / 2;
        return overlapsX &&
            v.y - v.depth / 2 < front + SiteGate.laneDepthM - 1e-6;
      }

      for (final v in m.volumes) {
        expect(inLane(v), isFalse,
            reason: '${spec.type}: a volume stands in the gate lane');
      }
      if (rules.massFor(spec, parcel, gate: shut).volumes.any(inLane)) {
        laneCleared++;
      }
    }
    expect(served, greaterThan(3), reason: 'the installations that park');
    expect(laneCleared, greaterThan(3),
        reason: 'the installations whose gate lane the pass actually clears '
            '(9 today); without these the lane check above could never fail');
  });
}
