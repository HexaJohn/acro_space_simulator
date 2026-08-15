// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// STRING-keyed commodities for the colony economy.
///
/// Deliberately separate from the flight sim's `ResourceType` enum: the city
/// runs a much richer supply chain (military goods, advanced manufacturing
/// inputs, compute) that would bloat the vessel-side resource model. The two
/// meet only at the spaceport, where a delivery converts between them.
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
