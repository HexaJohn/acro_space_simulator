import 'planet_surface.dart';

/// Real-world-grounded [PlanetSurface] presets for the solar system bodies.
/// Mean surface temperatures, albedos, and axial tilts from planetary fact
/// sheets. Seeds are arbitrary but fixed for reproducible geography.
class SurfacePresets {
  static const PlanetSurface earth = PlanetSurface(
    seed: 0x5EA17,
    meanSurfaceTemperature: 288,
    albedo: 0.30,
    solarFlux: 1361,
    axialTilt: 0.4091, // 23.44 deg
  );

  static const PlanetSurface mars = PlanetSurface(
    seed: 0x3A75,
    meanSurfaceTemperature: 210,
    albedo: 0.25,
    solarFlux: 586,
    axialTilt: 0.4396, // 25.19 deg
  );

  static const PlanetSurface moon = PlanetSurface(
    seed: 0x10001,
    meanSurfaceTemperature: 250,
    albedo: 0.12,
    solarFlux: 1361,
    axialTilt: 0.0269,
  );

  static const PlanetSurface venus = PlanetSurface(
    seed: 0xCAFE,
    meanSurfaceTemperature: 737,
    albedo: 0.65,
    solarFlux: 2601,
    axialTilt: 3.096, // ~177 deg (retrograde) -> near pi
  );

  static const PlanetSurface titan = PlanetSurface(
    seed: 0x7174,
    meanSurfaceTemperature: 94,
    albedo: 0.22,
    solarFlux: 15,
    axialTilt: 0.0,
  );
}
