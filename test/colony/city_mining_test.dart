import 'package:acro_space_simulator/domain/colony/building.dart';
import 'package:acro_space_simulator/domain/colony/city_mining_service.dart';
import 'package:acro_space_simulator/domain/colony/colony.dart';
import 'package:acro_space_simulator/domain/mining/resource_deposit.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const mining = CityMiningService();

  Building mine(String id) => Building(
        id: id,
        spec: const BuildingSpec(type: 'mine', jobs: 10, miningRate: 5),
        gridX: 0,
        gridY: 0,
      );

  Colony colony({required int mines}) {
    final ore = ResourceContainer(
        type: ResourceType.ore, capacity: 100000, amount: 0, unitMass: 1);
    return Colony(
      id: 'c',
      name: 'C',
      body: const BodyId('earth'),
      latitude: 0,
      longitude: 0,
      buildings: [for (var i = 0; i < mines; i++) mine('mine-$i')],
      stockpile: {ResourceType.ore: ore},
    );
  }

  ResourceDeposit deposit({double? reserves}) => ResourceDeposit(
        id: 'd',
        body: const BodyId('earth'),
        latitude: 0,
        longitude: 0,
        resource: ResourceType.ore,
        concentration: 1.0,
        reserves: reserves,
      );

  test('mining buildings extract ore from the body deposit into the stockpile', () {
    final c = colony(mines: 3);
    final d = deposit(reserves: 100000);
    mining.advance(c, d, dt: 10);
    expect(c.stockpile[ResourceType.ore]!.amount, greaterThan(0));
    expect(d.reserves, lessThan(100000));
  });

  test('more mines extract proportionally more (city = large-scale mining)', () {
    final small = colony(mines: 1);
    final big = colony(mines: 10);
    final d1 = deposit(reserves: 1e9);
    final d2 = deposit(reserves: 1e9);
    mining.advance(small, d1, dt: 10);
    mining.advance(big, d2, dt: 10);
    expect(big.stockpile[ResourceType.ore]!.amount,
        closeTo(small.stockpile[ResourceType.ore]!.amount * 10, 1e-6));
  });

  test('a depleted deposit yields nothing', () {
    final c = colony(mines: 5);
    final d = deposit(reserves: 0);
    mining.advance(c, d, dt: 10);
    expect(c.stockpile[ResourceType.ore]!.amount, 0);
  });

  test('a city with no mines extracts nothing', () {
    final c = colony(mines: 0);
    final d = deposit(reserves: 1000);
    mining.advance(c, d, dt: 10);
    expect(c.stockpile[ResourceType.ore]!.amount, 0);
  });
}
