// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// R4 track B: a plan-served building stands on its plan's ENVELOPE, in the
/// plan's own axes (docs/plans/site-access.md §3.1, §5.2, §6.1, §8.3 R4
/// `envelope_axes_test`).
///
/// The envelope, the gate and the door are computed in the site frame, so
/// spinning the building by `−SiteFrame.buildingHeading` makes them its own
/// local axes: local +X on the frame's `u`, local +Y on `v`. Get that wrong
/// by a quarter turn and the gate gap in the fence opens on a side with no
/// road behind it, while the site's width and depth swap over.
///
/// The two cases only R4 can turn (§10.2 Q10) are here by name: a claimed
/// plot with NO stored frontage, and a grid cell whose stored north edge is
/// fake. Both keep `Parcel.facing` on the legacy path, and both turn to the
/// road their plan found once the knob is on.
library;

import 'package:acro_space_simulator/application/snapshot/city_site_frame.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/architecture/architecture_style.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

import '../application/site_town_fixture.dart';
import 'site_envelope_fixture.dart';

void main() {
  const style = ArchitectureStyle.masonryStreet;
  late CitySim city;
  late EnvelopeScene scene;

  setUpAll(() {
    city = envelopeTown();
    scene = EnvelopeScene.of(city, style);
  });

  // Put the knob back the way this suite found it, never to a hard-coded
  // value: the production default is ON, and restoring OFF would hide a
  // regression in the default path from every test that runs after.
  late bool wasPlacement;
  setUp(() => wasPlacement = SiteCapture.envelopePlacement);
  tearDown(() => SiteCapture.envelopePlacement = wasPlacement);

  test('every served building takes its plan\'s axes and envelope', () {
    var served = 0, turned = 0;
    for (final b in scene.buildings) {
      final plan = scene.planOf(b);
      if (plan == null) continue;
      served++;
      final (x, y) = scene.axesOf(b);
      final u = Vec2(plan.frameUE, plan.frameUN);
      final v = Vec2(plan.frameVE, plan.frameVN);
      expect(x.dot(u), greaterThan(0.99),
          reason: '${b.id}: local +X must run along the frame\'s u');
      expect(y.dot(v), greaterThan(0.99),
          reason: '${b.id}: local +Y must run into the lot, along v');
      // And it stands ON the envelope: it is placed at the envelope centre.
      final centre = scene.positionOf(b);
      final want = Vec2(
        plan.frameE +
            u.e * (plan.envX0 + plan.envX1) / 2 +
            v.e * (plan.envY0 + plan.envY1) / 2,
        plan.frameN +
            u.n * (plan.envX0 + plan.envX1) / 2 +
            v.n * (plan.envY0 + plan.envY1) / 2,
      );
      expect(centre.distanceTo(want), lessThan(0.01), reason: b.id);
      expect(b.siteWidthM, closeTo(plan.envX1 - plan.envX0, 1e-3));
      expect(b.siteDepthM, closeTo(plan.envY1 - plan.envY0, 1e-3));
      final parcel = city.layout.parcelById(scene.siteIdOf(b));
      if (parcel?.frontage == null) turned++;
    }
    expect(served, greaterThan(100));
    expect(turned, greaterThan(0),
        reason: 'the fixture carries sites with no stored frontage');
  });

  test('a frontage-less plot and a grid cell turn to the road they front',
      () {
    final ids = [envelopeClaimedId!, CitySim.siteIdOfCell(envelopeCell!)];
    for (final id in ids) {
      final plan = city.siteAccess.planOf(id);
      expect(plan, isNotNull, reason: '$id has a plan');
      final b = scene.buildings.firstWhere((b) => scene.siteIdOf(b) == id);
      expect(b.siteSlot, greaterThanOrEqualTo(0));
      final (x, y) = scene.axesOf(b);
      expect(x.dot(Vec2(plan!.frameUE, plan.frameUN)), greaterThan(0.99),
          reason: id);
      expect(y.dot(Vec2(plan.frameVE, plan.frameVN)), greaterThan(0.99),
          reason: id);
      // The turn is REAL: the legacy path (no stored frontage, so
      // `Parcel.facing` is the polygon's default) faces somewhere else.
      final legacy = _legacyFacing(city, id);
      final street = Vec2(0.0 - plan.frameVE, 0.0 - plan.frameVN);
      expect(legacy, isNotNull, reason: id);
      expect(street.dot(legacy!), lessThan(0.99),
          reason: '$id: the plan found a road the lot does not face');
    }
  });

  test('the massing\'s gate gap lies on the plan\'s gate edge', () {
    var checked = 0, cut = 0, fenced = 0;
    for (final b in scene.buildings) {
      final plan = scene.planOf(b);
      if (plan == null || !(plan.gateW > 0)) continue;
      checked++;
      final gate = scene.gateOf(b)!;
      expect(gate.isOpen, isTrue);
      // The gate stands where the plan put it: on the envelope's front edge,
      // to within the metre the archetype key quantises it to.
      final drawn = scene.drawn(b, gate.xM, scene.frontEdgeOf(b));
      final u = Vec2(plan.frameUE, plan.frameUN);
      final v = Vec2(plan.frameVE, plan.frameVN);
      final want = Vec2(
        plan.frameE + u.e * plan.gateX + v.e * plan.envY0,
        plan.frameN + u.n * plan.gateX + v.n * plan.envY0,
      );
      expect(drawn.distanceTo(want), lessThan(0.05), reason: b.id);

      // And the volumes leave it open: nothing stands in the gate lane, and
      // the fence run that crossed it is CUT rather than deleted. The MESH
      // is shared by every building keying to it, so its lane is the gate
      // quantised to the metre — within half a metre of the plan's own.
      final canon = BuildingArchetype.gateOfBucket(
          BuildingArchetype.gateBucketOf(gate),
          surfaceParking: false)!;
      expect((canon.xM - gate.xM).abs(), lessThanOrEqualTo(0.5), reason: b.id);
      expect((canon.widthM - gate.widthM).abs(), lessThanOrEqualTo(0.5),
          reason: b.id);
      final built = scene.builtOf(b);
      final y0 = scene.frontEdgeOf(b);
      for (final vol in built.massing.volumes) {
        final inLane =
            vol.x - vol.width / 2 < canon.xM + canon.widthM / 2 - 0.2 &&
                vol.x + vol.width / 2 > canon.xM - canon.widthM / 2 + 0.2 &&
                vol.y - vol.depth / 2 < y0 + 11.8 &&
                vol.y + vol.depth / 2 > y0 + 0.2;
        expect(inLane, isFalse,
            reason: '${b.id}: a volume stands in the gate lane');
      }
      // Where there IS a fence line across the front, the gap is cut in it
      // exactly at the gate: a run ends on one edge of the lane, and
      // (unless the gate is at a corner) another starts on the other.
      double? front;
      for (final vol in built.massing.volumes) {
        if (vol.depth > 1.0 || vol.width < 2 || vol.floors != 0) continue;
        if (vol.y - vol.depth / 2 > y0 + 12 || vol.y + vol.depth / 2 < y0) {
          continue;
        }
        final x0 = vol.x - vol.width / 2, x1 = vol.x + vol.width / 2;
        if ((x1 - (canon.xM - canon.widthM / 2)).abs() < 1e-6 ||
            (x0 - (canon.xM + canon.widthM / 2)).abs() < 1e-6) {
          cut++;
          final f = front;
          if (f == null || vol.y - vol.depth / 2 < f) {
            front = vol.y - vol.depth / 2;
          }
        }
      }
      // ...and that run stands ON the plan's fence line, not a few metres
      // inside it: §3.7 step 9 puts gate node G on `envY0`, where the access
      // road ends, so the gap and the end of the drive are the same place.
      // The run is laid with its OUTER FACE on the line (it has to be, or its
      // own thickness would stand outside the envelope), so the face is the
      // number pinned here, to the 0.05 m the gate point above is pinned to.
      final f = front;
      if (f != null) {
        fenced++;
        final at = scene.drawn(b, gate.xM, f);
        final into =
            (at.e - plan.frameE) * v.e + (at.n - plan.frameN) * v.n;
        expect(into, closeTo(plan.envY0, 0.05),
            reason: '${b.id}: the cut fence run stands off the plan\'s '
                'fence line');
      }
    }
    expect(checked, greaterThanOrEqualTo(4),
        reason: 'the starter kit\'s four installations have gates');
    expect(cut, greaterThanOrEqualTo(1),
        reason: 'a fence run across the front is CUT at the gate, not '
            'deleted');
    expect(fenced, greaterThanOrEqualTo(3),
        reason: 'the solar farm, the aquifer and the spaceport all fence '
            'their frontage');
  });

  test('a plan with no envelope is legacy on both sides of the knob', () {
    final id = envelopeNoEnvelopeId;
    expect(id, isNotNull, reason: 'the fixture stakes a narrow-frontage lot');
    // The plan IS published — it just has nothing to stand on.
    final plan = city.siteAccess.planOf(id!);
    expect(plan, isNotNull);
    expect(plan!.envX1 - plan.envX0, 0);
    expect(plan.envY1 - plan.envY0, 0);
    expect(city.siteAccess.slotOf(id), greaterThanOrEqualTo(0));

    final b = scene.buildings.firstWhere((b) => b.id == id);
    // So the wire says legacy...
    expect(b.siteSlot, -1,
        reason: 'an empty envelope is not a site to stand on');
    // ...the renderer agrees (one predicate, not two: a building DRAWN
    // plan-served but PLACED the legacy way stands beside its own
    // driveway)...
    expect(scene.gateOf(b), isNull);
    // ...and it is placed exactly where the legacy path puts it.
    final parcel = city.layout.parcelById(id)!;
    final legacy = BuildingSnapshot.ofParcel(
        city, parcel, city.parcelBuildings[id]!, city.body,
        siteRadiusM: city.groundCache['lot:$id']!.radius);
    expect(b.px, legacy.px);
    expect(b.py, legacy.py);
    expect(b.qw, legacy.qw);
    expect(b.siteWidthM, legacy.siteWidthM);
    expect(b.siteDepthM, legacy.siteDepthM);
  });

  test('with the knob off every served building is placed the legacy way',
      () {
    SiteCapture.envelopePlacement = false;
    final off = captureSiteTown(city);
    var moved = 0;
    for (final b in off.buildings.values) {
      if (b.colonyId != city.id) continue;
      final parcel = city.layout.parcelById(b.id);
      if (parcel == null) continue;
      final legacy = BuildingSnapshot.ofParcel(
          city, parcel, city.parcelBuildings[b.id]!, city.body,
          siteRadiusM: city.groundCache['lot:${b.id}']!.radius);
      expect(b.px, legacy.px, reason: b.id);
      expect(b.py, legacy.py, reason: b.id);
      expect(b.pz, legacy.pz, reason: b.id);
      expect(b.qw, legacy.qw, reason: b.id);
      expect(b.qx, legacy.qx, reason: b.id);
      expect(b.qy, legacy.qy, reason: b.id);
      expect(b.qz, legacy.qz, reason: b.id);
      expect(b.siteWidthM, legacy.siteWidthM, reason: b.id);
      expect(b.siteDepthM, legacy.siteDepthM, reason: b.id);
      // ...and the slot and gate still ride the wire, as R3 left them —
      // except on a plan with no envelope, which is legacy either way (see
      // 'a plan with no envelope is legacy on both sides of the knob').
      final plan = city.siteAccess.planOf(b.id);
      final slot = plan == null ||
              plan.envX1 - plan.envX0 <= 0 ||
              plan.envY1 - plan.envY0 <= 0
          ? -1
          : city.siteAccess.slotOf(b.id);
      expect(b.siteSlot, slot, reason: b.id);
      final on = scene.buildings.firstWhere((x) => x.id == b.id);
      if (on.px != b.px || on.py != b.py || on.pz != b.pz) moved++;
    }
    expect(moved, greaterThan(50),
        reason: 'the knob is what moves them, and it moves most of them');
  });

  // R4 review: these suites used to put the knob back to a hard-coded OFF,
  // which stopped being the default at 'the sites are drawn by default'. A
  // test that runs after one of them would then read the knob OFF while
  // production reads it ON, and a regression in the default path would go
  // unseen. Declared LAST on purpose: it is the one that would have been
  // handed the wrong value.
  test('every case here starts from production\'s own knob, and the fixture '
      'gives it back', () {
    expect(SiteCapture.envelopePlacement, isTrue,
        reason: 'the production default (§9 "R4 as built"), not what the '
            'case before this one happened to leave behind');
    EnvelopeScene.of(city, style);
    expect(SiteCapture.envelopePlacement, isTrue,
        reason: 'the fixture restores what it found, it does not force off');
    SiteCapture.envelopePlacement = false;
    EnvelopeScene.of(city, style);
    expect(SiteCapture.envelopePlacement, isFalse,
        reason: 'and it gives an OFF caller its OFF back');
  });
}

/// The direction the LEGACY path faces [id] in, or null when it is a cell.
Vec2? _legacyFacing(CitySim city, String id) {
  final cell = CitySim.cellOfSiteId(id);
  if (cell != null) {
    // A cell fronts its fake north edge, so the legacy street side is north.
    return const Vec2(0, 1);
  }
  final parcel = city.layout.parcelById(id);
  return parcel?.facing;
}
