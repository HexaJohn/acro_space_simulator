// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_building_spec.dart';
import '../../../domain/colony/city/commodity.dart';

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
