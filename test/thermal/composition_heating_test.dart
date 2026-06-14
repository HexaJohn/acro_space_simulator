import 'package:acro_space_simulator/domain/thermal/thermal_model.dart';
import 'package:acro_space_simulator/domain/thermal/thermal_state.dart';
import 'package:acro_space_simulator/domain/universe/atmosphere_model.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const model = ThermalModel();
  const air = AtmosphereSample(
    pressure: 101325,
    density: 1.225,
    temperature: 250,
    speedOfSound: 340,
  );

  PartThermalState hull() => PartThermalState(
        part: const PartId('hull'),
        temperature: 300,
        heatCapacity: 5000,
        maxTemperature: 4000,
        surfaceArea: 6,
      );

  test('a higher gas-heating factor produces more reentry heating', () {
    final light = hull();
    final heavy = hull();

    model.advance(light,
        dt: 1,
        solarFlux: 0,
        solarFacingFraction: 0,
        ambient: air,
        airspeed: 3000,
        gasHeatingFactor: 1.0);
    model.advance(heavy,
        dt: 1,
        solarFlux: 0,
        solarFacingFraction: 0,
        ambient: air,
        airspeed: 3000,
        gasHeatingFactor: 2.0); // e.g. CO2-rich heavy atmosphere

    expect(heavy.temperature, greaterThan(light.temperature));
  });

  test('default gas-heating factor of 1.0 leaves the old behaviour', () {
    final a = hull();
    final b = hull();
    model.advance(a,
        dt: 1, solarFlux: 0, solarFacingFraction: 0, ambient: air, airspeed: 2000);
    model.advance(b,
        dt: 1,
        solarFlux: 0,
        solarFacingFraction: 0,
        ambient: air,
        airspeed: 2000,
        gasHeatingFactor: 1.0);
    expect(a.temperature, closeTo(b.temperature, 1e-6));
  });
}
