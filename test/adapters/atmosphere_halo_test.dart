import 'package:acro_space_simulator/adapters/presenters/atmosphere_halo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const halo = AtmosphereHalo(bodyRadiusPx: 100.0, thicknessFraction: 0.2);

  test('inner/outer radii follow the thickness fraction', () {
    expect(halo.innerRadius, 100.0);
    expect(halo.outerRadius, closeTo(120.0, 1e-9));
    expect(halo.thicknessPx, closeTo(20.0, 1e-9));
  });

  test('alpha is highest (full) at the surface', () {
    expect(halo.alphaAt(halo.innerRadius), 1.0);
    // At or inside the surface stays full.
    expect(halo.alphaAt(90.0), 1.0);
  });

  test('alpha is 0 at and after the outer edge', () {
    expect(halo.alphaAt(halo.outerRadius), 0.0);
    expect(halo.alphaAt(halo.outerRadius + 50.0), 0.0);
  });

  test('alpha is monotonically decreasing across the band', () {
    var prev = halo.alphaAt(halo.innerRadius);
    for (var r = halo.innerRadius; r <= halo.outerRadius + 5.0; r += 0.5) {
      final a = halo.alphaAt(r);
      expect(a, lessThanOrEqualTo(prev + 1e-12));
      expect(a, inInclusiveRange(0.0, 1.0));
      prev = a;
    }
  });

  test('alpha sits between full and zero midway through the band', () {
    final mid = (halo.innerRadius + halo.outerRadius) / 2;
    final a = halo.alphaAt(mid);
    expect(a, greaterThan(0.0));
    expect(a, lessThan(1.0));
    expect(a, closeTo(0.5, 1e-9));
  });
}
