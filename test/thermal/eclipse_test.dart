import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/thermal/eclipse_service.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const eclipse = EclipseService();
  final body = CelestialBody(
    id: const BodyId('kerbin'),
    name: 'Kerbin',
    mu: 3.5316e12,
    radius: 600000,
    soiRadius: 84159286,
    siderealRotationPeriod: 21549,
    parent: null,
  );

  // Sun toward +X (unit vector from body to sun).
  const sunDir = Vector3.unitX;

  test('vessel on the sunward side is fully lit', () {
    final lit = eclipse.litFraction(
      bodyCentredPosition: const Vector3(700000, 0, 0), // +X, toward the sun
      body: body,
      sunDirection: sunDir,
    );
    expect(lit, 1.0);
  });

  test('vessel directly behind the body is in shadow', () {
    final lit = eclipse.litFraction(
      bodyCentredPosition: const Vector3(-700000, 0, 0), // -X, anti-sun, low alt
      body: body,
      sunDirection: sunDir,
    );
    expect(lit, 0.0);
  });

  test('vessel behind but outside the shadow cylinder is lit', () {
    // Anti-sun side, but far off-axis (beyond the body radius) -> sunlight
    // passes by the planet.
    final lit = eclipse.litFraction(
      bodyCentredPosition: const Vector3(-700000, 2000000, 0),
      body: body,
      sunDirection: sunDir,
    );
    expect(lit, 1.0);
  });

  test('vessel on the terminator (perpendicular to sun) is lit', () {
    final lit = eclipse.litFraction(
      bodyCentredPosition: const Vector3(0, 700000, 0), // +Y, side-on
      body: body,
      sunDirection: sunDir,
    );
    expect(lit, 1.0);
  });
}
