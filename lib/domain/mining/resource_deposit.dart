// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

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

  ResourceDeposit({
    required this.id,
    required this.body,
    required this.latitude,
    required this.longitude,
    required this.resource,
    required this.concentration,
    this.reserves,
  });

  bool get isDepleted => reserves != null && reserves! <= 0;

  /// Remove up to [units]; returns the amount actually extracted (respecting
  /// finite reserves). Invariant: reserves never go negative.
  double extract(double units) {
    if (reserves == null) return units; // infinite
    final taken = units.clamp(0, reserves!).toDouble();
    reserves = reserves! - taken;
    return taken;
  }
}
