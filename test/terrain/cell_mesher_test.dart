// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cell_mesher.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:flutter_test/flutter_test.dart';

TerrainField _moon() => TerrainField(
      radius: 1.7374e6,
      amplitude: 4000,
      featureScale: 60000,
      seed: 0x11A00,
    );

void main() {
  final field = _moon();

  group('meshTerrainCell', () {
    test('produces geometry for a mid-level chunk', () {
      final k = chunkAt(const Vector3(0.3, 0.4, 0.87).normalized, 6);
      final cell = meshTerrainCell(field, k, resolution: 16);
      expect(cell.isEmpty, isFalse);
      expect(cell.mesh.triangleCount, greaterThan(0));
      expect(cell.chunk, k);
      expect(cell.clipped, isFalse);
    });

    test('the shell contains the surface at every level', () {
      // The clipped flag is the mesher's own containment check: inner shell all
      // solid, outer shell all air.
      for (final level in [2, 4, 6, 8, 10]) {
        for (final d in [
          const Vector3(0, 0, 1),
          const Vector3(1, 0, 0),
          const Vector3(0.3, -0.7, 0.6),
          const Vector3(-0.5, 0.5, -0.7),
        ]) {
          final k = chunkAt(d.normalized, level);
          final cell = meshTerrainCell(field, k, resolution: 12);
          expect(cell.clipped, isFalse,
              reason: 'level $level dir $d escaped the radial band');
        }
      }
    });

    test('vertices lie on the isosurface', () {
      // skirtVoxels 0: the apron deliberately hangs BELOW the surface, so it is
      // excluded here and covered by its own tests instead.
      final k = chunkAt(const Vector3(0.2, 0.9, 0.35).normalized, 7);
      final cell = meshTerrainCell(field, k, resolution: 16, skirtVoxels: 0);
      expect(cell.isEmpty, isFalse);

      // Tolerance scales with voxel size: Surface Nets places a vertex at the
      // averaged edge crossing, not exactly on the surface.
      final voxel = k.circumradiusM(field.radius) * 2 / 16;
      final p = cell.mesh.positions;
      var worst = 0.0;
      for (var i = 0; i < p.length; i += 3) {
        final w = cell.anchorBF + Vector3(p[i], p[i + 1], p[i + 2]);
        final dens = field.density(w.x, w.y, w.z).abs();
        if (dens > worst) worst = dens;
      }
      expect(worst, lessThan(voxel),
          reason: 'worst |density| $worst exceeded one voxel $voxel');
    });

    test('normals point outward and are unit length', () {
      final k = chunkAt(const Vector3(-0.6, 0.2, 0.77).normalized, 6);
      final cell = meshTerrainCell(field, k, resolution: 16);
      final p = cell.mesh.positions, nrm = cell.mesh.normals;
      expect(nrm.length, p.length);
      for (var i = 0; i < nrm.length; i += 3) {
        final n = Vector3(nrm[i], nrm[i + 1], nrm[i + 2]);
        expect(n.length, closeTo(1.0, 1e-5));
        // Outward: on relief this gentle, every normal has a positive radial
        // component (no overhangs in a height field).
        final w = cell.anchorBF + Vector3(p[i], p[i + 1], p[i + 2]);
        expect(n.dot(w.normalized), greaterThan(0.0),
            reason: 'inward-facing normal at vertex ${i ~/ 3}');
      }
    });

    test('vertices stay inside the cell plus its apron', () {
      final k = chunkAt(const Vector3(0.1, 0.2, 0.97).normalized, 5);
      const res = 16;
      // Bare surface: the skirt intentionally drops below innerRadiusM.
      final cell = meshTerrainCell(field, k, resolution: res, skirtVoxels: 0);
      // One apron cell on each side, in face (s,t) units.
      final ds = (k.s1 - k.s0) / res, dt = (k.t1 - k.t0) / res;
      final p = cell.mesh.positions;
      for (var i = 0; i < p.length; i += 3) {
        final w = cell.anchorBF + Vector3(p[i], p[i + 1], p[i + 2]);
        final dir = w.normalized;
        // Apron can spill onto a neighbouring face at a cell edge; project onto
        // THIS cell's face regardless, which is what the mapping used.
        final st = faceST(k.face, dir);
        expect(st.s, inInclusiveRange(k.s0 - ds * 1.5, k.s1 + ds * 1.5));
        expect(st.t, inInclusiveRange(k.t0 - dt * 1.5, k.t1 + dt * 1.5));
        final r = w.length;
        expect(r, inInclusiveRange(cell.innerRadiusM, cell.outerRadiusM));
      }
    });

    test('the shell thins as chunks get smaller', () {
      // The whole point of §1: a deep chunk must not carry a coarse chunk's
      // radial extent, or voxel count explodes with chunk count.
      final d = const Vector3(0.5, 0.5, 0.7).normalized;
      var prev = double.infinity;
      for (final level in [4, 6, 8, 10]) {
        final cell = meshTerrainCell(field, chunkAt(d, level), resolution: 12);
        final band = cell.outerRadiusM - cell.innerRadiusM;
        expect(band, lessThan(prev), reason: 'level $level band $band');
        prev = band;
      }
    });

    test('radial sample count stays bounded', () {
      for (final level in [0, 2, 5, 9, 12]) {
        final k = chunkAt(const Vector3(0.4, 0.4, 0.8).normalized, level);
        final cell = meshTerrainCell(field, k, resolution: 8, maxRadialSamples: 48);
        expect(cell.radialSamples, lessThanOrEqualTo(49));
        expect(cell.radialSamples, greaterThanOrEqualTo(3));
      }
    });

    test('deterministic: same key gives byte-identical geometry', () {
      // Plan §8 — and the precondition for meshing off-thread in 4c.
      final k = chunkAt(const Vector3(0.33, -0.21, 0.92).normalized, 7);
      final a = meshTerrainCell(field, k, resolution: 16);
      final b = meshTerrainCell(_moon(), k, resolution: 16);
      expect(a.mesh.positions, b.mesh.positions);
      expect(a.mesh.normals, b.mesh.normals);
      expect(a.mesh.indices, b.mesh.indices);
      expect(a.anchorBF.x, b.anchorBF.x);
      expect(a.innerRadiusM, b.innerRadiusM);
    });

    test('anchor sits on the ground at the cell centre', () {
      for (final level in [3, 6, 9]) {
        final k = chunkAt(const Vector3(-0.2, 0.8, 0.55).normalized, level);
        final cell = meshTerrainCell(field, k, resolution: 8);
        final a = cell.anchorBF;
        expect(field.density(a.x, a.y, a.z).abs(), lessThan(1e-3));
        // And the local vertices really are local — that is the float32 fix.
        final span = k.circumradiusM(field.radius) * 3;
        for (var i = 0; i < cell.mesh.positions.length; i++) {
          expect(cell.mesh.positions[i].abs(), lessThan(span));
        }
      }
    });

    test('neighbouring chunks meet at the shared edge', () {
      // Same-level neighbours must not leave a visible gap: their aprons
      // overlap, so the surfaces should coincide near the seam.
      final k = chunkAt(const Vector3(0.35, 0.35, 0.87).normalized, 7);
      final nb = k.neighbour(ChunkEdge.plusS);
      expect(nb.level, k.level);

      final a = meshTerrainCell(field, k, resolution: 16, skirtVoxels: 0);
      final b = meshTerrainCell(field, nb, resolution: 16, skirtVoxels: 0);
      expect(a.isEmpty, isFalse);
      expect(b.isEmpty, isFalse);

      // Every vertex of each mesh is on the same isosurface, so sampling the
      // field at one chunk's vertices must agree with the other's field.
      final voxel = k.circumradiusM(field.radius) * 2 / 16;
      for (final cell in [a, b]) {
        final p = cell.mesh.positions;
        for (var i = 0; i < p.length; i += 3) {
          final w = cell.anchorBF + Vector3(p[i], p[i + 1], p[i + 2]);
          expect(field.density(w.x, w.y, w.z).abs(), lessThan(voxel * 1.5));
        }
      }
    });

    test('a flat field still meshes a closed sheet', () {
      // Zero relief is the degenerate case: the isosurface is an exact sphere,
      // which can sit precisely on a lattice plane.
      final flat = TerrainField(
        radius: 1.0e6,
        amplitude: 0,
        featureScale: 50000,
        seed: 7,
      );
      final k = chunkAt(const Vector3(0, 0, 1), 5);
      final cell = meshTerrainCell(flat, k, resolution: 12, skirtVoxels: 0);
      expect(cell.clipped, isFalse);
      expect(cell.isEmpty, isFalse);
      final p = cell.mesh.positions;
      for (var i = 0; i < p.length; i += 3) {
        final w = cell.anchorBF + Vector3(p[i], p[i + 1], p[i + 2]);
        expect((w.length - flat.radius).abs(), lessThan(200),
            reason: 'flat field should mesh at the datum radius');
      }
    });
  });

  group('skirts (phase 4b)', () {
    final k = chunkAt(const Vector3(0.35, 0.35, 0.87).normalized, 7);
    const res = 16;

    test('skirtVoxels 0 leaves the bare surface', () {
      final bare = meshTerrainCell(field, k, resolution: res, skirtVoxels: 0);
      expect(bare.mesh.triangleCount, bare.surfaceTriangleCount);
      expect(bare.mesh.vertexCount, bare.surfaceVertexCount);
    });

    test('adds an apron without touching the surface', () {
      final bare = meshTerrainCell(field, k, resolution: res, skirtVoxels: 0);
      final skirt = meshTerrainCell(field, k, resolution: res);
      expect(skirt.surfaceTriangleCount, bare.surfaceTriangleCount);
      expect(skirt.mesh.triangleCount, greaterThan(bare.mesh.triangleCount));
      // Surface vertices must be untouched — the apron is additive.
      for (var i = 0; i < bare.mesh.positions.length; i++) {
        expect(skirt.mesh.positions[i], bare.mesh.positions[i]);
      }
    });

    test('apron hangs inward by the skirt depth', () {
      const voxels = 2.5;
      final cell =
          meshTerrainCell(field, k, resolution: res, skirtVoxels: voxels);
      final depth = voxels * (k.circumradiusM(field.radius) * 2 / res);
      final p = cell.mesh.positions;
      var checked = 0;
      for (var v = cell.surfaceVertexCount; v < cell.mesh.vertexCount; v++) {
        final w = cell.anchorBF +
            Vector3(p[v * 3], p[v * 3 + 1], p[v * 3 + 2]);
        // Every skirt vertex sits below the local ground by ~depth.
        final ground = field.groundRadiusAt(w.x, w.y, w.z);
        final below = ground - w.length;
        expect(below, greaterThan(depth * 0.5),
            reason: 'skirt vertex $v only $below m below ground');
        checked++;
      }
      expect(checked, greaterThan(0), reason: 'no skirt vertices emitted');
    });

    test('closes the surface boundary: no open edge among surface vertices',
        () {
      // The crack the skirt exists to hide is at the surface perimeter. After
      // skirting, every open edge must belong to the apron's bottom rim.
      final cell = meshTerrainCell(field, k, resolution: res);
      final idx = cell.mesh.indices;
      final n = cell.mesh.vertexCount;
      final uses = <int, int>{};
      int keyOf(int a, int b) => a < b ? a * n + b : b * n + a;
      for (var t = 0; t < idx.length; t += 3) {
        final a = idx[t], b = idx[t + 1], c = idx[t + 2];
        uses.update(keyOf(a, b), (v) => v + 1, ifAbsent: () => 1);
        uses.update(keyOf(b, c), (v) => v + 1, ifAbsent: () => 1);
        uses.update(keyOf(c, a), (v) => v + 1, ifAbsent: () => 1);
      }
      var openOnSurface = 0;
      for (final e in uses.entries) {
        if (e.value != 1) continue;
        final a = e.key ~/ n, b = e.key % n;
        if (a < cell.surfaceVertexCount && b < cell.surfaceVertexCount) {
          openOnSurface++;
        }
      }
      expect(openOnSurface, 0,
          reason: '$openOnSurface surface edges still open after skirting');
    });

    test('is deep enough to cover a 2:1 neighbour mis-sample', () {
      // 2:1 balance bounds a neighbour at one level coarser, i.e. voxels twice
      // ours. The crack it can open is bounded by how far the ground moves over
      // one of ITS voxels — the skirt must out-reach that.
      for (final level in [5, 7, 9]) {
        final c = chunkAt(const Vector3(0.2, 0.55, 0.81).normalized, level);
        final lateralM = c.circumradiusM(field.radius) * 2 / res;
        final depth = 2.5 * lateralM;

        // Step across the cell in coarse-voxel strides, worst ground delta.
        final coarseS = (c.s1 - c.s0) / res * 2, coarseT = (c.t1 - c.t0) / res * 2;
        var worst = 0.0;
        for (var a = 0; a < res ~/ 2; a++) {
          for (var b = 0; b < res ~/ 2; b++) {
            final s = c.s0 + a * coarseS, t = c.t0 + b * coarseT;
            final d0 = directionOf(c.face, s, t);
            final d1 = directionOf(c.face, s + coarseS, t);
            final d2 = directionOf(c.face, s, t + coarseT);
            final g0 = field.groundRadiusAt(d0.x, d0.y, d0.z);
            final g1 = field.groundRadiusAt(d1.x, d1.y, d1.z);
            final g2 = field.groundRadiusAt(d2.x, d2.y, d2.z);
            worst = math.max(worst, math.max((g1 - g0).abs(), (g2 - g0).abs()));
          }
        }
        expect(depth, greaterThan(worst),
            reason: 'level $level: skirt ${depth.toStringAsFixed(1)}m vs '
                'worst step ${worst.toStringAsFixed(1)}m');
      }
    });

    test('apron stays a modest fraction of the triangle budget', () {
      final cell = meshTerrainCell(field, k, resolution: res);
      final skirtTris = cell.mesh.triangleCount - cell.surfaceTriangleCount;
      expect(skirtTris, greaterThan(0));
      // Perimeter scales as O(res), interior as O(res^2), so the apron should
      // stay well under the surface it protects.
      expect(skirtTris, lessThan(cell.surfaceTriangleCount),
          reason: 'skirt $skirtTris vs surface ${cell.surfaceTriangleCount}');
    });

    test('deterministic with skirts on', () {
      final a = meshTerrainCell(field, k, resolution: res);
      final b = meshTerrainCell(_moon(), k, resolution: res);
      expect(a.mesh.positions, b.mesh.positions);
      expect(a.mesh.indices, b.mesh.indices);
    });
  });

  group('cost', () {
    test('per-chunk voxel cost is level-independent', () {
      // The §6 risk: chunk COUNT grows with depth, so per-chunk cost must not.
      // Both the band and the voxel size shrink with level, so the radial
      // sample count — and hence the work per chunk — stays flat.
      final d = const Vector3(0.6, 0.1, 0.79).normalized;
      final samples = [
        for (final level in [3, 5, 7, 9, 11, 13])
          meshTerrainCell(field, chunkAt(d, level), resolution: 12)
              .radialSamples,
      ];
      final lo = samples.reduce(math.min), hi = samples.reduce(math.max);
      expect(hi, lessThanOrEqualTo(12), reason: 'radial samples: $samples');
      expect(hi - lo, lessThanOrEqualTo(3),
          reason: 'per-chunk cost drifts with level: $samples');
    });

    test('triangle count scales with resolution, not level', () {
      final d = const Vector3(0.2, 0.6, 0.77).normalized;
      final counts = [
        for (final level in [5, 7, 9])
          meshTerrainCell(field, chunkAt(d, level), resolution: 16)
              .mesh
              .triangleCount,
      ];
      for (final c in counts) {
        expect(c, greaterThan(0));
      }
      final lo = counts.reduce(math.min), hi = counts.reduce(math.max);
      expect(hi / lo, lessThan(3.0),
          reason: 'tri count swung with level: $counts');
    });
  });
}
