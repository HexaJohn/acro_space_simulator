import '../shared/vector3.dart';
import '../vessel/docking_port.dart';
import '../vessel/propulsion.dart';
import '../vessel/resource_container.dart';
import 'jet_engine.dart';
import 'lifting_surface.dart';

enum PartCategory {
  commandPod, // crewed control + reaction wheels
  fuelTank,
  rocketEngine,
  jetEngine,
  intake, // feeds air to jet engines
  wing, // lifting surface
  controlSurface, // movable lifting surface (aileron/elevator/rudder)
  structural,
  decoupler, // stage separation
  landingGear,
  parachute,
  science,
  rcsThruster,
  heatShield,
}

/// A catalog template for a part: the immutable spec the [VesselAssembler]
/// stamps into a concrete [Part]/sub-part when assembling a craft. One [PartDef]
/// can describe a rocket part, an aircraft part, or a utility part depending on
/// which optional capability it carries.
class PartDef {
  final String id;
  final String name;
  final PartCategory category;
  final double dryMass; // kg

  /// Bounding size (m), used for inertia + stacking. (x,y,z).
  final Vector3 size;

  /// Drag profile.
  final double dragCoefficient;
  final double crossSectionArea; // m^2
  final double maxTemperature; // K

  // Optional capabilities — at most one of the engine kinds is set.
  final Engine? rocketEngine;
  final JetEngine? jetEngine;
  final LiftingSurface? wing;
  final List<ResourceContainer> resources; // tanks, monoprop, etc.
  final DockingPort? dockingPort;
  final double intakeArea; // air provided to jets (intake parts)
  final int crewCapacity; // command pods
  final double ablator; // heat shields

  const PartDef({
    required this.id,
    required this.name,
    required this.category,
    required this.dryMass,
    this.size = const Vector3(1, 1, 1),
    this.dragCoefficient = 0.2,
    this.crossSectionArea = 1.0,
    this.maxTemperature = 2000,
    this.rocketEngine,
    this.jetEngine,
    this.wing,
    this.resources = const [],
    this.dockingPort,
    this.intakeArea = 0,
    this.crewCapacity = 0,
    this.ablator = 0,
  });

  bool get isEngine => rocketEngine != null || jetEngine != null;
}

/// A [PartDef] placed at a position/orientation within a craft being assembled.
class PlacedPart {
  final PartDef def;
  final String instanceId;
  final Vector3 position; // m, relative to the craft origin
  final int stage; // staging group index

  const PlacedPart({
    required this.def,
    required this.instanceId,
    this.position = Vector3.zero,
    this.stage = 0,
  });
}
