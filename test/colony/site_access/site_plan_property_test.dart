// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'site_random_sites.dart';

/// `site_plan_property_test` (docs/plans/site-access.md §8.3, §3.9): 500
/// seeded random lots planned in their seeded order, in shuffled orders and
/// one by one give each site the same plan rows. A plan depends on its own
/// inputs only: no state carries from one site to the next, whatever chunk
/// it lands in or where in the chunk.
void main() {
  /// Plans [order] (indices into [sites]) into chunks; each site's
  /// signature by index (null: no plan).
  List<List<Object>?> planAll(List<RandomSite> sites, List<int> order,
      {int chunkSize = kSitesPerChunk}) {
    final out = List<List<Object>?>.filled(sites.length, null);
    var b = PlanBuilder();
    var ids = <int>[];
    void flush() {
      if (b.siteCount == 0) return;
      final chunk = b.build(validate: false);
      for (var k = 0; k < chunk.siteCount; k++) {
        out[ids[k]] = RandomSites.signatureOf(chunk.plan(k));
      }
      b = PlanBuilder();
      ids = [];
    }

    for (final i in order) {
      if (b.siteCount == chunkSize) flush();
      if (planSite(b, sites[i].context()) != null) ids.add(i);
    }
    flush();
    return out;
  }

  test('500 seeded lots: the same plan in any order and any chunk', () {
    final sites = RandomSites.build();
    final seeded = [for (var i = 0; i < sites.length; i++) i];
    final base = planAll(sites, seeded);
    expect(base.where((s) => s != null).length, greaterThan(400));

    for (final shuffleSeed in [1, 2, 3]) {
      final order = [...seeded]..shuffle(math.Random(shuffleSeed));
      final got = planAll(sites, order, chunkSize: 37);
      for (var i = 0; i < sites.length; i++) {
        expect(got[i], base[i], reason: 'site $i, shuffle $shuffleSeed');
      }
    }

    // One by one, each in a chunk of its own.
    final alone = planAll(sites, seeded.reversed.toList(), chunkSize: 1);
    for (var i = 0; i < sites.length; i++) {
      expect(alone[i], base[i], reason: 'site $i alone');
    }

    // A second draw of the same seed builds the same sites and plans.
    final twin = planAll(RandomSites.build(), seeded);
    for (var i = 0; i < sites.length; i++) {
      expect(twin[i], base[i], reason: 'site $i, twin draw');
    }
  });
}
