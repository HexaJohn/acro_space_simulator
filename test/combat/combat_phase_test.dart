// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/adapters/wire/flatbuffer_codec.dart';
import 'package:acro_space_simulator/application/persistence/game_state_codec.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/application/usecases/combat_phase.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_reclaim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/city_war.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:acro_space_simulator/domain/combat/operation_registry.dart';
import 'package:acro_space_simulator/domain/combat/powers/sky.dart';
import 'package:acro_space_simulator/domain/combat/resolver_tuning.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/multiplayer/command.dart';
import 'package:acro_space_simulator/domain/multiplayer/player.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// The world's combat phase, through the real tick: combat.md §7.4–§7.8.
void main() {
  const player = PlayerId('player');
  final barracks = kUtilCatalog.firstWhere((s) => s.type == 'barracks');

  CitySim moonColony(String id) => quiet(CityStarterKit.found(
        bodies: fixtureBodies,
        config: const CityConfig(bodyId: 'moon', gridSize: 20),
        id: id,
        name: id,
      ));

  /// A Moon colony with [n] fed barracks.
  CitySim source(int n) {
    final c = moonColony('src');
    var placed = 0;
    for (final lot in freeLots(c)) {
      if (placed == n) break;
      if (place(c, lot.id, barracks)) placed++;
    }
    expect(placed, n);
    c.stock[Commodity.rations] = 400;
    c.stock[Commodity.guns] = 80;
    c.stock[Commodity.ammo] = 400;
    c.population = 300;
    return c;
  }

  /// A dependent Moon colony whose rebels hold the port.
  ///
  /// At low complexity, where nobody breathes shipped oxygen to live but it
  /// still counts against independence (secession §3.4): at the default, the
  /// port's rebels refuse the oxygen runs and the colony suffocates to about
  /// one settler over a five-day operation — and a colony of one is
  /// self-sufficient, so it secedes the moment the port is retaken. True,
  /// and a finding (a long rescue comes too late), but not what these tests
  /// are about.
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

  ({AdvanceSimulationTick tick, SimulationClock clock, OperationRegistry ops,
      InMemoryCityRepository cities}) world(List<CitySim> colonies, {double step = 0.5}) {
    final ops = OperationRegistry();
    final cities = InMemoryCityRepository(colonies);
    final tick = AdvanceSimulationTick(
      vessels: InMemoryVesselRepository(),
      universe: StaticUniverseRepository(SampleWorld.realSystem()),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
      cities: cities,
      operations: ops,
    );
    return (tick: tick, clock: SimulationClock(warpFactor: 1, fixedStep: step), ops: ops, cities: cities);
  }

  LaunchOperationCommand launch(CitySim src, {int? each, int garrison = 2}) {
    final sources = src.trooperSources();
    return LaunchOperationCommand(player, 0,
        targetColonyId: 'tgt',
        draws: [
          for (final s in sources)
            if (s.ready) (colonyId: src.id, siteId: s.siteId, count: each ?? s.available)
        ],
        garrison: garrison);
  }

  void runUntilReported(({AdvanceSimulationTick tick, SimulationClock clock, OperationRegistry ops,
      InMemoryCityRepository cities}) w, {int maxTicks = 8000}) {
    for (var i = 0; i < maxTicks; i++) {
      w.tick.execute(w.clock);
      final op = w.ops.operations.isEmpty ? null : w.ops.operations.first;
      if (op != null && w.ops.reported.contains(op.id)) {
        // One more tick so the colonies drain the report.
        w.tick.execute(w.clock);
        return;
      }
    }
  }

  test('a launched operation musters, fights and reports home through the tick', () {
    final src = source(3), tgt = target();
    final w = world([src, tgt]);
    w.tick.execute(w.clock); // a first tick, so throttles settle
    final cmd = launch(src);
    final sent = [for (final d in cmd.draws) d.count].fold(0, (a, b) => a + b);
    w.ops.inbox.enqueue(cmd);
    w.tick.execute(w.clock);
    expect(w.ops.operations, hasLength(1), reason: w.ops.lastRefusal);
    expect(src.troopersAway, sent, reason: 'the deploy write drains in the same tick');
    final popBefore = src.population;
    runUntilReported(w);
    final op = w.ops.operations.single;
    // ignore: avoid_print
    print('world: $sent troopers vs ${op.defenderRaised} → ${op.outcome} (${op.band}); '
        '${op.attackerDead} dead, port seized ${tgt.loyalty.portSeized}, '
        'garrison ${tgt.war.garrison?.count}');
    expect(op.resolved, isTrue);
    expect(w.ops.reported, contains(op.id));
    expect(src.population, lessThanOrEqualTo(popBefore - op.attackerDead + 1e-9));
    if (op.outcome == OperationOutcome.won) {
      expect(tgt.loyalty.portSeized, isFalse);
      expect(tgt.war.garrison?.count, 2);
      expect(src.troopersAway, 2, reason: 'the garrison is still away');
      expect(w.ops.garrisons.single.count, 2);
    } else {
      expect(src.troopersAway, 0);
    }
  });

  test('a refused launch says why and sends nobody', () {
    final src = source(1), tgt = target();
    final w = world([src, tgt]);
    w.tick.execute(w.clock);
    w.ops.inbox.enqueue(launch(src, each: 999));
    w.tick.execute(w.clock);
    expect(w.ops.operations, isEmpty);
    expect(w.ops.lastRefusal, contains('can field only'));
    expect(src.troopersAway, 0);
  });

  test('withdrawing brings the survivors home', () {
    final src = source(1), tgt = target();
    final w = world([src, tgt]);
    w.tick.execute(w.clock);
    w.ops.inbox.enqueue(launch(src));
    w.tick.execute(w.clock);
    for (var i = 0; i < 40; i++) {
      w.tick.execute(w.clock);
    }
    w.ops.inbox.enqueue(WithdrawOperationCommand(player, 0, w.ops.operations.single.id));
    runUntilReported(w);
    expect(w.ops.operations.single.outcome, OperationOutcome.withdrawn);
    expect(src.troopersAway, 0);
  });

  test('a garrison on a retaken port is resupplied every three days', () {
    final src = source(3), tgt = target();
    final w = world([src, tgt]);
    w.tick.execute(w.clock);
    w.ops.inbox.enqueue(launch(src, garrison: 3));
    runUntilReported(w);
    final op = w.ops.operations.single;
    if (op.outcome != OperationOutcome.won) {
      markTestSkipped('this seed lost: no garrison to supply');
      return;
    }
    // Three garrison days and a supply transit: the first run left at the
    // win, the second three days later. Fed, all three are still there.
    for (var i = 0; i < (3 * 120 + 70) * 2; i++) {
      w.tick.execute(w.clock);
    }
    expect(w.ops.runs.length + w.ops.garrisons.length, greaterThan(0));
    expect(tgt.war.garrison?.count, 3, reason: 'supplied, nobody went home');
    expect(tgt.war.garrison!.perTrooperDay.containsKey(Commodity.guns), isFalse);
    expect(tgt.loyalty.portSeized, isFalse);
  });

  test('a save mid-operation resumes as if it never stopped', () {
    String run(bool viaSave) {
      final src = source(2), tgt = target();
      var w = world([src, tgt]);
      w.tick.execute(w.clock);
      w.ops.inbox.enqueue(launch(src));
      for (var i = 0; i < 300; i++) {
        w.tick.execute(w.clock);
      }
      if (viaSave) {
        const codec = GameStateCodec();
        final json = jsonDecode(jsonEncode(codec.encode(
          vessels: InMemoryVesselRepository(),
          colonies: InMemoryColonyRepository(),
          deposits: InMemoryDepositRepository(),
          clock: w.clock,
          cities: w.cities,
          operations: w.ops,
        ))) as Map<String, dynamic>;
        expect(json['version'], 3);
        expect(json['operations'], isNotNull);
        final fresh = world(const []);
        codec.decode(json,
            vessels: InMemoryVesselRepository(),
            colonies: InMemoryColonyRepository(),
            deposits: InMemoryDepositRepository(),
            clock: fresh.clock,
            cities: fresh.cities,
            bodies: fixtureBodies,
            operations: fresh.ops);
        w = fresh;
      }
      for (var i = 0; i < 500; i++) {
        w.tick.execute(w.clock);
      }
      return jsonEncode(w.ops.operations.single.toJson());
    }

    expect(run(true), run(false));
  });

  test('how the world chops time does not change the battle', () {
    // The colonies are not step-invariant (their own sim integrates dt), so
    // two worlds launching at their first tick launch slightly different
    // battles. The same operation, handed to both, must come out the same.
    final seedWorld = world([source(3), target()]);
    seedWorld.tick.execute(seedWorld.clock);
    seedWorld.ops.inbox.enqueue(launch(seedWorld.cities.all().firstWhere((c) => c.id == 'src')));
    seedWorld.tick.execute(seedWorld.clock);
    final launched = jsonEncode(seedWorld.ops.operations.single.toJson());

    String run(double step) {
      final w = world([source(3), target()], step: step);
      w.ops.operations.add(Operation.fromJson(
          (jsonDecode(launched) as Map).cast<String, dynamic>()));
      final ticks = (200 / step).round();
      for (var i = 0; i < ticks; i++) {
        w.tick.execute(w.clock);
      }
      return jsonEncode(w.ops.operations.single.toJson());
    }

    expect(run(0.1), run(0.5));
  });

  /// An independent Earth colony: it feeds itself, so it can stay gone.
  CitySim rebels() {
    final c = quiet(CityStarterKit.found(
      bodies: fixtureBodies,
      config: const CityConfig(bodyId: 'earth', gridSize: 20),
      id: 'tgt',
      name: 'Free Town',
    ))
      ..population = 80;
    c.loyalty
      ..allegiance = Allegiance.independent
      ..stage = LoyaltyStage.seceded
      ..independentAtS = 0
      ..reclaim.grievance = const Grievance(rebellion: 0.9, revolts: 3);
    return c;
  }

  test('an assault on an independent colony, through the tick, ends in an '
      'occupation — and the charter, restored, brings the garrison home', () {
    final src = source(3), tgt = rebels();
    final w = world([src, tgt]);
    w.tick.execute(w.clock);
    final sources = src.trooperSources();
    w.ops.inbox.enqueue(LaunchOperationCommand(player, 0,
        targetColonyId: 'tgt',
        draws: [
          for (final s in sources)
            if (s.ready) (colonyId: src.id, siteId: s.siteId, count: s.available)
        ],
        kitDays: 6,
        garrison: 4));
    w.tick.execute(w.clock);
    expect(w.ops.operations, hasLength(1), reason: w.ops.lastRefusal);
    final op = w.ops.operations.single;
    expect(op.kind, OperationKind.colonyAssault);
    expect(op.goalId, 'seat');
    runUntilReported(w, maxTicks: 40000);
    // ignore: avoid_print
    print('assault: ${op.attackerRaised} troopers vs ${op.defenderRaised} -> '
        '${op.outcome} (${op.band}); ${op.attackerDead} dead, rebels dead '
        '${op.defenderDead}; ${tgt.loyalty.allegiance}');
    expect(op.resolved, isTrue);
    if (op.outcome != OperationOutcome.won) {
      expect(tgt.loyalty.allegiance, Allegiance.independent);
      expect(tgt.war.resolveBoostUntilS, greaterThan(0));
      return;
    }
    expect(tgt.loyalty.allegiance, Allegiance.occupied);
    expect(tgt.war.garrison!.occupation, isTrue);
    expect(tgt.war.garrison!.count, 4);
    expect(w.ops.garrisons.single.targetColonyId, 'tgt');
    expect(src.troopersAway, 4, reason: 'the garrison is still away');
    expect(tgt.loyalty.warDead, op.defenderDead);

    // Governed back to the line for ten days, its charter is restored.
    tgt.loyalty
      ..level = 0.7
      ..charterSinceS = tgt.loyalty.colonyTimeS - 11 * 120;
    w.ops.inbox.enqueue(const RestoreCharterCommand(player, 0, 'tgt'));
    for (var i = 0; i < 4; i++) {
      w.tick.execute(w.clock);
    }
    expect(tgt.loyalty.allegiance, Allegiance.colonial);
    expect(tgt.war.garrison, isNull);
    expect(src.troopersAway, 0, reason: 'home');
    expect(w.ops.garrisons, isEmpty);
  });

  test('a won assault keeps its base as the post: turrets crewed, kit left to the garrison', () {
    final src = source(3), tgt = rebels();
    src.stock[Commodity.ore] = 900;
    final w = world([src, tgt]);
    w.tick.execute(w.clock);
    final sources = src.trooperSources();
    w.ops.inbox.enqueue(LaunchOperationCommand(player, 0,
        targetColonyId: 'tgt',
        draws: [
          for (final s in sources)
            if (s.ready) (colonyId: src.id, siteId: s.siteId, count: s.available)
        ],
        kitDays: 6,
        garrison: 4,
        baseMateriel: 400,
        baseSupport: 8));
    w.tick.execute(w.clock);
    expect(w.ops.operations, hasLength(1), reason: w.ops.lastRefusal);
    final op = w.ops.operations.single;
    final b = op.base!;
    var crews = 0, rations = 0.0;
    for (var i = 0; i < 40000 && !w.ops.reported.contains(op.id); i++) {
      w.tick.execute(w.clock);
      if (!op.resolved) {
        crews = [for (final f in b.turretCrews(op)) if (f.count >= kTurretCrew) f.count]
            .fold(0, (a, v) => a + v);
        rations = b.stockC[kBaseGoods.indexOf(Commodity.rations)] / 100;
      }
    }
    w.tick.execute(w.clock);
    // ignore: avoid_print
    print('post: ${op.outcome}, base standing ${b.standing}, crews $crews, rations $rations');
    if (op.outcome != OperationOutcome.won || !b.standing) return;
    final g = tgt.war.garrison!;
    expect(g.count, 4 + crews, reason: 'the crews stay with the post');
    expect(g.turrets, greaterThan(0));
    expect(g.suppressing, g.count + kTurretTroopers * g.turrets);
    expect(src.troopersAway, g.count);
    expect(w.ops.garrisons.single.count, g.count);
    expect(src.war.deployed.fold<int>(0, (a, d) => a + d.count), g.count);
  });

  test('a post\'s turrets count while two of the garrison crew each', () {
    final g = PortGarrison(
        opId: 1, homeColonyId: 'a', count: 5, perTrooperDay: const {}, stock: {}, turrets: 3);
    expect(g.suppressing, 5 + 2 * 2, reason: 'five crew two turrets');
    final back = PortGarrison.fromJson(jsonDecode(jsonEncode(g.toJson())))!;
    expect(back.turrets, 3);
    g.count = 1;
    expect(g.suppressing, 1);
  });

  test('orbital support through the phase: armed at a pad, assigned, held at 10x, lost when '
      'it leaves', () {
    final src = source(3), tgt = rebels();
    src.stock[Commodity.ore] = 700;
    src.stock[Commodity.steel] = 100;
    src.stock[Commodity.electronics] = 15;
    final reg = OperationRegistry();
    final phase = CombatPhase(reg);
    final sky = _FakeSky();
    final cities = [src, tgt];
    void run([int n = 1]) {
      for (var i = 0; i < n; i++) {
        phase.run(0.5, cities, sky: sky);
        src.drainCombatInbox();
        tgt.drainCombatInbox();
      }
    }

    // Armed on the source's pad: it pays for what it can (15 electronics: 3 rounds).
    sky.vessels['v1'] = (pos: null, pad: 'src');
    reg.inbox.enqueue(ArmVesselCommand(player, 0, 'v1', 'src', 4));
    run(2);
    expect(reg.lastRefusal, contains('3 of 4'));
    expect(reg.roundsLoading('v1'), 3);
    expect(src.stockOf(Commodity.steel), closeTo(25, 1e-9));
    final sources = src.trooperSources();
    reg.inbox.enqueue(LaunchOperationCommand(player, 0,
        targetColonyId: 'tgt',
        draws: [
          for (final s in sources)
            if (s.ready) (colonyId: src.id, siteId: s.siteId, count: 4)
        ],
        kitDays: 6,
        garrison: 2,
        baseMateriel: 200,
        baseSupport: 4));
    run();
    expect(reg.operations, hasLength(1), reason: reg.lastRefusal);
    final op = reg.operations.single;
    expect(op.orbital.centreBF, isNotNull);
    expect(op.orbital.craterM, greaterThan(5));
    // Still on the pad: it cannot be assigned.
    reg.inbox.enqueue(AssignOrbitalSupportCommand(player, 0, op.id, 'v1'));
    run();
    expect(reg.lastRefusal, contains('in flight'));
    // Up, straight over the battle.
    final c = op.orbital.centreBF!;
    sky.vessels['v1'] = (pos: c.normalized * (c.length + 100e3), pad: null);
    reg.inbox.enqueue(AssignOrbitalSupportCommand(player, 0, op.id, 'v1'));
    run();
    expect(reg.lastRefusal, isNull);
    expect(reg.supportAssigned, isTrue);
    expect(op.orbital.byId('v1')!.strike, isTrue);
    run(120);
    expect(op.orbital.roundsAboard['v1'], 3, reason: 'loaded 60 s after it was paid for');
    // Gone from the sky: unassigned, with a notice.
    sky.vessels.remove('v1');
    run();
    expect(op.orbital.any, isFalse);
    expect(op.orbital.notices.last, contains('left the battle'));
    expect(reg.loadout, isEmpty, reason: 'its rounds went with it');
  });

  test('a silo strike debits four missiles, or reports it could not', () {
    final c = source(1);
    c.stock[Commodity.missiles] = 5;
    c.war.inbox.add(const SiloDebitWrite(1, 'port', 4));
    c.drainCombatInbox();
    expect(c.stockOf(Commodity.missiles), closeTo(1, 1e-9));
    expect((c.war.outbox.last as SiloFiredEvent).fired, isTrue);
    c.war.inbox.add(const SiloDebitWrite(1, 'port', 4));
    c.drainCombatInbox();
    expect((c.war.outbox.last as SiloFiredEvent).fired, isFalse);
    expect(c.stockOf(Commodity.missiles), closeTo(1, 1e-9));
  });

  test('Heavy rules raze a site: its building is gone from the colony', () {
    final c = source(1);
    final (parcel, _) = c.buildingParcels().first;
    final before = c.buildingParcels().length;
    c.war.inbox.add(WarRazeWrite([parcel.id]));
    c.drainCombatInbox();
    expect(c.buildingParcels().length, before - 1);
    expect(c.buildingParcels().any((e) => e.$1.id == parcel.id), isFalse);
  });

  test('an assault ends Rejoined when the colony comes back on its own', () {
    final src = source(2), tgt = rebels();
    final w = world([src, tgt]);
    w.tick.execute(w.clock);
    final sources = src.trooperSources();
    w.ops.inbox.enqueue(LaunchOperationCommand(player, 0,
        targetColonyId: 'tgt',
        draws: [
          for (final s in sources)
            if (s.ready) (colonyId: src.id, siteId: s.siteId, count: s.available)
        ],
        garrison: 2));
    w.tick.execute(w.clock);
    w.tick.execute(w.clock);
    expect(tgt.acceptNegotiation(), isTrue);
    runUntilReported(w);
    expect(w.ops.operations.single.outcome, OperationOutcome.rejoined);
    expect(src.troopersAway, 0);
    expect(tgt.loyalty.allegiance, Allegiance.colonial);
  });

  test('orders and reinforcements go through the tick as commands', () {
    final src = source(3), tgt = target();
    final w = world([src, tgt]);
    w.tick.execute(w.clock);
    w.ops.inbox.enqueue(launch(src, each: 4));
    w.tick.execute(w.clock);
    final op = w.ops.operations.single;
    final away = src.troopersAway;
    w.ops.inbox.enqueue(OrderOperationCommand(player, 0, op.id, 'hold'));
    w.tick.execute(w.clock);
    expect(op.order, OrderKind.hold);
    final sources = src.trooperSources();
    w.ops.inbox.enqueue(ReinforceOperationCommand(player, 0, op.id, draws: [
      for (final s in sources)
        if (s.ready) (colonyId: src.id, siteId: s.siteId, count: 2)
    ]));
    w.tick.execute(w.clock);
    expect(w.ops.lastRefusal, isNull);
    expect(src.troopersAway, away + 2 * sources.where((s) => s.ready).length);
    expect(op.attackerRaised, away + 2 * sources.where((s) => s.ready).length);
    w.ops.inbox.enqueue(OrderOperationCommand(player, 0, op.id, 'auto'));
    runUntilReported(w);
    expect(op.resolved, isTrue);
    expect(src.troopersAway, op.outcome == OperationOutcome.won ? 2 : 0);
  });

  test('a forward base: shipped from the lead source, supplied through the tick, '
      'struck and sent home at the end', () {
    final src = source(3), tgt = target();
    src.stock[Commodity.ore] = 700;
    final w = world([src, tgt]);
    w.tick.execute(w.clock);
    final ore = src.stockOf(Commodity.ore);
    final sources = src.trooperSources();
    w.ops.inbox.enqueue(LaunchOperationCommand(player, 0,
        targetColonyId: 'tgt',
        draws: [
          for (final s in sources)
            if (s.ready) (colonyId: src.id, siteId: s.siteId, count: s.available)
        ],
        garrison: 2,
        baseMateriel: 200,
        baseSupport: 4));
    w.tick.execute(w.clock);
    expect(w.ops.operations, hasLength(1), reason: w.ops.lastRefusal);
    final op = w.ops.operations.single;
    final b = op.base!;
    expect(b.homeColonyId, src.id);
    expect(src.stockOf(Commodity.ore), closeTo(ore - 200, 1e-6));
    expect(src.war.deployed.where((d) => d.siteId == kSupportSite).single.count, 4);
    // Fight it out; a supply run is asked for, shipped and landed on the way.
    var asked = false, landed = false;
    for (var i = 0; i < 12000 && !w.ops.reported.contains(op.id); i++) {
      w.tick.execute(w.clock);
      if (b.runs.any((r) => r.posted)) asked = true;
      if (asked && b.runs.isEmpty) landed = true;
    }
    w.tick.execute(w.clock);
    // ignore: avoid_print
    print('base: deployed ${b.deployed}, modules ${[for (final m in b.modules) m.kind.name]}, '
        'runs asked $asked landed $landed, outcome ${op.outcome}');
    expect(b.deployed, isTrue);
    expect(op.resolved, isTrue);
    expect(src.war.deployed.where((d) => d.siteId == kSupportSite), isEmpty,
        reason: 'support staff home');
    if (op.outcome == OperationOutcome.won) {
      expect(src.stockOf(Commodity.ore), greaterThan(ore - 200), reason: 'what was left came home');
    }
  });

  test('a v2 save loads with no operations, and the registry forgets the session', () {
    final ops = OperationRegistry()..nextOperationId = 9;
    const GameStateCodec().decode(
      {
        'version': 2,
        'clock': {'tick': 0, 'epoch': 0.0, 'warp': 1.0, 'fixedStep': 0.5},
        'vessels': const [],
        'colonies': const [],
        'deposits': const [],
      },
      vessels: InMemoryVesselRepository(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(warpFactor: 1, fixedStep: 0.5),
      operations: ops,
    );
    expect(ops.isEmpty, isTrue);
    expect(ops.nextOperationId, 1);
  });

  test('a queued combat command survives a save', () {
    final ops = OperationRegistry();
    ops.inbox.enqueue(const LaunchOperationCommand(player, 3,
        targetColonyId: 'tgt', draws: [(colonyId: 'src', siteId: 'lot-1', count: 5)], garrison: 2));
    final back = OperationRegistry()..restore(jsonDecode(jsonEncode(ops.toJson())));
    final c = back.inbox.pending.single as LaunchOperationCommand;
    expect(c.targetColonyId, 'tgt');
    expect(c.draws.single.count, 5);
    expect(c.garrison, 2);
  });

  test('combat commands travel on the wire as their JSON (combat.md §7N)', () {
    const other = PlayerId('player-2');
    final cmds = <CombatCommand>[
      WithdrawOperationCommand(player, 3, 1),
      LaunchOperationCommand(player, 4,
          targetColonyId: 'tgt',
          draws: const [(colonyId: 'src', siteId: 'b0', count: 9)],
          garrison: 2,
          roe: 'heavy',
          baseMateriel: 300,
          baseSupport: 6,
          baseDoctrine: 'hold'),
      const SquadOrderCommand(other, 5, 1, [3, 4], 'power'),
      const CommanderPowerCommand(player, 6, 1, 'gunship', target: 'seat'),
      const LiveCasualtiesCommand(player, 7, 1, [2, 2, 5]),
      const ArmVesselCommand(player, 8, 'rod-1', 'src', 4),
    ];
    const codec = FlatBufferCodec();
    final back = codec.decodeCommands(codec.encodeCommands(CommandBatch(Epoch(12), cmds))).commands;
    expect(back, hasLength(cmds.length));
    for (var i = 0; i < cmds.length; i++) {
      expect(jsonEncode((back[i] as CombatCommand).toJson()), jsonEncode(cmds[i].toJson()));
    }
    expect(back[2].issuedBy, other, reason: 'the envelope attributes it');
  });

  test('an operation takes orders from the player who launched it (§7N)', () {
    final src = source(3), tgt = target();
    final w = world([src, tgt]);
    w.tick.execute(w.clock);
    w.ops.inbox.enqueue(launch(src));
    w.tick.execute(w.clock);
    final op = w.ops.operations.single;
    expect(op.ownerId, 'player');
    expect(Operation.fromJson(jsonDecode(jsonEncode(op.toJson()))).ownerId, 'player');

    w.ops.inbox.enqueue(WithdrawOperationCommand(const PlayerId('player-2'), 0, op.id));
    w.tick.execute(w.clock);
    expect(op.resolved, isFalse, reason: 'a stranger cannot withdraw it');
    expect(w.ops.lastRefusal, 'That operation is not yours to order.');

    w.ops.inbox.enqueue(WithdrawOperationCommand(player, 0, op.id));
    w.tick.execute(w.clock);
    expect(op.outcome, OperationOutcome.withdrawn, reason: 'its owner can');
  });

  /// A Moon colony of [pop] occupied by [troopers] of the player's from 'src'.
  CitySim occupied(int pop, int troopers) {
    final c = moonColony('tgt')
      ..complexity = 0.2
      ..population = pop.toDouble();
    c.stock[Commodity.rations] = 2000;
    c.stock[Commodity.guns] = 10;
    c.loyalty
      ..allegiance = Allegiance.independent
      ..stage = LoyaltyStage.seceded;
    c.applyCombatWrite(OccupyWrite(PortGarrison(
      opId: 77,
      homeColonyId: 'src',
      count: troopers,
      perTrooperDay: const {Commodity.rations: 0.1},
      stock: {Commodity.rations: 500},
      occupation: true,
    )));
    return c;
  }

  Operation? runRising(({AdvanceSimulationTick tick, SimulationClock clock, OperationRegistry ops,
      InMemoryCityRepository cities}) w, CitySim tgt) {
    final t = tgt.colonyTimeS;
    tgt.loyalty.revolts.addAll([t, t, t]);
    runUntilReported(w);
    return w.ops.operations.where((o) => o.kind == OperationKind.uprising).firstOrNull;
  }

  test('a rising the garrison holds is crushed through the tick (§7N)', () {
    final src = source(1), tgt = occupied(80, 30);
    final w = world([src, tgt]);
    final op = runRising(w, tgt);
    expect(op, isNotNull);
    // ignore: avoid_print
    print('rising: ${op!.outcome} · garrison lost ${op.defenderRemoved} of ${op.defenderRaised}'
        ' · rebels ${op.attackerRemoved} of ${op.attackerRaised}');
    expect(op.garrisonOpId, 77);
    expect(op.playerWon, isTrue);
    expect(tgt.loyalty.allegiance, Allegiance.occupied);
    expect(tgt.loyalty.risen, isFalse);
    expect(tgt.loyalty.revolts, isEmpty);
    expect(tgt.loyalty.notices.map((n) => n.kind), contains(LoyaltyNoticeKind.uprisingCrushed));
    expect(tgt.war.garrison!.count, 30 - op.defenderRemoved);
    expect(w.ops.lastRefusal, isNull);
    // The player cannot order a fight they are defending.
    w.ops.inbox.enqueue(WithdrawOperationCommand(player, 0, op.id));
    w.tick.execute(w.clock);
    expect(op.outcome, isNot(OperationOutcome.withdrawn));
    expect(Operation.fromJson(jsonDecode(jsonEncode(op.toJson()))).kind, OperationKind.uprising);
  });

  test('a rising that takes the Seat throws the garrison out through the tick (§7N)', () {
    final src = source(1), tgt = occupied(400, 2);
    final w = world([src, tgt]);
    final op = runRising(w, tgt);
    expect(op, isNotNull);
    // ignore: avoid_print
    print('rising: ${op!.outcome} · garrison lost ${op.defenderRemoved} of ${op.defenderRaised}'
        ' · rebels ${op.attackerRemoved} of ${op.attackerRaised}');
    expect(op.outcome, OperationOutcome.won);
    expect(op.playerWon, isFalse);
    w.tick.execute(w.clock);
    expect(tgt.loyalty.allegiance, isNot(Allegiance.occupied));
    expect(tgt.war.garrison, isNull);
    expect(w.ops.garrisons.where((g) => g.targetColonyId == 'tgt'), isEmpty);
  });

  test('a colony of a handful cannot rise: the garrison holds without a battle (§7N)', () {
    final src = source(1), tgt = occupied(80, 4);
    tgt.population = 2;
    final w = world([src, tgt]);
    final t = tgt.colonyTimeS;
    tgt.loyalty.revolts.addAll([t, t, t]);
    for (var i = 0; i < 20; i++) {
      w.tick.execute(w.clock);
    }
    expect(w.ops.operations.where((o) => o.kind == OperationKind.uprising), isEmpty);
    expect(tgt.loyalty.risen, isFalse);
    expect(tgt.loyalty.allegiance, Allegiance.occupied);
    expect(tgt.loyalty.uprisingQuietUntilS, greaterThan(tgt.colonyTimeS));
    expect(tgt.loyalty.notices.last.message, contains('Too few turned out'));
  });

  test('a rival raids its colonial neighbour on its own day (§7N)', () {
    final tgt = moonColony('tgt')
      ..complexity = 0.2
      ..population = 60;
    tgt.stock[Commodity.ore] = 500;
    tgt.stock[Commodity.rations] = 500;
    final rival = moonColony('rival')
      ..complexity = 0.2
      ..population = 400;
    rival.stock[Commodity.rations] = 2000;
    rival.stock[Commodity.guns] = 60;
    rival.loyalty
      ..allegiance = Allegiance.independent
      ..stage = LoyaltyStage.seceded;
    final w = world([tgt, rival]);
    final dayUs = (const ResolverTuning().daySec * 1e6).round();
    Operation? raid;
    for (var d = 1; d <= CombatPhase.raidEveryDays && raid == null; d++) {
      w.ops.clockUs = d * dayUs - 100000;
      w.tick.execute(w.clock);
      raid = w.ops.operations.where((o) => o.kind == OperationKind.raid).firstOrNull;
      if (raid == null) expect(w.ops.operations, isEmpty, reason: 'no raid but on its day');
    }
    expect(raid, isNotNull, reason: 'one day in ten is its own');
    expect(raid!.raiderId, 'rival');
    expect(raid.targetColonyId, 'tgt');
    final rations0 = rival.stockOf(Commodity.rations);
    runUntilReported(w);
    // ignore: avoid_print
    print('raid: ${raid.outcome} · raiders ${raid.attackerRemoved} of ${raid.attackerRaised}'
        ' · defenders ${raid.defenderRemoved} of ${raid.defenderRaised}');
    expect(raid.resolved, isTrue);
    final kinds = tgt.loyalty.notices.map((n) => n.kind);
    if (raid.outcome == OperationOutcome.won) {
      expect(kinds, contains(LoyaltyNoticeKind.raided));
      expect(tgt.stockOf(Commodity.ore), lessThan(500 * 0.81));
      w.tick.execute(w.clock);
      expect(rival.stockOf(Commodity.ore), greaterThan(0), reason: 'the plunder went home');
    } else {
      expect(kinds, contains(LoyaltyNoticeKind.raidBeaten));
      expect(rival.stockOf(Commodity.rations), lessThanOrEqualTo(rations0));
    }
  });
}

class _FakeSky implements CombatSky {
  final Map<String, ({Vector3? pos, String? pad})> vessels = {};

  @override
  Vector3? positionAbout(String vesselId, String bodyId) => vessels[vesselId]?.pos;

  @override
  Vector3 toInertial(String bodyId, Vector3 bf) => bf;

  @override
  String? nameOf(String vesselId) => vessels.containsKey(vesselId) ? 'Rod $vesselId' : null;

  @override
  bool isPlayers(String vesselId) => vessels.containsKey(vesselId);

  @override
  bool landedAtPad(String vesselId, String colonyId) => vessels[vesselId]?.pad == colonyId;
}
