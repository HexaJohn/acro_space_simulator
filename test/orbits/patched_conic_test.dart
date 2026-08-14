// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/orbits/body_ephemeris.dart';
import 'package:acro_space_simulator/domain/orbits/patched_conic_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/star_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Kerbin/Mun-like two-body system (same numbers as the SOI transition tests):
  // circular equatorial moon at 12,000 km, so encounter timing is exact.
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
    orbitRadius: 12000000,
    orbitPhase: 0,
  );
  final system = StarSystem(
    name: 'Test',
    rootStar: const BodyId('planet'),
    bodies: [planet, moon],
  );
  const ephemeris = BodyEphemeris();
  const service = PatchedConicService();

  double circSpeed(double mu, double r) => math.sqrt(mu / r);

  test('low circular orbit: one closed patch, no transition', () {
    const r = 700000.0;
    final patches = service.predict(
      position: const Vector3(r, 0, 0),
      velocity: Vector3(0, circSpeed(planet.mu, r), 0),
      body: planet,
      system: system,
      epoch: Epoch.zero,
    );
    expect(patches, hasLength(1));
    expect(patches.first.end, PatchEndKind.closed);
    expect(patches.first.body, planet.id);
    // The ring closes on itself and stays near the circular radius.
    for (final p in patches.first.points) {
      expect(p.length, closeTo(r, r * 0.01));
    }
  });

  test('suborbital lob: single patch ending at the surface', () {
    // Straight up at well below escape speed -> falls back and hits.
    final patches = service.predict(
      position: const Vector3(700000, 0, 0),
      velocity: const Vector3(800, 0, 0),
      body: planet,
      system: system,
      epoch: Epoch.zero,
    );
    expect(patches, hasLength(1));
    expect(patches.first.end, PatchEndKind.impact);
    // The last sample sits at (or just above) the surface radius.
    expect(patches.first.points.last.length,
        closeTo(planet.radius, planet.radius * 0.02));
  });

  test('hyperbolic escape from the root: single horizon-bounded patch', () {
    // Well above escape speed from low orbit. The root planet has no parent,
    // so — exactly like the live SOI service — there is no frame to hand off
    // to: the trajectory stays in the root frame and the display leg is
    // bounded by the prediction horizon.
    const r = 700000.0;
    final vEsc = math.sqrt(2 * planet.mu / r);
    final patches = service.predict(
      position: const Vector3(r, 0, 0),
      velocity: Vector3(0, vEsc * 1.3, 0),
      body: planet,
      system: system,
      epoch: Epoch.zero,
    );
    expect(patches, hasLength(1));
    expect(patches.first.body, planet.id);
    expect(patches.first.end, PatchEndKind.horizon);
    // Monotonically outbound, every sample finite.
    final pts = patches.first.points;
    expect(pts.length, greaterThan(10));
    for (var i = 1; i < pts.length; i++) {
      expect(pts[i].length, greaterThan(pts[i - 1].length));
    }
  });

  test('transfer to the moon: encounter patch in the moon frame', () {
    // Hohmann-style transfer from 700 km circular, apoapsis at the moon's
    // orbit radius, phased so the moon arrives at apoapsis when we do.
    const r0 = 700000.0;
    final rMoon = moon.orbitRadius;
    final a = (r0 + rMoon) / 2;
    // Vis-viva at periapsis of the transfer ellipse.
    final vPeri = math.sqrt(planet.mu * (2 / r0 - 1 / a));
    final tTransfer = math.pi * math.sqrt(a * a * a / planet.mu);
    // Moon angular position at arrival must be the craft's apoapsis (pi rad
    // from launch at +X): phase the moon so n_moon * tTransfer ends at pi.
    final nMoon = math.sqrt(planet.mu / (rMoon * rMoon * rMoon));
    final moonAtLaunch = math.pi - nMoon * tTransfer;
    final phasedMoon = CelestialBody(
      id: moon.id,
      name: moon.name,
      mu: moon.mu,
      radius: moon.radius,
      soiRadius: moon.soiRadius,
      siderealRotationPeriod: moon.siderealRotationPeriod,
      parent: moon.parent,
      orbitRadius: moon.orbitRadius,
      orbitPhase: moonAtLaunch,
    );
    final phasedSystem = StarSystem(
      name: 'Test',
      rootStar: planet.id,
      bodies: [planet, phasedMoon],
    );

    final patches = service.predict(
      position: const Vector3(r0, 0, 0),
      velocity: Vector3(0, vPeri, 0),
      body: planet,
      system: phasedSystem,
      epoch: Epoch.zero,
    );

    expect(patches.length, greaterThanOrEqualTo(2),
        reason: 'transfer must produce a handoff into the moon frame');
    expect(patches[0].end, PatchEndKind.encounter);
    expect(patches[0].nextBody, moon.id);
    expect(patches[1].body, moon.id);
    // Continuity: the first point of the moon-frame patch, lifted back to the
    // planet frame at the handoff epoch, matches the last point of patch 0.
    final tX = patches[0].endSeconds;
    final moonAtX = ephemeris.positionRelativeToParent(
        phasedMoon, phasedSystem, Epoch(tX));
    final joinPlanetFrame = moonAtX + patches[1].points.first;
    final gap = (joinPlanetFrame - patches[0].points.last).length;
    expect(gap, lessThan(moon.soiRadius * 0.05),
        reason: 'frames must join at the SOI boundary');
    // The handoff happens at the moon SOI edge.
    expect(patches[1].points.first.length,
        closeTo(moon.soiRadius, moon.soiRadius * 0.02));
  });

  test('escape from the moon: continuation patch in the planet frame', () {
    // Start in a low moon orbit with enough speed to leave the moon SOI.
    const rm = 300000.0;
    final vEscMoon = math.sqrt(2 * moon.mu / rm);
    final patches = service.predict(
      position: const Vector3(rm, 0, 0),
      velocity: Vector3(0, vEscMoon * 1.2, 0),
      body: moon,
      system: system,
      epoch: Epoch.zero,
    );
    expect(patches.length, greaterThanOrEqualTo(2));
    expect(patches[0].end, PatchEndKind.escape);
    expect(patches[0].nextBody, planet.id);
    expect(patches[1].body, planet.id);
    // Patch 0 ends at the moon's SOI edge.
    expect(patches[0].points.last.length,
        closeTo(moon.soiRadius, moon.soiRadius * 0.02));
    // The planet-frame continuation starts near the moon's orbit radius.
    expect(patches[1].points.first.length,
        closeTo(moon.orbitRadius, moon.soiRadius * 2));
  });
}
