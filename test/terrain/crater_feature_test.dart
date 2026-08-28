// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/crater_feature.dart';
import 'package:acro_space_simulator/domain/terrain/exotic_features.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_control.dart';
import 'package:flutter_test/flutter_test.dart';

const double _moonRadius = 1.7374e6;
const double _europaRadius = 1.5608e6;

List<Vector3> sphereDirections(int n) {
  final golden = math.pi * (3.0 - math.sqrt(5.0));
  return [
    for (var i = 0; i < n; i++)
      () {
        final y = 1.0 - 2.0 * (i + 0.5) / n;
        final r = math.sqrt(math.max(0.0, 1.0 - y * y));
        final t = golden * i;
        return Vector3(math.cos(t) * r, y, math.sin(t) * r);
      }(),
  ];
}

void main() {
  group('crater profile', () {
    test('is a bowl inside, a rim at the edge, and nothing far out', () {
      const rimOverDepth = 0.2, reach = 2.5;
      // Centre is the deepest point.
      expect(CraterFeature.profile(0, rimOverDepth, reach), closeTo(-1.0, 1e-9));
      // Rises monotonically out of the bowl.
      var previous = CraterFeature.profile(0, rimOverDepth, reach);
      for (var x = 0.05; x < 1.0; x += 0.05) {
        final v = CraterFeature.profile(x, rimOverDepth, reach);
        expect(v, greaterThan(previous));
        previous = v;
      }
      // Crest stands above the surrounding datum.
      expect(CraterFeature.profile(1.0, rimOverDepth, reach),
          closeTo(rimOverDepth, 1e-9));
      // Ejecta decays to exactly zero at the reach, and stays there.
      expect(CraterFeature.profile(reach, rimOverDepth, reach), 0);
      expect(CraterFeature.profile(reach + 5, rimOverDepth, reach), 0);
    });

    test('is continuous across the rim join', () {
      // A step here would show as a hard ring in the mesh.
      const rimOverDepth = 0.2, reach = 2.5;
      final inside = CraterFeature.profile(1.0 - 1e-7, rimOverDepth, reach);
      final outside = CraterFeature.profile(1.0 + 1e-7, rimOverDepth, reach);
      expect((inside - outside).abs(), lessThan(1e-5));
    });

    test('decays monotonically through the ejecta blanket', () {
      var previous = CraterFeature.profile(1.0, 0.2, 2.5);
      for (var x = 1.1; x < 2.5; x += 0.1) {
        final v = CraterFeature.profile(x, 0.2, 2.5);
        expect(v, lessThan(previous));
        expect(v, greaterThanOrEqualTo(0));
        previous = v;
      }
    });
  });

  group('CraterFeature', () {
    const control = UniformControl(relief: 3000, roughness: 1.0);
    const feature = CraterFeature(seed: 0x11A00, radiusM: _moonRadius);

    test('is deterministic', () {
      for (final d in sphereDirections(200)) {
        expect(feature.heightAt(d, control), feature.heightAt(d, control));
      }
    });

    test('actually cuts craters — most of the surface is affected', () {
      var touched = 0;
      final dirs = sphereDirections(1000);
      for (final d in dirs) {
        if (feature.heightAt(d, control).abs() > 1.0) touched++;
      }
      expect(touched, greaterThan(dirs.length ~/ 2),
          reason: 'a saturated surface should be mostly cratered');
    });

    test('digs down more than it builds up', () {
      // Craters are excavations: the mean must be negative, and the deepest
      // point far deeper than the highest rim is tall.
      final values = [
        for (final d in sphereDirections(2000)) feature.heightAt(d, control)
      ];
      final mean = values.reduce((a, b) => a + b) / values.length;
      expect(mean, lessThan(0));
      expect(values.reduce(math.min).abs(),
          greaterThan(values.reduce(math.max)));
    });

    test('stays inside its declared bound', () {
      final bound = feature.maxMagnitude(3000);
      for (final d in sphereDirections(3000)) {
        expect(feature.heightAt(d, control).abs(), lessThanOrEqualTo(bound));
      }
    });

    test('roughness gates retention — smooth ground keeps no craters', () {
      // Young resurfaced plains should be nearly crater-free, which is what
      // makes Io and Europa look nothing like the Moon.
      const resurfaced = UniformControl(relief: 3000, roughness: 0);
      for (final d in sphereDirections(200)) {
        expect(feature.heightAt(d, resurfaced), 0);
      }
    });

    test('the seed changes the crater field', () {
      const other = CraterFeature(seed: 0xBEEF, radiusM: _moonRadius);
      var differing = 0;
      for (final d in sphereDirections(300)) {
        if ((feature.heightAt(d, control) - other.heightAt(d, control)).abs() >
            1.0) {
          differing++;
        }
      }
      expect(differing, greaterThan(250));
    });

    test('minRadiusM culls the fine decades', () {
      const coarse = CraterFeature(
          seed: 0x11A00, radiusM: _moonRadius, minRadiusM: 20000);
      // Coverage is the wrong measure: a single decade of 40 km craters with
      // 100 km of ejecta already blankets the whole Moon, so both fields touch
      // every sample. What culling removes is FINE-SCALE variation, so measure
      // that — how much the field changes over a short step.
      double roughness(CraterFeature f) {
        var sum = 0.0;
        final dirs = sphereDirections(400);
        for (final d in dirs) {
          final seed = d.x.abs() < 0.9 ? Vector3.unitX : Vector3.unitY;
          final tangent = seed.cross(d).normalized;
          final near = (d + tangent * (600 / _moonRadius)).normalized;
          sum += (f.heightAt(d, control) - f.heightAt(near, control)).abs();
        }
        return sum / dirs.length;
      }
      // Culling the fine decades removes MOST of the short-step variation.
      //
      // It would remove only about half if depth were a fixed fraction of
      // diameter, since then every decade has the same characteristic slope and
      // the four add in quadrature. But the simple-to-complex break means large
      // craters are proportionally SHALLOWER — depth grows as D^0.3 past the
      // transition — so the coarse decades are gentler than the fine ones and
      // contribute far less slope. Leaving only the coarsest leaves ~1/5.
      expect(roughness(coarse), lessThan(roughness(feature) * 0.35));
      expect(roughness(coarse), greaterThan(roughness(feature) * 0.1));
    });

    test('density 0 produces a pristine surface', () {
      const none =
          CraterFeature(seed: 1, radiusM: _moonRadius, density: 0);
      for (final d in sphereDirections(200)) {
        expect(none.heightAt(d, control), 0);
      }
    });

    test('is continuous: no pop-in at lattice cell walls', () {
      // REGRESSION: the cell scan used to cover +-1 cells, but a crater can
      // draw up to _sizeMax (1.45x) its decade radius with ejecta reaching 2.5
      // radii — an influence of ~1.65 lattice pitches, more than the 1.0 pitch
      // a +-1 window guarantees. Craters in Chebyshev-distance-2 cells popped
      // in and out of the sum as the window slid across cell walls, stepping
      // the ground by a rim-tail's height (hundreds of metres in the coarsest
      // decade) along walls all over the body.
      //
      // Detector: a discontinuity keeps the largest one-step height delta
      // CONSTANT as the step shrinks, while a continuous field shrinks it
      // linearly. Walk a great circle crossing many coarsest-decade walls,
      // find the worst step, then re-measure the same spot with a step 16x
      // smaller.
      final tanA = Vector3.unitX;
      final tanB = Vector3(0, 0.6, 0.8).normalized;
      double at(double theta) => feature.heightAt(
          (tanA * math.cos(theta) + tanB * math.sin(theta)).normalized,
          control);

      const h = 4.0e-5; // ~70 m of ground per step
      const steps = 8000; // ~0.32 rad: several 40 km-decade pitches
      var worstTheta = 0.0, worstDelta = -1.0;
      var prev = at(0);
      for (var i = 1; i <= steps; i++) {
        final theta = i * h;
        final v = at(theta);
        final delta = (v - prev).abs();
        if (delta > worstDelta) {
          worstDelta = delta;
          worstTheta = theta;
        }
        prev = v;
      }
      // Refine across the worst step with a 16x finer step; take the largest
      // sub-step. Continuous ground shrinks ~16x; a pop-in stays put.
      var refined = -1.0;
      var p = at(worstTheta - h);
      for (var i = 1; i <= 16; i++) {
        final v = at(worstTheta - h + i * h / 16);
        final d = (v - p).abs();
        if (d > refined) refined = d;
        p = v;
      }
      expect(refined, lessThan(worstDelta * 0.3),
          reason: 'worst step ${worstDelta.toStringAsFixed(1)} m at '
              'theta=$worstTheta does not shrink with the step size — '
              'a crater is popping in/out of the cell window');
    });
  });

  group('LineaFeature', () {
    final europa = SyntheticControl(
      seed: 0xE0F0BA,
      radiusM: _europaRadius,
      reliefScaleM: 300, // Europa's global relief really is this small
      lineation: 1.0,
    );
    final linea = LineaFeature(seed: 0xE0, radiusM: _europaRadius);

    test('is deterministic and bounded', () {
      for (final d in sphereDirections(300)) {
        final h = linea.heightAt(d, europa);
        expect(h, linea.heightAt(d, europa));
        expect(h.abs(), lessThanOrEqualTo(europa.reliefAt(d) + 1e-9));
      }
    });

    test('produces nothing without a lineation field', () {
      const isotropic = UniformControl(relief: 300);
      for (final d in sphereDirections(100)) {
        expect(linea.heightAt(d, isotropic), 0);
      }
    });

    test('is ANISOTROPIC — some directions vary far more than others', () {
      // The defining property, tested without assuming which way the ridges
      // happen to run: sweep tangent directions and compare the calmest
      // against the busiest. An isotropic field changes at the same rate
      // whichever way you walk and could never make a linea.
      final base = const Vector3(0.3, 0.5, 0.81).normalized;
      final t = Vector3.unitZ.cross(base).normalized;
      final b = base.cross(t);
      const stepM = 3000.0;
      final h0 = linea.heightAt(base, europa);

      final variation = <double>[];
      for (var a = 0; a < 12; a++) {
        final theta = math.pi * a / 12;
        final axis = t * math.cos(theta) + b * math.sin(theta);
        var change = 0.0;
        for (var i = 1; i <= 8; i++) {
          final p =
              (base + axis * (stepM * i / _europaRadius)).normalized;
          change += (linea.heightAt(p, europa) - h0).abs();
        }
        variation.add(change);
      }
      final calmest = variation.reduce(math.min);
      final busiest = variation.reduce(math.max);
      expect(busiest, greaterThan(calmest * 2.0),
          reason: 'expected a strongly preferred direction, got '
              'calmest=$calmest busiest=$busiest');
    });
  });

  group('DuneFeature', () {
    final titan = SyntheticControl(
      seed: 0x71714,
      radiusM: 2.5747e6,
      reliefScaleM: 500,
      lineation: 1.0,
    );
    final dunes =
        DuneFeature(seed: 0x71, radiusM: 2.5747e6, wavelengthM: 3000);

    test('is deterministic and never exceeds the dune height', () {
      for (final d in sphereDirections(300)) {
        final h = dunes.heightAt(d, titan);
        expect(h, dunes.heightAt(d, titan));
        expect(h, inInclusiveRange(0.0, 120.0 + 1e-9));
      }
    });

    test('is PERIODIC across the wind, unlike noise', () {
      // Dune fields have a characteristic spacing, and no fBm sum produces one.
      // The dunes are zonal, so "across the wind" is a traverse in LATITUDE.
      const radius = 2.5747e6;
      final samples = <double>[];
      for (var i = 0; i < 500; i++) {
        // 30 km of latitude, from the equator north, in 60 m steps.
        final lat = i * 60.0 / radius;
        final p = Vector3(math.cos(lat), 0, math.sin(lat));
        samples.add(dunes.heightAt(p, titan));
      }
      // At 3 km spacing, 30 km of traverse should hold ~10 crests.
      var crests = 0;
      for (var i = 1; i < samples.length - 1; i++) {
        if (samples[i] > samples[i - 1] &&
            samples[i] >= samples[i + 1] &&
            samples[i] > 20) {
          crests++;
        }
      }
      expect(crests, greaterThan(5), reason: 'expected a repeating dune train');
    });

    test('fades out away from the equator', () {
      // An equatorial habit, like Titan's real dune seas.
      final polar = Vector3(0.1, 0.0, 0.995).normalized;
      expect(dunes.heightAt(polar, titan), 0);
    });

    test('produces nothing without a lineation field', () {
      const isotropic = UniformControl(relief: 500);
      for (final d in sphereDirections(100)) {
        expect(dunes.heightAt(d, isotropic), 0);
      }
    });
  });
}
