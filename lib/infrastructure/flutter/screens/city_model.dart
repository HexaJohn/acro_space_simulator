import 'package:flutter/material.dart';

/// Self-contained economy model for the city builder. Uses STRING-keyed
/// commodities (not the domain ResourceType enum) so the city can have its own
/// rich supply chain — military goods, advanced manufacturing inputs, compute —
/// without bloating the core domain. The flight sim keeps using ResourceType;
/// this is a UI-layer economic game on top of the [Colony] aggregate.

/// Bulk commodities the city produces, stores, and consumes.
class Commodity {
  // Raw / basic
  static const ore = 'ore';
  static const water = 'water';
  static const food = 'food';
  static const oxygen = 'oxygen';
  static const medicine = 'medicine';
  static const garbage = 'garbage'; // solid waste backlog
  static const sewage = 'sewage'; // wastewater backlog
  static const fuel = 'fuel';
  static const oxidizer = 'oxidizer';
  // Manufacturing intermediates (overlap civilian + military + aerospace)
  static const steel = 'steel'; // ore -> steel
  static const electronics = 'electronics'; // computers/chips
  static const compute = 'compute'; // data-centre output (a live capacity)
  static const tubes = 'tubes'; // structural tubing (rockets + weapons)
  static const rocketParts = 'rocketParts'; // engines/avionics for craft
  // Military
  static const guns = 'guns';
  static const ammo = 'ammo';
  static const rations = 'rations'; // packaged military food
  static const missiles = 'missiles';

  /// Display order for the stockpile panel.
  static const ordered = [
    ore, steel, water, food, oxygen, rations, fuel, oxidizer,
    electronics, compute, tubes, rocketParts, medicine,
    guns, ammo, missiles,
    garbage, sewage,
  ];

  static const Map<String, String> label = {
    ore: 'Ore', steel: 'Steel', water: 'Water', food: 'Food',
    oxygen: 'Oxygen', medicine: 'Medicine', rations: 'Rations', fuel: 'Fuel',
    oxidizer: 'Oxidizer',
    electronics: 'Electronics', compute: 'Compute', tubes: 'Tubes',
    rocketParts: 'Rocket Parts', guns: 'Guns', ammo: 'Ammo',
    missiles: 'Missiles',
    garbage: 'Garbage', sewage: 'Sewage',
  };

  static String name(String c) => label[c] ?? c;

  /// Stockpile section a commodity belongs to: raw extracted resources,
  /// intermediate manufacturing components, or finished/military goods.
  static const _raw = {ore, water, food, oxygen, fuel, oxidizer};
  static const _components = {steel, electronics, compute, tubes, rocketParts, medicine};
  static const _waste = {garbage, sewage};
  static String section(String c) {
    if (_raw.contains(c)) return 'RAW RESOURCES';
    if (_components.contains(c)) return 'COMPONENTS';
    if (_waste.contains(c)) return 'WASTE';
    return 'FINISHED GOODS';
  }

  static const sections = [
    'RAW RESOURCES', 'COMPONENTS', 'FINISHED GOODS', 'WASTE'
  ];
}

/// Residential / commercial / industrial zone density tiers.
enum Density { low, medium, high }

/// A zone kind + density. Higher density grows bigger buildings (more
/// housing/jobs) but needs more services + power.
class ZoneType {
  final String kind; // 'residential' | 'commercial' | 'industrial'
  final Density density;
  const ZoneType(this.kind, this.density);
}

/// What a placed/grown building does. All flows are per-second over string
/// commodities. Buildings need staffing (jobs filled) + power to run at full
/// output; below that they throttle.
class CitySpec {
  final String type;
  final String label;
  final IconData icon;
  final Color color;
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

  const CitySpec({
    required this.type,
    required this.label,
    required this.icon,
    required this.color,
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
  });

  int get cellCount => footW * footH;

  double height() {
    if (housing > 0) return 14 + housing * 0.18;
    if (powerOutput > 100) return 22;
    if (jobs >= 30) return 20;
    return 11;
  }
}

