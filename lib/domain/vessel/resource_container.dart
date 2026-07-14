// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

/// Kinds of bulk resource a part can store or consume. Extended freely as the
/// economy/mining contexts grow (ore, water, monoprop, ...).
enum ResourceType {
  liquidFuel,
  oxidizer,
  monopropellant,
  electricCharge,
  ore,
  water,
  food,
  oxygen,
}

/// A finite store of one resource inside a part. Entity within the Vessel
/// aggregate (mutated only through the aggregate root). Mass of contents feeds
/// the vessel's mass properties, so draining fuel lightens the ship.
class ResourceContainer {
  final ResourceType type;
  final double capacity; // units
  double amount; // current units
  final double unitMass; // kg per unit

  ResourceContainer({
    required this.type,
    required this.capacity,
    required this.amount,
    required this.unitMass,
  });

  double get fraction => capacity == 0 ? 0 : amount / capacity;
  double get mass => amount * unitMass;
  bool get isEmpty => amount <= 0;

  /// Draw up to [request] units; returns how much was actually drawn.
  double draw(double request) {
    final taken = request.clamp(0, amount).toDouble();
    amount -= taken;
    return taken;
  }

  /// Add up to remaining capacity; returns the overflow that didn't fit.
  double fill(double units) {
    final space = capacity - amount;
    final added = units.clamp(0, space).toDouble();
    amount += added;
    return units - added;
  }
}
