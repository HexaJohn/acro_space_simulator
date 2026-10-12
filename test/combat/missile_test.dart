// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/application/usecases/combat_phase.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/combat/operation_registry.dart';
import 'package:acro_space_simulator/domain/combat/powers/missile.dart';
import 'package:acro_space_simulator/domain/multiplayer/command.dart';
import 'package:acro_space_simulator/domain/multiplayer/player.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// Silo salvos flown as real missiles through the tick (combat.md §7O).
void main() {
  const player = PlayerId('player');
  final silo = kUtilCatalog.firstWhere((s) => s.type == 'silo');

  CitySim moonColony(String id, {double lat = 0, double lon = 0}) => quiet(CityStarterKit.found(
        bodies: fixtureBodies,
        config: CityConfig(bodyId: 'moon', gridSize: 20, latitude: lat, longitude: lon),
        id: id,
        name: id,
      ));

  /// A colony with a Missile Silo and missiles to fire.
  CitySim firing() {
    final c = moonColony('src', lat: 1);
    expect(freeLots(c).any((lot) => place(c, lot.id, silo)), isTrue, reason: 'a silo stands');
    c.stock[Commodity.missiles] = 10;
    return c;
  }

  ({AdvanceSimulationTick tick, InMemoryVesselRepository vessels, InMemoryTerrainEditsRepository edits,
      SimulationClock clock}) world(List<CitySim> colonies, OperationRegistry ops) {
    final v = InMemoryVesselRepository(const []);
    final edits = InMemoryTerrainEditsRepository();
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
        terrainEdits: edits,
      ),
      vessels: v,
      edits: edits,
      clock: SimulationClock(warpFactor: 1, fixedStep: 0.1),
    );
  }

  /// A salvo from [from] at [at]'s first building (its centre is a
  /// crossroads, with nothing standing on it).
  MissileStrikeCommand strikeAt(CitySim from, CitySim at) {
    final sites = [...at.buildingParcels()]..sort((a, b) => a.$1.id.compareTo(b.$1.id));
    final c = sites.isEmpty ? const Vec2(0, 0) : sites.first.$1.centroid;
    final d = at.localToBodyFixed(c, bodyRadiusM: at.body.radius).normalized;
    return MissileStrikeCommand(player, 0, from.id, 'moon', (d.x, d.y, d.z));
  }

  test('a strike on a point: paid, flown on its arc to the ground, and down where it was aimed', () {
    final src = firing();
    final tgt = moonColony('tgt', lat: 1.1, lon: 0.05);
    final housed = tgt.buildingParcels().length;
    final ops = OperationRegistry();
    final w = world([src, tgt], ops);
    w.tick.execute(w.clock);
    ops.inbox.enqueue(strikeAt(src, tgt));
    w.tick.execute(w.clock);
    expect(ops.lastRefusal, isNull);
    expect(ops.missiles.single.state, MissileState.unpaid);

    Vessel? salvo;
    var arcPoints = 0;
    for (var i = 0; i < 20000 && ops.missiles.isNotEmpty; i++) {
      w.tick.execute(w.clock);
      final v = w.vessels.byId(VesselId('${kMissileIdPrefix}1'));
      if (v != null && salvo == null) {
        salvo = v;
        expect(src.stockOf(Commodity.missiles), 10 - 4, reason: 'four missiles paid');
        expect(v.arcEndEpochS, isNotNull);
        final moon = SampleWorld.realSystem().require(const BodyId('moon'));
        final snap = VesselSnapshot.of(v, system: SampleWorld.realSystem(), epoch: w.clock.epoch);
        expect(snap.trajectoryOpen, isTrue, reason: 'cut at the impact, not the full ellipse');
        arcPoints = snap.trajectory.length ~/ 3;
        // The arc ends at the aimed ground, where the Moon will have turned it.
        final m = ops.missiles.single;
        final end = Vector3(snap.trajectory[snap.trajectory.length - 3], snap.trajectory[snap.trajectory.length - 2],
            snap.trajectory.last);
        final aimThen = moon.orientationAt(Epoch(m.impactEpochS)).rotate(m.aimBF!);
        expect((end - aimThen).length, lessThan(5), reason: 'the line ends where it lands');
        // ignore: avoid_print
        print('salvo: ${((m.impactEpochS - m.launchEpochS)).toStringAsFixed(1)} s of flight, '
            '${(m.siloBF!.normalized.dot(m.aimBF!.normalized)).toStringAsFixed(6)} cos of arc');
      }
    }
    expect(salvo, isNotNull, reason: 'it flew as a vessel');
    expect(arcPoints, greaterThan(50));
    expect(w.vessels.byId(VesselId('${kMissileIdPrefix}1')), isNull, reason: 'gone at impact');
    expect(w.edits.forBody(const BodyId('moon'))!.all, isNotEmpty, reason: 'it dug a crater');
    w.tick.execute(w.clock);
    final kinds = tgt.loyalty.notices.map((n) => n.kind);
    expect(kinds, contains(LoyaltyNoticeKind.missileStrike));
    expect(tgt.buildingParcels().length, lessThan(housed), reason: 'what stood at the centre is razed');
    // ignore: avoid_print
    print('tgt: ${tgt.loyalty.notices.last.message}');
  });

  test('refused: no silo, a salvo already in hand, out of range', () {
    final src = firing();
    final bare = moonColony('bare', lat: 1.3);
    final far = moonColony('far', lat: -60, lon: 120);
    final ops = OperationRegistry();
    final w = world([src, bare, far], ops);
    w.tick.execute(w.clock);
    ops.inbox.enqueue(strikeAt(bare, src));
    w.tick.execute(w.clock);
    expect(ops.lastRefusal, contains('no Missile Silo'));
    ops.inbox
      ..enqueue(strikeAt(src, far))
      ..enqueue(strikeAt(src, bare));
    w.tick.execute(w.clock);
    expect(ops.lastRefusal, contains('already has a salvo'));
    for (var i = 0; i < 20; i++) {
      w.tick.execute(w.clock);
    }
    expect(ops.lastRefusal, contains('out of range'));
    expect(ops.missiles, isEmpty);
    expect(src.stockOf(Commodity.missiles), 6, reason: 'paid for at the silo, then found out of reach');
  });

  test('a shot in the air survives a save', () {
    final ops = OperationRegistry()
      ..missiles.add(MissileShot(
          id: 3,
          homeColonyId: 'src',
          bodyId: 'moon',
          aimDir: const Vector3(0, 0, 1),
          opId: 2,
          strikeSeq: 5,
          state: MissileState.flying,
          launchEpochS: 10,
          impactEpochS: 70,
          aimBF: const Vector3(0, 0, 1737e3),
          siloBF: const Vector3(0, 1737e3, 0)))
      ..nextMissileId = 4;
    final back = OperationRegistry()..restore(jsonDecode(jsonEncode(ops.toJson())));
    final m = back.missiles.single;
    expect((m.id, m.opId, m.strikeSeq, m.state, m.impactEpochS), (3, 2, 5, MissileState.flying, 70.0));
    expect(m.aimBF!.z, 1737e3);
    expect(back.nextMissileId, 4);
    expect(CombatPhase.missileColonyReachM, greaterThan(kMissileBlastM));
  });
}
