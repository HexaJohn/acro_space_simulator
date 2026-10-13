// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Shared colony fixtures for the factory-floor integration tests: a relaxed
/// Earth starter colony with a plant placed on a free street lot.
library;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';

List<CelestialBody> fixtureBodies() =>
    RealSolarSystem.build().all.where((b) => !b.isStar).toList();

/// A relaxed starter colony on [bodyId] (Earth by default), with the
/// random disasters off (hostility 0) and its people pinned, so two copies
/// run alike.
CitySim foundedColony({String bodyId = 'earth'}) {
  final sim = CityStarterKit.found(
    bodies: fixtureBodies(),
    config: CityConfig(bodyId: bodyId),
    start: CityStart.relaxed,
  );
  sim.hostility = 0;
  sim.pinPopulation = true;
  return sim;
}

/// The util catalogue's spec of [type].
CityBuildingSpec specOf(String type) =>
    kUtilCatalog.firstWhere((s) => s.type == type);

/// Free, served street lots of [sim], in layout order.
List<String> freeLots(CitySim sim) {
  final net = sim.parcelNetwork();
  return [
    for (final p in sim.layout.autoParcels)
      if (!sim.parcelBuildings.containsKey(p.id) && net.lotServed(p.id)) p.id,
  ];
}

/// Places [spec] on the first free lot that takes it; returns the lot id.
String placeOnFreeLot(CitySim sim, CityBuildingSpec spec) {
  for (final id in freeLots(sim)) {
    if (sim.placeOnParcel(id, spec)) return id;
  }
  throw StateError('no free lot for ${spec.label}');
}
