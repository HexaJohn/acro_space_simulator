// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_building_spec.dart';
import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/colony/city/commodity.dart';
import '../../../domain/planetary/planet_surface.dart';

export '../../../domain/colony/city/city_building_spec.dart'
    show Density, kGroupLabels, kUtilCatalog, kZoneSpecs;
export '../../../domain/colony/city/commodity.dart' show Commodity;

/// PRESENTATION half of the colony building catalogue.
///
/// The specs themselves now live in the domain (`domain/colony/city/`) so the
/// authoritative sim can tick a colony with no Flutter in scope. What stays here
/// is the part that genuinely is a widget concern: the Material icon each
/// building draws with. The palette colour rides along in the domain spec as a
/// packed ARGB int — it is data the 2D map, the 3D facade tint and the minimap
/// all key off — and [CitySpecVisuals.color] just wraps it back into a [Color].

/// The city builder's spec type. Aliased so the (large) UI keeps its original
/// vocabulary while the definition lives in the domain.
typedef CitySpec = CityBuildingSpec;

/// A zone kind + density pair.
typedef ZoneType = CityZoneType;

/// Icon per building LABEL. Keyed on label rather than `type` because several
/// specs deliberately share a type — the three spaceport sizes are all
/// `spaceport`, and Quarry is a big `mine` — so type is not unique.
const Map<String, IconData> kCityIcons = {
  // Grown zones
  'Low-Density Homes': Icons.house,
  'Apartments': Icons.apartment,
  'Towers': Icons.location_city,
  'Shops': Icons.store,
  'Mall': Icons.local_mall,
  'Business District': Icons.business,
  'Workshops': Icons.handyman,
  'Factories': Icons.factory,
  'Heavy Industry': Icons.precision_manufacturing,
  // Power
  'Solar Farm': Icons.solar_power,
  'Solar Array': Icons.solar_power,
  'Wind Turbine': Icons.wind_power,
  'Gas Generator': Icons.local_fire_department,
  'Fission Reactor': Icons.bolt,
  'Fusion Plant': Icons.blur_on,
  // Services
  'Aquifer Pump': Icons.water,
  'Water Plant': Icons.water_drop,
  'Farm': Icons.agriculture,
  'Industrial Farm': Icons.agriculture,
  'Hydroponics': Icons.eco,
  'Lab-Grown Meat': Icons.biotech,
  'Electrolysis Plant': Icons.science,
  'Atmospheric O₂ Harvester': Icons.air,
  'Clinic': Icons.medical_information,
  'Hospital': Icons.local_hospital,
  'Chemist': Icons.medication,
  'Pharma Plant': Icons.science,
  'School': Icons.school,
  'Police Station': Icons.local_police,
  'Park': Icons.park,
  // Waste + deathcare
  'Landfill': Icons.delete_outline,
  'Recycling Center': Icons.recycling,
  'Sewage Treatment': Icons.water_damage,
  'Morgue': Icons.medical_services,
  'Crematorium': Icons.local_fire_department,
  'Cemetery': Icons.park_outlined,
  // Resources + factories
  'Mine': Icons.diamond,
  'Quarry': Icons.landscape,
  'Refinery': Icons.oil_barrel,
  'Steel Mill': Icons.fireplace,
  'Electronics Plant': Icons.memory,
  'Data Center': Icons.dns,
  // Aerospace
  'Rocket Parts Factory': Icons.rocket,
  'Vehicle Assembly Building': Icons.rocket_launch,
  // Military
  'Arms Factory': Icons.precision_manufacturing,
  'Missile Plant': Icons.rocket,
  'Rations Plant': Icons.lunch_dining,
  'Barracks': Icons.military_tech,
  'Military Base': Icons.shield,
  'Gun Emplacement': Icons.gps_fixed,
  'Missile Silo': Icons.rocket_launch,
  'Airfield': Icons.flight,
  // Storage
  'Warehouse': Icons.warehouse,
  'Silo Cluster': Icons.storage,
  // Environment + prep
  'Terraforming Tower': Icons.eco,
  'Fallout Shelter': Icons.security,
  'Early-Warning Station': Icons.sensors,
  'Bunker': Icons.shield_moon,
  'Emergency Services': Icons.emergency,
  // Transport
  'Transit Stop': Icons.directions_transit,
  'Spaceport': Icons.rocket_launch,
  'Spaceport Complex (2×4)': Icons.rocket_launch,
  'Starport (3×6)': Icons.rocket_launch,
};

