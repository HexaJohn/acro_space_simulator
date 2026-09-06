// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/frame_budget.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/perf_knobs.dart';
import 'package:flutter_test/flutter_test.dart';

/// The knob table is the one place the perf trade-offs are reached by
/// name — the studio's PERF rows, the dev hook, the sweep's --knob — so
/// every entry must round-trip: set by name, read back from the static it
/// fronts and from the snapshot.
void main() {
  late Map<String, num> before;
  setUp(() => before = PerfKnobs.snapshot());
  tearDown(() {
    for (final k in PerfKnobs.all) {
      k.set(before[k.name]!);
    }
  });

  test('every knob has a distinct name and an explainer', () {
    final names = PerfKnobs.all.map((k) => k.name).toSet();
    expect(names.length, PerfKnobs.all.length);
    for (final k in PerfKnobs.all) {
      expect(k.trades, isNotEmpty, reason: k.name);
    }
  });

  test('a number sets the static it fronts and reads back', () {
    expect(PerfKnobs.set('tierCacheMiB', '64'), isTrue);
    expect(CityNodes.tierCacheBytes, 64 << 20);
    expect(PerfKnobs.snapshot()['tierCacheMiB'], 64);
    expect(PerfKnobs.set('bufferPoolMiB', '0'), isTrue);
    expect(CityNodes.bufferPoolBytes, 0);
    expect(PerfKnobs.set('chunkMiB', '4'), isTrue);
    expect(CityTileMesher.maxGroupBytes, 4 << 20);
    expect(PerfKnobs.set('uploadKiBPerFrame', '256'), isTrue);
    expect(CityNodes.uploadBytesPerFrame, 256 * 1024);
    expect(PerfKnobs.set('frameTargetMs', '16.5'), isTrue);
    expect(FrameBudget.targetMs, 16.5);
    expect(PerfKnobs.set('stallMs', '0'), isTrue);
    expect(FrameBudget.stallMs, 0);
    expect(PerfKnobs.set('maxInFlight', '2'), isTrue);
    expect(CityNodes.maxInFlight, 2);
    expect(PerfKnobs.set('tierCacheSetsPerTile', '3'), isTrue);
    expect(CityNodes.tierCacheSetsPerTile, 3);
    expect(PerfKnobs.set('detailBudgetMs', '1.5'), isTrue);
    expect(CityNodes.detailBudgetMs, 1.5);
    expect(PerfKnobs.set('buildBudgetMs', '12'), isTrue);
    expect(CityNodes.buildBudgetMs, 12);
    expect(PerfKnobs.set('buildShare', '0.4'), isTrue);
    expect(CityFrameBudgets.buildShare, 0.4);
    expect(PerfKnobs.snapshot()['buildShare'], 0.4);
  });

  test('a flag takes true/false, on/off or 0/1', () {
    expect(PerfKnobs.set('detailLayer', 'false'), isTrue);
    expect(CityNodes.detailLayer, isFalse);
    expect(PerfKnobs.snapshot()['detailLayer'], 0);
    expect(PerfKnobs.set('detailLayer', 'on'), isTrue);
    expect(CityNodes.detailLayer, isTrue);
    expect(PerfKnobs.set('frameBudget', '0'), isTrue);
    expect(FrameBudget.enabled, isFalse);
    expect(PerfKnobs.set('frameBudget', '1'), isTrue);
    expect(FrameBudget.enabled, isTrue);
    expect(PerfKnobs.set('scaleUploadBytes', 'true'), isTrue);
    expect(CityFrameBudgets.scaleBytes, isTrue);
  });

  test('an unknown name or a bad value sets nothing', () {
    expect(PerfKnobs.set('noSuchKnob', '1'), isFalse);
    expect(PerfKnobs.set('tierCacheMiB', 'lots'), isFalse);
    expect(PerfKnobs.snapshot(), before);
  });
}
