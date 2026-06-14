import 'package:acro_space_simulator/domain/colony/city_demand.dart';
import 'package:acro_space_simulator/domain/colony/colony.dart';
import 'package:acro_space_simulator/domain/colony/zone_growth_service.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const growth = ZoneGrowthService();

  Colony city({required double happiness}) {
    final c = Colony(
      id: 'c',
      name: 'C',
      body: const BodyId('earth'),
      latitude: 0,
      longitude: 0,
      zones: const [Zone(0, 0, ZoneType.residential)],
      happiness: happiness,
    );
    c.demand = const CityDemand(residential: 1.0);
    return c;
  }

  test('a happy city with demand grows', () {
    final c = city(happiness: 0.9);
    growth.grow(c, dt: 10);
    expect(c.buildings, isNotEmpty);
  });

  test('a miserable city does not grow despite demand', () {
    final c = city(happiness: 0.05); // 0.05 * 1.0 = 0.05 < 0.2 threshold
    growth.grow(c, dt: 10);
    expect(c.buildings, isEmpty);
  });
}
