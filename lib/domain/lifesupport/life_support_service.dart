import '../simulation/domain_event.dart';
import '../vessel/resource_container.dart';
import '../vessel/vessel.dart';

/// Consumes a crew's life-support resources each tick and kills the crew when a
/// vital resource runs out (raising [CrewLost]). Domain service.
///
/// A vital resource (oxygen, food, water) that can't meet the full per-tick
/// demand is fatal — there is no partial survival. Whatever is available is
/// still drawn so stores deplete realistically.
class LifeSupportService {
  const LifeSupportService();

  void update(Vessel vessel, {required double dt}) {
    final crew = vessel.crew;
    if (crew == null || crew.count <= 0) return;

    final demands = <ResourceType, double>{
      ResourceType.oxygen: crew.oxygenPerCrewPerSecond * crew.count * dt,
      ResourceType.food: crew.foodPerCrewPerSecond * crew.count * dt,
      ResourceType.water: crew.waterPerCrewPerSecond * crew.count * dt,
    };

    for (final entry in demands.entries) {
      final demand = entry.value;
      if (demand <= 0) continue;
      final drawn = _drawAcross(vessel, entry.key, demand);
      if (drawn < demand - 1e-9) {
        // Vital resource exhausted — lose the crew.
        crew.count = 0;
        vessel.raise(CrewLost(vessel.id, entry.key.name));
        return;
      }
    }
  }

  /// Draw up to [amount] of [type] across all of the vessel's containers.
  /// Returns the total actually drawn.
  double _drawAcross(Vessel vessel, ResourceType type, double amount) {
    var remaining = amount;
    var drawn = 0.0;
    for (final part in vessel.allParts) {
      if (remaining <= 0) break;
      for (final c in part.resources) {
        if (c.type != type) continue;
        final took = c.draw(remaining);
        drawn += took;
        remaining -= took;
        if (remaining <= 0) break;
      }
    }
    return drawn;
  }
}
