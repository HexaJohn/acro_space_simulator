// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Repro/regression for the debug panel's "Terrain view" row: opening the
// panel and tapping the row must cycle TerrainNodes.debugView. Runs the real
// SimulationView on the software backend, so the whole hit-test path — Stack
// order, SafeArea, the panel's scroll view — is the one the user clicks.

import 'package:acro_space_simulator/infrastructure/flutter/simulation_view.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/terrain/terrain_nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/register_baked_dems.dart';

void main() {
  testWidgets('debug panel Terrain view row cycles the shader debug view',
      (t) async {
    registerBakedDemsForTest();
    TerrainNodes.debugView = 0;
    addTearDown(() => TerrainNodes.debugView = 0);
    t.view.physicalSize = const Size(1200, 1800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    await t.pumpWidget(const MaterialApp(home: SimulationView()));
    await t.pump(const Duration(milliseconds: 400));

    await t.tap(find.byIcon(Icons.bug_report));
    await t.pump();

    final row = find.textContaining('Terrain view:');
    expect(row, findsOneWidget, reason: 'panel should show the row');
    await t.ensureVisible(row);
    await t.pump();

    await t.tap(row);
    await t.pump();
    expect(TerrainNodes.debugView, 1,
        reason: 'one tap must advance normal -> height');
    expect(find.textContaining('Terrain view: height'), findsOneWidget);

    await t.tap(row);
    await t.pump();
    expect(TerrainNodes.debugView, 2,
        reason: 'second tap must advance height -> albedo');
  });
}
