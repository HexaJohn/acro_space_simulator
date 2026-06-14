import 'package:acro_space_simulator/domain/planetary/magnetosphere.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Earth-like dipole: moment ~8e22 A*m^2, radius ~6.37e6 m.
  const radius = 6.371e6; // m
  const dipoleMoment = 8.0e22; // A*m^2

  final mag = Magnetosphere(
    dipoleMoment: dipoleMoment,
    bodyRadius: radius,
  );

  test('field strength weakens with distance (~1/r^3)', () {
    final near = mag.fieldStrengthAt(Vector3(0, 0, 2 * radius));
    final far = mag.fieldStrengthAt(Vector3(0, 0, 4 * radius));
    expect(near, greaterThan(far));

    // Doubling r should drop the field by ~factor of 8 (1/r^3) along the axis.
    expect(near / far, closeTo(8.0, 0.5));
  });

  test('field is stronger at the pole than the equator at the same radius', () {
    const r = 3 * radius;
    final pole = mag.fieldStrengthAt(Vector3(0, 0, r));
    final equator = mag.fieldStrengthAt(Vector3(r, 0, 0));
    // Dipole pole field is exactly twice the equatorial field.
    expect(pole, greaterThan(equator));
    expect(pole / equator, closeTo(2.0, 0.05));
  });

  test('field strength is positive and finite away from the origin', () {
    final b = mag.fieldStrengthAt(Vector3(radius, 0, 0));
    expect(b, greaterThan(0));
    expect(b.isFinite, isTrue);
  });

  test('radiation belt intensity is in [0,1]', () {
    for (var k = 1.0; k < 10; k += 0.5) {
      final i = mag.radiationBeltIntensity(Vector3(0, 0, k * radius));
      expect(i, inInclusiveRange(0.0, 1.0));
    }
  });

  test('radiation belt peaks in a mid-altitude shell, ~0 at surface and far',
      () {
    // Sample the intensity across many altitudes along the equator and find
    // the radius of peak intensity.
    var peakIntensity = 0.0;
    var peakRadius = 0.0;
    for (var k = 1.0; k <= 12.0; k += 0.1) {
      final i = mag.radiationBeltIntensity(Vector3(k * radius, 0, 0));
      if (i > peakIntensity) {
        peakIntensity = i;
        peakRadius = k * radius;
      }
    }

    // The peak should sit in a shell a few radii out, not at the surface.
    final peakInRadii = peakRadius / radius;
    expect(peakInRadii, greaterThan(1.5));
    expect(peakInRadii, lessThan(8.0));
    expect(peakIntensity, greaterThan(0.5));

    // At the surface and very far away, intensity collapses toward zero.
    final atSurface = mag.radiationBeltIntensity(Vector3(radius, 0, 0));
    final farAway = mag.radiationBeltIntensity(Vector3(50 * radius, 0, 0));
    expect(atSurface, lessThan(0.1));
    expect(farAway, lessThan(0.1));
  });

  test('zero position returns zero field and zero belt intensity', () {
    expect(mag.fieldStrengthAt(Vector3.zero), 0.0);
    expect(mag.radiationBeltIntensity(Vector3.zero), 0.0);
  });
}
