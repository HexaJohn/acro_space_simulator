import 'package:acro_space_simulator/domain/thermal/thermal_model.dart';
import 'package:acro_space_simulator/domain/thermal/thermal_state.dart';
import 'package:acro_space_simulator/domain/universe/atmosphere_model.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const model = ThermalModel();

  // Cold part in warm dense air -> convection heats it toward ambient.
  const warmAir = AtmosphereSample(
    pressure: 101325,
    density: 1.225,
    temperature: 320, // warmer than the part
    speedOfSound: 340,
  );

  PartThermalState coldPart() => PartThermalState(
        part: const PartId('p'),
        temperature: 280,
        heatCapacity: 100000, // big, so one tick barely moves it
        maxTemperature: 3000,
        surfaceArea: 5,
      );

  test('faster airflow transfers heat faster (forced convection)', () {
    final still = coldPart();
    final fast = coldPart();

    model.advance(still,
        dt: 1, solarFlux: 0, solarFacingFraction: 0, ambient: warmAir, airspeed: 0);
    model.advance(fast,
        dt: 1, solarFlux: 0, solarFacingFraction: 0, ambient: warmAir, airspeed: 200);

    final stillGain = still.temperature - 280;
    final fastGain = fast.temperature - 280;
    // Both warmed (toward 320), but the fast-moving part warmed more.
    expect(stillGain, greaterThan(0));
    expect(fastGain, greaterThan(stillGain));
  });

  test('no atmosphere -> no convective transfer regardless of speed', () {
    final p = coldPart();
    final before = p.temperature;
    model.advance(p,
        dt: 1,
        solarFlux: 0,
        solarFacingFraction: 0,
        ambient: AtmosphereSample.vacuum,
        airspeed: 500);
    // Only radiative cooling applies in vacuum; temperature should not rise.
    expect(p.temperature, lessThanOrEqualTo(before));
  });
}
