import 'dart:math' as math;

/// A sample of atmospheric conditions at one altitude. Value object consumed by
/// the aerodynamics and thermal contexts.
class AtmosphereSample {
  final double pressure; // Pa
  final double density; // kg/m^3
  final double temperature; // K
  final double speedOfSound; // m/s

  const AtmosphereSample({
    required this.pressure,
    required this.density,
    required this.temperature,
    required this.speedOfSound,
  });

  static const AtmosphereSample vacuum = AtmosphereSample(
    pressure: 0,
    density: 0,
    temperature: 2.7, // cosmic background
    speedOfSound: 0,
  );
}

/// Exponential isothermal-ish atmosphere model. Pressure and density fall off
/// with scale height; temperature follows a simple lapse profile. Good enough
/// for gameplay aero/thermal; can be swapped for a tabulated model later
/// without touching callers.
class AtmosphereModel {
  /// Sea-level (datum) values.
  final double seaLevelPressure; // Pa
  final double seaLevelDensity; // kg/m^3
  final double seaLevelTemperature; // K

  /// e-folding height for pressure/density, metres.
  final double scaleHeight;

  /// Altitude above the datum at which the atmosphere is treated as vacuum.
  final double atmosphereHeight;

  /// Temperature lapse rate, K per metre (positive = cools with altitude).
  final double lapseRate;

  /// Ratio of specific heats (gamma) and specific gas constant — for the
  /// speed of sound a = sqrt(gamma * R * T).
  final double gamma;
  final double specificGasConstant; // J/(kg*K)

  const AtmosphereModel({
    required this.seaLevelPressure,
    required this.seaLevelDensity,
    required this.seaLevelTemperature,
    required this.scaleHeight,
    required this.atmosphereHeight,
    this.lapseRate = 0.0065,
    this.gamma = 1.4,
    this.specificGasConstant = 287.05,
  });

  bool hasAtmosphere(double altitude) =>
      altitude >= 0 && altitude < atmosphereHeight;

  AtmosphereSample sampleAt(double altitude) {
    if (!hasAtmosphere(altitude)) return AtmosphereSample.vacuum;
    final factor = math.exp(-altitude / scaleHeight);
    final t = math.max(
      2.7,
      seaLevelTemperature - lapseRate * altitude,
    );
    final a = math.sqrt(gamma * specificGasConstant * t);
    return AtmosphereSample(
      pressure: seaLevelPressure * factor,
      density: seaLevelDensity * factor,
      temperature: t,
      speedOfSound: a,
    );
  }
}
