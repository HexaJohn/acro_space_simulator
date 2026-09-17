// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/architecture/building_massing.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where an installation's cars go, and the lane they get in by.
///
/// The massing itself parks nobody: R7 deleted the surface car park it used to
/// lay inside its own plot (docs/plans/site-access.md §9), so an installation's
/// stalls are its site plan's, packed by `car_park_packer` and drawn by
/// `SiteAccessMesher`. What the massing still owes a plan is the GATE LANE —
/// the strip its drive comes in through, which no volume may stand in.
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

  // R4 (docs/plans/site-access.md §6.2, §8.2), kept at R7: the gate lane is
  // the plan's drive, so nothing stands in it.
  test('nothing stands in a plan-served installation gate lane', () {
    const gate = SiteGate(xM: 0, widthM: 9);
    // A gate of zero width is a plan-served site with no drive of its own
    // (building_massing.dart:140), so it is the SAME massing with the lane
    // pass skipped — the probe that says whether the lane half of this test
    // has anything to bite on.
    const shut = SiteGate(xM: 0, widthM: 0);
    var laneCleared = 0;
    for (final spec in kUtilCatalog.where((s) => s.claimsOwnSite)) {
      final parcel = plotFor(spec);
      final m = rules.massFor(spec, parcel, gate: gate);
      // Over EVERY staked installation, parking or not: the specs that put a
      // volume in the gate lane are exactly the ones that parked nothing, so
      // filtering by a car park made this vacuous.
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
    expect(laneCleared, greaterThan(3),
        reason: 'the installations whose gate lane the pass actually clears '
            '(9 today); without these the lane check above could never fail');
  });
}
