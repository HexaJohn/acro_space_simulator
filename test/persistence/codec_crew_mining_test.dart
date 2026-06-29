import 'dart:convert';

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/persistence/game_state_codec.dart';
import 'package:acro_space_simulator/domain/lifesupport/crew.dart';
import 'package:acro_space_simulator/domain/mining/mining_operation.dart';
import 'package:acro_space_simulator/domain/mining/mining_rig.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const codec = GameStateCodec();

  Vessel restore(Vessel v) {
    final json = jsonEncode(codec.encode(
      vessels: InMemoryVesselRepository([v]),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(),
    ));
    final repo = InMemoryVesselRepository();
    codec.decode(
      jsonDecode(json) as Map<String, dynamic>,
      vessels: repo,
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(),
    );
    return repo.all().first;
  }

  test('crew survive a save/load round-trip', () {
    final v = SampleWorld.buildVessel();
    v.crew = CrewModule(
      count: 4,
      foodPerCrewPerSecond: 0.01,
      oxygenPerCrewPerSecond: 0.02,
    );
    final r = restore(v);
    expect(r.crew, isNotNull);
    expect(r.crew!.count, 4);
    expect(r.crew!.oxygenPerCrewPerSecond, closeTo(0.02, 1e-9));
  });

  test('a mining operation survives a save/load round-trip', () {
    final v = SampleWorld.buildMiner(); // landed miner with an ore drill
    final r = restore(v);
    expect(r.mining, isNotNull);
    expect(r.mining!.depositId, v.mining!.depositId);
    expect(r.mining!.rig.active, v.mining!.rig.active);
    expect(r.mining!.targetType, v.mining!.targetType);
    expect(r.landed, isTrue);
  });

  test('a vessel without crew/mining restores them as null', () {
    final v = SampleWorld.buildVessel();
    final r = restore(v);
    expect(r.crew, isNull);
    expect(r.mining, isNull);
  });

  test('engines survive a save/load round-trip (thrust after load)', () {
    final v = SampleWorld.buildVessel();
    // The sample vessel must have at least one engine for this to be meaningful.
    final srcEngines = v.allParts.where((p) => p.isEngine).toList();
    expect(srcEngines, isNotEmpty,
        reason: 'sample vessel should have an engine to test');
    final r = restore(v);
    final restoredEngines = r.allParts.where((p) => p.isEngine).toList();
    expect(restoredEngines.length, srcEngines.length,
        reason: 'all engines must restore as engines, not dead structural mass');
    final e0 = srcEngines.first.engine!, r0 = restoredEngines.first.engine!;
    expect(r0.maxThrustVacuum, closeTo(e0.maxThrustVacuum, 1e-6));
    expect(r0.ispVacuum, closeTo(e0.ispVacuum, 1e-6));
    expect(r0.propellant, e0.propellant);
  });

  // Keep an unused import meaningful.
  test('mining rig fields default sensibly', () {
    final rig = MiningRig(id: 'x', baseRate: 1, powerDraw: 1);
    expect(rig.active, isFalse);
    expect(MiningOperation(rig: rig, depositId: 'd', targetType: ResourceType.ore).depositId, 'd');
  });
}
