// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where a building is pointless before it is built, said ONCE.
///
/// The flat builder refused an Atmospheric Harvester under a sky with no
/// oxygen in it, and a mine with no ground under it; the independent
/// governor copied the same two rules; the in-world editor had neither. So
/// on reference Mars the editor placed a harvester, charged its ore and said
/// nothing, and the production step (which gates a harvester's run on
/// [CitySim.o2Harvestable]) then ran it at zero for ever: a building that
/// silently makes nothing. Every placement path asks [placementRefusal]
/// instead, so the three cannot drift apart again.
library;

import 'city_building_spec.dart';
import 'city_sim.dart';

/// The placement rules the colony's own mutators do not make (they place
/// anything that fits), and the idle state the same sky rule leaves an
/// already-built harvester in.
extension CitySiteRules on CitySim {
  /// Why [spec] would do nothing wherever it stood on this colony, or null
  /// when it may be built: a harvester where the air holds no oxygen to
  /// draw, a mine on a colony with no ground (an orbital station, a cloud
  /// city). Footprint, cost and unlocks are the callers' own checks.
  String? placementRefusal(CityBuildingSpec spec) {
    if (spec.type == 'o2harvester' && !o2Harvestable) {
      return '${body.name} has no harvestable oxygen — use Electrolysis '
          'instead.';
    }
    if (spec.type == 'mine' && colonyMode != ColonyStyle.open) {
      return colonyMode == ColonyStyle.orbital
          ? 'No surface to mine in orbit.'
          : 'No ground to mine on a cloud city.';
    }
    return null;
  }

  /// Whether a built [spec] stands idle for want of sky: a harvester under
  /// air with too little oxygen (or too little air) to draw, which the
  /// production step runs at zero. Built where the sky fed it, it goes idle
  /// the day the colony's intakes thin the oxygen below 2% — the site sheet
  /// says so rather than report some unrelated colony mood.
  bool idleForSky(CityBuildingSpec spec) =>
      spec.type == 'o2harvester' && !o2Harvestable;
}
