// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What it costs to move one kilogram from one world's surface to another's
/// (docs/plans/factory-floors.md §3 "Prices are local and derived").
///
/// The import ceiling on every off-world price is "Earth price + transport",
/// so transport decides which goods a colony makes for itself. It is derived
/// from physics, not tabulated:
///
/// 1. **Δv** from the bodies' real data (`RealSolarSystem`): ascent to a low
///    orbit (orbital speed + gravity and drag losses), a Hohmann transfer
///    between the two orbits about their common parent (with the Oberth
///    effect from low orbit), capture and descent at the far end (an
///    atmosphere aerobrakes most of it away — why Mars is as reachable as
///    the Moon).
/// 2. **The rocket equation** at an era Isp turns Δv into propellant per kg
///    of payload, stage by stage, with a structural fraction. The launcher
///    lifts the interplanetary ship and ALL of its propellant out of the
///    source well, which is why Earth's ascent dominates every Earth export.
/// 3. **Credits**: propellant at the source's price, plus the vehicles' dry
///    mass amortised over their life (a Mars ship is tied up for a whole
///    synodic period per trip), plus flight operations.
///
/// The constants describe a MATURE REUSABLE methalox fleet (~2040s): fully
/// reusable launchers and ships, orbital refuelling, all propellant from the
/// source world. That era lands cargo on Mars for a few hundred credits/kg
/// — the ballpark today's fully-reusable plans aim at, versus ~$1M/kg for
/// the robotic landers of the 2020s.
///
/// Pure arithmetic over immutable body data; results are cached per
/// (from, to) and are fully deterministic.
library;

import 'dart:math' as math;

import '../../../universe/celestial_body.dart';
import '../../../universe/real_solar_system.dart';
import '../../../universe/star_system.dart';
import 'earth_market.dart';
import 'economy_contracts.dart';

/// Specific impulse of the era's engines, s: methalox full-flow staged
/// combustion, ~330 s at sea level to ~380 s in vacuum; 350 is the
/// trajectory-weighted mean.
const double kEraIspS = 350;

/// Standard gravity, m/s², for Isp → exhaust velocity.
const double kG0 = 9.80665;

/// Stage dry mass per kg of the propellant it carries. A reusable booster
/// runs ~0.07, a reusable ship with heat shield and legs ~0.12; 0.1 is the
/// fleet mean.
const double kStructuralFraction = 0.1;

/// The most a single stage may be asked for: s·(R − 1) below this, or the
/// leg is split into more stages. At 1 a stage could lift only itself.
const double kMaxStageLoad = 0.8;

/// The most stages any one vehicle gets; past this a leg is unflyable
/// (a gas giant's "surface").
const int kMaxStages = 6;

/// Low orbit altitude as a share of the body's radius (Earth: ~190 km),
/// raised to clear the atmosphere where one exists.
const double kLowOrbitAltFrac = 0.03;

/// Gravity loss on ascent as a share of orbital speed (Earth ~0.9-1.2 km/s
/// on ~7.8 km/s; the Moon ~0.2 km/s on 1.7).
const double kGravityLossFrac = 0.12;

/// Drag loss climbing out of Earth's sea-level air, m/s; scales with the
/// square root of surface pressure (dense air is crossed slower).
const double kDragLossEarthMps = 300;

/// Cap on drag loss, m/s, so a Venus-class atmosphere stays finite.
const double kMaxDragLossMps = 3000;

/// Aerobraking strength: the share of an arrival burn an atmosphere leaves
/// to the engines is 1 / (1 + k·√(P/P_earth)). k = 30 leaves ~3% at Earth
/// (a ~0.3 km/s landing burn) and ~30% at Mars' 0.6 kPa (~1 km/s, the
/// supersonic-retropropulsion figure for heavy Mars landers).
const double kAeroBrakeK = 30;

/// Hover and divert margin on every landing, m/s.
const double kLandingMarginMps = 100;

/// Earth's sea-level pressure, Pa — the reference for drag and aerobraking.
const double kEarthSurfacePa = 101325;

/// Vehicle hardware cost per kg of dry mass, credits: a mature, mass-
/// produced reusable launcher or ship (~$100-150M for ~100-150 t dry).
const double kVehicleCostPerDryKg = 1000;

/// Flights a reusable vehicle is good for before it is retired.
const int kVehicleLifeFlights = 100;

/// Calendar life of a vehicle, days (20 years). A ship that spends a whole
/// synodic period on each Mars round trip wears out on the calendar long
/// before it reaches its flight count.
const double kVehicleLifeDays = 20 * 365.25;

