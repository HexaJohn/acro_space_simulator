import 'package:acro_space_simulator/domain/colony/building.dart';
import 'package:acro_space_simulator/domain/colony/colony.dart';
import 'package:acro_space_simulator/domain/colony/supply_chain.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const chain = SupplyChain();

  Colony makeColony() {
    final ore = ResourceContainer(
        type: ResourceType.ore, capacity: 1000, amount: 500, unitMass: 1);
    final water = ResourceContainer(
        type: ResourceType.water, capacity: 1000, amount: 0, unitMass: 1);
    return Colony(
      id: 'c1',
      name: 'Base',
      body: const BodyId('earth'),
      latitude: 0,
      longitude: 0,
      population: 5,
      buildings: [
        // Refinery: ore -> water; provides jobs.
        Building(
          id: 'refinery',
          spec: const BuildingSpec(
            type: 'refinery',
            inputsPerSecond: {ResourceType.ore: 2},
            outputsPerSecond: {ResourceType.water: 1},
            jobs: 5,
          ),
          gridX: 0,
          gridY: 0,
        ),
        // Housing: grows population.
        Building(
          id: 'hab',
          spec: const BuildingSpec(type: 'hab', housing: 50),
          gridX: 1,
          gridY: 0,
        ),
      ],
      stockpile: {
        ResourceType.ore: ore,
        ResourceType.water: water,
      },
    );
  }

  test('supply chain consumes inputs and produces outputs', () {
    final colony = makeColony();
    chain.advance(colony, 10.0);

    expect(colony.stockpile[ResourceType.ore]!.amount, lessThan(500));
    expect(colony.stockpile[ResourceType.water]!.amount, greaterThan(0));
  });

  test('population grows toward housing capacity', () {
    final colony = makeColony();
    final before = colony.population;
    for (var i = 0; i < 50; i++) {
      chain.advance(colony, 10.0);
    }
    expect(colony.population, greaterThan(before));
    expect(colony.population, lessThanOrEqualTo(colony.housingCapacity));
  });

  test('production starves when an input is exhausted', () {
    final colony = makeColony();
    colony.stockpile[ResourceType.ore]!.amount = 0;
    final waterBefore = colony.stockpile[ResourceType.water]!.amount;
    chain.advance(colony, 10.0);
    // No ore -> efficiency drops to zero -> no water produced.
    expect(colony.stockpile[ResourceType.water]!.amount, closeTo(waterBefore, 1e-9));
  });
}
