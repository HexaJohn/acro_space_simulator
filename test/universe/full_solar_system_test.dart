import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final system = RealSolarSystem.build();

  test('all five recognised dwarf planets are present and orbit the Sun', () {
    for (final id in ['ceres', 'pluto', 'eris', 'haumea', 'makemake']) {
      final body = system.body(BodyId(id));
      expect(body, isNotNull, reason: '$id should exist');
      expect(body!.parent, const BodyId('sun'));
    }
  });

  test('Charon orbits Pluto; Triton orbits Neptune', () {
    expect(system.require(const BodyId('charon')).parent, const BodyId('pluto'));
    expect(system.require(const BodyId('triton')).parent, const BodyId('neptune'));
  });

  test('major moons of every gas giant are present', () {
    const moons = [
      'io', 'europa', 'ganymede', 'callisto', // Jupiter
      'titan', 'enceladus', 'mimas', 'rhea', 'iapetus', 'dione', 'tethys', // Saturn
      'titania', 'oberon', 'miranda', 'ariel', 'umbriel', // Uranus
      'triton', // Neptune
    ];
    for (final m in moons) {
      expect(system.body(BodyId(m)), isNotNull, reason: '$m should exist');
    }
  });

  test('Mars has both Phobos and Deimos', () {
    expect(system.require(const BodyId('phobos')).parent, const BodyId('mars'));
    expect(system.require(const BodyId('deimos')).parent, const BodyId('mars'));
  });

  test('Earth carries its planetary-science models (surface, composition, tilt, J2)', () {
    final earth = system.require(const BodyId('earth'));
    expect(earth.surface, isNotNull);
    expect(earth.composition, isNotNull);
    expect(earth.axialTilt, greaterThan(0));
    expect(earth.j2, greaterThan(0));
  });

  test('the system has a large body count (planets + dwarfs + moons)', () {
    expect(system.all.length, greaterThanOrEqualTo(30));
  });
}
