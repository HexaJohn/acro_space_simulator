// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_join.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_validator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'site_plan_fixtures.dart';

/// Join handles (docs/plans/site-access.md §2.3): `RoadGraph.joinRefOf` and
/// `joinOfRef` round trip every slot, stay put across `withOverrides` and
/// `refreshedFor` (graphs that share structure), and are re-resolved, never
/// carried, across a structure change.
void main() {
  void sameSlot(JoinSlot? a, JoinSlot? b, String why) {
    expect(a == null, b == null, reason: why);
    if (a == null || b == null) return;
    expect([a.piece, a.s, a.dirs, a.right, a.flags, a.roomM, a.kerbE, a.kerbN, a.normE, a.normN, a.crossLots],
        [b.piece, b.s, b.dirs, b.right, b.flags, b.roomM, b.kerbE, b.kerbN, b.normE, b.normN, b.crossLots],
        reason: why);
  }

  test('every slot round trips, and (lot, slot) <-> ref is a bijection', () {
    final g = SyntheticSites.starterCity().roadGraph;
    final refs = <int>[];
    var sides = 0, alleys = 0;
    for (var lot = 0; lot < g.lotCount; lot++) {
      for (var slot = 0; slot <= 3; slot++) {
        final ref = g.joinRefOf(lot, slot);
        if (ref == kJoinRefNone) {
          expect(
              switch (slot) {
                kJoinSlotSideStreet => g.sideStreetJoinOf(lot),
                kJoinSlotAlley => g.rearAlleyJoinOf(lot),
                _ => null,
              },
              isNull);
          continue;
        }
        refs.add(ref);
        final got = g.joinOfRef(ref)!;
        if (slot == kJoinSlotAlley) {
          alleys++;
          expect(ref, kJoinRefAlleyBase - lot);
          sameSlot(got, g.rearAlleyJoinOf(lot), 'lot $lot rear alley');
          expect(got.flags & kJoinAlley, isNot(0));
        } else if (slot == kJoinSlotSideStreet) {
          sides++;
          expect(ref, kJoinRefSideStreetBase - lot);
          sameSlot(got, g.sideStreetJoinOf(lot), 'lot $lot side street');
          expect(got.flags & kJoinSideStreet, isNot(0));
        } else {
          expect(ref, g.lotJoinStart[lot] + slot);
          expect(got.piece, g.joinPiece[ref]);
          expect(got.s, g.joinS[ref]);
          expect(got.kerbE, g.joinKerbE[ref]);
          if (slot == 0) {
            expect([got.piece, got.s, got.dirs],
                [g.lotPiece[lot], g.lotS[lot], g.lotDirs[lot]]);
          }
        }
      }
    }
    expect(sides, greaterThan(0));
    // The starter kit draws no alley, so slot 3 is offered nowhere on it (the
    // rear joins have their own fixture, `rear_alley_slot_test`).
    expect(alleys, 0);
    final sorted = [...refs]..sort();
    for (var i = 1; i < sorted.length; i++) {
      expect(sorted[i], isNot(sorted[i - 1]));
    }
    expect(g.joinOfRef(kJoinRefNone), isNull);
    expect(g.joinOfRef(g.joinCount), isNull);
    expect(g.joinOfRef(kJoinRefSideStreetBase - g.lotCount), isNull);
    expect(g.joinRefOf(-1, 0), kJoinRefNone);
    expect(g.joinRefOf(g.lotCount, 0), kJoinRefNone);
  });

  test('handles are stable while sharesStructureWith holds (withOverrides, '
      'refreshedFor)', () {
    final city = SyntheticSites.starterCity();
    final g = city.roadGraph;
    final chunk = SyntheticSites.starterChunk(g);
    final crossing = g.nodes.firstWhere((n) => n.legs.length >= 3);
    final lit = g.withOverrides([JunctionOverride(at: crossing.at, lights: true)]);
    expect(identical(lit, g), isFalse);
    city.layout.renameRoad(g.roads.first.id, 'Main Street');
    final renamed = g.refreshedFor(city.layout)!;
    expect(identical(renamed, g), isFalse);

    for (final copy in [lit, renamed]) {
      expect(copy.sharesStructureWith(g), isTrue);
      for (var lot = 0; lot < g.lotCount; lot++) {
        for (var slot = 0; slot <= 3; slot++) {
          final ref = g.joinRefOf(lot, slot);
          expect(copy.joinRefOf(lot, slot), ref);
          sameSlot(copy.joinOfRef(ref), g.joinOfRef(ref), 'lot $lot slot $slot');
        }
      }
      // A plan synced against the original is current for the copy.
      final vs = SitePlanValidator.validateChunk(chunk,
          graph: copy, laneSpans: SyntheticSites.laneSpansOf(copy));
      expect(vs, isEmpty, reason: vs.join('\n'));
    }
  });

  test('across a structure change handles are re-resolved, never carried', () {
    final city = SyntheticSites.starterCity();
    final g = city.roadGraph;
    final old = SyntheticSites.starterChunk(g);
    // A new manual lot goes among the manual lots, ahead of every auto lot
    // in the graph's lot order: the auto lots are renumbered.
    city.layout.addManualParcel(const [
      Vec2(-200, 600), Vec2(-150, 600), Vec2(-150, 650), Vec2(-200, 650), //
    ]);
    final g2 = RoadGraph.of(city.layout);
    expect(g2.sharesStructureWith(g), isFalse);
    expect(g2.lotCount, g.lotCount + 1);

    // An old handle read against the new graph fails V3 wherever its lot
    // number now names another lot.
    final stale = SitePlanValidator.validateChunk(old, graph: g2);
    var moved = 0;
    for (var k = 0; k < old.siteCount; k++) {
      final p = old.plan(k);
      if (p.graphLot < 0) continue;
      final renumbered = g2.lotIds[p.graphLot] != g.lotIds[p.graphLot];
      if (renumbered) moved++;
      final v3 = stale.where(
          (v) => v.site == k && v.invariant == SiteInvariant.v3OneSource);
      expect(v3.isNotEmpty, renumbered, reason: p.siteId);
    }
    expect(moved, greaterThan(0));

    // Re-resolved by lot id on the new graph, every fixture is valid again,
    // and its revision is the old one: handles are no part of rev.
    final fresh = SyntheticSites.starterChunk(g2);
    final vs = SitePlanValidator.validateChunk(fresh, graph: g2,
        laneSpans: SyntheticSites.laneSpansOf(g2));
    expect(vs, isEmpty, reason: vs.join('\n'));
    for (var k = 0; k < fresh.siteCount; k++) {
      final p = fresh.plan(k), q = old.plan(k);
      if (q.graphLot < 0) continue;
      expect(p.graphLot, g2.lotNoOf(g.lotIds[q.graphLot]), reason: p.siteId);
      expect(p.rev, q.rev, reason: p.siteId);
    }
  });
}
