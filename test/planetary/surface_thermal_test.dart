import 'package:acro_space_simulator/domain/planetary/planet_surface.dart';
import 'package:acro_space_simulator/domain/planetary/surface_thermal_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const model = SurfaceThermalModel();

  test('an ocean cell warms slower than land for the same forcing (thermal mass)',
      () {
    // Both start cold, equilibrium target is warm; ocean has huge heat capacity.
    final ocean = SurfaceCellThermal(
        temperature: 280, biome: Biome.ocean);
    final desert = SurfaceCellThermal(
        temperature: 280, biome: Biome.desert);

    model.advance(ocean, equilibriumTemperature: 320, dt: 3600);
    model.advance(desert, equilibriumTemperature: 320, dt: 3600);

    expect(desert.temperature, greaterThan(ocean.temperature)); // land reacts faster
    expect(ocean.temperature, greaterThan(280)); // but still warms some
  });

  test('cells relax toward the equilibrium temperature over time', () {
    final cell = SurfaceCellThermal(temperature: 250, biome: Biome.grassland);
    for (var i = 0; i < 500; i++) {
      model.advance(cell, equilibriumTemperature: 300, dt: 3600);
    }
    expect(cell.temperature, closeTo(300, 2.0));
  });

  test('ocean moderates: it neither overheats nor overcools as fast', () {
    final ocean = SurfaceCellThermal(temperature: 290, biome: Biome.ocean);
    // Swing the target hot then cold; ocean temperature stays near the middle.
    model.advance(ocean, equilibriumTemperature: 350, dt: 3600);
    final afterHot = ocean.temperature;
    model.advance(ocean, equilibriumTemperature: 230, dt: 3600);
    final afterCold = ocean.temperature;
    expect(afterHot, lessThan(320)); // didn't shoot up to 350
    expect(afterCold, greaterThan(260)); // didn't crash to 230
  });

  test('ocean freezes below 273 K (forms ice)', () {
    final ocean = SurfaceCellThermal(temperature: 274, biome: Biome.ocean);
    for (var i = 0; i < 2000; i++) {
      model.advance(ocean, equilibriumTemperature: 250, dt: 3600);
    }
    expect(ocean.temperature, lessThan(273.16));
    expect(ocean.frozen, isTrue);
  });

  test('a frozen ocean is not frozen once it warms back up', () {
    final ocean = SurfaceCellThermal(temperature: 260, biome: Biome.ocean, frozen: true);
    for (var i = 0; i < 4000; i++) {
      model.advance(ocean, equilibriumTemperature: 300, dt: 3600);
    }
    expect(ocean.frozen, isFalse);
  });
}
