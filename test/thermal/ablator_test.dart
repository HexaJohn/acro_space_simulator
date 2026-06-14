import 'package:acro_space_simulator/domain/thermal/thermal_model.dart';
import 'package:acro_space_simulator/domain/thermal/thermal_state.dart';
import 'package:acro_space_simulator/domain/universe/atmosphere_model.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const model = ThermalModel();

  const reentryAir = AtmosphereSample(
    pressure: 50000,
    density: 0.8,
    temperature: 270,
    speedOfSound: 320,
  );

  PartThermalState shielded({required double ablator}) => PartThermalState(
        part: const PartId('shield'),
        temperature: 300,
        heatCapacity: 5000,
        maxTemperature: 3000,
        surfaceArea: 8,
        ablator: ablator,
        ablationHeatPerUnit: 5000, // J absorbed per unit burned
      );

  test('ablator burns off during reentry heating', () {
    final s = shielded(ablator: 100);
    model.advance(
      s,
      dt: 1.0,
      solarFlux: 0,
      solarFacingFraction: 0,
      ambient: reentryAir,
      airspeed: 2500,
    );
    expect(s.ablator, lessThan(100)); // some ablator consumed
  });

  test('a shielded part heats less than an unshielded one in the same reentry', () {
    // Enough ablator to soak the reentry flux across all five steps.
    final shieldedPart = shielded(ablator: 100000);
    final barePart = PartThermalState(
      part: const PartId('bare'),
      temperature: 300,
      heatCapacity: 5000,
      maxTemperature: 3000,
      surfaceArea: 8,
    );

    for (var i = 0; i < 5; i++) {
      model.advance(shieldedPart,
          dt: 1.0, solarFlux: 0, solarFacingFraction: 0, ambient: reentryAir, airspeed: 2500);
      model.advance(barePart,
          dt: 1.0, solarFlux: 0, solarFacingFraction: 0, ambient: reentryAir, airspeed: 2500);
    }
    expect(shieldedPart.temperature, lessThan(barePart.temperature));
  });

  test('once the ablator is spent the part heats like a bare one', () {
    final s = shielded(ablator: 0.0001); // basically empty
    final before = s.temperature;
    model.advance(s,
        dt: 1.0, solarFlux: 0, solarFacingFraction: 0, ambient: reentryAir, airspeed: 2500);
    expect(s.ablator, 0);
    expect(s.temperature, greaterThan(before));
  });
}