/// Days a surface-to-orbit launcher is tied up per flight (launch, land,
/// refurbish, stack).
const double kShuttleTurnaroundDays = 2;

/// Flight operations per kg of payload per vehicle flight, credits: range,
/// recovery, refurbishment and ground crew (~$3M a flight for 150 t).
const double kFlightOpsPerKg = 20;

/// Seconds in a day, for transfer times.
const double _kDayS = 86400;

/// The physics of one route, for tests and the UI's "why this price".
class TransportRoute {
  const TransportRoute({
    required this.fromBodyId,
    required this.toBodyId,
    required this.ascentDv,
    required this.transferDv,
    required this.arrivalDv,
    required this.missionDays,
    required this.propellantKgPerKg,
    required this.dryKgPerKg,
    required this.propellantCost,
    required this.vehicleCost,
    required this.opsCost,
  });

  final String fromBodyId;
  final String toBodyId;

  /// m/s: surface → low orbit at the source.
  final double ascentDv;

  /// m/s: low orbit → the destination's sphere, all the way out (departure
  /// burn plus any climb out of a moon's parent).
  final double transferDv;

  /// m/s: capture and descent at the destination, after aerobraking.
  final double arrivalDv;

  /// Days the interplanetary ship is tied up per trip.
  final double missionDays;

  /// Propellant burned, and vehicle dry mass flown, per kg delivered.
  final double propellantKgPerKg;
  final double dryKgPerKg;

  /// Credits per kg delivered, by cause.
  final double propellantCost;
  final double vehicleCost;
  final double opsCost;

  double get totalDv => ascentDv + transferDv + arrivalDv;
  double get perKg => propellantCost + vehicleCost + opsCost;
  bool get flyable => perKg.isFinite;

  static TransportRoute none(String from, String to) => TransportRoute(
      fromBodyId: from, toBodyId: to, ascentDv: 0, transferDv: 0,
      arrivalDv: 0, missionDays: 0, propellantKgPerKg: 0, dryKgPerKg: 0,
      propellantCost: 0, vehicleCost: 0, opsCost: 0);

  static TransportRoute unflyable(String from, String to) => TransportRoute(
      fromBodyId: from, toBodyId: to, ascentDv: double.infinity,
      transferDv: 0, arrivalDv: 0, missionDays: 0,
      propellantKgPerKg: double.infinity, dryKgPerKg: double.infinity,
      propellantCost: double.infinity, vehicleCost: 0, opsCost: 0);
}

/// One vehicle's staging: propellant and dry mass per kg of its payload.
class _Staging {
  const _Staging(this.gross, this.propellant, this.dry);
  final double gross; // lift-off mass per kg payload (payload included)
  final double propellant;
  final double dry;
  static const _Staging nothing = _Staging(1, 0, 0);
  static const _Staging unflyable =
      _Staging(double.infinity, double.infinity, double.infinity);
}

/// Surface-to-surface cost per kg from Δv and the rocket equation.
class DeltaVTransportModel implements TransportCostModel {
  /// [system] defaults to the real Solar System. [propellantPricePerKg]
  /// overrides the propellant price at a source body (a Martian ISRU depot);
  /// any body not listed buys at Earth's methalox price.
  DeltaVTransportModel({
    StarSystem? system,
    Map<String, double> propellantPricePerKg = const {},
  })  : _system = system ?? _realSystem,
        _propellant = Map.unmodifiable(propellantPricePerKg);

  static final StarSystem _realSystem = RealSolarSystem.build();

  final StarSystem _system;
  final Map<String, double> _propellant;
  final Map<String, TransportRoute> _cache = {};

  @override
  double perKg(String fromBodyId, String toBodyId) =>
      route(fromBodyId, toBodyId).perKg;

  /// The full breakdown of a route, cached.
  TransportRoute route(String fromBodyId, String toBodyId) =>
      _cache['$fromBodyId>$toBodyId'] ??= _solve(fromBodyId, toBodyId);

  double _propellantPrice(String body) =>
      _propellant[body] ?? earthPropellantPerKg();

