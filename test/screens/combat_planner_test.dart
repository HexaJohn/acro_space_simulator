// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/combat/operation_registry.dart';
import 'package:acro_space_simulator/domain/multiplayer/command.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/combat/operation_planner_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

void main() {
  final barracks = kUtilCatalog.firstWhere((s) => s.type == 'barracks');

  CitySim moon(String id) => quiet(CityStarterKit.found(
        bodies: fixtureBodies,
        config: const CityConfig(bodyId: 'moon', gridSize: 20),
        id: id,
        name: id == 'src' ? 'Garrison Town' : 'Rebel Port',
      ));

  CitySim source() {
    final c = moon('src');
    var placed = 0;
    for (final lot in freeLots(c)) {
      if (placed == 2) break;
      if (place(c, lot.id, barracks)) placed++;
    }
    c.stock[Commodity.rations] = 400;
    c.stock[Commodity.guns] = 80;
    c.stock[Commodity.ammo] = 400;
    c.population = 200;
    run(c, 1);
    return c;
  }

  CitySim target() => moon('tgt')
    ..population = 60
    ..loyalty.stage = LoyaltyStage.standoff
    ..loyalty.portSeized = true;

  Future<OperationRegistry> pump(WidgetTester t, List<CitySim> sources,
      {required List<LaunchOperationCommand> launched}) async {
    final reg = OperationRegistry();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OperationPlannerSheet(
          target: target(),
          sources: sources,
          registry: reg,
          onLaunch: launched.add,
        ),
      ),
    ));
    return reg;
  }

  testWidgets('lists what each colony can send, previews it, and launches a '
      'command', (t) async {
    final launched = <LaunchOperationCommand>[];
    await pump(t, [source()], launched: launched);
    expect(find.text('Garrison Town'), findsOneWidget);
    expect(find.text('Barracks'), findsNWidgets(2));
    // The preview fills in over frames.
    for (var i = 0; i < 200; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(find.byKey(const Key('planner-preview')), findsOneWidget);
    expect(find.textContaining('You lose'), findsOneWidget);
    expect(find.textContaining('Troopers are your colonists'), findsOneWidget);
    await t.ensureVisible(find.byKey(const Key('planner-launch')));
    await t.pump();
    await t.tap(find.byKey(const Key('planner-launch')));
    await t.pump();
    final cmd = launched.single;
    expect(cmd.targetColonyId, 'tgt');
    expect(cmd.draws, hasLength(2));
    expect(cmd.draws.every((d) => d.colonyId == 'src' && d.count > 0), isTrue);
    expect(cmd.garrison, greaterThanOrEqualTo(2));
  });

  testWidgets('with no colony to send from it says what is needed, and cannot '
      'launch', (t) async {
    final launched = <LaunchOperationCommand>[];
    await pump(t, const [], launched: launched);
    expect(find.textContaining('cannot be shipped in'), findsOneWidget);
    final launch = t.widget<FilledButton>(find.byKey(const Key('planner-launch')));
    expect(launch.onPressed, isNull);
  });

  testWidgets('against an independent colony: take it, ROE, a garrison of one at '
      'least, and the command carries the ROE', (t) async {
    t.view.physicalSize = const Size(1200, 2000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final launched = <LaunchOperationCommand>[];
    final rebels = moon('tgt')..population = 80;
    rebels.loyalty
      ..allegiance = Allegiance.independent
      ..stage = LoyaltyStage.seceded
      ..independentAtS = 0;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OperationPlannerSheet(
          target: rebels,
          sources: [source()],
          registry: OperationRegistry(),
          onLaunch: launched.add,
        ),
      ),
    ));
    expect(find.text('Take Rebel Port by force'), findsOneWidget);
    expect(find.text('Garrison to hold the colony'), findsOneWidget);
    expect(find.textContaining('A win occupies it'), findsOneWidget);
    await t.tap(find.byKey(const Key('planner-roe-standard')));
    await t.pump();
    expect(find.textContaining('kill townsfolk'), findsOneWidget);
    for (var i = 0; i < 300; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(find.textContaining('You lose'), findsOneWidget);
    expect(find.textContaining('; its defenders'), findsOneWidget);
    await t.ensureVisible(find.byKey(const Key('planner-launch')));
    await t.pump();
    await t.tap(find.byKey(const Key('planner-launch')));
    await t.pump();
    final cmd = launched.single;
    expect(cmd.roe, 'standard');
    expect(cmd.kitDays, 6);
    expect(cmd.garrison, greaterThanOrEqualTo(1));
  });

  test('sources are every other colony that takes orders', () {
    final a = moon('a'), b = moon('b'), t0 = moon('t');
    b.loyalty.allegiance = Allegiance.independent;
    expect([for (final c in forceSourcesFor(t0, [t0, b, a])) c.id], ['a']);
  });
}
