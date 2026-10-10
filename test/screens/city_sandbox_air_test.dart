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
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_builder_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_panels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The flat sandbox once its own air has moved: the colony's body is then a
/// republished one that is not in its list of worlds, and the planet picker
/// — matched by identity — failed its assert on every build, taking the
/// whole side pane (and in the builder, the map with it) down with it.
void main() {
  final bodies =
      RealSolarSystem.build().all.where((b) => !b.isStar).toList();
  CityBuildingSpec spec(String type) =>
      kUtilCatalog.firstWhere((s) => s.type == type);

  /// A Mars colony whose Greenhouse Factory moves its sky within a step.
  CitySim factoryColony() {
    final city = CitySim.found(
      const CityConfig(bodyId: 'mars', gridSize: 30),
      bodies: bodies,
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
    city.placeUtil(h + 1, spec('greenhousefactory'));
    city.placeUtil(h + 4, spec('terraformer'));
    city.population = 2000;
    city.stock[Commodity.electronics] = 1e6;
    city.recompute();
    return city;
  }

  bool listed(CitySim c) => c.bodies.any((b) => identical(b, c.body));

  testWidgets('the planet picker survives a republished body, and a re-pick '
      'of the same world keeps its air', (t) async {
    final city = factoryColony();
    final air = LocalColonyAtmosphere();
    for (var i = 0; i < 40 && listed(city); i++) {
      city.advance(0.5);
      air.step(city, 86400.0 * 5);
    }
    expect(listed(city), isFalse, reason: 'the sandbox republished the body');
    final moved = city.body;

    t.view.physicalSize = const Size(900, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: _ResitingHost(city)));
    expect(t.takeException(), isNull);
    final picker = find.byType(DropdownButton<CelestialBody>);
    expect(picker, findsOneWidget);
    expect(t.widget<DropdownButton<CelestialBody>>(picker).value?.id,
        const BodyId('mars'));

    // Re-pick Mars: no change, so no reference air for a frame.
    await t.tap(picker);
    await t.pumpAndSettle();
    await t.tap(find.text('Mars').last);
    await t.pumpAndSettle();
    expect(identical(city.body, moved), isTrue);

    // Pick another world: the colony moves there.
    await t.tap(picker);
    await t.pumpAndSettle();
    await t.tap(find.text('Moon').last);
    await t.pumpAndSettle();
    expect(city.body.id, const BodyId('moon'));
    expect(t.takeException(), isNull);
  });

  testWidgets('the stand-alone builder keeps its screen as its air moves',
      (t) async {
    final city = factoryColony()..timeWarp = 20;
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: CityBuilderScreen(sim: city)));
    for (var i = 0; i < 12 && listed(city); i++) {
      await t.pump(const Duration(seconds: 2));
    }
    expect(listed(city), isFalse, reason: 'the sandbox republished the body');
    expect(city.planetAir!.molesOf(AtmosphereGas.oxygen), greaterThan(0));
    await t.pump(const Duration(milliseconds: 100));
    expect(t.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byType(TabBar), findsWidgets);
  });
}

/// The colony panels as the flat builder wears them: free to re-site.
class _ResitingHost extends StatefulWidget {
  const _ResitingHost(this.city);
  final CitySim city;
  @override
  State<_ResitingHost> createState() => _ResitingHostState();
}

class _ResitingHostState extends State<_ResitingHost>
    with CityPanels<_ResitingHost> {
  @override
  CitySim get sim => widget.city;

  @override
  bool get panelCanResite => true;

  @override
  void panelChanged() => setState(() {});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: ListView(children: cityWorldPanel()),
      );
}
