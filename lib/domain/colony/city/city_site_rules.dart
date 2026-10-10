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
  /// ground; a Greenhouse Factory under no sky to hold its agent; either
  /// warming tower on a world already as warm as they aim for (Earth,
  /// Venus); a Carbon Sequestrator under air with no CO2 above the floor it
  /// stops at.
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
      // The baker bakes only while the world is colder than the target.
      if (!_colderThanTarget) {
        return '${body.name} is already as warm as Regolith Bakers aim for.';
      }
    }
    if (spec.type == TerraformTowers.greenhouseFactory) {
      if (!body.hasAtmosphere) {
        return '${body.name} has no air to hold a greenhouse gas.';
      }
      // Earth and Venus already stand at or past the warming target, so a
      // factory there would never emit — and still cost its ore, power,
      // hands and smog while the site sheet called it "Operating".
      if (!warmingWanted) {
        return '${body.name} is already as warm as Greenhouse Factories '
            'aim for.';
      }
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

  /// Whether a Greenhouse Factory would ever emit here: the world, every gas
  /// and haze held but WITHOUT any agent, is colder than
  /// `TerraformTuning.warmingTargetK` — what the factories' controller tops
  /// the agent up to (`PlanetAtmosphereService.agentHeadroom`). Judged
  /// without the agent so a world the factories already hold at the target
  /// still counts as wanting them (stop them and it cools); a world warm on
  /// its own — Earth, Venus — never does. Read off the live sky where a host
  /// integrates one ([CitySim.planetAir]), else the body's published air.
  bool get warmingWanted {
    final air = planetAir;
    if (air != null) {
      return air.agentMolesForTemperature(
              const TerraformTuning().warmingTargetK) >
          0;
    }
    return _colderThanTarget;
  }

  /// Whether the world now — agent and all — is colder than the warming
  /// target: the Regolith Baker's own stop
  /// (`PlanetAtmosphereService._warmingWanted`).
  bool get _colderThanTarget {
    final target = const TerraformTuning().warmingTargetK;
    final air = planetAir;
    if (air != null) return air.surfaceTemperatureK < target;
    final t = body.atmosphere?.seaLevelTemperature;
    // No air model at all: an airless world is as cold as its rock.
    return t == null || t < target;
  }

  /// Why a built terraforming tower moves no gas right now though it is
  /// powered and staffed, or null while it works: it has reached the limit
  /// its planetary process stops at (docs/plans/terraforming.md §4). The
  /// colony still runs it at full throttle — the throttle is the colony's,
  /// the stop the planet's — so without this its site sheet read
  /// "Operating — running at full output" over a building that, for its
  /// ore, power and jobs, did nothing at all.
  String? towerIdleReason(CityBuildingSpec spec) {
    switch (spec.type) {
      case TerraformTowers.greenhouseFactory:
        if (!warmingWanted) {
          return '${body.name} is warm enough without any greenhouse agent, '
              'so the factory adds none.';
        }
      case TerraformTowers.regolithBaker:
        if (!_colderThanTarget) {
          return '${body.name} is already as warm as Regolith Bakers aim '
              'for, so the baker frees nothing.';
        }
        if (!_bakeableLeft) {
          return 'The soil has given up every carbonate and nitrate it held.';
        }
      case TerraformTowers.carbonSequestrator:
        final air = planetAir;
        final left = air != null
            ? const PlanetAtmosphereService().co2AboveFloor(air) > 0
            : hasCo2ToTake;
        if (!left) {
          return "${body.name}'s CO₂ is down to the floor the sequestrators "
              'stop at.';
        }
    }
    return null;
  }

  /// Whether any bakeable store still holds gas: the live sky's own stores
  /// where one is integrated, else whether the body has any at all.
  bool get _bakeableLeft {
    final air = planetAir;
    if (air == null) return VolatileReservoir.hasBakeableStore(body.id.value);
    return air.reservoirs.any((r) => r.bakeable && r.moles > 0);
  }

  /// Whether a built [spec] stands idle for want of sky: a harvester under
  /// air with too little oxygen (or too little air) to draw, which the
  /// production step runs at zero. Built where the sky fed it, it goes idle
  /// the day the colony's intakes thin the oxygen below 2% — the site sheet
  /// says so rather than report some unrelated colony mood.
  bool idleForSky(CityBuildingSpec spec) =>
      spec.type == 'o2harvester' && !o2Harvestable;
}
