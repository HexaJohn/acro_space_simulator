// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Perf smoke: what a mesh-job SUBMIT costs the sending thread. Isolate.run
// deep-copies the captured field into the new isolate — including the whole
// decoded DEM pyramid — and that copy bills the caller, once per job. The
// pooled scheduler exists to pay that copy once per body instead; this bench
// keeps both numbers honest. Reference (debug JIT, 2026-08): Isolate.run 6
// submits = 29 ms (moon) / 72 ms (earth) sync; pool after warm-up = ~0 ms.
import 'dart:io';
import 'dart:isolate';

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/dem_pyramid.dart';
import 'package:acro_space_simulator/domain/terrain/mesh_scheduler_isolate.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_feature.dart';
import 'package:flutter_test/flutter_test.dart';

TerrainField _fieldFor(String body) {
  final bytes = File('assets/terrain/$body.acrodem').readAsBytesSync();
  final dem = DemPyramid.decode(bytes);
  return TerrainField(
    radius: dem.radiusM,
    amplitude: 4000,
    featureScale: 60000,
    seed: 0x11A00,
    dem: dem,
    detail: TerrainDetail(const [], DemDerivedControl(dem)),
  );
}

void main() {
  test('bench: main-thread cost of shipping a DEM field per Isolate.run',
      () async {
    for (final body in ['moon', 'earth']) {
      final field = _fieldFor(body);

      // Warmup.
      await Isolate.run(() => field.radius);

      const reps = 6; // one frame's meshBudgetPerFrame worth of submits
      final sync = Stopwatch();
      final total = Stopwatch()..start();
      final futures = <Future<double>>[];
      sync.start();
      for (var i = 0; i < reps; i++) {
        futures.add(Isolate.run(() => field.radius));
      }
      sync.stop();
      await Future.wait(futures);
      total.stop();
      // ignore: avoid_print
      print('$body Isolate.run: $reps submits — sync '
          '${sync.elapsedMilliseconds} ms, '
          'round-trip ${total.elapsedMilliseconds} ms');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('bench: pooled scheduler submit cost after the one-time field ship',
      () async {
    final field = _fieldFor('earth');
    final scheduler = PlatformMeshScheduler(workers: 3);
    final dir = const Vector3(0.3, 0.4, 0.87).normalized;

    // First batch pays the per-worker field ship + spawn.
    final first = Stopwatch()..start();
    await Future.wait([
      for (var i = 0; i < 3; i++)
        scheduler.mesh(field, chunkAt(dir, 10 + i),
            resolution: 24, skirtVoxels: 2.5),
    ]);
    first.stop();

    // Steady state: submits should cost microseconds of sync time.
    const reps = 6;
    final sync = Stopwatch()..start();
    final futures = [
      for (var i = 0; i < reps; i++)
        scheduler.mesh(field, chunkAt(dir, 8 + (i % 5)),
            resolution: 24, skirtVoxels: 2.5),
    ];
    sync.stop();
    final total = Stopwatch()..start();
    await Future.wait(futures);
    total.stop();
    scheduler.dispose();
    // ignore: avoid_print
    print('earth pooled: first batch ${first.elapsedMilliseconds} ms; '
        'then $reps submits — sync ${sync.elapsedMilliseconds} ms, '
        'round-trip ${total.elapsedMilliseconds} ms');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
