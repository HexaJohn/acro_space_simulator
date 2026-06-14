import '../universe/celestial_body.dart';
import '../vessel/resource_container.dart';
import 'building.dart';
import 'city_demand.dart';
import 'city_network.dart';

enum ZoneType { residential, industrial, commercial, spaceport, mining }

/// A zoned grid cell. City-builder layer: the player paints zones, buildings
/// grow within them (top-down XY grid this pass).
class Zone {
  final int gridX;
  final int gridY;
  final ZoneType type;
  const Zone(this.gridX, this.gridY, this.type);
}

/// A surface settlement on a body. Aggregate root for the colony/city context.
/// Owns its zones, buildings, shared resource stockpile, and population, and
/// runs the supply-chain tick that ties them together.
class Colony {
  final String id;
  final String name;
  final BodyId body;
  final double latitude;
  final double longitude;

  final List<Zone> zones;

  /// Growable so the zone-growth service can add buildings over time.
  final List<Building> buildings;

  /// Shared stockpile the buildings draw from / deposit into.
  final Map<ResourceType, ResourceContainer> stockpile;

  int population;

  /// RCI demand gauge; mutated by population pressure and arriving flights.
  CityDemand demand;

  /// City happiness 0..1; raised by services, lowered by shortages.
  double happiness;

  /// Optional road/utility network. When set, disconnected buildings can't
  /// function. Null = no connectivity requirement (legacy colonies).
  CityNetwork? network;

  Colony({
    required this.id,
    required this.name,
    required this.body,
    required this.latitude,
    required this.longitude,
    this.zones = const [],
    List<Building> buildings = const [],
    Map<ResourceType, ResourceContainer>? stockpile,
    this.population = 0,
    this.demand = CityDemand.none,
    this.happiness = 0.5,
  })  : buildings = List<Building>.of(buildings),
        stockpile = stockpile ?? {};

  int get housingCapacity =>
      buildings.fold(0, (s, b) => s + b.spec.housing);
  int get jobs => buildings.fold(0, (s, b) => s + b.spec.jobs);

  /// Available workers — capped by population.
  int get workforce => population < jobs ? population : jobs;

  /// Total electric charge generated per second (solar/reactors).
  double get powerOutput =>
      buildings.fold(0.0, (s, b) => s + b.spec.powerOutput);

  /// Total electric charge demanded per second by power-drawing buildings.
  double get powerDemand =>
      buildings.fold(0.0, (s, b) => s + b.spec.powerDraw);

  /// Fraction of demand the grid can meet, 0..1 (1 = surplus). Brownouts below 1
  /// throttle every powered building's throughput.
  double get powerRatio {
    final demand = powerDemand;
    if (demand <= 0) return 1.0;
    return (powerOutput / demand).clamp(0.0, 1.0);
  }
}
