// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Every chunk of the DEM Moon must mesh to a non-empty, non-clipped cell.
//
// An EMPTY result is not cosmetic: TerrainNodes blacklists the chunk
// (nothing resubmits it, nothing stands in for it), so one spurious empty is
// one permanently missing ground tile. On an airless body with no seas there
// is no legitimate empty — the shell always contains the surface — so any
// empty here is a mesher band failure, full stop. CLIPPED (isosurface
// touching the shell edge) is the same failure caught earlier.

import 'dart:math' as math;

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/terrain/cell_mesher.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/register_baked_dems.dart';

void main() {
  registerBakedDemsForTest();
  final system = SampleWorld.realSystem();
  final body = system.require(const BodyId('moon'));
  final field =
      BodyDescriptorSnapshot.of(body, system).buildTerrainField()!;

  test('every chunk to level 3 meshes non-empty and unclipped', () {
    final bad = <String>[];
    for (var level = 0; level <= 3; level++) {
      final n = 1 << level;
      for (final face in CubeFace.values) {
        for (var u = 0; u < n; u++) {
          for (var v = 0; v < n; v++) {
            final k = ChunkKey(face, level, u, v);
            final cell = meshTerrainCell(field, k, resolution: 24);
            if (cell.isEmpty) bad.add('$k EMPTY');
            if (cell.clipped) bad.add('$k CLIPPED');
          }
        }
      }
    }
    expect(bad, isEmpty, reason: bad.take(10).join('\n'));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('random deep chunks (levels 5-9) mesh non-empty and unclipped', () {
    final rng = math.Random(42);
    final bad = <String>[];
    for (var i = 0; i < 120; i++) {
      final level = 5 + rng.nextInt(5);
      final n = 1 << level;
      final k = ChunkKey(CubeFace.values[rng.nextInt(6)], level,
          rng.nextInt(n), rng.nextInt(n));
      final cell = meshTerrainCell(field, k, resolution: 24);
      if (cell.isEmpty) bad.add('$k EMPTY');
      if (cell.clipped) bad.add('$k CLIPPED');
    }
    expect(bad, isEmpty, reason: bad.take(10).join('\n'));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
