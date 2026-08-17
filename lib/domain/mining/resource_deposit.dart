// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../universe/celestial_body.dart';
import '../vessel/resource_container.dart';

/// A minable concentration of a resource at a surface location on a body.
/// Aggregate root for the mining context. Depletes as it is harvested.
class ResourceDeposit {
  final String id;
  final BodyId body;
  final double latitude; // rad
  final double longitude; // rad
  final ResourceType resource;

  /// Concentration 0..1 — scales extraction rate (ore richness).
  final double concentration;

  /// Remaining reserves in resource units; null = effectively infinite.
  double? reserves;

  /// Lifetime units taken out of the ground here, by anyone — vessel rigs and
  /// city mining both funnel through [extract]. PERSISTED: the excavation pit
  /// at the site is re-derived deterministically from this total, so a loaded
  /// save re-digs the same hole without storing any terrain brushes.
  double extractedTotal;

  /// How many excavation quanta have already been carved into the terrain for
  /// this deposit. TRANSIENT bookkeeping for `DepositExcavation` — starts at 0
  /// each session so the pit is reconstructed from [extractedTotal].
  int carvedQuanta;

  ResourceDeposit({
    required this.id,
    required this.body,
    required this.latitude,
    required this.longitude,
    required this.resource,
    required this.concentration,
    this.reserves,
    this.extractedTotal = 0,
    this.carvedQuanta = 0,
  });

  bool get isDepleted => reserves != null && reserves! <= 0;

  /// Remove up to [units]; returns the amount actually extracted (respecting
  /// finite reserves). Invariant: reserves never go negative.
  double extract(double units) {
    if (reserves == null) {
      extractedTotal += units; // infinite
      return units;
    }
    final taken = units.clamp(0, reserves!).toDouble();
    reserves = reserves! - taken;
    extractedTotal += taken;
    return taken;
  }
}
