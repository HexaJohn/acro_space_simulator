import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/orbits/body_ephemeris.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/star_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
  const service = SoiTransitionService(ephemeris);

  test('no transition when deep inside the current SOI', () {
    final state = const StateVector(
      position: Vector3(700000, 0, 0), // low planet orbit
      velocity: Vector3(0, 2200, 0),
    );
    final result = service.resolve(
      state: state,
      current: planet,
      system: system,
      epoch: Epoch.zero,
    );
    expect(result, isNull);
  });

  test('entering the moon SOI shifts state into the moon-centred frame', () {
    // Vessel placed right at the moon's position (well inside its SOI).
    final moonPos = ephemeris.positionRelativeToParent(moon, system, Epoch.zero);
    final moonVel = ephemeris.velocityRelativeToParent(moon, system, Epoch.zero);
    // 100 km above the moon, moving with it plus a bit.
    final state = StateVector(
      position: moonPos + const Vector3(300000, 0, 0),
      velocity: moonVel + const Vector3(0, 100, 0),
    );

    final result = service.resolve(
      state: state,
      current: planet,
      system: system,
      epoch: Epoch.zero,
    );

    expect(result, isNotNull);
    expect(result!.newBody.id, const BodyId('moon'));
    // In the moon frame the vessel should be ~300 km out, not ~12,000 km.
    expect(result.shiftedState.position.length, closeTo(300000, 1));
    // Relative velocity is what we added on top of the moon's velocity.
    expect(result.shiftedState.velocity.length, closeTo(100, 1e-3));
  });

  test('escaping the moon SOI shifts state back to the planet frame', () {
    // Vessel just outside the moon SOI, in the moon frame.
    final state = StateVector(
      position: Vector3(moon.soiRadius + 1000, 0, 0),
      velocity: const Vector3(0, 50, 0),
    );
    final result = service.resolve(
      state: state,
      current: moon,
      system: system,
      epoch: Epoch.zero,
    );

    expect(result, isNotNull);
    expect(result!.newBody.id, const BodyId('planet'));
    // Back in the planet frame the vessel is near the moon's orbit radius.
    expect(result.shiftedState.position.length, closeTo(moon.orbitRadius, moon.soiRadius * 2));
  });
}
