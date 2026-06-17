import 'ground_vehicle.dart';
import 'vehicle_catalog.dart';
import 'vehicle_part.dart';

/// Bakes a list of catalog part ids into a single [GroundVehicle], aggregating
/// mass, locomotion, drive power, terrain capability, crew, and cargo. Domain
/// service — the rover/walker equivalent of the spacecraft VesselAssembler.
class VehicleAssembler {
  const VehicleAssembler();

  /// Base top speed (m/s) by locomotion type on ideal ground.
  static const Map<LocomotionType, double> _baseTopSpeed = {
    LocomotionType.wheeled: 30, // ~110 km/h
    LocomotionType.tracked: 12,
    LocomotionType.legged: 6,
    LocomotionType.hover: 40,
  };

  GroundVehicle assemble({
    required String id,
    required String name,
    required List<String> partIds,
    required VehicleCatalog catalog,
  }) {
    var mass = 0.0;
    var drivePower = 0.0;
    var powerDraw = 0.0;
    var crew = 0;
    var cargo = 0.0;

    // Locomotion: the dominant locomotion among the locomotion parts (most
    // numerous); terrain capability = best (max) among them.
    final locoCounts = <LocomotionType, int>{};
    var bestTerrain = 0.0;

    for (final pid in partIds) {
      final part = catalog.byId(pid);
      if (part == null) continue;
      mass += part.dryMass;
      drivePower += part.drivePower;
      powerDraw += part.powerDraw;
      crew += part.crewCapacity;
      cargo += part.cargoCapacity;
      if (part.locomotion != null) {
        locoCounts[part.locomotion!] = (locoCounts[part.locomotion!] ?? 0) + 1;
        if (part.terrainCapability > bestTerrain) bestTerrain = part.terrainCapability;
      }
    }

    final locomotion = locoCounts.isEmpty
        ? LocomotionType.wheeled
        : (locoCounts.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .first
            .key;

    return GroundVehicle(
      id: id,
      name: name,
      mass: mass,
      locomotion: locomotion,
      terrainCapability: bestTerrain,
      totalDrivePower: drivePower,
      powerDraw: powerDraw,
      crewCapacity: crew,
      cargoCapacity: cargo,
      baseTopSpeed: _baseTopSpeed[locomotion] ?? 20,
    );
  }
}
