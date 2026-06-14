import 'package:acro_space_simulator/domain/colony/building.dart';
import 'package:acro_space_simulator/domain/colony/city_services.dart';
import 'package:acro_space_simulator/domain/colony/colony.dart';
import 'package:acro_space_simulator/domain/colony/happiness_service.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const happiness = HappinessService();

  Colony colony({required List<Building> buildings, int population = 100}) => Colony(
        id: 'c',
        name: 'C',
        body: const BodyId('earth'),
        latitude: 0,
        longitude: 0,
        population: population,
        buildings: buildings,
        happiness: 0.5,
      );

  Building service(String id, ServiceType type, double coverage) => Building(
        id: id,
        spec: BuildingSpec(type: type.name, services: {type: coverage}),
        gridX: 0,
        gridY: 0,
      );

  test('well-serviced city becomes happier over time', () {
    final c = colony(buildings: [
      service('police', ServiceType.safety, 200),
      service('clinic', ServiceType.health, 200),
      service('park', ServiceType.leisure, 200),
    ]);
    final before = c.happiness;
    for (var i = 0; i < 50; i++) {
      happiness.update(c, dt: 1);
    }
    expect(c.happiness, greaterThan(before));
  });

  test('an unserviced city loses happiness', () {
    final c = colony(buildings: const [], population: 100);
    final before = c.happiness;
    for (var i = 0; i < 50; i++) {
      happiness.update(c, dt: 1);
    }
    expect(c.happiness, lessThan(before));
  });

  test('happiness is bounded to [0,1]', () {
    final c = colony(buildings: [
      service('a', ServiceType.safety, 1e6),
      service('b', ServiceType.health, 1e6),
      service('c', ServiceType.leisure, 1e6),
    ]);
    for (var i = 0; i < 1000; i++) {
      happiness.update(c, dt: 1);
    }
    expect(c.happiness, lessThanOrEqualTo(1.0));
    expect(c.happiness, greaterThanOrEqualTo(0.0));
  });

  test('service coverage is the min across required service types', () {
    // Great safety but zero health -> coverage limited by health.
    final c = colony(buildings: [service('police', ServiceType.safety, 1000)]);
    final coverage = happiness.serviceCoverage(c);
    expect(coverage, closeTo(0, 1e-9)); // no health/leisure at all
  });
}