  TransportRoute _solve(String fromId, String toId) {
    if (fromId == toId) return TransportRoute.none(fromId, toId);
    final a = _system.body(BodyId(fromId));
    final b = _system.body(BodyId(toId));
    if (a == null || b == null || a.isStar || b.isStar) {
      return TransportRoute.unflyable(fromId, toId);
    }

    final ascent = _ascentDv(a);
    final trip = _transfer(a, b);
    final arrival = trip.arrival + _descentDv(b);

    // The ship flies transfer + capture + descent; the launcher lifts the
    // fuelled ship out of the source well.
    final ship = _stage(trip.departure + arrival);
    final launcher = _stage(ascent);
    if (ship.gross.isInfinite || launcher.gross.isInfinite) {
      return TransportRoute.unflyable(fromId, toId);
    }
    final propellant = ship.propellant + ship.gross * launcher.propellant;
    final launcherDry = ship.gross * launcher.dry;
    double amortised(double days) =>
        math.max(days / kVehicleLifeDays, 1 / kVehicleLifeFlights);
    final vehicle = kVehicleCostPerDryKg *
        (ship.dry * amortised(trip.missionDays) +
            launcherDry * amortised(kShuttleTurnaroundDays));
    final ops = kFlightOpsPerKg * (1 + (ascent > 0 ? ship.gross : 0));
    return TransportRoute(
      fromBodyId: fromId,
      toBodyId: toId,
      ascentDv: ascent,
      transferDv: trip.departure,
      arrivalDv: arrival,
      missionDays: trip.missionDays,
      propellantKgPerKg: propellant,
      dryKgPerKg: ship.dry + launcherDry,
      propellantCost: propellant * _propellantPrice(fromId),
      vehicleCost: vehicle,
      opsCost: ops,
    );
  }

  // ---- Δv pieces --------------------------------------------------------

  static double _surfacePa(CelestialBody b) =>
      b.atmosphere?.seaLevelPressure ?? 0;

  static double _lowOrbit(CelestialBody b) =>
      b.radius +
      math.max(kLowOrbitAltFrac * b.radius, b.atmosphere?.atmosphereHeight ?? 0);

  static double _vCirc(double mu, double r) => math.sqrt(mu / r);

  /// Share of an arrival burn the air leaves to the engines.
  static double _aeroResidual(CelestialBody b) =>
      1 / (1 + kAeroBrakeK * math.sqrt(_surfacePa(b) / kEarthSurfacePa));

  static double _ascentDv(CelestialBody b) {
    final v = _vCirc(b.mu, _lowOrbit(b));
    final drag = math.min(kMaxDragLossMps,
        kDragLossEarthMps * math.sqrt(_surfacePa(b) / kEarthSurfacePa));
    return v * (1 + kGravityLossFrac) + drag;
  }

  static double _descentDv(CelestialBody b) {
    final v = _vCirc(b.mu, _lowOrbit(b));
    return v * (1 + kGravityLossFrac) * _aeroResidual(b) + kLandingMarginMps;
  }

  /// Burn from a low orbit about [b] to leave with excess speed [vInf]
  /// (Oberth: the burn is made deep in the well).
  static double _oberth(CelestialBody b, double vInf) {
    final r = _lowOrbit(b);
    return math.sqrt(vInf * vInf + 2 * b.mu / r) - _vCirc(b.mu, r);
  }

  /// Burn to climb from rest relative to [child] (in its orbit about its
  /// parent, at [rOrbit] about [mu]) to escape that parent: v_esc − v_circ.
  static double _climb(double mu, double rOrbit) =>
      _vCirc(mu, rOrbit) * (math.sqrt2 - 1);

  /// Hohmann time between radii [r1], [r2] about [mu], s.
  static double _hohmannS(double mu, double r1, double r2) {
    final a = (r1 + r2) / 2;
    return math.pi * math.sqrt(a * a * a / mu);
  }

  static double _periodS(double mu, double a) =>
      2 * math.pi * math.sqrt(a * a * a / mu);

  List<CelestialBody> _chain(CelestialBody b) {
    final out = <CelestialBody>[b];
    var p = _system.parentOf(b);
    while (p != null) {
      out.add(p);
      p = _system.parentOf(p);
    }
    return out;
  }

  /// Escape from [b]'s low orbit all the way out of [top] (an ancestor of
  /// [b], or [b] itself): the climb out of [b], then out of each parent up
  /// to and including [top], from the orbit of the child below it.
  double _climbOut(List<CelestialBody> chain, CelestialBody top) {
    var dv = _climb(chain.first.mu, _lowOrbit(chain.first));
    for (var i = 1; i < chain.length && chain[i - 1] != top; i++) {
      dv += _climb(chain[i].mu, chain[i - 1].orbitRadius);
    }
    return dv;
  }

