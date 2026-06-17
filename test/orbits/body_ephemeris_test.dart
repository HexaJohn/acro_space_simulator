import 'dart:math' as math;

import 'package:acro_space_simulator/domain/orbits/body_ephemeris.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/star_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Planet at origin; a moon on a circular orbit around it.
  final planet = CelestialBody(
    id: const BodyId('planet'),
    name: 'Planet',
    mu: 3.5316e12,
    radius: 600000,
    soiRadius: 84159286,
    siderealRotationPeriod: 21549,
    parent: null,
  );
  final moon = CelestialBody(
    id: const BodyId('moon'),
    name: 'Moon',
    mu: 6.5138e10,
    radius: 200000,
    soiRadius: 2429559,
    siderealRotationPeriod: 138984,
    parent: const BodyId('planet'),
    orbitRadius: 12000000, // 12,000 km
    orbitPhase: 0,
  );
  final system = StarSystem(
    name: 'Test',
    rootStar: const BodyId('planet'),
    bodies: [planet, moon],
  );
  const ephemeris = BodyEphemeris();

  test('root body is at the origin in its own frame', () {
    final p = ephemeris.positionRelativeToParent(planet, system, Epoch.zero);
    expect(p.length, 0);
  });

  test('moon sits at its orbit radius from the planet at epoch 0', () {
    final p = ephemeris.positionRelativeToParent(moon, system, Epoch.zero);
    expect(p.length, closeTo(moon.orbitRadius, 1));
  });

  test('moon moves along its orbit over time (position changes, radius holds)',
      () {
    final p0 = ephemeris.positionRelativeToParent(moon, system, Epoch.zero);
    // Quarter of the moon's orbital period.
    final parentMu = planet.mu;
    final period = 2 * math.pi * math.sqrt(math.pow(moon.orbitRadius, 3) / parentMu);
    final p1 = ephemeris.positionRelativeToParent(moon, system, Epoch(period / 4));

    expect((p1 - p0).length, greaterThan(1000)); // it moved
    expect(p1.length, closeTo(moon.orbitRadius, moon.orbitRadius * 1e-6)); // circular
  });

  test('velocity is perpendicular to position for a circular orbit', () {
    final r = ephemeris.positionRelativeToParent(moon, system, Epoch.zero);
    final v = ephemeris.velocityRelativeToParent(moon, system, Epoch.zero);
    // r . v ~ 0 for circular motion.
    expect(r.dot(v).abs() / (r.length * v.length), lessThan(1e-3));
  });

  group('orbit path (rails)', () {
    test('root body has no orbit path', () {
      expect(ephemeris.orbitPathRelativeToParent(planet, system), isEmpty);
    });

    test('moon path is a closed ring at the orbit radius', () {
      final pts = ephemeris.orbitPathRelativeToParent(moon, system, samples: 64);
      expect(pts.length, 65); // samples + 1 (closing point)
      // Every sample sits on the (circular) orbit radius.
      for (final p in pts) {
        expect(p.length, closeTo(moon.orbitRadius, moon.orbitRadius * 1e-3));
      }
      // The ring closes: last point == first.
      expect((pts.last - pts.first).length,
          lessThan(moon.orbitRadius * 1e-3));
    });

    test('rail vertex 0 sits exactly on the body at the given epoch', () {
      final period = 2 *
          math.pi *
          math.sqrt(moon.orbitRadius * moon.orbitRadius * moon.orbitRadius /
              planet.mu);
      final epoch = Epoch(period * 0.3); // somewhere mid-orbit
      final bodyPos =
          ephemeris.positionRelativeToParent(moon, system, epoch);
      final pts = ephemeris
          .orbitPathRelativeToParent(moon, system, samples: 64, epoch: epoch);
      // First rail point coincides with the body's actual position, so the rail
      // passes through the marker instead of floating off.
      expect((pts.first - bodyPos).length,
          lessThan(moon.orbitRadius * 1e-3));
    });
  });
}
