// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Agent traffic's slice 2 in the real view (docs/plans/agent-traffic.md
// §13.9, §18 slice 2): V and the HUD's Flow chip open the road agent's
// Traffic tool on Lane speed, and a click on a car opens the route
// inspector — before the site sheet on Look, and on Lane speed.
//
// The 3D backend, because ground picking needs the scene snapshot only it
// captures. Its GPU asset warnings are expected here.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_inspection.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/traffic_vehicle_inspector.dart';
import 'package:acro_space_simulator/infrastructure/flutter/sim_view_control.dart';
import 'package:acro_space_simulator/infrastructure/flutter/simulation_view.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_overlay_state.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/render_backend.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../traffic/traffic_fixture.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    RoadOverlayState.instance.clear();
    AgentTuning.reset();
  });

  Future<void> pumpCity(WidgetTester t, CitySim colony) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: SimulationView(
        injectedCity: colony,
        cityMode: true,
        spawnDemoOrbiter: false,
        initialBackend: RenderBackend.flutterScene,
      ),
    ));
    // A few frames: picking needs the scene snapshot the frame captures.
    for (var i = 0; i < 3; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
  }

  Map<String, Object?> road([Map<String, String> p = const {}]) =>
      SimViewControl.instance.roadTool!(p);

  /// Long enough for a sheet to slide up or away, a frame at a time.
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> click(WidgetTester t, Offset at) async {
    final g = await t.createGesture(
        kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
    await g.down(at);
    await t.pump();
    await g.up();
    await t.pump();
  }

  testWidgets('V opens the Traffic tool on Lane speed, and closes it',
      (t) async {
    await pumpCity(t, starterKit(agentTraffic: true));
    expect(road()['tool'], 'inspect');
    await t.sendKeyEvent(LogicalKeyboardKey.keyV);
    await t.pump();
    expect(road()['tool'], 'traffic');
    expect(road()['trafficView'], 'laneSpeed');
    expect(find.text('70% and up'), findsOneWidget, reason: 'the legend');

    await t.sendKeyEvent(LogicalKeyboardKey.keyV);
    await t.pump();
    expect(road()['tool'], 'inspect', reason: 'V again puts it down');

    // From another view of the same tool, V goes to Lane speed.
    road({'tool': 'traffic', 'view': 'routes'});
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyV);
    await t.pump();
    expect(road()['tool'], 'traffic');
    expect(road()['trafficView'], 'laneSpeed');
  });

  testWidgets('the Flow chip opens the Traffic tool on Lane speed', (t) async {
    await pumpCity(t, starterKit(agentTraffic: true));
    final chip = find.textContaining('Flow ');
    expect(chip, findsOneWidget);
    await click(t, t.getCenter(chip));
    expect(road()['tool'], 'traffic');
    expect(road()['trafficView'], 'laneSpeed');
    await click(t, t.getCenter(chip));
    expect(road()['tool'], 'inspect', reason: 'and closes it');
  });

  testWidgets('setTrafficView and selectVehicle drive the same paths', (t) async {
    final city = town(agentTraffic: true);
    final h = _carOnTheRoad(city);
    await pumpCity(t, city);
    final c = SimViewControl.instance;
    expect(c.setTrafficView!('laneSpeed'),
        {'tool': 'traffic', 'trafficView': 'laneSpeed'});
    await t.pump();
    expect(c.setTrafficView!(null)['tool'], 'inspect');
    await t.pump();

    expect(c.selectVehicle!(-7), isNull, reason: 'no such car: nothing opens');
    final d = c.selectVehicle!(h);
    expect(d, isNotNull);
    await t.pump();
    await settle(t);
    final sheet = t.widget<VehicleInspectorSheet>(
        find.byType(VehicleInspectorSheet));
    expect(sheet.handle, h);
    final words = VehicleInspection.fromDescribe(d, roadName: city.roadNameOf)!;
    expect(find.text(words.lines[1]), findsOneWidget,
        reason: 'the sheet says what describe (the vehicle= hook) says');
    expect(RoadOverlayState.instance.lines, isNotEmpty,
        reason: 'its road ahead is laid over the world');
    SimViewControl.instance.clear();
    expect(SimViewControl.instance.selectVehicle, isNull);
    expect(SimViewControl.instance.setTrafficView, isNull);
  });

  testWidgets('a click on a car opens the route inspector — on Look, before '
      'the site sheet, and on Lane speed', (t) async {
    final city = town(agentTraffic: true);
    final h = _carOnTheRoad(city);
    await pumpCity(t, city);
    // Where on the screen the car stands: three ground points through the
    // road tool's own pick (an anchor, no snapping), an affine map between
    // the screen and the colony, solved for the car.
    road({'tool': 'road', 'snap': ''});
    Vec2 groundAt(Offset px) {
      road({'click': '${px.dx / 1600},${px.dy / 1000}'});
      final a = road()['anchor']! as Map;
      road({'key': 'escape'});
      return Vec2(a['e']! as double, a['n']! as double);
    }

    const s0 = Offset(800, 500), sx = Offset(900, 500), sy = Offset(800, 600);
    final g0 = groundAt(s0), gx = groundAt(sx), gy = groundAt(sy);
    final car = _positionOf(city, h);
    // car = g0 + (gx − g0)·u + (gy − g0)·v, for the screen steps u, v.
    final ax = gx - g0, ay = gy - g0;
    final det = ax.cross(ay);
    Offset step(Offset from, Vec2 r) => Offset(
        from.dx + 100 * r.cross(ay) / det, from.dy + 100 * ax.cross(r) / det);
    // The view is a perspective, not an affine map: a couple of steps of
    // the same map from where the last one landed close in on the point.
    Offset screenOf(Vec2 p) {
      var at = step(s0, p - g0);
      for (var i = 0; i < 3; i++) {
        at = step(at, p - groundAt(at));
      }
      expect(groundAt(at).distanceTo(p), lessThan(1.5),
          reason: 'the map lands on $p');
      return at;
    }

    final at = screenOf(car);
    expect(at.dx, inInclusiveRange(200, 1400), reason: 'the car is in view');
    expect(at.dy, inInclusiveRange(250, 900));

    // A point on a built lot beside the car, still within the pick's reach
    // of it (eight pixels, 4–20 m): where a site sheet would open if the
    // site were asked first.
    final pxM = groundAt(at + const Offset(10, 0)).distanceTo(car) / 10;
    final reachM = (8 * pxM).clamp(4.0, 20.0);
    Vec2? onLot;
    for (var deg = 0; deg < 360 && onLot == null; deg += 10) {
      final rad = deg * math.pi / 180;
      for (final m in [reachM - 1.5, reachM - 3]) {
        final p = car + Vec2(m * math.sin(rad), m * math.cos(rad));
        if (city.siteAt(p) != null) {
          onLot = p;
          break;
        }
      }
    }
    expect(onLot, isNotNull,
        reason: 'a built lot within ${reachM.toStringAsFixed(1)} m of the car');
    final besideAt = screenOf(onLot!);
    road({'tool': 'look'});
    await t.pump();

    await click(t, besideAt);
    await settle(t);
    expect(find.byType(VehicleInspectorSheet), findsOneWidget,
        reason: 'Look over a lot, beside a car: the car first');
    expect(find.text('Demolish'), findsNothing, reason: 'no site sheet');
    Navigator.of(t.element(find.byType(VehicleInspectorSheet))).pop();
    await settle(t);
    expect(find.byType(VehicleInspectorSheet), findsNothing);

    await t.sendKeyEvent(LogicalKeyboardKey.keyV);
    await t.pump();
    expect(road()['trafficView'], 'laneSpeed');
    await click(t, at);
    await settle(t);
    expect(find.byType(VehicleInspectorSheet), findsOneWidget,
        reason: 'Lane speed: the car');
    Navigator.of(t.element(find.byType(VehicleInspectorSheet))).pop();
    await settle(t);
  });
}

