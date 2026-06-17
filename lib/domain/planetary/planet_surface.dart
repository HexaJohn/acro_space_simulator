import 'dart:math' as math;

import '../vessel/resource_container.dart';

/// Surface biomes — terrain/climate classes that gate ore richness, science,
/// and rendering tint. Kept compact; expand freely.
enum Biome {
  ocean,
  iceCap,
  tundra,
  desert,
  grassland,
  forest,
  mountains,
  volcanic,
  barren, // airless rock/regolith
  wetland, // swamp — high water table, spotty standing water
  coastal, // beaches + a coastline (part sea, part land)
  volcano, // a lava-lake biome (molten "ocean", inhospitable)
}

/// Per-biome surface traits used by the conditions model:
/// - [surfaceMoisture]: how wet the GROUND is, independent of the air (0..1).
/// - [floraPotential]: max plant cover this biome supports once climate allows
///   (0 = nothing grows, 1 = lush). Together they make "humid desert" (wet air,
///   low flora) differ from "dry forest" (low air moisture, high flora base).
extension BiomeTraits on Biome {
  double get surfaceMoisture => switch (this) {
        Biome.ocean => 1.0,
        Biome.coastal => 0.8,
        Biome.wetland => 0.95,
        Biome.forest => 0.85,
        Biome.grassland => 0.6,
        Biome.tundra => 0.5,
        Biome.mountains => 0.4,
        Biome.iceCap => 0.3, // frozen, not liquid-wet
        Biome.desert => 0.15,
        Biome.volcanic => 0.2,
        Biome.volcano => 0.0,
        Biome.barren => 0.0,
      };

  double get floraPotential => switch (this) {
        Biome.forest => 1.0,
        Biome.wetland => 0.95,
        Biome.grassland => 0.8,
        Biome.coastal => 0.6,
        Biome.tundra => 0.35,
        Biome.mountains => 0.4,
        Biome.ocean => 0.15,
        Biome.desert => 0.25,
        Biome.iceCap => 0.05,
        Biome.volcanic => 0.1,
        Biome.volcano => 0.0,
        Biome.barren => 0.0,
      };
}

/// Per-body surface model: temperature map (latitude + albedo + insolation),
/// biome classification, and a deterministic ore-distribution field. This is the
/// "what's on the ground" layer the mining, science, and render systems read.
///
/// Deterministic from [seed] so a body's geography is stable across sessions and
/// reproducible for multiplayer. Temperature uses a simple energy balance:
/// absorbed insolation ~ S*(1-albedo)*cos(zenith), blended with the body mean.
class PlanetSurface {
  final int seed;
  final double meanSurfaceTemperature; // K, planet average
  final double albedo; // 0..1 Bond albedo
  final double solarFlux; // W/m^2 at the body
  final double axialTilt; // rad, obliquity

  const PlanetSurface({
    required this.seed,
    required this.meanSurfaceTemperature,
    required this.albedo,
    required this.solarFlux,
    this.axialTilt = 0,
  });

  /// Surface temperature (K) at [latitude] given the current [subsolarLatitude]
  /// (the latitude the sun is overhead — driven by season/axial tilt).
  double temperatureAt({required double latitude, double subsolarLatitude = 0}) {
    const sigma = 5.670374419e-8; // Stefan-Boltzmann
    // Solar zenith proxy: how directly the sun strikes this latitude.
    final incidence = math.cos(latitude - subsolarLatitude).clamp(0.0, 1.0);
    final absorbed = solarFlux * (1 - albedo) * incidence;

    // Local radiative-equilibrium temperature for this absorbed flux (a floor of
    // a few K avoids 0). Higher albedo -> less absorbed -> cooler.
    final tEq = math.pow(math.max(absorbed, 1.0) / sigma, 0.25).toDouble();

    // Blend the local radiative estimate with the body mean (greenhouse +
    // thermal inertia smear the pure radiative value toward the average).
    return 0.5 * tEq + 0.5 * meanSurfaceTemperature;
  }

  /// Biome at a surface point, from temperature + a noise field for variety.
  Biome biomeAt({required double latitude, required double longitude}) {
    final t = temperatureAt(latitude: latitude, subsolarLatitude: 0);
    final n = _noise(latitude, longitude, 7); // 0..1 terrain noise

    if (t < 250) return Biome.iceCap;
    if (t < 268) return Biome.tundra;
    if (albedo > 0.5 && meanSurfaceTemperature < 200) return Biome.barren;
    if (t > 320) return n > 0.6 ? Biome.volcanic : Biome.desert;
    if (n < 0.45) return Biome.ocean;
    if (n < 0.6) return Biome.grassland;
    if (n < 0.8) return Biome.forest;
    return Biome.mountains;
  }

  /// Ore concentration 0..1 at a point for a resource — deterministic noise
  /// veins. Different resources use different noise channels.
  double oreConcentrationAt({
    required double latitude,
    required double longitude,
    required ResourceType resource,
  }) {
    final channel = resource.index + 1;
    final raw = _noise(latitude, longitude, channel);
    // Sharpen into veins: most of the surface is poor, a few spots rich.
    final vein = math.pow(raw, 3).toDouble();
    return vein.clamp(0.0, 1.0);
  }

  /// Deterministic value noise in [0,1] from lat/long + a channel, seeded.
  double _noise(double lat, double lon, int channel) {
    // Hash the quantized coordinates + seed + channel into a pseudo-random unit.
    final la = (lat * 9.0).round();
    final lo = (lon * 9.0).round();
    var h = seed ^ (channel * 0x9E3779B1);
    h = _hash(h ^ (la * 73856093));
    h = _hash(h ^ (lo * 19349663));
    h = _hash(h ^ channel);
    return (h & 0xFFFFFF) / 0xFFFFFF;
  }

  int _hash(int x) {
    var h = x & 0x7FFFFFFF;
    h = (h ^ (h >> 16)) * 0x45d9f3b & 0x7FFFFFFF;
    h = (h ^ (h >> 16)) * 0x45d9f3b & 0x7FFFFFFF;
    h = h ^ (h >> 16);
    return h;
  }
}
