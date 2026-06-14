import 'package:acro_space_simulator/domain/dynamics/jet_force.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/parts/jet_engine.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/atmosphere_model.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/domain/vessel/stage.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const seaLevel = AtmosphereSample(
    pressure: 101325,
    density: 1.225,
    temperature: 288,
    speedOfSound: 340,
  );

  Vessel plane({required double fuel, double throttle = 1.0}) {
    final tank = ResourceContainer(
        type: ResourceType.liquidFuel, capacity: 400, amount: fuel, unitMass: 5);
    final v = Vessel(
      id: const VesselId('plane'),
      name: 'Plane',
      ownerId: 'p',
      state: const StateVector(
        position: Vector3(6471000, 0, 0),
        velocity: Vector3(0, 200, 0),
      ),
      dominantBody: const BodyId('earth'),
      stages: [
        Stage(index: 0, parts: [
          Part(id: const PartId('body'), name: 'body', dryMass: 3000, resources: [tank]),
        ]),
      ],
    );
    v.setThrottle(throttle);
    v.totalIntakeArea = 1.0;
    v.jetEngines.add(const JetEngine(
      name: 'J85',
      maxStaticThrust: 18000,
      optimalMach: 1.5,
      machThrustMultiplier: 1.8,
      intakeAreaRequired: 0.3,
    ));
    return v;
  }

  test('jet produces forward thrust in atmosphere and burns fuel', () {
    final v = plane(fuel: 400);
    final force = JetForce(
      vessel: v,
      atmosphere: seaLevel,
      dt: 1.0,
    );
    final gf = force.evaluate(v.state, v.massProperties);
    expect(gf.force.length, greaterThan(0));
    // Fuel consumed.
    final fuelLeft = v.allParts.expand((p) => p.resources).first.amount;
    expect(fuelLeft, lessThan(400));
  });

  test('no thrust in vacuum (air-breather flames out)', () {
    final v = plane(fuel: 400);
    final force = JetForce(
      vessel: v,
      atmosphere: AtmosphereSample.vacuum,
      dt: 1.0,
    );
    final gf = force.evaluate(v.state, v.massProperties);
    expect(gf.force.length, 0);
  });

  test('no thrust when out of fuel', () {
    final v = plane(fuel: 0);
    final force = JetForce(vessel: v, atmosphere: seaLevel, dt: 1.0);
    final gf = force.evaluate(v.state, v.massProperties);
    expect(gf.force.length, 0);
  });

  test('zero throttle -> no thrust', () {
    final v = plane(fuel: 400, throttle: 0);
    final force = JetForce(vessel: v, atmosphere: seaLevel, dt: 1.0);
    final gf = force.evaluate(v.state, v.massProperties);
    expect(gf.force.length, 0);
  });
}
