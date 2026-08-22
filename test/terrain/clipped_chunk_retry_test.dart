// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/mining/hand_drill.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cell_mesher.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_edits.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/terrain/terrain_nodes.dart';
import 'package:flutter_test/flutter_test.dart';

/// A chunk that reports its own meshing failure must not be retired for good.
///
/// `clipped` means the radial band did not contain the surface — the mesher
/// saying it got it wrong. Treating that as "no ground here" retires the chunk
/// into the empty set, and the empty set is only ever cleared by a LATER edit
/// that touches it. Stop mining and nothing ever will, so the tile drops to
/// its loading placeholder and stays there.
void main() {
  TerrainField moon() => TerrainField(
        radius: 1.7371e6,
        amplitude: 2000,
        featureScale: 60000,
        seed: 7,
        octaves: 5,
      );

  test('the band tracks a drill hole, at every level it is dug at', () {
    // The band widens to hold what a brush can move the surface into. This is
    // the mechanism that keeps ordinary mining OUT of the clipped path at all,
    // so it is worth pinning: if it regresses, every hole starts retiring its
    // own chunk.
    final field = moon();
    const drill = HandDrill();
    final dir = Vector3(0.3, 0.2, 0.93).normalized;

    for (final level in [16, 18, 20, 21]) {
      final key = chunkAt(dir, level);
      final centre = key.centreDirection;
      final ground = field.groundRadiusAt(centre.x, centre.y, centre.z);
      for (var steps = 1; steps <= 12; steps += 3) {
        final edits = TerrainEdits()
          ..add(TerrainBrush.sphere(
            centreBF: centre * (ground - steps * drill.stepRadiusM * 0.6),
            radiusM: steps * drill.stepRadiusM,
            tick: steps,
          ));
        final cell = meshTerrainCell(field.withEdits(edits), key,
            resolution: 16, skirtVoxels: 1);
        expect(cell.clipped, isFalse,
            reason: 'level $level, ${steps * drill.stepRadiusM} m bore: the '
                'band missed the surface a drill hole moved');
        expect(cell.isEmpty, isFalse,
            reason: 'level $level lost its ground to a '
                '${steps * drill.stepRadiusM} m hole');
      }
    }
  });

  test('a chunk is given more than one look before it is written off', () {
    // The value itself is the invariant: at 1, a single mid-edit sample —
    // which is precisely what mining produces, because the field is changing
    // under the mesher while it works — retires the tile permanently.
    expect(TerrainNodes.clippedRetryLimit, greaterThan(1),
        reason: 'one clipped sample must not be enough to retire a chunk');
  });

  // NOT TESTED HERE: that a retried chunk actually reappears. `TerrainNodes`
  // owns an `fs.Scene` and the streaming path needs a GPU, neither of which
  // exists under `flutter test` — so the retry itself is verified only by the
  // `RETIRED` counter in the terrain HUD, which is why that counter is there.
}
