import 'dart:convert';

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/persistence/game_state_codec.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const codec = GameStateCodec();

  AdvanceSimulationTick tickFor(InMemoryVesselRepository vessels) =>
      AdvanceSimulationTick(
        vessels: vessels,
        universe: StaticUniverseRepository(SampleWorld.realSystem()),
        compute: DartCompute(),
        soi: const SoiTransitionService(),
        events: InMemoryEventBus(),
        colonies: InMemoryColonyRepository(),
        deposits: InMemoryDepositRepository(),
        weather: const NullWeatherRepository(),
      );

  test('a sim resumed from a save continues identically to one that never saved',
      () {
    // Reference run: 100 ticks straight.
    final refVessels = InMemoryVesselRepository([SampleWorld.buildVessel()]);
    final refClock = SimulationClock(warpFactor: 5, fixedStep: 1.0);
    final refTick = tickFor(refVessels);
    for (var i = 0; i < 100; i++) {
      refTick.execute(refClock);
    }
    final reference = WorldSnapshot.capture(refClock.tick, refVessels).fingerprint;

    // Saved run: 50 ticks, serialize, restore into fresh repos, 50 more.
    final vessels = InMemoryVesselRepository([SampleWorld.buildVessel()]);
    final clock = SimulationClock(warpFactor: 5, fixedStep: 1.0);
    final tick = tickFor(vessels);
    for (var i = 0; i < 50; i++) {
      tick.execute(clock);
    }
    final json = jsonEncode(codec.encode(
      vessels: vessels,
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: clock,
    ));

    final resumedVessels = InMemoryVesselRepository();
    final resumedClock = SimulationClock(fixedStep: 1.0);
    codec.decode(
      jsonDecode(json) as Map<String, dynamic>,
      vessels: resumedVessels,
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: resumedClock,
    );
    final resumedTick = tickFor(resumedVessels);
    for (var i = 0; i < 50; i++) {
      resumedTick.execute(resumedClock);
    }
    final resumed =
        WorldSnapshot.capture(resumedClock.tick, resumedVessels).fingerprint;

    expect(resumed, equals(reference));
  });
}
