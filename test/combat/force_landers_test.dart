// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/application/usecases/force_landers.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/city_war.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/combat/formation.dart';
import 'package:acro_space_simulator/domain/combat/lander.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:acro_space_simulator/domain/combat/operation_registry.dart';
import 'package:acro_space_simulator/domain/multiplayer/command.dart';
import 'package:acro_space_simulator/domain/multiplayer/player.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// Troop landers flown for real through the tick, on the Moon: combat.md §7B.
void main() {
  const player = PlayerId('player');
  final barracks = kUtilCatalog.firstWhere((s) => s.type == 'barracks');

  CitySim moonColony(String id, {double lat = 0}) => quiet(CityStarterKit.found(
        bodies: fixtureBodies,
        config: CityConfig(bodyId: 'moon', gridSize: 20, latitude: lat),
        id: id,
        name: id,
      ));

  CitySim source() {
    final c = moonColony('src', lat: 1);
    var placed = 0;
    for (final lot in freeLots(c)) {
      if (placed == 2) break;
      if (place(c, lot.id, barracks)) placed++;
    }
    c.stock[Commodity.rations] = 400;
    c.stock[Commodity.guns] = 80;
    c.stock[Commodity.ammo] = 400;
    c.population = 300;
    return c;
  }

  CitySim target() {
    final c = moonColony('tgt')
      ..complexity = 0.2
      ..population = 60;
    c.loyalty
      ..tuning = const CityLoyaltyTuning(independenceBar: 5)
      ..level = 0.05
      ..desperation = 0.6
      ..stage = LoyaltyStage.standoff
      ..portSeized = true
      ..impoundPending = true;
    return c;
  }

  ({AdvanceSimulationTick tick, InMemoryVesselRepository vessels}) build(
      List<CitySim> colonies, OperationRegistry ops,
      {InMemoryVesselRepository? vessels}) {
    final v = vessels ?? InMemoryVesselRepository(const []);
    return (
      tick: AdvanceSimulationTick(
        vessels: v,
        universe: StaticUniverseRepository(SampleWorld.realSystem()),
        compute: DartCompute(),
        soi: const SoiTransitionService(),
        events: InMemoryEventBus(),
        colonies: InMemoryColonyRepository(),
        deposits: InMemoryDepositRepository(),
        weather: const NullWeatherRepository(),
        cities: InMemoryCityRepository(colonies),
        operations: ops,
        forceLanders: true,
      ),
      vessels: v,
    );
  }

  LaunchOperationCommand launch(CitySim src) => LaunchOperationCommand(player, 0,
      targetColonyId: 'tgt',
      draws: [
        for (final s in src.trooperSources())
          if (s.ready) (colonyId: src.id, siteId: s.siteId, count: s.available)
      ],
      garrison: 2);

  Iterable<Vessel> landers(InMemoryVesselRepository v) =>
      v.all().where((x) => x.id.value.startsWith('force-'));

  test('the squads come down in real landers, and the fight waits for them', () {
    final src = source(), tgt = target();
    final ops = OperationRegistry();
    final w = build([src, tgt], ops);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.1);
    w.tick.execute(clock);
    ops.inbox.enqueue(launch(src));
    w.tick.execute(clock);
    final op = ops.operations.single;
    final troopers = op.attackerRaised;
    expect(op.landers, hasLength((troopers / kLanderCapacity).ceil()),
        reason: 'one lander per $kLanderCapacity troopers, squads never split');
    expect(landers(w.vessels), isEmpty, reason: 'they launch once mustered');

    // Mustering, then the landers spawn and fly. The warp ceiling: a player
    // asking for 1,000x gets 1x while one descends.
    var sawDescent = false;
    for (var i = 0; i < 12000 && op.phase != OperationPhase.engaged; i++) {
      if (op.landers.any((l) => l.state == LanderState.descending)) {
        sawDescent = true;
        clock.warpFactor = 1000;
      }
      w.tick.execute(clock);
      if (sawDescent && op.landersAloft) expect(clock.warpFactor, 1);
    }
    expect(sawDescent, isTrue);
    expect(op.phase, OperationPhase.engaged, reason: 'every lander came down');
    expect(op.landers.every((l) => l.state == LanderState.landed), isTrue);
    final down = landers(w.vessels).toList();
    expect(down, hasLength(op.landers.length));
    expect(down.every((v) => v.landed), isTrue);
    expect(down.every((v) => v.name == 'Troop Lander'), isTrue);
    for (final f in op.formations.where((f) => f.side == CombatSide.attacker)) {
      expect(f.at, isNot(FormationAt.transit), reason: 'landed with its lander');
    }
    // Each came down on its own point round the LZ, inside the guidance's
    // tolerance: 450 m from the pads, so nothing was impounded.
    final moon = SampleWorld.realSystem().all.firstWhere((b) => b.id.value == 'moon');
    final q = moon.orientationAt(clock.epoch);
    final lz = op.graph.byId(op.lzId)!;
    for (final l in op.landers) {
      final v = down.firstWhere((x) => x.id.value == l.vesselId);
      final at = q.conjugate.rotate(v.state.position).normalized;
      final want = tgt
          .localToBodyFixed(Vec2(lz.e + l.offE, lz.n + l.offN), bodyRadiusM: moon.radius)
          .normalized;
      final missM = (at - want).length * moon.radius;
      expect(missM, lessThan(30), reason: '${l.vesselId} missed by ${missM.round()} m');
    }
    // ignore: avoid_print
    print('landers: ${op.landers.length} for $troopers troopers; engaged at '
        '${op.engagedAtStep} s (abstract transit ends at ${op.phaseEndsStep} s)');
    expect(op.engagedAtStep, greaterThanOrEqualTo(op.phaseEndsStep));
  });

  test('a lander lost on the way down takes everyone aboard with it', () {
    final src = source(), tgt = target();
    final ops = OperationRegistry();
    final w = build([src, tgt], ops);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.1);
    w.tick.execute(clock);
    ops.inbox.enqueue(launch(src));
    w.tick.execute(clock);
    final op = ops.operations.single;
    for (var i = 0; i < 3000 && !op.landers.any((l) => l.state == LanderState.descending); i++) {
      w.tick.execute(clock);
    }
    final doomed = op.landers.first;
    final aboard = [
      for (final f in op.formations)
        if (doomed.formationIds.contains(f.id)) f
    ];
    final people = aboard.fold<int>(0, (a, f) => a + f.count);
    w.vessels.remove(VesselId(doomed.vesselId)); // destroyed, as a crash would
    w.tick.execute(clock);
    expect(doomed.state, LanderState.lost);
    expect(aboard.every((f) => f.count == 0), isTrue);
    expect(aboard.fold<int>(0, (a, f) => a + f.dead), people, reason: 'all dead, none wounded');
  });

  test('a save mid-descent resumes the descent', () {
    final src = source(), tgt = target();
    final ops = OperationRegistry();
    final w = build([src, tgt], ops);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.1);
    w.tick.execute(clock);
    ops.inbox.enqueue(launch(src));
    w.tick.execute(clock);
    final op = ops.operations.single;
    for (var i = 0; i < 3000 && !op.landers.any((l) => l.state == LanderState.descending); i++) {
      w.tick.execute(clock);
    }
    for (var i = 0; i < 200; i++) {
      w.tick.execute(clock);
    }
    expect(op.landersAloft, isTrue);
    // A load: the registry from its JSON, the vessels kept (the codec saves
    // them), a fresh tick — so no lander guidance survives but the records.
    final saved = jsonDecode(jsonEncode(ops.toJson()));
    final back = OperationRegistry()..restore(saved);
    final w2 = build([src, tgt], back, vessels: w.vessels);
    final op2 = back.operations.single;
    for (var i = 0; i < 12000 && op2.phase != OperationPhase.engaged; i++) {
      w2.tick.execute(clock);
    }
    expect(op2.phase, OperationPhase.engaged);
    expect(op2.landers.every((l) => l.state == LanderState.landed), isTrue);
  });

  test('on a world with air, landing stays abstract', () {
    expect(ForceLanderFlight.aloft(OperationRegistry()), isFalse);
    final src = source(), tgt = target();
    final ops = OperationRegistry();
    // Rebuild the target on Earth: it has air.
    final earth = quiet(CityStarterKit.found(
      bodies: fixtureBodies,
      config: const CityConfig(bodyId: 'earth', gridSize: 20),
      id: 'tgt',
      name: 'tgt',
    ))
      ..population = 60;
    earth.loyalty
      ..tuning = const CityLoyaltyTuning(independenceBar: 5)
      ..level = 0.05
      ..desperation = 0.6
      ..stage = LoyaltyStage.standoff
      ..portSeized = true
      ..impoundPending = true;
    expect(tgt.body.hasAtmosphere, isFalse);
    final w = build([src, earth], ops);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.5);
    w.tick.execute(clock);
    ops.inbox.enqueue(launch(src));
    w.tick.execute(clock);
    expect(ops.operations.single.landers, isEmpty);
  });
}
