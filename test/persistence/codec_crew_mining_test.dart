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

  // Keep an unused import meaningful.
  test('mining rig fields default sensibly', () {
    final rig = MiningRig(id: 'x', baseRate: 1, powerDraw: 1);
    expect(rig.active, isFalse);
    expect(MiningOperation(rig: rig, depositId: 'd', targetType: ResourceType.ore).depositId, 'd');
  });
}
