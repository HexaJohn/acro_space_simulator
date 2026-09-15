// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/car_park_packer.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../traffic/bench/bench_support.dart';
import '../../../traffic/traffic_fixture.dart';

/// The car park / yard generation bench (docs/plans/site-access.md §3.10:
/// `carPark` / `yard` plan ≤ 60 µs). Per fixture it prints:
///
/// - the packer's own time per call (`carParkPlanOf` / `yardPlanOf` alone,
///   nothing written) over EXACTLY the sites the dispatcher offers each
///   program (a yard call includes its car park fallback), after at least
///   20,000 warm-up calls so the JIT has optimised the packer (a few hundred
///   cold calls read 3–5× slower and are no measure of a town's drain), the
///   best of three passes;
/// - the dispatcher's time per written plan (generation and `PlanBuilder`
///   emission), one cold-ish pass as a town's drain would run it.
///
/// Skipped unless `ACRO_BENCH` or `ACRO_PERF` is defined; prints, and holds
/// the packer's time to the budget only under `ACRO_PERF` (a quiet machine).
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
      // Which sites the dispatcher offers each generator.
      final offered = <SiteProgram, List<SiteContext>>{
        SiteProgram.carPark: [],
        SiteProgram.yard: [],
      };
      final recording = SiteGenerators(
        yard: (ctx) {
          offered[SiteProgram.yard]!.add(ctx);
          return yardPlanOf(ctx);
        },
        carPark: (ctx) {
          offered[SiteProgram.carPark]!.add(ctx);
          return carParkPlanOf(ctx);
        },
      );
      for (final ctx in siteContextsOf(city)) {
        planSite(PlanBuilder(graph: g), ctx, generators: recording);
      }

      // The dispatcher, per written plan (frames and profiles warm).
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
        if (p == SiteProgram.carPark || p == SiteProgram.yard) {
          micros[p!] = (micros[p] ?? 0) + sw.elapsedMicroseconds;
          counts[p] = (counts[p] ?? 0) + 1;
        }
      }

      for (final p in const [SiteProgram.carPark, SiteProgram.yard]) {
        final list = offered[p]!;
        if (list.isEmpty) continue;
        void call(SiteContext ctx) =>
            p == SiteProgram.yard ? yardPlanOf(ctx) : carParkPlanOf(ctx);
        for (var w = 0; w < 20000 ~/ list.length + 1; w++) {
          list.forEach(call);
        }
        var packer = double.infinity;
        final reps = 5000 ~/ list.length + 1;
        for (var pass = 0; pass < 3; pass++) {
          sw
            ..reset()
            ..start();
          for (var r = 0; r < reps; r++) {
            list.forEach(call);
          }
          sw.stop();
          final each = sw.elapsedMicroseconds / (reps * list.length);
          if (each < packer) packer = each;
        }
        final n = counts[p] ?? 0;
        report('$name: ${p.name} offered ${list.length}, packer '
            '${f(packer, 1)} µs per call warm (budget 60 µs); $n written at '
            '${n == 0 ? '-' : f(micros[p]! / n, 1)} µs each through the '
            'dispatcher');
        if (kPerf) expect(packer, lessThanOrEqualTo(60));
      }
    }
  }, skip: benchSkip, timeout: benchTimeout);
}
