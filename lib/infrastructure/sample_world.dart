import 'dart:math' as math;

import '../domain/autonomy/flight_plan.dart';
import '../domain/autonomy/maneuver_planner.dart';
import '../domain/colony/building.dart';
import '../domain/colony/colony.dart';
import '../domain/dynamics/state_vector.dart';
import '../domain/mining/mining_operation.dart';
import '../domain/mining/mining_rig.dart';
import '../domain/mining/resource_deposit.dart';
import '../domain/shared/quaternion.dart';
import '../domain/shared/vector3.dart';
import '../domain/simulation/epoch.dart';
import '../domain/thermal/thermal_state.dart';
import '../domain/universe/atmosphere_model.dart';
import '../domain/universe/celestial_body.dart';
import '../domain/universe/star_system.dart';
import '../domain/vessel/part.dart';
import '../domain/vessel/propulsion.dart';
import '../domain/vessel/resource_container.dart';
import '../domain/vessel/stage.dart';
import '../domain/vessel/vessel.dart';
import '../domain/weather/weather_system.dart';

/// Composition-root sample data: a small Kerbin-like system and a vessel in low
/// orbit, used to drive the demo. This is infrastructure (concrete data), not
/// domain — it just constructs domain aggregates.
class SampleWorld {
  static final BodyId kerbin = const BodyId('kerbin');
  static final BodyId mun = const BodyId('mun');

  static StarSystem buildSystem() {
    final planet = CelestialBody(
      id: kerbin,
      name: 'Kerbin',
      mu: 3.5316e12, // KSP Kerbin standard gravitational parameter
      radius: 600000, // 600 km
      soiRadius: 84159286,
      siderealRotationPeriod: 21549.425,
      parent: null,
      atmosphere: const AtmosphereModel(
        seaLevelPressure: 101325,
        seaLevelDensity: 1.225,
        seaLevelTemperature: 288,
        scaleHeight: 5600,
        atmosphereHeight: 70000,
      ),
      solarFlux: 1360,
    );
    final moon = CelestialBody(
      id: mun,
      name: 'Mun',
      mu: 6.5138e10, // KSP Mun
      radius: 200000,
      soiRadius: 2429559,
      siderealRotationPeriod: 138984,
      parent: kerbin,
      orbitRadius: 12000000, // semi-major axis, 12,000 km
      orbitPhase: 0,
      orbitEccentricity: 0.05, // slightly elliptical
      orbitInclination: 0.05, // ~3 deg, out of the equatorial plane
      solarFlux: 1360,
    );
    return StarSystem(
      name: 'Kerbol (sample)',
      rootStar: kerbin,
      bodies: [planet, moon],
    );
  }

  /// A vessel on a circular low orbit at [altitude] above Kerbin, in the XY
  /// plane (Z up), moving prograde. Circular speed v = sqrt(mu / r).
  static Vessel buildVessel({double altitude = 100000}) {
    final body = buildSystem().require(kerbin);
    final r = body.radius + altitude;
    final v = math.sqrt(body.mu / r);

    final state = StateVector(
      position: Vector3(r, 0, 0),
      velocity: Vector3(0, v, 0), // prograde in +Y for a +X start
      attitude: Quaternion.identity,
    );

    final tank = ResourceContainer(
      type: ResourceType.liquidFuel,
      capacity: 400,
      amount: 400,
      unitMass: 5,
    );
    final engine = Part(
      id: const PartId('engine-0'),
      name: 'LV-T45',
      dryMass: 1500,
      inertiaContribution: Vector3(2000, 2000, 1000),
      engine: const Engine(
        name: 'LV-T45',
        maxThrustVacuum: 215000,
        maxThrustSeaLevel: 167000,
        ispVacuum: 320,
        ispSeaLevel: 250,
      ),
      resources: [tank],
      crossSectionArea: 1.5,
    );

    return Vessel(
      id: const VesselId('demo-1'),
      name: 'Demo Orbiter',
      ownerId: 'player-1',
      state: state,
      dominantBody: kerbin,
      stages: [
        Stage(index: 0, parts: [engine]),
      ],
      thermal: [
        PartThermalState(
          part: const PartId('engine-0'),
          temperature: 290,
          heatCapacity: 8000,
          maxTemperature: 2200,
          surfaceArea: 6,
        ),
      ],
    );
  }

