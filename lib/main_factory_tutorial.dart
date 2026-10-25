// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Tutorial entrypoint: boots STRAIGHT into the 'Rocket Parts' scenario on
/// an empty 120 × 80 m hall (lib/domain/colony/city/factory/
/// factory_scenario.dart).
///
///   fvm flutter run -d windows --profile -t lib/main_factory_tutorial.dart
///
/// The floor is the real `FactoryFloor`; the tutorial card walks the loop
/// (dock → belt → machine → arm → handler → shipping dock), then leaves an
/// open goal: a plant that makes rocket parts at the real plant's rate.
/// Docks receive only what the scenario supplies (tubes and electronics,
/// or ore alone for the deep-chain challenge) through its
/// `ScenarioColonyPort`; every unlock is on and the editor drives the
/// floor itself. Profile mode because the floor sim is the point: debug
/// mode's JIT is several times slower and hides real frame costs.
library;

import 'package:flutter/material.dart';

import 'domain/colony/city/factory/dock_logistics.dart';
import 'domain/colony/city/factory/factory_floor.dart';
import 'domain/colony/city/factory/factory_scenario.dart';
import 'domain/colony/city/factory/factory_unlocks.dart';
import 'domain/colony/city/factory/supply_world.dart';
import 'infrastructure/flutter/screens/factory/factory_floor_screen.dart';

void main() {
  runApp(const FactoryTutorialApp());
}

class FactoryTutorialApp extends StatefulWidget {
  const FactoryTutorialApp({super.key});

  @override
  State<FactoryTutorialApp> createState() => _FactoryTutorialAppState();
}

class _FactoryTutorialAppState extends State<FactoryTutorialApp> {
  final FactoryScenario scenario = rocketPartsScenario();
  late final FactoryFloor floor = FactoryFloor.fromBlueprint(
      scenario.blueprint(),
      unlocks: FactoryUnlocks.all)
    // Goods come by truck from finite suppliers (§10 items 4, 11); the
    // Orders panel's switch brings back the old unlimited feed.
    ..logistics = FloorLogistics(world: SupplyWorld.sandbox());

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Factory Floor: Rocket Parts tutorial',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: FactoryFloorScreen(
        sim: floor,
        title: 'Tutorial: ${scenario.title}',
        scenario: scenario,
        unlocks: FactoryUnlocks.all,
      ),
    );
  }
}
