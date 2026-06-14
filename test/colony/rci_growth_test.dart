import 'package:acro_space_simulator/domain/colony/city_demand.dart';
import 'package:acro_space_simulator/domain/colony/colony.dart';
import 'package:acro_space_simulator/domain/colony/zone_growth_service.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const growth = ZoneGrowthService();

  Colony cityWith({required List<Zone> zones, required CityDemand demand}) {
    final c = Colony(
      id: 'c',
      name: 'City',
      body: const BodyId('earth'),
      latitude: 0,
      longitude: 0,
      zones: zones,
    );
    c.demand = demand;
    return c;
  }

  test('high residential demand on an empty residential zone grows a building', () {
    final c = cityWith(
      zones: const [Zone(0, 0, ZoneType.residential)],
      demand: const CityDemand(residential: 1.0, commercial: 0, industrial: 0),
    );
    expect(c.buildings, isEmpty);
    growth.grow(c, dt: 10);
    expect(c.buildings.where((b) => b.gridX == 0 && b.gridY == 0), isNotEmpty);
    // Growing consumed some residential demand.
    expect(c.demand.residential, lessThan(1.0));
  });

  test('no demand -> no growth', () {
    final c = cityWith(
      zones: const [Zone(0, 0, ZoneType.industrial)],
      demand: const CityDemand(residential: 0, commercial: 0, industrial: 0),
    );
    growth.grow(c, dt: 10);
    expect(c.buildings, isEmpty);
  });

  test('a building only grows in a zone matching the demand type', () {
    final c = cityWith(
      zones: const [Zone(0, 0, ZoneType.commercial)],
      // Only residential demand; commercial zone should stay empty.
      demand: const CityDemand(residential: 1.0, commercial: 0, industrial: 0),
    );
    growth.grow(c, dt: 10);
    expect(c.buildings, isEmpty);
  });

  test('growth fills empty zoned cells but not already-occupied ones', () {
    final c = cityWith(
      zones: const [
        Zone(0, 0, ZoneType.industrial),
        Zone(1, 0, ZoneType.industrial),
      ],
      demand: const CityDemand(residential: 0, commercial: 0, industrial: 1.0),
    );
    growth.grow(c, dt: 100); // strong, long tick
    // At most one cell per growth step keeps it gradual; run again to fill more.
    growth.grow(c, dt: 100);
    final cells = c.buildings.map((b) => '${b.gridX},${b.gridY}').toSet();
    expect(cells.length, c.buildings.length); // no two buildings share a cell
  });
}
