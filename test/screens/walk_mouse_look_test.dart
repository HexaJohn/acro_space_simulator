// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Walk mode captures the mouse for first-person look: no click-and-drag.
//
// Driven through a FAKE lock — the real one warps the developer's actual
// cursor — whose deltas stand in for the hand on the mouse.
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/pointer_lock.dart';
import 'package:acro_space_simulator/infrastructure/flutter/sim_view_control.dart';
import 'package:acro_space_simulator/infrastructure/flutter/simulation_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeLock implements PointerLock {
  _FakeLock({this.supported = true});

  @override
  final bool supported;

  @override
  bool captured = false;

  /// Movement waiting to be read, as if the hand had moved the mouse.
  (double, double) pending = (0, 0);

  int captures = 0;
  bool disposed = false;

  @override
  void capture() {
    if (!supported) return;
    captured = true;
    captures++;
  }

  @override
  void release() => captured = false;

  @override
  (double, double) takeDelta() {
    if (!captured) return (0, 0);
    final d = pending;
    pending = (0, 0);
    return d;
  }

  @override
  void dispose() => disposed = true;
}

void main() {
  late _FakeLock lock;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    lock = _FakeLock();
    PointerLock.create = () => lock;
  });
  tearDown(() => PointerLock.create = PointerLock.platform);

  Future<void> pumpCity(WidgetTester t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final colony = CityStarterKit.found(
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      config: const CityConfig(bodyId: 'earth', latitude: 12, longitude: 20),
      id: 'look',
    );
    await t.pumpWidget(MaterialApp(
      home: SimulationView(
        injectedCity: colony,
        cityMode: true,
        spawnDemoOrbiter: false,
      ),
    ));
    await t.pump(const Duration(milliseconds: 16));
  }

  Map<String, dynamic> status() => SimViewControl.instance.status!();

  testWidgets('G captures the mouse; leaving the walk releases it', (t) async {
    await pumpCity(t);
    expect(lock.captured, isFalse, reason: 'the city camera is not a walk');
    await t.sendKeyEvent(LogicalKeyboardKey.keyG);
    await t.pump();
    expect(status()['walk'], isTrue);
    expect(lock.captured, isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.keyG);
    await t.pump();
    expect(status()['walk'], isFalse);
    expect(lock.captured, isFalse);
  });

  testWidgets('moving the mouse looks, without a button held', (t) async {
    await pumpCity(t);
    await t.sendKeyEvent(LogicalKeyboardKey.keyG);
    await t.pump();
    final before = status();
    lock.pending = (100, -40);
    await t.pump(const Duration(milliseconds: 16));
    final after = status();
    const k = SimulationView.mouseLookRadPerPx;
    expect((after['azimuth'] as double) - (before['azimuth'] as double),
        closeTo(100 * k, 1e-9));
    expect((after['elevation'] as double) - (before['elevation'] as double),
        closeTo(-40 * k, 1e-9));
  });

  testWidgets('Esc frees the cursor and the walk goes on; a click on the '
      'world takes it back', (t) async {
    await pumpCity(t);
    await t.sendKeyEvent(LogicalKeyboardKey.keyG);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(lock.captured, isFalse);
    expect(status()['walk'], isTrue, reason: 'Esc frees the mouse, not the walk');

    // A freed cursor must not keep looking.
    final before = status();
    lock.pending = (200, 0);
    await t.pump(const Duration(milliseconds: 16));
    expect(status()['azimuth'], before['azimuth']);

    // Click the open world, clear of the top bar and the toolbar.
    final g = await t.createGesture(
        kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
    await g.down(const Offset(800, 450));
    await t.pump();
    await g.up();
    await t.pump();
    expect(lock.captured, isTrue);
  });

  testWidgets('a click on the toolbar does NOT recapture', (t) async {
    await pumpCity(t);
    await t.sendKeyEvent(LogicalKeyboardKey.keyG);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    final captures = lock.captures;
    final g = await t.createGesture(
        kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
    await g.down(t.getCenter(find.text('Zone')));
    await t.pump();
    await g.up();
    await t.pump();
    expect(lock.captured, isFalse,
        reason: 'the cursor was freed to use the UI; using it must not '
            'snatch it back');
    expect(lock.captures, captures);
  });

  testWidgets('a platform that cannot capture keeps click-and-drag look',
      (t) async {
    lock = _FakeLock(supported: false);
    await pumpCity(t);
    await t.sendKeyEvent(LogicalKeyboardKey.keyG);
    await t.pump();
    expect(lock.captured, isFalse);
    final before = status();
    final g = await t.createGesture(
        kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
    await g.down(const Offset(800, 450));
    await t.pump();
    await g.moveBy(const Offset(40, 0));
    await t.pump();
    await g.up();
    await t.pump();
    expect(status()['azimuth'], isNot(before['azimuth']));
  });

  testWidgets('the lock is disposed with the view', (t) async {
    await pumpCity(t);
    await t.pumpWidget(const SizedBox());
    expect(lock.disposed, isTrue);
  });
}
