// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/shuttle_cargo.dart';
import 'package:acro_space_simulator/domain/colony/city/shuttle_run.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// The automatic shuttles at a port the rebels hold
/// (docs/plans/colony-secession.md §4.1): the one let in is impounded and
/// grounded, the rest are refused, and the record of what was taken is one
/// line per craft and commodity, however many ticks the unloading takes.
void main() {
  /// [city]'s rebels have just taken its port: a standoff it cannot leave
  /// (a bar it cannot clear) at a loyalty too low to end it.
  void seize(CitySim city) => city.loyalty
    ..tuning = const CityLoyaltyTuning(independenceBar: 5)
    ..level = 0.05
    ..desperation = 0.5
    ..stage = LoyaltyStage.standoff
    ..portSeized = true
    ..impoundPending = true;

  group('the pad-side cargo service', () {
    ({CitySim city, double bodyRadius}) colonyWithPort() {
      final bodies =
          RealSolarSystem.build().all.where((b) => !b.isStar).toList();
      final city = CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: bodies,
        id: 'port',
      );
      city.placeUtil(
          city.hubKey, kUtilCatalog.firstWhere((s) => s.label == 'Spaceport'));
      final body = bodies.firstWhere((b) => b.id.value == 'earth');
      return (city: city, bodyRadius: body.radius);
    }

    test('one record per craft and commodity, however it trickles off', () {
      final (:city, :bodyRadius) = colonyWithPort();
      seize(city);
      final craft = SampleWorld.buildVessel(altitude: 0)
        ..landed = true
        ..updateState(StateVector(
            position: city.localToBodyFixed(city.landingPads().first.$1.centroid,
                bodyRadiusM: bodyRadius),
            velocity: Vector3.zero));
      for (final part in craft.allParts) {
        for (final tank in part.resources) {
          tank.amount = tank.capacity;
        }
      }
      const service = ShuttleCargoService();
      // A store all but full, that the colony draws on between ticks: each
      // unload moves only the room the last tick freed.
      var moved = 0.0;
      for (var i = 0; i < 40; i++) {
        for (final c in [Commodity.fuel, Commodity.oxidizer, Commodity.ore]) {
          city.stock[c] = city.stockCap - 1;
        }
        moved += service
                .unload(city, craft, bodyRadiusM: bodyRadius)
                ?.totalDelivered ??
            0;
      }
      expect(moved, greaterThan(20), reason: 'it trickled off, tick by tick');
      final taken = city.loyalty.impounded;
      expect(taken.length, lessThanOrEqualTo(3),
          reason: 'not a record per top-up');
      expect(taken.map((c) => c.resource).toSet(), hasLength(taken.length));
      expect(taken.fold(0.0, (s, c) => s + c.amount), closeTo(moved, 1e-9),
          reason: 'and the records add up to all that was taken');
    });
  });

  group('the shuttle loop', () {
    test('one shuttle let in and held; released, it leaves; then refused',
        () {
      final city = CitySim.found(
        const CityConfig(bodyId: 'moon', gridSize: 20),
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'heldbase',
      );
      city.layout.addRoad(const RoadSpline(
          id: 'main', controls: [Vec2(0, -150), Vec2(0, 150)]));
      city.parcelBuildings[city.layout.autoParcels.first.id] =
          kUtilCatalog.firstWhere((s) => s.label == 'Spaceport');
      city.stock[Commodity.food] = 0;
      city.nextShuttleEpoch = 0;
      seize(city);

      final vessels = InMemoryVesselRepository(const []);
      final tick = AdvanceSimulationTick(
        vessels: vessels,
        universe: StaticUniverseRepository(SampleWorld.realSystem()),
        compute: DartCompute(),
        soi: const SoiTransitionService(),
        events: InMemoryEventBus(),
        colonies: InMemoryColonyRepository(),
        deposits: InMemoryDepositRepository(),
        weather: const NullWeatherRepository(),
        cities: InMemoryCityRepository([city]),
      );
      final clock = SimulationClock(warpFactor: 1, fixedStep: 0.1);

      // The next shuttle is let in — and that was the one admission.
      tick.execute(clock);
      expect(vessels.all(), hasLength(1));
      expect(city.loyalty.impoundPending, isFalse);

      // It lands, and stays landed: held, unloaded, its cargo the rebels'.
      for (var i = 0; i < 5000; i++) {
        tick.execute(clock);
        if (city.shuttleRuns.single.phase != ShuttleRunPhase.inbound) break;
      }
      expect(city.shuttleRuns.single.phase, ShuttleRunPhase.unloading,
          reason: 'it touched down');
      for (var i = 0; i < 600; i++) {
        tick.execute(clock);
      }
      expect(city.loyalty.portSeized, isTrue);
      expect(city.shuttleRuns.single.phase, ShuttleRunPhase.unloading,
          reason: 'grounded while the rebels hold the port');
      expect(vessels.all(), hasLength(1));
      final taken = city.loyalty.impounded;
      expect(taken.map((c) => c.resource), contains(Commodity.food));
      expect(taken.map((c) => c.resource).toSet(), hasLength(taken.length),
          reason: 'one record per commodity it brought');
      expect(city.stock[Commodity.food], greaterThan(0),
          reason: "the cargo is in the colony's own stock");

      // The port given back: the held shuttle finishes its turnaround and
      // climbs out.
      city.loyalty
        ..level = 1
        ..desperation = 0
        ..stage = LoyaltyStage.loyal
        ..portSeized = false;
      for (var i = 0; i < 5000 && city.shuttleRuns.isNotEmpty; i++) {
        tick.execute(clock);
      }
      expect(city.shuttleRuns, isEmpty, reason: 'the round trip completed');
      expect(vessels.all(), isEmpty, reason: 'the hull was recovered');

      // Seized again, its one admission spent: docking is refused.
      seize(city);
      city.loyalty.impoundPending = false;
      city.nextShuttleEpoch = 0;
      for (var i = 0; i < 50; i++) {
        tick.execute(clock);
      }
      expect(vessels.all(), isEmpty, reason: 'no shuttle is sent');
      expect(city.shuttleRuns, isEmpty);
    });
  });
}
