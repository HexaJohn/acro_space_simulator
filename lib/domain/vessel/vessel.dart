import 'dart:math' as math;

import '../autonomy/docking_approach.dart';
import '../autonomy/flight_plan.dart';
import '../dynamics/force.dart';
import '../dynamics/force_model.dart';
import '../dynamics/mass_properties.dart';
import '../dynamics/state_vector.dart';
import '../lifesupport/crew.dart';
import '../mining/mining_operation.dart';
import '../parts/jet_engine.dart';
import '../science/experiment.dart';
import '../shared/units.dart';
import '../shared/vector3.dart';
import '../simulation/domain_event.dart';
import '../thermal/thermal_state.dart';
import '../universe/celestial_body.dart';
import 'converter.dart';
import 'part.dart';
import 'stage.dart';

class VesselId {
  final String value;
  const VesselId(this.value);
  @override
  bool operator ==(Object other) => other is VesselId && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => 'VesselId($value)';
}

/// How a vessel is being propagated this tick. On rails = analytic Kepler
/// (cheap, unperturbed); physics = numeric integration (thrust/drag/contact).
enum PropagationMode { onRails, physics }

/// Aggregate root for a spacecraft. Owns its stages/parts, its 6-DOF state, and
/// its control inputs. ALL mutation of parts/resources/staging goes through
/// here so invariants hold:
///   * total mass == sum of active parts (recomputed, never stored stale)
///   * throttle in [0,1]
///   * a separated stage's parts leave the vessel atomically
///
/// Emits [DomainEvent]s (staging, etc.) for the application layer to publish.
class Vessel {
  final VesselId id;
  String name;

  /// Player/AI that owns this vessel (multiplayer ownership + command auth).
  String ownerId;

  StateVector state;
  BodyId dominantBody;
  PropagationMode mode;

  /// True when sitting on a surface (enables mining, disables orbital physics
  /// drift). Set by the surface-contact check in the tick.
  bool landed;

  /// Per-part thermal states, keyed by part. Owned by the vessel aggregate so
  /// the subsystem tick can heat/cool parts and destroy overheated ones.
  final List<PartThermalState> thermal;

  /// Active mining operation, if this vessel is a miner sitting on a deposit.
  MiningOperation? mining;

  /// In-situ resource converters (ISRU) aboard — ore->fuel, water->oxygen, etc.
  final List<Converter> converters = [];

  /// Autonomous flight plan, if this vessel is AI-flown. Executed by the
  /// autopilot updater during the subsystem phase.
  FlightPlan? flightPlan;

  /// Active docking approach, if this vessel is closing on a target port.
  DockingApproach? docking;

  /// Desired forward (+Z body) axis in the inertial frame. The attitude
  /// controller (reaction wheels) rotates the vessel toward it. Null = hold.
  Vector3? targetFacing;

  /// Science experiments this vessel carries.
  final List<Experiment> experiments = [];

  /// The last situation string an experiment was collected in (so re-running in
  /// the same place is suppressed). Null = nothing collected yet.
  String? lastScienceSituation;

  /// Whether the vessel currently has a control signal (set each tick by the
  /// comms check). During a blackout an autonomous vessel can't act on new
  /// commands. Defaults true (in contact).
  bool hasCommLink = true;

  /// Crew aboard, if any. The life-support service draws their consumables.
  CrewModule? crew;

  /// Baked aircraft aero properties (set by the VesselAssembler). Total wing
  /// planform area (m^2), total intake air available, and the air-breathing
  /// engines aboard. Lift-curve slope is averaged across the wings.
  double totalWingArea = 0;
  double totalIntakeArea = 0;
  double wingLiftSlope = 5.5;
  final List<JetEngine> jetEngines = [];

  bool get hasJetEngine => jetEngines.isNotEmpty;
  bool get hasWings => totalWingArea > 0;

  /// Radiation shielding fraction 0..1 from onboard mass (more structural mass =
  /// more attenuation). Heat shields with ablator count double. Crude but gives
  /// heavier/shielded craft a survivability edge; saturates toward ~0.95.
  double get radiationShielding {
    var shieldMass = 0.0;
    for (final t in thermal) {
      if (t.ablator > 0) shieldMass += t.heatCapacity / 800; // ~part mass
    }
    // 5 tonnes of shielding ~ 0.5 attenuation; saturating curve.
    final s = shieldMass / (shieldMass + 5000);
    return s.clamp(0.0, 0.95);
  }

  /// Last flight situation the tick observed (drives SituationEntered events for
  /// contracts). Distinct from [lastScienceSituation], which gates experiments.
  String? lastSituation;

  double _throttle = 0;
  final List<Stage> _stages;
  final List<DomainEvent> _pendingEvents = [];

  Vessel({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.state,
    required this.dominantBody,
    required List<Stage> stages,
    this.mode = PropagationMode.physics,
    this.landed = false,
    List<PartThermalState>? thermal,
  })  : _stages = stages,
        thermal = thermal ?? const [];

  /// Raise a domain event from outside the aggregate's own methods (used by the
  /// subsystem tick when a part overheats or contact occurs).
  void raise(DomainEvent event) => _pendingEvents.add(event);

  PartThermalState? thermalOf(PartId part) {
    for (final t in thermal) {
      if (t.part == part) return t;
    }
    return null;
  }

  double get throttle => _throttle;
  List<Stage> get stages => List.unmodifiable(_stages);
  Iterable<Part> get allParts => _stages.expand((s) => s.parts);

