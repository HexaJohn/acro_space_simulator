// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_unlocks.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_painter.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_screen.dart';
import 'package:acro_space_simulator/main_factory_dev.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_factory_sim.dart';

/// The editor wired to the REAL floor (docs/plans/factory-floors.md §4,
/// wave 2): the Steel Mill template opened in the editor must take edits,
/// preview them with the floor's own rules, draw its vehicles where the
/// floor says they are, and — when the colony is the one stepping the
/// floor — keep its hands off the clock and the period ledger.
void main() {
  late FactoryEditorController c;
  late Finder canvas;

  FactoryFloor mill({FactoryUnlocks unlocks = FactoryUnlocks.all}) =>
      FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!,
          unlocks: unlocks);

  Future<void> open(WidgetTester t, FactorySim sim,
      {FactoryUnlocks unlocks = FactoryUnlocks.all,
      bool drivesSim = true}) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
        home: FactoryFloorScreen(
            sim: sim, unlocks: unlocks, drivesSim: drivesSim)));
    await t.pump();
    c = t.state<FactoryFloorScreenState>(find.byType(FactoryFloorScreen))
        .controller;
    canvas = find.byKey(const Key('factory-canvas'));
  }

  Offset at(WidgetTester t, TilePos p) =>
      t.getTopLeft(canvas) + c.tileCenterLocal(p);

  Future<void> click(WidgetTester t, TilePos p) async {
    final g = await t.startGesture(at(t, p), kind: PointerDeviceKind.mouse);
    await g.up();
    await t.pump();
  }

  Future<TestGesture> hover(WidgetTester t, TilePos p) async {
    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: at(t, p) + const Offset(0, 1));
    await g.moveTo(at(t, p));
    await t.pump();
    return g;
  }

  FactoryFloorPainter painter(WidgetTester t) => t
      .widget<CustomPaint>(find.descendant(
          of: canvas, matching: find.byType(CustomPaint)))
      .painter! as FactoryFloorPainter;

  /// The first tile of [f]'s hall a chest may go on, row-major.
  TilePos freeTile(FactoryFloor f) {
    for (final p in f.blueprint.hall.rect.tiles) {
      if (f.check(Placement(id: 0, kind: EntityKind.chest, pos: p)).ok) {
        return p;
      }
    }
    throw StateError('no free tile');
  }

  /// A palette pick and a click land in the floor itself: a new chest in
  /// its blueprint, a new layout revision.
  testWidgets('palette place lands in the real floor', (t) async {
    final f = mill();
    await open(t, f);
    final rev = f.layoutRev, n = f.blueprint.placements.length;
    final spot = freeTile(f);
    await t.tap(find.byKey(const Key('palette-chest')));
    await t.pump();
    await click(t, spot);
    expect(f.blueprint.placements, hasLength(n + 1));
    expect(f.blueprint.placements.last.kind, EntityKind.chest);
    expect(f.blueprint.placements.last.pos, spot);
    expect(f.layoutRev, greaterThan(rev));
  });

  /// The ghost is the floor's own verdict (`check`), not a mirror of it: on
  /// a machine it names that machine, and a crane bay — a floor marking the
  /// old index-side check waved through — is refused as locked when the
  /// colony has no cranes.
  testWidgets('a refused ghost is the floor check() verdict', (t) async {
    final f = mill(unlocks: FactoryUnlocks.starter);
    await open(t, f, unlocks: FactoryUnlocks.starter);
    final m = f.blueprint.placements
        .firstWhere((p) => p.kind == EntityKind.machine);
    await t.tap(find.byKey(const Key('palette-chest')));
    await t.pump();
    final g = await hover(t, m.pos);
    final want =
        f.check(Placement(id: 0, kind: EntityKind.chest, pos: m.pos));
    expect(c.ghostValid, isFalse);
    expect(c.ghost.single.check.refusal, EditRefusal.overlaps);
    expect(c.ghost.single.check.refusal, want.refusal);
    expect(c.ghost.single.check.otherId, m.id);

    await t.tap(find.byKey(const Key('palette-craneBay')));
    await t.pump();
    await g.moveTo(at(t, freeTile(f)));
    await t.pump();
    expect(c.ghost.single.check.refusal, EditRefusal.notAllowed,
        reason: 'starter colonies have no cranes');
    await g.removePointer();
    final n = f.blueprint.placements.length;
    await click(t, freeTile(f));
    expect(f.blueprint.placements, hasLength(n), reason: 'nothing was sent');
  });

  /// The ghost asks the sim on every hover: a fake counts the calls.
  testWidgets('the ghost preview calls sim.check', (t) async {
    final s = FakeFactorySim(
        FloorBlueprint(name: 'h', hall: const HallSize(20, 10)));
    await open(t, s);
    await t.tap(find.byKey(const Key('palette-chest')));
    await t.pump();
    final before = s.checks;
    final g = await hover(t, const TilePos(3, 3));
    await g.moveTo(at(t, const TilePos(4, 3)));
    await t.pump();
    expect(s.checks, greaterThan(before));
    await g.removePointer();
  });

  /// HandlerView (x, y) is an anchor: a forklift covers the 2 × 2 square
  /// above-right of it and is drawn centred on that square, a walker on its
  /// tile's centre, and a crane's bridge spans its whole bay.
  testWidgets('vehicles are drawn centred on their square', (t) async {
    final f = mill();
    await open(t, f);
    await t.pump(const Duration(milliseconds: 16));
    final rects = painter(t).handlerRects;
    expect(rects, isNotEmpty);
    for (final h in f.handlers) {
      final r = rects[h.id];
      expect(r, isNotNull, reason: 'handler ${h.id} drawn');
      final w = switch (h.kind) {
        HandlerKind.forklift || HandlerKind.agv => 2.0,
        _ => 1.0,
      };
      expect(r!.center.dx, closeTo(h.x + w / 2, 1e-9));
      expect(r.center.dy, closeTo(h.y + w / 2, 1e-9));
      expect(r.width, w);
    }
    final cranes = f.handlers.where((h) => h.kind == HandlerKind.crane);
    expect(cranes, isNotEmpty);
    for (final h in cranes) {
      final br = painter(t).bridgeRects[h.id];
      expect(br, isNotNull, reason: 'each crane stands in its bay');
      expect(br!.height, 3, reason: 'the template bays are 9 x 3 tiles');
    }
    expect(handlerSquare(const HandlerView(id: 1, kind: HandlerKind.forklift,
            x: 10, y: 4, state: HandlerState.idle)).center,
        const Offset(11, 5));
  });

  /// Hiring from the roster adds a real forklift to the floor.
  testWidgets('the roster hires a forklift into the floor', (t) async {
    final f = mill();
    await open(t, f);
    final had = f.blueprint.roster[HandlerKind.forklift] ?? 0;
    await t.tap(find.byKey(const Key('hire-forklift-plus')));
    await t.pump();
    expect(f.blueprint.roster[HandlerKind.forklift], had + 1);
    expect(f.handlers.where((h) => h.kind == HandlerKind.forklift),
        hasLength(had + 1));
    final count = t.widget<Text>(find.byKey(const Key('hire-forklift-count')));
    expect(count.data, '${had + 1}');
  });

  /// A colony that has not unlocked forklifts sees them greyed and
  /// labelled locked, and buying one is refused by the floor with a
  /// message; automated stations are greyed in the mode picker.
  testWidgets('locked kinds are greyed and refused', (t) async {
    final f = mill(unlocks: FactoryUnlocks.starter);
    await open(t, f, unlocks: FactoryUnlocks.starter);
    final had = f.blueprint.roster[HandlerKind.forklift] ?? 0;
    expect(t.widget<Text>(find.byKey(const Key('hire-forklift-label'))).data,
        contains('locked'));
    expect(t.widget<Opacity>(find.byKey(const Key('roster-forklift'))).opacity,
        lessThan(1));
    expect(t.widget<Opacity>(find.byKey(const Key('roster-onFoot'))).opacity,
        1);
    await t.tap(find.byKey(const Key('hire-forklift-plus')));
    await t.pump();
    expect(f.blueprint.roster[HandlerKind.forklift] ?? 0, had);
    expect(c.message, contains('locked'));
    expect(find.byKey(const Key('factory-message')), findsOneWidget);

    final m = f.blueprint.placements.firstWhere(
        (p) => p.kind == EntityKind.machine && p.crew == MachineMode.manual);
    c.select(m.id);
    await t.pump();
    expect(t.widget<ChoiceChip>(find.byKey(const Key('mode-automated')))
        .onSelected, isNull);
    expect(t.widget<ChoiceChip>(find.byKey(const Key('mode-assisted')))
        .onSelected, isNotNull);
  });

  /// Inside a colony the colony steps the floor: the screen must not
  /// advance its clock, must hide the speed controls, and shows it is
  /// watching live colony time.
  testWidgets('drivesSim=false never steps the real floor', (t) async {
    final f = mill();
    await open(t, f, drivesSim: false);
    final t0 = f.simSeconds;
    for (var i = 0; i < 40; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(f.simSeconds, t0);
    expect(find.byKey(const Key('speed-1')), findsNothing);
    expect(find.byKey(const Key('colony-driven')), findsOneWidget);
  });

  /// The colony owns the period ledger: a watching editor never calls
  /// step or takeLedger, yet its readout still moves, from lifetime.
  testWidgets('drivesSim=false reads rates from lifetime only', (t) async {
    final s = FakeFactorySim(
        FloorBlueprint(name: 'h', hall: const HallSize(20, 10)));
    await open(t, s, drivesSim: false);
    for (var i = 0; i < 80; i++) {
      s.colonyStep(0.016);
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(s.steps, 0);
    expect(s.ledgersTaken, 0);
    expect(c.ratesOut['steel'], closeTo(2, 1e-9));
    expect(find.byKey(const Key('readout-out-steel')), findsOneWidget);
  });

  /// The header prices the layout and sizes the hall, from the floor.
  testWidgets('the cost strip shows capex and the hall in metres',
      (t) async {
    final f = mill();
    await open(t, f);
    final hall = t.widget<Text>(find.byKey(const Key('cost-hall'))).data!;
    expect(hall, contains('66 × 56 m'));
    final cost = t.widget<Text>(find.byKey(const Key('cost-capex'))).data!;
    expect(cost, contains(c.capex.total.toStringAsFixed(1)));
    expect(cost, contains('vehicles'));
  });

  /// The dev entry offers only plants that have a template, plus a blank
  /// hall, and opens the real floor.
  testWidgets('dev app opens the real steel mill and a blank hall',
      (t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    expect(availableDevPlants(), contains('steelmill'));
    expect(availableDevPlants().every((p) => factoryTemplateFor(p) != null),
        isTrue);
    await t.pumpWidget(const FactoryDevApp());
    await t.pump();
    final st = t.state<FactoryDevAppState>(find.byType(FactoryDevApp));
    expect(st.floor.blueprint.plantType, 'steelmill');
    st.pick(kBlankHall, const HallSize(20, 15));
    await t.pump();
    expect(st.floor.blueprint.placements, isEmpty);
    expect(st.floor.blueprint.hall, const HallSize(20, 15));
    expect(t.takeException(), isNull);
  });

  /// Lifetime counters fold every closed period and survive a save, so a
  /// reopened editor's readout picks up where it left off; a fresh floor
  /// saves no 'life' key at all (old saves are unchanged).
  test('lifetime survives takeLedger and save/load', () {
    final f = mill();
    expect(f.toJson().containsKey('life'), isFalse);
    final port = InfiniteColonyPort();
    f.step(120, port);
    final first = f.takeLedger();
    f.step(60, port);
    final life = f.lifetime;
    expect(life.seconds, closeTo(180, 1e-9));
    expect(life.shipped['steel'],
        closeTo((first.shipped['steel'] ?? 0) + (f.ledger.shipped['steel'] ?? 0),
            1e-9));
    expect(life.shipped['steel'], greaterThan(0));

    final back = FactoryFloor.fromJson(
        jsonDecode(jsonEncode(f.toJson())) as Map<String, Object?>);
    expect(jsonEncode(back.lifetime.toJson()), jsonEncode(life.toJson()));
    expect(back.ledger.seconds, closeTo(60, 1e-9),
        reason: 'the open period stays open');
  });

  /// What a removed station held is set down as a pile, and the view's
  /// piles list it (the painter draws them).
  test('piles view lists what a removal set down', () {
    final f = mill();
    f.step(200, InfiniteColonyPort());
    final m = f.blueprint.placements.firstWhere((p) =>
        p.kind == EntityKind.machine && f.contentsOf(p.id).isNotEmpty);
    final held = f.contentsOf(m.id);
    expect(f.remove(m.id).ok, isTrue);
    final piled = <String, int>{};
    for (final p in f.piles) {
      piled[p.item] = (piled[p.item] ?? 0) + p.count;
    }
    for (final e in held.entries) {
      expect(piled[e.key] ?? 0, greaterThanOrEqualTo(e.value));
    }
    final flat = {
      for (final e in f.floorPiles.entries)
        for (final i in e.value.entries) (e.key, i.key): i.value,
    };
    expect({for (final p in f.piles) (p.tile, p.item): p.count}, flat);
  });
}
