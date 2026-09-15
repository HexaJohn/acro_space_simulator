// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_program.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';

/// The R2 sprawl audit (docs/plans/site-access.md §8.3): on the R1 audit
/// fixture (`blocksAcross 4, seed 5, sprawlMiles 12`), the program counts and
/// the home demotions to `kerbOnly` by §3.3 back-out rule.
///
/// Owned by R2 core. The home figures do not depend on the car park, yard and
/// installation generators, so they are pinned now. The rest of the mix is
/// pinned as a total until those tracks land; core re-pins the full mix at
/// the R2 merge (Appendix A).
void main() {
  test('sprawl audit: programs and home demotions by rule', () {
    final sprawl = const CityGenerator().generate(
        const CityGenSpec(blocksAcross: 4, seed: 5, sprawlMiles: 12),
        bodies: fixtureBodies);
    final stats = SiteProgramStats();
    final chunks = planCity(sprawl, stats: stats, validate: false);
    // ignore: avoid_print
    print('sprawl programs (site-access R2 audit): $stats');
    final planned = chunks.fold<int>(0, (a, c) => a + c.siteCount);
    final homeRules = {
      for (final d in [
        SiteDemotion.homeRoad,
        SiteDemotion.homeRoom,
        SiteDemotion.homeSwingMargin,
        SiteDemotion.homeSkew,
        SiteDemotion.homeGeometry,
      ])
        d.name: stats.demotionCount(d),
    };
    expect({
      'planned': planned,
      'unplanned': stats.unplanned,
      'homeDriveway': stats.programCount(SiteProgram.homeDriveway),
      ...homeRules,
    }, _audit);
    expect(stats.programs.fold<int>(0, (a, n) => a + n), planned);
  });
}

/// Pinned R2 core, 2026-09-15.
const Map<String, int> _audit = {
  'planned': 30559,
  'unplanned': 2,
  'homeDriveway': 24996,
  'homeRoad': 0,
  'homeRoom': 154,
  'homeSwingMargin': 411,
  'homeSkew': 36,
  'homeGeometry': 107,
};
