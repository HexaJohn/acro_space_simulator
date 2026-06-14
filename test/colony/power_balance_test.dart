import 'package:acro_space_simulator/domain/colony/building.dart';
import 'package:acro_space_simulator/domain/colony/colony.dart';
import 'package:acro_space_simulator/domain/colony/supply_chain.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const chain = SupplyChain();

  Colony colony({required double plantOutput}) {
    final ore = ResourceContainer(
        type: ResourceType.ore, capacity: 1000, amount: 1000, unitMass: 1);
    final water = ResourceContainer(
        type: ResourceType.water, capacity: 1000, amount: 0, unitMass: 1);
    return Colony(
      id: 'c',
      name: 'Base',
      body: const BodyId('kerbin'),
      latitude: 0,
      longitude: 0,
      population: 20,
      buildings: [
        // Refinery needs 10 power/s to run at full output.
        Building(
          id: 'refinery',
          spec: const BuildingSpec(
            type: 'refinery',
            inputsPerSecond: {ResourceType.ore: 2},
            outputsPerSecond: {ResourceType.water: 1},
            jobs: 10,
            powerDraw: 10,
          ),
          gridX: 0,
          gridY: 0,
        ),
        // Solar plant supplying [plantOutput] power/s.
        Building(
          id: 'solar',
          spec: BuildingSpec(type: 'solar', powerOutput: plantOutput),
          gridX: 1,
          gridY: 0,
        ),
      ],
      stockpile: {ResourceType.ore: ore, ResourceType.water: water},
    );
  }

  test('fully powered colony runs the refinery at full output', () {
    final c = colony(plantOutput: 20); // surplus
    chain.advance(c, 10.0);
    expect(c.stockpile[ResourceType.water]!.amount, closeTo(10, 1e-6));
  });

  test('power shortage throttles production proportionally', () {
    final c = colony(plantOutput: 5); // only half the 10/s demand
    chain.advance(c, 10.0);
    // ~50% power -> ~half the water of a fully powered run.
    final water = c.stockpile[ResourceType.water]!.amount;
    expect(water, lessThan(8));
    expect(water, greaterThan(2));
  });

  test('no power -> no production', () {
    final c = colony(plantOutput: 0);
    chain.advance(c, 10.0);
    expect(c.stockpile[ResourceType.water]!.amount, closeTo(0, 1e-9));
  });

  test('output respects storage capacity (no overfill)', () {
    final c = colony(plantOutput: 100);
    // Shrink water capacity so it fills fast.
    c.stockpile[ResourceType.water] = ResourceContainer(
        type: ResourceType.water, capacity: 3, amount: 0, unitMass: 1);
    chain.advance(c, 100.0); // would produce ~100 but capacity is 3
    expect(c.stockpile[ResourceType.water]!.amount, lessThanOrEqualTo(3));
  });

  test('colony exposes its power balance', () {
    final c = colony(plantOutput: 25);
    expect(c.powerOutput, closeTo(25, 1e-9));
    expect(c.powerDemand, closeTo(10, 1e-9));
    expect(c.powerRatio, 1.0); // surplus -> fully powered
  });
}
