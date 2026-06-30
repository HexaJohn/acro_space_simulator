import 'dart:convert';

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/persistence/game_state_codec.dart';
import 'package:acro_space_simulator/domain/autonomy/flight_plan.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const codec = GameStateCodec();

  Map<String, dynamic> roundTrip(Vessel v) {
    final json = jsonEncode(codec.encode(
      vessels: InMemoryVesselRepository([v]),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(),
    ));
    return jsonDecode(json) as Map<String, dynamic>;
  }

  Vessel restoreFrom(Map<String, dynamic> json) {
    final repo = InMemoryVesselRepository();
    codec.decode(
      json,
      vessels: repo,
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(),
    );
    return repo.all().first;
  }

  test('thermal state survives a save/load round-trip', () {
    final v = SampleWorld.buildVessel();
    v.thermal.first.temperature = 777;
    final restored = restoreFrom(roundTrip(v));
    expect(restored.thermal, isNotEmpty);
    expect(restored.thermal.first.temperature, closeTo(777, 1e-6));
    expect(restored.thermal.first.part, v.thermal.first.part);
  });

  test('flight plan survives a save/load round-trip', () {
    final v = SampleWorld.buildVessel();
    v.flightPlan = FlightPlan(
      vessel: v.id,
      legs: [
        FlightLeg(
          targetBody: SampleWorld.earth,
          targetAltitude: 300000,
          nodes: [
            ManeuverNode(executeAt: const Epoch(12), deltaV: const Vector3(120, 0, 0)),
            ManeuverNode(executeAt: const Epoch(34), deltaV: const Vector3(0, 30, 0)),
          ],
        ),
      ],
    );
    final restored = restoreFrom(roundTrip(v));
    expect(restored.flightPlan, isNotNull);
    final leg = restored.flightPlan!.currentLeg!;
    expect(leg.nodes.length, 2);
    expect(leg.nodes.first.executeAt.seconds, 12);
    expect(leg.nodes.first.deltaV.x, closeTo(120, 1e-6));
    expect(leg.targetAltitude, closeTo(300000, 1e-6));
  });

  test('a vessel with no plan/thermal restores cleanly', () {
    final v = Vessel(
      id: const VesselId('bare'),
      name: 'Bare',
      ownerId: 'p',
      state: SampleWorld.buildVessel().state,
      dominantBody: SampleWorld.earth,
      stages: const [],
    );
    final restored = restoreFrom(roundTrip(v));
    expect(restored.flightPlan, isNull);
    expect(restored.thermal, isEmpty);
  });
}
