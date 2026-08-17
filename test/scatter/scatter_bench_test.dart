// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Perf smoke: prints scatter generation + batching cost. Never asserts wall
// time — read the numbers when touching placement or the batcher.
// Reference (debug JIT, 2026-08): before the gate reorder a barren-world cell
// that placed NOTHING still cost 9-27 ms (the 4-tap normal ran per candidate
// before the biome gate); after, rejected candidates cost one biome probe.
// Generation now also runs on background isolates (scatter_scheduler.dart),
// so these are isolate-side numbers, not frame costs.
import 'package:acro_space_simulator/domain/planetary/planet_surface.dart';
import 'package:acro_space_simulator/domain/scatter/prop_catalog.dart';
import 'package:acro_space_simulator/domain/scatter/scatter_instance.dart';
import 'package:acro_space_simulator/domain/scatter/scatter_layer.dart';
import 'package:acro_space_simulator/domain/scatter/scatter_placement.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_profile.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/scatter/scatter_nodes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bench: cell generation cost per layer', () {
    const radiusM = 1.7374e6;
    final detail = TerrainProfile.moonlike.detailFor(
      seed: 0x11A00,
      radiusM: radiusM,
      amplitudeM: 4000,
      featureScaleM: 60000,
      octaves: 6,
    );
    final field = TerrainField(
      radius: radiusM,
      amplitude: 4000,
      featureScale: 60000,
      seed: 0x11A00,
      detail: detail,
    );
    const surface = PlanetSurface(
      seed: 11,
      meanSurfaceTemperature: 250,
      albedo: 0.12,
      solarFlux: 1361,
    );
    final placement = ScatterPlacement(
      field: field,
      surface: surface,
      bodySeed: 99,
      // Vegetated so every layer actually places (worst case), even though
      // the Moon would gate the plant layers off.
      vegetationCap: 1.0,
    );

    final dir = const Vector3(0.3, 0.4, 0.87).normalized;
    for (final layer in ScatterLayers.all) {
      final level = layer.levelFor(radiusM);
      final cell = chunkAt(dir, level);
      placement.instancesFor(cell, layer); // warmup
      const reps = 5;
      final sw = Stopwatch()..start();
      var placed = 0;
      for (var i = 0; i < reps; i++) {
        placed = placement.instancesFor(cell, layer).length;
      }
      sw.stop();
      // ignore: avoid_print
      print('${layer.name.padRight(13)} lvl $level: '
          '${(sw.elapsedMicroseconds / reps / 1000).toStringAsFixed(2)} ms/cell '
          '($placed placed)');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('bench: instance transform build rate (the rebuild hot loop)', () {
    final up = const Vector3(0.3, 0.4, 0.87).normalized;
    final pos = up * 1.7374e6;
    final anchor = Vector3(
      (pos.x / 256).roundToDouble() * 256,
      (pos.y / 256).roundToDouble() * 256,
      (pos.z / 256).roundToDouble() * 256,
    );
    final instances = [
      for (var i = 0; i < 30000; i++)
        ScatterInstance(
          kind: PropKind.boulder,
          seed: i,
          positionBF: pos + Vector3(i % 100.0, (i ~/ 100) % 100.0, 0),
          upBF: up,
          yaw: i * 0.01,
          scale: 1.0 + (i % 10) * 0.05,
        ),
    ];
    final sw = Stopwatch()..start();
    for (final inst in instances) {
      ScatterNodes.instanceTransform(inst, anchor);
    }
    sw.stop();
    // ignore: avoid_print
    print('30k instance transforms: ${sw.elapsedMilliseconds} ms '
        '(${(sw.elapsedMicroseconds / instances.length).toStringAsFixed(2)} us each)');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
