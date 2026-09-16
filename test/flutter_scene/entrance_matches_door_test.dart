// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// R4 track B: the DRAWN door is the plan's door (docs/plans/site-access.md
/// §6.1 step 5, §6.2, §8.3 R4 `entrance_matches_door_test`).
///
/// The plan runs its footpath to a door on the envelope's front edge (the
/// gate, on an installation) and the traffic side walks its agents to the
/// same point, so the building the renderer draws has to put its entrance
/// there. Centring the footprint in the buildable strip does not: it leaves
/// the entrance `(1 − coverD)/2 · buildD` behind the front edge — metres on a
/// house, tens of metres on an installation — which is why a plan-served
/// massing is FRONT-ALIGNED and its instance is shifted back by the
/// bucketing slack.
///
/// Tolerance 0.5 m, and it is the archetype's: the mesh is shared by every
/// building that keys to it, so the gate it is cut with is quantised to the
/// metre (±0.5 m) — while the depth bucket, up to 3 m of it, is taken out
/// exactly by the instance shift.
library;

import 'package:acro_space_simulator/application/snapshot/city_site_frame.dart';
import 'package:acro_space_simulator/domain/architecture/architecture_style.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

import '../application/site_town_fixture.dart';
import 'site_envelope_fixture.dart';

void main() {
  late CitySim city;

  setUpAll(() => city = envelopeTown());

  // Put the knob back the way this suite found it, never to a hard-coded
  // value: the production default is ON, and restoring OFF would hide a
  // regression in the default path from every test that runs after.
  late bool wasPlacement;
  setUp(() => wasPlacement = SiteCapture.envelopePlacement);
  tearDown(() => SiteCapture.envelopePlacement = wasPlacement);

  for (final style in ArchitectureStyle.kits) {
    test('${style.id}: every drawn door lands on its plan\'s door', () {
      final scene = EnvelopeScene.of(city, style);
      final seen = <String>{};
      var bucketed = 0, checked = 0;
      for (final b in scene.buildings) {
        final plan = scene.planOf(b);
        if (plan == null) continue;
        final door = plan.entrancePt;
        if (door < 0 || door >= plan.pointCount) continue;
        checked++;
        seen.add(b.type);
        final built = scene.builtOf(b);
        final (ex, ey) = built.massing.entrance;
        final drawn = scene.drawn(b, ex, ey);
        final want = Vec2(plan.ptE(door), plan.ptN(door));
        expect(drawn.distanceTo(want), lessThan(0.5),
            reason: '${b.id} (${b.type}): the drawn door is '
                '${drawn.distanceTo(want).toStringAsFixed(2)} m from the '
                'plan\'s');
        // The min-fit bucket really does move: count the buildings whose
        // mesh was generated against a depth that is not their envelope's.
        final depth = b.siteDepthM + style.frontSetbackM + style.rearSetbackM;
        if ((BuildingArchetype.bucketOf(depth, 6, minFit: true) * 6 - depth)
                .abs() >
            0.05) {
          bucketed++;
        }
      }
      expect(checked, greaterThan(100));
      expect(bucketed, greaterThan(10),
          reason: 'the bucketed cases are the ones the instance shift is '
              'for');
      // The four the slice names, plus the homes: r-low, c-low, i-med and
      // the starter kit's aquifer.
      expect(seen, containsAll(<String>['r-low', 'c-low', 'i-med', 'aquifer']));
    });
  }

  test('the legacy path leaves its door where it was', () {
    // The same buildings with the knob OFF: the entrance sits behind the
    // front edge, exactly as it did before R4 — which is what makes the
    // check above a change and not a tautology.
    SiteCapture.envelopePlacement = false;
    final scene =
        EnvelopeScene(city, captureSiteTown(city), ArchitectureStyle.utilitarian);
    var behind = 0, checked = 0;
    for (final b in scene.buildings) {
      final plan = scene.planOf(b);
      if (plan == null || b.type != 'r-low') continue;
      checked++;
      final built = scene.legacyBuiltOf(b);
      final (_, ey) = built.massing.entrance;
      final front = -(b.siteDepthM + scene.style.frontSetbackM) / 2;
      if ((ey - front).abs() > 0.5) behind++;
    }
    expect(checked, greaterThan(10));
    expect(behind, checked,
        reason: 'the legacy massing centres its footprint in the strip');
  });
}
