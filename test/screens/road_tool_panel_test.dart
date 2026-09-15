// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_build.dart';
import 'package:acro_space_simulator/domain/colony/city/road_snapper.dart';
import 'package:acro_space_simulator/domain/colony/city/road_traffic_model.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_edit_overlay.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_game_hud.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/road_tool_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The road tool's toolbar and the HUD's road money, built on their own: the
/// modes, the road menu, the elevation bar, the snapping menu, the readouts,
/// the info views — and upkeep in the budget, roads in the milestones.
void main() {
  CitySim colony({double population = 0, double funds = 5000}) =>
      CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'panel',
      )
        ..population = population
        ..funds = funds;

  Future<CityEditController> pumpTool(WidgetTester t, CitySim city,
      {CityEditTool tool = CityEditTool.roadSpline}) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final c = CityEditController()..set(tool);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CityEditOverlay(controller: c, city: city, onClose: () {}),
      ),
    ));
    await t.pump();
    return c;
  }

  group('the Road tool', () {
    testWidgets('its mode chips switch how a road is laid', (t) async {
      final c = await pumpTool(t, colony());
      for (final m in RoadToolMode.values) {
        await t.tap(find.text(m.label));
        await t.pump();
        expect(c.mode, m);
      }
    });

    testWidgets('the road menu opens a group; a locked type is shown greyed '
        'with the population that opens it', (t) async {
      final c = await pumpTool(t, colony());
      expect(find.text('Two-Lane'), findsOneWidget, reason: 'Small Roads open');
      await t.tap(find.text('Highways'));
      await t.pump();
      expect(find.text('Highway'), findsOneWidget);
      expect(find.text('opens at 200 pop'), findsWidgets,
          reason: 'never hidden: the gate is what to grow toward');
      await t.tap(find.text('Highway'));
      await t.pump();
      expect(c.roadType.id, 'two-lane', reason: 'a locked road is not held');
      expect(c.blocked, 'Opens at 200 population');
    });

    testWidgets('an open type is picked, with its price per cell', (t) async {
      final c = await pumpTool(t, colony(population: 5000));
      await t.tap(find.text('Highways'));
      await t.pump();
      expect(find.text('§70/cell'), findsWidgets);
      await t.tap(find.text('Highway'));
      await t.pump();
      expect(c.roadType.id, 'highway');
    });

    testWidgets('the elevation bar raises and lowers the road, by the step '
        'chosen', (t) async {
      final c = await pumpTool(t, colony());
      expect(find.text('Ground'), findsOneWidget);
      await t.tap(find.byIcon(Icons.keyboard_arrow_up));
      await t.pump();
      expect(find.text('+12 m'), findsOneWidget);
      await t.tap(find.text('6 m'));
      await t.pump();
      expect(c.elevationStepM, 6);
      await t.tap(find.byIcon(Icons.keyboard_arrow_up));
      await t.pump();
      expect(find.text('+18 m'), findsOneWidget);
      for (var i = 0; i < 5; i++) {
        await t.tap(find.byIcon(Icons.keyboard_arrow_down));
        await t.pump();
      }
      expect(find.text('−12 m'), findsOneWidget, reason: 'into a tunnel');
    });

    testWidgets('the snapping menu switches each option', (t) async {
      final c = await pumpTool(t, colony());
      for (final item in RoadSnapItem.values) {
        expect(item.isOn(c.snap), isTrue);
        await t.tap(find.byTooltip('Snapping'));
        await t.pumpAndSettle();
        await t.tap(find.text(item.label));
        await t.pumpAndSettle();
        expect(item.isOn(c.snap), isFalse, reason: item.label);
      }
      expect(c.snap.roads || c.snap.angles || c.snap.zoningGrid ||
          c.snap.guidelines, isFalse);
    });

    testWidgets('the readouts price the stretch under the cursor', (t) async {
      final city = colony(funds: 5000);
      final c = await pumpTool(t, city);
      c.snap = RoadSnapOptions.off;
      expect(find.text('Click the ground to start a road'), findsOneWidget);
      c.clickAt(city, const Vec2(0, 0));
      final q = c.previewTo(city, const Vec2(0, 160))!.quote;
      c.changed();
      await t.pump();
      expect(find.text('160 m'), findsOneWidget);
      expect(find.text(formatMoney(q.cost)), findsOneWidget);
      expect(find.text('§${q.upkeepPerWeek.toStringAsFixed(2)}/wk upkeep'),
          findsOneWidget);

      city.funds = 0;
      c.previewTo(city, const Vec2(0, 160));
      c.changed();
      await t.pump();
      final cost = t.widget<Text>(find.text(formatMoney(q.cost)));
      expect(cost.style?.color, const Color(0xFFFF8A80),
          reason: 'red when the treasury cannot pay it');
      expect(find.text('Not enough money: ${formatMoney(q.cost)} needed'),
          findsOneWidget);
    });

    testWidgets('raised, the readouts say how much of it stands on piers',
        (t) async {
      final city = colony(funds: 50000);
      final c = await pumpTool(t, city);
      c.snap = RoadSnapOptions.off;
      c.stepElevation(1);
      c.clickAt(city, const Vec2(0, 0));
      c.previewTo(city, const Vec2(0, 160));
      c.changed();
      await t.pump();
      expect(find.text('Elevated 160 m'), findsOneWidget);
      expect(find.textContaining('Grade 0.0%'), findsOneWidget);
    });
  });

  group('the Traffic tool', () {
    testWidgets('sits beside Road, and the strip still names each tool once',
        (t) async {
      await pumpTool(t, colony(), tool: CityEditTool.inspect);
      for (final label in ['Look', 'Zone', 'Road', 'Traffic', 'Build']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('offers its four views; the rename field only while Adjust '
        'has a road', (t) async {
      final city = colony();
      final id =
          city.commitRoad(const [Vec2(0, 0), Vec2(0, 200)], RoadClass.street)!;
      final c = await pumpTool(t, city, tool: CityEditTool.traffic);
      for (final v in TrafficInfoView.values) {
        expect(find.text(v.label), findsOneWidget);
      }
      expect(find.byType(TextField), findsNothing);
      await t.tap(find.text('Adjust'));
      await t.pump();
      expect(c.trafficView, TrafficInfoView.adjust);
      expect(find.byType(TextField), findsNothing);

      c.selectRoad(id);
      await t.pump();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text(city.roadNameOf(id)), findsOneWidget);
      await t.enterText(find.byType(TextField), 'Harbour Road');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(city.roadNameOf(id), 'Harbour Road');
    });

    testWidgets('Enter names the road and hands the keyboard back to what '
        'had it', (t) async {
      // The field's own Enter unfocused to the route's scope — an ancestor
      // of the world's key node — and keys bubble up from focus, never
      // down: nothing reached the world until it was clicked.
      t.view.physicalSize = const Size(1600, 1000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      final city = colony();
      final id =
          city.commitRoad(const [Vec2(0, 0), Vec2(0, 200)], RoadClass.street)!;
      final world = FocusNode(debugLabel: 'world');
      addTearDown(world.dispose);
      final c = CityEditController()
        ..set(CityEditTool.traffic)
        ..setTrafficView(TrafficInfoView.adjust)
        ..selectRoad(id);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Focus(
            focusNode: world,
            autofocus: true,
            child: CityEditOverlay(controller: c, city: city, onClose: () {}),
          ),
        ),
      ));
      await t.pump();
      expect(world.hasPrimaryFocus, isTrue);
      await t.tap(find.byType(TextField));
      await t.pump();
      expect(world.hasPrimaryFocus, isFalse, reason: 'typing');
      await t.enterText(find.byType(TextField), 'Harbour Road');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(city.roadNameOf(id), 'Harbour Road');
      expect(world.hasPrimaryFocus, isTrue,
          reason: 'the keys go back to the world the moment the name is in');
    });

    testWidgets('Adjust: while an end is dragged, the row prices letting go',
        (t) async {
      final city = colony(funds: 5000);
      final id =
          city.commitRoad(const [Vec2(0, 0), Vec2(0, 200)], RoadClass.street)!;
      final c = await pumpTool(t, city, tool: CityEditTool.traffic);
      c.setTrafficView(TrafficInfoView.adjust);
      c.selectRoad(id);
      await t.pump();
      expect(find.textContaining('Drag an end circle'), findsOneWidget);
      final m = c.previewMoveEnd(city, atStart: false, to: const Vec2(0, 260))!;
      expect(m.quote.cost, greaterThan(0));
      c.changed();
      await t.pump();
      expect(find.text('Re-lay ${formatMoney(m.quote.cost)}'), findsOneWidget);
      expect(find.text('260 m'), findsOneWidget);
      expect(find.textContaining('Drag an end circle'), findsNothing);
    });

    testWidgets('Routes counts one route as a route', (t) async {
      final city = colony();
      final id =
          city.commitRoad(const [Vec2(0, 0), Vec2(0, 200)], RoadClass.street)!;
      for (var i = 0; i < 1000 && !city.trafficReadout.hasRun; i++) {
        city.roadTraffic.advance(0.1);
      }
      expect(city.trafficReadout.hasRun, isTrue);
      final c = await pumpTool(t, city, tool: CityEditTool.traffic);
      c.selectRoad(id);
      final name = city.roadNameOf(id);
      for (final (n, text) in [
        (1, '$name: 1 route'),
        (2, '$name: 2 routes'),
        (0, '$name: 0 routes'),
      ]) {
        c.routeCount = n;
        c.changed();
        await t.pump();
        expect(find.text(text), findsOneWidget, reason: '$n');
      }
    });

    testWidgets('Routes filters by why a trip travels', (t) async {
      final c = await pumpTool(t, colony(), tool: CityEditTool.traffic);
      expect(find.text('Goods'), findsOneWidget);
      await t.tap(find.text('Goods'));
      await t.pump();
      expect(c.routeKinds.contains(TripKind.goods), isFalse);
      await t.tap(find.text('Goods'));
      await t.pump();
      expect(c.routeKinds.contains(TripKind.goods), isTrue);
    });
  });

  group('the HUD', () {
    Future<void> pumpHud(WidgetTester t, CitySim city) async {
      t.view.physicalSize = const Size(1600, 1000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(body: CityGameHud(city: city)),
      ));
      await t.pump();
    }

    testWidgets('the budget shows what the roads cost to keep', (t) async {
      final city = colony();
      city.commitRoad(const [Vec2(0, -200), Vec2(0, 200)], RoadClass.street);
      await pumpHud(t, city);
      await t.tap(find.text('Budget'));
      await t.pump();
      expect(find.text('Road upkeep'), findsOneWidget);
      expect(find.text('−${city.roadUpkeepRate.toStringAsFixed(2)} §/s'),
          findsOneWidget);
      expect(
          find.text('${formatMoney(city.roadUpkeepPerWeek)} a week for 1 road'),
          findsOneWidget);
      expect(city.roadUpkeepPerWeek, greaterThan(0));
      expect(find.textContaining('BUILDINGS are paid in ore'), findsOneWidget);
      expect(find.textContaining('CONSTRUCTION is paid in ore'), findsNothing);
    });

    testWidgets('a milestone lists the roads it opens', (t) async {
      await pumpHud(t, colony());
      await t.tap(find.text('Goals'));
      await t.pump();
      expect(find.text('Highway'), findsOneWidget);
      expect(find.text('Highway Ramp'), findsOneWidget);
      expect(find.text('Two-Lane Road with Decorative Trees'), findsOneWidget);
    });
  });
}
