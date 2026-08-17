// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/autonomy/flight_plan.dart';
import 'package:acro_space_simulator/domain/orbits/encounter_planner.dart';
import 'package:acro_space_simulator/domain/orbits/patched_conic_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/star_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Same Kerbin/Mun-like system as the patched-conic tests: circular
  // equatorial moon at 12,000 km, so transfer timing is exact.
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
  const service = EncounterPlannerService();

  double circSpeed(double mu, double r) => math.sqrt(mu / r);

  test('zero delta-v: post-burn orbit matches the current orbit', () {
    const r = 700000.0;
    final plan = service.plan(
      position: const Vector3(r, 0, 0),
      velocity: Vector3(0, circSpeed(planet.mu, r), 0),
      body: planet,
      system: system,
      epoch: Epoch.zero,
      node: const ManeuverNode(executeAt: Epoch(600), deltaV: Vector3.zero),
      targetBody: moon.id,
    );
    expect(plan, isNotNull);
    expect(plan!.postOrbit.elements.semiMajorAxis, closeTo(r, r * 0.001));
    expect(plan.postOrbit.elements.eccentricity, lessThan(0.01));
    expect(plan.patches.first.end, PatchEndKind.closed);
    // Equatorial prograde orbit: plane normal is +Z.
    expect(plan.planeNormal.z, closeTo(1.0, 1e-6));
    // The moon never comes closer than its orbit radius minus ours.
    final ca = plan.closeApproach;
    expect(ca, isNotNull);
    expect(ca!.distanceMeters,
        closeTo(moon.orbitRadius - r, (moon.orbitRadius - r) * 0.02));
    // Coplanar orbits: no relative inclination, no AN/DN line.
    expect(plan.relativeInclination, closeTo(0, 0.01));
    expect(plan.nodeLineDirection, isNull);
  });

  test('a burn scheduled in the past clamps to now', () {
    const r = 700000.0;
    final plan = service.plan(
      position: const Vector3(r, 0, 0),
      velocity: Vector3(0, circSpeed(planet.mu, r), 0),
      body: planet,
      system: system,
      epoch: const Epoch(5000),
      node: const ManeuverNode(executeAt: Epoch(1000), deltaV: Vector3.zero),
    );
    expect(plan, isNotNull);
    expect(plan!.node.executeAt.seconds, 5000);
  });

  test('delayed burn point lies on the current conic', () {
    const r = 700000.0;
    final v = circSpeed(planet.mu, r);
    final n = v / r; // circular angular rate
    const tBurn = 1000.0;
    final plan = service.plan(
      position: const Vector3(r, 0, 0),
      velocity: Vector3(0, v, 0),
      body: planet,
      system: system,
      epoch: Epoch.zero,
      node: const ManeuverNode(
          executeAt: Epoch(tBurn), deltaV: Vector3.zero),
    );
    expect(plan, isNotNull);
    expect(plan!.burnPosition.length, closeTo(r, r * 0.001));
    final expected =
        Vector3(r * math.cos(n * tBurn), r * math.sin(n * tBurn), 0);
    expect((plan.burnPosition - expected).length, lessThan(r * 0.01));
  });

  test('prograde Hohmann burn finds the moon encounter', () {
    // Phase the moon so it arrives at the transfer apoapsis with the craft
    // (same construction as the patched-conic transfer test), but here the
    // craft starts CIRCULAR and the PLANNER applies the burn.
    const r0 = 700000.0;
    final rMoon = moon.orbitRadius;
    final a = (r0 + rMoon) / 2;
    final vCirc = circSpeed(planet.mu, r0);
    final vPeri = math.sqrt(planet.mu * (2 / r0 - 1 / a));
    final tTransfer = math.pi * math.sqrt(a * a * a / planet.mu);
    final nMoon = math.sqrt(planet.mu / (rMoon * rMoon * rMoon));
    final phasedMoon = CelestialBody(
      id: moon.id,
      name: moon.name,
      mu: moon.mu,
      radius: moon.radius,
      soiRadius: moon.soiRadius,
      siderealRotationPeriod: moon.siderealRotationPeriod,
      parent: moon.parent,
      orbitRadius: moon.orbitRadius,
      orbitPhase: math.pi - nMoon * tTransfer,
    );
    final phasedSystem = StarSystem(
      name: 'Test',
      rootStar: planet.id,
      bodies: [planet, phasedMoon],
    );

    final plan = service.plan(
      position: const Vector3(r0, 0, 0),
      velocity: Vector3(0, vCirc, 0),
      body: planet,
      system: phasedSystem,
      epoch: Epoch.zero,
      node: ManeuverNode(
        executeAt: Epoch.zero,
        deltaV: Vector3(vPeri - vCirc, 0, 0), // pure prograde
      ),
      targetBody: moon.id,
    );

    expect(plan, isNotNull);
    expect(plan!.postOrbit.apoapsis, closeTo(rMoon, rMoon * 0.01));
    expect(plan.encounterBody, moon.id,
        reason: 'the planned trajectory must enter the moon SOI');
    // Closest approach comes from the moon-frame leg: inside the SOI.
    final ca = plan.closeApproach;
    expect(ca, isNotNull);
    expect(ca!.distanceMeters, lessThan(moon.soiRadius));
    expect(ca.frameBody, planet.id);
  });

  test('rendezvous target: closest approach matches the phase offset', () {
    // Two craft on the same circular orbit, target 2 degrees ahead: the
    // separation is constant, so the closest approach IS the chord distance.
    const r = 700000.0;
    final v = circSpeed(planet.mu, r);
    const phase = 2 * math.pi / 180;
    final target = TargetCraftState(
      position: Vector3(r * math.cos(phase), r * math.sin(phase), 0),
      velocity: Vector3(-v * math.sin(phase), v * math.cos(phase), 0),
      body: planet.id,
    );
    final plan = service.plan(
      position: const Vector3(r, 0, 0),
      velocity: Vector3(0, v, 0),
      body: planet,
      system: system,
      epoch: Epoch.zero,
      node: const ManeuverNode(executeAt: Epoch(60), deltaV: Vector3.zero),
      targetCraft: target,
    );
    expect(plan, isNotNull);
    final chord = 2 * r * math.sin(phase / 2);
    expect(plan!.closeApproach, isNotNull);
    expect(plan.closeApproach!.distanceMeters, closeTo(chord, chord * 0.05));
    expect(plan.relativeInclination, closeTo(0, 0.01));
  });

  test('inclined plan against the equatorial moon: rel inc + node line', () {
    // Polar orbit (plane normal along +Y-ish) vs the equatorial moon.
    const r = 700000.0;
    final v = circSpeed(planet.mu, r);
    final plan = service.plan(
      position: const Vector3(r, 0, 0),
      velocity: Vector3(0, 0, v), // climbs over the pole
      body: planet,
      system: system,
      epoch: Epoch.zero,
      node: const ManeuverNode(executeAt: Epoch(60), deltaV: Vector3.zero),
      targetBody: moon.id,
    );
    expect(plan, isNotNull);
    expect(plan!.relativeInclination, isNotNull);
    expect(plan.relativeInclination!, closeTo(math.pi / 2, 0.02));
    final line = plan.nodeLineDirection;
    expect(line, isNotNull, reason: 'non-coplanar planes must yield a node line');
    // The AN/DN line is perpendicular to both plane normals.
    expect(line!.dot(plan.planeNormal).abs(), lessThan(1e-6));
    expect(line.z.abs(), lessThan(1e-6)); // lies in the moon's (equatorial) plane
  });
}
