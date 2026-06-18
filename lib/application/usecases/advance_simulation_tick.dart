import 'dart:math' as math;

import '../../domain/aerodynamics/aero_force.dart';
import '../../domain/agriculture/farming_service.dart';
import '../../domain/autonomy/attitude_controller.dart';
import '../../domain/autonomy/autopilot_updater.dart';
import '../../domain/autonomy/cargo_scheduler.dart';
import '../../domain/autonomy/docking_updater.dart';
import '../../domain/colony/city_mining_service.dart';
import '../../domain/colony/happiness_service.dart';
import '../../domain/colony/supply_chain.dart';
import '../../domain/colony/zone_growth_service.dart';
import '../../domain/comms/comms_service.dart';
import '../../domain/comms/relay_network.dart';
import '../../domain/contracts/contract_tracker.dart';
import '../../domain/dynamics/force_model.dart';
import '../../domain/dynamics/jet_force.dart';
import '../../domain/dynamics/structural_service.dart';
import '../../domain/economy/treasury.dart';
import '../../domain/lifesupport/life_support_service.dart';
import '../../domain/megastructure/megastructure_construction.dart';
import '../../domain/science/situation_service.dart';
import '../../domain/dynamics/gravity_force.dart';
import '../../domain/dynamics/state_vector.dart';
import '../../domain/orbits/body_ephemeris.dart';
import '../../domain/orbits/soi_transition_service.dart';
import '../../domain/planetary/magnetosphere.dart';
import '../../domain/planetary/splashdown_service.dart';
import '../../domain/radiation/radiation_environment.dart';
import '../../domain/radiation/radiation_service.dart';
import '../../domain/science/experiment_runner.dart';
import '../../domain/science/research_ledger.dart';
import '../../domain/simulation/domain_event.dart';
import '../../domain/orbits/state_vector_converter.dart';
import '../../domain/thermal/eclipse_service.dart';
import '../../domain/shared/vector3.dart';
import '../../domain/simulation/simulation_clock.dart';
import '../../domain/subsystems/vessel_mining_updater.dart';
import '../../domain/subsystems/vessel_thermal_updater.dart';
import '../../domain/vessel/isru_service.dart';
import '../../domain/universe/atmosphere_model.dart';
import '../../domain/universe/celestial_body.dart';
import '../../domain/universe/star_system.dart';
import '../../domain/vessel/vessel.dart';
import '../../domain/weather/weather_updater.dart';
import '../ports/compute_port.dart';
import '../ports/event_bus.dart';
import '../ports/repositories.dart';
import '../ports/world_repositories.dart';

/// THE core simulation loop, as a use case.
///
/// One call advances every vessel by one fixed step in two phases:
///   MOTION  — SOI resolution, mode selection, integrate/propagate.
///   SUBSYSTEMS — thermal, mining (per vessel); supply chain (per colony).
///
/// Orchestration only — all physics/systems logic lives in the domain; all IO
/// behind ports. Gameplay-system repos are optional so a motion-only tick can
/// still be built (the [NullWeatherRepository] / empty repos are the defaults).
class AdvanceSimulationTick {
  final VesselRepository vessels;
  final UniverseRepository universe;
  final ComputePort compute;
  final SoiTransitionService soi;
  final EventBus events;
  final ColonyRepository colonies;
  final DepositRepository deposits;
  final WeatherRepository weather;
  final CargoScheduleRepository cargo;
  final StateVectorOrbitConverter converter;
  final VesselThermalUpdater thermalUpdater;
  final VesselMiningUpdater miningUpdater;
  final SupplyChain supplyChain;
  final ZoneGrowthService zoneGrowth;
  final HappinessService happinessService;
  final CityMiningService cityMining;
  final FarmingService farming;
  final IsruService isru;
  final MegastructureRepository megastructures;
  final MegastructureConstruction megaConstruction;
  final RadiationEnvironment radiationEnvironment;
  final RadiationService radiation;
  final SplashdownService splashdown;
  final AutopilotUpdater autopilot;
  final DockingUpdater dockingUpdater;
  final CargoScheduler cargoScheduler;
  final WeatherUpdater weatherUpdater;
  final BodyEphemeris ephemeris;
  final EclipseService eclipse;
  final AttitudeController attitudeController;
  final ExperimentRunner experimentRunner;
  final CommsService comms;
  final RelayNetwork relayNetwork;
  final LifeSupportService lifeSupport;
  final SituationService situations;
  final StructuralService structural;

