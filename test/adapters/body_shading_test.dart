import 'package:acro_space_simulator/adapters/presenters/body_shading.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const shading = BodyShading();

  // Sun toward +X in the XY render plane.
  const sunDir = Vector3.unitX;

  test('sub-solar point (facing the sun) is fully lit', () {
    // The disc point whose normal aligns with the sun: rim point on the +X side,
    // where normal -> (1, 0, 0).
    expect(shading.brightnessAt(1.0, 0.0, sunDir), closeTo(1.0, 1e-9));
  });

  test('disc centre faces the viewer (+Z), lit by the in-plane sun is dark', () {
    // Centre normal is (0,0,1); perpendicular to an in-plane sun -> 0.
    expect(shading.brightnessAt(0.0, 0.0, sunDir), closeTo(0.0, 1e-9));
  });

  test('anti-solar edge is dark (~0)', () {
    expect(shading.brightnessAt(-1.0, 0.0, sunDir), closeTo(0.0, 1e-9));
  });

  test('points off the disc return 0', () {
    expect(shading.brightnessAt(0.8, 0.8, sunDir), 0.0); // r^2 = 1.28 > 1
    expect(shading.brightnessAt(2.0, 0.0, sunDir), 0.0);
    expect(shading.brightnessAt(0.0, -1.5, sunDir), 0.0);
  });

  test('brightness is always within [0, 1]', () {
    for (var i = -10; i <= 10; i++) {
      for (var j = -10; j <= 10; j++) {
        final dx = i / 10.0;
        final dy = j / 10.0;
        final b = shading.brightnessAt(dx, dy, sunDir);
        expect(b, inInclusiveRange(0.0, 1.0));
      }
    }
  });

  test('brightness decreases moving from sub-solar point toward terminator', () {
    final lit = shading.brightnessAt(0.9, 0.0, sunDir);
    final dim = shading.brightnessAt(0.3, 0.0, sunDir);
    expect(lit, greaterThan(dim));
  });

  test('terminatorBrightness is 0 under the ideal Lambert model', () {
    expect(shading.terminatorBrightness(sunDir), 0.0);
  });
}
