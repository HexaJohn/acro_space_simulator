// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_atmosphere_repository.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere_service.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Atmospheric Harvester takes what it makes out of the planet's sky
/// (user request, 2026-10-10; docs/plans/terraforming.md phase 2): through
/// the real tick, the colony's harvest lands on its body's inventory and the
/// body republishes thinner.
void main() {
  const mars = BodyId('mars');

  /// A Mars with a twelfth of an atmosphere of oxygen in its sky, and one
  /// colony on it running [harvesters] Atmospheric Harvesters, ticked for
  /// two days.
  ({double before, double after, double harvested, CelestialBody published})
      harvest(int harvesters) {
    final system = RealSolarSystem.build();
    final universe = StaticUniverseRepository(system);
    final air = InMemoryAtmosphereRepository.seeded(system);
    final bodies = system.all.where((b) => !b.isStar).toList();
    final state = air.forBody('mars')!;
    state.add(
        AtmosphereGas.oxygen,
        state.molesForPartialPressure(
                state.moles, AtmosphereGas.oxygen, 0.08 * 101325) -
            state.molesOf(AtmosphereGas.oxygen));
    universe.replaceBody(state.applyTo(system.require(mars)));
    state.markPublished();

    final city = CitySim.found(
      const CityConfig(bodyId: 'mars', gridSize: 20),
      bodies: bodies,
      id: 'harvest',
    )..infiniteRobotics = true;
    CityBuildingSpec spec(String type) =>
        kUtilCatalog.firstWhere((s) => s.type == type);
    final g = city.grid;
    final h = city.hubKey;
    city.placeUtil(h - 1, spec('fusion'));
    city.placeUtil(h + g, spec('datacenter'));
    final sites = [h + 1, h - g];
    for (var i = 0; i < harvesters; i++) {
      city.placeUtil(sites[i], spec('o2harvester'));
    }
    city.population = 300;
    city.stock[Commodity.electronics] = 1e6;
    city.recompute();

    final tick = AdvanceSimulationTick(
      vessels: InMemoryVesselRepository(),
      universe: universe,
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
      cities: InMemoryCityRepository([city]),
      atmosphere: air,
    );
    final before = state.molesOf(AtmosphereGas.oxygen);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 3600);
    var harvested = 0.0;
    for (var i = 0; i < 48; i++) {
      tick.execute(clock);
      harvested += city.o2HarvestRate * 3600;
    }
    final published = universe.current().require(mars);
    expect(identical(city.body, published), isTrue);
    return (
      before: before,
      after: state.molesOf(AtmosphereGas.oxygen),
      harvested: harvested,
      published: published,
    );
  }

  test("a harvesting colony thins its planet's oxygen", () {
    const tuning = TerraformTuning();
    final control = harvest(0);
    final w = harvest(2);
    expect(w.harvested / (48 * 3600), greaterThan(1),
        reason: 'two powered, staffed harvesters');
    expect(control.after, control.before,
        reason: 'nothing else on Mars makes or takes oxygen');
    final expected = w.harvested * tuning.harvesterMolesPerStockUnit;
    expect(w.before - w.after, closeTo(expected, expected * 1e-6),
        reason: 'every stock unit made is that many moles out of the sky');
    // The published body is thinner than the same world unharvested (the
    // warmth the oxygen holds frees some CO2 in both, so compare the two).
    double o2Pa(CelestialBody b) =>
        b.atmosphere!.seaLevelPressure *
        b.composition!.fractions[AtmosphereGas.oxygen]!;
    expect(w.published.atmosphere!.seaLevelPressure,
        lessThan(control.published.atmosphere!.seaLevelPressure));
    expect(o2Pa(w.published), lessThan(o2Pa(control.published)));
  });
}
