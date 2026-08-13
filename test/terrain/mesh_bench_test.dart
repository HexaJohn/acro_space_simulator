// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Perf smoke: prints per-chunk meshing cost on a Moon-like (cratered, eroded)
// field. Never asserts wall time — read the numbers when touching the mesher.
// Reference (debug JIT, 2026-08): ~12-20 ms/chunk; the pre-column-cache mesher
// sat at 108-335 ms/chunk.
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cell_mesher.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
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
}