  /// Dynamic-pressure limit (Pa) above which a vessel breaks apart in atmosphere.
  final double maxDynamicPressure;

  /// Debug cheats: skip the aerodynamic (max-Q) structural-failure check, the
  /// overheating destruction check, and/or impact destruction (any touchdown
  /// speed lands instead of exploding), so a craft can fly an otherwise-fatal
  /// reentry / launch / landing profile while testing.
  final bool disableAeroStress;
  final bool disableOverheat;
  final bool disableImpact;

  /// Optional contracts board; when set, the tick raises SituationEntered events
  /// and feeds all vessel events to it. Completed-contract rewards flow into
  /// [research] (science) and [treasury] (funds) when those are provided.
  final ContractBoard? contracts;
  final Treasury? treasury;

  /// Campaign-wide science ledger experiments deposit into. Defaults to a fresh
  /// ledger; callers that want to track/spend science pass their own.
  final ResearchLedger research;

  AdvanceSimulationTick({
    required this.vessels,
    required this.universe,
    required this.compute,
    required this.soi,
    required this.events,
    required this.colonies,
    required this.deposits,
    required this.weather,
    this.cargo = const NullCargoScheduleRepository(),
    this.converter = const StateVectorOrbitConverter(),
    this.thermalUpdater = const VesselThermalUpdater(),
    this.miningUpdater = const VesselMiningUpdater(),
    this.supplyChain = const SupplyChain(),
    this.zoneGrowth = const ZoneGrowthService(),
    this.happinessService = const HappinessService(),
    this.cityMining = const CityMiningService(),
    this.farming = const FarmingService(),
    this.isru = const IsruService(),
    this.megastructures = const NullMegastructureRepository(),
    this.megaConstruction = const MegastructureConstruction(),
    this.radiationEnvironment = const RadiationEnvironment(),
    this.radiation = const RadiationService(),
    this.splashdown = const SplashdownService(),
    this.autopilot = const AutopilotUpdater(),
    this.dockingUpdater = const DockingUpdater(),
    this.cargoScheduler = const CargoScheduler(),
    this.weatherUpdater = const WeatherUpdater(),
    this.ephemeris = const BodyEphemeris(),
    this.eclipse = const EclipseService(),
    this.attitudeController = const AttitudeController(),
    this.experimentRunner = const ExperimentRunner(),
    this.comms = const CommsService(),
    this.relayNetwork = const RelayNetwork(),
    this.lifeSupport = const LifeSupportService(),
    this.situations = const SituationService(),
    this.structural = const StructuralService(),
    // Max-Q before structural failure. 80 kPa was too low — a heat-shielded
    // reentry capsule routinely rides out higher dynamic pressure than a flimsy
    // launch stack, and a normal descent was breaking up. 200 kPa survives a
    // realistic reentry / steep launch; only a genuinely insane dive (very fast,
    // very low) still tears the ship apart.
    this.maxDynamicPressure = 200000,
    this.disableAeroStress = false,
    this.disableOverheat = false,
    this.disableImpact = false,
    this.contracts,
    this.treasury,
    ResearchLedger? research,
  }) : research = research ?? ResearchLedger();

