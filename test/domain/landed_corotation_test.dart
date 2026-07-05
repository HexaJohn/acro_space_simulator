import 'dart:math' as math;

import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:flutter_test/flutter_test.dart';

/// A landed craft co-rotates about the body's TRUE inertial spin axis. On a
/// tilted body that axis is tilt·(+Z), not a bare +Z — rotating about +Z leaves
/// a residual about an equatorial axis that slides the craft in latitude (N/S).
/// These tests pin the fix: co-rotation about [spinAxisInertial] keeps a landed
/// craft locked to its body-fixed surface point.
void main() {
  CelestialBody tilted(double tilt) => CelestialBody(
        id: const BodyId('t'),
        name: 'T',
        mu: 4.9e12,
        radius: 1.7374e6,
        soiRadius: 6.6e7,
        siderealRotationPeriod: 2.36e5, // fast enough to move a lot per tick
        parent: const BodyId('earth'),
        axialTilt: tilt,
      );

  test('spinAxisInertial is tilt·(+Z): unit, correct for known tilts', () {
    final b = tilted(0.4); // ~23 deg
    final a = b.spinAxisInertial;
    expect(a.length, closeTo(1.0, 1e-12));
    // Rotating +Z about +X by tilt -> (0, -sin, cos).
    expect(a.x, closeTo(0.0, 1e-12));
    expect(a.y, closeTo(-math.sin(0.4), 1e-9));
    expect(a.z, closeTo(math.cos(0.4), 1e-9));
    // Zero tilt collapses to bare +Z.
    expect(tilted(0).spinAxisInertial.z, closeTo(1.0, 1e-12));
  });

  test('co-rotation about the tilted axis PINS a landed craft to its body point',
      () {
    final b = tilted(0.4091); // Earth-like obliquity
    final omega = b.angularVelocity;
    // A surface point fixed in the BODY frame (some lat/lon), at datum radius.
    final pBody = Vector3(0.3, -0.6, 0.74).normalized * b.radius;

    // Its inertial position now and one tick later (terrain-fixed truth).
    const dt = 900.0; // s
    final inertial0 = b.orientationAt(Epoch.zero).rotate(pBody);
    final inertial1 = b.orientationAt(const Epoch(dt)).rotate(pBody);

    // The sim's co-rotation step applied to inertial0.
    final spinQ = Quaternion.axisAngle(b.spinAxisInertial, omega * dt);
    final corotated = spinQ.rotate(inertial0);

    // Exactly tracks the body-fixed point (to numeric precision).
    expect((corotated - inertial1).length, lessThan(1.0)); // < 1 m of ~1.7e6 m

    // And the body-fixed coordinates are invariant -> no lat/lon drift.
    final bfStart = b.orientationAt(Epoch.zero).conjugate.rotate(inertial0);
    final bfEnd = b.orientationAt(const Epoch(dt)).conjugate.rotate(corotated);
    expect((bfEnd - bfStart).length, lessThan(1.0));
  });

  test('the OLD bare-+Z co-rotation drifts a tilted craft in latitude', () {
    // Documents the bug: rotating about +Z (not the tilted axis) changes the
    // body-fixed latitude, i.e. the craft slides N/S.
    final b = tilted(0.4091);
    final omega = b.angularVelocity;
    final pBody = Vector3(0.3, -0.6, 0.74).normalized * b.radius;

    const dt = 900.0;
    final inertial0 = b.orientationAt(Epoch.zero).rotate(pBody);
    final bareZ = Quaternion.axisAngle(Vector3.unitZ, omega * dt).rotate(inertial0);

    // Body-fixed latitude (asin(z/r)) before vs after the WRONG rotation.
    double latOf(Vector3 inertial, Epoch e) {
      final bf = b.orientationAt(e).conjugate.rotate(inertial);
      return math.asin((bf.z / bf.length).clamp(-1.0, 1.0));
    }

    final latStart = latOf(inertial0, Epoch.zero);
    final latDrifted = latOf(bareZ, const Epoch(dt));
    expect((latDrifted - latStart).abs(), greaterThan(1e-4)); // real N/S drift
  });

  test('surfaceVelocityAt is Ω×r: perpendicular to spin axis and to r', () {
    final b = tilted(0.3);
    final r = Vector3(1.2e6, -0.5e6, 0.8e6);
    final v = b.surfaceVelocityAt(r);
    expect(v.dot(b.spinAxisInertial), closeTo(0.0, 1e-3));
    expect(v.dot(r), closeTo(0.0, 1e-3));
    // A non-spinning body imparts no surface velocity.
    final still = CelestialBody(
      id: const BodyId('s'),
      name: 'S',
      mu: 4.9e12,
      radius: 1e6,
      soiRadius: 6e7,
      siderealRotationPeriod: 0,
      parent: const BodyId('earth'),
    );
    expect(still.surfaceVelocityAt(r).length, 0.0);
  });
}
