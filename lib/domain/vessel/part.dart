import '../dynamics/mass_properties.dart';
import '../shared/vector3.dart';
import 'docking_port.dart';
import 'propulsion.dart';
import 'resource_container.dart';

class PartId {
  final String value;
  const PartId(this.value);
  @override
  bool operator ==(Object other) => other is PartId && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => 'PartId($value)';
}

/// A component of a vessel — tank, engine, structural, command, etc. Entity
/// inside the Vessel aggregate; never referenced from outside the aggregate.
///
/// Holds its dry mass and any resource containers; live mass is dry + contents.
/// Thermal state lives in the thermal context keyed by [id], keeping physics
/// concerns separated from structure.
class Part {
  final PartId id;
  final String name;
  final double dryMass; // kg
  final Vector3 positionInVessel; // m, body frame
  final Vector3 inertiaContribution; // kg*m^2 diagonal at this part

  final Engine? engine;
  final List<ResourceContainer> resources;
  final DockingPort? dockingPort;

  /// Max temperature before the part is destroyed (thermal context enforces).
  final double maxTemperature; // K
  final double dragCoefficient; // contributes to vessel aero
  final double crossSectionArea; // m^2

  Part({
    required this.id,
    required this.name,
    required this.dryMass,
    this.positionInVessel = Vector3.zero,
    this.inertiaContribution = Vector3.zero,
    this.engine,
    this.resources = const [],
    this.dockingPort,
    this.maxTemperature = 2000,
    this.dragCoefficient = 0.2,
    this.crossSectionArea = 1.0,
  });

  double get resourceMass =>
      resources.fold(0.0, (sum, r) => sum + r.mass);

  double get mass => dryMass + resourceMass;

  bool get isEngine => engine != null;

  MassProperties get massProperties => MassProperties(
        mass: mass,
        centerOfMass: positionInVessel,
        inertia: inertiaContribution,
      );

  /// First container of [type] with fuel left, or null.
  ResourceContainer? containerFor(ResourceType type) {
    for (final r in resources) {
      if (r.type == type && !r.isEmpty) return r;
    }
    return null;
  }
}