  void execute(SimulationClock clock) {
    final dt = clock.advance();
    final system = universe.current();
    final forceRails = clock.forcesRails;

    // ---- Comms pre-pass: relay-network connectivity per body ----
    // Group vessels by dominant body, then flood link reachability so relays can
    // restore a link for vessels with no direct line to the ground station.
    final commLinks = <String, bool>{};
    final byBody = <String, List<Vessel>>{};
    for (final v in vessels.all()) {
      byBody.putIfAbsent(v.dominantBody.value, () => []).add(v);
    }
    byBody.forEach((bodyId, group) {
      final body = system.require(BodyId(bodyId));
      commLinks.addAll(relayNetwork.computeLinks(group, body));
    });

    // ---- MOTION + per-vessel subsystem phase ----
    // Snapshot the list so destroyed vessels can be removed mid-iteration.
    for (final vessel in vessels.all().toList()) {
      final body = system.require(vessel.dominantBody);

      // 1. SOI transition check — uses real body ephemeris and shifts the
      // vessel state into the new body frame so motion is continuous.
      final transition = soi.resolve(
        state: vessel.state,
        current: body,
        system: system,
        epoch: clock.epoch,
      );
      if (transition != null) {
        vessel.rebaseTo(transition.newBody.id, transition.shiftedState);
      }
      final activeBody = system.require(vessel.dominantBody);

      // 1a. Comms: link state from the relay-network pre-pass (direct line to a
      // ground station, or relayed through another connected vessel).
      vessel.hasCommLink = commLinks[vessel.id.value] ?? true;

      // 1b. Autopilot: execute any due maneuver node BEFORE motion so the burn
      // affects this tick's trajectory.
      autopilot.update(vessel, now: clock.epoch);

      // 2. Environment sampling.
      final altitude = activeBody.altitudeOf(vessel.state.position);
      final inAtmosphere = activeBody.hasAtmosphere &&
          activeBody.atmosphere!.hasAtmosphere(altitude);
      final sample = inAtmosphere
          ? activeBody.atmosphere!.sampleAt(altitude)
          : AtmosphereSample.vacuum;

      // 3. Mode selection. Landed vessels also skip orbital propagation.
      final underThrust = vessel.throttle > 0;
      // LIFTOFF: a landed vessel whose engines are firing un-lands so physics can
      // carry it off the pad. (Until it throttles up it sits — no motion, so no
      // spurious aero/gravity load on a craft just spawned on the surface.)
      if (vessel.landed && underThrust) vessel.landed = false;
      final mode = (!vessel.landed && (forceRails || (!underThrust && !inAtmosphere)))
          ? PropagationMode.onRails
          : PropagationMode.physics;
      vessel.mode = mode;

      // 4. Advance motion (landed vessels stay put).
      if (!vessel.landed) {
        final next = mode == PropagationMode.onRails
            ? _onRails(vessel, activeBody, clock)
            : _physics(vessel, activeBody, sample, inAtmosphere, dt);
        vessel.updateState(next);
      }

      // 4b. Surface contact: a vessel that has descended below the surface
      // either lands (slow) or is destroyed on impact (fast).
      if (_handleSurfaceContact(vessel, activeBody)) {
        _publishEvents(vessel);
        vessels.remove(vessel.id);
        continue; // destroyed — skip subsystems
      }

      // 4c. Structural overstress: exceeding max-Q in atmosphere breaks the ship.
      if (!disableAeroStress &&
          inAtmosphere &&
          structural.check(vessel,
              ambient: sample, maxDynamicPressure: maxDynamicPressure)) {
        _publishEvents(vessel);
        vessels.remove(vessel.id);
        continue;
      }

      // 5. Per-vessel subsystems.
      _vesselSubsystems(vessel, activeBody, sample, inAtmosphere, dt, system, clock);

      // 5b. Destroy any vessel whose part overheated this tick.
      if (!disableOverheat && _overheated(vessel)) {
        _publishEvents(vessel);
        vessels.remove(vessel.id);
        continue;
      }

      // 6. Persist + publish.
      vessels.save(vessel);
      _publishEvents(vessel);
    }

    // ---- Colony / city phase ----
    for (final colony in colonies.all()) {
      // City-scale mining from a deposit on the colony's body, if any.
      for (final deposit in deposits.all()) {
        if (deposit.body == colony.body) {
          cityMining.advance(colony, deposit, dt: dt);
          break;
        }
      }
      // Agriculture: farms grow crops + harvest food (averaged daylight).
      if (colony.farms.isNotEmpty) {
        farming.advance(colony, dt: dt, sunlightFraction: 0.6);
      }
      // Production, services/happiness, then RCI zone growth.
      supplyChain.advance(colony, dt);
      happinessService.update(colony, dt: dt);
      zoneGrowth.grow(colony, dt: dt);
      // A colony's leftover generating capacity can fund megaprojects.
      colony.constructionPowerSurplus =
          (colony.powerOutput - colony.powerDemand).clamp(0.0, double.infinity);
      colonies.save(colony);
    }

    // ---- Megastructure phase: colonies pour mass + surplus power into the
    // endgame builds (Dyson spheres, Halo rings, ...). Glacially slow on
    // purpose — these are the long-game sinks for planetary-scale economies.
    for (final mega in megastructures.all()) {
      // On-site / connected power plants generate energy into the build buffer.
      // (Material must be flown in by cargo craft via deliverToSite — never
      // teleported from a remote colony.)
      if (mega.siteGenerationWatts > 0) {
        mega.deliverEnergy(mega.siteGenerationWatts * dt);
      }
      final milestones = megaConstruction.advance(mega, dt: dt);
      for (final m in milestones) {
        events.publish(MegastructureMilestone(
          mega.id,
          m,
          completed: m.contains('complete') && !m.contains('phase'),
        ));
      }
      megastructures.save(mega);
    }

    // ---- Weather phase: advect + decay cells per body ----
    for (final w in weather.all()) {
      final wBody = system.body(w.body);
      if (wBody == null) continue;
      weather.save(weatherUpdater.advance(w, bodyRadius: wBody.radius, dt: dt));
    }

    // ---- Logistics phase: dispatch due autonomous cargo runs ----
    final dispatched = cargoScheduler.process(cargo.all(), now: clock.epoch);
    for (final id in dispatched) {
      for (final s in cargo.all()) {
        if (s.id == id) cargo.save(s);
      }
    }
  }

