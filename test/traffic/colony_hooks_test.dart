// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// The colony's own agents, through the one-line hooks that wire them in
/// (docs/plans/agent-traffic.md §1.2: E3a, E3b, E4, E12, E14, E17, E37).
///
/// Everything else under test/traffic drives agents a test holds itself,
/// beside a colony that never reads them. These found the colony the way
/// the play surface does, with its agents on, and let `CitySim.advance`
/// run them — so the economy reads what they measure.
void main() {
  tearDown(AgentTuning.reset);

  test('the City Builder founding runs agents only when asked (E17, E37)', () {
    final plain = starterKit();
    expect(plain.agents.enabled, isFalse);
    expect(identical(plain.trafficReadout, plain.roadTraffic), isTrue);
    expect(plain.toJson().containsKey('agents'), isFalse);

    final city = starterKit(agentTraffic: true);
    expect(city.agents.enabled, isTrue);
    expect(identical(city.trafficReadout, city.agents.readout), isTrue);
    expect(city.agents.laneGraph, isNull,
        reason: 'nothing is built before the colony first advances');
    expect(city.toJson()['agents'], {'v': 1, 'enabled': true});

    AgentTuning.agentsOn = false;
    expect(identical(city.trafficReadout, city.roadTraffic), isTrue,
        reason: 'the A/B knob hands the readout back to the routed model');
  });

  test('zoned, the colony grows and puts cars on its streets on the world '
      'tick (E3a)', () {
    final city = starterKit(agentTraffic: true);
    zoneAll(city);
    final tick = AdvanceSimulationTick(
      vessels: InMemoryVesselRepository(const []),
      universe: StaticUniverseRepository(SampleWorld.realSystem()),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
      cities: InMemoryCityRepository([city]),
    );
    // Two minutes of colony time on the world's clock: the first car pulls
    // out at about 36 s today — the 10 s spawn ramp, then the first homes'
    // commutes coming due.
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.5);
    var grownS = -1.0, carS = -1.0;
    for (var i = 1; i <= 240 && carS < 0; i++) {
      tick.execute(clock);
      if (grownS < 0 && city.grownParcels.isNotEmpty) grownS = i * 0.5;
      if (city.agents.stats.spawned > 0) carS = i * 0.5;
    }
    expect(grownS, greaterThan(0), reason: 'zoned lots grow under demand');
    expect(carS, greaterThan(0),
        reason: 'a growing town sends commuters within two minutes');
    expect(city.agents.laneGraph, isNotNull);
    expect(city.agents.liveVehicles + city.agents.stats.arrived,
        greaterThan(0));
  });

  test('the parcel congestion is what the agents measured (E37)', () {
    AgentTuning.commuteRatePerResident = 0.004;
    final city = town(agentTraffic: true);
    run(city, 300);
    final r = city.trafficReadout;
    expect(identical(r, city.agents.readout), isTrue);
    expect(r.hasRun, isTrue);
    expect(city.agents.stats.spawned, greaterThan(0));
    expect(city.parcelCongestion,
        (0.5 * (r.peakCongestion + r.averageCongestion)).clamp(0.0, 1.0));
  });

  test('staffing follows the commutes the agents measured (E4)', () {
    final city = town(agentTraffic: true);
    city.advance(0.5); // the agents build their tables
    city.population = 20;
    // Commutes that took three times their free-flow time: the floor.
    final stats = city.agents.stats..tripRatio = 3;
    expect(stats.commuteEff, 0.6);
    final pop = city.population;
    city.advance(0.02);
    expect(city.jobs, greaterThan(20));
    final workforce = math.min(pop.floor(), city.jobs);
    expect(city.staffing, closeTo(workforce / city.jobs * 0.6, 1e-12));
  });

  test('a lot renamed by a re-plat keeps its building, and a cleared lot '
      'loses it (E12, E14)', () {
    final city = town(agentTraffic: true);
    city.advance(0.5);
    final b = city.agents.buildings!;
    final before = <String, int>{
      for (final id in city.parcelBuildings.keys) id: ?b.handleOfSite(id),
    };
    // A street across the north arm re-cuts the lots along it.
    commit(city, const FixtureRoad([Vec2(-300, 150), Vec2(300, 150)]));
    final carried = <String, int>{};
    for (final id in city.parcelBuildings.keys) {
      if (before.containsKey(id)) continue;
      final h = b.handleOfSite(id);
      expect(h, isNotNull, reason: '$id took over a lot with a building');
      expect(before.values, contains(h));
      carried[id] = h!;
    }
    expect(carried, isNotEmpty, reason: 'the re-plat renamed built lots');
    city.advance(0.5); // the sync the moved plat calls for at once
    for (final e in carried.entries) {
      expect(b.handleOfSite(e.key), e.value);
    }

    final lot = carried.keys.first;
    city.clearParcel(lot);
    expect(b.handleOfSite(lot), isNull,
        reason: 'gone at once, not at the next sync');
  });

  test('the frame hold replays the colony\'s own ticks and changes nothing '
      'they compute (E3b)', () {
    AgentTuning.commuteRatePerResident = 0.004;
    final inline = town(agentTraffic: true);
    final held = town(agentTraffic: true);
    held.agents.frameBudgeted = true;
    final rng = math.Random(7);
    for (var frame = 0; frame < 300; frame++) {
      final ticks = 1 + rng.nextInt(12);
      for (var k = 0; k < ticks; k++) {
        final dt = frame.isEven ? 0.5 : 0.02 + 0.1 * (k % 3);
        inline.advance(dt);
        held.advance(dt);
      }
      expect(held.agents.heldTicks, greaterThan(0),
          reason: 'queued whole, not run');
      held.agents.endFrame();
    }
    while (held.agents.heldTicks > 0) {
      held.agents.endFrame();
    }
    expect(held.agents.timeUs, inline.agents.timeUs);
    expect(held.agents.digest(), inline.agents.digest());
    expect(held.agents.stats.spawned, greaterThan(0));
    expect(held.dayPhase, inline.dayPhase);
    expect(held.parcelCongestion, inline.parcelCongestion);
    expect(held.staffing, inline.staffing);
    expect(held.housing, inline.housing);
    expect(held.jobs, inline.jobs);
  });

  test('held on the world tick, the colony keeps its place among what the '
      'world writes into it: a shuttle on its pad unloads as it does inline, '
      'at any frame rate (E3b, §5.7)', () {
    AgentTuning.commuteRatePerResident = 0.004;
    final system = SampleWorld.realSystem();

    /// Two minutes of colony time on the world's clock at 25×, a loaded
    /// craft standing on the colony's pad and the store all but full, so
    /// what the craft hands over each tick is what the colony has eaten
    /// since. [fps] null: the colony ticks inline; else it is held, and
    /// replayed at the ends of frames that many a second.
    ({Map<String, double> stock, double aboard, int digest}) run(
        {double? fps}) {
      final city = town(agentTraffic: true)
        // No supply run of its own: its dispatch reads the world's epoch.
        ..nextShuttleEpoch = double.infinity;
      final body = system.body(city.body.id)!;
      final clock = SimulationClock(warpFactor: 25, fixedStep: 0.02);
      final padBF = city.localToBodyFixed(city.landingPads().first.$1.centroid,
          bodyRadiusM: body.radius);
      final food = ResourceContainer(
          type: ResourceType.food, capacity: 1e6, amount: 1e6, unitMass: 1);
      final craft = SampleWorld.buildVessel(altitude: 0)
        ..landed = true
        ..updateState(StateVector(
            position: body.orientationAt(clock.epoch).rotate(padBF),
            velocity: Vector3.zero));
      craft.allParts.first.resources.add(food);
      city.stock[Commodity.food] = city.stockCap - 1;
      final tick = AdvanceSimulationTick(
        vessels: InMemoryVesselRepository([craft]),
        universe: StaticUniverseRepository(system),
        compute: DartCompute(),
        soi: const SoiTransitionService(),
        events: InMemoryEventBus(),
        colonies: InMemoryColonyRepository(),
        deposits: InMemoryDepositRepository(),
        weather: const NullWeatherRepository(),
        cities: InMemoryCityRepository([city]),
      );
      city.agents.frameBudgeted = fps != null;
      var frames = 0.0;
      for (var i = 0; i < 240; i++) {
        tick.execute(clock);
        if (fps == null) continue;
        frames += fps / 50;
        while (frames >= 1) {
          city.agents.endFrame();
          frames -= 1;
        }
      }
      city.agents.flushHeld();
      return (
        stock: Map.of(city.stock),
        aboard: food.amount,
        digest: city.agents.digest(),
      );
    }

    final inline = run();
    expect(inline.aboard, lessThan(1e6), reason: 'the craft unloaded');
    expect(run().aboard, inline.aboard, reason: 'the inline run repeats');
    for (final fps in [60.0, 40.0]) {
      final held = run(fps: fps);
      expect(held.aboard, inline.aboard, reason: 'food handed over, $fps fps');
      expect(held.stock, inline.stock, reason: 'the stores, $fps fps');
      expect(held.digest, inline.digest, reason: 'the agents, $fps fps');
    }
  });
}
