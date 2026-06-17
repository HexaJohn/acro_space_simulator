import '../vessel/resource_container.dart';

/// Every kind of electricity source. Power can ONLY come from one of these —
/// there is no free/teleported energy; a base, ship, or megastructure must own
/// or be wired to a plant of one of these types to have power.
enum PowerPlantType {
  solar, // photovoltaic — needs sunlight
  wind, // needs atmosphere (handled by caller)
  hydro, // needs liquid water (handled by caller)
  geothermal, // taps planetary heat, runs anywhere with a hot interior
  fuelCell, // burns fuel+oxidizer, no sun needed
  rtg, // radioisotope decay — runs forever, low output
  fission, // nuclear reactor — needs fissile fuel
  fusion, // needs fusion fuel (deuterium etc.)
  antimatter, // needs antimatter fuel — enormous output
  beamedMicrowave, // receives power beamed from orbit/solar sats
}

/// A power-plant type with its rated output and fuel/environment needs. Value
/// object from the [PowerPlantCatalog].
class PowerPlant {
  final PowerPlantType type;
  final String name;
  final double ratedOutput; // W at full operation
  final bool requiresSunlight;
  final bool requiresFuel;
  final ResourceType? fuelType;
  final double fuelPerSecond; // units/s consumed at rated output

  const PowerPlant({
    required this.type,
    required this.name,
    required this.ratedOutput,
    this.requiresSunlight = false,
    this.requiresFuel = false,
    this.fuelType,
    this.fuelPerSecond = 0,
  });

  /// Instantaneous output (W) given sunlight (0..1) and available fuel units.
  double output({required double sunlightFraction, required double fuelAvailable}) {
    if (requiresSunlight) {
      return ratedOutput * sunlightFraction.clamp(0.0, 1.0);
    }
    if (requiresFuel) {
      return fuelAvailable > 0 ? ratedOutput : 0;
    }
    return ratedOutput; // RTG / geothermal / always-on
  }
}

/// The catalog of available power plants, real-world to far-future.
class PowerPlantCatalog {
  final Map<PowerPlantType, PowerPlant> _byType;

  PowerPlantCatalog(Iterable<PowerPlant> plants)
      : _byType = {for (final p in plants) p.type: p};

  Iterable<PowerPlant> get all => _byType.values;
  PowerPlant? byType(PowerPlantType t) => _byType[t];

  factory PowerPlantCatalog.standard() => PowerPlantCatalog(const [
        PowerPlant(
          type: PowerPlantType.solar,
          name: 'Solar Array',
          ratedOutput: 2.0e5, // 200 kW
          requiresSunlight: true,
        ),
        PowerPlant(
          type: PowerPlantType.wind,
          name: 'Wind Turbine',
          ratedOutput: 3.0e6, // 3 MW
        ),
        PowerPlant(
          type: PowerPlantType.hydro,
          name: 'Hydroelectric Dam',
          ratedOutput: 1.0e8, // 100 MW
        ),
        PowerPlant(
          type: PowerPlantType.geothermal,
          name: 'Geothermal Plant',
          ratedOutput: 5.0e7, // 50 MW
        ),
        PowerPlant(
          type: PowerPlantType.fuelCell,
          name: 'Fuel Cell',
          ratedOutput: 5.0e4, // 50 kW
          requiresFuel: true,
          fuelType: ResourceType.liquidFuel,
          fuelPerSecond: 0.02,
        ),
        PowerPlant(
          type: PowerPlantType.rtg,
          name: 'RTG',
          ratedOutput: 300, // ~Voyager-class, runs for decades
        ),
        PowerPlant(
          type: PowerPlantType.fission,
          name: 'Fission Reactor',
          ratedOutput: 1.0e9, // 1 GW
          requiresFuel: true,
          fuelType: ResourceType.ore, // (uranium ore stand-in)
          fuelPerSecond: 1e-4,
        ),
        PowerPlant(
          type: PowerPlantType.fusion,
          name: 'Fusion Reactor',
          ratedOutput: 5.0e9, // 5 GW
          requiresFuel: true,
          fuelType: ResourceType.water, // (deuterium from water stand-in)
          fuelPerSecond: 1e-3,
        ),
        PowerPlant(
          type: PowerPlantType.antimatter,
          name: 'Antimatter Reactor',
          ratedOutput: 1.0e13, // 10 TW
          requiresFuel: true,
          fuelType: ResourceType.monopropellant, // (antimatter stand-in)
          fuelPerSecond: 1e-6,
        ),
        PowerPlant(
          type: PowerPlantType.beamedMicrowave,
          name: 'Microwave Rectenna',
          ratedOutput: 1.0e9, // receives beamed power
          requiresSunlight: true, // proxy: needs the orbital beamer in sunlight
        ),
      ]);
}
