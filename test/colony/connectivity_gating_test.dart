import 'package:acro_space_simulator/domain/colony/building.dart';
import 'package:acro_space_simulator/domain/colony/city_network.dart';
import 'package:acro_space_simulator/domain/colony/colony.dart';
import 'package:acro_space_simulator/domain/colony/supply_chain.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const chain = SupplyChain();

  Colony colony({required bool connected}) {
    final ore = ResourceContainer(
        type: ResourceType.ore, capacity: 1000, amount: 1000, unitMass: 1);
    final water = ResourceContainer(
        type: ResourceType.water, capacity: 1000, amount: 0, unitMass: 1);
    final c = Colony(
      id: 'c',
      name: 'C',
      body: const BodyId('earth'),
      latitude: 0,
      longitude: 0,
      population: 20,
      buildings: [
        Building(
          id: 'refinery',
          spec: const BuildingSpec(
            type: 'refinery',
            inputsPerSecond: {ResourceType.ore: 2},
            outputsPerSecond: {ResourceType.water: 1},
            jobs: 10,
          ),
          gridX: 0,
          gridY: 0,
        ),
      ],
      stockpile: {ResourceType.ore: ore, ResourceType.water: water},
    );
    final net = CityNetwork(hub: 'depot');
    if (connected) net.addRoad('depot', 'refinery');
    c.network = net;
    return c;
  }

  test('a road-connected building produces normally', () {
    final c = colony(connected: true);
    chain.advance(c, 10);
    expect(c.stockpile[ResourceType.water]!.amount, greaterThan(0));
  });

  test('a building cut off from the network produces nothing', () {
    final c = colony(connected: false);
    chain.advance(c, 10);
    expect(c.stockpile[ResourceType.water]!.amount, closeTo(0, 1e-9));
    expect(c.buildings.first.efficiency, 0);
  });
}
