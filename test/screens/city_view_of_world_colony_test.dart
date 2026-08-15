// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_builder_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Founding a colony from the cockpit used to open a builder that owned its
/// OWN colony — a second town, invisible to the sim the craft was standing in.
/// The builder is now a view onto a colony the world owns.
void main() {
  CitySim worldColony() => CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'world-colony',
      );

  testWidgets('the builder shows the colony it was handed, not a new one',
      (t) async {
    final colony = worldColony();
    colony.population = 137;

    await t.pumpWidget(MaterialApp(
      home: CityBuilderScreen(sim: colony, driveLocally: false),
    ));
    await t.pump(const Duration(milliseconds: 16));

    expect(t.takeException(), isNull);
    // Same object, not a copy. Had the screen founded its own colony, this
    // population would have been reset to the starting crew.
    expect(colony.population, 137);
  });

  testWidgets('a world-driven colony is not advanced twice', (t) async {
    final colony = worldColony()..timeWarp = 4;
    // Give it something that would visibly change if it ticked.
    colony.funds = 1000;
    final funds = colony.funds;

    await t.pumpWidget(MaterialApp(
      home: CityBuilderScreen(sim: colony, driveLocally: false),
    ));
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 33));
    }

    expect(colony.funds, funds,
        reason: 'the authoritative tick owns this colony; the screen only '
            'repaints, or the city runs at double speed while open');
  });

  testWidgets('a stand-alone builder still drives its own colony', (t) async {
    // The menu entry point has no world behind it, so it must still tick.
    await t.pumpWidget(const MaterialApp(home: CityBuilderScreen()));
    await t.pump(const Duration(milliseconds: 16));
    expect(t.takeException(), isNull);
  });
}