  /// A landed miner on the surface with an active ore drill, bound to [oreField].
  static Vessel buildMiner() {
    final body = buildSystem().require(kerbin);
    final ore = ResourceContainer(
        type: ResourceType.ore, capacity: 200, amount: 0, unitMass: 1);
    final power = ResourceContainer(
        type: ResourceType.electricCharge,
        capacity: 2000,
        amount: 2000,
        unitMass: 0);
    final drill = Part(
      id: const PartId('drill-0'),
      name: 'Drill-O-Matic',
      dryMass: 1200,
      resources: [ore, power],
      crossSectionArea: 2.0,
    );
    return Vessel(
      id: const VesselId('miner-1'),
      name: 'Surface Miner',
      ownerId: 'player-1',
      state: StateVector(
        position: Vector3(body.radius, 0, 0),
        velocity: Vector3.zero,
      ),
      dominantBody: kerbin,
      stages: [Stage(index: 0, parts: [drill])],
      landed: true,
    )..mining = MiningOperation(
        rig: MiningRig(id: 'rig-0', baseRate: 8, powerDraw: 4, active: true),
        depositId: 'ore-field-1',
        targetType: ResourceType.ore,
      );
  }

  static ResourceDeposit buildDeposit() => ResourceDeposit(
        id: 'ore-field-1',
        body: kerbin,
        latitude: 0,
        longitude: 0,
        resource: ResourceType.ore,
        concentration: 0.9,
        reserves: 100000,
      );

  /// A small surface colony: a refinery turning ore into water plus housing.
  static Colony buildColony() {
    final ore = ResourceContainer(
        type: ResourceType.ore, capacity: 5000, amount: 2000, unitMass: 1);
    final water = ResourceContainer(
        type: ResourceType.water, capacity: 5000, amount: 0, unitMass: 1);
    return Colony(
      id: 'colony-1',
      name: 'New Kerbal City',
      body: kerbin,
      latitude: 0,
      longitude: 0,
      population: 20,
      buildings: [
        Building(
          id: 'refinery-1',
          spec: const BuildingSpec(
            type: 'refinery',
            inputsPerSecond: {ResourceType.ore: 1.5},
            outputsPerSecond: {ResourceType.water: 1.0},
            jobs: 10,
            powerDraw: 15,
          ),
          gridX: 0,
          gridY: 0,
        ),
        Building(
          id: 'hab-1',
          spec: const BuildingSpec(type: 'hab', housing: 200, jobs: 0),
          gridX: 1,
          gridY: 0,
        ),
        Building(
          id: 'solar-1',
          spec: const BuildingSpec(type: 'solar', powerOutput: 20),
          gridX: 2,
          gridY: 0,
        ),
      ],
      stockpile: {
        ResourceType.ore: ore,
        ResourceType.water: water,
      },
    );
  }

  /// A weather system over Kerbin: a couple of drifting storm cells.
  static WeatherSystem buildWeather() => WeatherSystem(
        body: kerbin,
        cells: [
          const WeatherCell(
            latitude: 0.2,
            longitude: 0.1,
            radius: 800000,
            wind: Vector3(45, 5, 0), // brisk easterly
            precipitation: 0.7,
            turbulence: 0.6,
          ),
          const WeatherCell(
            latitude: -0.4,
            longitude: 1.2,
            radius: 600000,
            wind: Vector3(-30, 10, 0),
            precipitation: 0.4,
            turbulence: 0.8,
          ),
        ],
      );

  /// An autonomous freighter in low orbit with a Hohmann plan to raise its
  /// orbit — the autopilot flies it.
  static Vessel buildFreighter() {
    final body = buildSystem().require(kerbin);
    final r = body.radius + 90000;
    final v = math.sqrt(body.mu / r);
    final tank = ResourceContainer(
        type: ResourceType.liquidFuel, capacity: 300, amount: 300, unitMass: 5);
    final core = Part(
      id: const PartId('freighter-core'),
      name: 'Freighter Core',
      dryMass: 2000,
      inertiaContribution: Vector3(3000, 3000, 1500),
      engine: const Engine(
        name: 'cargo-ion',
        maxThrustVacuum: 60000,
        maxThrustSeaLevel: 40000,
        ispVacuum: 800,
        ispSeaLevel: 300,
        gimbalRange: 0.12, // gimballed nozzle for steering during burns
      ),
      resources: [tank],
    );
    final freighter = Vessel(
      id: const VesselId('freighter-1'),
      name: 'Auto Freighter',
      ownerId: 'ai',
      state: StateVector(position: Vector3(r, 0, 0), velocity: Vector3(0, v, 0)),
      dominantBody: kerbin,
      stages: [Stage(index: 0, parts: [core])],
    );
    const planner = ManeuverPlanner();
    freighter.flightPlan = FlightPlan(
      vessel: freighter.id,
      legs: [
        FlightLeg(
          targetBody: kerbin,
          targetAltitude: 250000,
          nodes: planner.hohmann(
            mu: body.mu,
            fromRadius: r,
            toRadius: body.radius + 250000,
            startEpoch: const Epoch(20),
          ),
        ),
      ],
    );
    return freighter;
  }
}
