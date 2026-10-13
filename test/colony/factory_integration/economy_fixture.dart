// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Shared fixtures for the plant-economy integration tests
/// (docs/plans/factory-floors.md §3 "Ownership and money"): a starter colony
/// with one plant whose stock is held steady, run whole economy days.
library;

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/colony_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';

import 'factory_colony_fixture.dart';

/// One tick, as the colony screens drive it (the sim clamps to 0.5 s).
const double kEconTickS = 0.5;

/// A relaxed Earth starter colony ([foundedColony]) under [economy], with
/// enough people for any plant and power and compute laid on
/// ([CitySim.infinitePower]): these tests ask whether a plant pays at the
/// colony's derived prices, not whether the starter grid can carry a 50 MW
/// plant or already has a data centre.
CitySim economyColony({Economy economy = Economy.capitalism}) {
  final sim = foundedColony()
    ..population = kEconPopulation
    ..infinitePower = true
    ..economy = economy;
  return sim;
}

/// Places [type] on a free lot of [sim]; returns the lot id.
String placePlant(CitySim sim, String type) =>
    placeOnFreeLot(sim, specOf(type));

/// Holds [spec]'s goods steady before a tick: inputs at [inputs] units
/// (0 = starved) and outputs emptied, as if the colony's consumers took
/// everything the plant made (otherwise its shipping stops at the storage
/// cap and the books measure a full warehouse, not the plant).
void holdStock(CitySim sim, CityBuildingSpec spec, {double inputs = 300}) {
  for (final k in spec.inputs.keys) {
    sim.stock[k] = inputs;
  }
  for (final k in spec.outputs.keys) {
    sim.stock[k] = 0;
  }
}

/// People the economy fixtures keep at work ([runDays]).
const double kEconPopulation = 300;

/// Runs [sim] for [days] economy days, holding [specs]' stock each tick.
/// [after] runs after every tick (stop early by returning true).
///
/// The population is held at [kEconPopulation] too: the starter colony
/// houses six, so its 300 people die of homelessness and thirst inside a
/// fortnight (`pinPopulation` stops migration, not deaths) and every
/// plant's staffing goes with them — a colony story these tests aren't
/// about.
void runDays(
  CitySim sim,
  double days, {
  List<CityBuildingSpec> specs = const [],
  double inputs = 300,
  bool Function()? after,
}) {
  final ticks = (days * kColonyDaySec / kEconTickS).round();
  for (var i = 0; i < ticks; i++) {
    sim.population = kEconPopulation;
    for (final s in specs) {
      holdStock(sim, s, inputs: inputs);
    }
    sim.advance(kEconTickS);
    if (after != null && after()) return;
  }
}

/// [sim]'s economy as saved, canonical text (for equality).
String economyJson(CitySim sim) => jsonEncode(sim.colonyEconomy.toJson());

/// When each cut first showed, in colony seconds.
class Walk {
  double? layoff, idle, close;
}

/// A private Steel Mill with no ore, run until it closes (at most 45 days).
/// Its roster is cut to ONE walker first: a layoff lets one handler go a
/// week, so the template's full crew would take months to walk through,
/// and one is enough to show the order.
({CitySim sim, String lot, Walk walk, int jobsBefore}) starvedMill() {
  final sim = economyColony();
  final mill = specOf('steelmill');
  final lot = placePlant(sim, 'steelmill');
  sim.factoryFloors[lot]!.blueprint.roster
    ..clear()
    ..[HandlerKind.onFoot] = 1;
  runDays(sim, 0.1, specs: [mill], inputs: 0);
  final jobsBefore = sim.jobs;
  final walk = Walk();
  var t = 0.1 * kColonyDaySec; // colony seconds since placement
  runDays(sim, 45, specs: [mill], inputs: 0, after: () {
    t += kEconTickS;
    final rec = sim.factoryFloors[lot]!;
    if (walk.layoff == null && rec.blueprint.roster.isEmpty) walk.layoff = t;
    final thr = sim.floorThrottleOf(lot);
    if (walk.idle == null && thr == kIdleStationsThrottle) walk.idle = t;
    if (walk.close == null && thr == 0) walk.close = t;
    return walk.close != null;
  });
  return (sim: sim, lot: lot, walk: walk, jobsBefore: jobsBefore);
}

/// [json] saved and loaded back, as a colony file would be.
CitySim reload(Map<String, dynamic> json) => CitySim.fromJson(
      (jsonDecode(jsonEncode(json)) as Map).cast<String, dynamic>(),
      bodies: fixtureBodies(),
    )
      ..hostility = 0
      ..pinPopulation = true
      ..infinitePower = true;