  /// Invariant-backed: mass is always the live sum of current parts.
  MassProperties get massProperties => _stages.fold(
        MassProperties.zero,
        (acc, s) => acc + s.massProperties,
      );

  double get mass => massProperties.mass;

  /// The active (last) stage whose engines can fire.
  Stage? get activeStage => _stages.isEmpty ? null : _stages.last;

  /// Remaining delta-v capacity of the active stage (m/s), via the Tsiolkovsky
  /// rocket equation dv = Isp * g0 * ln(m0 / mf), where m0 is current total mass
  /// and mf removes the active stage's usable propellant. Uses vacuum Isp.
  double deltaVCapacity() {
    final stage = activeStage;
    if (stage == null) return 0;
    final engine = stage.engines.isEmpty ? null : stage.engines.first.engine;
    if (engine == null) return 0;

    final m0 = mass;
    final propellantMass = stage.parts.fold(0.0, (s, p) {
      return s + p.resources.fold(0.0, (r, c) => r + c.mass);
    });
    final mf = m0 - propellantMass;
    if (mf <= 0 || m0 <= mf) return 0;
    return engine.ispVacuum * standardGravity * math.log(m0 / mf);
  }

  void setThrottle(double t) => _throttle = t.clamp(0.0, 1.0);

  void updateState(StateVector s) => state = s;

  /// Switch dominant body on a SOI transition; the caller has already rebased
  /// [state] into the new body's frame.
  void rebaseTo(BodyId body, StateVector stateInNewFrame) {
    final from = dominantBody;
    dominantBody = body;
    state = stateInNewFrame;
    _pendingEvents.add(SoiTransition(id, from, body));
  }

  /// Drop the active stage; its parts and mass leave the vessel atomically.
  /// No-op (returns false) if nothing to separate.
  bool separateStage() {
    if (_stages.length <= 1) return false;
    final dropped = _stages.removeLast();
    _pendingEvents.add(StageSeparation(id, dropped.index));
    return true;
  }

  /// Thrust contributor for the force model, given ambient pressure fraction
  /// (1 = sea level, 0 = vacuum) and integration [dt] for propellant draw.
  /// Returns null when there's no thrust this tick (no active engine / zero
  /// throttle / dry tanks) so the force model can skip it.
  ForceContributor? thrustContributor({
    required double pressureFraction,
    required double dt,
  }) {
    final stage = activeStage;
    if (stage == null || _throttle <= 0) return null;
    return _ThrustForce(
      vessel: this,
      stage: stage,
      throttle: _throttle,
      pressureFraction: pressureFraction,
      dt: dt,
    );
  }

  /// Build the force model for this tick from a gravity contributor plus
  /// thrust (and later: aero, etc. injected by the application tick).
  ForceModel buildForceModel(
    List<ForceContributor> environmentForces, {
    required double pressureFraction,
    required double dt,
  }) {
    final thrust = thrustContributor(pressureFraction: pressureFraction, dt: dt);
    return ForceModel([
      ...environmentForces,
      ?thrust,
    ]);
  }

  /// Drain and return queued domain events (application publishes them).
  List<DomainEvent> drainEvents() {
    final out = List<DomainEvent>.of(_pendingEvents);
    _pendingEvents.clear();
    return out;
  }
}

/// Thrust force: sums active-engine thrust along the vessel's facing and draws
/// propellant. Lives with the aggregate because it mutates resource state.
class _ThrustForce implements ForceContributor {
  final Vessel vessel;
  final Stage stage;
  final double throttle;
  final double pressureFraction;
  final double dt;

  _ThrustForce({
    required this.vessel,
    required this.stage,
    required this.throttle,
    required this.pressureFraction,
    required this.dt,
  });

  @override
  GeneralizedForce evaluate(StateVector stateVec, MassProperties mass) {
    var totalThrust = 0.0;
    for (final p in stage.engines) {
      final eng = p.engine!;
      final container = stage.parts
          .map((q) => q.containerFor(eng.propellant))
          .firstWhere((c) => c != null, orElse: () => null);
      if (container == null) continue; // dry: this engine can't fire

      final thrust = eng.thrustAt(pressureFraction, throttle);
      final isp = eng.ispAt(pressureFraction);
      final flow = eng.massFlow(thrust, isp); // kg/s
      final drawnMass = container.draw(flow * dt / container.unitMass);
      if (drawnMass <= 0) continue;
      totalThrust += thrust;
    }
    if (totalThrust == 0) return GeneralizedForce.zero;

    // Nominal thrust is along the vessel's forward (+Z body) axis, in inertial.
    final forward = stateVec.attitude.rotate(Vector3.unitZ);

    // Engine gimbal: if the active engine can vector and a facing is commanded,
    // deflect thrust toward it. The off-axis component yields a steering torque.
    final gimbalRange = stage.engines
        .map((p) => p.engine!.gimbalRange)
        .fold(0.0, (a, b) => a > b ? a : b);
    final steer = vessel.targetFacing;
    if (gimbalRange > 0 && steer != null) {
      final eng = stage.engines.first.engine!;
      final dir = eng.gimballedDirection(
        thrustAxis: forward,
        steerToward: steer.normalized,
      );
      final force = dir * totalThrust;
      // Torque ~ deflection of thrust from the forward axis (small-angle), about
      // the axis perpendicular to both. Scaled by a moment-arm factor.
      const momentArm = 1.0; // m, nominal engine offset from CoM
      final torque = forward.cross(dir) * (totalThrust * momentArm);
      return GeneralizedForce(force, torque);
    }

    return GeneralizedForce(forward * totalThrust, Vector3.zero);
  }
}
