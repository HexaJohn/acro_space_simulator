// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_book.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../traffic/bench/bench_support.dart';
import '../../../traffic/traffic_fixture.dart';

/// The book's sync bench (docs/plans/site-access.md §4.2, §4.3): the full
/// drain, a steady tick with nothing changed, and the worst budgeted tick
/// after a road edit (budget ≤ 2 ms on the 127k-building town; measured here
/// on the sprawl fixtures at 12 and 20 miles, every generator in place).
void main() {
  test(
    'bench: site access sync on the sprawl fixtures',
    () {
      for (final miles in const [12.0, 20.0]) {
        final city = CityGenerator().generate(
          CityGenSpec(blocksAcross: 4, seed: 5, sprawlMiles: miles),
          bodies: fixtureBodies,
        );
        final book = SiteAccessBook();
        var g = city.roadGraph;
        final drain = Stopwatch()..start();
        book.sync(city, g);
        drain.stop();
        final sites = book.chunks.fold<int>(0, (a, c) => a + c.siteCount);
        report(
          'sprawl $miles mi: drain of $sites plans in '
          '${f(drain.elapsedMicroseconds / 1000)} ms '
          '(${book.lastSync.toJson()})',
        );

        final steady = Stopwatch();
        for (var i = 0; i < 20; i++) {
          steady.start();
          book.sync(city, g);
          steady.stop();
        }
        report(
          '  steady tick: ${f(steady.elapsedMicroseconds / 20 / 1000, 3)} ms',
        );

        // One copy-on-write republish of a full chunk.
        final c0 = book.chunks.first;
        final rows = [for (var k = 0; k < c0.siteCount; k++) (c0, k)];
        SiteAccessBook.debugRepack(rows);
        final pack = Stopwatch()..start();
        for (var i = 0; i < 10; i++) {
          SiteAccessBook.debugRepack(rows);
        }
        pack.stop();
        report(
          '  re-pack of a ${c0.siteCount}-site chunk: '
          '${f(pack.elapsedMicroseconds / 10 / 1000, 3)} ms',
        );

        // Streets across the town, one edit at a time (the first also warms the
        // JIT on the sync's structure-change paths).
        for (final (i, n) in const [
          (1, 55.0),
          (2, -545.0),
          (3, 655.0),
          (4, -245.0),
          (5, 355.0),
        ].indexed) {
          final oldG = g;
          final roadStart = Stopwatch()..start();
          commit(city, FixtureRoad([Vec2(-400, n.$2), Vec2(400, n.$2)]));
          g = city.roadGraph;
          roadStart.stop();
          // What a first tick after the edit walks, timed from outside: the
          // roads by id and the walk's snapshot of the lots.
          final probe = Stopwatch()..start();
          var same = 0;
          for (var r = 0; r < g.roadCount; r++) {
            if (r < oldG.roadCount && identical(oldG.roads[r], g.roads[r])) {
              same++;
            }
          }
          final tRoads = probe.elapsedMicroseconds;
          final lots = city.layout.parcels.length;
          final tParcels = probe.elapsedMicroseconds - tRoads;
          // The graph's structure stamp is hashed on its first read (core's
          // cost, once per structure change, whoever reads it first).
          final stampSw = Stopwatch()..start();
          g.structureStamp;
          stampSw.stop();
          var worst = 0.0, first = 0.0, ticks = 0, done = false;
          var worstStats = '';
          // Tick times by kind: a tick that re-packed a chunk whole (it wrote
          // or dropped a plan) or only re-resolved / checked.
          final replan = <double>[], resolve = <double>[];
          final all = Stopwatch()..start();
          while (!done && ticks < 5000) {
            final t = Stopwatch()..start();
            done = book.sync(city, g);
            t.stop();
            final ms = t.elapsedMicroseconds / 1000;
            final s = book.lastSync;
            (s.generated + s.dropped > 0 ? replan : resolve).add(ms);
            if (ticks == 0) first = ms;
            if (ms > worst) {
              worst = ms;
              worstStats = '${book.lastSync.toJson()}';
            }
            ticks++;
          }
          all.stop();
          String dist(List<double> xs) {
            if (xs.isEmpty) return 'none';
            final s = [...xs]..sort();
            double p(double q) => s[((s.length - 1) * q).round()];
            final over = s.where((x) => x > 2).length;
            return '${s.length} ticks, p50 ${f(p(0.5), 3)} p90 ${f(p(0.9), 3)} '
                'p99 ${f(p(0.99), 3)} max ${f(s.last, 3)} ms, $over over 2 ms';
          }
          report(
            '  road edit $i (commit + graph '
            '${f(roadStart.elapsedMicroseconds / 1000)} ms; stamp '
            '${f(stampSw.elapsedMicroseconds / 1000)} ms; ${g.roadCount} roads, '
            '$same in place, walked in ${f(tRoads / 1000)} ms; $lots lots '
            'snapshot ${f(tParcels / 1000)} ms): $ticks ticks, '
            '${f(all.elapsedMicroseconds / 1000)} ms in all, first tick '
            '${f(first, 3)} ms, worst tick ${f(worst, 3)} ms (budget 2 ms) '
            '$worstStats',
          );
          report('    re-resolving ticks: ${dist(resolve)}');
          report('    re-planning ticks: ${dist(replan)}');
        }
      }
    },
    skip: benchSkip,
    timeout: benchTimeout,
  );
}
