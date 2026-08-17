// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Perf smoke: prints per-chunk meshing cost on a Moon-like (cratered, eroded)
// field. Never asserts wall time — read the numbers when touching the mesher.
// Reference (debug JIT, 2026-08): ~12-20 ms/chunk; the pre-column-cache mesher
// sat at 108-335 ms/chunk. Edited chunks: ~19 ms (was ~90-105 before the
// surfaceBand radial bound + lattice-gradient normals); one 16 m crater
// forces ~45 leaves at editResBoost 4 (was +117 split-only).
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cell_mesher.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_edits.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_lod.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bench: moonlike chunk mesh cost', () {
    final detail = TerrainProfile.moonlike.detailFor(
      seed: 0x11A00,
      radiusM: 1.7374e6,
      amplitudeM: 4000,
      featureScaleM: 60000,
      octaves: 6,
    );
    final field = TerrainField(
      radius: 1.7374e6,
      amplitude: 4000,
      featureScale: 60000,
      seed: 0x11A00,
      detail: detail,
    );
    final dirs = [
      const Vector3(0.3, 0.4, 0.87),
      const Vector3(-0.6, 0.2, 0.77),
      const Vector3(0.1, -0.9, 0.4),
    ];
    // Warmup (JIT).
    for (final d in dirs) {
      meshTerrainCell(field, chunkAt(d.normalized, 8), resolution: 24);
    }
    for (final level in [4, 8, 12]) {
      final sw = Stopwatch()..start();
      var tris = 0;
      for (final d in dirs) {
        final c =
            meshTerrainCell(field, chunkAt(d.normalized, level), resolution: 24);
        tris += c.mesh.triangleCount;
      }
      sw.stop();
      // ignore: avoid_print
      print('level $level: ${(sw.elapsedMicroseconds / dirs.length / 1000).toStringAsFixed(2)} ms/chunk  ($tris tris total)');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('bench: edited chunk mesh cost + forced leaf count', () {
    const radiusM = 1.7374e6;
    final detail = TerrainProfile.moonlike.detailFor(
      seed: 0x11A00,
      radiusM: radiusM,
      amplitudeM: 4000,
      featureScaleM: 60000,
      octaves: 6,
    );
    TerrainField makeField(TerrainEdits? edits) => TerrainField(
          radius: radiusM,
          amplitude: 4000,
          featureScale: 60000,
          seed: 0x11A00,
          detail: detail,
          edits: edits,
        );

    final dir = const Vector3(0.3, 0.4, 0.87).normalized;
    final clean = makeField(null);
    final ground = clean.baseGroundRadiusAt(dir.x, dir.y, dir.z);
    final crater = TerrainBrush.crater(
      contactBF: dir * ground,
      normalBF: dir,
      radiusM: 16,
      depthM: 3.2,
      rimHeightM: 1.0,
    );
    final edited = makeField(TerrainEdits.of([crater]));

    // The chunk + resolution the renderer would actually pick: forced level
    // computed against resolution * editResBoost, the boost meshed in-chunk.
    const resolution = 24, boost = 4;
    final targetVoxelM = crater.radiusM * 2.0 / 8;
    final lvl = levelForVoxelSize(dir, radiusM, resolution * boost, targetVoxelM,
        maxLevel: 20);
    final key = chunkAt(dir, lvl);

    meshTerrainCell(clean, key, resolution: resolution * boost); // warmup
    meshTerrainCell(edited, key, resolution: resolution * boost);
    const reps = 5;
    var sw = Stopwatch()..start();
    for (var i = 0; i < reps; i++) {
      meshTerrainCell(clean, key, resolution: resolution * boost);
    }
    sw.stop();
    final cleanMs = sw.elapsedMicroseconds / reps / 1000;
    sw = Stopwatch()..start();
    CellMesh? m;
    for (var i = 0; i < reps; i++) {
      m = meshTerrainCell(edited, key, resolution: resolution * boost);
    }
    sw.stop();
    final editMs = sw.elapsedMicroseconds / reps / 1000;
    // ignore: avoid_print
    print('crater chunk (lvl $lvl, res ${resolution * boost}): '
        'clean ${cleanMs.toStringAsFixed(2)} ms  '
        'edited ${editMs.toStringAsFixed(2)} ms  '
        '(${(editMs / cleanMs).toStringAsFixed(2)}x, '
        'radial ${m!.radialSamples}, '
        'band ${(m.outerRadiusM - m.innerRadiusM).toStringAsFixed(1)} m, '
        'clipped=${m.clipped})');

    // Leaf count one crater forces on a landed-camera tree.
    final tree = TerrainLodTree(splitPx: 220);
    double apparent(ChunkKey k) => k.contains(dir) ? 1e6 : 0.0;
    final before = tree.update(apparent).length;
    final refine = refinementsFor(crater, radiusM, resolution * boost,
        voxelsAcrossBrush: 8, maxLevel: tree.maxRefineLevel);
    final after = tree.update(apparent, refine: refine).length;
    // ignore: avoid_print
    print('one 16 m crater: $before -> $after leaves '
        '(+${after - before} at editResBoost $boost)');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
