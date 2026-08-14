// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Cover for "pressing MMB or RMB causes a big camera shift": the stock
// GestureDetector scale gesture accepts EVERY mouse button, so a middle drag
// orbited at double rate (Listener + gesture) and a right press orbited on
// the few pixels of jitter a physical click carries. The scale gesture is now
// primary-button-only (RawGestureDetector + allowedButtonsFilter); MMB orbits
// once through the Listener, RMB moves nothing.
import 'package:acro_space_simulator/infrastructure/flutter/sim_view_control.dart';
import 'package:acro_space_simulator/infrastructure/flutter/simulation_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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

  testWidgets('bare MMB press+release does not move the camera', (t) async {
    await pumpView(t);
    final before = status();
    final g = await t.createGesture(
        kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
    await g.down(const Offset(700, 1000));
    await t.pump();
    await g.up();
    await t.pump();
    final after = status();
    expect(after['azimuth'], before['azimuth']);
    expect(after['elevation'], before['elevation']);
    expect(after['rangeM'], before['rangeM']);
  });

  testWidgets('bare RMB press+release does not move the camera', (t) async {
    await pumpView(t);
    final before = status();
    final g = await t.createGesture(
        kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await g.down(const Offset(700, 1000));
    await t.pump();
    await g.up();
    await t.pump();
    final after = status();
    expect(after['azimuth'], before['azimuth']);
    expect(after['elevation'], before['elevation']);
    expect(after['rangeM'], before['rangeM']);
  });

  testWidgets('a 10 px MMB drag orbits by exactly 0.05 rad (no double-fire)',
      (t) async {
    await pumpView(t);
    final before = status();
    final g = await t.createGesture(
        kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
    await g.down(const Offset(700, 1000));
    await t.pump();
    await g.moveBy(const Offset(10, 0));
    await t.pump();
    await g.up();
    await t.pump();
    final after = status();
    final dAz = (after['azimuth'] as double) - (before['azimuth'] as double);
    expect(dAz, closeTo(0.05, 1e-9));
  });

  testWidgets('a 10 px RMB drag does not orbit at all', (t) async {
    await pumpView(t);
    final before = status();
    final g = await t.createGesture(
        kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await g.down(const Offset(700, 1000));
    await t.pump();
    await g.moveBy(const Offset(10, 0));
    await t.pump();
    await g.up();
    await t.pump();
    final after = status();
    final dAz = (after['azimuth'] as double) - (before['azimuth'] as double);
    expect(dAz, closeTo(0.0, 1e-9));
  });
}
