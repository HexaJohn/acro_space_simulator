// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// TEMPORARY diagnostic bench — delete after use.
import 'dart:io';
import 'dart:isolate';

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cell_mesher.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/dem_pyramid.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_feature.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bench: Isolate.run cost with a DEM-backed field', () async {
    final bytes = File('assets/terrain/moon.acrodem').readAsBytesSync();
    final dem = DemPyramid.decode(bytes);
    // ignore: avoid_print
    print('moon DEM: faceSize=${dem.faceSize} levels=${dem.levelCount} '
        '${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB on disk');

    final relief = ErodedReliefFeature(
      seed: 0x11A00,
      radiusM: dem.radiusM,
      featureScaleM: 8000,
    );
    final field = TerrainField(
      radius: dem.radiusM,
      amplitude: 4000,
      featureScale: 60000,
      seed: 0x11A00,
      dem: dem,
      detail: TerrainDetail([relief], DemDerivedControl(dem)),
    );
    final dir = const Vector3(0.3, 0.4, 0.87).normalized;
    final key = chunkAt(dir, 16);

    // Inline cost (no isolate).
    meshTerrainCell(field, key, resolution: 24); // warmup
    var sw = Stopwatch()..start();
    for (var i = 0; i < 3; i++) {
      meshTerrainCell(field, key, resolution: 24);
    }
    sw.stop();
    // ignore: avoid_print
    print('inline DEM chunk: ${(sw.elapsedMicroseconds / 3 / 1000).toStringAsFixed(2)} ms');

    // Isolate.run round trip — same call the scheduler makes.
    await Isolate.run(() => meshTerrainCell(field, key, resolution: 24));
    sw = Stopwatch()..start();
    for (var i = 0; i < 3; i++) {
      await Isolate.run(() => meshTerrainCell(field, key, resolution: 24));
    }
    sw.stop();
    // ignore: avoid_print
    print('Isolate.run DEM chunk: ${(sw.elapsedMicroseconds / 3 / 1000).toStringAsFixed(2)} ms');

    // Isolate spawn floor with NO captured field, for comparison.
    await Isolate.run(() => 1 + 1);
    sw = Stopwatch()..start();
    for (var i = 0; i < 3; i++) {
      await Isolate.run(() => 1 + 1);
    }
    sw.stop();
    // ignore: avoid_print
    print('Isolate.run empty: ${(sw.elapsedMicroseconds / 3 / 1000).toStringAsFixed(2)} ms');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
