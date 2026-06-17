import 'package:acro_space_simulator/domain/agriculture/farm.dart';
import 'package:acro_space_simulator/domain/agriculture/farming_service.dart';
import 'package:acro_space_simulator/domain/colony/colony.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const farming = FarmingService();

  Colony farmColony({required double water, required int farms, CropType crop = CropType.grain}) {
    final waterC = ResourceContainer(
        type: ResourceType.water, capacity: 1e6, amount: water, unitMass: 1);
    final foodC = ResourceContainer(
        type: ResourceType.food, capacity: 1e6, amount: 0, unitMass: 1);
    final c = Colony(
      id: 'farm',
      name: 'Farmstead',
      body: const BodyId('earth'),
      latitude: 0,
      longitude: 0,
      stockpile: {ResourceType.water: waterC, ResourceType.food: foodC},
    );
    for (var i = 0; i < farms; i++) {
      c.farms.add(Farm(id: 'f$i', crop: crop, area: 1e4));
    }
    return c;
  }

  test('a farm grows crops over time given sunlight and water', () {
    final c = farmColony(water: 1e5, farms: 1);
    final before = c.farms.first.growth;
    farming.advance(c, dt: 86400, sunlightFraction: 1.0); // one day
    expect(c.farms.first.growth, greaterThan(before));
  });

  test('a mature crop is harvested into the food stockpile, resetting growth', () {
    final c = farmColony(water: 1e9, farms: 1);
    final farm = c.farms.first;
    // Push it to maturity over many days.
    for (var i = 0; i < 400; i++) {
      farming.advance(c, dt: 86400, sunlightFraction: 1.0);
    }
    expect(c.stockpile[ResourceType.food]!.amount, greaterThan(0));
    // After at least one harvest, growth has cycled back down.
    expect(farm.growth, lessThan(1.0));
  });

  test('without water, crops do not grow', () {
    final c = farmColony(water: 0, farms: 1);
    final before = c.farms.first.growth;
    farming.advance(c, dt: 86400, sunlightFraction: 1.0);
    expect(c.farms.first.growth, before);
  });

  test('darkness halts growth (no photosynthesis)', () {
    final c = farmColony(water: 1e5, farms: 1);
    final before = c.farms.first.growth;
    farming.advance(c, dt: 86400, sunlightFraction: 0.0);
    expect(c.farms.first.growth, before);
  });

  test('more farms produce more food', () {
    final one = farmColony(water: 1e9, farms: 1);
    final ten = farmColony(water: 1e9, farms: 10);
    for (var i = 0; i < 400; i++) {
      farming.advance(one, dt: 86400, sunlightFraction: 1.0);
      farming.advance(ten, dt: 86400, sunlightFraction: 1.0);
    }
    expect(ten.stockpile[ResourceType.food]!.amount,
        greaterThan(one.stockpile[ResourceType.food]!.amount));
  });

  test('crop type affects yield (different growth times / output)', () {
    expect(CropType.grain.growthDays, isNot(CropType.potato.growthDays));
  });
}