  /// Departure (low orbit at [a] → on the way) and arrival (excess speed at
  /// [b] → low orbit at [b], aerobraked) burns, plus the ship's mission time.
  ({double departure, double arrival, double missionDays}) _transfer(
      CelestialBody a, CelestialBody b) {
    final ca = _chain(a), cb = _chain(b);
    final c = ca.firstWhere(cb.contains); // lowest common ancestor
    final ia = ca.indexOf(c), ib = cb.indexOf(c);
    final aTop = ia > 0 ? ca[ia - 1] : null; // child of c on a's side
    final bTop = ib > 0 ? cb[ib - 1] : null;
    final mu = c.mu;

    // Leaving a moon, the ship climbs out of the moon and its parent, then
    // burns the excess with no Oberth help (conservative). Arriving at a
    // moon, it aerocaptures in the parent's air where there is one (Earth),
    // then climbs down to the moon.
    double depart(double vInf) => aTop == a
        ? _oberth(a, vInf)
        : _climbOut(ca, aTop!) + vInf;
    double arrive(double vInf) => bTop == b
        ? _oberth(b, vInf) * _aeroResidual(b)
        : _climbOut(cb, bTop!) + vInf * _aeroResidual(bTop);

    if (aTop != null && bTop != null) {
      // Siblings about c: a Hohmann between their orbits.
      final r1 = aTop.orbitRadius, r2 = bTop.orbitRadius;
      final vInf1 = (_vCirc(mu, r1) * (math.sqrt(2 * r2 / (r1 + r2)) - 1)).abs();
      final vInf2 = (_vCirc(mu, r2) * (1 - math.sqrt(2 * r1 / (r1 + r2)))).abs();
      final t1 = _periodS(mu, r1), t2 = _periodS(mu, r2);
      final synodic = (t1 - t2).abs() < 1 ? double.infinity
          : 1 / (1 / t1 - 1 / t2).abs();
      final busy = math.min(synodic, kVehicleLifeDays * _kDayS);
      return (
        departure: depart(vInf1),
        arrival: arrive(vInf2),
        missionDays: math.max(2 * _hohmannS(mu, r1, r2), busy) / _kDayS +
            kShuttleTurnaroundDays,
      );
    }
    if (aTop == null) {
      // b orbits (somewhere below) a: from a's low orbit out to bTop.
      final r1 = _lowOrbit(a), r2 = bTop!.orbitRadius;
      final burn = _vCirc(mu, r1) * (math.sqrt(2 * r2 / (r1 + r2)) - 1);
      final vApo = _vCirc(mu, r2) * math.sqrt(2 * r1 / (r1 + r2));
      return (
        departure: burn,
        arrival: arrive((_vCirc(mu, r2) - vApo).abs()),
        missionDays: 2 * _hohmannS(mu, r1, r2) / _kDayS +
            kShuttleTurnaroundDays,
      );
    }
    // a orbits (somewhere below) b: from aTop down to b's low orbit.
    final r1 = aTop.orbitRadius, r2 = _lowOrbit(b);
    final vApo = _vCirc(mu, r1) * math.sqrt(2 * r2 / (r1 + r2));
    final vPeri = _vCirc(mu, r2) * math.sqrt(2 * r1 / (r1 + r2));
    return (
      departure: depart((_vCirc(mu, r1) - vApo).abs()),
      arrival: (vPeri - _vCirc(mu, r2)) * _aeroResidual(b),
      missionDays: 2 * _hohmannS(mu, r1, r2) / _kDayS + kShuttleTurnaroundDays,
    );
  }

  // ---- rocket equation --------------------------------------------------

  /// Fewest equal stages that fly [dv]; propellant, dry and lift-off mass per
  /// kg of payload.
  static _Staging _stage(double dv) {
    if (dv <= 0) return _Staging.nothing;
    const ve = kEraIspS * kG0;
    for (var n = 1; n <= kMaxStages; n++) {
      final r = math.exp(dv / n / ve);
      final load = kStructuralFraction * (r - 1);
      if (load > kMaxStageLoad) continue;
      final propPerPayload = (r - 1) / (1 - load);
      var mass = 1.0, prop = 0.0, dry = 0.0;
      for (var i = 0; i < n; i++) {
        final p = propPerPayload * mass;
        prop += p;
        dry += kStructuralFraction * p;
        mass += p * (1 + kStructuralFraction);
      }
      return _Staging(mass, prop, dry);
    }
    return _Staging.unflyable;
  }
}
