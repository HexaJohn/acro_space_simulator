// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// TEMPORARY diagnostic bench — delete after use.
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cell_mesher.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_edits.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_lod.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_profile.dart';
import 'package:flutter_test/flutter_test.dart';

const radiusM = 1.7374e6;

TerrainField makeField(TerrainEdits? edits) {
  final detail = TerrainProfile.moonlike.detailFor(
    seed: 0x11A00,
    radiusM: radiusM,
    amplitudeM: 4000,
    featureScaleM: 60000,
    octaves: 6,
  );
  return TerrainField(
    radius: radiusM,
    amplitude: 4000,
    featureScale: 60000,
    seed: 0x11A00,
    detail: detail,
    edits: edits,
  );
}

void main() {
  test('bench: clean vs edited chunk cost', () {
    final dir = const Vector3(0.3, 0.4, 0.87).normalized;
    final clean = makeField(null);
    final ground = clean.baseGroundRadiusAt(dir.x, dir.y, dir.z);
    final contact = dir * ground;
    final crater = TerrainBrush.crater(
      contactBF: contact,
      normalBF: dir,
      radiusM: 16,
      depthM: 3.2,
      rimHeightM: 1.0,
    );
    final edits = TerrainEdits.of([crater]);
    final edited = makeField(edits);

    // level chosen the way refinementsFor does
    final targetVoxelM = crater.radiusM * 2.0 / 8;
    final lvl = levelForVoxelSize(dir, radiusM, 24, targetVoxelM, maxLevel: 20);
    final key = chunkAt(dir, lvl);
    // ignore: avoid_print
    print('crater r=${crater.radiusM}m bound=${crater.boundingRadiusM.toStringAsFixed(1)}m '
        '-> forced level $lvl (cell ${(key.circumradiusM(radiusM) * 2).toStringAsFixed(1)} m)');

    // warmup
    meshTerrainCell(clean, key, resolution: 24);
    meshTerrainCell(edited, key, resolution: 24);

    const reps = 5;
    var sw = Stopwatch()..start();
    for (var i = 0; i < reps; i++) {
      meshTerrainCell(clean, key, resolution: 24);
    }
    sw.stop();
    final cleanMs = sw.elapsedMicroseconds / reps / 1000;

    sw = Stopwatch()..start();
    CellMesh? m;
    for (var i = 0; i < reps; i++) {
      m = meshTerrainCell(edited, key, resolution: 24);
    }
    sw.stop();
    final editMs = sw.elapsedMicroseconds / reps / 1000;
    final c0 = meshTerrainCell(clean, key, resolution: 24);
    // ignore: avoid_print
    print('clean chunk: ${cleanMs.toStringAsFixed(2)} ms   '
        'edited chunk: ${editMs.toStringAsFixed(2)} ms   '
        'ratio ${(editMs / cleanMs).toStringAsFixed(2)}x   '
        'verts ${m!.surfaceVertexCount}  tris ${m.mesh.triangleCount}');
    // ignore: avoid_print
    print('radial samples: clean ${c0.radialSamples} (band '
        '${(c0.outerRadiusM - c0.innerRadiusM).toStringAsFixed(1)} m)  '
        'edited ${m.radialSamples} (band '
        '${(m.outerRadiusM - m.innerRadiusM).toStringAsFixed(1)} m)');

    // Same again for a building pad, whose bound is inflated by maxCutM.
    final pad = TerrainBrush.pad(
      centreBF: contact,
      radiusM: 12,
      datumRadiusM: ground,
    );
    // ignore: avoid_print
    print('pad r=${pad.radiusM}m -> bound ${pad.boundingRadiusM.toStringAsFixed(1)} m, '
        'forced level ${levelForVoxelSize(dir, radiusM, 24, pad.radiusM * 2 / 8, maxLevel: 20)}');
    final padField = makeField(TerrainEdits.of([pad]));
    final padKey = chunkAt(dir, levelForVoxelSize(dir, radiusM, 24, pad.radiusM * 2 / 8, maxLevel: 20));
    meshTerrainCell(padField, padKey, resolution: 24);
    sw = Stopwatch()..start();
    for (var i = 0; i < reps; i++) {
      m = meshTerrainCell(padField, padKey, resolution: 24);
    }
    sw.stop();
    // ignore: avoid_print
    print('pad chunk: ${(sw.elapsedMicroseconds / reps / 1000).toStringAsFixed(2)} ms  '
        'radial ${m!.radialSamples} (band ${(m.outerRadiusM - m.innerRadiusM).toStringAsFixed(1)} m)');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('bench: chunk count forced by one crater', () {
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

    final tree = TerrainLodTree(splitPx: 220);
    // Pretend the camera is landed: split to maxLevel near `dir`, nothing else.
    double apparent(ChunkKey k) => k.contains(dir) ? 1e6 : 0.0;
    final before = tree.update(apparent);
    // ignore: avoid_print
    print('leaves without edit: ${before.length}');

    final refine = refinementsFor(crater, radiusM, 24,
        voxelsAcrossBrush: 8, maxLevel: tree.maxRefineLevel);
    final after = tree.update(apparent, refine: refine);
    // ignore: avoid_print
    print('leaves with 1 crater: ${after.length}  (+${after.length - before.length})');
    final byLevel = <int, int>{};
    for (final k in after) {
      byLevel[k.level] = (byLevel[k.level] ?? 0) + 1;
    }
    final levels = byLevel.keys.toList()..sort();
    // ignore: avoid_print
    print('by level: ${[for (final l in levels) '$l:${byLevel[l]}'].join(' ')}');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
