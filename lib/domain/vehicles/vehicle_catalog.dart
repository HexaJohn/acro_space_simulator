import 'vehicle_part.dart';

/// The roster of ground-vehicle parts — enough to build cars, rovers, crawlers,
/// and walkers. Reference data; the [VehicleAssembler] picks from it.
class VehicleCatalog {
  final Map<String, VehiclePart> _byId;

  VehicleCatalog(Iterable<VehiclePart> parts)
      : _byId = {for (final p in parts) p.id: p};

  Iterable<VehiclePart> get all => _byId.values;
  VehiclePart? byId(String id) => _byId[id];
  Iterable<VehiclePart> inCategory(VehiclePartCategory c) =>
      _byId.values.where((p) => p.category == c);

  factory VehicleCatalog.standard() => VehicleCatalog(const [
        // ---- Chassis ----
        VehiclePart(id: 'chassis-light', name: 'Light Chassis', category: VehiclePartCategory.chassis, dryMass: 300),
        VehiclePart(id: 'chassis-heavy', name: 'Heavy Chassis', category: VehiclePartCategory.chassis, dryMass: 1500),

        // ---- Cabins ----
        VehiclePart(id: 'cabin-1', name: 'Rover Cabin', category: VehiclePartCategory.cabin, dryMass: 400, crewCapacity: 2),
        VehiclePart(id: 'cabin-pressurized', name: 'Pressurized Cabin', category: VehiclePartCategory.cabin, dryMass: 900, crewCapacity: 4),

        // ---- Wheels (car / rover) ----
        VehiclePart(id: 'wheel-road', name: 'Road Wheel', category: VehiclePartCategory.wheel, dryMass: 60, locomotion: LocomotionType.wheeled, terrainCapability: 0.2),
        VehiclePart(id: 'wheel-rover', name: 'Rugged Rover Wheel', category: VehiclePartCategory.wheel, dryMass: 90, locomotion: LocomotionType.wheeled, terrainCapability: 0.5),

        // ---- Tracks (crawler) ----
        VehiclePart(id: 'track-unit', name: 'Track Unit', category: VehiclePartCategory.track, dryMass: 250, locomotion: LocomotionType.tracked, terrainCapability: 0.8),

        // ---- Legs (walker) ----
        VehiclePart(id: 'leg-actuator', name: 'Walker Leg', category: VehiclePartCategory.leg, dryMass: 180, locomotion: LocomotionType.legged, terrainCapability: 0.95),

        // ---- Hover ----
        VehiclePart(id: 'hover-pad', name: 'Hover Pad', category: VehiclePartCategory.wheel, dryMass: 200, locomotion: LocomotionType.hover, terrainCapability: 0.9),

        // ---- Motors ----
        VehiclePart(id: 'motor-electric', name: 'Electric Drive Motor', category: VehiclePartCategory.motor, dryMass: 120, drivePower: 50000, powerDraw: 60000),
        VehiclePart(id: 'motor-heavy', name: 'Heavy Drive Motor', category: VehiclePartCategory.motor, dryMass: 400, drivePower: 250000, powerDraw: 300000),

        // ---- Batteries ----
        VehiclePart(id: 'battery-pack', name: 'Battery Pack', category: VehiclePartCategory.battery, dryMass: 200, batteryCapacity: 5000),

        // ---- Utility ----
        VehiclePart(id: 'cargo-bay', name: 'Cargo Bay', category: VehiclePartCategory.cargoBay, dryMass: 150, cargoCapacity: 2000),
        VehiclePart(id: 'science-bay', name: 'Mobile Lab', category: VehiclePartCategory.scienceBay, dryMass: 250),
      ]);
}
