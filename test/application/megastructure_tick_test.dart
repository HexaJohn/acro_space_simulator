import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/megastructure/megastructure.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AdvanceSimulationTick buildTick(InMemoryMegastructureRepository megas) =>
      AdvanceSimulationTick(
        vessels: InMemoryVesselRepository(),
        universe: StaticUniverseRepository(SampleWorld.realSystem()),
        compute: DartCompute(),
        soi: const SoiTransitionService(),
        events: InMemoryEventBus(),
        colonies: InMemoryColonyRepository(),
        deposits: InMemoryDepositRepository(),
        weather: const NullWeatherRepository(),
        megastructures: megas,
      );

  test('on-site power + delivered material builds a megastructure to completion',
      () {
    final mega = Megastructure.oNeillCylinder(id: 'oneill-1', radius: 100, length: 200)
      ..siteGenerationWatts = 1e22; // a colocated fusion/antimatter plant
    final megas = InMemoryMegastructureRepository([mega]);
    final tick = buildTick(megas);

    expect(mega.isComplete, isFalse);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 1e7);
    for (var i = 0; i < 20 && !mega.isComplete; i++) {
      // Cargo craft drops off material at the site each "tick" (simulated here).
      final p = mega.currentPhase;
      if (p != null) mega.deliverMaterial(p.requiredMass);
      tick.execute(clock);
    }

    expect(mega.isComplete, isTrue);
    expect(mega.operational, isTrue);
    expect(mega.populationCapacity, greaterThan(0));
  });

  test('without on-site power a megastructure cannot complete (no grid teleport)',
      () {
    final mega = Megastructure.oNeillCylinder(id: 'm', radius: 100, length: 200);
    // No siteGenerationWatts -> no energy ever, even with material delivered.
    mega.deliverMaterial(mega.totalRequiredMass * 2);
    final megas = InMemoryMegastructureRepository([mega]);
    final tick = buildTick(megas);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 1e7);
    for (var i = 0; i < 20; i++) {
      tick.execute(clock);
    }
    expect(mega.isComplete, isFalse);
  });

  test('completion publishes a MegastructureMilestone event', () {
    final mega = Megastructure.oNeillCylinder(id: 'm', radius: 100, length: 200)
      ..siteGenerationWatts = 1e22;
    final megas = InMemoryMegastructureRepository([mega]);
    final events = InMemoryEventBus();
    final tick = AdvanceSimulationTick(
      vessels: InMemoryVesselRepository(),
      universe: StaticUniverseRepository(SampleWorld.realSystem()),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: events,
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
      megastructures: megas,
    );
    final clock = SimulationClock(warpFactor: 1, fixedStep: 1e7);
    for (var i = 0; i < 20 && !mega.isComplete; i++) {
      final p = mega.currentPhase;
      if (p != null) mega.deliverMaterial(p.requiredMass);
      tick.execute(clock);
    }
    expect(
      events.recent.whereType<MegastructureMilestone>().any((e) => e.completed),
      isTrue,
    );
  });
}
