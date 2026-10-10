// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/application/usecases/local_colony_atmosphere.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere_service.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_atmosphere_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The atmosphere panel (docs/plans/terraforming.md §6 phase 3): pumped
/// over a real colony whose towers have moved its planet's real air, it
/// must read back that air — pressure, mix, temperature trend, escape and
/// its suppression, the stores in the ground — and say which colony's
/// towers are moving which gas.
void main() {
  final bodies =
      RealSolarSystem.build().all.where((b) => !b.isStar).toList();
  CityBuildingSpec spec(String type) =>
      kUtilCatalog.firstWhere((s) => s.type == type);

  CitySim towered(List<String> types) {
    final city = CitySim.found(
      const CityConfig(bodyId: 'mars', gridSize: 30),
      bodies: bodies,
      name: 'Bradbury',
    )..infiniteRobotics = true;
    final g = city.grid;
    final h = city.hubKey;
    for (var x = -5; x <= 12; x++) {
      city.addRoad(h - g + x);
    }
    city.placeUtil(h - 1, spec('fusion'));
    city.placeUtil(h - 2, spec('fusion'));
    city.placeUtil(h - 3, spec('datacenter'));
    city.placeUtil(h - 4, spec('datacenter'));
    for (var i = 0; i < types.length; i++) {
      city.placeUtil(h + 1 + 2 * i, spec(types[i]));
    }
    city.population = 2000;
    city.stock[Commodity.electronics] = 1e6;
    city.recompute();
    return city;
  }

  Future<void> pump(WidgetTester t, CitySim city) async {
    t.view.physicalSize = const Size(700, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: ListView(children: [AtmospherePanel(city: city)])),
    ));
  }

  String rowText(WidgetTester t, String key) => t
      .widgetList<Text>(
          find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)))
      .map((w) => w.data ?? '')
      .join(' | ');

  testWidgets('it reads the live sky and says who is moving it', (t) async {
    final city = towered([
      TerraformTowers.oxygenator,
      TerraformTowers.greenhouseFactory,
      TerraformTowers.regolithBaker,
    ]);
    final air = LocalColonyAtmosphere();
    for (var i = 0; i < 20; i++) {
      city.advance(0.5);
      air.step(city, 86400.0 * 5);
    }
    final state = air.state!;
    await pump(t, city);

    // The pressure row is the published body's, in the panel's units.
    final p = city.body.atmosphere!.seaLevelPressure;
    expect(rowText(t, 'atmo-pressure'), contains('${p.toStringAsFixed(0)} Pa'));
    // The oxygen the towers vented is in the mix.
    final o2 = city.body.composition!.fractions[AtmosphereGas.oxygen]!;
    expect(o2, greaterThan(0.003), reason: 'twice bare Mars');
    expect(rowText(t, 'atmo-gas-oxygen'), contains('O₂'));
    expect(rowText(t, 'atmo-gas-oxygen'), contains('${(o2 * 100).toStringAsFixed(2)}%'));
    // The factory's agent, and the warming it drives.
    expect(state.greenhouseAgentMoles, greaterThan(0));
    expect(find.byKey(const Key('atmo-agent')), findsOneWidget);
    expect(rowText(t, 'atmo-temperature'), contains('warming'));
    // Escape and its (absent) suppression.
    expect(rowText(t, 'atmo-suppression'), contains('0%'));
    expect(find.byKey(const Key('atmo-escape')), findsOneWidget);
    // The stores, the bakeable ones drawn down.
    expect(rowText(t, 'atmo-store-carbonates'), contains('Carbonates'));
    expect(state.reservoirs.firstWhere((r) => r.name == 'carbonates').moles,
        lessThan(state.reservoirs
            .firstWhere((r) => r.name == 'carbonates')
            .referenceMoles));
    // Who is doing it: the towers, by process and by colony.
    expect(rowText(t, 'atmo-process-oxygenator'), contains('O₂ +'));
    expect(rowText(t, 'atmo-process-oxygenator'), contains('CO₂ −'),
        reason: 'the towers split the CO2 they turn into oxygen');
    expect(rowText(t, 'atmo-process-greenhouse'), contains('PFC +'));
    expect(rowText(t, 'atmo-process-baker'), contains('CO₂ +'));
    final mine = rowText(t, 'atmo-colony-${city.id}');
    expect(mine, contains('Bradbury (this colony)'));
    expect(mine, contains('Terraforming Towers: CO₂ −'));
    expect(RegExp(r'Terraforming Towers: [^|]*O₂ \+').hasMatch(mine), isTrue);
    expect(mine, contains('Greenhouse Factories: PFC +'));
    // And the progress readout is the derived sky's.
    expect(rowText(t, 'atmo-progress'),
        contains('${(city.terraform * 100).floor()}%'));
  });

  testWidgets('with arrays running it shows the escape they hold', (t) async {
    final city = CitySim.found(
      const CityConfig(bodyId: 'moon', gridSize: 12),
      bodies: bodies,
    );
    final air = LocalColonyAtmosphere()..step(city, 0);
    final state = air.state!;
    state.pendingFlows.addColony(
        pollutionRate: 0,
        oxygenatorRun: 50,
        towers: TowerRuns()..retention = 3,
        dt: 86400,
        colony: 'x');
    const PlanetAtmosphereService()
        .advance(state, state.takePendingFlows()!, dt: 86400);
    await pump(t, city);
    expect(rowText(t, 'atmo-suppression'), contains('88%'));
    expect(rowText(t, 'atmo-escape'), contains('Pa/yr'));
  });

  testWidgets('without an integrated planet it says why nothing moves',
      (t) async {
    final city = CitySim.found(
      const CityConfig(bodyId: 'mars', gridSize: 12),
      bodies: bodies,
    );
    await pump(t, city);
    expect(find.byKey(const Key('atmo-pressure')), findsOneWidget);
    expect(find.textContaining('Nothing here integrates'), findsOneWidget);
  });
}
