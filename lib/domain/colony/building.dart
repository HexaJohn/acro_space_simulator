import '../vessel/resource_container.dart';
import 'city_services.dart';

/// What a building does each tick: consume some resources, produce others, and
/// house/employ population. Value object describing a building type.
class BuildingSpec {
  final String type;
  final Map<ResourceType, double> inputsPerSecond;
  final Map<ResourceType, double> outputsPerSecond;
  final int housing; // residents supported
  final int jobs; // workers required to run at full output
  final double powerDraw; // electric charge/s consumed when running
  final double powerOutput; // electric charge/s generated (solar/reactor)

  /// City-service coverage this building provides (citizens served per type).
  final Map<ServiceType, double> services;

  /// Resource units/second this building mines from the body's deposits (city-
  /// scale ISRU/extraction). 0 = not a mine.
  final double miningRate;

  const BuildingSpec({
    required this.type,
    this.inputsPerSecond = const {},
    this.outputsPerSecond = const {},
    this.housing = 0,
    this.jobs = 0,
    this.powerDraw = 0,
    this.powerOutput = 0,
    this.services = const {},
    this.miningRate = 0,
  });

  bool get isPowerPlant => powerOutput > 0;
}

/// A placed building instance in a colony. Entity within the Colony aggregate.
class Building {
  final String id;
  final BuildingSpec spec;

  /// Grid cell it occupies (Cities-Skylines style top-down placement, XY).
  final int gridX;
  final int gridY;

  /// 0..1 — how fully staffed/supplied it is, scaling actual throughput.
  double efficiency;

  Building({
    required this.id,
    required this.spec,
    required this.gridX,
    required this.gridY,
    this.efficiency = 1.0,
  });
}
