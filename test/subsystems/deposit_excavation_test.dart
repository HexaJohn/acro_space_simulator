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
import 'package:acro_space_simulator/domain/mining/deposit_excavation.dart';
import 'package:acro_space_simulator/domain/mining/resource_deposit.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mining excavates the ground: `DepositExcavation` turns a deposit's
/// cumulative extraction into a growing stepped quarry pit, deterministically
/// enough that a save can rebuild the pit from one number.
void main() {
  final system = SampleWorld.realSystem();
  final psyche = system.require(SampleWorld.psyche);

  ResourceDeposit deposit({double extracted = 0}) => ResourceDeposit(
        id: 'psyche-metal-1',
        body: SampleWorld.psyche,
        latitude: 0.2,
        longitude: 0.7,
        resource: ResourceType.ore,
        concentration: 0.95,
        reserves: 500000,
        extractedTotal: extracted,
      );

  const excavation = DepositExcavation();

  test('extract() accumulates lifetime total, including on infinite deposits',
      () {
    final d = deposit();
    d.extract(100);
    d.extract(50);
    expect(d.extractedTotal, 150);
    final infinite = ResourceDeposit(
      id: 'inf',
      body: SampleWorld.psyche,
      latitude: 0,
      longitude: 0,
      resource: ResourceType.ore,
      concentration: 1,
    );
    infinite.extract(70);
    expect(infinite.extractedTotal, 70);
  });

  test('no quantum earned -> no brushes, bookkeeping untouched', () {
    final d = deposit(extracted: excavation.quantumUnits - 1);
    final brushes =
        excavation.pendingBrushes(deposit: d, body: psyche, tick: 1);
    expect(brushes, isEmpty);
    expect(d.carvedQuanta, 0);
  });

  test('earned quanta emit growing stepped pits and advance carvedQuanta', () {
    final d = deposit(extracted: excavation.quantumUnits * 3);
    final brushes =
        excavation.pendingBrushes(deposit: d, body: psyche, tick: 7);
    expect(brushes, hasLength(3));
    expect(d.carvedQuanta, 3);
    for (final b in brushes) {
      expect(b.kind, TerrainBrushKind.steppedPit);
      expect(b.tick, 7);
    }
    // Each successive pit is strictly larger — it must swallow its
    // predecessor for the "latest pit wins" composition to hold.
    expect(brushes[1].radiusM, greaterThan(brushes[0].radiusM));
    expect(brushes[2].radiusM, greaterThan(brushes[1].radiusM));
    // Same centre: the pit grows in place over the lode.
    expect((brushes[2].centreBF - brushes[0].centreBF).length, lessThan(1e-6));

    // Calling again with nothing new earns nothing.
    expect(excavation.pendingBrushes(deposit: d, body: psyche, tick: 8),
        isEmpty);
  });

  test('maxQuanta caps the pit for effectively infinite extraction', () {
    final d = deposit(extracted: excavation.quantumUnits * 1e6);
    final brushes =
        excavation.pendingBrushes(deposit: d, body: psyche, tick: 1);
    expect(brushes, hasLength(excavation.maxQuanta));
  });

  test('a body without terrain earns no brushes', () {
    final ceres = system.require(const BodyId('ceres'));
    final d = ResourceDeposit(
      id: 'ceres-1',
      body: ceres.id,
      latitude: 0,
      longitude: 0,
      resource: ResourceType.ore,
      concentration: 1,
      extractedTotal: excavation.quantumUnits * 5,
    );
    expect(excavation.pendingBrushes(deposit: d, body: ceres, tick: 1),
        isEmpty);
  });

  test('save reconstruction: incremental carving == one-shot from the total',
      () {
    // Session A: mined in dribs, carved as it went.
    final a = deposit();
    final aBrushes = <TerrainBrush>[];
    for (var i = 0; i < 5; i++) {
      a.extract(excavation.quantumUnits);
      aBrushes.addAll(
          excavation.pendingBrushes(deposit: a, body: psyche, tick: i));
    }
    // Session B: loaded a save holding only extractedTotal; carves in one go.
    final b = deposit(extracted: a.extractedTotal);
    final bBrushes =
        excavation.pendingBrushes(deposit: b, body: psyche, tick: 99);

    expect(bBrushes.length, aBrushes.length);
    for (var i = 0; i < aBrushes.length; i++) {
      expect(bBrushes[i].radiusM, aBrushes[i].radiusM, reason: 'quantum $i');
      expect(bBrushes[i].depthM, aBrushes[i].depthM, reason: 'quantum $i');
      expect(bBrushes[i].datumRadiusM, aBrushes[i].datumRadiusM,
          reason: 'quantum $i');
      expect((bBrushes[i].centreBF - aBrushes[i].centreBF).length,
          lessThan(1e-9),
          reason: 'quantum $i');
    }
  });

  test('recorded pit actually lowers the walkable ground at the site', () {
    final d = deposit(extracted: excavation.quantumUnits * 4);
    final edits = InMemoryTerrainEditsRepository();
    for (final b
        in excavation.pendingBrushes(deposit: d, body: psyche, tick: 1)) {
      edits.record(psyche.id, b);
    }
    final cosLat = math.cos(d.latitude);
    final dx = cosLat * math.cos(d.longitude);
    final dy = cosLat * math.sin(d.longitude);
    final dz = math.sin(d.latitude);

    final pristine = psyche.terrainField!.groundRadiusAt(dx, dy, dz);
    final dug = psyche
        .terrainFieldWith(edits.forBody(psyche.id))!
        .groundRadiusAt(dx, dy, dz);
    expect(dug, lessThan(pristine - 0.5),
        reason: 'mining must visibly deepen the site');
  });

  test('live tick: a landed asteroid miner digs the pit as it drills', () {
    final miner = SampleWorld.buildAsteroidMiner();
    final deposits =
        InMemoryDepositRepository(SampleWorld.buildAsteroidDeposits());
    final terrainEdits = InMemoryTerrainEditsRepository();
    final tick = AdvanceSimulationTick(
      vessels: InMemoryVesselRepository([miner]),
      universe: StaticUniverseRepository(system),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: deposits,
      weather: const NullWeatherRepository(),
      terrainEdits: terrainEdits,
      // Tiny quantum so the drill's few units per tick carve within the test.
      excavation: const DepositExcavation(quantumUnits: 10),
      maxDynamicPressure: double.infinity,
    );
    // 1 s steps: rig baseRate 8 * concentration 0.95 = 7.6 units/tick.
    final clock = SimulationClock(warpFactor: 1, fixedStep: 1.0);
    for (var i = 0; i < 5; i++) {
      tick.execute(clock);
    }
    final d = deposits.byId('psyche-metal-1')!;
    expect(d.extractedTotal, greaterThan(10),
        reason: 'the rig must actually be mining');
    expect(d.carvedQuanta, greaterThan(0));
    expect(terrainEdits.forBody(SampleWorld.psyche), isNotNull,
        reason: 'mining must have recorded terrain excavation');
    expect(terrainEdits.forBody(SampleWorld.psyche)!.isEmpty, isFalse);
  });
}