/// A car on a lane of [city]'s streets near the site, stalled where it
/// stands so a test can click it: its handle.
int _carOnTheRoad(CitySim city) {
  final a = city.agents;
  for (var i = 0; i < 600; i++) {
    city.advance(0.5);
    final f = a.frame;
    var best = -1;
    var bestM = 350.0;
    for (var row = 0; row < f.count; row++) {
      final h = f.handle[row];
      if (h < 0 || f.elem[row] < 0 || f.elem[row] >= a.laneGraph!.laneCount) {
        continue;
      }
      if (a.describe(h) == null) continue;
      final m = _positionOf(city, h).distanceTo(const Vec2(0, 0));
      if (m < bestM) {
        bestM = m;
        best = h;
      }
    }
    if (best >= 0) {
      a.debugStall(best);
      city.advance(0.5);
      return best;
    }
  }
  fail('no car took to the streets near the site in 300 s');
}

/// Where [handle] stands in the frame [city]'s agents last published.
Vec2 _positionOf(CitySim city, int handle) {
  final a = city.agents, f = a.frame;
  for (var row = 0; row < f.count; row++) {
    if (f.handle[row] != handle) continue;
    final out = Float64List(4);
    VehiclePicker.positionOn(a.laneGraph!, f.elem[row], f.s[row], out);
    return Vec2(out[0], out[1]);
  }
  fail('vehicle $handle is not in the frame');
}
