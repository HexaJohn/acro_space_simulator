import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/converter.dart';
import 'package:acro_space_simulator/domain/vessel/isru_service.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/domain/vessel/stage.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const isru = IsruService();

  Vessel colonyShip({
    required double ore,
    required double power,
    double fuel = 0,
    double fuelCap = 1000,
  }) {
    final oreC = ResourceContainer(
        type: ResourceType.ore, capacity: 1000, amount: ore, unitMass: 1);
    final powerC = ResourceContainer(
        type: ResourceType.electricCharge, capacity: 5000, amount: power, unitMass: 0);
    final fuelC = ResourceContainer(
        type: ResourceType.liquidFuel, capacity: fuelCap, amount: fuel, unitMass: 5);
    final v = Vessel(
      id: const VesselId('isru'),
      name: 'Colony Ship',
      ownerId: 'p',
      state: const StateVector(position: Vector3(6471000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
      stages: [
        Stage(index: 0, parts: [
          Part(id: const PartId('hull'), name: 'hull', dryMass: 4000, resources: [oreC, powerC, fuelC]),
        ]),
      ],
      landed: true,
    );
    // Fuel-cell-style converter: ore + power -> liquid fuel.
    v.converters.add(const Converter(
      id: 'ore-to-fuel',
      inputsPerSecond: {ResourceType.ore: 2, ResourceType.electricCharge: 10},
      outputsPerSecond: {ResourceType.liquidFuel: 1},
    ));
    return v;
  }

  ResourceContainer res(Vessel v, ResourceType t) =>
      v.allParts.expand((p) => p.resources).firstWhere((r) => r.type == t);

  test('converter turns ore + power into fuel (in-situ resource utilization)', () {
    final v = colonyShip(ore: 100, power: 1000);
    isru.advance(v, dt: 10);
    expect(res(v, ResourceType.liquidFuel).amount, greaterThan(0));
    expect(res(v, ResourceType.ore).amount, lessThan(100));
    expect(res(v, ResourceType.electricCharge).amount, lessThan(1000));
  });

  test('no ore -> no conversion', () {
    final v = colonyShip(ore: 0, power: 1000);
    isru.advance(v, dt: 10);
    expect(res(v, ResourceType.liquidFuel).amount, 0);
  });

  test('no power -> no conversion', () {
    final v = colonyShip(ore: 100, power: 0);
    isru.advance(v, dt: 10);
    expect(res(v, ResourceType.liquidFuel).amount, 0);
  });

  test('conversion stops when the output tank is full', () {
    final v = colonyShip(ore: 1000, power: 5000, fuel: 1000, fuelCap: 1000); // full
    final oreBefore = res(v, ResourceType.ore).amount;
    isru.advance(v, dt: 10);
    // Output full -> no inputs consumed, no waste.
    expect(res(v, ResourceType.ore).amount, oreBefore);
  });

  test('a vessel with no converters does nothing', () {
    final v = colonyShip(ore: 100, power: 1000);
    v.converters.clear();
    isru.advance(v, dt: 10);
    expect(res(v, ResourceType.liquidFuel).amount, 0);
  });
}
