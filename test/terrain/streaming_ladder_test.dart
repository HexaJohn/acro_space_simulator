// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The streaming ladder's pure policy: which rung to request next, and which
// arrivals the upload pump admits. The full streaming path needs a GPU (see
// clipped_chunk_retry_test.dart), so these decisions are extracted as static
// functions on TerrainNodes and pinned here.

import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/terrain/terrain_nodes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = ChunkKey.root(CubeFace.posX);
  final want = ChunkKey(CubeFace.posX, 9, 17, 130);
  ChunkKey ancestorAt(ChunkKey k, int level) =>
      k.ancestors.firstWhere((a) => a.level == level);

  group('nextRung', () {
    test('steps levelStep past the deepest resident ancestor', () {
      // Nothing resident: first rung is levelStep - 1 above the root's step.
      final bare = TerrainNodes.nextRung(want,
          levelStep: 3, isResident: (_) => false, isEmpty: (_) => false);
      expect(bare, ancestorAt(want, 2));

      // Root resident: climb to level 3.
      final fromRoot = TerrainNodes.nextRung(want,
          levelStep: 3, isResident: (k) => k == root, isEmpty: (_) => false);
      expect(fromRoot, ancestorAt(want, 3));

      // Within a step of the target: the target itself.
      final near = TerrainNodes.nextRung(want,
          levelStep: 3,
          isResident: (k) => k.level == 7 && want.ancestors.contains(k),
          isEmpty: (_) => false);
      expect(near, want);

      // levelStep 0 disables the ladder entirely.
      final direct = TerrainNodes.nextRung(want,
          levelStep: 0, isResident: (_) => false, isEmpty: (_) => false);
      expect(direct, want);
    });

    test('an EMPTY rung is skipped to the target, not re-requested', () {
      // REGRESSION: a rung that meshed empty (including one retired as
      // permanently clipped) can never become resident, and the ladder
      // re-returned it forever — the rung was remeshed every completion
      // cycle and the wanted leaf was never requested. It must step straight
      // to the target instead.
      final rung = ancestorAt(want, 3);
      final k = TerrainNodes.nextRung(want,
          levelStep: 3,
          isResident: (k) => k == root,
          isEmpty: (k) => k == rung);
      expect(k, want,
          reason: 'the empty rung $rung would deadlock the ladder');
    });
  });

  group('admitsArrival', () {
    test('admits deliberately requested ladder rungs', () {
      // REGRESSION: the pump used to accept only wanted leaves and bare
      // coverage ancestors. Ladder rungs are neither once ANY ancestor is
      // resident, so every rung mesh was dropped on arrival and instantly
      // resubmitted — streaming deadlocked below the first resident level.
      final rung = ancestorAt(want, 3);
      expect(
        TerrainNodes.admitsArrival(rung,
            wanted: {want}, bareAncestors: const {}, ladderRungs: {rung}),
        isTrue,
        reason: 'a requested rung must be admitted on arrival',
      );
      expect(
        TerrainNodes.admitsArrival(rung,
            wanted: {want}, bareAncestors: const {}, ladderRungs: const {}),
        isFalse,
        reason: 'an unrequested non-leaf stays rejected',
      );
      expect(
        TerrainNodes.admitsArrival(want,
            wanted: {want}, bareAncestors: const {}, ladderRungs: const {}),
        isTrue,
      );
      expect(
        TerrainNodes.admitsArrival(root,
            wanted: {want}, bareAncestors: {root}, ladderRungs: const {}),
        isTrue,
      );
    });
  });
}
