import 'package:acro_space_simulator/domain/vehicles/vehicle_catalog.dart';
import 'package:acro_space_simulator/domain/vehicles/vehicle_part.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final catalog = VehicleCatalog.standard();

  test('catalog covers wheels, tracks, legs, chassis, motors, and cabins', () {
    final cats = catalog.all.map((p) => p.category).toSet();
    for (final c in [
      VehiclePartCategory.chassis,
      VehiclePartCategory.wheel,
      VehiclePartCategory.track,
      VehiclePartCategory.leg,
      VehiclePartCategory.motor,
      VehiclePartCategory.cabin,
      VehiclePartCategory.battery,
    ]) {
      expect(cats, contains(c), reason: '$c missing');
    }
  });

  test('locomotion parts declare a locomotion type', () {
    final wheel = catalog.all.firstWhere((p) => p.category == VehiclePartCategory.wheel);
    expect(wheel.locomotion, LocomotionType.wheeled);
    final leg = catalog.all.firstWhere((p) => p.category == VehiclePartCategory.leg);
    expect(leg.locomotion, LocomotionType.legged);
  });

  test('every part has positive mass and a unique id', () {
    final ids = <String>{};
    for (final p in catalog.all) {
      expect(p.dryMass, greaterThan(0));
      expect(ids.add(p.id), isTrue, reason: 'dup ${p.id}');
    }
  });

  test('there are car, rover, crawler, and walker-grade options', () {
    // A light fast wheel (car), rugged wheel/track (rover/crawler), legs (walker).
    expect(catalog.all.any((p) => p.category == VehiclePartCategory.wheel), isTrue);
    expect(catalog.all.any((p) => p.category == VehiclePartCategory.track), isTrue);
    expect(catalog.all.any((p) => p.category == VehiclePartCategory.leg), isTrue);
  });
}
