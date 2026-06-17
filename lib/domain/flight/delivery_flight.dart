import 'dart:math' as math;

import '../shared/vector3.dart';

/// Phases of an autonomous delivery flight's round trip.
enum DeliveryPhase {
  /// Climbing from the pad to orbit (powered, gravity-turn autopilot).
  ascent,

  /// Coasting in orbit while it "loads" cargo (timed).
  orbitCoast,

  /// De-orbiting + powered descent back down toward the pad.
  descent,

  /// Settled on the pad, unloading (the payload drops here).
  unload,

  /// Finished — the cargo is delivered, the flight can be retired.
  done,
}

/// A HEADLESS, auto-piloted delivery flight. It runs the SAME body-relative
/// gravity + thrust physics the interactive ascent/descent screens use, but with
/// a built-in guidance law (no player input): a gravity turn to orbit, a timed
/// coast, then a retro-burn descent onto its pad. The colony advances it each
/// tick and renders it climbing / coasting / falling on the map.
///
/// Pure domain: no Flutter/IO. Motion is in the body's X-Y plane (Z = spin
/// axis); the pad sits at angle 0 (+X). Distances in metres, time in seconds.
class DeliveryFlight {
  final double mu; // gravitational parameter (m^3/s^2)
  final double bodyRadius; // m
  final double dryMass; // kg
  final double maxThrust; // N
  final double exhaustVelocity; // m/s (Isp * g0)
  final double targetOrbitAlt; // m — parking-orbit altitude to reach
  final double loadSeconds; // orbit coast time (loading cargo)
  final double unloadSeconds; // pad dwell after touchdown

  Vector3 pos; // body-centred (m)
  Vector3 vel; // body-centred (m/s)
  double fuel; // kg
  DeliveryPhase phase;
  double _phaseTime = 0; // seconds in the current phase

  DeliveryFlight({
    required this.mu,
    required this.bodyRadius,
    required this.dryMass,
    required this.maxThrust,
    required this.exhaustVelocity,
    required this.targetOrbitAlt,
    required this.fuel,
    this.loadSeconds = 20,
    this.unloadSeconds = 30,
    this.phase = DeliveryPhase.ascent,
  })  : pos = Vector3(bodyRadius, 0, 0),
        vel = Vector3.zero;

  /// An INBOUND delivery: starts in a parking orbit (loaded with cargo) and
  /// descends to the pad. After unloading it climbs back to orbit + finishes.
  factory DeliveryFlight.inbound({
    required double mu,
    required double bodyRadius,
    required double dryMass,
    required double maxThrust,
    required double exhaustVelocity,
    required double targetOrbitAlt,
    required double fuel,
    double loadSeconds = 20,
    double unloadSeconds = 30,
  }) {
    final f = DeliveryFlight(
      mu: mu,
      bodyRadius: bodyRadius,
      dryMass: dryMass,
      maxThrust: maxThrust,
      exhaustVelocity: exhaustVelocity,
      targetOrbitAlt: targetOrbitAlt,
      fuel: fuel,
      loadSeconds: loadSeconds,
      unloadSeconds: unloadSeconds,
      phase: DeliveryPhase.descent,
    );
    // Begin in a circular parking orbit, a quarter-turn downrange of the pad,
    // moving prograde so the descent arcs in toward the pad at angle 0.
    final r = bodyRadius + targetOrbitAlt;
    f.pos = Vector3(0, r, 0); // 90° downrange (+Y)
    final orbV = math.sqrt(mu / r);
    f.vel = Vector3(-orbV, 0, 0); // prograde toward -X (back toward the pad)
    return f;
  }

  double get mass => dryMass + fuel;
  double get altitude => pos.length - bodyRadius;
  double get speed => vel.length;

  /// Downrange angle (rad) from the pad (+X), used to project to the map.
  double get downrange => math.atan2(pos.y, pos.x);

  double _orbitalSpeed(double alt) => math.sqrt(mu / (bodyRadius + alt));

  /// Vertical (radial) speed component.
  double get _vVert => vel.dot(pos.normalized);

