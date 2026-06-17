import 'dart:math' as math;

import 'package:acro_space_simulator/domain/orbits/state_vector_converter.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const conv = StateVectorOrbitConverter();
  final earth = CelestialBody(
    id: const BodyId('earth'),
    name: 'Earth',
    mu: 3.986e14,
    radius: 6371000,
    soiRadius: 9.24e8,
    siderealRotationPeriod: 86164,
    parent: null,
  );

  test('toOrbit recovers the actual position angle of a CIRCULAR orbit', () {
    final r = earth.radius + 3000000;
    final v = math.sqrt(earth.mu / r);

    // Two craft on the same circular orbit, 90 degrees apart.
    final atZero = conv.toOrbit(
      position: Vector3(r, 0, 0),
      velocity: Vector3(0, v, 0),
      body: earth,
      epoch: Epoch.zero,
    );
    final atNinety = conv.toOrbit(
      position: Vector3(0, r, 0),
      velocity: Vector3(-v, 0, 0),
      body: earth,
      epoch: Epoch.zero,
    );

    // Their mean anomalies must differ by ~90 deg — NOT both be zero (the old
    // bug forced circular orbits to anomaly 0, freezing on-rails craft).
    final diff = (atNinety.elements.meanAnomalyAtEpoch -
            atZero.elements.meanAnomalyAtEpoch)
        .abs();
    expect(diff, closeTo(math.pi / 2, 0.05));
  });

  test('a circular on-rails round-trip advances (does not freeze)', () {
    final r = earth.radius + 3000000;
    final v = math.sqrt(earth.mu / r);
    var pos = Vector3(r, 0, 0);
    var vel = Vector3(0, v, 0);

    double angle(Vector3 p) => math.atan2(p.y, p.x);
    final start = angle(pos);

    // Re-derive the orbit from state each step and propagate forward 200 s —
    // exactly what AdvanceSimulationTick._onRails does on rails.
    const step = 200.0;
    for (var i = 0; i < 5; i++) {
      final orbit = conv.toOrbit(
        position: pos,
        velocity: vel,
        body: earth,
        epoch: Epoch(step * i),
      );
      final next = conv.toStateVector(orbit, Epoch(step * (i + 1)));
      pos = next.position;
      vel = next.velocity;
    }

    final moved = (angle(pos) - start).abs();
    expect(moved, greaterThan(0.05),
        reason: 'circular craft must sweep around its orbit, not stay put');
  });

  // The teleport bug: an EQUATORIAL orbit has a zero node vector, so argP was
  // forced to 0 and periapsis snapped to +X. A vessel at apoapsis (or off-axis)
  // then reconstructed at the wrong spot — a jump of up to AP-PE.
  test('toOrbit/toStateVector round-trips exactly for equatorial orbits', () {
    final r = earth.radius + 1000000;
    final vc = math.sqrt(earth.mu / r);

    void roundTrips(Vector3 pos, Vector3 vel, String label) {
      final orbit = conv.toOrbit(
          position: pos, velocity: vel, body: earth, epoch: const Epoch(123));
      final back = conv.toStateVector(orbit, const Epoch(123));
      expect((back.position - pos).length, lessThan(1.0), reason: label);
    }

    roundTrips(Vector3(r, 0, 0), Vector3(0, vc, 0), 'circular');
    roundTrips(Vector3(r, 0, 0), Vector3(0, vc * 1.05, 0), 'periapsis (raised AP)');
    roundTrips(Vector3(r, 0, 0), Vector3(0, vc * 0.95, 0), 'apoapsis (lowered PE)');
    roundTrips(Vector3(r * 0.7, r * 0.7, 0),
        Vector3(-vc * 0.5, vc * 0.5, 0), 'off-axis eccentric');
  });
}
