// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_edit_overlay.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_game_hud.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/road_tool_scene.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/traffic_lane_speed_overlay.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/traffic_vehicle_inspector.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_overlay_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// The Lane speed view (docs/plans/agent-traffic.md §13.9, §18 slice 2 as
/// agreed with the road side): the fourth tab of the road agent's Traffic
/// tool, its legend, its ribbons coloured by band, the 0.5 Hz ceiling on
/// what the renderer is made to re-mesh — and the HUD's Flow chip, which
/// opens it instead of a drawer.
void main() {
  final o = RoadOverlayState.instance;
  setUp(o.clear);
  tearDown(() {
    o.clear();
    AgentTuning.reset();
  });

  /// A built town whose own agents have measured their lanes at least once.
  CitySim measuredTown() {
    final city = town(agentTraffic: true);
    for (var i = 0; i < 200 && city.agents.laneSpeeds.pct == null; i++) {
      city.advance(0.5);
    }
    expect(city.agents.laneSpeeds.pct, isNotNull,
        reason: 'the first congestion epoch never came');
    return city;
  }

  /// A flat world: colony-local P at lift H is body-fixed (P.e, P.n, 1000 + H).
  Vector3 flatDrape(Vec2 p, [double liftM = 0]) => Vector3(p.e, p.n, 1000 + liftM);

  group('bands', () {
    test('green from 70, amber from 40, red below', () {
      expect(AgentLaneSpeeds.band(100), 2);
      expect(AgentLaneSpeeds.band(70), 2);
      expect(AgentLaneSpeeds.band(69), 1);
      expect(AgentLaneSpeeds.band(40), 1);
      expect(AgentLaneSpeeds.band(39), 0);
      expect(AgentLaneSpeeds.band(0), 0);
      expect(TrafficLaneSpeedOverlay.argbOfBand(2),
          TrafficLaneSpeedOverlay.greenArgb);
      expect(TrafficLaneSpeedOverlay.argbOfBand(1),
          TrafficLaneSpeedOverlay.amberArgb);
      expect(TrafficLaneSpeedOverlay.argbOfBand(0),
          TrafficLaneSpeedOverlay.redArgb);
    });
  });

  group('the rebuild gate', () {
    test('the first read is due; after it, a new revision waits out 2 s', () {
      final g = LaneSpeedGate();
      expect(g.due(1, 1, 0), isTrue);
      g.took(1, 1, 0);
      expect(g.due(1, 1, 10000000), isFalse, reason: 'nothing moved');
      expect(g.due(2, 1, 500000), isFalse, reason: 'moved, 0.5 s on');
      expect(g.due(2, 1, 1999999), isFalse);
      expect(g.due(2, 1, 2000000), isTrue);
      g.took(2, 1, 2000000);
      expect(g.due(2, 2, 2100000), isFalse, reason: 'a rebuild waits too');
      expect(g.due(2, 1, 4100000, 'graded'), isTrue,
          reason: 'the ground moved, 2 s on');
      g.reset();
      expect(g.due(2, 1, 0), isTrue, reason: 'forgotten: due at once');
    });

    test('ribbons re-read at most every 2 s however often the speeds move, '
        'and a read with every lane in its band hands back the same list', () {
      final city = measuredTown();
      final speeds = city.agents.laneSpeeds;
      var nowUs = 0;
      final view = TrafficLaneSpeedOverlay(clockUs: () => nowUs);
      final first = view.lines(speeds, drape: flatDrape, bodyId: 'earth');
      expect(view.gate.reads, 1);
      expect(view.builds, 1);
      expect(first, isNotEmpty);

      // Ten agent seconds a step — five epochs, the revision moving every
      // step — against a quarter of a second of the view's clock.
      var revisions = 0;
      var lastRev = speeds.revision;
      var lines = first;
      for (var step = 1; step <= 40; step++) {
        for (var i = 0; i < 20; i++) {
          city.advance(0.5);
        }
        nowUs += 250000;
        if (speeds.revision != lastRev) revisions++;
        lastRev = speeds.revision;
        final next = view.lines(speeds, drape: flatDrape, bodyId: 'earth');
        if (!identical(next, lines)) {
          expect(view.gate.reads, greaterThan(1));
        }
        lines = next;
      }
      expect(revisions, greaterThan(30), reason: 'the speeds kept moving');
      // 10 s of the view's clock: the first read, then one every 2 s.
      expect(view.gate.reads, lessThanOrEqualTo(1 + 10 ~/ 2));
      expect(view.builds, lessThanOrEqualTo(view.gate.reads));
    });

    test('a ribbon down every lane, in the colour of its band', () {
      final city = measuredTown();
      final speeds = city.agents.laneSpeeds;
      final view = TrafficLaneSpeedOverlay(clockUs: () => 0);
      final lines = view.lines(speeds, drape: flatDrape, bodyId: 'earth');
      final pct = speeds.pct!;
      var drawn = 0;
      for (var lane = 0; lane < speeds.laneCount; lane++) {
        if (speeds.laneLine(lane).length >= 2) drawn++;
      }
      expect(lines, hasLength(drawn));
      var k = 0;
      for (var lane = 0; lane < speeds.laneCount; lane++) {
        final pts = speeds.laneLine(lane, stepM: TrafficLaneSpeedOverlay.stepM);
        if (pts.length < 2) continue;
        final l = lines[k++];
        expect(l.argb,
            TrafficLaneSpeedOverlay.argbOfBand(AgentLaneSpeeds.band(pct[lane])));
        expect(l.pointsBF.first, flatDrape(pts.first));
        expect(l.pointsBF, hasLength(pts.length));
      }
    });

    test('with agents off there is nothing to draw', () {
      final view = TrafficLaneSpeedOverlay(clockUs: () => 0);
      expect(
          view.lines(town().agents.laneSpeeds,
              drape: flatDrape, bodyId: 'earth'),
          isEmpty);
    });
  });

  group('the Traffic tool on Lane speed', () {
    test('the scene publishes the ribbons once, and a hover over them costs '
        'the renderer nothing', () {
      final city = measuredTown();
      final s = RoadToolScene()
        ..bindCustom(
          bodyId: 'earth',
          toBodyFixed: (p, h) => Vector3(p.e, p.n, 1000 + h),
          height: (_) => 0,
        );
      final c = CityEditController()
        ..set(CityEditTool.traffic)
        ..setTrafficView(TrafficInfoView.laneSpeed);
      s.showTraffic(city, c);
      expect(o.lines, isNotEmpty);
      expect(o.lines.first.argb,
          anyOf(TrafficLaneSpeedOverlay.greenArgb,
              TrafficLaneSpeedOverlay.amberArgb,
              TrafficLaneSpeedOverlay.redArgb));
      final rev = o.revision;
      for (var i = 1; i <= 10; i++) {
        s.hover = Vec2(5.0 + i, 5);
        s.showTraffic(city, c);
      }
      expect(o.revision, rev, reason: 'only the mouse moved');
    });

    Future<CityEditController> pumpTraffic(WidgetTester t, CitySim city) async {
      t.view.physicalSize = const Size(1600, 1000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      final c = CityEditController()..set(CityEditTool.traffic);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CityEditOverlay(controller: c, city: city, onClose: () {}),
        ),
      ));
      await t.pump();
      return c;
    }

    testWidgets('its tab is the fourth, and its row is the legend',
        (t) async {
      final city = town(agentTraffic: true);
      final c = await pumpTraffic(t, city);
      expect(find.text('Lane speed'), findsOneWidget);
      expect(find.byType(TrafficLaneSpeedLegend), findsNothing);
      await t.tap(find.text('Lane speed'));
      await t.pump();
      expect(c.trafficView, TrafficInfoView.laneSpeed);
      expect(find.byType(TrafficLaneSpeedLegend), findsOneWidget);
      expect(find.text('70% and up'), findsOneWidget);
      expect(find.text('40–69%'), findsOneWidget);
      expect(find.text('under 40%'), findsOneWidget);
      expect(find.textContaining('Measuring lane speeds'), findsOneWidget,
          reason: 'nothing measured yet');
    });

    testWidgets('the legend says why there is nothing to colour with agents '
        'off', (t) async {
      final c = await pumpTraffic(t, town());
      c.setTrafficView(TrafficInfoView.laneSpeed);
      await t.pump();
      expect(find.textContaining('agent traffic, which is off'),
          findsOneWidget);
    });
  });

  group('the HUD', () {
    Future<void> pumpHud(WidgetTester t, CitySim city,
        {VoidCallback? onToggleTraffic, bool trafficOn = false}) async {
      t.view.physicalSize = const Size(1600, 1000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CityGameHud(
            city: city,
            trafficOn: trafficOn,
            onToggleTraffic: onToggleTraffic,
          ),
        ),
      ));
      await t.pump();
    }

    testWidgets('the Flow chip reads one minus the agents\' congestion and '
        'opens Lane speed instead of a drawer', (t) async {
      final city = town(agentTraffic: true);
      var opened = 0;
      await pumpHud(t, city, onToggleTraffic: () => opened++);
      final pct = ((1 - city.agents.stats.congestionIndex) * 100).round();
      final chip = find.textContaining('Flow $pct%');
      expect(chip, findsOneWidget);
      expect(find.textContaining('${city.agents.liveVehicles} car'),
          findsOneWidget);
      await t.tap(chip);
      await t.pump();
      expect(opened, 1);
      expect(find.text('BUDGET'), findsNothing);
      expect(find.text('MILESTONES'), findsNothing, reason: 'no drawer opens');
    });

    testWidgets('no Flow chip without agents', (t) async {
      await pumpHud(t, town(), onToggleTraffic: () {});
      expect(find.textContaining('Flow '), findsNothing);
    });
  });

  group('the route inspector', () {
    test('a vehicle under the click comes before the site, which is then '
        'never asked', () {
      var asked = 0;
      String? site() {
        asked++;
        return 'lot-1';
      }

      final car = InspectOrder.pick(() => 7, site);
      expect(car?.vehicle, 7);
      expect(car?.site, isNull);
      expect(asked, 0, reason: 'the site sheet is not even looked up');

      final building = InspectOrder.pick(() => null, site);
      expect(building?.vehicle, isNull);
      expect(building?.site, 'lot-1');
      expect(asked, 1);

      expect(InspectOrder.pick<String>(() => null, () => null), isNull);
    });
  });
}
