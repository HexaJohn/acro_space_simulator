import 'dart:math' as math;

import '../planetary/atmospheric_composition.dart';
import '../planetary/surface_presets.dart';
import 'atmosphere_model.dart';
import 'celestial_body.dart';
import 'star_system.dart';

/// The real Solar System, built from published body parameters (NASA planetary
/// fact sheets / JPL). Distances and masses are 1:1 SI — exactly the scale the
/// [PreciseVector3] lattice exists to handle.
///
/// Values: GM (mu) in m^3/s^2, mean radius in m, semi-major axis in m,
/// eccentricity dimensionless, inclination in radians (to the ecliptic), SOI in
/// m (= a * (m_body / m_parent)^(2/5)). Rotation periods in seconds.
class RealSolarSystem {
  static const double _au = 1.495978707e11; // metres
  static double _deg(double d) => d * math.pi / 180.0;

  /// Compact factory for a moon (tidally-locked, near-circular, no atmosphere).
  static CelestialBody _moon(
    String id,
    String name,
    double mu,
    double radius,
    double soiRadius,
    String parent,
    double orbitRadius,
    double eccentricity,
    double solarFlux,
  ) =>
      CelestialBody(
        id: BodyId(id),
        name: name,
        mu: mu,
        radius: radius,
        soiRadius: soiRadius,
        siderealRotationPeriod: 1e5,
        parent: BodyId(parent),
        orbitRadius: orbitRadius,
        orbitEccentricity: eccentricity,
        solarFlux: solarFlux,
      );

  // Atmospheric compositions (factories aren't const, so build them lazily).
  static final AtmosphericComposition _earthAir = AtmosphericComposition.earth();
  static final AtmosphericComposition _marsAir = AtmosphericComposition.mars();
  static final AtmosphericComposition _venusAir = AtmosphericComposition.venus();
  static final AtmosphericComposition _titanAir = AtmosphericComposition.titan();

