// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// TEMPORARY diagnostic bench — delete after use.
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_lod.dart';
import 'package:flutter_test/flutter_test.dart';

const radiusM = 1.7374e6;

void main() {
  test('bench: per-frame LOD selection cost vs edit count', () {
    final dir = const Vector3(0.3, 0.4, 0.87).normalized;
    final seedAxis = Vector3.unitX.cross(dir).normalized;
    final bitan = dir.cross(seedAxis);

    for (final n in [0, 1, 5, 20, 60]) {
      final brushes = <TerrainBrush>[];
      for (var i = 0; i < n; i++) {
        // Scatter pads over ~200 m, like a colony site.
        final off = seedAxis * ((i % 8) * 25.0) + bitan * ((i ~/ 8) * 25.0);
        final c = (dir * radiusM) + off;
        brushes.add(TerrainBrush.pad(
          centreBF: c,
          radiusM: 12,
          datumRadiusM: radiusM,
        ));
      }
      final tree = TerrainLodTree(splitPx: 220);
      double apparent(ChunkKey k) => k.contains(dir) ? 1e6 : 0.0;
      tree.update(apparent); // settle the base tree

      final sw = Stopwatch()..start();
      const frames = 10;
      var leafCount = 0;
      for (var f = 0; f < frames; f++) {
        final refine = <TerrainRefinement>[];
        for (final b in brushes) {
          refine.addAll(refinementsFor(b, radiusM, 24,
              voxelsAcrossBrush: 8, maxLevel: tree.maxRefineLevel));
        }
        final leaves = tree.update(apparent, refine: refine);
        leafCount = leaves.length;
        // The renderer also sorts every visible chunk nearest-first each frame.
        final visible = leaves.toList()
          ..sort((x, y) {
            final dx = (x.centreDirection * radiusM - dir * radiusM).length;
            final dy = (y.centreDirection * radiusM - dir * radiusM).length;
            return dx.compareTo(dy);
          });
        leafCount = visible.length;
      }
      sw.stop();
      // ignore: avoid_print
      print('$n edits -> $leafCount leaves, '
          '${(sw.elapsedMicroseconds / frames / 1000).toStringAsFixed(2)} ms/frame '
          '(LOD select + sort, main thread)');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