/// Grown-building specs per zone kind + density tier (Cities-Skylines RCI).
const Map<String, Map<Density, CitySpec>> kZoneSpecs = {
  'residential': {
    // Homes barely pollute (heating + cars) — a fraction of industry. Kept
    // tiny so a residential-only colony never trips a critical-air alarm; real
    // pollution comes from industry / power.
    Density.low: CitySpec(
        type: 'r-low', label: 'Low-Density Homes', icon: Icons.house,
        color: Color(0xFF7FE0A0), group: 'res', housing: 20, powerDraw: 2,
        pollution: 0.02),
    Density.medium: CitySpec(
        type: 'r-med', label: 'Apartments', icon: Icons.apartment,
        color: Color(0xFF7FE0A0), group: 'res', housing: 60, powerDraw: 6,
        pollution: 0.05),
    Density.high: CitySpec(
        type: 'r-high', label: 'Towers', icon: Icons.location_city,
        color: Color(0xFF7FE0A0), group: 'res', housing: 160, powerDraw: 16,
        pollution: 0.1),
  },
  'commercial': {
    Density.low: CitySpec(
        type: 'c-low', label: 'Shops', icon: Icons.store,
        color: Color(0xFF4FC3F7), group: 'com', jobs: 8, powerDraw: 4,
        services: {'leisure': 60}, pollution: 0.3),
    Density.medium: CitySpec(
        type: 'c-med', label: 'Mall', icon: Icons.local_mall,
        color: Color(0xFF4FC3F7), group: 'com', jobs: 24, powerDraw: 12,
        services: {'leisure': 180}, pollution: 0.6),
    Density.high: CitySpec(
        type: 'c-high', label: 'Business District', icon: Icons.business,
        color: Color(0xFF4FC3F7), group: 'com', jobs: 60, powerDraw: 30,
        computeDraw: 2, services: {'leisure': 400}, pollution: 1.0),
  },
  'industrial': {
    Density.low: CitySpec(
        type: 'i-low', label: 'Workshops', icon: Icons.handyman,
        color: Color(0xFFE3A857), group: 'ind', jobs: 10, powerDraw: 6,
        inputs: {Commodity.ore: 0.3}, outputs: {Commodity.steel: 0.2},
        pollution: 1.5),
    Density.medium: CitySpec(
        type: 'i-med', label: 'Factories', icon: Icons.factory,
        color: Color(0xFFE3A857), group: 'ind', jobs: 28, powerDraw: 16,
        inputs: {Commodity.ore: 1}, outputs: {Commodity.steel: 0.7},
        pollution: 3.0),
    Density.high: CitySpec(
        type: 'i-high', label: 'Heavy Industry', icon: Icons.precision_manufacturing,
        color: Color(0xFFE3A857), group: 'ind', jobs: 70, powerDraw: 40,
        inputs: {Commodity.ore: 2.5}, outputs: {Commodity.steel: 2},
        pollution: 6.0),
  },
};

