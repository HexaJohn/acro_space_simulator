// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/megastructure/halo_ring.dart';
import 'package:acro_space_simulator/domain/megastructure/halo_ring_mesher.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_edits.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const spec = HaloRingSpec(radiusM: 5.0e6);
  final field = spec.field();
  final grid = HaloRingGrid(spec);

  group('grid addressing', () {
    test('covers the whole band with ~square cells', () {
      expect(grid.cellsAround * grid.cellArcRad, closeTo(2 * math.pi, 1e-9));
      expect(grid.cellsAcross * grid.cellSpanM,
          closeTo(2 * spec.interiorHalfWidthM, 1e-6));
      // ~square: arc length within 2x of span.
      final arcM = spec.radiusM * grid.cellArcRad;
      expect(arcM / grid.cellSpanM, inInclusiveRange(0.5, 2.0));
    });

    test('cellAt inverts phiOf/zOf and wraps phi', () {
      final key = grid.cellAt(grid.phiOf(17), grid.zOf(3));
      expect(key, const RingCellKey(17, 3));
      final wrapped = grid.cellAt(grid.phiOf(17) - 2 * math.pi, grid.zOf(3));
      expect(wrapped, const RingCellKey(17, 3));
      expect(grid.wrapI(-1), grid.cellsAround - 1);
      expect(grid.wrapI(grid.cellsAround), 0);
    });
  });

  group('meshHaloRingCell', () {
    final cell = meshHaloRingCell(field, grid, const RingCellKey(5, 4));

    test('produces a surface', () {
      expect(cell.mesh.isEmpty, isFalse);
      expect(cell.mesh.triangleCount, greaterThan(50));
    });

    test('local vertices stay near the cell (anchored, float32-safe)', () {
      final p = cell.mesh.positions;
      final bound = grid.cellSpanM + spec.terrainAmplitudeM + 200;
      for (var i = 0; i < p.length; i++) {
        expect(p[i].isFinite, isTrue);
        expect(p[i].abs(), lessThan(bound),
            reason: 'vertex component $i escaped the local frame');
      }
    });

    test('anchor sits on the floor datum cylinder', () {
      final a = cell.anchorRF;
      final rho = math.sqrt(a.x * a.x + a.y * a.y);
      expect(rho, closeTo(spec.radiusM, 1e-6));
    });

    test('local frame maps +Z to radially inward', () {
      final inward = cell.localToRing.rotate(Vector3(0, 0, 1));
      final a = cell.anchorRF;
      final outward =
          Vector3(a.x, a.y, 0) / math.sqrt(a.x * a.x + a.y * a.y);
      expect(inward.dot(outward), closeTo(-1, 1e-9));
    });

    test('reconstructed ring-frame surface lies near the floor radius', () {
      final p = cell.mesh.positions;
      // Sample a handful of vertices, push them through anchor+rotation, and
      // check the cylindrical radius lands within the relief band.
      for (var v = 0; v < p.length ~/ 3; v += 97) {
        final local = Vector3(p[v * 3], p[v * 3 + 1], p[v * 3 + 2]);
        final ring = cell.anchorRF + cell.localToRing.rotate(local);
        final rho = math.sqrt(ring.x * ring.x + ring.y * ring.y);
        expect(
            rho,
            inInclusiveRange(spec.radiusM - spec.terrainAmplitudeM - 60,
                spec.radiusM + spec.terrainAmplitudeM + 60));
      }
    });

    test('deterministic', () {
      final again = meshHaloRingCell(field, grid, const RingCellKey(5, 4));
      expect(again.mesh.positions, cell.mesh.positions);
      expect(again.mesh.indices, cell.mesh.indices);
    });

    test('a mining brush changes the meshed surface', () {
      final key = const RingCellKey(5, 4);
      final centrePhi = grid.phiOf(key.i);
      final floor = field.surfacePointAt(centrePhi, grid.zOf(key.j));
      final edits = TerrainEdits()
        ..add(TerrainBrush.sphere(centreBF: floor, radiusM: 30));
      final dug = meshHaloRingCell(field.withEdits(edits), grid, key);
      expect(dug.mesh.positions, isNot(equals(cell.mesh.positions)),
          reason: 'the crater must show up in the voxel mesh');
    });
  });
}
