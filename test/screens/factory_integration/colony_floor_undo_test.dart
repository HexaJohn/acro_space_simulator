// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Undo on a colony's LIVE floor (docs/plans/factory-floors.md §10 item 9).
///
/// The editor shown over the colony view takes Ctrl+Z like the sandbox
/// does, and an undone edit must cost nothing: the colony settles a floor
/// edit on close as the build-cost difference between the blueprint it
/// opened with and the one it closes with, so undo only changes the
/// "after" and an edit-then-undo leaves no investment due.
library;

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/sim_view_control.dart';
import 'package:acro_space_simulator/infrastructure/flutter/simulation_view.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/render_backend.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../colony/factory_integration/factory_colony_fixture.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpView(WidgetTester t, CitySim colony) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: SimulationView(
        injectedCity: colony,
        cityMode: true,
        spawnDemoOrbiter: false,
        initialBackend: RenderBackend.software,
      ),
    ));
    await t.pump(const Duration(milliseconds: 16));
  }

  /// Opens [lot]'s floor over the view and returns its editor.
  Future<FactoryEditorController> openFloor(WidgetTester t, String lot) async {
    SimViewControl.instance.factoryFloor!(lot);
    await t.pump();
    await t.pump();
    return t
        .state<FactoryFloorScreenState>(find.byType(FactoryFloorScreen))
        .controller;
  }

  /// The Delete tool's box over the whole hall: every solid goes.
  void deleteEverything(FactoryEditorController c) {
    final hall = c.sim.blueprint.hall;
    c.setTool(FactoryTool.delete);
    c.pointerDown(1, c.tileCenterLocal(const TilePos(0, 0)), kPrimaryButton);
    c.pointerMove(1, c.tileCenterLocal(TilePos(hall.w - 1, hall.h - 1)));
    c.pointerUp(1, c.tileCenterLocal(TilePos(hall.w - 1, hall.h - 1)));
  }

  int solids(FactoryEditorController c) => c.sim.blueprint.placements
      .where((p) => !kOverlayKinds.contains(p.kind))
      .length;

  testWidgets('Ctrl+Z on the live floor undoes, and the undone edit is free',
      (t) async {
    final colony = foundedColony();
    final lot = placeOnFreeLot(colony, specOf('steelmill'));
    await pumpView(t, colony);
    final c = await openFloor(t, lot);
    final n = solids(c);
    expect(n, greaterThan(0));
    deleteEverything(c);
    expect(solids(c), 0);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(solids(c), n, reason: 'Ctrl+Z reached the editor over the view');
    await t.tap(find.byKey(const Key('factory-back')));
    await t.pump();
    expect(colony.pendingFloorInvestment[lot], isNull,
        reason: 'edit + undo changes nothing the colony pays for');

    // The control: the same edit kept is a real (negative) investment.
    final c2 = await openFloor(t, lot);
    deleteEverything(c2);
    await t.tap(find.byKey(const Key('factory-back')));
    await t.pump();
    expect(colony.pendingFloorInvestment[lot], lessThan(0),
        reason: 'the kit sold off is booked');
  });
}
