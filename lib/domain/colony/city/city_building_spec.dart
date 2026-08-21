// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'commodity.dart';

/// Residential / commercial / industrial zone density tiers.
enum Density { low, medium, high }

/// What KIND of site a spec occupies.
///
/// Games routinely draw a nuclear plant and a corner shop at the same size,
/// which is a gameplay compromise for a bounded map. Here land is not the
/// constraint, so these are built at the scale the real thing occupies — and
/// that only works if the generator knows a solar farm is a FIELD of racks and
/// a quarry is a HOLE, not a building with a big footprint.
enum SiteKind {
  /// An enclosed structure: housing, offices, factories, sheds.
  building,

  /// An open installation covering its site — solar arrays, tank farms,
  /// antenna fields. Mostly low, mostly repeating.
  field,

  /// An excavation. The site IS the hole; any buildings are ancillary plant
  /// around its rim.
  pit,

  /// A paved apron: spaceport pads, runways, hardstanding.
  pad,
}

/// A zone kind + density. Higher density grows bigger buildings (more
/// housing/jobs) but needs more services + power.
class CityZoneType {
  final String kind; // 'residential' | 'commercial' | 'industrial'
  final Density density;
  const CityZoneType(this.kind, this.density);
}

/// What a placed/grown colony building does. All flows are per-second over
/// string commodities. Buildings need staffing (jobs filled) and power to run at
/// full output; below either they throttle.
///
/// Pure domain: presentation carries no `IconData` here. The palette colour is
/// kept as a packed ARGB int because it is DATA about the building type (used by
/// the 2D map, the 3D facade tint, and the minimap alike), while the icon is
/// purely a Flutter widget concern and lives in the UI's visuals table.
class CityBuildingSpec {
  /// Which density band a ZONE spec belongs to, read off its type.
  ///
  /// The band is already encoded there — every zoned spec is `r-low`,
  /// `c-med`, `i-high` and so on — and `type` is the canonical identity the
  /// archetype cache and the save format both key on, so it is not going to
  /// drift out from under this. Duplicating the band into a field of its own
  /// would just be a second thing to keep in step.
  ///
  /// Null for the utility catalogue, which is not zoned.
  Density? get zoneDensity {
    if (type.endsWith('-high')) return Density.high;
    if (type.endsWith('-med')) return Density.medium;
    if (type.endsWith('-low')) return Density.low;
    return null;
  }

  final String type;
  final String label;
  final int colorArgb;
  final String group; // palette grouping
  final int housing;
  final int jobs; // workers needed to run at 100%
  final double powerDraw;
  final double powerOutput;
  final double computeDraw; // compute capacity consumed (advanced buildings)
  final double computeOutput; // data centres
  final Map<String, double> inputs; // /s at full output
  final Map<String, double> outputs; // /s at full output
  final Map<String, double> services; // ServiceType.name -> pop served
  final double pollution; // per-second pollution emitted (− = scrubs)
  final int unlockPop; // min city population before it's buildable
  final double buildCost; // ore to build
  final double storageBonus; // +stockpile cap per resource (warehouses)
  final double deathcareRate; // corpses processed /s (morgue/crematorium)
  final int footW; // footprint width in cells (>=1)
  final int footH; // footprint height in cells (>=1)

  /// REAL site size in metres. Zero means "derive it from the cell footprint",
  /// which is what the ordinary street-scale buildings do. The heavy
  /// installations state their true extent here instead, because a fixed grid
  /// cannot express a two-kilometre solar farm and rounding one to the nearest
  /// cell is how these end up comically undersized.
  final double siteWidthM;
  final double siteDepthM;

  final SiteKind siteKind;

  const CityBuildingSpec({
    required this.type,
    required this.label,
    required this.colorArgb,
    required this.group,
    this.housing = 0,
    this.jobs = 0,
    this.powerDraw = 0,
    this.powerOutput = 0,
    this.computeDraw = 0,
    this.computeOutput = 0,
    this.inputs = const {},
    this.outputs = const {},
    this.services = const {},
    this.pollution = 0,
    this.unlockPop = 0,
    this.buildCost = 40,
    this.storageBonus = 0,
    this.deathcareRate = 0,
    this.footW = 1,
    this.footH = 1,
    this.siteWidthM = 0,
    this.siteDepthM = 0,
    this.siteKind = SiteKind.building,
  });

