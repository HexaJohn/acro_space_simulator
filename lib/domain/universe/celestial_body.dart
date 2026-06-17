import 'dart:math' as math;

import '../planetary/atmospheric_composition.dart';
import '../planetary/planet_surface.dart';
import '../shared/vector3.dart';
import 'atmosphere_model.dart';

class BodyId {
  final String value;
  const BodyId(this.value);

  @override
  bool operator ==(Object other) => other is BodyId && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => 'BodyId($value)';
}

/// A celestial body (star, planet, moon). Aggregate root for the Universe
/// context, but effectively immutable reference data — its orbit about its
/// parent is on perfect rails.
///
/// Gravity is point-mass (two-body) per KSP's patched-conic model: a vessel
/// feels exactly one body at a time, whichever sphere of influence it is in.
class CelestialBody {
  final BodyId id;
  final String name;

  /// Standard gravitational parameter mu = G*M (m^3/s^2). Stored directly
  /// because it is known far more precisely than G and M separately.
  final double mu;

  final double radius; // m, equatorial
  final double soiRadius; // m, sphere of influence (infinite for the root star)
  final double siderealRotationPeriod; // s

  /// Parent body this one orbits; null for the system's root (the star).
  final BodyId? parent;

  /// Semi-major axis of the orbit about the parent. For a circular orbit this
  /// equals the orbit radius; named [orbitRadius] for backward compatibility.
  final double orbitRadius;
  final double orbitPhase; // mean anomaly at epoch 0, rad

  /// Orbital shape/orientation about the parent. Defaults are a circular,
  /// equatorial orbit (e=0, i=0) — identical to the previous circular model, so
  /// existing bodies need no changes.
  final double orbitEccentricity; // e
  final double orbitInclination; // i, rad
  final double orbitLongitudeAscending; // RAAN, rad
  final double orbitArgPeriapsis; // omega, rad

  final AtmosphereModel? atmosphere;

  /// Mean solar irradiance at this body's distance, W/m^2 (for thermal/solar).
  final double solarFlux;

  // ---- Planetary science (Universe-Sandbox-style) ----

  /// Axial tilt / obliquity (rad), drives seasons via the subsolar latitude.
  final double axialTilt;

  /// J2 zonal harmonic (oblateness). 0 = perfect sphere (point-mass gravity).
  final double j2;

  /// Magnetic dipole moment (A*m^2). 0 = no magnetosphere.
  final double dipoleMoment;

  /// Surface science: biome map, ore distribution, temperature map.
  final PlanetSurface? surface;

  /// Atmospheric gas composition (mole fractions, mean molecular weight).
  final AtmosphericComposition? composition;

  const CelestialBody({
    required this.id,
    required this.name,
    required this.mu,
    required this.radius,
    required this.soiRadius,
    required this.siderealRotationPeriod,
    required this.parent,
    this.orbitRadius = 0,
    this.orbitPhase = 0,
    this.orbitEccentricity = 0,
    this.orbitInclination = 0,
    this.orbitLongitudeAscending = 0,
    this.orbitArgPeriapsis = 0,
    this.atmosphere,
    this.solarFlux = 0,
    this.axialTilt = 0,
    this.j2 = 0,
    this.dipoleMoment = 0,
    this.surface,
    this.composition,
  });

  /// Returns a copy with selected fields replaced. Used by debug/terraforming
  /// tools that re-skin a body's atmosphere (its composition + air model) at
  /// runtime to show the render react to a chemistry change.
  CelestialBody copyWith({
    AtmosphereModel? atmosphere,
    AtmosphericComposition? composition,
  }) =>
      CelestialBody(
        id: id,
        name: name,
        mu: mu,
        radius: radius,
        soiRadius: soiRadius,
        siderealRotationPeriod: siderealRotationPeriod,
        parent: parent,
        orbitRadius: orbitRadius,
        orbitPhase: orbitPhase,
        orbitEccentricity: orbitEccentricity,
        orbitInclination: orbitInclination,
        orbitLongitudeAscending: orbitLongitudeAscending,
        orbitArgPeriapsis: orbitArgPeriapsis,
        atmosphere: atmosphere ?? this.atmosphere,
        solarFlux: solarFlux,
        axialTilt: axialTilt,
        j2: j2,
        dipoleMoment: dipoleMoment,
        surface: surface,
        composition: composition ?? this.composition,
      );

  bool get isStar => parent == null;
  bool get hasAtmosphere => atmosphere != null;

  /// Mean bulk density (kg/m^3) from mu (=> mass) and radius. ~5500 for rocky
  /// worlds, ~1000-1600 for the gas/ice giants.
  double get bulkDensity {
    const g = 6.674e-11;
    final mass = mu / g;
    final volume = (4 / 3) * math.pi * radius * radius * radius;
    return volume > 0 ? mass / volume : 0;
  }

  /// A gas/ice giant: big + low density => no solid surface to land on. Such
  /// bodies only host floating (cloud-city) or orbital colonies.
  bool get isGasGiant => radius > 2.0e7 && bulkDensity < 2500;

  /// Gravitational acceleration at body-centred position [r] (m, inertial).
  /// a = -mu * r / |r|^3.
  Vector3 gravityAt(Vector3 r) {
    final d2 = r.lengthSquared;
    if (d2 == 0) return Vector3.zero;
    final d = math.sqrt(d2);
    return r * (-mu / (d2 * d));
  }

  /// Altitude above the surface for a body-centred position.
  double altitudeOf(Vector3 r) => r.length - radius;

  /// Surface rotation rate, rad/s, about the body's spin axis (+Z).
  double get angularVelocity =>
      siderealRotationPeriod == 0 ? 0 : 2 * math.pi / siderealRotationPeriod;
}
