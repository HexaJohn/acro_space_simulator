// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Regression for the debug panel's EXPOSURE section: the auto/manual toggle
// must flip SceneSync.autoExposure, manual mode must surface the manual
// slider, auto mode the min/max clamp sliders, and the readout line must
// show the eased exposure and its target. Runs the real SimulationView so
// the hit-test path is the one the user clicks.

import 'package:acro_space_simulator/infrastructure/flutter/simulation_view.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/scene_sync.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/register_baked_dems.dart';

void main() {
  testWidgets('debug panel exposure section toggles auto/manual', (t) async {
    registerBakedDemsForTest();
    SceneSync.autoExposure = true;
    addTearDown(() {
      SceneSync.autoExposure = true;
      SceneSync.manualExposure = 1.0;
      SceneSync.minExposure = 0.55;
      SceneSync.maxExposure = 3.2;
      SceneSync.adaptUpS = 0.8;
      SceneSync.adaptDownS = 0.8;
    });
    t.view.physicalSize = const Size(1200, 1800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    await t.pumpWidget(const MaterialApp(home: SimulationView()));
    await t.pump(const Duration(milliseconds: 400));

    await t.tap(find.byIcon(Icons.bug_report));
    await t.pump();

    final row = find.textContaining('Exposure: auto');
    expect(row, findsOneWidget, reason: 'panel should show the toggle row');
    await t.ensureVisible(row);
    await t.pump();

    // Auto mode surfaces the clamp sliders and the live readout.
    expect(find.textContaining('auto min'), findsOneWidget);
    expect(find.textContaining('auto max'), findsOneWidget);
    expect(find.textContaining('now '), findsOneWidget);

    await t.tap(row);
    await t.pump();
    expect(SceneSync.autoExposure, isFalse,
        reason: 'one tap must switch auto -> manual');
    expect(find.textContaining('Exposure: manual'), findsOneWidget);
    expect(find.textContaining('manual '), findsWidgets);
    expect(find.textContaining('auto min'), findsNothing,
        reason: 'clamp sliders are auto-only');

    await t.tap(find.textContaining('Exposure: manual'));
    await t.pump();
    expect(SceneSync.autoExposure, isTrue,
        reason: 'second tap must switch back to auto');

    // The ease-time sliders show in both modes.
    expect(find.textContaining('up '), findsWidgets);
    expect(find.textContaining('down '), findsWidgets);
  });
}