  int get cellCount => footW * footH;

  /// Site extent in metres, falling back to the cell footprint.
  /// Whether this thing brings its own PLOT rather than taking a lot.
  ///
  /// A subdivided street lot is about 24x32 m. The installations that declare
  /// their own extent start at 260 m and run to 3000 m for a quarry — a solar
  /// farm is thirty times wider than a lot and could never fit one, which is
  /// why the build ghost and the placed building disagreed so wildly: the
  /// ghost drew the real site, placement shrank it to the lot. These claim a
  /// parcel of their own instead.
  bool get claimsOwnSite => siteWidthM > 0 || siteDepthM > 0;

  ({double width, double depth}) siteMetres({double cellM = 24}) => (
        width: siteWidthM > 0 ? siteWidthM : footW * cellM,
        depth: siteDepthM > 0 ? siteDepthM : footH * cellM,
      );

  /// Ground area the installation needs, m².
  double siteArea({double cellM = 24}) {
    final s = siteMetres(cellM: cellM);
    return s.width * s.depth;
  }

  double height() {
    if (housing > 0) return 14 + housing * 0.18;
    if (powerOutput > 100) return 22;
    if (jobs >= 30) return 20;
    return 11;
  }
}

/// Grown-building specs per zone kind + density tier (Cities-Skylines RCI).
const Map<String, Map<Density, CityBuildingSpec>> kZoneSpecs = {
  'residential': {
    // Homes barely pollute (heating + cars) — a fraction of industry. Kept
    // tiny so a residential-only colony never trips a critical-air alarm; real
    // pollution comes from industry / power.
    Density.low: CityBuildingSpec(
        type: 'r-low', label: 'Low-Density Homes',
        colorArgb: 0xFF7FE0A0, group: 'res', housing: 20, powerDraw: 2,
        pollution: 0.02),
    Density.medium: CityBuildingSpec(
        type: 'r-med', label: 'Apartments',
        colorArgb: 0xFF7FE0A0, group: 'res', housing: 60, powerDraw: 6,
        pollution: 0.05),
    Density.high: CityBuildingSpec(
        type: 'r-high', label: 'Towers',
        colorArgb: 0xFF7FE0A0, group: 'res', housing: 160, powerDraw: 16,
        pollution: 0.1),
  },
  'commercial': {
    Density.low: CityBuildingSpec(
        type: 'c-low', label: 'Shops',
        colorArgb: 0xFF4FC3F7, group: 'com', jobs: 8, powerDraw: 4,
        services: {'leisure': 60}, pollution: 0.3),
    Density.medium: CityBuildingSpec(
        type: 'c-med', label: 'Mall',
        colorArgb: 0xFF4FC3F7, group: 'com', jobs: 24, powerDraw: 12,
        services: {'leisure': 180}, pollution: 0.6),
    Density.high: CityBuildingSpec(
        type: 'c-high', label: 'Business District',
        colorArgb: 0xFF4FC3F7, group: 'com', jobs: 60, powerDraw: 30,
        computeDraw: 2, services: {'leisure': 400}, pollution: 1.0),
  },
  'industrial': {
    Density.low: CityBuildingSpec(
        type: 'i-low', label: 'Workshops',
        colorArgb: 0xFFE3A857, group: 'ind', jobs: 10, powerDraw: 6,
        inputs: {Commodity.ore: 0.3}, outputs: {Commodity.steel: 0.2},
        pollution: 1.5),
    Density.medium: CityBuildingSpec(
        type: 'i-med', label: 'Factories',
        colorArgb: 0xFFE3A857, group: 'ind', jobs: 28, powerDraw: 16,
        inputs: {Commodity.ore: 1}, outputs: {Commodity.steel: 0.7},
        pollution: 3.0),
    Density.high: CityBuildingSpec(
        type: 'i-high', label: 'Heavy Industry',
        colorArgb: 0xFFE3A857, group: 'ind', jobs: 70, powerDraw: 40,
        inputs: {Commodity.ore: 2.5}, outputs: {Commodity.steel: 2},
        pollution: 6.0),
  },
};

