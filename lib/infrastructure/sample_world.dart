import 'dart:math' as math;

import '../domain/autonomy/flight_plan.dart';
import '../domain/autonomy/maneuver_planner.dart';
import '../domain/colony/building.dart';
import '../domain/colony/colony.dart';
import '../domain/dynamics/state_vector.dart';
import '../domain/lifesupport/crew.dart';
import '../domain/mining/mining_operation.dart';
import '../domain/mining/mining_rig.dart';
import '../domain/mining/resource_deposit.dart';
import '../domain/science/experiment.dart';
import '../domain/shared/quaternion.dart';
import '../domain/shared/vector3.dart';
import '../domain/simulation/epoch.dart';
import '../domain/thermal/thermal_state.dart';
import '../domain/universe/atmosphere_model.dart';
import '../domain/universe/celestial_body.dart';
import '../domain/universe/real_solar_system.dart';
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

  // ============================================================
  //  REAL SOLAR SYSTEM demo (Earth + Moon + planets + dwarfs)
  // ============================================================

  static final BodyId earth = const BodyId('earth');

  /// The real Solar System with a small starter fleet around Earth.
  static StarSystem realSystem() => RealSolarSystem.build();

  /// A demo vessel in Low Earth Orbit (~400 km), prograde, with experiments.
  static Vessel buildEarthOrbiter({double altitude = 400000}) {
    final body = RealSolarSystem.build().require(earth);
    final r = body.radius + altitude;
    final v = math.sqrt(body.mu / r);
    final tank = ResourceContainer(
        type: ResourceType.liquidFuel, capacity: 400, amount: 400, unitMass: 5);
    return Vessel(
      id: const VesselId('orbiter-1'),
      name: 'Orbiter',
      ownerId: 'player-1',
      state: StateVector(
        position: Vector3(r, 0, 0),
        velocity: Vector3(0, v, 0),
        // Nose (+Z) pointed prograde (+Y) so the chase cam has a real heading.
        attitude: Quaternion.axisAngle(Vector3.unitX, -math.pi / 2),
      ),
      dominantBody: earth,
      stages: [
        Stage(index: 0, parts: [
          Part(
            id: const PartId('engine-0'),
            name: 'Raptor',
            dryMass: 1500,
            inertiaContribution: Vector3(2000, 2000, 1000),
            engine: const Engine(
              name: 'Raptor',
              maxThrustVacuum: 2.3e6,
              maxThrustSeaLevel: 1.8e6,
              ispVacuum: 350,
              ispSeaLevel: 330,
              gimbalRange: 0.12,
            ),
            resources: [tank],
            crossSectionArea: 1.5,
          ),
        ]),
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
    )..experiments.addAll(const [
        Experiment(id: 'thermometer', baseValue: 8),
        Experiment(id: 'goo-canister', baseValue: 15),
      ]);
  }

  /// A MULTI-STAGE launch vehicle sitting on [body]'s surface at ([latDeg],
  /// [lonDeg]) — the craft an ascent/descent flight controls in the real 3D sim.
  /// Two stages (booster + upper) so the player can stage/decouple. Landed, at
  /// rest, nose pointing radially out (straight up).
  static Vessel buildSurfaceCraft(
    CelestialBody body, {
    double latDeg = 0,
    double lonDeg = 0,
    String id = 'ascent-craft',
    String name = 'Ascent Vehicle',
    String ownerId = 'player-1',
  }) {
    final lat = latDeg * math.pi / 180, lon = lonDeg * math.pi / 180;
    // Surface point in the body frame (Z = spin axis / north).
    final outward = Vector3(
      math.cos(lat) * math.cos(lon),
      math.cos(lat) * math.sin(lon),
      math.sin(lat),
    );
    final pos = outward * body.radius;
    // Nose points radially OUT (up). Body nose is +Z; rotate it onto [outward].
    final attitude = _alignZTo(outward);

    ResourceContainer tank(double cap) => ResourceContainer(
        type: ResourceType.liquidFuel, capacity: cap, amount: cap, unitMass: 5);
    Part stagePart(String pid, String label, double dry, double cap,
            double thrustVac, double thrustSl) =>
        Part(
          id: PartId(pid),
          name: label,
          dryMass: dry,
          inertiaContribution: Vector3(3000, 3000, 1500),
          engine: Engine(
            name: label,
            maxThrustVacuum: thrustVac,
            maxThrustSeaLevel: thrustSl,
            ispVacuum: 330,
            ispSeaLevel: 300,
            gimbalRange: 0.1,
          ),
          resources: [tank(cap)],
          crossSectionArea: 1.5,
        );

    return Vessel(
      id: VesselId(id),
      name: name,
      ownerId: ownerId,
      state: StateVector(
          position: pos, velocity: Vector3.zero, attitude: attitude),
      dominantBody: body.id,
      landed: true,
      stages: [
        // Stage 0 = upper (fires last, on top); stage 1 = booster (active first
        // — the active stage is the LAST in the list per the Vessel model).
        Stage(index: 0, parts: [
          stagePart('upper-engine', 'Upper Stage', 1500, 300, 8.0e5, 6.5e5),
        ]),
        Stage(index: 1, parts: [
          stagePart('booster-engine', 'Booster', 4000, 1200, 3.0e6, 2.4e6),
        ]),
      ],
      thermal: [
        PartThermalState(
          part: const PartId('booster-engine'),
          temperature: 290,
          heatCapacity: 12000,
          maxTemperature: 2400,
          surfaceArea: 10,
        ),
      ],
    );
  }

  /// A simple named orbiter around [body] at [altitude], prograde — used to
  /// inject TRAFFIC (cargo shuttles, other players) into the sim so they show as
  /// craft with their own orbital trajectories.
  static Vessel buildTrafficVessel(
    CelestialBody body, {
    required String id,
    required String name,
    String ownerId = 'traffic',
    double altitude = 300000,
    double phase = 0, // start angle around the orbit (rad)
  }) {
    final r = body.radius + altitude;
    final v = math.sqrt(body.mu / r);
    final cp = math.cos(phase), sp = math.sin(phase);
    final pos = Vector3(r * cp, r * sp, 0);
    final vel = Vector3(-v * sp, v * cp, 0); // prograde tangent
    final tank = ResourceContainer(
        type: ResourceType.liquidFuel, capacity: 200, amount: 200, unitMass: 5);
    return Vessel(
      id: VesselId(id),
      name: name,
      ownerId: ownerId,
      state: StateVector(position: pos, velocity: vel),
      dominantBody: body.id,
      stages: [
        Stage(index: 0, parts: [
          Part(
            id: PartId('$id-core'),
            name: 'Core',
            dryMass: 2000,
            inertiaContribution: Vector3(2000, 2000, 1000),
            engine: const Engine(
              name: 'cargo',
              maxThrustVacuum: 1.0e5,
              maxThrustSeaLevel: 8.0e4,
              ispVacuum: 320,
              ispSeaLevel: 290,
            ),
            resources: [tank],
          ),
        ]),
      ],
    );
  }

  /// Quaternion rotating the body nose (+Z) onto the unit [target] direction.
  static Quaternion _alignZTo(Vector3 target) {
    final z = Vector3.unitZ;
    final t = target.normalized;
    final dot = z.dot(t).clamp(-1.0, 1.0);
    if (dot > 0.99999) return Quaternion.identity;
    if (dot < -0.99999) return Quaternion.axisAngle(Vector3.unitX, math.pi);
    final axis = z.cross(t).normalized;
    return Quaternion.axisAngle(axis, math.acos(dot));
  }

  /// A second craft headed for the Moon on a Hohmann transfer, autopilot-flown.
  static Vessel buildEarthFreighter() {
    final body = RealSolarSystem.build().require(earth);
    final r = body.radius + 300000;
    final v = math.sqrt(body.mu / r);
    final tank = ResourceContainer(
        type: ResourceType.liquidFuel, capacity: 600, amount: 600, unitMass: 5);
    final f = Vessel(
      id: const VesselId('luna-freighter'),
      name: 'Luna Freighter',
      ownerId: 'ai',
      state: StateVector(position: Vector3(r, 0, 0), velocity: Vector3(0, v, 0)),
      dominantBody: earth,
      stages: [
        Stage(index: 0, parts: [
          Part(
            id: const PartId('f-core'),
            name: 'Core',
            dryMass: 3000,
            inertiaContribution: Vector3(4000, 4000, 2000),
            engine: const Engine(
              name: 'ion',
              maxThrustVacuum: 5.0e5,
              maxThrustSeaLevel: 4.0e5,
              ispVacuum: 800,
              ispSeaLevel: 300,
              gimbalRange: 0.1,
            ),
            resources: [tank],
          ),
        ]),
      ],
    );
    // A flight computer (modelled as crew) so the planned transfer burns fire
    // even when the freighter passes behind Earth (out of ground link).
    f.crew = CrewModule(count: 2);
    const planner = ManeuverPlanner();
    f.flightPlan = FlightPlan(
      vessel: f.id,
      legs: [
        FlightLeg(
          targetBody: earth,
          targetAltitude: 2000000,
          nodes: planner.hohmann(
            mu: body.mu,
            fromRadius: r,
            toRadius: body.radius + 2000000,
            startEpoch: const Epoch(30),
          ),
        ),
      ],
    );
    return f;
  }
}
