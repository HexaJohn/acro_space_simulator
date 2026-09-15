// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_program.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../traffic/bench/bench_support.dart';
import '../../../traffic/traffic_fixture.dart';

/// The R2 generation bench (docs/plans/site-access.md §3.10): the program
/// mix, the measured cost per program, the drain sum `Σ count × unitBudget`
/// against the 3 s budget, and bytes per home and kerbside site.
///
/// R2 core: car park, yard and installation generators are still stubs, so
/// their sites read as `kerbOnly` here until their tracks land.
void main() {
  test('bench: plan generation on the built town and the sprawl fixture', () {
    for (final (name, city) in <(String, CitySim Function())>[
      ('built town', () => town()),
      (
        'sprawl',
        () => const CityGenerator().generate(
            const CityGenSpec(blocksAcross: 4, seed: 5, sprawlMiles: 12),
            bodies: fixtureBodies)
      ),
    ]) {
      final c = city();
      final g = c.roadGraph;
      final sites = siteContextsOf(c);
      // Warm up (frames, profiles and side-street slots are lazy per context,
      // so warm on a twin list and time a fresh one).
      planSites(g, siteContextsOf(c), validate: false);
      final micros = List<double>.filled(SiteProgram.values.length, 0);
      final stats = SiteProgramStats();
      var b = PlanBuilder(graph: g);
      final homes = PlanBuilder(graph: g), kerbs = PlanBuilder(graph: g);
      final sw = Stopwatch();
      final total = Stopwatch()..start();
      for (final ctx in sites) {
        if (b.siteCount == 1024) {
          b.build(validate: false);
          b = PlanBuilder(graph: g);
        }
        sw
          ..reset()
          ..start();
        final p = planSite(b, ctx, stats: stats);
        sw.stop();
        if (p != null) micros[p.index] += sw.elapsedMicroseconds.toDouble();
        if (p == SiteProgram.homeDriveway && homes.siteCount < 1024) {
          planSite(homes, ctx);
        } else if (p == SiteProgram.kerbOnly && kerbs.siteCount < 1024) {
          planSite(kerbs, ctx);
        }
      }
      b.build(validate: false);
      total.stop();
      report('$name: ${sites.length} sites, $stats; all in '
          '${f(total.elapsedMicroseconds / 1000)} ms');
      const unit = {
        SiteProgram.kerbOnly: 5.0,
        SiteProgram.homeDriveway: 12.0,
        SiteProgram.carPark: 60.0,
        SiteProgram.yard: 60.0,
        SiteProgram.installation: 3000.0,
      };
      var budget = 0.0;
      for (final p in SiteProgram.values) {
        final n = stats.programCount(p);
        if (n == 0) continue;
        budget += n * (unit[p] ?? 0);
        report('  ${p.name}: $n plans, ${f(micros[p.index] / n, 1)} µs each '
            '(budget ${unit[p]} µs)');
      }
      report('  drain sum Σ count × unit budget, stubs as kerbOnly: '
          '${f(budget / 1e6, 3)} s (budget 3 s for the 127k-building town)');
      // While car park / yard / installation are stubs, their sites fall to
      // kerbOnly and are costed at 5 µs: the sum above is a LOWER bound.
      // Cost each stubbed site at the unit budget of the program it was
      // offered instead (its NoFit demotion counts it).
      final cp = stats.demotionCount(SiteDemotion.carParkNoFit);
      final yd = stats.demotionCount(SiteDemotion.yardNoFit);
      final inst = stats.demotionCount(SiteDemotion.installationNoFit);
      final offered = budget +
          cp * (unit[SiteProgram.carPark]! - unit[SiteProgram.kerbOnly]!) +
          yd * (unit[SiteProgram.yard]! - unit[SiteProgram.kerbOnly]!) +
          inst * (unit[SiteProgram.installation]! - unit[SiteProgram.kerbOnly]!);
      report('  drain sum Σ with the stubbed sites at their offered program\'s '
          'unit budget ($cp car park, $yd yard, $inst installation): '
          '${f(offered / 1e6, 3)} s; per site ${f(offered / sites.length, 1)} '
          'µs, × 127k buildings ≈ ${f(offered / sites.length * 0.127, 2)} s');
      for (final (what, pb) in [('home', homes), ('kerbside', kerbs)]) {
        if (pb.siteCount == 0) continue;
        final chunk = pb.build(validate: false);
        report('  bytes per $what site: '
            '${f(chunk.byteLength / chunk.siteCount, 0)} B over '
            '${chunk.siteCount} sites (home budget 512 B)');
      }
    }
  }, skip: benchSkip, timeout: benchTimeout);
}
