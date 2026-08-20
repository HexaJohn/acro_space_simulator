// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/megastructure/halo_ring.dart';
import 'package:acro_space_simulator/domain/megastructure/halo_ring_meshes.dart';
import 'package:acro_space_simulator/domain/terrain/surface_nets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const spec = HaloRingSpec(radiusM: 5.0e6);
  final field = spec.field();

  void expectSane(SurfaceMesh m,
      {required double rhoMin, required double rhoMax, double zSlackM = 1}) {
    expect(m.isEmpty, isFalse);
    expect(m.positions.length, m.normals.length);
    for (var v = 0; v < m.vertexCount; v++) {
      final x = m.positions[v * 3], y = m.positions[v * 3 + 1];
      final z = m.positions[v * 3 + 2];
      expect(x.isFinite && y.isFinite && z.isFinite, isTrue);
      final rho = math.sqrt(x * x + y * y);
      expect(rho, inInclusiveRange(rhoMin, rhoMax));
      expect(z.abs(), lessThanOrEqualTo(spec.halfWidthM + zSlackM));
    }
    for (final i in m.indices) {
      expect(i, lessThan(m.vertexCount));
    }
  }

  group('hullBandMesh', () {
    test('full ring is sane and bounded by the cross-section', () {
      expectSane(hullBandMesh(spec),
          rhoMin: spec.crestRadiusM - 1, rhoMax: spec.outerRadiusM + 1);
    });

    test('coverage grows the mesh; zero coverage is empty', () {
      expect(hullBandMesh(spec, arcCoverage: 0).isEmpty, isTrue);
      final half = hullBandMesh(spec, arcCoverage: 0.5);
      final full = hullBandMesh(spec);
      expect(half.triangleCount, lessThan(full.triangleCount));
      expect(half.triangleCount, greaterThan(0));
    });

    test('the deck recedes as terrain pours', () {
      final bare = hullBandMesh(spec, arcCoverage: 1, deckArcStart: 0);
      final poured = hullBandMesh(spec, arcCoverage: 1, deckArcStart: 0.6);
      expect(poured.triangleCount, lessThan(bare.triangleCount));
    });
  });

  group('trussMesh', () {
    test('full skeleton is sane', () {
      // Struts are centred on the hull envelope corners, so their bodies
      // protrude half a strut past every extent.
      expectSane(trussMesh(spec),
          rhoMin: spec.crestRadiusM - 400,
          rhoMax: spec.outerRadiusM + 400,
          zSlackM: 400);
    });

    test('zero coverage is empty, partial is smaller', () {
      expect(trussMesh(spec, arcCoverage: 0).isEmpty, isTrue);
      expect(trussMesh(spec, arcCoverage: 0.25).triangleCount,
          lessThan(trussMesh(spec).triangleCount));
    });
  });

  group('terrainStripMesh', () {
    test('hugs the floor within relief bounds (sunk below the surface)', () {
      expectSane(terrainStripMesh(field),
          rhoMin: spec.radiusM - spec.terrainAmplitudeM - 1,
          rhoMax: spec.radiusM + spec.terrainAmplitudeM + haloStripSinkM + 1);
    });

    test('zero coverage is empty', () {
      expect(terrainStripMesh(field, arcCoverage: 0).isEmpty, isTrue);
    });
  });

  group('crestLightsMesh', () {
    test('two ribbons at the crest', () {
      expectSane(crestLightsMesh(spec),
          rhoMin: spec.crestRadiusM - 3, rhoMax: spec.crestRadiusM);
    });
  });
}
