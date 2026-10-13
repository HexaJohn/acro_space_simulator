// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_unlocks.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_factory_sim.dart';

/// The editor's per-frame and per-move costs, and the state it must keep
/// across a colony parent's rebuilds. Each test pins a cost or a survival
/// that a real hall (thousands of placements, warped time, a parent that
/// rebuilds every tick) would otherwise pay or lose.
void main() {
  FloorBlueprint hall() =>
      FloorBlueprint(name: 'Test Hall', hall: const HallSize(60, 30));

  FactoryEditorController controller(FakeFactorySim s, {bool drives = true}) {
    final c = FactoryEditorController(s, InfiniteColonyPort(),
        drivesSim: drives);
    // A fixed camera so tile centres are known without a layout pass.
    c.pxPerTile = 10;
    c.origin = const Offset(0, 300);
    c.viewSize = const Size(600, 300);
    return c;
  }

  /// A dragged belt run re-derives its whole ghost on every move. The real
  /// floor's check scans every placement, so re-asking it for every piece
  /// on every move makes a long drag quadratic; the verdicts are reused
  /// within one layout revision, so a 30-tile drag asks once per tile.
  test('a belt drag checks each tile once per layout revision', () {
    final s = FakeFactorySim(hall());
    final c = controller(s)..choose(EntityKind.belt);
    c.pointerDown(1, c.tileCenterLocal(const TilePos(2, 5)), kPrimaryButton);
    for (var x = 3; x <= 32; x++) {
      c.pointerMove(1, c.tileCenterLocal(TilePos(x, 5)));
    }
    expect(c.ghost.length, 31);
    // One check per distinct piece (+ slack for the hover tile); the
    // un-memoised editor asked ~31*32/2 = 496 times.
    expect(s.checks, lessThanOrEqualTo(40));
    c.pointerUp(1, c.tileCenterLocal(const TilePos(32, 5)));
    expect(s.placed.length, 31, reason: 'memoised verdicts still commit');
    c.dispose();
  });

  /// A new layout revision must invalidate the memo: a tile that was free
  /// before a placement is not free after it.
  test('the check memo is dropped when the layout changes', () {
    final s = FakeFactorySim(hall());
    final c = controller(s)..choose(EntityKind.chest);
    c.pointerHover(c.tileCenterLocal(const TilePos(4, 4)));
    expect(c.ghostValid, isTrue);
    s.place(Placement(id: 0, kind: EntityKind.chest, pos: const TilePos(4, 4)));
    c.pointerHover(c.tileCenterLocal(const TilePos(5, 4)));
    c.pointerHover(c.tileCenterLocal(const TilePos(4, 4)));
    expect(c.ghostValid, isFalse);
    c.dispose();
  });

  /// Heat decays by the sim time that passed, so its ~30 s half-life holds
  /// whether the floor is stepped at 1x in small frames or by the colony in
  /// one 30 s jump. A once-per-frame decay would barely touch it.
  test('heat decays by elapsed sim time, not once per frame', () {
    final s = FakeFactorySim(hall())
      ..crew = [
        const HandlerView(id: 1, kind: HandlerKind.onFoot, x: 1, y: 1,
            state: HandlerState.carrying),
      ];
    final c = controller(s, drives: false);
    s.colonyStep(1);
    c.tick(0.016);
    final h0 = c.heat[0];
    expect(h0, closeTo(1 * kHeatDecay, 1e-4));
    s.crew = [];
    s.colonyStep(30);
    c.tick(0.016);
    expect(c.heat[0], closeTo(h0 * math.pow(kHeatDecay, 30), 1e-4));
    expect(c.heatMax, closeTo(h0 * math.pow(kHeatDecay, 30), 1e-4));
    c.dispose();
  });

  /// The cost strip rebuilds on every hover and live tick; the capex walk
  /// is cached until the layout or roster changes.
  test('capex is cached per layout revision and roster', () {
    final s = FakeFactorySim(hall());
    final c = controller(s);
    final a = c.capex;
    expect(identical(c.capex, a), isTrue, reason: 'no change, no re-walk');
    c.hire(HandlerKind.forklift, 1);
    final b = c.capex;
    expect(identical(b, a), isFalse, reason: 'a hire changes the roster');
    expect(b.vehicles, greaterThan(a.vehicles));
    s.place(Placement(id: 0, kind: EntityKind.chest, pos: const TilePos(4, 4)));
    expect(identical(c.capex, b), isFalse, reason: 'a placement bumps rev');
    c.dispose();
  });

  /// A colony parent builds a fresh, equal FactoryUnlocks on each rebuild;
  /// that must not replace the controller (camera, tool, heat, rate window)
  /// — only the displayed unlocks change.
  testWidgets('new unlocks keep the controller and update the display',
      (t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final s = FakeFactorySim(hall());
    Widget screen(FactoryUnlocks u) => MaterialApp(
        home: FactoryFloorScreen(sim: s, unlocks: u, drivesSim: false));
    FactoryUnlocks fresh() => FactoryUnlocks(
        handlers: {...FactoryUnlocks.all.handlers},
        modes: {...FactoryUnlocks.all.modes});
    await t.pumpWidget(screen(fresh()));
    await t.pump();
    FactoryFloorScreenState st() =>
        t.state<FactoryFloorScreenState>(find.byType(FactoryFloorScreen));
    final c = st().controller..choose(EntityKind.chest);
    await t.pumpWidget(screen(fresh()));
    await t.pump();
    expect(identical(st().controller, c), isTrue);
    expect(st().controller.kind, EntityKind.chest, reason: 'tool survives');
    await t.pumpWidget(screen(FactoryUnlocks.starter));
    await t.pump();
    expect(identical(st().controller, c), isTrue);
    expect(c.unlocks, same(FactoryUnlocks.starter));
    expect(
        find.descendant(
            of: find.byKey(const Key('hire-forklift-plus')),
            matching: find.byIcon(Icons.lock_outline)),
        findsOneWidget,
        reason: 'the roster greys what the new unlocks lock');
  });
}
