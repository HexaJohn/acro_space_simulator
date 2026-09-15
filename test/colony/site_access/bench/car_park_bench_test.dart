// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../traffic/bench/bench_support.dart';
import '../../../traffic/traffic_fixture.dart';

/// The car park / yard generation bench (docs/plans/site-access.md §3.10:
/// `carPark` / `yard` plan ≤ 60 µs): the dispatcher's time per written car
/// park and yard, with the offered sites that fell to `kerbOnly` counted
/// apart (their generator ran and found nothing). Skipped unless
/// `ACRO_BENCH` or `ACRO_PERF` is defined; prints, and holds the budget only
/// under `ACRO_PERF` (a quiet machine).
void main() {
  test('bench: car park and yard plans on the towns', () {
    for (final (name, make) in <(String, CitySim Function())>[
      ('built town', town),
      (
        'small generated town',
        () => const CityGenerator().generate(
            const CityGenSpec(blocksAcross: 4, seed: 5),
            bodies: fixtureBodies)
      ),
      (
        'sprawl',
        () => const CityGenerator().generate(
            const CityGenSpec(blocksAcross: 4, seed: 5, sprawlMiles: 12),
            bodies: fixtureBodies)
      ),
    ]) {
      final city = make();
      final g = city.roadGraph;
      // Warm up on a twin list (frames and profiles are lazy per context).
      planSites(g, siteContextsOf(city), validate: false);
      final sites = siteContextsOf(city);
      for (final ctx in sites) {
        ctx.frame?.profile.maxDepthM;
      }
      final micros = <SiteProgram, double>{};
      final counts = <SiteProgram, int>{};
      var b = PlanBuilder(graph: g);
      final sw = Stopwatch();
      for (final ctx in sites) {
        if (b.siteCount == 1024) {
          b.build(validate: false);
          b = PlanBuilder(graph: g);
        }
        sw
          ..reset()
          ..start();
        final p = planSite(b, ctx);
        sw.stop();
        if (p != null && (p == SiteProgram.carPark || p == SiteProgram.yard)) {
          micros[p] = (micros[p] ?? 0) + sw.elapsedMicroseconds;
          counts[p] = (counts[p] ?? 0) + 1;
        }
      }
      for (final p in const [SiteProgram.carPark, SiteProgram.yard]) {
        final n = counts[p] ?? 0;
        if (n == 0) continue;
        final each = micros[p]! / n;
        report('$name: ${p.name} $n plans, ${f(each, 1)} µs each '
            '(budget 60 µs, frame and profile warm)');
        if (kPerf) expect(each, lessThanOrEqualTo(60));
      }
    }
  }, skip: benchSkip, timeout: benchTimeout);
}