/// All hand-placed utilities/services/factories/military/aerospace, grouped.
/// `unlockPop` gates the advanced ones behind city growth.
const List<CitySpec> kUtilCatalog = [
  // ---- POWER ----
  // (solar/wind outputs are scaled by the host planet's sun-distance + air.)
  CitySpec(type: 'solar', label: 'Solar Farm', icon: Icons.solar_power,
      color: Color(0xFFFFD23F), group: 'power', powerOutput: 60, buildCost: 40),
  CitySpec(type: 'wind', label: 'Wind Turbine', icon: Icons.wind_power,
      color: Color(0xFFB2DFDB), group: 'power', powerOutput: 50, buildCost: 40),
  CitySpec(type: 'gas', label: 'Gas Generator', icon: Icons.local_fire_department,
      color: Color(0xFFFF8A65), group: 'power', powerOutput: 120, jobs: 6,
      inputs: {Commodity.fuel: 0.6}, pollution: 2.5, buildCost: 50),
  CitySpec(type: 'reactor', label: 'Fission Reactor', icon: Icons.bolt,
      color: Color(0xFF7FE0A0), group: 'power', powerOutput: 240, jobs: 12,
      unlockPop: 120, buildCost: 80, pollution: 1.0),
  CitySpec(type: 'fusion', label: 'Fusion Plant', icon: Icons.blur_on,
      color: Color(0xFF80D8FF), group: 'power', powerOutput: 800, jobs: 30,
      computeDraw: 4, unlockPop: 600, buildCost: 200),
  // ---- CITY SERVICES ----
  // Aquifer Pump: extracts water from the ground table — cheap + plentiful, but
  // it DRAWS DOWN the water table, drying the surface (and eventually killing
  // the flora) if you over-pump. Special-cased: its water output + drawdown are
  // handled in the sim tick (type 'aquifer').
  CitySpec(type: 'aquifer', label: 'Aquifer Pump', icon: Icons.water,
      color: Color(0xFF4DD0E1), group: 'svc', jobs: 6, powerDraw: 8,
      outputs: {Commodity.water: 1.5}, buildCost: 35),
  CitySpec(type: 'water', label: 'Water Plant', icon: Icons.water_drop,
      color: Color(0xFF26C6DA), group: 'svc', jobs: 8, powerDraw: 12,
      outputs: {Commodity.water: 2.0}, services: {'water': 300}, pollution: 0.5),
  CitySpec(type: 'farm', label: 'Farm', icon: Icons.agriculture,
      color: Color(0xFF8BC34A), group: 'svc', jobs: 10, powerDraw: 4,
      inputs: {Commodity.water: 0.5}, outputs: {Commodity.food: 1.0}),
  // Industrial Farm: a 2x2 mega-farm. ~4x the yield of a Farm but only ~3x the
  // build cost + ~2.4x the jobs — economy of scale, at the cost of land + sprawl.
  CitySpec(type: 'farm-big', label: 'Industrial Farm', icon: Icons.agriculture,
      color: Color(0xFFAED581), group: 'svc', jobs: 24, powerDraw: 14,
      inputs: {Commodity.water: 1.8}, outputs: {Commodity.food: 4.2},
      pollution: 1.0, unlockPop: 80, buildCost: 110, footW: 2, footH: 2),
  // Hydroponics: a 1x2 indoor stack. No open ground / sunlight needed (great
  // off-world), but power-hungry and water-fed. Compact, high yield per tile.
  CitySpec(type: 'hydroponics', label: 'Hydroponics', icon: Icons.eco,
      color: Color(0xFF66BB6A), group: 'svc', jobs: 14, powerDraw: 22,
      inputs: {Commodity.water: 1.2}, outputs: {Commodity.food: 3.0},
      unlockPop: 120, buildCost: 90, footW: 1, footH: 2),
  // Lab-Grown Meat: a 2x2 cultured-protein plant. Compute + power + water in,
  // dense food out, with some waste — the high-tech end of the food chain.
  CitySpec(type: 'labmeat', label: 'Lab-Grown Meat', icon: Icons.biotech,
      color: Color(0xFFF48FB1), group: 'svc', jobs: 30, powerDraw: 30,
      computeDraw: 4, inputs: {Commodity.water: 1.5, Commodity.electronics: 0.1},
      outputs: {Commodity.food: 5.0}, pollution: 1.5, unlockPop: 300,
      buildCost: 160, footW: 2, footH: 2),
  // Solar Array: a 2x2 scaled solar farm. ~4.5x a Solar Farm's output for ~3.5x
  // the cost — pack more panels per footprint at a premium.
  CitySpec(type: 'solar-big', label: 'Solar Array', icon: Icons.solar_power,
      color: Color(0xFFFFD23F), group: 'power', powerOutput: 270,
      unlockPop: 60, buildCost: 140, footW: 2, footH: 2),
  // ---- LIFE SUPPORT: oxygen (only needed off breathable worlds) ----
  CitySpec(type: 'electrolysis', label: 'Electrolysis Plant',
      icon: Icons.science, color: Color(0xFF80DEEA), group: 'svc', jobs: 12,
      powerDraw: 20, inputs: {Commodity.water: 1.0},
      outputs: {Commodity.oxygen: 0.8}, buildCost: 50),
  CitySpec(type: 'o2harvester', label: 'Atmospheric O₂ Harvester',
      icon: Icons.air, color: Color(0xFF4DD0E1), group: 'svc', jobs: 10,
      powerDraw: 15, outputs: {Commodity.oxygen: 2.0}, buildCost: 60),
  CitySpec(type: 'clinic', label: 'Clinic', icon: Icons.medical_information,
      color: Color(0xFFFF8A80), group: 'svc', jobs: 6, powerDraw: 5,
      inputs: {Commodity.medicine: 0.2}, services: {'health': 80}, buildCost: 30),
  CitySpec(type: 'hospital', label: 'Hospital', icon: Icons.local_hospital,
      color: Color(0xFFFF6B6B), group: 'svc', jobs: 15, powerDraw: 10,
      inputs: {Commodity.medicine: 0.5}, services: {'health': 200}, unlockPop: 60),
  CitySpec(type: 'chemist', label: 'Chemist', icon: Icons.medication,
      color: Color(0xFF9575CD), group: 'svc', jobs: 8, powerDraw: 6,
      inputs: {Commodity.water: 0.3}, outputs: {Commodity.medicine: 0.4},
      buildCost: 40),
  CitySpec(type: 'pharma', label: 'Pharma Plant', icon: Icons.science,
      color: Color(0xFF7E57C2), group: 'svc', jobs: 30, powerDraw: 25,
      computeDraw: 2, inputs: {Commodity.water: 0.5, Commodity.electronics: 0.1},
      outputs: {Commodity.medicine: 1.5}, pollution: 1.0, unlockPop: 200,
      buildCost: 80),
  CitySpec(type: 'school', label: 'School', icon: Icons.school,
      color: Color(0xFF4FC3F7), group: 'svc', jobs: 12, powerDraw: 8,
      services: {'education': 150}),
  CitySpec(type: 'police', label: 'Police Station', icon: Icons.local_police,
      color: Color(0xFF90A4AE), group: 'svc', jobs: 14, powerDraw: 9,
      services: {'safety': 220}),
  CitySpec(type: 'park', label: 'Park', icon: Icons.park,
      color: Color(0xFF66BB6A), group: 'svc', powerDraw: 2,
      services: {'leisure': 180}),
  // ---- WASTE MANAGEMENT (process garbage + sewage the population generates) ----
  CitySpec(type: 'landfill', label: 'Landfill', icon: Icons.delete_outline,
      color: Color(0xFF8D6E63), group: 'waste', jobs: 6, powerDraw: 3,
      inputs: {Commodity.garbage: 2.0}, pollution: 1.5, buildCost: 30),
  CitySpec(type: 'recycler', label: 'Recycling Center', icon: Icons.recycling,
      color: Color(0xFF66BB6A), group: 'waste', jobs: 18, powerDraw: 14,
      inputs: {Commodity.garbage: 3.0},
      outputs: {Commodity.ore: 0.3, Commodity.steel: 0.2},
      unlockPop: 120, buildCost: 60),
  CitySpec(type: 'sewage', label: 'Sewage Treatment', icon: Icons.water_damage,
      color: Color(0xFF4DB6AC), group: 'waste', jobs: 12, powerDraw: 16,
      inputs: {Commodity.sewage: 3.0}, outputs: {Commodity.water: 1.0},
      pollution: 0.5, buildCost: 50),
  // ---- DEATHCARE (processes corpses; deathcareRate is corpses/sec handled) ----
  CitySpec(type: 'morgue', label: 'Morgue', icon: Icons.medical_services,
      color: Color(0xFF9E9E9E), group: 'death', jobs: 8, powerDraw: 6,
      deathcareRate: 1.5, buildCost: 40),
  CitySpec(type: 'crematorium', label: 'Crematorium', icon: Icons.local_fire_department,
      color: Color(0xFF757575), group: 'death', jobs: 14, powerDraw: 14,
      deathcareRate: 5.0, pollution: 1.0, unlockPop: 150, buildCost: 70),
  CitySpec(type: 'cemetery', label: 'Cemetery', icon: Icons.park_outlined,
      color: Color(0xFF8D9C7A), group: 'death', jobs: 4, powerDraw: 2,
      deathcareRate: 0.8, services: {'leisure': 30}, buildCost: 30),
  // ---- RESOURCES / FACTORIES ----
  CitySpec(type: 'mine', label: 'Mine', icon: Icons.diamond,
      color: Color(0xFFB388FF), group: 'res-x', jobs: 20, powerDraw: 15,
      outputs: {Commodity.ore: 2}, pollution: 2.0),
  // Quarry: a 5×5 open-pit megamine. ~11x a Mine's ore for ~9x the jobs at a
  // steep land + pollution cost — bulk extraction for big colonies.
  CitySpec(type: 'mine', label: 'Quarry', icon: Icons.landscape,
      color: Color(0xFF9575CD), group: 'res-x', jobs: 180, powerDraw: 130,
      outputs: {Commodity.ore: 22}, pollution: 14.0, unlockPop: 400,
      buildCost: 360, footW: 5, footH: 5),
  CitySpec(type: 'refinery', label: 'Refinery', icon: Icons.oil_barrel,
      color: Color(0xFFE3A857), group: 'res-x', jobs: 30, powerDraw: 25,
      inputs: {Commodity.ore: 1}, outputs: {Commodity.fuel: 0.4, Commodity.oxidizer: 0.3},
      pollution: 4.0, unlockPop: 80),
  CitySpec(type: 'steelmill', label: 'Steel Mill', icon: Icons.fireplace,
      color: Color(0xFFBCAAA4), group: 'res-x', jobs: 35, powerDraw: 30,
      inputs: {Commodity.ore: 2}, outputs: {Commodity.steel: 1.5, Commodity.tubes: 0.4},
      pollution: 5.0, unlockPop: 120),
  CitySpec(type: 'electronics', label: 'Electronics Plant',
      icon: Icons.memory, color: Color(0xFF64FFDA), group: 'res-x', jobs: 40,
      powerDraw: 35, computeDraw: 1,
      inputs: {Commodity.steel: 0.5}, outputs: {Commodity.electronics: 0.6},
      pollution: 2.0, unlockPop: 200),
  // ---- COMPUTE ----
  CitySpec(type: 'datacenter', label: 'Data Center', icon: Icons.dns,
      color: Color(0xFF40C4FF), group: 'compute', jobs: 25, powerDraw: 60,
      inputs: {Commodity.electronics: 0.2}, computeOutput: 20,
      pollution: 1.0, unlockPop: 250, buildCost: 120),
  // ---- AEROSPACE ----
  CitySpec(type: 'rocketfactory', label: 'Rocket Parts Factory',
      icon: Icons.rocket, color: Color(0xFFFF8A65), group: 'aero', jobs: 50,
      powerDraw: 45, computeDraw: 3,
      inputs: {Commodity.tubes: 0.5, Commodity.electronics: 0.3},
      outputs: {Commodity.rocketParts: 0.4}, pollution: 3.0, unlockPop: 400),
  CitySpec(type: 'assembly', label: 'Vehicle Assembly Building',
      icon: Icons.rocket_launch, color: Color(0xFFEC407A), group: 'aero',
      jobs: 80, powerDraw: 80, computeDraw: 8,
      inputs: {Commodity.rocketParts: 0.3, Commodity.tubes: 0.2,
        Commodity.electronics: 0.2, Commodity.fuel: 0.5},
      pollution: 2.0, unlockPop: 700, buildCost: 300),
  // ---- MILITARY ----
  CitySpec(type: 'gunfactory', label: 'Arms Factory', icon: Icons.precision_manufacturing,
      color: Color(0xFF8D6E63), group: 'mil', jobs: 35, powerDraw: 25,
      inputs: {Commodity.steel: 0.5, Commodity.electronics: 0.1},
      outputs: {Commodity.guns: 0.3, Commodity.ammo: 1.0},
      pollution: 3.0, unlockPop: 300),
  CitySpec(type: 'missilefactory', label: 'Missile Plant', icon: Icons.rocket,
      color: Color(0xFFD84315), group: 'mil', jobs: 60, powerDraw: 50,
      computeDraw: 4,
      inputs: {Commodity.tubes: 0.4, Commodity.rocketParts: 0.2,
        Commodity.electronics: 0.2},
      outputs: {Commodity.missiles: 0.15}, pollution: 4.0, unlockPop: 800),
  CitySpec(type: 'rationsfactory', label: 'Rations Plant', icon: Icons.lunch_dining,
      color: Color(0xFFA1887F), group: 'mil', jobs: 18, powerDraw: 10,
      inputs: {Commodity.food: 1.0}, outputs: {Commodity.rations: 0.8},
      unlockPop: 200),
  CitySpec(type: 'barracks', label: 'Barracks', icon: Icons.military_tech,
      color: Color(0xFF607D8B), group: 'mil', jobs: 30, powerDraw: 12,
      inputs: {Commodity.rations: 0.5, Commodity.guns: 0.05, Commodity.ammo: 0.3},
      services: {'safety': 150}, unlockPop: 300, buildCost: 80),
  CitySpec(type: 'base', label: 'Military Base', icon: Icons.shield,
      color: Color(0xFF455A64), group: 'mil', jobs: 80, powerDraw: 40,
      inputs: {Commodity.rations: 1.5, Commodity.fuel: 0.5, Commodity.ammo: 1.0},
      services: {'safety': 400}, unlockPop: 600, buildCost: 200),
  CitySpec(type: 'gunemplacement', label: 'Gun Emplacement', icon: Icons.gps_fixed,
      color: Color(0xFF6D4C41), group: 'mil', jobs: 8, powerDraw: 6,
      inputs: {Commodity.ammo: 0.5}, services: {'safety': 120}, unlockPop: 400),
  CitySpec(type: 'silo', label: 'Missile Silo', icon: Icons.rocket_launch,
      color: Color(0xFFBF360C), group: 'mil', jobs: 20, powerDraw: 20,
      computeDraw: 2, inputs: {Commodity.missiles: 0.05},
      unlockPop: 1000, buildCost: 250),
  CitySpec(type: 'airfield', label: 'Airfield', icon: Icons.flight,
      color: Color(0xFF78909C), group: 'mil', jobs: 50, powerDraw: 30,
      footW: 1, footH: 10, // a long runway strip
      inputs: {Commodity.fuel: 1.0, Commodity.ammo: 0.5},
      services: {'safety': 200}, unlockPop: 700, buildCost: 200),
  // ---- STORAGE ----
  CitySpec(type: 'warehouse', label: 'Warehouse', icon: Icons.warehouse,
      color: Color(0xFFA1887F), group: 'storage', powerDraw: 3,
      storageBonus: 500),
  CitySpec(type: 'silo2', label: 'Silo Cluster', icon: Icons.storage,
      color: Color(0xFFA1887F), group: 'storage', powerDraw: 6,
      storageBonus: 1500, unlockPop: 300, buildCost: 80),
  // ---- ENVIRONMENT ----
  CitySpec(type: 'terraformer', label: 'Terraforming Tower', icon: Icons.eco,
      color: Color(0xFF66BB6A), group: 'env', jobs: 30, powerDraw: 60,
      computeDraw: 4, outputs: {Commodity.oxygen: 0.5}, pollution: -2.0,
      unlockPop: 300, buildCost: 150),
  CitySpec(type: 'shelter', label: 'Fallout Shelter', icon: Icons.security,
      color: Color(0xFF78909C), group: 'env', housing: 30, powerDraw: 8,
      buildCost: 60),
  // ---- DISASTER PREPAREDNESS ----
  CitySpec(type: 'warning', label: 'Early-Warning Station',
      icon: Icons.sensors, color: Color(0xFFFFB74D), group: 'prep', jobs: 10,
      powerDraw: 8, computeDraw: 1, unlockPop: 100, buildCost: 50),
  CitySpec(type: 'bunker', label: 'Bunker', icon: Icons.shield_moon,
      color: Color(0xFF607D8B), group: 'prep', housing: 50, jobs: 4,
      powerDraw: 6, buildCost: 70),
  CitySpec(type: 'emergency', label: 'Emergency Services',
      icon: Icons.emergency, color: Color(0xFFEF5350), group: 'prep', jobs: 20,
      powerDraw: 12, inputs: {Commodity.medicine: 0.3},
      services: {'safety': 100, 'health': 60}, unlockPop: 80, buildCost: 60),
  // ---- TRANSPORT ----
  CitySpec(type: 'transit', label: 'Transit Stop', icon: Icons.directions_transit,
      color: Color(0xFF7C4DFF), group: 'transport', jobs: 4, powerDraw: 5,
      services: {'leisure': 80}, buildCost: 30),
  CitySpec(type: 'spaceport', label: 'Spaceport', icon: Icons.rocket_launch,
      color: Color(0xFFEC407A), group: 'transport', jobs: 40, powerDraw: 40,
      inputs: {Commodity.fuel: 1, Commodity.oxidizer: 1},
      outputs: {
        // Life support trickles in on automatic shuttles; ORE only ever arrives
        // via an explicit scheduled delivery, never produced passively.
        Commodity.food: 0.3, Commodity.water: 0.3,
        Commodity.oxygen: 0.3,
      }),
  // Bigger spaceports for colonies with many automatic shuttles arriving +
  // departing: more pads (footprint) = more throughput per build. They can be
  // landed ON (occupied state) by the lander.
  CitySpec(type: 'spaceport', label: 'Spaceport Complex (2×4)',
      icon: Icons.rocket_launch, color: Color(0xFFEC407A), group: 'transport',
      jobs: 110, powerDraw: 110, unlockPop: 200, buildCost: 160,
      footW: 2, footH: 4,
      inputs: {Commodity.fuel: 2.6, Commodity.oxidizer: 2.6},
      outputs: {
        Commodity.food: 0.9, Commodity.water: 0.9,
        Commodity.oxygen: 0.9,
      }),
  CitySpec(type: 'spaceport', label: 'Starport (3×6)',
      icon: Icons.rocket_launch, color: Color(0xFFEC407A), group: 'transport',
      jobs: 240, powerDraw: 240, unlockPop: 800, buildCost: 360,
      footW: 3, footH: 6,
      inputs: {Commodity.fuel: 6, Commodity.oxidizer: 6},
      outputs: {
        Commodity.food: 2.2, Commodity.water: 2.2,
        Commodity.oxygen: 2.2,
      }),
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

