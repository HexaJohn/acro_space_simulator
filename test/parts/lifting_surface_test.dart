import 'dart:math' as math;

import 'package:acro_space_simulator/domain/parts/lifting_surface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const wing = LiftingSurface(
    name: 'Swept Wing',
    area: 12.0, // m^2
    liftCurveSlope: 5.7, // per radian (~2*pi thin-airfoil, reduced)
    stallAngle: 0.26, // ~15 deg
    dragCoefficient: 0.02,
  );

  test('zero angle of attack makes no lift', () {
    expect(wing.liftCoefficient(0.0), closeTo(0.0, 1e-9));
  });

  test('lift coefficient rises linearly with small angle of attack', () {
    final cl5 = wing.liftCoefficient(_deg(5));
    final cl10 = wing.liftCoefficient(_deg(10));
    expect(cl5, greaterThan(0));
    expect(cl10, closeTo(cl5 * 2, cl5 * 0.05)); // ~linear below stall
  });

  test('past the stall angle the lift collapses', () {
    final clPreStall = wing.liftCoefficient(wing.stallAngle * 0.95);
    final clPostStall = wing.liftCoefficient(wing.stallAngle * 1.5);
    expect(clPostStall, lessThan(clPreStall));
  });

  test('lift force scales with dynamic pressure and area', () {
    const q = 5000.0; // Pa
    final lift = wing.liftForce(dynamicPressure: q, angleOfAttack: _deg(8));
    final expectedCl = wing.liftCoefficient(_deg(8));
    expect(lift, closeTo(q * expectedCl * wing.area, 1e-6));
  });

  test('negative angle of attack gives negative (downward) lift', () {
    expect(wing.liftCoefficient(_deg(-5)), lessThan(0));
  });
}

double _deg(double d) => d * math.pi / 180.0;
