// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Moving goods between a landed craft and a colony.
///
/// This is the seam between the two resource models the sim deliberately keeps
/// apart: vessels carry a small [ResourceType] enum sized for flight, while the
/// colony runs a much richer string-keyed supply chain. They meet here, at the
/// pad, and nowhere else — which is exactly where they meet in reality.
library;

import 'dart:math' as math;

import '../../shared/quaternion.dart';

import '../../vessel/resource_container.dart';
import '../../vessel/vessel.dart';
import 'city_sim.dart';
import 'commodity.dart';

/// Which colony commodity a vessel resource becomes.
///
/// Not every vessel resource has a colony equivalent — monopropellant and
/// electric charge are flight-side only — and a missing entry means "does not
/// unload", not "unloads as zero".
const Map<ResourceType, String> kCommodityForResource = {
  ResourceType.liquidFuel: Commodity.fuel,
  ResourceType.oxidizer: Commodity.oxidizer,
  ResourceType.ore: Commodity.ore,
  ResourceType.water: Commodity.water,
  ResourceType.food: Commodity.food,
  ResourceType.oxygen: Commodity.oxygen,
};

/// What one pad visit moved.
class CargoTransfer {
  const CargoTransfer({
    required this.padId,
    required this.delivered,
    required this.loaded,
  });

  /// The parcel id of the pad the craft was standing on.
  final String padId;

  /// Commodity -> units unloaded into the colony.
  final Map<String, double> delivered;

  /// Commodity -> units loaded back aboard.
  final Map<String, double> loaded;

  bool get isEmpty => delivered.isEmpty && loaded.isEmpty;

  double get totalDelivered =>
      delivered.values.fold(0.0, (a, b) => a + b);
}

class ShuttleCargoService {
  const ShuttleCargoService({
    this.padRadiusM = 60,
    this.keepFuelFraction = 0.35,
  });

  /// How close to a pad's centre a craft must be standing to be serviced.
  final double padRadiusM;

  /// Fraction of a craft's propellant left aboard when unloading.
  ///
  /// Unloading a lander's tanks completely is how a colony gains 40 units of
  /// fuel and strands the shuttle that brought it. The reserve is what it
  /// leaves on to fly home.
  final double keepFuelFraction;

  /// Unload [vessel] into [city] if it is landed on one of the colony's pads.
  ///
  /// Returns null when the craft is not on a pad — which is the common case
  /// every tick, so the cheap checks come first.
  CargoTransfer? unload(
    CitySim city,
    Vessel vessel, {
    required double bodyRadiusM,
    Quaternion bodyOrientation = Quaternion.identity,
  }) {
    if (!vessel.landed) return null;
    if (vessel.dominantBody != city.body.id) return null;

    final padId = _padUnder(city, vessel, bodyRadiusM, bodyOrientation);
    if (padId == null) return null;

    final delivered = <String, double>{};
    for (final part in vessel.allParts) {
      for (final tank in part.resources) {
        final commodity = kCommodityForResource[tank.type];
        if (commodity == null || tank.amount <= 0) continue;

        // Propellant keeps a return reserve; everything else comes off whole.
        final isPropellant = tank.type == ResourceType.liquidFuel ||
            tank.type == ResourceType.oxidizer;
        final reserve =
            isPropellant ? tank.capacity * keepFuelFraction : 0.0;
        final take = math.max(0.0, tank.amount - reserve);
        if (take <= 0) continue;

        // The colony's stockpile is capped, so a delivery into a full store
        // must not vanish — what will not fit stays on the craft.
        final have = city.stock[commodity] ?? 0;
        final room = math.max(0.0, city.stockCap - have);
        final moved = math.min(take, room);
        if (moved <= 0) continue;

        tank.amount -= moved;
        city.stock[commodity] = have + moved;
        delivered[commodity] = (delivered[commodity] ?? 0) + moved;
      }
    }

    if (delivered.isEmpty) return null;
    return CargoTransfer(padId: padId, delivered: delivered, loaded: const {});
  }

  /// The pad the vessel is standing on, or null.
  String? _padUnder(CitySim city, Vessel vessel, double bodyRadiusM,
      Quaternion bodyOrientation) {
    // The craft's position is INERTIAL; a pad is BODY-FIXED. The craft must be
    // rotated into the body frame before directions are compared — comparing
    // raw directions looked fine at epoch zero and drifted with the planet's
    // spin: even the Moon's crawl put a landed shuttle 600 m of false miss
    // from the pad it was standing on within two minutes of sim time.
    final craftDir =
        bodyOrientation.conjugate.rotate(vessel.state.position).normalized;
    for (final (parcel, _) in city.landingPads()) {
      final padBF = city.localToBodyFixed(
        parcel.centroid,
        bodyRadiusM: bodyRadiusM,
      );
      final padDir = padBF.normalized;
      // Small-angle: arc length ~= angle * radius.
      final dot = craftDir.dot(padDir).clamp(-1.0, 1.0);
      final arc = math.acos(dot) * bodyRadiusM;
      if (arc <= padRadiusM) return parcel.id;
    }
    return null;
  }
}
