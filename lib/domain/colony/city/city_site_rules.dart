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

import '../../planetary/atmospheric_composition.dart';
import '../../planetary/planet_atmosphere_service.dart';
import '../../planetary/volatile_reservoir.dart';
import 'city_building_spec.dart';
import 'city_sim.dart';

/// The placement rules the colony's own mutators do not make (they place
/// anything that fits), and the idle state the same sky rule leaves an
/// already-built harvester in.
extension CitySiteRules on CitySim {
  /// Why [spec] would do nothing wherever it stood on this colony, or null
  /// when it may be built: a harvester where the air holds no oxygen to
  /// draw, a mine on a colony with no ground (an orbital station, a cloud
  /// city), and the terraforming towers where their gas has nowhere to come
  /// from or go (docs/plans/terraforming.md §4, phase 3): a Regolith Baker
  /// on a world with no carbonates or nitrates in its soil, or off the
  /// ground; a Greenhouse Factory under no sky to hold its agent; a Carbon
  /// Sequestrator under air with no CO2 above the floor it stops at.
  /// Footprint, cost and unlocks are the callers' own checks.
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
    if (spec.type == TerraformTowers.regolithBaker) {
      if (colonyMode != ColonyStyle.open) {
        return 'A Regolith Baker needs ground to bake.';
      }
      if (!VolatileReservoir.hasBakeableStore(body.id.value)) {
        return "${body.name}'s soil holds no carbonates or nitrates to bake.";
      }
    }
    if (spec.type == TerraformTowers.greenhouseFactory &&
        !body.hasAtmosphere) {
      return '${body.name} has no air to hold a greenhouse gas.';
    }
    if (spec.type == TerraformTowers.carbonSequestrator && !hasCo2ToTake) {
      return "There is no CO₂ left in ${body.name}'s air to take out.";
    }
    return null;
  }

  /// Whether the sky holds CO2 above the floor the carbon-removing towers
  /// stop at (`TerraformTuning.co2FloorPa`, a column weight): read off the
  /// body's derived air, so a world already sequestered to the floor stops
  /// offering the building.
  bool get hasCo2ToTake {
    final air = body.atmosphere;
    final mix = body.composition;
    if (air == null || mix == null) return false;
    final x = mix.fractions[AtmosphereGas.carbonDioxide] ?? 0;
    if (x <= 0) return false;
    // Column weight of the CO2: its mole share of the column, by mass.
    final column = air.seaLevelPressure *
        x *
        AtmosphericComposition.molarMass[AtmosphereGas.carbonDioxide]! /
        mix.meanMolecularWeight;
    return column > const TerraformTuning().co2FloorPa;
  }

  /// Whether a built [spec] stands idle for want of sky: a harvester under
  /// air with too little oxygen (or too little air) to draw, which the
  /// production step runs at zero. Built where the sky fed it, it goes idle
  /// the day the colony's intakes thin the oxygen below 2% — the site sheet
  /// says so rather than report some unrelated colony mood.
  bool idleForSky(CityBuildingSpec spec) =>
      spec.type == 'o2harvester' && !o2Harvestable;
}
