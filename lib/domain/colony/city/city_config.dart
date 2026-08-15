// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../../planetary/planet_surface.dart';

/// Starting parameters for a colony, chosen on the new-city setup screen. All
/// optional — omitted fields fall back to [CitySim]'s defaults (Earth, etc.).
///
/// Lives in the domain rather than beside the screen because founding a colony
/// is a world action: the authoritative sim can seed one from a saved config
/// with no UI in the process.
class CityConfig {
  final int gridSize; // cells per side at start
  final String? bodyId; // host CelestialBody id (e.g. 'earth', 'mars')
  final Biome? biome;
  final int? govtIndex; // index into Govt.values
  final int? economyIndex; // index into Economy.values
  final int? colonyModeIndex; // index into ColonyStyle.values
  final double? latitude, longitude; // colony site on the host body (degrees)
  final double? complexity, hostility, forgiveness, bounty; // 0..1 each

  const CityConfig({
    this.gridSize = 20,
    this.bodyId,
    this.biome,
    this.govtIndex,
    this.economyIndex,
    this.colonyModeIndex,
    this.latitude,
    this.longitude,
    this.complexity,
    this.hostility,
    this.forgiveness,
    this.bounty,
  });
}
