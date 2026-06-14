import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/colony/building.dart';
import 'package:acro_space_simulator/domain/colony/colony.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/mining/mining_operation.dart';
import 'package:acro_space_simulator/domain/mining/mining_rig.dart';
import 'package:acro_space_simulator/domain/mining/resource_deposit.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/thermal/thermal_state.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/domain/vessel/stage.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AdvanceSimulationTick buildTick({
    required InMemoryVesselRepository vessels,
    required InMemoryColonyRepository colonies,
    required InMemoryDepositRepository deposits,
  }) {
    final system = SampleWorld.buildSystem();
    return AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(system),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: colonies,
      deposits: deposits,
      weather: const NullWeatherRepository(),
      // Isolate thermal behaviour from structural overstress in these tests.
      maxDynamicPressure: double.infinity,
    );
  }

  test('subsystem phase mines ore for a landed miner during the tick', () {
    final body = SampleWorld.buildSystem().require(SampleWorld.kerbin);
    final ore = ResourceContainer(
        type: ResourceType.ore, capacity: 100, amount: 0, unitMass: 1);
    final power = ResourceContainer(
        type: ResourceType.electricCharge, capacity: 1000, amount: 1000, unitMass: 0);
    final drill = Part(
        id: const PartId('drill'),
        name: 'Drill',
        dryMass: 500,
        resources: [ore, power]);

    final miner = Vessel(
      id: const VesselId('miner'),
      name: 'Miner',
      ownerId: 'p',
      // sitting on the surface (radius), zero velocity, landed
      state: StateVector(position: Vector3(body.radius, 0, 0), velocity: Vector3.zero),
      dominantBody: SampleWorld.kerbin,
      stages: [Stage(index: 0, parts: [drill])],
      landed: true,
    )..mining = MiningOperation(
        rig: MiningRig(id: 'rig', baseRate: 10, powerDraw: 5, active: true),
        depositId: 'd1',
        targetType: ResourceType.ore,
      );

    final deposit = ResourceDeposit(
      id: 'd1',
      body: SampleWorld.kerbin,
      latitude: 0,
      longitude: 0,
      resource: ResourceType.ore,
      concentration: 1.0,
      reserves: 1000,
    );

    final vessels = InMemoryVesselRepository([miner]);
    final colonies = InMemoryColonyRepository();
    final deposits = InMemoryDepositRepository([deposit]);
    final tick = buildTick(vessels: vessels, colonies: colonies, deposits: deposits);

    final clock = SimulationClock(warpFactor: 1, fixedStep: 1.0);
    for (var i = 0; i < 5; i++) {
      tick.execute(clock);
    }
    expect(ore.amount, greaterThan(0));
  });

  test('subsystem phase advances colony production during the tick', () {
    final oreC = ResourceContainer(
        type: ResourceType.ore, capacity: 1000, amount: 500, unitMass: 1);
    final waterC = ResourceContainer(
        type: ResourceType.water, capacity: 1000, amount: 0, unitMass: 1);
    final colony = Colony(
      id: 'base',
      name: 'Base',
      body: SampleWorld.kerbin,
      latitude: 0,
      longitude: 0,
      population: 5,
      buildings: [
        Building(
          id: 'r',
          spec: const BuildingSpec(
            type: 'refinery',
            inputsPerSecond: {ResourceType.ore: 2},
            outputsPerSecond: {ResourceType.water: 1},
            jobs: 5,
          ),
          gridX: 0,
          gridY: 0,
        ),
      ],
      stockpile: {ResourceType.ore: oreC, ResourceType.water: waterC},
    );

    final vessels = InMemoryVesselRepository();
    final colonies = InMemoryColonyRepository([colony]);
    final deposits = InMemoryDepositRepository();
    final tick = buildTick(vessels: vessels, colonies: colonies, deposits: deposits);

    final clock = SimulationClock(warpFactor: 1, fixedStep: 1.0);
    for (var i = 0; i < 10; i++) {
      tick.execute(clock);
    }
    expect(waterC.amount, greaterThan(0));
  });

  test('reentry heats a part flying fast in atmosphere', () {
    final hull = PartThermalState(
      part: const PartId('hull'),
      temperature: 300,
      heatCapacity: 2000,
      maxTemperature: 2500,
      surfaceArea: 6,
    );
    final body = SampleWorld.buildSystem().require(SampleWorld.kerbin);
    // 10 km altitude, screaming fast horizontally -> reentry heating.
    final vessel = Vessel(
      id: const VesselId('reentry'),
      name: 'Reentry',
      ownerId: 'p',
      state: StateVector(
        position: Vector3(body.radius + 10000, 0, 0),
        velocity: Vector3(0, 2500, 0),
      ),
      dominantBody: SampleWorld.kerbin,
      stages: const [],
      thermal: [hull],
    );

    final vessels = InMemoryVesselRepository([vessel]);
    final tick = buildTick(
      vessels: vessels,
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
    );
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.1);
    for (var i = 0; i < 10; i++) {
      tick.execute(clock);
    }
    expect(vessel.thermalOf(const PartId('hull'))!.temperature, greaterThan(300));
  });
}