  /// Advance one step. Runs the phase autopilot + integrates the physics.
  void advance(double dt) {
    _phaseTime += dt;
    switch (phase) {
      case DeliveryPhase.ascent:
        _ascentStep(dt); // empty return climb; orbit reached -> done
      case DeliveryPhase.orbitCoast:
        _coastStep(dt);
        if (_phaseTime >= loadSeconds) _enter(DeliveryPhase.descent);
      case DeliveryPhase.descent:
        _descentStep(dt); // arrives -> touchdown -> unload
      case DeliveryPhase.unload:
        if (_phaseTime >= unloadSeconds) _enter(DeliveryPhase.ascent);
      case DeliveryPhase.done:
        break;
    }
  }

  void _enter(DeliveryPhase p) {
    phase = p;
    _phaseTime = 0;
  }

  // --- Guidance: a simple gravity turn. Thrust radial-out low, pitch toward the
  //     horizon (prograde-ish) as it climbs, to build orbital speed. ---
  Vector3 _ascentThrustDir() {
    final up = pos.normalized;
    final east = Vector3(-up.y, up.x, 0).normalized; // prograde horizontal
    // Pitch program: straight up at the pad, leaning east as altitude builds.
    final t = (altitude / targetOrbitAlt).clamp(0.0, 1.0);
    final pitch = math.pi / 2 * (1 - t * 0.92); // 90° -> ~7° above horizon
    return (up * math.sin(pitch) + east * math.cos(pitch)).normalized;
  }

  void _gravityStep(double dt, Vector3 thrustDir, double throttle) {
    final r = pos.length;
    final g = pos.normalized * (-mu / (r * r));
    var a = g;
    if (throttle > 0 && fuel > 0) {
      final thrustN = maxThrust * throttle;
      a = a + thrustDir * (thrustN / mass);
      fuel = math.max(0, fuel - thrustN / exhaustVelocity * dt);
    }
    vel = vel + a * dt;
    pos = pos + vel * dt;
  }

  void _ascentStep(double dt) {
    _gravityStep(dt, _ascentThrustDir(), fuel > 0 ? 1.0 : 0.0);
    // Reached a circular-ish parking orbit? (apoapsis high + moving fast enough).
    final orbV = _orbitalSpeed(targetOrbitAlt);
    if (altitude >= targetOrbitAlt * 0.95 && _vHorizontal >= orbV * 0.98) {
      // Reached orbit on the empty RETURN leg -> the delivery run is complete.
      _circularise();
      _enter(DeliveryPhase.done);
    } else if (altitude >= targetOrbitAlt * 1.2 || (fuel <= 0 && _vVert < 0)) {
      // Safety: high enough (or out of fuel) -> consider the return finished so
      // the flight always retires and frees its pad.
      _enter(DeliveryPhase.done);
    }
  }

  double get _vHorizontal =>
      math.sqrt(math.max(0, speed * speed - _vVert * _vVert));

  void _circularise() {
    final up = pos.normalized;
    final east = Vector3(-up.y, up.x, 0).normalized;
    final orbV = _orbitalSpeed(altitude);
    vel = east * orbV; // pure horizontal at orbital speed
  }

  void _coastStep(double dt) {
    _gravityStep(dt, Vector3.unitX, 0); // unpowered coast
  }

  // --- Descent: retro-burn to kill speed + lower toward the pad, then a final
  //     hover/touchdown. A proportional controller throttles to arrest the fall.
  void _descentStep(double dt) {
    final up = pos.normalized;
    final down = -up;
    final alt = altitude;
    if (alt <= 1.0) {
      // Touchdown.
      pos = up * bodyRadius;
      vel = Vector3.zero;
      _enter(DeliveryPhase.unload);
      return;
    }
    // High up: retro-burn against velocity to shed orbital speed + descend.
    // Low down: throttle to keep the descent gentle (suicide-burn-ish guidance).
    final vDown = -_vVert; // positive = descending
    // Desired descent rate scales with altitude (slow near the ground).
    final desired = (2 + alt * 0.02).clamp(2.0, 120.0);
    Vector3 dir;
    double throttle;
    if (alt > targetOrbitAlt * 0.3 && speed > _orbitalSpeed(alt) * 0.5) {
      // Still fast/high: burn retrograde to drop out of orbit.
      dir = vel.length > 1 ? -vel.normalized : down;
      throttle = 1.0;
    } else {
      // Final descent: burn down-velocity is too high -> thrust up to slow.
      dir = up;
      throttle = vDown > desired ? 1.0 : (vDown > desired * 0.6 ? 0.4 : 0.0);
    }
    _gravityStep(dt, dir, fuel > 0 ? throttle : 0.0);
  }
}
