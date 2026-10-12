// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Dev entrypoint: boots STRAIGHT into the factory floor editor on a demo
/// hall (docs/plans/factory-floors.md §4, phase 2).
///
///   fvm flutter run -d windows -t lib/main_factory_dev.dart
///
/// The floor is [DemoFactorySim], a stand-in that behaves just enough to
/// exercise every drawing path (items on belts, handler trips, machine
/// status) until the real `FactoryFloor` lands; wave 2 swaps it in here.
/// Receiving and shipping run against the sandbox colony
/// (`InfiniteColonyPort`). "Save as blueprint" prints the blueprint JSON.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import 'infrastructure/flutter/screens/factory/demo_factory_sim.dart';
import 'infrastructure/flutter/screens/factory/factory_floor_screen.dart';

void main() {
  runApp(FactoryDevApp(sim: DemoFactorySim.demo()));
}

class FactoryDevApp extends StatelessWidget {
  const FactoryDevApp({super.key, required this.sim});

  final DemoFactorySim sim;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Factory Floor (dev)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: FactoryFloorScreen(
        sim: sim,
        title: sim.blueprint.name,
        onSaveBlueprint: (bp) =>
            debugPrint('blueprint: ${jsonEncode(bp.toJson())}'),
      ),
    );
  }
}
