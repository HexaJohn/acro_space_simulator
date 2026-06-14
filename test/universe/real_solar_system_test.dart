import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final system = RealSolarSystem.build();

  test('the root body is the Sun', () {
    final sun = system.require(const BodyId('sun'));
    expect(sun.isStar, isTrue);
    expect(sun.mu, closeTo(1.32712440018e20, 1e15)); // GM_sun
  });

  test('Earth has realistic gravitational parameter, radius, and orbit', () {
    final earth = system.require(const BodyId('earth'));
    expect(earth.mu, closeTo(3.986004418e14, 1e9)); // GM_earth
    expect(earth.radius, closeTo(6371000, 1000)); // mean radius
    expect(earth.orbitRadius, closeTo(1.496e11, 1e9)); // 1 AU
    expect(earth.parent, const BodyId('sun'));
    expect(earth.hasAtmosphere, isTrue);
  });

  test('the Moon orbits Earth', () {
    final moon = system.require(const BodyId('moon'));
    expect(moon.parent, const BodyId('earth'));
    expect(moon.orbitRadius, closeTo(3.844e8, 1e6)); // ~384,400 km
    expect(moon.mu, closeTo(4.9028e12, 1e10));
  });

  test('all eight planets are present and orbit the Sun', () {
    const planets = [
      'mercury', 'venus', 'earth', 'mars', 'jupiter', 'saturn', 'uranus', 'neptune'
    ];
    for (final p in planets) {
      final body = system.require(BodyId(p));
      expect(body.parent, const BodyId('sun'), reason: '$p should orbit the Sun');
      expect(body.orbitRadius, greaterThan(0));
    }
  });

  test('Mars has a noticeably eccentric orbit', () {
    final mars = system.require(const BodyId('mars'));
    expect(mars.orbitEccentricity, greaterThan(0.05));
  });

  test('outer planets are much farther than inner planets', () {
    final mercury = system.require(const BodyId('mercury'));
    final neptune = system.require(const BodyId('neptune'));
    expect(neptune.orbitRadius, greaterThan(mercury.orbitRadius * 50));
  });

  test('gas giants are airless-modelled or have atmospheres but huge radii', () {
    final jupiter = system.require(const BodyId('jupiter'));
    expect(jupiter.radius, greaterThan(6.9e7)); // ~71,000 km
    expect(jupiter.mu, greaterThan(1.2e17));
  });

  test('major moons exist for the gas giants', () {
    // At least a few Galilean / Saturnian moons.
    for (final m in ['io', 'europa', 'titan']) {
      final moon = system.body(BodyId(m));
      expect(moon, isNotNull, reason: '$m should exist');
    }
    expect(system.require(const BodyId('titan')).parent, const BodyId('saturn'));
  });
}