  void _vesselSubsystems(
    Vessel vessel,
    CelestialBody body,
    AtmosphereSample sample,
    bool inAtmosphere,
    double dt,
    StarSystem system,
    SimulationClock clock,
  ) {
    // Thermal: solar (gated by eclipse shadow), reentry, radiative cooling.
    if (vessel.thermal.isNotEmpty) {
      final airspeed = inAtmosphere ? vessel.state.velocity.length : 0.0;

      // Sun direction = from the vessel's body toward the system root (star).
      // Body position relative to root, negated, points back to the star.
      final bodyToRoot = ephemeris.positionRelativeToRoot(body, system, clock.epoch);
      final sunDir = body.isStar ? Vector3.unitX : (-bodyToRoot).normalized;
      final lit = eclipse.litFraction(
        bodyCentredPosition: vessel.state.position,
        body: body,
        sunDirection: sunDir,
      );

      thermalUpdater.update(
        vessel,
        dt: dt,
        ambient: sample,
        airspeed: airspeed,
        solarFlux: body.solarFlux,
        // 0.5 geometric factor (half the area faces the sun) gated by eclipse.
        sunFacing: 0.5 * lit,
        // Heavy atmospheres (CO2 on Mars/Venus) heat reentry more than light.
        gasHeatingFactor: body.composition?.reentryHeatingFactor ?? 1.0,
      );
    }

    // Mining: landed vessel over its bound deposit.
    final op = vessel.mining;
    if (op != null && vessel.landed) {
      final deposit = deposits.byId(op.depositId);
      if (deposit != null) {
        miningUpdater.update(vessel, deposit: deposit, dt: dt);
      }
    }

    // ISRU: in-situ converters turn ore/water into fuel/oxygen aboard.
    if (vessel.converters.isNotEmpty) {
      isru.advance(vessel, dt: dt);
    }

    // Docking: chaser closing on a target vessel.
    final approach = vessel.docking;
    if (approach != null && !approach.docked) {
      final target = vessels.byId(approach.target);
      if (target != null) {
        dockingUpdater.update(vessel, target, dt: dt);
      }
    }

    // Attitude control: reaction wheels slew toward the commanded facing.
    attitudeController.update(vessel, dt: dt);

    // Science: auto-collect experiments when entering a new situation.
    experimentRunner.collect(vessel, body, research);

    // Life support: crew consume consumables; lost if a vital resource runs out.
    lifeSupport.update(vessel, dt: dt);

    // Radiation: crewed vessels accumulate dose from cosmic rays, the body's
    // trapped-particle belts, and solar particles (attenuated by shielding).
    if (vessel.crew != null && vessel.crew!.count > 0) {
      final mag = body.dipoleMoment > 0
          ? Magnetosphere(
              dipoleMoment: body.dipoleMoment, bodyRadius: body.radius)
          : null;
      final doseRate = radiationEnvironment.doseRate(
        position: vessel.state.position,
        magnetosphere: mag,
        solarFlux: body.solarFlux,
        shielding: vessel.radiationShielding,
      );
      radiation.apply(vessel, doseRateSv: doseRate, dt: dt);
    }

    // Situation change -> event (drives contracts). Independent of science.
    final situation = situations.classify(vessel, body);
    if (situation != vessel.lastSituation) {
      vessel.lastSituation = situation;
      vessel.raise(SituationEntered(vessel.id, situation));
    }
  }

