// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The LOD heatmap's contract with terrain.frag: what the vertex colour
// stream carries, and what the shared ramp does at its ends. The shader
// reads v_color.r as the RAW level and v_color.g as the sibling parity;
// if either encoding moves, the GLSL side must move with it.

import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/terrain/terrain_nodes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('levelVertexColors', () {
    test('r = raw level, g = sibling parity, b = 0, a = 1, per vertex', () {
      final key = ChunkKey(CubeFace.values.first, 7, 3, 4);
      final c = TerrainNodes.levelVertexColors(key, 5);
      expect(c.length, 20);
      for (var i = 0; i < c.length; i += 4) {
        expect(c[i], 7.0, reason: 'level is stored unnormalised');
        expect(c[i + 1], 1.0, reason: '(u + v) & 1 = (3 + 4) & 1');
        expect(c[i + 2], 0.0);
        expect(c[i + 3], 1.0);
      }
    });

    test('parity alternates between lateral neighbours', () {
      final face = CubeFace.values.first;
      double parity(int u, int v) =>
          TerrainNodes.levelVertexColors(ChunkKey(face, 9, u, v), 1)[1];
      expect(parity(4, 4), 0.0);
      expect(parity(5, 4), 1.0);
      expect(parity(4, 5), 1.0);
      expect(parity(5, 5), 0.0);
    });

    test('an empty chunk yields an empty stream', () {
      expect(
          TerrainNodes.levelVertexColors(
              ChunkKey.root(CubeFace.values.first), 0),
          isEmpty);
    });
  });

  group('lodRampColor', () {
    test('runs coarse blue to deep red and clamps past the span', () {
      final lo = TerrainNodes.lodRampColor(0);
      expect(lo.z, greaterThan(lo.x));
      expect(lo.z, greaterThan(lo.y));
      final hi = TerrainNodes.lodRampColor(TerrainNodes.lodRampLevels);
      expect(hi.x, greaterThan(hi.y));
      expect(hi.x, greaterThan(hi.z));
      expect(TerrainNodes.lodRampColor(TerrainNodes.lodRampLevels + 40), hi);
    });

    test('mid-span is green — the ramp is multi-hue, not a two-stop lerp',
        () {
      final mid = TerrainNodes.lodRampColor(TerrainNodes.lodRampLevels ~/ 2);
      expect(mid.y, greaterThan(mid.x));
      expect(mid.y, greaterThan(mid.z));
    });

    test('adjacent levels are distinguishable across the whole span', () {
      for (var l = 0; l < TerrainNodes.lodRampLevels; l++) {
        final a = TerrainNodes.lodRampColor(l);
        final b = TerrainNodes.lodRampColor(l + 1);
        expect((a - b).length, greaterThan(0.05),
            reason: 'levels $l and ${l + 1} nearly share a colour');
      }
    });
  });
}
