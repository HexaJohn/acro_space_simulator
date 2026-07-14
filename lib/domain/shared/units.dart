// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

/// Lightweight unit value objects. Extension types give us type-safety against
/// mixing kilograms with newtons at zero runtime cost (they compile to the
/// underlying `double`). All SI base units; 1:1 scale.
library;

/// Mass, kilograms.
extension type const Kilograms(double value) {
  Kilograms operator +(Kilograms o) => Kilograms(value + o.value);
  Kilograms operator -(Kilograms o) => Kilograms(value - o.value);
  bool get isZero => value == 0;
  static const Kilograms zero = Kilograms(0);
}

/// Force magnitude, newtons.
extension type const Newtons(double value) {
  Newtons operator +(Newtons o) => Newtons(value + o.value);
  static const Newtons zero = Newtons(0);
}

/// Specific impulse, seconds (engine efficiency).
extension type const Seconds(double value) {}

/// Temperature, kelvin.
extension type const Kelvin(double value) {
  Kelvin operator +(Kelvin o) => Kelvin(value + o.value);
  bool exceeds(Kelvin limit) => value > limit.value;
}

/// Pressure, pascals.
extension type const Pascals(double value) {}

/// Density, kg/m^3.
extension type const KgPerCubicMetre(double value) {}

/// Length, metres.
extension type const Metres(double value) {}

/// Standard gravity at Earth sea level, used in the rocket equation.
const double standardGravity = 9.80665; // m/s^2

/// Stefan-Boltzmann constant, for radiative thermal transfer (W/m^2/K^4).
const double stefanBoltzmann = 5.670374419e-8;

/// Gravitational constant (m^3 / kg / s^2).
const double gravitationalConstant = 6.67430e-11;
