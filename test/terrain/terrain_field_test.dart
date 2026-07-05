import 'dart:math' as math;

import 'package:acro_space_simulator/domain/terrain/noise3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ValueNoise3', () {
    test('deterministic and bounded 0..1', () {
      const n = ValueNoise3(0x1234);
      for (var i = 0; i < 200; i++) {
        final x = i * 0.37, y = i * 1.11, z = i * 0.53;
        final a = n.noise(x, y, z);
        expect(a, inInclusiveRange(0.0, 1.0));
        expect(n.noise(x, y, z), a); // same input -> same output
        expect(n.fbm(x, y, z), inInclusiveRange(0.0, 1.0));
      }
    });

    test('seed changes the field', () {
      const a = ValueNoise3(1), b = ValueNoise3(2);
      var differ = 0;
      for (var i = 0; i < 50; i++) {
        if ((a.fbm(i * 0.7, 0.2, 0.9) - b.fbm(i * 0.7, 0.2, 0.9)).abs() > 1e-6) {
          differ++;
        }
      }
      expect(differ, greaterThan(40));
    });
  });

  group('TerrainField', () {
    final field = TerrainField(
      radius: 1.7374e6,
      amplitude: 4000,
      featureScale: 60000,
      seed: 0x11A00,
    );

    test('height stays within +/- amplitude', () {
      final rng = math.Random(7);
      for (var i = 0; i < 500; i++) {
        // random unit direction
        var x = rng.nextDouble() * 2 - 1;
        var y = rng.nextDouble() * 2 - 1;
        var z = rng.nextDouble() * 2 - 1;
        final len = math.sqrt(x * x + y * y + z * z);
        if (len < 1e-6) continue;
        x /= len; y /= len; z /= len;
        final h = field.heightInDirection(x, y, z);
        expect(h.abs(), lessThanOrEqualTo(4000 + 1e-6));
      }
    });

    test('density sign: solid below the surface, air above', () {
      const dx = 0.3, dy = 0.6, dz = 0.74; // ~unit-ish direction
      final len = math.sqrt(dx * dx + dy * dy + dz * dz);
      final ux = dx / len, uy = dy / len, uz = dz / len;
      final surf = field.groundRadiusAt(ux, uy, uz);
      // Well below the surface -> solid (negative).
      expect(field.density(ux * (surf - 1000), uy * (surf - 1000), uz * (surf - 1000)),
          lessThan(0));
      // Well above -> air (positive).
      expect(field.density(ux * (surf + 1000), uy * (surf + 1000), uz * (surf + 1000)),
          greaterThan(0));
    });

    test('groundRadiusAt is the zero-crossing of density', () {
      final rng = math.Random(3);
      for (var i = 0; i < 100; i++) {
        var x = rng.nextDouble() * 2 - 1;
        var y = rng.nextDouble() * 2 - 1;
        var z = rng.nextDouble() * 2 - 1;
        final len = math.sqrt(x * x + y * y + z * z);
        if (len < 1e-6) continue;
        x /= len; y /= len; z /= len;
        final gr = field.groundRadiusAt(x, y, z);
        expect(field.density(x * gr, y * gr, z * gr).abs(), lessThan(1e-3),
            reason: 'density at the ground radius should be ~0');
        // Ground radius sits within the datum +/- amplitude band.
        expect(gr, inInclusiveRange(1.7374e6 - 4000, 1.7374e6 + 4000));
      }
    });

    test('deterministic across instances with the same seed', () {
      final a = TerrainField(radius: 1e6, amplitude: 2000, featureScale: 50000, seed: 42);
      final b = TerrainField(radius: 1e6, amplitude: 2000, featureScale: 50000, seed: 42);
      expect(a.density(1e6, 2e5, 3e5), b.density(1e6, 2e5, 3e5));
    });
  });
}
