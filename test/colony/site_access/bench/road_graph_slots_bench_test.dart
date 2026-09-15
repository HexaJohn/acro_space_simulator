// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../traffic/bench/bench_support.dart';
import '../../../traffic/traffic_fixture.dart';

/// Bench R-B1 (docs/plans/site-access.md §3.10): what `RoadGraph.of` costs
/// on the sprawl audit fixture, join slots included. The slice R1 budget is
/// at most +15% over the build before slots; the reading before the slice is
/// recorded in the R1 report, since the old build no longer exists to time
/// beside it.
void main() {
  test('bench: RoadGraph.of on the sprawl fixture (R-B1)', () {
    final city = const CityGenerator().generate(
        const CityGenSpec(blocksAcross: 4, seed: 5, sprawlMiles: 12),
        bodies: fixtureBodies);
    final layout = city.layout;
    for (var i = 0; i < 5; i++) {
      RoadGraph.of(layout);
    }
    final ms = <double>[];
    late RoadGraph g;
    for (var i = 0; i < 21; i++) {
      final sw = Stopwatch()..start();
      g = RoadGraph.of(layout);
      ms.add(sw.elapsedMicroseconds / 1000);
    }
    var without = 0;
    for (var i = 0; i < g.lotCount; i++) {
      if (g.lotPiece[i] < 0) without++;
    }
    report('RoadGraph.of, sprawl: ${g.roadCount} roads, ${g.pieceCount} '
        'pieces, ${g.lotCount} lots ($without without access), '
        '${g.joinCount} join slots: median ${f(percentile(ms, 0.5))} ms, '
        'best ${f(percentile(ms, 0))} ms');
  }, skip: benchSkip, timeout: benchTimeout);
}
