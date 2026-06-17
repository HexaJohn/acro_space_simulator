import 'vehicle_part.dart';

/// An assembled ground vehicle — car, rover, crawler, or walker — baked into a
/// single rigid unit. Aggregate root for the vehicles context.
class GroundVehicle {
  final String id;
  final String name;
  final double mass; // kg, total
  final LocomotionType locomotion;
  final double terrainCapability; // 0..1 max roughness it crosses
  final double totalDrivePower; // W
  final double powerDraw; // W at full drive
  final int crewCapacity;
  final double cargoCapacity;

  /// Locomotion-type speed ceiling (m/s) on ideal ground.
  final double baseTopSpeed;

  const GroundVehicle({
    required this.id,
    required this.name,
    required this.mass,
    required this.locomotion,
    required this.terrainCapability,
    required this.totalDrivePower,
    required this.powerDraw,
    required this.crewCapacity,
    required this.cargoCapacity,
    required this.baseTopSpeed,
  });
}

/// Computes how fast a [GroundVehicle] can travel over terrain of a given
/// roughness (0 = glass-smooth, 1 = impassable boulders). Domain service.
///
/// If the roughness exceeds the vehicle's [terrainCapability] it can't move at
/// all (it bogs/high-centres). Otherwise speed = base top speed, scaled by the
/// power-to-mass ratio and reduced as roughness approaches the capability limit.
class GroundVehicleMovement {
  const GroundVehicleMovement();

  double speedOnTerrain(GroundVehicle v, {required double roughness}) {
    final r = roughness.clamp(0.0, 1.0);
    if (r > v.terrainCapability) return 0; // can't cross it

    // Power-to-mass factor (heavier vehicle is slower for the same drive).
    final powerToMass = v.mass <= 0 ? 0.0 : v.totalDrivePower / v.mass;
    final pmFactor = (powerToMass / 50.0).clamp(0.1, 1.0); // normalize ~50 W/kg

    // Terrain penalty: speed falls off as roughness nears the capability limit.
    final headroom = v.terrainCapability <= 0 ? 0.0 : (1.0 - r / v.terrainCapability);
    final terrainFactor = headroom.clamp(0.1, 1.0);

    return v.baseTopSpeed * pmFactor * terrainFactor;
  }
}