  static StarSystem build() {
    final bodies = <CelestialBody>[
      // ---- Sun (root) ----
      const CelestialBody(
        id: BodyId('sun'),
        name: 'Sun',
        mu: 1.32712440018e20,
        radius: 6.957e8,
        soiRadius: double.infinity,
        siderealRotationPeriod: 2.1925e6, // ~25.38 d (equatorial)
        parent: null,
        solarFlux: 0,
      ),

      // ---- Planets ----
      CelestialBody(
        id: const BodyId('mercury'),
        name: 'Mercury',
        mu: 2.2032e13,
        radius: 2.4397e6,
        soiRadius: 1.124e8,
        siderealRotationPeriod: 5.0670e6,
        parent: const BodyId('sun'),
        orbitRadius: 0.387098 * _au,
        orbitEccentricity: 0.205630,
        orbitInclination: _deg(7.005),
        solarFlux: 9082,
      ),
      CelestialBody(
        id: const BodyId('venus'),
        name: 'Venus',
        mu: 3.24859e14,
        radius: 6.0518e6,
        soiRadius: 6.16e8,
        siderealRotationPeriod: -2.0997e7, // retrograde
        parent: const BodyId('sun'),
        orbitRadius: 0.723332 * _au,
        orbitEccentricity: 0.006772,
        orbitInclination: _deg(3.39458),
        atmosphere: const AtmosphereModel(
          seaLevelPressure: 9.2e6, // 92 bar
          seaLevelDensity: 65.0,
          seaLevelTemperature: 737,
          scaleHeight: 15900,
          atmosphereHeight: 250000,
        ),
        solarFlux: 2601,
        axialTilt: 3.0955, // ~177.4 deg (retrograde)
        j2: 4.458e-6,
        surface: SurfacePresets.venus,
        composition: _venusAir,
      ),
      CelestialBody(
        id: const BodyId('earth'),
        name: 'Earth',
        mu: 3.986004418e14,
        radius: 6.371e6,
        soiRadius: 9.24e8,
        siderealRotationPeriod: 86164.1, // sidereal day
        parent: const BodyId('sun'),
        orbitRadius: 1.00000011 * _au,
        orbitEccentricity: 0.0167086,
        orbitInclination: _deg(0.00005),
        atmosphere: const AtmosphereModel(
          seaLevelPressure: 101325,
          seaLevelDensity: 1.225,
          seaLevelTemperature: 288.15,
          scaleHeight: 8500,
          atmosphereHeight: 140000,
        ),
        solarFlux: 1361,
        axialTilt: 0.4091, // 23.44 deg -> seasons
        j2: 1.08263e-3, // Earth oblateness
        dipoleMoment: 8.0e22, // A*m^2
        surface: SurfacePresets.earth,
        composition: _earthAir,
      ),
      CelestialBody(
        id: const BodyId('mars'),
        name: 'Mars',
        mu: 4.282837e13,
        radius: 3.3895e6,
        soiRadius: 5.76e8,
        siderealRotationPeriod: 88642.7,
        parent: const BodyId('sun'),
        orbitRadius: 1.523679 * _au,
        orbitEccentricity: 0.0934,
        orbitInclination: _deg(1.850),
        atmosphere: const AtmosphereModel(
          seaLevelPressure: 610, // ~6 mbar
          seaLevelDensity: 0.020,
          seaLevelTemperature: 210,
          scaleHeight: 11100,
          atmosphereHeight: 125000,
        ),
        solarFlux: 586,
        axialTilt: 0.4396, // 25.19 deg
        j2: 1.96045e-3,
        surface: SurfacePresets.mars,
        composition: _marsAir,
      ),
      CelestialBody(
        id: const BodyId('jupiter'),
        name: 'Jupiter',
        mu: 1.26686534e17,
        radius: 6.9911e7,
        soiRadius: 4.82e10,
        siderealRotationPeriod: 35730,
        parent: const BodyId('sun'),
        orbitRadius: 5.2044 * _au,
        orbitEccentricity: 0.0489,
        orbitInclination: _deg(1.303),
        solarFlux: 50,
      ),
      CelestialBody(
        id: const BodyId('saturn'),
        name: 'Saturn',
        mu: 3.7931187e16,
        radius: 5.8232e7,
        soiRadius: 5.46e10,
        siderealRotationPeriod: 38362,
        parent: const BodyId('sun'),
        orbitRadius: 9.5826 * _au,
        orbitEccentricity: 0.0565,
        orbitInclination: _deg(2.485),
        solarFlux: 15,
      ),
      CelestialBody(
        id: const BodyId('uranus'),
        name: 'Uranus',
        mu: 5.793939e15,
        radius: 2.5362e7,
        soiRadius: 5.18e10,
        siderealRotationPeriod: -62064, // retrograde
        parent: const BodyId('sun'),
        orbitRadius: 19.2184 * _au,
        orbitEccentricity: 0.0457,
        orbitInclination: _deg(0.773),
        solarFlux: 3.7,
      ),
      CelestialBody(
        id: const BodyId('neptune'),
        name: 'Neptune',
        mu: 6.836529e15,
        radius: 2.4622e7,
        soiRadius: 8.68e10,
        siderealRotationPeriod: 57996,
        parent: const BodyId('sun'),
        orbitRadius: 30.110 * _au,
        orbitEccentricity: 0.0113,
        orbitInclination: _deg(1.770),
        solarFlux: 1.5,
      ),

      // ---- Earth's Moon ----
      CelestialBody(
        id: const BodyId('moon'),
        name: 'Moon',
        mu: 4.9028e12,
        radius: 1.7374e6,
        soiRadius: 6.61e7,
        siderealRotationPeriod: 2.3606e6,
        parent: const BodyId('earth'),
        orbitRadius: 3.844e8,
        orbitEccentricity: 0.0549,
        orbitInclination: _deg(5.145),
        solarFlux: 1361,
        axialTilt: 0.0269,
        surface: SurfacePresets.moon,
      ),

      // ---- Mars' moons ----
      CelestialBody(
        id: const BodyId('phobos'),
        name: 'Phobos',
        mu: 7.087e5,
        radius: 11267,
        soiRadius: 1.5e4,
        siderealRotationPeriod: 27553,
        parent: const BodyId('mars'),
        orbitRadius: 9.376e6,
        orbitEccentricity: 0.0151,
        solarFlux: 586,
      ),

      // ---- Galilean moons (Jupiter) ----
      CelestialBody(
        id: const BodyId('io'),
        name: 'Io',
        mu: 5.959916e12,
        radius: 1.8216e6,
        soiRadius: 7.18e6,
        siderealRotationPeriod: 1.5293e5,
        parent: const BodyId('jupiter'),
        orbitRadius: 4.217e8,
        orbitEccentricity: 0.0041,
        solarFlux: 50,
      ),
      CelestialBody(
        id: const BodyId('europa'),
        name: 'Europa',
        mu: 3.202739e12,
        radius: 1.5608e6,
        soiRadius: 9.74e6,
        siderealRotationPeriod: 3.0681e5,
        parent: const BodyId('jupiter'),
        orbitRadius: 6.711e8,
        orbitEccentricity: 0.0094,
        solarFlux: 50,
      ),
      CelestialBody(
        id: const BodyId('ganymede'),
        name: 'Ganymede',
        mu: 9.887834e12,
        radius: 2.6341e6,
        soiRadius: 2.41e7,
        siderealRotationPeriod: 6.1834e5,
        parent: const BodyId('jupiter'),
        orbitRadius: 1.0704e9,
        orbitEccentricity: 0.0013,
        solarFlux: 50,
      ),
      CelestialBody(
        id: const BodyId('callisto'),
        name: 'Callisto',
        mu: 7.179289e12,
        radius: 2.4103e6,
        soiRadius: 3.71e7,
        siderealRotationPeriod: 1.4417e6,
        parent: const BodyId('jupiter'),
        orbitRadius: 1.8827e9,
        orbitEccentricity: 0.0074,
        solarFlux: 50,
      ),

      // ---- Titan (Saturn) ----
      CelestialBody(
        id: const BodyId('titan'),
        name: 'Titan',
        mu: 8.978e12,
        radius: 2.5747e6,
        soiRadius: 1.19e8,
        siderealRotationPeriod: 1.3779e6,
        parent: const BodyId('saturn'),
        orbitRadius: 1.22187e9,
        orbitEccentricity: 0.0288,
        atmosphere: const AtmosphereModel(
          seaLevelPressure: 146700, // 1.45 bar
          seaLevelDensity: 5.3,
          seaLevelTemperature: 94,
          scaleHeight: 21000,
          atmosphereHeight: 600000,
        ),
        solarFlux: 15,
        surface: SurfacePresets.titan,
        composition: _titanAir,
      ),

      // ---- Deimos (Mars) ----
      CelestialBody(
        id: const BodyId('deimos'),
        name: 'Deimos',
        mu: 9.46e4,
        radius: 6200,
        soiRadius: 1.3e4,
        siderealRotationPeriod: 109075,
        parent: const BodyId('mars'),
        orbitRadius: 2.346e7,
        orbitEccentricity: 0.00033,
        solarFlux: 586,
      ),

      // ---- More Saturn moons ----
      _moon('enceladus', 'Enceladus', 7.21e9, 252100, 1.8e6, 'saturn', 2.380e8,
          0.0047, 15),
      _moon('mimas', 'Mimas', 2.503e9, 198200, 8.9e5, 'saturn', 1.855e8, 0.0196, 15),
      _moon('rhea', 'Rhea', 1.539e11, 763800, 2.8e7, 'saturn', 5.270e8, 0.0013, 15),
      _moon('iapetus', 'Iapetus', 1.205e11, 734500, 1.0e8, 'saturn', 3.561e9,
          0.0286, 15),
      _moon('dione', 'Dione', 7.311e10, 561400, 2.0e7, 'saturn', 3.774e8, 0.0022, 15),
      _moon('tethys', 'Tethys', 4.121e10, 531100, 1.4e7, 'saturn', 2.947e8,
          0.0001, 15),

      // ---- Uranus moons ----
      _moon('titania', 'Titania', 2.347e11, 788400, 2.9e7, 'uranus', 4.358e8,
          0.0011, 3.7),
      _moon('oberon', 'Oberon', 1.923e11, 761400, 3.0e7, 'uranus', 5.835e8,
          0.0014, 3.7),
      _moon('miranda', 'Miranda', 4.4e9, 235800, 4.0e6, 'uranus', 1.299e8, 0.0013,
          3.7),
      _moon('ariel', 'Ariel', 8.346e10, 578900, 1.5e7, 'uranus', 1.909e8, 0.0012,
          3.7),
      _moon('umbriel', 'Umbriel', 8.509e10, 584700, 1.7e7, 'uranus', 2.660e8,
          0.0039, 3.7),

      // ---- Neptune moon ----
      _moon('triton', 'Triton', 1.428e12, 1353400, 1.0e8, 'neptune', 3.548e8,
          0.000016, 1.5),

      // ---- Dwarf planets ----
      CelestialBody(
        id: const BodyId('ceres'),
        name: 'Ceres',
        mu: 6.263e10,
        radius: 4.762e5,
        soiRadius: 7.6e7,
        siderealRotationPeriod: 32667,
        parent: const BodyId('sun'),
        orbitRadius: 2.7675 * _au,
        orbitEccentricity: 0.0758,
        orbitInclination: _deg(10.59),
        solarFlux: 178,
      ),
      CelestialBody(
        id: const BodyId('pluto'),
        name: 'Pluto',
        mu: 8.71e11,
        radius: 1.1883e6,
        soiRadius: 3.12e9,
        siderealRotationPeriod: 5.519e5,
        parent: const BodyId('sun'),
        orbitRadius: 39.482 * _au,
        orbitEccentricity: 0.2488,
        orbitInclination: _deg(17.16),
        axialTilt: 2.0857, // ~119.5 deg
        solarFlux: 0.88,
      ),
      _moon('charon', 'Charon', 1.058e11, 6.06e5, 1.0e7, 'pluto', 1.9591e7,
          0.0002, 0.88),
      CelestialBody(
        id: const BodyId('eris'),
        name: 'Eris',
        mu: 1.108e12,
        radius: 1.163e6,
        soiRadius: 8.0e9,
        siderealRotationPeriod: 9.32e4,
        parent: const BodyId('sun'),
        orbitRadius: 67.864 * _au,
        orbitEccentricity: 0.4407,
        orbitInclination: _deg(44.04),
        solarFlux: 0.30,
      ),
      CelestialBody(
        id: const BodyId('haumea'),
        name: 'Haumea',
        mu: 2.67e11,
        radius: 7.8e5,
        soiRadius: 5.0e9,
        siderealRotationPeriod: 14094,
        parent: const BodyId('sun'),
        orbitRadius: 43.13 * _au,
        orbitEccentricity: 0.1912,
        orbitInclination: _deg(28.19),
        solarFlux: 0.73,
      ),
      CelestialBody(
        id: const BodyId('makemake'),
        name: 'Makemake',
        mu: 2.0e11,
        radius: 7.15e5,
        soiRadius: 5.0e9,
        siderealRotationPeriod: 80870,
        parent: const BodyId('sun'),
        orbitRadius: 45.43 * _au,
        orbitEccentricity: 0.1559,
        orbitInclination: _deg(28.98),
        solarFlux: 0.66,
      ),
    ];

    return StarSystem(
      name: 'Sol',
      rootStar: const BodyId('sun'),
      bodies: bodies,
    );
  }
}
