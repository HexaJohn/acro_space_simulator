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
import 'package:acro_space_simulator/infrastructure/flutter_scene/terrain/terrain_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/walker_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter/simulation_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/register_baked_dems.dart';

void main() {
  // Real relief, not a smooth datum: the ground-sampling bug this file's last
  // test covers is invisible on a featureless sphere.
  setUpAll(registerBakedDemsForTest);
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

  testWidgets('F lights the head lamp, T stands the camera off on a boom',
      (t) async {
    await pumpView(t);
    SimViewControl.instance.focusBody!('earth');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyG);
    await t.pump();

    expect(status()['lamp'], isFalse);
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.pump();
    expect(status()['lamp'], isTrue);
    expect(TerrainNodes.lampOn, isTrue);

    expect(status()['thirdPerson'], isFalse);
    expect(WalkerNodes.visible, isFalse,
        reason: 'in first person you are inside your own head');
    await t.sendKeyEvent(LogicalKeyboardKey.keyT);
    await t.pump(const Duration(milliseconds: 16));
    expect(status()['thirdPerson'], isTrue);
    expect(WalkerNodes.visible, isTrue, reason: 'now there is a body to see');

    // Clean up the statics so test order cannot leak the lamp into another case.
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.sendKeyEvent(LogicalKeyboardKey.keyG);
    await t.pump();
    expect(WalkerNodes.visible, isFalse, reason: 'leaving walk stows the body');
  });

  testWidgets('J deploys the pack, and leaving walk stows it', (t) async {
    await pumpView(t);
    SimViewControl.instance.focusBody!('earth');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyG);
    await t.pump();

    expect(status()['evaPack'], isFalse);
    await t.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await t.pump(const Duration(milliseconds: 16));
    expect(status()['evaPack'], isTrue);
    expect(status()['evaFuelKg'] as double, greaterThan(0));

    await t.sendKeyEvent(LogicalKeyboardKey.keyG); // out of walk
    await t.pump();
    expect(status()['evaPack'], isFalse);
  });

  testWidgets('the drill records terrain edits, and few of them', (t) async {
    await pumpView(t);
    SimViewControl.instance.focusBody!('earth');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyG);
    await t.pump();
    expect(status()['terrainEditCount'], 0);

    // Two seconds of held trigger, looking straight down at the ground.
    SimViewControl.instance.setDrill!(true);
    for (var i = 0; i < 120; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    SimViewControl.instance.setDrill!(false);
    await t.pump(const Duration(milliseconds: 16));

    final edits = status()['terrainEditCount'] as int;
    expect(edits, greaterThan(0), reason: 'the ground has to actually move');
    expect(edits, lessThan(20),
        reason: 'a brush per frame would be 120 — the snapshot ships this list');
    expect(status()['drilledM3'] as double, greaterThan(0));
    expect(status()['drilling'], isFalse, reason: 'trigger released, bore closed');
  });

  testWidgets('standing on a SPINNING body with real relief stays standing',
      (t) async {
    // Regression: the ground sample used to round-trip body-fixed -> inertial
    // with the SNAPSHOT's orientation and back with orientationAt(epoch). Those
    // differ by a frame of spin, which slides the sample point across the
    // relief, so the floor moved every frame and the walker fell, landed, and
    // fell again forever — a couple of metres of bobbing that never settled.
    await pumpView(t);
    SimViewControl.instance.focusBody!('moon');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyG);
    await t.pump(const Duration(milliseconds: 16));

    // Let any initial settle finish, then watch a couple of seconds of frames.
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    final alts = <double>[];
    for (var i = 0; i < 120; i++) {
      await t.pump(const Duration(milliseconds: 16));
      final a = status()['walkEyeAltM'] as double?;
      if (a != null) alts.add(a);
    }
    expect(alts, isNotEmpty);
    final spread = alts.reduce((a, b) => a > b ? a : b) -
        alts.reduce((a, b) => a < b ? a : b);
    expect(spread, lessThan(0.05),
        reason: 'the floor must hold still under a standing figure');
    expect(status()['walkGrounded'], isTrue);
  });

  testWidgets('on foot, camera elevation is measured from the walker horizon',
      (t) async {
    // Regression: the gravity gimbal keyed off the focused VESSEL's radial, and
    // a walker has no vessel — so the frame fell back to the body's equator and
    // "elevation" tilted toward the pole. Looking down was impossible, and
    // everything that aims by looking (the drill, the lamp) pointed at the sky.
    await pumpView(t);
    SimViewControl.instance.focusBody!('moon');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyG);
    await t.pump(const Duration(milliseconds: 16));

    double aimDot() => status()['drillAimDot'] as double;

    SimViewControl.instance.orbit!(elevation: 1.4); // near straight down
    await t.pump(const Duration(milliseconds: 16));
    final down = aimDot();
    SimViewControl.instance.orbit!(elevation: -1.4); // near straight up
    await t.pump(const Duration(milliseconds: 16));
    final up = aimDot();

    expect(down, lessThan(-0.9),
        reason: 'full positive elevation must aim down the local radial');
    expect(up, greaterThan(0.9), reason: 'and full negative must aim at zenith');
  });
}
