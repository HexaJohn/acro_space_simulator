// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/scatter/prop_catalog.dart';
import 'package:acro_space_simulator/domain/scatter/prop_mesh.dart';
import 'package:acro_space_simulator/domain/scatter/prop_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _meshLods = [PropLod.lod0, PropLod.lod1, PropLod.lod2];

void main() {
  group('every prop kind generates sane geometry', () {
    for (final kind in PropKind.values) {
      test(kind.name, () {
        final set = buildProp(kind, seed: 7);

        expect(set[PropLod.lod0].isEmpty, isFalse,
            reason: '$kind produced no geometry at all');
        expect(set.heightM, greaterThan(0.0));
        expect(set.radiusM, greaterThan(0.0));

        for (final lod in _meshLods) {
          final model = set[lod];
          for (final mesh in [model.solid, model.foliage]) {
            if (mesh.isEmpty) continue;
            // Attribute arrays must agree on vertex count, or the geometry
            // upload reads past the end of one of them.
            expect(mesh.normals.length, mesh.positions.length,
                reason: '$kind $lod normals/positions mismatch');
            expect(mesh.texCoords.length ~/ 2, mesh.vertexCount,
                reason: '$kind $lod texCoords/positions mismatch');
            expect(mesh.indices.length % 3, 0,
                reason: '$kind $lod index count is not a triangle multiple');
            for (final i in mesh.indices) {
              expect(i, lessThan(mesh.vertexCount),
                  reason: '$kind $lod index out of range');
            }
            for (final v in mesh.positions) {
              expect(v.isFinite, isTrue,
                  reason: '$kind $lod produced a non-finite position');
            }
            for (final n in mesh.normals) {
              expect(n.isFinite, isTrue,
                  reason: '$kind $lod produced a non-finite normal');
            }
          }
        }
      });
    }
  });

  test('props sit on the ground plane, not through it or above it', () {
    for (final kind in PropKind.values) {
      final b = buildProp(kind, seed: 3).bounds;
      // The origin is the ground contact point. A little geometry below zero is
      // fine (a rock is modelled part-buried, a blade splays outward), but a
      // prop whose whole base floats would hover over the terrain.
      expect(b.min.z, greaterThan(-b.heightM * 0.5),
          reason: '$kind sinks too far below its origin');
      expect(b.min.z, lessThan(b.heightM * 0.1),
          reason: '$kind floats above its origin');
    }
  });

  test('coarser LODs cost fewer triangles', () {
    for (final kind in PropKind.values) {
      final set = buildProp(kind, seed: 11);
      final counts = [
        for (final lod in _meshLods) set[lod].triangleCount,
      ];
      expect(counts[1], lessThan(counts[0]),
          reason: '$kind lod1 (${counts[1]}) is not cheaper than lod0 '
              '(${counts[0]})');
      expect(counts[2], lessThan(counts[1]),
          reason: '$kind lod2 (${counts[2]}) is not cheaper than lod1 '
              '(${counts[1]})');
    }
  });

  test('coarser LODs keep the silhouette they stand in for', () {
    for (final kind in PropKind.values) {
      final set = buildProp(kind, seed: 5);
      final full = set.bounds;
      for (final lod in [PropLod.lod1, PropLod.lod2]) {
        final coarse = set[lod].bounds;
        // Height and width may drift a little as detail is dropped, but a
        // level that loses a third of its extent will visibly pop on switch.
        expect(coarse.heightM, greaterThan(full.heightM * 0.7),
            reason: '$kind $lod lost too much height');
        expect(coarse.heightM, lessThan(full.heightM * 1.3),
            reason: '$kind $lod grew too much');
        expect(coarse.radiusM, greaterThan(full.radiusM * 0.6),
            reason: '$kind $lod lost too much width');
      }
    }
  });

  test('the same seed always grows the same prop', () {
    for (final kind in PropKind.values) {
      final a = buildProp(kind, seed: 99)[PropLod.lod0];
      final b = buildProp(kind, seed: 99)[PropLod.lod0];
      expect(_bytesOf(a.solid), _bytesOf(b.solid), reason: '$kind solid');
      expect(_bytesOf(a.foliage), _bytesOf(b.foliage), reason: '$kind foliage');
    }
  });

  test('different seeds grow different individuals', () {
    for (final kind in PropKind.values) {
      final a = buildProp(kind, seed: 1)[PropLod.lod0];
      final b = buildProp(kind, seed: 2)[PropLod.lod0];
      expect(_bytesOf(a.solid) == _bytesOf(b.solid) &&
          _bytesOf(a.foliage) == _bytesOf(b.foliage),
          isFalse,
          reason: '$kind ignored its seed');
    }
  });

  test('every kind produces an imposter that covers its silhouette', () {
    for (final kind in PropKind.values) {
      final set = buildProp(kind, seed: 4);
      final imp = set.imposter;
      expect(imp.isEmpty, isFalse, reason: '$kind has no imposter shapes');
      expect(imp.heightM, greaterThan(0.0));
      expect(imp.widthM, greaterThan(0.0));
      // Card space is normalised: nothing may reach beyond the card it is
      // painted into, or the billboard clips the prop it replaces.
      for (final blob in imp.blobs) {
        expect(blob.x.abs(), lessThanOrEqualTo(1.0), reason: '$kind blob x');
        expect(blob.y, inInclusiveRange(-0.5, 1.5), reason: '$kind blob y');
      }
    }
  });

  test('grass and ferns never cost an opaque draw', () {
    // Ground cover is scattered by the tens of thousands; any solid geometry
    // on it would add a second instanced draw per patch for no visual gain.
    for (final kind in [PropKind.grassTuft, PropKind.fern, PropKind.reeds]) {
      for (final lod in _meshLods) {
        expect(buildProp(kind, seed: 8)[lod].solid.isEmpty, isTrue,
            reason: '$kind $lod grew solid geometry');
      }
    }
  });

  test('rocks are pure opaque geometry', () {
    for (final kind in [
      PropKind.boulder,
      PropKind.rockShard,
      PropKind.rockSlab,
      PropKind.rockCluster,
    ]) {
      final model = buildProp(kind, seed: 8)[PropLod.lod0];
      expect(model.solid.isEmpty, isFalse);
      expect(model.foliage.isEmpty, isTrue, reason: '$kind grew foliage');
    }
  });

  test('size overrides scale the prop', () {
    final small = buildProp(PropKind.coniferTree, seed: 2, sizeM: 6.0);
    final large = buildProp(PropKind.coniferTree, seed: 2, sizeM: 24.0);
    expect(large.heightM, greaterThan(small.heightM * 3.0));
    expect(large.radiusM, greaterThan(small.radiusM * 2.0));
  });
}

/// A cheap structural fingerprint — enough to tell two generated meshes apart
/// without comparing megabytes of floats element by element.
String _bytesOf(PropMesh m) {
  var sum = 0.0;
  for (final v in m.positions) {
    sum = sum * 1.0000001 + v;
  }
  return '${m.vertexCount}/${m.triangleCount}/${sum.toStringAsFixed(6)}';
}
