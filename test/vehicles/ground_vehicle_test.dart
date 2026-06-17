import 'package:acro_space_simulator/domain/vehicles/ground_vehicle.dart';
import 'package:acro_space_simulator/domain/vehicles/vehicle_assembler.dart';
import 'package:acro_space_simulator/domain/vehicles/vehicle_catalog.dart';
import 'package:acro_space_simulator/domain/vehicles/vehicle_part.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final catalog = VehicleCatalog.standard();
  const assembler = VehicleAssembler();
  const movement = GroundVehicleMovement();

  GroundVehicle car() => assembler.assemble(id: 'car', name: 'Buggy', partIds: [
        'chassis-light', 'cabin-1', 'motor-electric',
        'wheel-road', 'wheel-road', 'wheel-road', 'wheel-road',
        'battery-pack',
      ], catalog: catalog);

  GroundVehicle walker() => assembler.assemble(id: 'walker', name: 'Strider', partIds: [
        'chassis-heavy', 'cabin-pressurized', 'motor-heavy',
        'leg-actuator', 'leg-actuator', 'leg-actuator', 'leg-actuator',
        'battery-pack', 'battery-pack',
      ], catalog: catalog);

  test('an assembled car has wheeled locomotion, mass, and drive power', () {
    final v = car();
    expect(v.locomotion, LocomotionType.wheeled);
    expect(v.mass, greaterThan(0));
    expect(v.totalDrivePower, greaterThan(0));
    expect(v.crewCapacity, greaterThan(0));
  });

  test('a walker uses legged locomotion and crosses rough terrain', () {
    final v = walker();
    expect(v.locomotion, LocomotionType.legged);
    expect(v.terrainCapability, greaterThan(0.8));
  });

  test('a car is faster than a walker on smooth ground', () {
    final carSpeed = movement.speedOnTerrain(car(), roughness: 0.1);
    final walkerSpeed = movement.speedOnTerrain(walker(), roughness: 0.1);
    expect(carSpeed, greaterThan(walkerSpeed));
  });

  test('a car bogs down (stops) on terrain rougher than its wheels handle', () {
    final v = car();
    final speed = movement.speedOnTerrain(v, roughness: 0.9); // very rough
    expect(speed, 0); // beyond wheel terrain capability
  });

  test('a walker keeps moving on terrain that stops a car', () {
    final w = walker();
    expect(movement.speedOnTerrain(w, roughness: 0.9), greaterThan(0));
  });

  test('a heavier vehicle is slower for the same drive power', () {
    final light = car();
    final heavy = walker();
    // On terrain both can handle, more mass per watt -> less speed.
    final lightSpeed = movement.speedOnTerrain(light, roughness: 0.1);
    final heavySpeed = movement.speedOnTerrain(heavy, roughness: 0.1);
    expect(lightSpeed, greaterThan(heavySpeed));
  });
}
