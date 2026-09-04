// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The plat scales: laying and subdividing a street grid costs about what
/// the grid is, not what it is squared.
///
/// This is the test that lets the whole twenty-mile city be one plat. The
/// scanning subdivider was quadratic in lots and the crossing test
/// quadratic in roads, which is why the sprawl was a separate model; if a
/// change brings either back, the ratio here says so long before a
/// generated city takes minutes.
library;

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel_network.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lay an n x n grid of streets [spacingM] apart through the editor path
/// and plat it once. Returns the layout and the wall time in milliseconds.
(CityLayout, int) grid(int n, {double spacingM = 100}) {
  final layout = CityLayout();
  final sw = Stopwatch()..start();
  final half = (n - 1) * spacingM / 2;
  for (var i = 0; i < n; i++) {
    final x = -half + i * spacingM;
    layout.commitRoad(
        controls: [Vec2(x, -half - 30), Vec2(x, half + 30)],
        regenerateLots: false);
    layout.commitRoad(
        controls: [Vec2(-half - 30, x), Vec2(half + 30, x)],
        regenerateLots: false);
  }
  layout.regenerate();
  return (layout, sw.elapsedMilliseconds);
}

void main() {
  test('a street grid plats every block and splits at every crossing', () {
    final (layout, _) = grid(6);
    // 6 lines each way: each split into 5 inner pieces plus two stubs.
    expect(layout.roads.length, 2 * 6 * 7);
    expect(layout.autoParcels.length, greaterThan(150));
    // No lot overlaps another: the clash test through the index still
    // rejects what the scan rejected.
    final lots = layout.autoParcels;
    for (var i = 0; i < lots.length; i++) {
      for (var j = i + 1; j < lots.length; j++) {
        if (lots[i].overlaps(lots[j])) {
          fail('${lots[i].id} overlaps ${lots[j].id}');
        }
      }
    }
  });

  test('platting a grid four times bigger costs about four times as much',
      () {
    // Warm up the JIT so the small grid is not paying for compilation.
    grid(6);
    final (small, tSmall) = grid(12);
    final (big, tBig) = grid(24);
    final lotRatio = big.autoParcels.length / small.autoParcels.length;
    expect(lotRatio, greaterThan(3.5));
    // Quadratic would be ~16x; allow generous headroom over linear for
    // cache effects, but nowhere near quadratic.
    final timeRatio = tBig / (tSmall.clamp(1, 1 << 30));
    expect(timeRatio, lessThan(8),
        reason: 'small ${small.autoParcels.length} lots in $tSmall ms, '
            'big ${big.autoParcels.length} lots in $tBig ms');
  });

  test('a big grid plats in seconds', () {
    final (layout, ms) = grid(30);
    expect(layout.autoParcels.length, greaterThan(4000));
    expect(ms, lessThan(20000), reason: '${layout.autoParcels.length} lots');
    // And the network over it is not quadratic either.
    final sw = Stopwatch()..start();
    final net = ParcelNetwork.of(layout);
    expect(net.rootedRoads.length, layout.roads.length);
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });

  test('a road drawn near an existing one still snaps and crosses', () {
    final (layout, _) = grid(4);
    final before = layout.roads.length;
    // Ends 10 m short of the outer lines snap onto them; the middle crosses
    // the two inner lines.
    layout.commitRoad(
        controls: const [Vec2(-140, 33), Vec2(140, 33)], regenerateLots: false);
    // The new road: 3 pieces (cut by the two inner verticals) once its ends
    // have snapped to the outer verticals; each of the four verticals it
    // meets is cut once more.
    expect(layout.roads.length, before + 3 + 4);
    expect(layout.nearestRoadPoint(const Vec2(0, 34), withinM: 5), isNotNull);
    expect(layout.nearestRoadPoint(const Vec2(0, 60), withinM: 5), isNull);
  });
}
