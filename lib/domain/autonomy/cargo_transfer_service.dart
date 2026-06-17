import '../colony/colony.dart';
import '../megastructure/megastructure.dart';
import '../vessel/resource_container.dart';
import '../vessel/vessel.dart';

/// Moves resource from a vessel's holds into a colony stockpile (and back) —
/// the delivery step that closes the autonomous cargo loop. Domain service.
///
/// Respects both the vessel's available cargo and the colony's storage
/// capacity; overflow that won't fit stays aboard the vessel.
class CargoTransferService {
  const CargoTransferService();

  /// Unload all [type] cargo from [vessel] into [colony]'s stockpile. Returns
  /// the amount actually transferred.
  double unload(Vessel vessel, Colony colony, ResourceType type) {
    final sink = colony.stockpile[type];
    if (sink == null) return 0;

    var total = 0.0;
    for (final part in vessel.allParts) {
      for (final hold in part.resources) {
        if (hold.type != type || hold.isEmpty) continue;
        // Pull from the hold, push into the stockpile; overflow goes back.
        final taken = hold.draw(hold.amount);
        final overflow = sink.fill(taken);
        if (overflow > 0) hold.fill(overflow); // didn't fit — keep aboard
        total += taken - overflow;
      }
    }
    return total;
  }

  /// Load [units] of [type] from a colony stockpile into the vessel's holds.
  /// Returns the amount actually loaded.
  double load(Vessel vessel, Colony colony, ResourceType type, double units) {
    final source = colony.stockpile[type];
    if (source == null) return 0;

    var remaining = source.draw(units);
    var loaded = 0.0;
    for (final part in vessel.allParts) {
      if (remaining <= 0) break;
      for (final hold in part.resources) {
        if (hold.type != type) continue;
        final overflow = hold.fill(remaining);
        loaded += remaining - overflow;
        remaining = overflow;
      }
    }
    // Anything that didn't fit goes back to the colony.
    if (remaining > 0) source.fill(remaining);
    return loaded;
  }

  /// Unload a vessel's ore/material cargo onto a megastructure build site,
  /// converting it to delivered structural mass. Returns kg delivered. This is
  /// the ONLY way material reaches a megastructure — it must be flown in.
  double deliverToSite(Vessel vessel, Megastructure structure,
      {double massPerUnit = 1000}) {
    var deliveredUnits = 0.0;
    for (final part in vessel.allParts) {
      for (final hold in part.resources) {
        if (hold.type != ResourceType.ore || hold.isEmpty) continue;
        deliveredUnits += hold.draw(hold.amount);
      }
    }
    final kg = deliveredUnits * massPerUnit;
    structure.deliverMaterial(kg);
    return kg;
  }
}