/// Widget-side accessors for a domain building spec.
extension CitySpecVisuals on CityBuildingSpec {
  /// Palette icon. Falls back to a generic block for a spec added to the domain
  /// catalogue without a matching entry above.
  IconData get icon => kCityIcons[label] ?? Icons.domain;

  /// Palette colour, unpacked from the spec's ARGB.
  Color get color => Color(colorArgb);
}

/// Commodity display helpers that need a Flutter type live here rather than in
/// the domain's [Commodity].
Color commodityColor(String c) => switch (Commodity.section(c)) {
      'RAW RESOURCES' => const Color(0xFF8BC34A),
      'COMPONENTS' => const Color(0xFF4FC3F7),
      'WASTE' => const Color(0xFF8D6E63),
      _ => const Color(0xFFE3A857),
    };

/// Icon per disaster. Lives here, not on the enum, because the enum is domain
/// data now and [IconData] is a widget type.
const Map<Disaster, IconData> kDisasterIcons = {
  Disaster.none: Icons.wb_sunny,
  Disaster.rain: Icons.water_drop,
  Disaster.thunderstorm: Icons.thunderstorm,
  Disaster.snow: Icons.ac_unit,
  Disaster.dustStorm: Icons.air,
  Disaster.tornado: Icons.cyclone,
  Disaster.fire: Icons.local_fire_department,
  Disaster.meteorShower: Icons.stream,
  Disaster.plague: Icons.coronavirus,
  Disaster.famine: Icons.no_meals,
  Disaster.solarStorm: Icons.flare,
  Disaster.nuke: Icons.dangerous,
  Disaster.hurricane: Icons.cyclone,
  Disaster.blizzard: Icons.severe_cold,
  Disaster.fog: Icons.foggy,
  Disaster.acidRain: Icons.invert_colors,
  Disaster.earthquake: Icons.vibration,
  Disaster.radiationStorm: Icons.bubble_chart,
  Disaster.glassRain: Icons.grain,
  Disaster.ammoniaStorm: Icons.ac_unit,
  Disaster.cryovolcanism: Icons.ac_unit,
  Disaster.miasma: Icons.cloud,
  Disaster.lavaFlow: Icons.local_fire_department,
  Disaster.sandworm: Icons.waves,
  Disaster.grayGoo: Icons.blur_on,
  Disaster.crawlingForest: Icons.forest,
  Disaster.rollingGlitch: Icons.broken_image,
  Disaster.auroraBloom: Icons.auto_awesome,
  Disaster.eclipse: Icons.dark_mode,
  Disaster.gammaRayBurst: Icons.flare,
  Disaster.fallingStar: Icons.star,
  Disaster.skyCrack: Icons.bolt,
  Disaster.timeDilation: Icons.hourglass_bottom,
  Disaster.sporeBloom: Icons.grass,
  Disaster.crystalGrowth: Icons.diamond,
  Disaster.biolumTide: Icons.water,
  Disaster.chemicalRain: Icons.science,
  Disaster.diamondRain: Icons.diamond,
  Disaster.ironSnow: Icons.ac_unit,
  Disaster.methaneDownpour: Icons.local_gas_station,
  Disaster.bloodRain: Icons.water_drop,
  Disaster.blackRain: Icons.grain,
  Disaster.commsBlackout: Icons.signal_cellular_off,
  Disaster.goldRush: Icons.paid,
  Disaster.refugeeInflux: Icons.groups,
  Disaster.festival: Icons.celebration,
  Disaster.cultUprising: Icons.report,
  Disaster.aiAwakening: Icons.smart_toy,
  Disaster.marketCrash: Icons.trending_down,
  Disaster.alienBeacon: Icons.cell_tower,
  Disaster.rainingFrogs: Icons.pets,
  Disaster.glitchInMatrix: Icons.replay,
};

extension DisasterIcon on Disaster {
  IconData get icon => kDisasterIcons[this] ?? Icons.warning_amber;
}

/// Human name for a biome, for the panels that let you pick one.
String cityBiomeName(Biome b) => switch (b) {
      Biome.ocean => 'Ocean',
      Biome.iceCap => 'Ice Cap',
      Biome.tundra => 'Tundra',
      Biome.desert => 'Desert',
      Biome.grassland => 'Grassland',
      Biome.forest => 'Forest',
      Biome.mountains => 'Mountains',
      Biome.volcanic => 'Volcanic',
      Biome.barren => 'Barren',
      Biome.wetland => 'Wetland',
      Biome.coastal => 'Coastal',
      Biome.volcano => 'Volcano (lava)',
    };