/// All hand-placed utilities/services/factories/military/aerospace, grouped.
/// `unlockPop` gates the advanced ones behind city growth.
const List<CityBuildingSpec> kUtilCatalog = [
  // ---- POWER ----
  // (solar/wind outputs are scaled by the host planet's sun-distance + air.)
  CityBuildingSpec(type: 'solar', label: 'Solar Farm',
      colorArgb: 0xFFFFD23F, group: 'power', powerOutput: 60, buildCost: 40,
      siteWidthM: 780, siteDepthM: 780, siteKind: SiteKind.field),
  CityBuildingSpec(type: 'wind', label: 'Wind Turbine',
      colorArgb: 0xFFB2DFDB, group: 'power', powerOutput: 50, buildCost: 40,
      siteWidthM: 420, siteDepthM: 420, siteKind: SiteKind.field),
  CityBuildingSpec(type: 'gas', label: 'Gas Generator',
      colorArgb: 0xFFFF8A65, group: 'power', powerOutput: 120, jobs: 6,
      inputs: {Commodity.fuel: 0.6}, pollution: 2.5, buildCost: 50,
      siteWidthM: 260, siteDepthM: 200),
  CityBuildingSpec(type: 'reactor', label: 'Fission Reactor',
      colorArgb: 0xFF7FE0A0, group: 'power', powerOutput: 240, jobs: 12,
      unlockPop: 120, buildCost: 80, pollution: 1.0,
      siteWidthM: 1400, siteDepthM: 1100),
  CityBuildingSpec(type: 'fusion', label: 'Fusion Plant',
      colorArgb: 0xFF80D8FF, group: 'power', powerOutput: 800, jobs: 30,
      computeDraw: 4, unlockPop: 600, buildCost: 200,
      siteWidthM: 2200, siteDepthM: 1800),
  // ---- CITY SERVICES ----
  // Aquifer Pump: extracts water from the ground table — cheap + plentiful, but
  // it DRAWS DOWN the water table, drying the surface (and eventually killing
  // the flora) if you over-pump. Special-cased: its water output + drawdown are
  // handled in the sim tick (type 'aquifer').
  CityBuildingSpec(type: 'aquifer', label: 'Aquifer Pump',
      colorArgb: 0xFF4DD0E1, group: 'svc', jobs: 6, powerDraw: 8,
      outputs: {Commodity.water: 1.5}, buildCost: 35),
  CityBuildingSpec(type: 'water', label: 'Water Plant',
      colorArgb: 0xFF26C6DA, group: 'svc', jobs: 8, powerDraw: 12,
      outputs: {Commodity.water: 2.0}, services: {'water': 300}, pollution: 0.5),
  CityBuildingSpec(type: 'farm', label: 'Farm',
      colorArgb: 0xFF8BC34A, group: 'svc', jobs: 10, powerDraw: 4,
      inputs: {Commodity.water: 0.5}, outputs: {Commodity.food: 1.0},
      siteWidthM: 400, siteDepthM: 400, siteKind: SiteKind.field),
  // Industrial Farm: a 2x2 mega-farm. ~4x the yield of a Farm but only ~3x the
  // build cost + ~2.4x the jobs — economy of scale, at the cost of land + sprawl.
  CityBuildingSpec(type: 'farm-big', label: 'Industrial Farm',
      colorArgb: 0xFFAED581, group: 'svc', jobs: 24, powerDraw: 14,
      inputs: {Commodity.water: 1.8}, outputs: {Commodity.food: 4.2},
      pollution: 1.0, unlockPop: 80, buildCost: 110, footW: 2, footH: 2,
      siteWidthM: 1600, siteDepthM: 1600, siteKind: SiteKind.field),
  // Hydroponics: a 1x2 indoor stack. No open ground / sunlight needed (great
  // off-world), but power-hungry and water-fed. Compact, high yield per tile.
  CityBuildingSpec(type: 'hydroponics', label: 'Hydroponics',
      colorArgb: 0xFF66BB6A, group: 'svc', jobs: 14, powerDraw: 22,
      inputs: {Commodity.water: 1.2}, outputs: {Commodity.food: 3.0},
      unlockPop: 120, buildCost: 90, footW: 1, footH: 2),
  // Lab-Grown Meat: a 2x2 cultured-protein plant. Compute + power + water in,
  // dense food out, with some waste — the high-tech end of the food chain.
  CityBuildingSpec(type: 'labmeat', label: 'Lab-Grown Meat',
      colorArgb: 0xFFF48FB1, group: 'svc', jobs: 30, powerDraw: 30,
      computeDraw: 4, inputs: {Commodity.water: 1.5, Commodity.electronics: 0.1},
      outputs: {Commodity.food: 5.0}, pollution: 1.5, unlockPop: 300,
      buildCost: 160, footW: 2, footH: 2),
  // Solar Array: a 2x2 scaled solar farm. ~4.5x a Solar Farm's output for ~3.5x
  // the cost — pack more panels per footprint at a premium.
  CityBuildingSpec(type: 'solar-big', label: 'Solar Array',
      colorArgb: 0xFFFFD23F, group: 'power', powerOutput: 270,
      unlockPop: 60, buildCost: 140, footW: 2, footH: 2,
      siteWidthM: 2000, siteDepthM: 2000, siteKind: SiteKind.field),
  // ---- LIFE SUPPORT: oxygen (only needed off breathable worlds) ----
  CityBuildingSpec(type: 'electrolysis', label: 'Electrolysis Plant',
      colorArgb: 0xFF80DEEA, group: 'svc', jobs: 12,
      powerDraw: 20, inputs: {Commodity.water: 1.0},
      outputs: {Commodity.oxygen: 0.8}, buildCost: 50),
  CityBuildingSpec(type: 'o2harvester', label: 'Atmospheric O₂ Harvester',
      colorArgb: 0xFF4DD0E1, group: 'svc', jobs: 10,
      powerDraw: 15, outputs: {Commodity.oxygen: 2.0}, buildCost: 60),
  CityBuildingSpec(type: 'clinic', label: 'Clinic',
      colorArgb: 0xFFFF8A80, group: 'svc', jobs: 6, powerDraw: 5,
      inputs: {Commodity.medicine: 0.2}, services: {'health': 80}, buildCost: 30),
  CityBuildingSpec(type: 'hospital', label: 'Hospital',
      colorArgb: 0xFFFF6B6B, group: 'svc', jobs: 15, powerDraw: 10,
      inputs: {Commodity.medicine: 0.5}, services: {'health': 200}, unlockPop: 60),
  CityBuildingSpec(type: 'chemist', label: 'Chemist',
      colorArgb: 0xFF9575CD, group: 'svc', jobs: 8, powerDraw: 6,
      inputs: {Commodity.water: 0.3}, outputs: {Commodity.medicine: 0.4},
      buildCost: 40),
  CityBuildingSpec(type: 'pharma', label: 'Pharma Plant',
      colorArgb: 0xFF7E57C2, group: 'svc', jobs: 30, powerDraw: 25,
      computeDraw: 2, inputs: {Commodity.water: 0.5, Commodity.electronics: 0.1},
      outputs: {Commodity.medicine: 1.5}, pollution: 1.0, unlockPop: 200,
      buildCost: 80),
  CityBuildingSpec(type: 'school', label: 'School',
      colorArgb: 0xFF4FC3F7, group: 'svc', jobs: 12, powerDraw: 8,
      services: {'education': 150}),
  CityBuildingSpec(type: 'police', label: 'Police Station',
      colorArgb: 0xFF90A4AE, group: 'svc', jobs: 14, powerDraw: 9,
      services: {'safety': 220}),
  CityBuildingSpec(type: 'park', label: 'Park',
      colorArgb: 0xFF66BB6A, group: 'svc', powerDraw: 2,
      services: {'leisure': 180}),
  // ---- WASTE MANAGEMENT (process garbage + sewage the population generates) ----
  CityBuildingSpec(type: 'landfill', label: 'Landfill',
      colorArgb: 0xFF8D6E63, group: 'waste', jobs: 6, powerDraw: 3,
      inputs: {Commodity.garbage: 2.0}, pollution: 1.5, buildCost: 30,
      siteWidthM: 700, siteDepthM: 700, siteKind: SiteKind.pit),
  CityBuildingSpec(type: 'recycler', label: 'Recycling Center',
      colorArgb: 0xFF66BB6A, group: 'waste', jobs: 18, powerDraw: 14,
      inputs: {Commodity.garbage: 3.0},
      outputs: {Commodity.ore: 0.3, Commodity.steel: 0.2},
      unlockPop: 120, buildCost: 60),
  CityBuildingSpec(type: 'sewage', label: 'Sewage Treatment',
      colorArgb: 0xFF4DB6AC, group: 'waste', jobs: 12, powerDraw: 16,
      inputs: {Commodity.sewage: 3.0}, outputs: {Commodity.water: 1.0},
      pollution: 0.5, buildCost: 50),
  // ---- DEATHCARE (processes corpses; deathcareRate is corpses/sec handled) ----
  CityBuildingSpec(type: 'morgue', label: 'Morgue',
      colorArgb: 0xFF9E9E9E, group: 'death', jobs: 8, powerDraw: 6,
      deathcareRate: 1.5, buildCost: 40),
  CityBuildingSpec(type: 'crematorium', label: 'Crematorium',
      colorArgb: 0xFF757575, group: 'death', jobs: 14, powerDraw: 14,
      deathcareRate: 5.0, pollution: 1.0, unlockPop: 150, buildCost: 70),
  CityBuildingSpec(type: 'cemetery', label: 'Cemetery',
      colorArgb: 0xFF8D9C7A, group: 'death', jobs: 4, powerDraw: 2,
      deathcareRate: 0.8, services: {'leisure': 30}, buildCost: 30),
  // ---- RESOURCES / FACTORIES ----
  CityBuildingSpec(type: 'mine', label: 'Mine',
      colorArgb: 0xFFB388FF, group: 'res-x', jobs: 20, powerDraw: 15,
      outputs: {Commodity.ore: 2}, pollution: 2.0,
      siteWidthM: 420, siteDepthM: 420, siteKind: SiteKind.pit),
  // Quarry: a 5×5 open-pit megamine. ~11x a Mine's ore for ~9x the jobs at a
  // steep land + pollution cost — bulk extraction for big colonies.
  CityBuildingSpec(type: 'mine', label: 'Quarry',
      colorArgb: 0xFF9575CD, group: 'res-x', jobs: 180, powerDraw: 130,
      outputs: {Commodity.ore: 22}, pollution: 14.0, unlockPop: 400,
      buildCost: 360, footW: 5, footH: 5,
      siteWidthM: 3000, siteDepthM: 3000, siteKind: SiteKind.pit),
  CityBuildingSpec(type: 'refinery', label: 'Refinery',
      colorArgb: 0xFFE3A857, group: 'res-x', jobs: 30, powerDraw: 25,
      inputs: {Commodity.ore: 1}, outputs: {Commodity.fuel: 0.4, Commodity.oxidizer: 0.3},
      pollution: 4.0, unlockPop: 80,
      siteWidthM: 900, siteDepthM: 700),
  CityBuildingSpec(type: 'steelmill', label: 'Steel Mill',
      colorArgb: 0xFFBCAAA4, group: 'res-x', jobs: 35, powerDraw: 30,
      inputs: {Commodity.ore: 2}, outputs: {Commodity.steel: 1.5, Commodity.tubes: 0.4},
      pollution: 5.0, unlockPop: 120,
      siteWidthM: 1100, siteDepthM: 800),
  CityBuildingSpec(type: 'electronics', label: 'Electronics Plant',
      colorArgb: 0xFF64FFDA, group: 'res-x', jobs: 40,
      powerDraw: 35, computeDraw: 1,
      inputs: {Commodity.steel: 0.5}, outputs: {Commodity.electronics: 0.6},
      pollution: 2.0, unlockPop: 200),
  // ---- COMPUTE ----
  CityBuildingSpec(type: 'datacenter', label: 'Data Center',
      colorArgb: 0xFF40C4FF, group: 'compute', jobs: 25, powerDraw: 60,
      inputs: {Commodity.electronics: 0.2}, computeOutput: 20,
      pollution: 1.0, unlockPop: 250, buildCost: 120,
      siteWidthM: 520, siteDepthM: 380),
  // ---- AEROSPACE ----
  CityBuildingSpec(type: 'rocketfactory', label: 'Rocket Parts Factory',
      colorArgb: 0xFFFF8A65, group: 'aero', jobs: 50,
      powerDraw: 45, computeDraw: 3,
      inputs: {Commodity.tubes: 0.5, Commodity.electronics: 0.3},
      outputs: {Commodity.rocketParts: 0.4}, pollution: 3.0, unlockPop: 400),
  CityBuildingSpec(type: 'assembly', label: 'Vehicle Assembly Building',
      colorArgb: 0xFFEC407A, group: 'aero',
      jobs: 80, powerDraw: 80, computeDraw: 8,
      inputs: {Commodity.rocketParts: 0.3, Commodity.tubes: 0.2,
        Commodity.electronics: 0.2, Commodity.fuel: 0.5},
      pollution: 2.0, unlockPop: 700, buildCost: 300,
      siteWidthM: 260, siteDepthM: 220),
  // ---- MILITARY ----
  CityBuildingSpec(type: 'gunfactory', label: 'Arms Factory',
      colorArgb: 0xFF8D6E63, group: 'mil', jobs: 35, powerDraw: 25,
      inputs: {Commodity.steel: 0.5, Commodity.electronics: 0.1},
      outputs: {Commodity.guns: 0.3, Commodity.ammo: 1.0},
      pollution: 3.0, unlockPop: 300),
  CityBuildingSpec(type: 'missilefactory', label: 'Missile Plant',
      colorArgb: 0xFFD84315, group: 'mil', jobs: 60, powerDraw: 50,
      computeDraw: 4,
      inputs: {Commodity.tubes: 0.4, Commodity.rocketParts: 0.2,
        Commodity.electronics: 0.2},
      outputs: {Commodity.missiles: 0.15}, pollution: 4.0, unlockPop: 800),
  CityBuildingSpec(type: 'rationsfactory', label: 'Rations Plant',
      colorArgb: 0xFFA1887F, group: 'mil', jobs: 18, powerDraw: 10,
      inputs: {Commodity.food: 1.0}, outputs: {Commodity.rations: 0.8},
      unlockPop: 200),
  CityBuildingSpec(type: 'barracks', label: 'Barracks',
      colorArgb: 0xFF607D8B, group: 'mil', jobs: 30, powerDraw: 12,
      inputs: {Commodity.rations: 0.5, Commodity.guns: 0.05, Commodity.ammo: 0.3},
      services: {'safety': 150}, unlockPop: 300, buildCost: 80),
  CityBuildingSpec(type: 'base', label: 'Military Base',
      colorArgb: 0xFF455A64, group: 'mil', jobs: 80, powerDraw: 40,
      inputs: {Commodity.rations: 1.5, Commodity.fuel: 0.5, Commodity.ammo: 1.0},
      services: {'safety': 400}, unlockPop: 600, buildCost: 200,
      siteWidthM: 1600, siteDepthM: 1600),
  CityBuildingSpec(type: 'gunemplacement', label: 'Gun Emplacement',
      colorArgb: 0xFF6D4C41, group: 'mil', jobs: 8, powerDraw: 6,
      inputs: {Commodity.ammo: 0.5}, services: {'safety': 120}, unlockPop: 400),
  CityBuildingSpec(type: 'silo', label: 'Missile Silo',
      colorArgb: 0xFFBF360C, group: 'mil', jobs: 20, powerDraw: 20,
      computeDraw: 2, inputs: {Commodity.missiles: 0.05},
      unlockPop: 1000, buildCost: 250),
  CityBuildingSpec(type: 'airfield', label: 'Airfield',
      colorArgb: 0xFF78909C, group: 'mil', jobs: 50, powerDraw: 30,
      footW: 1, footH: 10, // a long runway strip
      inputs: {Commodity.fuel: 1.0, Commodity.ammo: 0.5},
      services: {'safety': 200}, unlockPop: 700, buildCost: 200,
      siteWidthM: 300, siteDepthM: 3200, siteKind: SiteKind.pad),
  // ---- STORAGE ----
  CityBuildingSpec(type: 'warehouse', label: 'Warehouse',
      colorArgb: 0xFFA1887F, group: 'storage', powerDraw: 3,
      storageBonus: 500),
  CityBuildingSpec(type: 'silo2', label: 'Silo Cluster',
      colorArgb: 0xFFA1887F, group: 'storage', powerDraw: 6,
      storageBonus: 1500, unlockPop: 300, buildCost: 80),
  // ---- ENVIRONMENT ----
  CityBuildingSpec(type: 'terraformer', label: 'Terraforming Tower',
      colorArgb: 0xFF66BB6A, group: 'env', jobs: 30, powerDraw: 60,
      computeDraw: 4, outputs: {Commodity.oxygen: 0.5}, pollution: -2.0,
      unlockPop: 300, buildCost: 150,
      siteWidthM: 320, siteDepthM: 320),
  CityBuildingSpec(type: 'shelter', label: 'Fallout Shelter',
      colorArgb: 0xFF78909C, group: 'env', housing: 30, powerDraw: 8,
      buildCost: 60),
  // ---- DISASTER PREPAREDNESS ----
  CityBuildingSpec(type: 'warning', label: 'Early-Warning Station',
      colorArgb: 0xFFFFB74D, group: 'prep', jobs: 10,
      powerDraw: 8, computeDraw: 1, unlockPop: 100, buildCost: 50),
  CityBuildingSpec(type: 'bunker', label: 'Bunker',
      colorArgb: 0xFF607D8B, group: 'prep', housing: 50, jobs: 4,
      powerDraw: 6, buildCost: 70),
  CityBuildingSpec(type: 'emergency', label: 'Emergency Services',
      colorArgb: 0xFFEF5350, group: 'prep', jobs: 20,
      powerDraw: 12, inputs: {Commodity.medicine: 0.3},
      services: {'safety': 100, 'health': 60}, unlockPop: 80, buildCost: 60),
  // ---- TRANSPORT ----
  CityBuildingSpec(type: 'transit', label: 'Transit Stop',
      colorArgb: 0xFF7C4DFF, group: 'transport', jobs: 4, powerDraw: 5,
      services: {'leisure': 80}, buildCost: 30),
  CityBuildingSpec(type: 'spaceport', label: 'Spaceport',
      colorArgb: 0xFFEC407A, group: 'transport', jobs: 40, powerDraw: 40,
      inputs: {Commodity.fuel: 1, Commodity.oxidizer: 1},
      outputs: {
        // Life support trickles in on automatic shuttles; ORE only ever arrives
        // via an explicit scheduled delivery, never produced passively.
        Commodity.food: 0.3, Commodity.water: 0.3,
        Commodity.oxygen: 0.3,
      },
      siteWidthM: 900, siteDepthM: 900, siteKind: SiteKind.pad),
  // Bigger spaceports for colonies with many automatic shuttles arriving +
  // departing: more pads (footprint) = more throughput per build. They can be
  // landed ON (occupied state) by the lander.
  CityBuildingSpec(type: 'spaceport', label: 'Spaceport Complex (2×4)',
      colorArgb: 0xFFEC407A, group: 'transport',
      jobs: 110, powerDraw: 110, unlockPop: 200, buildCost: 160,
      footW: 2, footH: 4,
      inputs: {Commodity.fuel: 2.6, Commodity.oxidizer: 2.6},
      outputs: {
        Commodity.food: 0.9, Commodity.water: 0.9,
        Commodity.oxygen: 0.9,
      },
      siteWidthM: 1800, siteDepthM: 2600, siteKind: SiteKind.pad),
  CityBuildingSpec(type: 'spaceport', label: 'Starport (3×6)',
      colorArgb: 0xFFEC407A, group: 'transport',
      jobs: 240, powerDraw: 240, unlockPop: 800, buildCost: 360,
      footW: 3, footH: 6,
      inputs: {Commodity.fuel: 6, Commodity.oxidizer: 6},
      outputs: {
        Commodity.food: 2.2, Commodity.water: 2.2,
        Commodity.oxygen: 2.2,
      },
      siteWidthM: 3200, siteDepthM: 4200, siteKind: SiteKind.pad),
];

const Map<String, String> kGroupLabels = {
  'power': 'POWER',
  'svc': 'CITY SERVICES',
  'waste': 'WASTE MANAGEMENT',
  'death': 'DEATHCARE',
  'res-x': 'RESOURCES & FACTORIES',
  'compute': 'COMPUTE',
  'aero': 'AEROSPACE',
  'mil': 'MILITARY',
  'env': 'ENVIRONMENT',
  'prep': 'DISASTER PREP',
  'storage': 'STORAGE',
  'transport': 'TRANSPORT',
};
