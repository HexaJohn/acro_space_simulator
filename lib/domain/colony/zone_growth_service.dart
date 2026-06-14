import 'building.dart';
import 'city_demand.dart';
import 'colony.dart';

/// Grows a city by spawning buildings into zoned-but-empty cells when there is
/// demand for that zone's type — the Cities-Skylines RCI growth loop. Domain
/// service. Each call fills at most one cell per zone type so cities grow
/// gradually rather than instantly.
///
/// A grown building consumes a slice of its zone-type demand (satisfying need),
/// so demand must be replenished (population pressure, flights) to keep growing.
class ZoneGrowthService {
  /// Demand threshold a zone type must clear before it grows.
  final double growthThreshold;

  /// Demand consumed per building grown.
  final double demandPerBuilding;

  const ZoneGrowthService({
    this.growthThreshold = 0.2,
    this.demandPerBuilding = 0.3,
  });

  void grow(Colony colony, {required double dt}) {
    var demand = colony.demand;

    // Unhappy cities grow slowly or not at all — happiness scales effective
    // demand (a miserable city repels new residents/business).
    final happiness = colony.happiness.clamp(0.0, 1.0);

    for (final type in ZoneType.values) {
      final level = _demandFor(demand, type) * happiness;
      if (level < growthThreshold) continue;

      final cell = _firstEmptyZoneOf(colony, type);
      if (cell == null) continue;

      colony.buildings.add(_buildingFor(type, cell));
      demand = _consume(demand, type, demandPerBuilding);
    }

    colony.demand = demand;
  }

  double _demandFor(CityDemand d, ZoneType t) {
    switch (t) {
      case ZoneType.residential:
        return d.residential;
      case ZoneType.commercial:
        return d.commercial;
      case ZoneType.industrial:
        return d.industrial;
      case ZoneType.spaceport:
      case ZoneType.mining:
        return 0; // grown explicitly, not by RCI demand
    }
  }

  CityDemand _consume(CityDemand d, ZoneType t, double amount) {
    switch (t) {
      case ZoneType.residential:
        return d.copyWith(residential: d.residential - amount);
      case ZoneType.commercial:
        return d.copyWith(commercial: d.commercial - amount);
      case ZoneType.industrial:
        return d.copyWith(industrial: d.industrial - amount);
      case ZoneType.spaceport:
      case ZoneType.mining:
        return d;
    }
  }

  Zone? _firstEmptyZoneOf(Colony colony, ZoneType type) {
    final occupied = {
      for (final b in colony.buildings) '${b.gridX},${b.gridY}',
    };
    for (final z in colony.zones) {
      if (z.type != type) continue;
      if (occupied.contains('${z.gridX},${z.gridY}')) continue;
      return z;
    }
    return null;
  }

  Building _buildingFor(ZoneType type, Zone cell) {
    final id = '${type.name}-${cell.gridX}-${cell.gridY}';
    return Building(id: id, spec: _specFor(type), gridX: cell.gridX, gridY: cell.gridY);
  }

  /// Default building stats per zone type (one tier each for now).
  BuildingSpec _specFor(ZoneType type) {
    switch (type) {
      case ZoneType.residential:
        return const BuildingSpec(type: 'house', housing: 40, powerDraw: 3);
      case ZoneType.commercial:
        return const BuildingSpec(type: 'shop', jobs: 8, powerDraw: 4);
      case ZoneType.industrial:
        return const BuildingSpec(type: 'factory', jobs: 12, powerDraw: 8);
      case ZoneType.spaceport:
        return const BuildingSpec(type: 'pad', jobs: 6, powerDraw: 10);
      case ZoneType.mining:
        return const BuildingSpec(type: 'mine', jobs: 10, powerDraw: 12);
    }
  }
}
