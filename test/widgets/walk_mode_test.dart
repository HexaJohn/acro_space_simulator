// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Cover for the WIRING of first-person walk (the motion itself is pinned in
// test/presenters/first_person_walker_test.dart): the FAB and the G key put
// the view on foot, the eye lands at standing height above the real terrain of
// the focused body, and leaving walk gives the orbit camera its range back.
import 'package:acro_space_simulator/adapters/presenters/first_person_walker.dart';
import 'package:acro_space_simulator/infrastructure/flutter/sim_view_control.dart';
import 'package:acro_space_simulator/infrastructure/flutter/simulation_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpView(WidgetTester t) async {
    t.view.physicalSize = const Size(1400, 2000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: SimulationView()));
    await t.pump(const Duration(milliseconds: 16));
  }

  Map<String, dynamic> status() => SimViewControl.instance.status!();

  testWidgets('the walk FAB stands the camera on the ground and back off',
      (t) async {
    await pumpView(t);
    SimViewControl.instance.focusBody!('earth');
    await t.pump();
    final rangeBefore = status()['rangeM'] as double;

    await t.tap(find.byIcon(Icons.directions_walk));
    await t.pump();

    final s = status();
    expect(s['walk'], isTrue);
    expect(s['freecam'], isTrue, reason: 'walk owns the freecam anchor');
    expect(s['walkGrounded'], isTrue);
    expect(s['walkEyeAltM'] as double, closeTo(walkEyeHeight, 1e-6),
        reason: 'the eye starts exactly a standing height above the terrain');

    await t.tap(find.byIcon(Icons.directions_walk));
    await t.pump();
    expect(status()['walk'], isFalse);
    expect(status()['rangeM'], rangeBefore,
        reason: 'the orbit range is handed back untouched');
  });

  testWidgets('G toggles walk, and walking holds eye height over terrain',
      (t) async {
    await pumpView(t);
    SimViewControl.instance.focusBody!('earth');
    await t.pump();

    await t.sendKeyEvent(LogicalKeyboardKey.keyG);
    await t.pump();
    expect(status()['walk'], isTrue);

    // Hold W for a second of frames: the ground under the walker changes as it
    // moves, and the eye has to keep riding it.
    await t.sendKeyDownEvent(LogicalKeyboardKey.keyW);
    for (var i = 0; i < 60; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    await t.sendKeyUpEvent(LogicalKeyboardKey.keyW);
    await t.pump();

    final s = status();
    expect(s['walk'], isTrue);
    expect(s['walkGrounded'], isTrue, reason: 'a level walk never takes off');
    expect(s['walkEyeAltM'] as double, closeTo(walkEyeHeight, 0.05));

    await t.sendKeyEvent(LogicalKeyboardKey.keyG);
    await t.pump();
    expect(status()['walk'], isFalse);
  });
}
