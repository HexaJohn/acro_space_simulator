import 'package:acro_space_simulator/domain/power/power_plant.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final catalog = PowerPlantCatalog.standard();

  test('catalog includes the full range of power-plant types', () {
    final types = catalog.all.map((p) => p.type).toSet();
    for (final t in [
      PowerPlantType.solar,
      PowerPlantType.fission,
      PowerPlantType.fusion,
      PowerPlantType.rtg,
      PowerPlantType.fuelCell,
      PowerPlantType.geothermal,
      PowerPlantType.wind,
      PowerPlantType.hydro,
      PowerPlantType.antimatter,
      PowerPlantType.beamedMicrowave,
    ]) {
      expect(types, contains(t), reason: '$t missing');
    }
  });

  test('solar output scales with sunlight and falls to zero in the dark', () {
    final solar = catalog.byType(PowerPlantType.solar)!;
    final lit = solar.output(sunlightFraction: 1.0, fuelAvailable: 0);
    final dark = solar.output(sunlightFraction: 0.0, fuelAvailable: 0);
    expect(lit, greaterThan(0));
    expect(dark, 0);
  });

  test('a fission reactor produces power only when it has fuel', () {
    final fission = catalog.byType(PowerPlantType.fission)!;
    expect(fission.requiresFuel, isTrue);
    expect(fission.output(sunlightFraction: 0, fuelAvailable: 100), greaterThan(0));
    expect(fission.output(sunlightFraction: 0, fuelAvailable: 0), 0);
  });

  test('an RTG runs without sunlight or refuelling (decay heat)', () {
    final rtg = catalog.byType(PowerPlantType.rtg)!;
    expect(rtg.requiresFuel, isFalse);
    expect(rtg.requiresSunlight, isFalse);
    expect(rtg.output(sunlightFraction: 0, fuelAvailable: 0), greaterThan(0));
  });

  test('higher-tech plants output far more than basic ones', () {
    final solar = catalog.byType(PowerPlantType.solar)!;
    final antimatter = catalog.byType(PowerPlantType.antimatter)!;
    expect(antimatter.ratedOutput, greaterThan(solar.ratedOutput * 100));
  });

  test('fuelled plants declare their fuel resource type', () {
    final fusion = catalog.byType(PowerPlantType.fusion)!;
    expect(fusion.fuelType, isNotNull);
    expect(fusion.fuelType, isA<ResourceType>());
  });
}
