import '../colony/colony.dart';
import '../vessel/resource_container.dart';

/// Advances a colony's farms: crops photosynthesize (need sunlight) and drink
/// water to grow; at maturity they harvest into the food stockpile and replant.
/// Domain service — the agriculture loop that feeds a city's population off-Earth.
///
/// Growth per tick scales with sunlight (no light → no growth) and requires the
/// crop's water draw; a field with no water available doesn't grow that tick.
class FarmingService {
  const FarmingService();

  void advance(Colony colony, {required double dt, required double sunlightFraction}) {
    if (sunlightFraction <= 0) return; // night/eclipse: no photosynthesis
    final days = dt / 86400.0;
    final water = colony.stockpile[ResourceType.water];

    for (final farm in colony.farms) {
      final waterNeed = farm.crop.waterPerAreaPerDay * farm.area * days;
      if (water != null && waterNeed > 0) {
        final drawn = water.draw(waterNeed);
        if (drawn < waterNeed * 0.999) continue; // not enough water -> no growth
      } else if (waterNeed > 0) {
        continue; // no water store at all
      }

      // Advance growth proportional to sunlight over the crop's growth period.
      farm.growth += sunlightFraction.clamp(0.0, 1.0) * days / farm.crop.growthDays;

      if (farm.isMature) {
        final food = colony.stockpile[ResourceType.food];
        food?.fill(farm.harvestYield);
        farm.growth = 0; // replant
      }
    }
  }
}