  /// Speed (m/s) below which a surface touchdown is a safe landing rather than a
  /// destructive impact.
  static const double safeLandingSpeed = 12.0;

  /// Handle a vessel that has descended to/through the surface. Returns true if
  /// the vessel was destroyed (caller removes it). A gentle touchdown lands it
  /// (clamped to the surface, velocity zeroed); a fast one raises [Impact].
  bool _handleSurfaceContact(Vessel vessel, CelestialBody body) {
    if (vessel.landed) return false;
    final altitude = body.altitudeOf(vessel.state.position);
    // Non-finite state (e.g. an unpropagatable hyperbolic conic) is not a
    // surface contact — leave it to the physics path rather than "impacting".
    if (!altitude.isFinite || altitude > 0) return false;

    final speed = vessel.state.velocity.length;

    // Biome-aware touchdown: a water splashdown tolerates a higher speed and
    // quenches reentry heat; ice is firm-but-forgiving; rock/desert is hard.
    final dir = vessel.state.position.length == 0
        ? Vector3.unitX
        : vessel.state.position.normalized;
    var safeSpeed = safeLandingSpeed;
    var quench = 0.0;
    if (body.surface != null) {
      final lat = _asin(dir.z.clamp(-1.0, 1.0));
      final lon = _atan2(dir.y, dir.x);
      final biome = body.surface!.biomeAt(latitude: lat, longitude: lon);
      safeSpeed = splashdown.safeSpeedFor(biome);
      quench = splashdown.heatQuenchFraction(biome);
    }

    // Impact destruction (skipped by the debug cheat — any speed just lands).
    if (!disableImpact && !splashdown.survivesSpeed(speed, safeSpeed)) {
      vessel.raise(Impact(vessel.id, body.id, speed));
      return true; // destroyed
    }

    // Gentle: clamp onto the surface, mark landed, quench heat on water.
    if (quench > 0) {
      for (final t in vessel.thermal) {
        t.temperature = 2.7 + (t.temperature - 2.7) * (1 - quench);
      }
    }
    vessel.updateState(vessel.state.copyWith(
      position: dir * body.radius,
      velocity: Vector3.zero,
    ));
    vessel.landed = true;
    return false;
  }

  /// Drain a vessel's queued events: feed them to the contracts board (if any),
  /// then publish on the bus.
  void _publishEvents(Vessel vessel) {
    final drained = vessel.drainEvents();
    final board = contracts;
    if (board != null) {
      for (final e in drained) {
        final reward = board.process(e);
        if (reward.funds > 0) {
          treasury?.earn(reward.funds, reason: 'contract reward');
        }
        if (reward.science > 0) research.addScience(reward.science);
      }
    }
    events.publishAll(drained);
  }

  /// True if any of the vessel's parts has exceeded its temperature limit.
  bool _overheated(Vessel vessel) {
    for (final t in vessel.thermal) {
      if (t.temperature > t.maxTemperature) return true;
    }
    return false;
  }

  StateVector _onRails(Vessel vessel, CelestialBody body, SimulationClock clock) {
    // clock.advance() has already moved clock.epoch to the END of this tick, but
    // vessel.state is from the START. Anchor the orbit at the start epoch
    // (clock.epoch - simStep) and propagate forward to the current epoch, so the
    // craft advances exactly one warped step. (Anchoring AND evaluating at the
    // same epoch gives zero delta — the craft appears frozen on rails.)
    final startEpoch = clock.epoch - clock.simStep;
    final orbit = converter.toOrbit(
      position: vessel.state.position,
      velocity: vessel.state.velocity,
      body: body,
      epoch: startEpoch,
    );
    final propagated = compute.propagate(orbit, clock.epoch);
    // Hyperbolic/escape conics aren't handled by the elliptical Kepler solver
    // and can produce non-finite output — fall back to keeping the current
    // state (the next physics tick advances it numerically) rather than NaN.
    if (!propagated.position.x.isFinite || !propagated.position.y.isFinite) {
      return vessel.state;
    }
    return propagated.copyWith(
      attitude: vessel.state.attitude,
      angularVelocity: vessel.state.angularVelocity,
    );
  }

