// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Dev entrypoint: boots STRAIGHT into the factory floor editor on a REAL
/// floor (docs/plans/factory-floors.md §4, phases 2 and 4).
///
///   fvm flutter run -d windows -t lib/main_factory_dev.dart
///
/// The floor is the real `FactoryFloor`, built from a plant's template so
/// what you see is what a colony would run. A picker in the strip above
/// the editor switches plants: every placed-plant type that has a template
/// ([kFactoryDevPlants] filtered by `factoryTemplateFor`, so new templates
/// appear here the moment they are wired, and none is hard-wired), plus
/// "Blank hall" — an empty floor of a chosen size to design from scratch —
/// and "Tutorial: Rocket Parts", the guided scenario
/// (`lib/main_factory_tutorial.dart` boots straight into it).
/// Receiving and shipping run against the sandbox colony
/// (`InfiniteColonyPort`), every unlock is on, and the editor drives the
/// floor itself. "Save as blueprint" prints the blueprint JSON.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import 'domain/colony/city/factory/factory_floor.dart';
import 'domain/colony/city/factory/factory_grid.dart';
import 'domain/colony/city/factory/factory_scenario.dart';
import 'domain/colony/city/factory/factory_templates.dart';
import 'domain/colony/city/factory/floor_blueprint.dart';
import 'infrastructure/flutter/screens/factory/factory_floor_screen.dart';

/// Placed-plant types that may get a floor (docs/plans/factory-floors.md
/// §2 "Candidates"). Only those with a template are offered.
const List<String> kFactoryDevPlants = [
  'steelmill',
  'refinery',
  'electronics',
  'rocketfactory',
  'gunfactory',
  'missilefactory',
  'rationsfactory',
];

/// The picker's value for an empty hall.
const String kBlankHall = 'blank';

/// The picker's value for the Rocket Parts tutorial scenario.
const String kRocketTutorial = 'tutorial:rocketParts';

/// Blank-hall sizes offered, in tiles (2 m each): a workshop, the Steel
/// Mill's 66 × 56 m shed, a big plant and the plan's 200 × 150 m scale
/// check.
const List<HallSize> kBlankHallSizes = [
  HallSize(20, 15),
  HallSize(33, 28),
  HallSize(60, 40),
  HallSize(100, 75),
];

/// The plant types [kFactoryDevPlants] that have a template right now.
List<String> availableDevPlants() =>
    [for (final t in kFactoryDevPlants) if (factoryTemplateFor(t) != null) t];

void main() {
  runApp(const FactoryDevApp());
}

class FactoryDevApp extends StatefulWidget {
  const FactoryDevApp({super.key});

  @override
  State<FactoryDevApp> createState() => FactoryDevAppState();
}

class FactoryDevAppState extends State<FactoryDevApp> {
  late final List<String> plants = availableDevPlants();

  /// A plant type from [plants], or [kBlankHall].
  late String choice = plants.isEmpty ? kBlankHall : plants.first;
  HallSize blankSize = kBlankHallSizes[1];

  /// The scenario running on [floor] (null: a plain floor). A fresh one on
  /// every pick, so the screen starts its tutorial over.
  FactoryScenario? scenario;
  late FactoryFloor floor = _build();

  FactoryFloor _build() {
    scenario = choice == kRocketTutorial ? rocketPartsScenario() : null;
    final sc = scenario;
    final bp = sc != null
        ? sc.blueprint()
        : choice == kBlankHall
            ? FloorBlueprint(
                name: 'Blank hall ${blankSize.w}×${blankSize.h}',
                hall: blankSize)
            : factoryTemplateFor(choice)!;
    return FactoryFloor.fromBlueprint(bp);
  }

  void pick(String c, [HallSize? size]) => setState(() {
        choice = c;
        if (size != null) blankSize = size;
        floor = _build();
      });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Factory Floor (dev)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Column(children: [
          Material(
            color: const Color(0xFF0E1622),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                const Text('Plant  '),
                DropdownButton<String>(
                  key: const Key('dev-plant'),
                  value: choice,
                  items: [
                    for (final t in plants)
                      DropdownMenuItem(value: t, child: Text(t)),
                    const DropdownMenuItem(
                        value: kBlankHall, child: Text('Blank hall')),
                    const DropdownMenuItem(
                        value: kRocketTutorial,
                        child: Text('Tutorial: Rocket Parts')),
                  ],
                  onChanged: (v) {
                    if (v != null) pick(v);
                  },
                ),
                if (choice == kBlankHall) ...[
                  const SizedBox(width: 16),
                  DropdownButton<HallSize>(
                    key: const Key('dev-hall-size'),
                    value: blankSize,
                    items: [
                      for (final h in kBlankHallSizes)
                        DropdownMenuItem(
                            value: h,
                            child: Text('${h.widthM.toStringAsFixed(0)} × '
                                '${h.depthM.toStringAsFixed(0)} m')),
                    ],
                    onChanged: (v) {
                      if (v != null) pick(kBlankHall, v);
                    },
                  ),
                ],
              ]),
            ),
          ),
          Expanded(
            child: FactoryFloorScreen(
              sim: floor,
              title: floor.blueprint.name,
              scenario: scenario,
              // The dev entry is the debug harness: the full product tree
              // lives here (and behind this flag), never in a game mode.
              debugTools: true,
              onSaveBlueprint: (bp) =>
                  debugPrint('blueprint: ${jsonEncode(bp.toJson())}'),
            ),
          ),
        ]),
      ),
    );
  }
}
