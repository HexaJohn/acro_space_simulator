// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:flutter_test/flutter_test.dart';

/// Climbing the LOD ladder a rung at a time.
///
/// Streaming had two rungs: a level-0 face root for coverage, then the target
/// leaf, often level 14 or deeper. Each region went from blocky to perfect in
/// one jump — and since the queue is nearest-first, that happened to one tile
/// at a time, so a city assembled piece by piece rather than sharpening as a
/// whole.
///
/// The walk itself is pure, so it is tested here directly rather than through
/// a live streamer: given what is resident, which chunk should be asked for.
void main() {
  /// The production rule, mirrored: up to the deepest resident ancestor, then
  /// back down by at most [step].
  ChunkKey stepToward(ChunkKey want, Set<ChunkKey> resident, int step) {
    var residentLevel = -1;
    for (final a in want.ancestors) {
      if (resident.contains(a)) {
        residentLevel = a.level;
        break;
      }
    }
    final next = residentLevel + step;
    if (next >= want.level) return want;
    var k = want;
    while (k.level > next) {
      final p = k.parent;
      if (p == null) break;
      k = p;
    }
    return k;
  }

  const face = CubeFace.posX;
  ChunkKey leafAt(int level) {
    var k = const ChunkKey.root(face);
    for (var i = 0; i < level; i++) {
      k = k.children.first;
    }
    return k;
  }

  test('with nothing resident it asks for a coarse rung, not the leaf', () {
    final want = leafAt(14);
    final got = stepToward(want, const {}, 3);
    expect(got.level, lessThan(want.level));
    expect(got.level, 2, reason: 'one step up from nothing resident');
    expect(want.ancestors, contains(got),
        reason: 'the rung must be an ancestor of the target');
  });

  test('each pass climbs, and it converges on the leaf', () {
    final want = leafAt(14);
    final resident = <ChunkKey>{};
    var last = -1;
    var passes = 0;
    while (passes < 40) {
      final k = stepToward(want, resident, 3);
      expect(k.level, greaterThan(last), reason: 'a pass made no progress');
      last = k.level;
      resident.add(k);
      passes++;
      if (k == want) break;
    }
    expect(resident, contains(want), reason: 'never reached the target');
    expect(passes, lessThan(10), reason: 'far too many rungs');
  });

  test('a target already within a step is requested directly', () {
    final want = leafAt(4);
    final resident = {leafAt(2)};
    expect(stepToward(want, resident, 3), want);
  });

  test('step 0 restores the old leap', () {
    final want = leafAt(14);
    expect(stepToward(want, const {}, 0).level, 0,
        reason: 'a zero step cannot climb');
  });
}
