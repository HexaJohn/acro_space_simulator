// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Cover for "clicking the zoning / build buttons moves the camera".
//
// The camera's drag recognizer used to wrap the whole view as an ANCESTOR, so
// it entered the gesture arena for every pointer — UI included. On a mouse its
// slop is ~2 px against a tap's 18, and every physical click carries a pixel
// or two of jitter: the camera claimed the click, the button lost its tap, and
// the view orbited. The recognizer is now a layer beneath the UI, so a click
// that lands on a button never reaches it.
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/sim_view_control.dart';
import 'package:acro_space_simulator/infrastructure/flutter/simulation_view.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/render_backend.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpCity(WidgetTester t,
      {RenderBackend backend = RenderBackend.software}) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final colony = CityStarterKit.found(
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      config: const CityConfig(bodyId: 'earth', latitude: 12, longitude: 20),
      id: 'clicks',
    );
    await t.pumpWidget(MaterialApp(
      home: SimulationView(
        injectedCity: colony,
        cityMode: true,
        spawnDemoOrbiter: false,
        initialBackend: backend,
      ),
    ));
    await t.pump(const Duration(milliseconds: 16));
  }

  Map<String, dynamic> status() => SimViewControl.instance.status!();

  /// A real mouse click: down, a couple of pixels of hand jitter, up.
  Future<void> jitteryClick(WidgetTester t, Offset at) async {
    final g = await t.createGesture(
        kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
    await g.down(at);
    await t.pump();
    await g.moveBy(const Offset(3, 1));
    await t.pump();
    await g.up();
    await t.pump();
  }

  testWidgets('a jittery click on a toolbar tool does not orbit the camera',
      (t) async {
    await pumpCity(t);
    final before = status();

    final zone = find.text('Zone');
    expect(zone, findsOneWidget, reason: 'the city toolbar is not up');
    await jitteryClick(t, t.getCenter(zone));

    final after = status();
    expect(after['azimuth'], before['azimuth']);
    expect(after['elevation'], before['elevation']);
    expect(after['rangeM'], before['rangeM']);
  });

  testWidgets('and the click reaches the button', (t) async {
    await pumpCity(t);
    // The Zone tool's row carries the zone kinds; it is only built once the
    // tool is held, so its appearance is the proof the tap landed.
    expect(find.text('Residential'), findsNothing);
    await jitteryClick(t, t.getCenter(find.text('Zone')));
    await t.pump();
    expect(find.text('Residential'), findsWidgets,
        reason: 'the camera ate the click instead of the button');
  });

  testWidgets('a click on a HUD button does not orbit the camera either',
      (t) async {
    await pumpCity(t);
    final before = status();
    await jitteryClick(t, t.getCenter(find.text('Budget')));
    final after = status();
    expect(after['azimuth'], before['azimuth']);
    expect(after['elevation'], before['elevation']);
    expect(find.text('BUDGET'), findsOneWidget,
        reason: 'the drawer should have opened');
  });

  testWidgets('holding the Zone tool raises the zoning view; putting it down '
      'drops it', (t) async {
    // "Zoning mode" is the Zone tool: pick up the brush and the plat appears,
    // put it down and the town goes back to being a town.
    await pumpCity(t);
    expect(CityNodes.zoneOverlay, isFalse);
    await jitteryClick(t, t.getCenter(find.text('Zone')));
    await t.pump();
    expect(CityNodes.zoneOverlay, isTrue, reason: 'the Zone tool is held');
    await jitteryClick(t, t.getCenter(find.text('Look')));
    await t.pump();
    expect(CityNodes.zoneOverlay, isFalse, reason: 'the Zone tool is down');
  });

  testWidgets('G steps out onto the camera pivot, not under the boom',
      (t) async {
    // The 3D backend, because the bug lived there: only with a scene
    // snapshot does the flight view's focus resolve to the PLANET'S CENTRE,
    // and walking off "the focus plus the eye offset" then lands wherever the
    // camera happens to be pointing, from the middle of the Earth.
    await pumpCity(t, backend: RenderBackend.flutterScene);
    // At open the pivot IS the colony site; the eye hangs on the boom. The
    // first version of this test ran in the software view's ORTHO camera,
    // where the eye sits on the pivot — so it passed while G was still
    // landing the walker under the eye. Perspective, with a real boom, is
    // the camera the mode actually plays in.
    SimViewControl.instance.setPerspective?.call(true);
    SimViewControl.instance.zoom?.call(rangeM: 1800);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyG);
    await t.pump();
    final s = status();
    expect(s['walk'], isTrue);
    expect(s['cityPivotOffsetM'] as double, lessThan(1.0),
        reason: 'the walker landed under the eye, not at the focus point');
  });

  testWidgets('a drag on open ground still orbits', (t) async {
    // The other half: moving the recognizer must not have disconnected it.
    await pumpCity(t);
    final before = status();
    final g = await t.createGesture(
        kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
    // Middle of the screen, clear of the top bar and the bottom toolbar.
    await g.down(const Offset(800, 450));
    await t.pump();
    await g.moveBy(const Offset(40, 0));
    await t.pump();
    await g.up();
    await t.pump();
    expect(status()['azimuth'], isNot(before['azimuth']));
  });
}
