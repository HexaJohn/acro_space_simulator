// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Off-thread ground point samples (docs/plans/combat.md §7G): many
/// [TerrainField.surfaceRadiusAt] queries at once, on a pool of persistent
/// workers that hold the field once — the mesh pool's pattern, because a
/// battle raster is 22,500 samples at ~0.4 ms each and the main thread has no
/// room for them (Spike S items 1 and 5). Inline on the web, which has no
/// isolates. Callers use [GroundSamplePool.platform] and never import an
/// implementation directly.
library;

import 'dart:typed_data';

import 'terrain_field.dart';
import 'ground_sample_pool_sync.dart'
    if (dart.library.isolate) 'ground_sample_pool_isolate.dart' as platform;

abstract interface class GroundSamplePool {
  factory GroundSamplePool.platform() = platform.PlatformGroundSamplePool;

  /// [field]'s surface radius along each direction in [dirs] (x, y, z
  /// packed, body-fixed; need not be unit). Deterministic: the same answer
  /// on every implementation.
  Future<Float64List> sample(TerrainField field, Float64List dirs);

  void dispose();
}

/// Every direction in [dirs], inline.
Float64List sampleGround(TerrainField field, Float64List dirs) {
  final n = dirs.length ~/ 3;
  final out = Float64List(n);
  for (var i = 0; i < n; i++) {
    out[i] = field.surfaceRadiusAt(dirs[3 * i], dirs[3 * i + 1], dirs[3 * i + 2]);
  }
  return out;
}

/// Samples inline on the calling thread: the web's, and the tests'.
class SyncGroundSamplePool implements GroundSamplePool {
  @override
  Future<Float64List> sample(TerrainField field, Float64List dirs) =>
      Future.value(sampleGround(field, dirs));

  @override
  void dispose() {}
}
