import 'package:acro_space_simulator/domain/planetary/magnetosphere.dart';
import 'package:acro_space_simulator/domain/radiation/radiation_environment.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const env = RadiationEnvironment();

  // Earth-like magnetosphere with a belt centred ~3 body radii out.
  const earthMag = Magnetosphere(
    dipoleMoment: 8.0e22,
    bodyRadius: 6.371e6,
    beltCenterRadii: 3.0,
    beltWidthRadii: 1.0,
  );

  test('deep space has a small nonzero cosmic-ray background', () {
    final d = env.doseRate(
      position: const Vector3(1e12, 0, 0),
      magnetosphere: null,
      solarFlux: 0,
      shielding: 0,
    );
    expect(d, greaterThan(0));
    expect(d, lessThan(1e-6)); // background is low
  });

  test('inside a radiation belt the dose rate spikes far above background', () {
    final beltPos = const Vector3(3.0 * 6.371e6, 0, 0); // ~3 Re, belt centre
    final inBelt = env.doseRate(
      position: beltPos,
      magnetosphere: earthMag,
      solarFlux: 1361,
      shielding: 0,
    );
    final deepSpace = env.doseRate(
      position: const Vector3(1e12, 0, 0),
      magnetosphere: null,
      solarFlux: 0,
      shielding: 0,
    );
    expect(inBelt, greaterThan(deepSpace * 10));
  });

  test('shielding reduces the dose rate', () {
    final pos = const Vector3(3.0 * 6.371e6, 0, 0);
    final bare = env.doseRate(
        position: pos, magnetosphere: earthMag, solarFlux: 1361, shielding: 0);
    final shielded = env.doseRate(
        position: pos, magnetosphere: earthMag, solarFlux: 1361, shielding: 0.9);
    expect(shielded, lessThan(bare));
    expect(shielded, closeTo(bare * 0.1, bare * 0.02)); // ~90% blocked
  });

  test('a solar flare raises the dose, stronger nearer the sun', () {
    final near = env.doseRate(
        position: const Vector3(1e11, 0, 0),
        magnetosphere: null,
        solarFlux: 1361,
        shielding: 0,
        solarFlare: 1.0);
    final far = env.doseRate(
        position: const Vector3(5e11, 0, 0),
        magnetosphere: null,
        solarFlux: 50,
        shielding: 0,
        solarFlare: 1.0);
    expect(near, greaterThan(far));
  });

  test('full shielding blocks almost all radiation', () {
    final d = env.doseRate(
      position: const Vector3(3.0 * 6.371e6, 0, 0),
      magnetosphere: earthMag,
      solarFlux: 1361,
      shielding: 1.0,
    );
    expect(d, closeTo(0, 1e-9));
  });
}
