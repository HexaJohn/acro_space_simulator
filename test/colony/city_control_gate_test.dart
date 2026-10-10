// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_control.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_builder_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_control_ui.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_edit_overlay.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_game_hud.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_site_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// The control gate (docs/plans/colony-secession.md §5, phase 2): on an
/// independent colony every tool and lever the player has is greyed or
/// refuses, and the colony is exactly as it was after the player has tried
/// every one of them.
///
/// The sweeps ENUMERATE what they try — the editor's tools, the road tool's
/// modes and info views, the flat builder's tools, every row of the site
/// sheet, every government, economy and law — rather than listing the
/// controls of today, so a tool added tomorrow is tried too, and fails here
/// if it reaches the colony around the gate.
void main() {
  /// Everything a player act could move, as one string: the save (which
  /// carries the loyalty clock, so a refused act that still stamped
  /// attention shows up), and what the save leaves out.
  String fingerprint(CitySim c) => jsonEncode({
        'save': c.toJson(),
        'deliveries': {
          for (final e in c.deliveries.entries)
            e.key: [
              for (final s in e.value)
                '${s.resource}|${s.intervalSec}|${s.amount}|${s.padIndex}|'
                    '${s.recurring}|${s.spareFuel}|${s.timer}',
            ],
        },
        'lander': c.landerPad,
        'flag': c.flagPlanted,
        'relief': c.terrainRelief,
        'scatter': c.scatter.length,
        'craft': c.craft.length,
        'reliefCooldown': c.reliefCooldown,
        'disaster': c.disaster.index,
        'radiation': c.radiation,
        'junctions': c.junctionOverrides.length,
        'zones': c.zones.length,
      });

  String portOf(CitySim city) => city.landingPads().first.$1.id;

  /// A centre [spec] could stake its own plot at on [city] — beside a road,
  /// clear of everything — so a refused claim there is the gate's refusal
  /// and nothing else's.
  Vec2 openSite(CitySim city, CityBuildingSpec spec) {
    for (var r = 100.0; r < 3000; r += 50) {
      for (var a = 0; a < 24; a++) {
        final p = Vec2(r * math.cos(a * math.pi / 12),
            r * math.sin(a * math.pi / 12));
        if (city.siteBlockedReason(spec, p) == null) return p;
      }
    }
    throw TestFailure('no open site for ${spec.label}');
  }

  /// A connected grid spaceport on [city]'s cell map, the flat builder's
  /// own kind of site (a lot's spaceport opens no sheet there): a road row
  /// through the hub and the port beside it. Its anchor.
  int gridPort(CitySim city) {
    final port = kUtilCatalog.firstWhere((s) => s.type == 'spaceport');
    final g = city.grid;
    final hy = city.hubKey ~/ g;
    for (var x = 0; x < g; x++) {
      final k = hy * g + x;
      if (k != city.hubKey) city.addRoad(k);
    }
    for (var x = 0; x < g; x++) {
      if (!city.footprintFree(x, hy + 1, port)) continue;
      final anchor = city.key(x, hy + 1);
      city.placeUtil(anchor, port);
      city.recompute();
      if (city.siteConnected(CitySim.siteIdOfCell(anchor))) return anchor;
      city.clearCell(anchor, keepSupport: true);
      city.recompute();
    }
    throw TestFailure('no connected cell for a grid spaceport');
  }

  /// The rows of the site sheet open on screen: title and subtitle.
  List<(String, String)> sheetRows(WidgetTester t) => [
        for (final tile in t.widgetList<ListTile>(find.descendant(
            of: find.byType(BottomSheet), matching: find.byType(ListTile))))
          ((tile.title! as Text).data!, (tile.subtitle! as Text).data!),
      ];

  /// Rows the gate deliberately leaves live: a readout, the player's own
  /// craft, and the delivery book (readable; its edits are gated inside).
  bool ungatedRow(String label) =>
      label == 'Details' ||
      label == 'Target this pad' ||
      label.toLowerCase().contains('deliveries');

  /// A starter colony with something of everything on it — free and built
  /// lots, a junction, a spaceport with a delivery booked, an autocrat's
  /// hand-voted laws — that has just declared independence.
  CitySim independent() {
    final city = starterKit();
    run(city, 30);
    city
      ..govt = Govt.autocracy
      ..laws.add(Law.curfew);
    city.deliveries[portOf(city)] = [
      DeliverySchedule(
          resource: Commodity.food, intervalSec: 30, amount: 200, timer: 30)
        ..recurring = true,
    ];
    city.loyalty
      ..allegiance = Allegiance.independent
      ..stage = LoyaltyStage.seceded
      ..independentAtS = city.colonyTimeS
      ..independenceCauses = '3 revolts in 15 days';
    return city;
  }

  test('the gate: refused for an independent colony, allowed otherwise', () {
    final city = starterKit();
    expect(city.playerControl.allowed, isTrue);
    city.loyalty.allegiance = Allegiance.occupied;
    expect(city.playerControl.allowed, isTrue,
        reason: 'occupation is phase 4\'s to restrict');
    city.loyalty
      ..allegiance = Allegiance.independent
      ..independentAtS = 5 * 120.0;
    final c = city.playerControl;
    expect(c.allowed, isFalse);
    expect(c.reason, contains('independent since day 6'));
    // A standing-off colony strikes, but still takes orders (§3.5).
    final standoff = starterKit()..loyalty.stage = LoyaltyStage.standoff;
    expect(standoff.playerControl.allowed, isTrue);
  });

  test('every editor tool, road mode and info view refuses', () {
    final city = independent();
    city.stock[Commodity.ore] = 1000; // every claim affordable
    final farm = kUtilCatalog.firstWhere((s) => s.label == 'Farm');
    final open = openSite(city, farm);
    final reason = city.playerControl.reason!;
    final before = fingerprint(city);
    final c = CityEditController()..gateCity = city;
    final free = freeLots(city).first.id;
    final built = city.parcelBuildings.keys.first;
    final road = city.layout.roads.first;
    final a = road.controls.first, b = road.controls.last;
    final mid = (a + b) * 0.5;

    for (final t in CityEditTool.values) {
      c.set(t);
      if (t.acts) {
        expect(c.tool, isNot(t), reason: '${t.name} picked up');
        expect(c.blocked, reason);
      }
      // Held anyway — as a colony that seceded while the tool was in hand.
      c.tool = t;
      for (final lot in [free, built]) {
        c.applyToLot(city, lot);
        c.applyToParcel(city, lot);
      }
      for (final cell in [0, city.hubKey + 1, city.grid * city.grid - 1]) {
        c.applyTo(city, cell);
      }
      c.pickUtil(kUtilCatalog.first);
      c.pickZone('commercial', Density.high);
      // The sprawling installation's own plot, staked off the tap.
      c.selectedUtil = farm;
      expect(c.claimOwnSite(city, open), isFalse);
      expect(fingerprint(city), before, reason: 'tool ${t.name}');
    }

    for (final m in RoadToolMode.values) {
      c
        ..tool = CityEditTool.roadSpline
        ..setMode(m);
      for (final p in [
        const Vec2(500, 500),
        const Vec2(500, 700),
        const Vec2(650, 800),
        mid,
      ]) {
        c.clickAt(city, p);
      }
      c.rightClickAt(city, mid);
      c
        ..addSplinePoint(const Vec2(-500, 500))
        ..addSplinePoint(const Vec2(-500, 900));
      c.commitSpline(city);
      expect(fingerprint(city), before, reason: 'road mode ${m.name}');
    }

    c.tool = CityEditTool.traffic;
    for (final v in TrafficInfoView.values) {
      c
        ..setTrafficView(v)
        ..selectRoad(road.id);
      c.toggleJunctionAt(city, const Vec2(0, 0));
      c.toggleJunctionAt(city, const Vec2(0, 20));
      c.moveSelectedEnd(city, atStart: true, to: a + const Vec2(30, 30));
      c.renameSelected(city, 'Rebel Road');
      c.upgradeAt(city, mid);
      c.reverseAt(city, mid);
      expect(fingerprint(city), before, reason: 'traffic view ${v.name}');
    }
    expect(c.blocked, reason, reason: 'and said why');

    // The claim was refused by the gate and nothing else: the same claim
    // on the colony taking orders again builds.
    city.loyalty.allegiance = Allegiance.colonial;
    c.selectedUtil = farm;
    expect(c.claimOwnSite(city, open), isTrue, reason: '${c.blocked}');
  });

  test('opening the editor asks the gate about the colony being opened', () {
    final indep = independent();
    final colonial = starterKit();
    final c = CityEditController()..gateCity = indep;
    c.set(CityEditTool.zone);
    expect(c.blocked, indep.playerControl.reason);
    // A colonial colony opened after the independent one: its own tool,
    // and not the other's refusal.
    c.enter(colonial, CityEditTool.zone);
    expect(c.gateCity, same(colonial));
    expect(c.tool, CityEditTool.zone);
    expect(c.blocked, isNull);
    // An independent one opened after a colonial one: no greyed tool held.
    c.enter(indep, CityEditTool.zone);
    expect(c.tool, CityEditTool.inspect);
    expect(c.blocked, isNull);
    c.enter(colonial, CityEditTool.zone);
    expect(c.tool, CityEditTool.zone);
  });

  testWidgets('the in-world toolbar greys its tools and the panels refuse',
      (t) async {
    t.view.physicalSize = const Size(1800, 2600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final city = independent();
    final reason = city.playerControl.reason!;
    final before = fingerprint(city);
    final c = CityEditController();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CityEditOverlay(controller: c, city: city, onClose: () {}),
      ),
    ));

    var chips = 0;
    for (final tool in CityEditTool.values.where((x) => x.acts)) {
      final chip = find.byKey(ValueKey('city-tool-${tool.name}'));
      if (chip.evaluate().isEmpty) continue; // not on this toolbar
      chips++;
      expect(
          find.ancestor(
              of: chip,
              matching: find.byWidgetPredicate(
                  (w) => w is Tooltip && w.message == reason)),
          findsOneWidget,
          reason: '${tool.name} greyed with the reason');
      await t.tap(chip, warnIfMissed: false);
      await t.pump();
      expect(c.tool, CityEditTool.inspect, reason: '${tool.name} refused');
      expect(find.text(reason), findsOneWidget,
          reason: 'the blocked line says why');
    }
    expect(chips, greaterThanOrEqualTo(4));

    // Politics: every government, every law.
    await t.tap(find.text('Politics'));
    await t.pumpAndSettle();
    expect(find.text('Independent since day 1'), findsWidgets);
    expect(find.text('RECLAIM'), findsOneWidget);
    for (final g in Govt.values) {
      await t.tap(find.text(g.label).first, warnIfMissed: false);
      await t.pump();
    }
    final switches = t.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches, isNotEmpty, reason: "an autocrat's laws are switches");
    for (final s in switches) {
      expect(s.onChanged, isNull, reason: 'a law switch left live');
    }
    expect(fingerprint(city), before, reason: 'government');

    // City: every economy, and the tax.
    await t.tap(find.text('City'));
    await t.pumpAndSettle();
    for (final e in Economy.values) {
      await t.tap(find.text(e.label).first, warnIfMissed: false);
      await t.pump();
    }
    final sliders = t.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders, isNotEmpty);
    for (final s in sliders) {
      expect(s.onChanged, isNull, reason: 'the tax slider left live');
    }
    expect(fingerprint(city), before, reason: 'economy');
  });

  testWidgets('the city game HUD: readouts live, tax greyed, the panel up',
      (t) async {
    t.view.physicalSize = const Size(1600, 1200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final city = independent();
    final before = fingerprint(city);
    await t.pumpWidget(
        MaterialApp(home: Scaffold(body: CityGameHud(city: city))));
    await t.pump();
    expect(find.text(IndependencePanel.headline(city)), findsOneWidget);
    expect(find.textContaining('3 revolts in 15 days'), findsOneWidget,
        reason: 'the causes it left for');
    expect(find.textContaining('Pop'), findsWidgets, reason: 'readouts stay');
    await t.tap(find.text('Budget'));
    await t.pump();
    final slider = t.widget<Slider>(find.byType(Slider));
    expect(slider.onChanged, isNull);
    // The chip opens the full panel, with the way back to come.
    await t.tap(find.text('Independent'));
    await t.pumpAndSettle();
    expect(find.text('RECLAIM'), findsOneWidget);
    expect(find.byKey(const ValueKey('independence-reclaim')), findsOneWidget);
    expect(find.textContaining('phase'), findsNothing,
        reason: 'no roadmap phase numbers in front of the player');
    expect(fingerprint(city), before);
  });

  testWidgets('every row of the site sheet refuses; deliveries stay shut',
      (t) async {
    t.view.physicalSize = const Size(1200, 2000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final city = independent();
    final reason = city.playerControl.reason!;
    final before = fingerprint(city);
    final site = portOf(city);
    final spec = city.siteSpec(site)!;
    var vab = 0, extra = 0;
    final hooks = CitySiteHooks(
      onOpenVab: () => vab++,
      onTargetPad: (_) {}, // the player's own craft: deliberately live
      extra: (site, spec) => [
        Builder(
            builder: (ctx) => gatedSiteAction(ctx, city, Icons.star,
                'A host row', 'Only one host offers it.', Colors.white,
                () => extra++)),
      ],
    );
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showCitySiteMenu(
                context: ctx,
                sim: city,
                site: site,
                spec: spec,
                onChanged: () {},
                hooks: hooks),
            child: const Text('open'),
          ),
        ),
      ),
    ));

    Future<List<String>> openRows() async {
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      return [for (final (title, _) in sheetRows(t)) title];
    }

    final rows = await openRows();
    for (final want in [
      'Design & launch craft',
      'Land lander on this pad',
      'Relief refused',
      'A host row',
      'Demolish',
    ]) {
      expect(rows, contains(want));
    }
    // Every row the gate covers says so, each on its own line.
    for (final (label, sub) in sheetRows(t)) {
      if (ungatedRow(label)) continue;
      expect(sub, reason, reason: 'row "$label" carries the reason');
    }
    await t.tapAt(const Offset(5, 5)); // dismiss
    await t.pumpAndSettle();
    for (final label in rows) {
      if (label == 'Details') continue; // a readout
      await openRows();
      await t.tap(find.text(label).last);
      await t.pumpAndSettle();
      if (label.toLowerCase().contains('deliveries')) {
        // The schedule is readable, and cannot be edited: no booking a
        // suspended run back on.
        expect(find.text('DELIVERY SCHEDULE'), findsOneWidget);
        final add = t.widget<ButtonStyleButton>(find.ancestor(
            of: find.text('Add delivery'),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));
        expect(add.onPressed, isNull);
        for (final b in t.widgetList<IconButton>(find.byType(IconButton))) {
          expect(b.onPressed, isNull, reason: 'edit/remove left live');
        }
        await t.tapAt(const Offset(5, 5));
        await t.pumpAndSettle();
      }
      expect(fingerprint(city), before, reason: 'site row "$label"');
    }
    expect(vab, 0, reason: 'the VAB opened on an independent colony');
    expect(extra, 0, reason: "a host's own row acted");

    // And the suspended run stays suspended: nothing flies, whatever time
    // passes.
    final stock = city.stockOf(Commodity.food);
    for (var i = 0; i < 400; i++) {
      city.reliefTick(0.5);
    }
    expect(city.craft, isEmpty);
    expect(city.stockOf(Commodity.food), stock);
    expect(city.requestRelief(site), isFalse);

    // The hooks were reachable: on a colony taking orders the same rows
    // act. (A no-op hook could not have told a bypass from a refusal.)
    city.loyalty.allegiance = Allegiance.colonial;
    await openRows();
    await t.tap(find.text('Design & launch craft').last);
    await t.pumpAndSettle();
    await openRows();
    await t.tap(find.text('A host row').last);
    await t.pumpAndSettle();
    expect((vab, extra), (1, 1));
  });

  testWidgets("the flat builder's own site rows refuse", (t) async {
    t.view.physicalSize = const Size(1600, 1400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final city = independent();
    final anchor = gridPort(city);
    final reason = city.playerControl.reason!;
    final before = fingerprint(city);
    final pushed = _Pushes();
    await t.pumpWidget(MaterialApp(
        navigatorObservers: [pushed],
        home: CityBuilderScreen(sim: city, driveLocally: false)));
    await t.pump();
    final driver =
        t.state(find.byType(CityBuilderScreen)) as CityBuilderToolDriver;
    final g = city.grid;
    // The screen animates without end: no settling, a sheet's own time.
    Future<void> settle() async {
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
    }

    Future<List<(String, String)>> openSheet() async {
      driver.debugInspect(anchor % g, anchor ~/ g);
      await settle();
      return sheetRows(t);
    }

    final rows = await openSheet();
    final labels = [for (final (l, _) in rows) l];
    for (final want in [
      'Design & launch craft',
      'Pilot a landing',
      'Launch in 3D sim',
      'Demolish',
    ]) {
      expect(labels, contains(want));
    }
    for (final (label, sub) in rows) {
      if (ungatedRow(label)) continue;
      expect(sub, reason, reason: 'row "$label" carries the reason');
    }
    await t.tapAt(const Offset(5, 5));
    await settle();
    final pages0 = pushed.pages;
    for (final label in labels) {
      if (ungatedRow(label)) continue;
      await openSheet();
      await t.tap(find.text(label).last);
      await settle();
      expect(pushed.pages, pages0,
          reason: 'row "$label" opened a screen on an independent colony');
      expect(fingerprint(city), before, reason: 'flat site row "$label"');
    }
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('every flat-builder tool, on every way it is applied, refuses',
      (t) async {
    t.view.physicalSize = const Size(1600, 1200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final city = independent();
    // A building on the cell map, so the toolbar's Clear-all is offered.
    gridPort(city);
    final reason = city.playerControl.reason!;
    final before = fingerprint(city);
    await t.pumpWidget(MaterialApp(
        home: CityBuilderScreen(sim: city, driveLocally: false)));
    await t.pump();
    final driver =
        t.state(find.byType(CityBuilderScreen)) as CityBuilderToolDriver;
    final g = city.grid;
    final hx = city.hubKey % g, hy = city.hubKey ~/ g;
    for (final tool in CityBuilderTool.values) {
      for (final (x, y) in [
        (1, 1),
        ((hx + 1) % g, hy),
        (hx, (hy + 2) % g),
        (g - 2, g - 2),
      ]) {
        driver.debugUseTool(tool, x, y);
        await t.pump();
      }
      expect(fingerprint(city), before, reason: 'flat tool ${tool.name}');
    }
    var chips = 0;
    for (final tool in CityBuilderTool.values.where((x) => x.acts)) {
      final chip = find.byKey(ValueKey('builder-tool-${tool.name}'));
      if (chip.evaluate().isEmpty) continue;
      chips++;
      expect(
          find.ancestor(
              of: chip,
              matching: find.byWidgetPredicate(
                  (w) => w is Tooltip && w.message == reason)),
          findsOneWidget,
          reason: '${tool.name} greyed with the reason');
    }
    expect(chips, greaterThanOrEqualTo(5));
    // The toolbar's own acts.
    for (final f in [
      find.text('Relief'),
      find.text('Plant'),
      find.textContaining('Buy land'),
      find.byTooltip('Clear'),
    ]) {
      // Each is on this toolbar: one left out is a control never tried.
      expect(f, findsWidgets, reason: '$f');
      await t.tap(f.first, warnIfMissed: false);
      await t.pump();
    }
    expect(fingerprint(city), before, reason: 'flat toolbar');
    // Unmount before the screen's ticker outlives the test.
    await t.pumpWidget(const SizedBox());
  });
}

/// Counts the full screens pushed: a site row that opened the VAB or a
/// flight would push one, where a refusal only shows a snack bar.
class _Pushes extends NavigatorObserver {
  int pages = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) pages++;
  }
}
