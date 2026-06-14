import 'dart:math' as math;

import 'package:acro_space_simulator/domain/orbits/body_ephemeris.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/star_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const ephemeris = BodyEphemeris();
  final planet = CelestialBody(
    id: const BodyId('planet'),
    name: 'Planet',
    mu: 3.5316e12,
    radius: 600000,
    soiRadius: 84159286,
    siderealRotationPeriod: 21549,
    parent: null,
  );

  StarSystem systemWith(CelestialBody moon) => StarSystem(
        name: 'T',
        rootStar: const BodyId('planet'),
        bodies: [planet, moon],
      );

  test('eccentric orbit: periapsis distance < apoapsis distance', () {
    final moon = CelestialBody(
      id: const BodyId('moon'),
      name: 'Moon',
      mu: 6.5e10,
      radius: 200000,
      soiRadius: 2.4e6,
      siderealRotationPeriod: 1,
      parent: const BodyId('planet'),
      orbitRadius: 12000000, // semi-major axis
      orbitEccentricity: 0.5,
      orbitPhase: 0, // mean anomaly 0 => at periapsis
    );
    final sys = systemWith(moon);
    final a = moon.orbitRadius;
    final e = moon.orbitEccentricity;

    // At M=0 (periapsis): r = a(1-e).
    final peri = ephemeris.positionRelativeToParent(moon, sys, Epoch.zero);
    expect(peri.length, closeTo(a * (1 - e), a * 1e-3));

    // Half a period later (M=pi, apoapsis): r = a(1+e).
    final period = 2 * math.pi * math.sqrt(a * a * a / planet.mu);
    final apo =
        ephemeris.positionRelativeToParent(moon, sys, Epoch(period / 2));
    expect(apo.length, closeTo(a * (1 + e), a * 1e-2));
  });

  test('inclined orbit produces an out-of-plane (z) component', () {
    final moon = CelestialBody(
      id: const BodyId('moon'),
      name: 'Moon',
      mu: 6.5e10,
      radius: 200000,
      soiRadius: 2.4e6,
      siderealRotationPeriod: 1,
      parent: const BodyId('planet'),
      orbitRadius: 12000000,
      orbitInclination: 0.5, // ~28.6 deg
      orbitArgPeriapsis: math.pi / 2, // push the body up out of plane
    );
    final sys = systemWith(moon);
    final p = ephemeris.positionRelativeToParent(moon, sys, Epoch.zero);
    expect(p.z.abs(), greaterThan(1000));
  });

  test('circular equatorial orbit still matches the simple model', () {
    final moon = CelestialBody(
      id: const BodyId('moon'),
      name: 'Moon',
      mu: 6.5e10,
      radius: 200000,
      soiRadius: 2.4e6,
      siderealRotationPeriod: 1,
      parent: const BodyId('planet'),
      orbitRadius: 12000000, // e=0, i=0 defaults
    );
    final sys = systemWith(moon);
    final p = ephemeris.positionRelativeToParent(moon, sys, Epoch.zero);
    expect(p.length, closeTo(12000000, 1));
    expect(p.z.abs(), lessThan(1)); // in-plane
  });
}
