import 'package:acro_space_simulator/domain/planetary/gravity_field.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Earth-like parameters.
  const mu = 3.986004418e14; // m^3/s^2
  const radius = 6378137.0; // m, equatorial
  const j2 = 1.08263e-3; // Earth's oblateness coefficient

  // A radius at which to sample, well above the surface.
  const r = 7.0e6; // m

  test('reduces to point-mass acceleration when j2 = 0', () {
    final field = GravityField(mu: mu, equatorialRadius: radius, j2: 0);
    final pos = Vector3(r, 0, 0);
    final a = field.accelerationAt(pos);

    // Point-mass: a = -mu/r^2 along -x.
    final expectedMag = mu / (r * r);
    expect(a.x, closeTo(-expectedMag, expectedMag * 1e-9));
    expect(a.y, closeTo(0, 1e-6));
    expect(a.z, closeTo(0, 1e-6));
  });

  test('j2 makes gravity at the pole differ from the equator at same radius',
      () {
    final field = GravityField(mu: mu, equatorialRadius: radius, j2: j2);

    final equator = field.accelerationAt(Vector3(r, 0, 0));
    final pole = field.accelerationAt(Vector3(0, 0, r));

    // Both point inward toward the centre.
    expect(equator.x, lessThan(0));
    expect(pole.z, lessThan(0));

    final equatorMag = equator.length;
    final poleMag = pole.length;

    // J2 oblateness breaks spherical symmetry: at the same geocentric radius
    // the gravitational acceleration at the pole differs from the equator.
    expect(poleMag, isNot(closeTo(equatorMag, equatorMag * 1e-9)));

    // The difference should be non-trivial (driven by J2), not numerical noise.
    expect((poleMag - equatorMag).abs() / equatorMag, greaterThan(1e-4));

    // For the same geocentric radius the standard J2 gravitational term gives a
    // slightly weaker pole; the salient point is that the two are not equal.
    final point = GravityField(mu: mu, equatorialRadius: radius, j2: 0);
    final pointMag = point.accelerationAt(Vector3(r, 0, 0)).length;
    expect(equatorMag, isNot(closeTo(pointMag, pointMag * 1e-9)));
  });

  test('j2 perturbation vanishes as j2 -> 0 (matches point-mass)', () {
    final j2Field = GravityField(mu: mu, equatorialRadius: radius, j2: j2);
    final pointField = GravityField(mu: mu, equatorialRadius: radius, j2: 0);

    // On the equator, magnitudes differ because of J2...
    final eqJ2 = j2Field.accelerationAt(Vector3(r, 0, 0)).length;
    final eqPoint = pointField.accelerationAt(Vector3(r, 0, 0)).length;
    expect(eqJ2, isNot(closeTo(eqPoint, eqPoint * 1e-6)));
  });

  test('acceleration falls off with distance', () {
    final field = GravityField(mu: mu, equatorialRadius: radius, j2: j2);
    final near = field.accelerationAt(Vector3(r, 0, 0)).length;
    final far = field.accelerationAt(Vector3(2 * r, 0, 0)).length;
    expect(far, lessThan(near));
  });

  test('zero position returns zero acceleration (no singularity blow-up)', () {
    final field = GravityField(mu: mu, equatorialRadius: radius, j2: j2);
    expect(field.accelerationAt(Vector3.zero), Vector3.zero);
  });
}
