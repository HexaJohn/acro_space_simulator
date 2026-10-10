// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_control.dart';
import 'package:acro_space_simulator/domain/colony/city/city_reclaim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_catalog.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_builder_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_edit_overlay.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_map_view.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_site_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// The demolition ban (docs/plans/colony-secession.md §6.1) against the
/// edits that tear buildings down without the bulldozer: a road laid,
/// spline-committed, upgraded or re-laid by its end, and a plot staked for
/// an installation, each re-cut the lots, and a lot the re-cut gives up
/// loses its building (`city_term_guard.dart`). Each is tried on a town
/// bound by the ban — refused, the colony exactly as it was — and on the
/// same town unbound, where it does tear a building down: the control that
/// says the bound try was a real one.
void main() {
  const day = 120.0;

  /// A town of placed buildings, rich enough for any road, and — [bound] —
  /// rejoined on terms that forbid demolition.
  CitySim townOf({required bool bound}) {
    final city = town();
    run(city, 30);
    city
      ..funds = 1e9
      ..ignoreUnlocks = true
      ..stock[Commodity.ore] = 1e6;
    if (bound) {
      city.reclaim
        ..terms = const BindingTerms(taxCap: 0.25, noDemolition: true, days: 12)
        ..termsUntilS = city.colonyTimeS + 12 * day;
    }
    return city;
  }

  Set<String> built(CitySim c) =>
      {...c.parcelBuildings.keys, ...c.grownParcels.keys};

  /// Everything a road edit moves: the roads, the lots and their zoning, the
  /// buildings, the treasury, the attention stamp.
  String plat(CitySim c) => jsonEncode({
        'roads': [
          for (final r in c.layout.roads)
            '${r.id}|${r.roadClass.name}|${r.controls.map((p) => '${p.e},${p.n}').join(';')}',
        ],
        'lots': [for (final p in c.layout.parcels) '${p.id}|${p.use.name}'],
        'built': [...built(c)]..sort(),
        'funds': c.funds,
        'ore': c.stockOf(Commodity.ore),
        'attended': c.loyalty.attendedAtS,
      });

  /// No building keyed by a lot that is not there.
  void expectNoDangling(CitySim c) {
    for (final id in built(c)) {
      expect(
          CitySim.cellOfSiteId(id) != null || c.layout.parcelById(id) != null,
          isTrue,
          reason: '$id dangles');
    }
  }

  CityEditController editor(CitySim city) =>
      CityEditController()..gateCity = city;

  /// The first built street lot, in plat order.
  Parcel builtLot(CitySim city) => city.layout.autoParcels
      .firstWhere((p) => built(city).contains(p.id));

  /// A straight road across [builtLot].
  void roadThroughLot(CitySim city, CityEditController c) {
    final lot = builtLot(city);
    c.set(CityEditTool.roadSpline);
    c.setMode(RoadToolMode.straight);
    c.clickAt(city, lot.centroid - const Vec2(150, 0));
    c.clickAt(city, lot.centroid + const Vec2(150, 0));
  }

  test('a road laid through a built lot is refused, nothing moved', () {
    final free = townOf(bound: false);
    final had = built(free).length;
    roadThroughLot(free, editor(free));
    expect(built(free).length, lessThan(had),
        reason: 'the control: unbound, the road tears buildings down');
    expectNoDangling(free);

    final city = townOf(bound: true);
    final before = plat(city);
    final c = editor(city);
    roadThroughLot(city, c);
    expect(plat(city), before);
    expect(c.blocked, startsWith(city.demolitionRefusal!));
    expect(c.blocked, contains('This would tear down'));
  });

  test('the refused edit leaves the plat exactly as an untried one', () {
    // A refused edit then an allowed one, against the allowed one alone:
    // the same roads, ids, lots and buildings — the trial put back every
    // counter the re-cut moved, so nothing after it is cut differently.
    void allowed(CitySim city) {
      final c = editor(city)
        ..set(CityEditTool.roadSpline)
        ..setMode(RoadToolMode.straight);
      c.clickAt(city, const Vec2(3000, 3000));
      c.clickAt(city, const Vec2(3300, 3000));
      expect(c.blocked, isNull, reason: 'clears nothing: allowed');
    }

    final tried = townOf(bound: true);
    roadThroughLot(tried, editor(tried));
    final roads = tried.layout.roads.length;
    allowed(tried);
    expect(tried.layout.roads.length, greaterThan(roads),
        reason: 'a road that tears nothing down builds under the terms');
    final untried = townOf(bound: true);
    allowed(untried);
    // The attention stamp is the same tick in both.
    expect(plat(tried), plat(untried));
  });

  test('a spline committed through built lots is refused, points kept', () {
    final city = townOf(bound: true);
    final lot = builtLot(city);
    final before = plat(city);
    final c = editor(city)..set(CityEditTool.roadSpline);
    c
      ..addSplinePoint(lot.centroid - const Vec2(150, 10))
      ..addSplinePoint(lot.centroid)
      ..addSplinePoint(lot.centroid + const Vec2(150, 10));
    c.commitSpline(city);
    expect(plat(city), before);
    expect(c.pending, hasLength(3), reason: 'refused, the points are kept');
    expect(c.blocked, startsWith(city.demolitionRefusal!));
  });

  test('Adjust: re-laying a road off its lots is refused', () {
    void drag(CitySim city, CityEditController c) {
      final road = city.layout.roads.first;
      final a = road.controls.first, b = road.controls.last;
      c.set(CityEditTool.traffic);
      c.selectRoad(road.id);
      c.moveSelectedEnd(city, atStart: false, to: a + (b - a) * 0.25);
    }

    final free = townOf(bound: false);
    final had = built(free).length;
    drag(free, editor(free));
    expect(built(free).length, lessThan(had), reason: 'the control');

    final city = townOf(bound: true);
    final before = plat(city);
    final c = editor(city);
    drag(city, c);
    expect(plat(city), before);
    expect(c.blocked, startsWith(city.demolitionRefusal!));
  });

  test('Upgrade under the terms: built if it clears nothing, never a lot',
      () {
    final city = townOf(bound: true);
    final had = built(city);
    final road = city.layout.roads.first;
    final mid = (road.controls.first + road.controls.last) * 0.5;
    final c = editor(city)
      ..set(CityEditTool.roadSpline)
      ..setMode(RoadToolMode.upgrade)
      ..roadType = RoadType.byId('six-lane-trees')!;
    final q = c.upgradeAt(city, mid);
    expect(built(city), had);
    expectNoDangling(city);
    if (q == null) {
      expect(c.blocked, startsWith(city.demolitionRefusal!));
    } else {
      expect(q.ok, isTrue, reason: q.reason);
    }
  });

  test('a plot staked over a built lot is refused', () {
    // Every free lot built on, so a plot near the streets covers one.
    CitySim kit({required bool bound}) {
      final city = starterKit();
      run(city, 30);
      final water = kUtilCatalog.firstWhere((s) => s.type == 'water');
      for (final lot in freeLots(city)) {
        city.placeOnParcel(lot.id, water);
      }
      city
        ..funds = 1e9
        ..stock[Commodity.ore] = 1e6;
      if (bound) {
        city.reclaim
          ..terms = const BindingTerms(noDemolition: true, days: 12)
          ..termsUntilS = city.colonyTimeS + 12 * day;
      }
      return city;
    }

    final farm = kUtilCatalog.firstWhere((s) => s.label == 'Farm');
    // A centre the farm may claim whose plot covers a built lot's middle.
    Vec2? over(CitySim city) {
      for (final id in [...city.parcelBuildings.keys]..sort()) {
        final lot = city.layout.parcelById(id);
        if (lot == null) continue;
        for (var dx = -200.0; dx <= 200; dx += 25) {
          for (var dy = -200.0; dy <= 200; dy += 25) {
            final p = lot.centroid + Vec2(dx, dy);
            if (city.siteBlockedReason(farm, p) != null) continue;
            final foot = Parcel(id: 'probe', polygon: city.siteFootprint(farm, p));
            if (foot.contains(lot.centroid)) return p;
          }
        }
      }
      return null;
    }

    final free = kit(bound: false);
    final at = over(free);
    expect(at, isNotNull, reason: 'a plot over a built lot exists');
    final had = free.parcelBuildings.length;
    final cf = editor(free)..selectedUtil = farm;
    expect(cf.claimOwnSite(free, at!), isTrue, reason: '${cf.blocked}');
    expect(free.parcelBuildings.length, lessThanOrEqualTo(had),
        reason: 'the control: the farm took a built lot (and was added)');
    expectNoDangling(free);

    final city = kit(bound: true);
    final before = plat(city);
    final c = editor(city)..selectedUtil = farm;
    expect(c.claimOwnSite(city, at), isFalse);
    expect(plat(city), before);
    expect(c.blocked, startsWith(city.demolitionRefusal!));
  });

  testWidgets('the meltdown row is refused as Demolish is', (t) async {
    t.view.physicalSize = const Size(1200, 2000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final city = starterKit();
    run(city, 30);
    city.stock[Commodity.ore] = 1e6;
    final reactor = kUtilCatalog.firstWhere((s) => s.type == 'reactor');
    final lot = freeLots(city)
        .firstWhere((p) => city.placeOnParcel(p.id, reactor))
        .id;
    city.reclaim
      ..terms = const BindingTerms(taxCap: 0.1, noDemolition: true, days: 12)
      ..termsUntilS = city.colonyTimeS + 12 * day;
    final reason = city.demolitionRefusal!;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showCitySiteMenu(
                context: ctx,
                sim: city,
                site: lot,
                spec: reactor,
                onChanged: () {},
                hooks: const CitySiteHooks()),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    final rows = {
      for (final tile in t.widgetList<ListTile>(find.descendant(
          of: find.byType(BottomSheet), matching: find.byType(ListTile))))
        (tile.title! as Text).data!: (tile.subtitle! as Text).data!,
    };
    // Every row that tears the reactor down carries the term.
    for (final label in ['Demolish', 'Disable safety systems']) {
      expect(rows[label], reason, reason: label);
    }
    await t.tap(find.text('Disable safety systems').last);
    await t.pumpAndSettle();
    expect(city.siteSpec(lot)?.type, 'reactor');
    expect(city.disaster, Disaster.none);
  });

  testWidgets('the flat builder: a road is not removed by another tool',
      (t) async {
    t.view.physicalSize = const Size(1600, 1200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final city = starterKit();
    run(city, 30);
    final g = city.grid;
    final hy = city.hubKey ~/ g;
    final x = (city.hubKey % g + 3) % g;
    final k = city.key(x, hy);
    city
      ..addRoad(k)
      ..recompute();
    city.reclaim
      ..terms = const BindingTerms(noDemolition: true, days: 12)
      ..termsUntilS = city.colonyTimeS + 12 * day;
    await t.pumpWidget(MaterialApp(
        home: CityBuilderScreen(sim: city, driveLocally: false)));
    await t.pump();
    final driver =
        t.state(find.byType(CityBuilderScreen)) as CityBuilderToolDriver;
    // A tap, a paint and the debug driver's every way, one by one: a paint
    // re-laying the road a tap took away would hide the tap.
    for (final tool in [
      CityBuilderTool.road,
      CityBuilderTool.zone,
      CityBuilderTool.support,
    ]) {
      // A platform tool only where the world has no ground to stand on.
      final chip = find.byKey(ValueKey('builder-tool-${tool.name}'));
      if (chip.evaluate().isEmpty) continue;
      await t.tap(chip);
      await t.pump();
      final map = t.widget<CityMapView>(find.byType(CityMapView));
      map.onTapCell(x, hy);
      await t.pump();
      expect(city.roads.contains(k), isTrue, reason: '${tool.name} tap');
      map.onPaintCell?.call(x, hy);
      await t.pump();
      expect(city.roads.contains(k), isTrue, reason: '${tool.name} paint');
    }
    for (final tool in [
      CityBuilderTool.road,
      CityBuilderTool.zone,
      CityBuilderTool.support,
      CityBuilderTool.bulldoze,
    ]) {
      driver.debugUseTool(tool, x, hy);
      await t.pump();
      expect(city.roads.contains(k), isTrue, reason: '${tool.name} on a road');
    }
    expect(city.blocked, city.demolitionRefusal);
    // Laying a road where there is none still goes ahead.
    final empty = city.key(x, (hy + 3) % g);
    if (city.anchorOf(empty) == null && !city.roads.contains(empty)) {
      driver.debugUseTool(CityBuilderTool.road, x, (hy + 3) % g);
      await t.pump();
      expect(city.roads.contains(empty), isTrue);
    }
    await t.pump(const Duration(seconds: 4));
    await t.pumpWidget(const SizedBox());
  });
}
