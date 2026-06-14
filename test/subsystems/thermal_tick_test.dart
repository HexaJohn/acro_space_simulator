import 'package:acro_space_simulator/domain/subsystems/vessel_thermal_updater.dart';
import 'package:acro_space_simulator/domain/thermal/thermal_state.dart';
import 'package:acro_space_simulator/domain/universe/atmosphere_model.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:flutter_test/flutter_test.dart';

Vessel _vesselWithThermal(PartThermalState thermal) => Vessel(
      id: const VesselId('t'),
      name: 'Thermal Test',
      ownerId: 'p',
      state: const StateVector(position: Vector3(700000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('kerbin'),
      stages: const [],
      thermal: [thermal],
    );

void main() {
  const updater = VesselThermalUpdater();

  test('reentry heating raises a part temperature', () {
    final t = PartThermalState(
      part: const PartId('hull'),
      temperature: 300,
      heatCapacity: 5000,
      maxTemperature: 2500,
      surfaceArea: 4,
    );
    final vessel = _vesselWithThermal(t);

    // Dense air at high speed -> stagnation heating.
    const dense = AtmosphereSample(
      pressure: 101325,
      density: 1.225,
      temperature: 288,
      speedOfSound: 340,
    );
    updater.update(
      vessel,
      dt: 1.0,
      ambient: dense,
      airspeed: 2000,
      solarFlux: 0,
      sunFacing: 0,
    );

    expect(vessel.thermalOf(const PartId('hull'))!.temperature, greaterThan(300));
  });

  test('overheating past max raises a destruction event', () {
    // Already at the limit: searing reentry flux (thin hot air at very high
    // speed, so convective cooling toward ambient can't keep up) tips it over.
    final t = PartThermalState(
      part: const PartId('hull'),
      temperature: 2500,
      heatCapacity: 50,
      maxTemperature: 2500,
      surfaceArea: 10,
    );
    final vessel = _vesselWithThermal(t);

    updater.update(
      vessel,
      dt: 1.0,
      ambient: const AtmosphereSample(
          pressure: 50000, density: 0.5, temperature: 2000, speedOfSound: 400),
      airspeed: 7000,
      solarFlux: 0,
      sunFacing: 0,
    );

    final events = vessel.drainEvents();
    expect(events.whereType<PartOverheated>().isNotEmpty, isTrue);
  });

  test('radiative cooling in vacuum lowers a hot part temperature', () {
    final t = PartThermalState(
      part: const PartId('rad'),
      temperature: 1000,
      heatCapacity: 1000,
      maxTemperature: 2500,
      surfaceArea: 20,
    );
    final vessel = _vesselWithThermal(t);

    updater.update(
      vessel,
      dt: 10.0,
      ambient: AtmosphereSample.vacuum,
      airspeed: 0,
      solarFlux: 0, // no sun
      sunFacing: 0,
    );

    expect(vessel.thermalOf(const PartId('rad'))!.temperature, lessThan(1000));
  });
}