  StateVector _physics(
    Vessel vessel,
    CelestialBody body,
    AtmosphereSample sample,
    bool inAtmosphere,
    double dt,
  ) {
    final pressureFraction =
        body.hasAtmosphere && body.atmosphere!.seaLevelPressure > 0
            ? (sample.pressure / body.atmosphere!.seaLevelPressure).clamp(0.0, 1.0)
            : 0.0;

    // Weather wind (surface frame) -> a crude inertial wind vector for aero.
    final wind = _windFor(vessel, body, inAtmosphere);

    final environment = <ForceContributor>[
      GravityForce(body),
      if (inAtmosphere)
        AeroForce(
          atmosphere: sample,
          windVelocity: wind,
          dragCoefficient: _vesselDrag(vessel),
          referenceArea: _vesselArea(vessel),
        ),
      // Wing lift: aircraft with wings get a lift force from angle of attack.
      if (inAtmosphere && vessel.hasWings)
        AeroForce(
          atmosphere: sample,
          windVelocity: wind,
          dragCoefficient: 0, // drag already counted above
          referenceArea: vessel.totalWingArea,
          liftCoefficient: _wingLiftCoefficient(vessel),
        ),
      // Air-breathing jet thrust.
      if (inAtmosphere && vessel.hasJetEngine)
        JetForce(vessel: vessel, atmosphere: sample, dt: dt),
    ];

    final model = vessel.buildForceModel(
      environment,
      pressureFraction: pressureFraction.toDouble(),
      dt: dt,
    );
    return compute.integrate(vessel.state, model, vessel.massProperties, dt);
  }

  /// Wing lift coefficient from the vessel's angle of attack (angle between its
  /// forward axis and its velocity), via the averaged wing lift-curve slope.
  double _wingLiftCoefficient(Vessel vessel) {
    final v = vessel.state.velocity;
    if (v.length < 1e-3) return 0;
    final forward = vessel.state.attitude.rotate(Vector3.unitZ);
    final cosA = (forward.dot(v.normalized)).clamp(-1.0, 1.0);
    final aoa = math.acos(cosA); // 0 = pointing along velocity
    // Small-angle linear region, capped at a stall-like value.
    final clamped = aoa.clamp(-0.30, 0.30);
    return vessel.wingLiftSlope * clamped;
  }

  /// Sample weather wind for the vessel's sub-point. Maps the surface-frame wind
  /// onto the orbital XY plane (Z up) as a first approximation — enough for
  /// storms to push ships; a full impl rotates by the body-fixed frame.
  Vector3 _windFor(Vessel vessel, CelestialBody body, bool inAtmosphere) {
    if (!inAtmosphere) return Vector3.zero;
    final w = weather.forBody(body.id);
    if (w == null) return Vector3.zero;
    final p = vessel.state.position;
    final altitude = body.altitudeOf(p);
    // Crude lat/long from the position direction.
    final dir = p.normalized;
    final lat = _asin(dir.z.clamp(-1.0, 1.0));
    final lon = _atan2(dir.y, dir.x);
    final surfaceWind =
        w.windAt(latitude: lat, longitude: lon, altitude: altitude);
    // Treat (east, north) as (x, y) in the orbital plane.
    return Vector3(surfaceWind.x, surfaceWind.y, 0);
  }

  double _vesselDrag(Vessel vessel) {
    final parts = vessel.allParts.toList();
    if (parts.isEmpty) return 0.2;
    return parts.map((p) => p.dragCoefficient).reduce((a, b) => a + b) /
        parts.length;
  }

  double _vesselArea(Vessel vessel) =>
      vessel.allParts.fold(0.0, (s, p) => s + p.crossSectionArea);

  double _asin(double x) => math.asin(x);
  double _atan2(double y, double x) => math.atan2(y, x);
}
