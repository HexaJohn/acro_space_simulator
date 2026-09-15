// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The site sync and what it keeps (docs/plans/t4a-implementation.md §1.3;
/// site-access.md §7.5, §7.6, §7.8 items 2 and 7, D49).
///
/// What is pinned here is what a plan change may NOT cost: a car parked in a
/// lot whose site was re-planned around it keeps its stall by key, a car
/// driving inside a site whose plan went keeps a plan to drive on until it
/// is out, and a site that was re-resolved against a new road graph without
/// changing a centimetre moves nothing at all. Each of those is a case
/// where the cheap implementation — rebuild everything, or drop what does
/// not match — teleports or deletes a car, and no behavioural test would
/// notice.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/building_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_geometry.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_plan_source.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:flutter_test/flutter_test.dart';

import '../colony/site_access/site_plan_fixtures.dart';
import 'site_fixture.dart';
import 'traffic_fixture.dart';

void main() {
  final strip = lotOf(SyntheticTemplate.strip);
  final home = lotOf(SyntheticTemplate.home);
  final tandem = lotOf(SyntheticTemplate.homeTandem);
  final kerbside = lotOf(SyntheticTemplate.kerbside);

  /// A town with the strip car park, both home drives and a kerbside plan.
  SiteWorld world({bool validate = true}) => SiteWorld(
        {
          strip: SyntheticTemplate.strip,
          home: SyntheticTemplate.home,
          tandem: SyntheticTemplate.homeTandem,
          kerbside: SyntheticTemplate.kerbside,
        },
        validate: validate,
      )..sync();

  group('capacity and stalls', () {
    test('lotCap is the stall count, and nothing else is', () {
      final w = world();
      final s = w.sites;
      for (final lot in [strip, home, tandem]) {
        final row = w.rowOf(lot);
        expect(s.lotCap[row], w.planOf(lot).stallCount, reason: lot);
        expect(s.lotUsed[row], 0, reason: lot);
      }
      expect(w.rowOf(kerbside), -1, reason: 'a kerbside plan has no row');
      expect(s.rowOfBuilding(-1), -1);
      expect(s.rowOfBuilding(1 << 20), -1, reason: 'a slot off the end');
    });

    test('reserving and parking keep lotUsed and the bitmap exact', () {
      final w = world();
      final s = w.sites;
      final row = w.rowOf(home);
      expect(s.lotCap[row], 2);

      expect(s.reserve(row, 0, 11), isTrue);
      expect(s.lotUsed[row], 1);
      expect(s.stallTaken(row, 0), isTrue);
      expect(s.reserve(row, 0, 12), isFalse, reason: 'binding (D17)');
      expect(s.lotUsed[row], 1, reason: 'a refused reservation counts once');
      expect(s.firstFreeStall(row, 0), 1, reason: 'the order skips it');

      // The reservation becomes the car: one stall, one use, all along.
      s.occupy(row, 0, 99);
      expect(s.lotUsed[row], 1);
      expect(s.stallRes[s.stallBase[row]], -1);
      expect(s.stallCar[s.stallBase[row]], 99);
      expect(s.stallTaken(row, 0), isTrue);

      expect(s.reserve(row, 1, 13), isTrue);
      expect(s.lotUsed[row], 2);
      expect(s.firstFreeStall(row, 0), -1, reason: 'the lot is full');

      s.unreserve(row, 1);
      expect(s.lotUsed[row], 1);
      expect(s.stallTaken(row, 1), isFalse);
      s.unreserve(row, 1);
      expect(s.lotUsed[row], 1, reason: 'twice is not twice');

      s.vacate(row, 0);
      expect(s.lotUsed[row], 0);
      expect(s.stallTaken(row, 0), isFalse);
      s.vacate(row, 0);
      expect(s.lotUsed[row], 0);

      // A stall that is not there is not a stall.
      expect(s.reserve(row, 2, 14), isFalse);
      expect(s.reserve(-1, 0, 14), isFalse);
      expect(s.firstFreeStall(row, -1), -1);
      expect(s.stallIndexOfKey(row, 12345), -1, reason: 'no such key');
      expect(s.stallIndexOfKey(-1, 0), -1);
    });

    test('a car parked on a stall follows its key, not its index', () {
      final w = world();
      final s = w.sites;
      final row = w.rowOf(strip);
      final p = w.planOf(strip);
      for (var i = 0; i < p.stallCount; i++) {
        expect(s.stallIndexOfKey(row, p.stallKey(i)), i, reason: 'stall $i');
      }
    });
  });

  group('needsSync', () {
    test('it fires on the revision, the chunks and the graph, and not else',
        () {
      final w = world();
      expect(w.sites.needsSync(w.plans, w.lg), isFalse,
          reason: 'nothing moved since the sync');
      expect(w.sites.syncedSitesRev, w.plans.sitesRev);

      // A different lane graph object is a rebuilt road network.
      expect(w.sites.needsSync(w.plans, LaneGraphBuilder.build(w.graph)), isTrue);
      expect(w.sites.needsSync(w.plans, null), isTrue);

      // A chunk republished with the same content is still a new chunk: the
      // book hands out a fresh list view on every read, so only the
      // ELEMENTS say anything.
      final same = FixturePlanSource(w.graph, {
        strip: SyntheticTemplate.strip,
        home: SyntheticTemplate.home,
        tandem: SyntheticTemplate.homeTandem,
        kerbside: SyntheticTemplate.kerbside,
      });
      expect(w.sites.needsSync(same, w.lg), isTrue);

      w.plans.replace(home, SyntheticTemplate.homeTandem);
      expect(w.sites.needsSync(w.plans, w.lg), isTrue);
    });

    test('a fresh table always needs one', () {
      final w = SiteWorld({strip: SyntheticTemplate.strip});
      expect(w.sites.syncedSitesRev, -1);
      expect(w.sites.needsSync(w.plans, w.lg), isTrue);
    });
  });

  group('a plan that did not change', () {
    test('a re-resolution against a new graph moves nothing at all', () {
      final w = world();
      final s = w.sites;
      final row = w.rowOf(strip);
      s.occupy(row, 3, 42);
      s.reserve(row, 5, 43);
      final before = s.digest(kFnvOffset32);
      final rows = [for (final l in [strip, home, tandem]) w.rowOf(l)];

      // The same sites, emitted again: the same `rev` down to the
      // centimetre (V12), in chunk objects nothing has seen before.
      final again = FixturePlanSource(w.graph, {
        strip: SyntheticTemplate.strip,
        home: SyntheticTemplate.home,
        tandem: SyntheticTemplate.homeTandem,
        kerbside: SyntheticTemplate.kerbside,
      });
      w.changes.clear();
      s.sync(again, w.buildings, w.lg, w.changes);

      expect(w.changes.count, 0, reason: 'nothing happened to tell about');
      expect([for (final l in [strip, home, tandem]) w.rowOf(l)], rows,
          reason: 'the rows are the rows');
      expect(s.digest(kFnvOffset32), before,
          reason: 'a re-resolution is not a change');
      expect(s.stallCar[s.stallBase[row] + 3], 42);
      expect(s.stallRes[s.stallBase[row] + 5], 43);
      expect(s.lotUsed[row], 2);
      expect(identical(s.plan[row], again.planOf(strip)), isFalse,
          reason: 'planOf allocates a view, so it is never the same object');
      expect(s.plan[row]!.rev, again.planOf(strip)!.rev);
    });

    test('a neighbour re-planned leaves this site where it was', () {
      final w = world();
      final s = w.sites;
      final row = w.rowOf(strip);
      s.occupy(row, 7, 21);
      final stripRev = s.rev[row];
      final stripDigest = s.stallCar[s.stallBase[row] + 7];

      // One lot changes; the fixture republishes the whole chunk, so every
      // other site's chunk object moves under it without its plan moving.
      w.plans.replace(home, SyntheticTemplate.homeTandem);
      w.sync();

      expect(w.changes.count, 1, reason: 'one site changed');
      expect(w.changes.kind[0], kSiteChangeRev);
      expect(w.rowOf(strip), row, reason: 'the strip kept its row');
      expect(s.rev[row], stripRev);
      expect(s.stallCar[s.stallBase[row] + 7], stripDigest);
      expect(s.lotUsed[row], 1);
    });
  });

  group('a plan that changed (§7.6)', () {
    test('a changed rev opens a new row, and the keys carry the cars over',
        () {
      // Validation off: a home pad with one stall is not something a
      // generator emits, and taking one stall out is the only way to move
      // PART of a site — which is what `stallKey` is for.
      final w = SiteWorld({tandem: SyntheticTemplate.homeTandem},
          validate: false)
        ..sync();
      final s = w.sites;
      final was = w.rowOf(tandem);
      final p0 = w.planOf(tandem);
      expect(p0.stallCount, 2);
      final deepKey = p0.stallKey(1);
      s.occupy(was, 1, 77);
      s.reserve(was, 0, 55);
      expect(s.lotUsed[was], 2);

      w.plans.edit(tandem, (d) => d.stalls.removeAt(0));
      w.sync();

      final now = w.rowOf(tandem);
      expect(now, isNot(was), reason: 'both halves must be readable at once');
      expect(w.changes.count, 1);
      expect(w.changes.kind[0], kSiteChangeRev, reason: '§7.6 row 1');
      expect(w.changes.oldRow[0], was);
      expect(w.changes.newRow[0], now);

      // The old row is limbo: its plan, its stalls and its cars all stand.
      expect(s.rowFlags[was] & kRowLimbo, kRowLimbo);
      expect(s.rowFlags[was] & kRowLive, kRowLive);
      expect(s.lotCap[was], 0, reason: 'but it takes nobody new');
      expect(s.plan[was]!.stallCount, 2);
      expect(s.stallCar[s.stallBase[was] + 1], 77);
      expect(s.stallRes[s.stallBase[was] + 0], 55);

      // The new row has one stall — the deep one, under its old key, at a
      // new index. That is C-19: indices are stable per `rev` only.
      expect(s.rev[now], isNot(s.rev[was]));
      expect(s.lotCap[now], 1);
      expect(s.plan[now]!.stallCount, 1);
      final at = s.stallIndexOfKey(now, deepKey);
      expect(at, 0, reason: 'the key kept, the index moved');
      expect(s.plan[now]!.stallKey(at), deepKey);
      expect(s.stallIndexOfKey(now, p0.stallKey(0)), -1,
          reason: 'the stall that went takes its key with it');

      // What the facade then does, and what it leaves behind.
      s.occupy(now, at, 77);
      s.vacate(was, 1);
      s.unreserve(was, 0);
      s.endStep();
      expect(s.isRowLive(was), isFalse, reason: 'an empty limbo row goes');
      expect(s.lotUsed[now], 1);
    });

    test('a plan that became kerbside lost its role, and has no new row', () {
      final w = world();
      final s = w.sites;
      final was = w.rowOf(home);
      s.occupy(was, 0, 31);

      w.plans.replace(home, SyntheticTemplate.kerbside);
      w.sync();

      expect(w.changes.count, 1);
      expect(w.changes.kind[0], kSiteChangeLostRole, reason: '§7.6 row 2');
      expect(w.changes.oldRow[0], was);
      expect(w.changes.newRow[0], -1, reason: 'kerbside has no network row');
      expect(w.rowOf(home), -1);
      expect(s.rowFlags[was] & kRowLimbo, kRowLimbo);
      expect(s.stallCar[s.stallBase[was]], 31,
          reason: 'the car is still there for the sink to garage');
    });

    test('a join that lost its in role is a lost role, not a growth', () {
      // The strip's one join both ways, then out only: a car may still
      // leave, and none may come in.
      final w = SiteWorld({strip: SyntheticTemplate.strip}, validate: false)
        ..sync();
      final was = w.rowOf(strip);
      expect(w.planOf(strip).joinRole(0), SiteJoinRole.both);

      w.plans.edit(strip, (d) => d.joins[0].role = SiteJoinRole.outOnly);
      w.sync();

      expect(w.changes.count, 1);
      expect(w.changes.kind[0], kSiteChangeLostRole);
      expect(w.changes.oldRow[0], was);
      expect(w.changes.newRow[0], w.rowOf(strip),
          reason: 'it still has a network, so it still has a row');
      expect(w.rowOf(strip), isNot(was));
      expect(w.planOf(strip).joinCanIn(0), isFalse);
      expect(w.sites.firstFreeStall(w.rowOf(strip), 0),
          greaterThanOrEqualTo(0),
          reason: 'the stalls are still there; the GATE is what refuses');
    });

    test('a demolished site goes to limbo, and endStep frees it when empty',
        () {
      final w = world();
      final s = w.sites;
      final was = w.rowOf(strip);

      w.plans.replace(strip, null);
      w.sync();

      expect(w.changes.count, 1);
      expect(w.changes.kind[0], kSiteChangeGone, reason: '§7.6 row 3');
      expect(w.changes.oldRow[0], was);
      expect(w.rowOf(strip), -1);
      expect(s.rowFlags[was] & kRowLimbo, kRowLimbo);
      expect(s.plan[was], isNotNull, reason: 'the old chunk is immutable, so '
          'the cars inside keep something to drive on');

      // A car is still in there: the row stays until it is out.
      s.inside[was] = 1;
      s.endStep();
      expect(s.isRowLive(was), isTrue);
      s.inside[was] = 0;
      s.endStep();
      expect(s.isRowLive(was), isFalse);
      expect(s.plan[was], isNull);
      expect(s.rowOfBuilding(w.buildingOf(strip)), -1);

      // And the freed slot is handed out again to the next site.
      w.plans.replace(strip, SyntheticTemplate.strip);
      w.sync();
      expect(w.rowOf(strip), greaterThanOrEqualTo(0));
      expect(w.sites.lotCap[w.rowOf(strip)], 24);
    });

    test('a building torn down takes its site row with it', () {
      final w = world();
      final s = w.sites;
      final was = w.rowOf(home);
      expect(w.buildings.clear(home), isTrue);
      w.sync();
      expect(w.changes.count, 1);
      expect(w.changes.kind[0], kSiteChangeGone);
      expect(w.changes.oldRow[0], was);
      s.endStep();
      expect(s.isRowLive(was), isFalse);
    });
  });

  group('a plan that is not current (§0 Q5)', () {
    test('new arrivals are refused; the cars inside carry on', () {
      final w = world();
      final s = w.sites;
      final row = w.rowOf(strip);
      s.occupy(row, 2, 61);
      s.reserve(row, 4, 62);
      s.inside[row] = 3;
      final hops = s.targetCount[row];
      final wasIn = s.nextLane(row, w.lanesOf(strip).inLane(0), 0);

      // A road edit puts the plan in the queue for a check. `sitesRev` does
      // not move for that, so the sync is the one the rebuilt road network
      // asks for.
      w.plans.markStale(strip);
      w.sync();

      expect(w.rowOf(strip), row, reason: 'the row itself is untouched');
      expect(s.rowFlags[row] & kRowNotCurrent, kRowNotCurrent);
      expect(s.rowFlags[row] & kRowLimbo, 0, reason: 'it is not limbo');
      expect(s.lotCap[row], 0, reason: 'it advertises no stalls');
      expect(s.firstFreeStall(row, 0), -1, reason: 'nobody new comes in');
      expect(w.changes.count, 0, reason: 'nothing moved under the cars');

      expect(s.stallCar[s.stallBase[row] + 2], 61);
      expect(s.stallRes[s.stallBase[row] + 4], 62);
      expect(s.lotUsed[row], 2);
      expect(s.inside[row], 3);
      expect(s.targetCount[row], hops);
      expect(s.nextLane(row, w.lanesOf(strip).inLane(0), 0), wasIn,
          reason: 'a car inside still knows its way about');

      w.plans.markStale(strip, stale: false);
      w.sync();
      expect(s.rowFlags[row] & kRowNotCurrent, 0);
      expect(s.lotCap[row], 24);
      expect(s.lotUsed[row], 2);
    });
  });

  group('the real book', () {
    test('a sync on the starter kit builds a row per planned site', () {
      final city = starterKit();
      final graph = city.roadGraph;
      final lg = LaneGraphBuilder.build(graph);
      final b = BuildingTable()..sync(city, lg);
      final src = BookPlanSource(city.siteAccess);
      final sites = SiteTable();
      final changes = SiteChanges();
      expect(sites.needsSync(src, lg), isTrue);
      sites.sync(src, b, lg, changes);
      expect(changes.count, 0);
      expect(sites.needsSync(src, lg), isFalse);

      // The founding plans the three utilities, the spaceport and the
      // warehouse: every one of them a built site with a network.
      var rows = 0;
      for (final chunk in src.chunks) {
        for (var k = 0; k < chunk.siteCount; k++) {
          final id = chunk.siteId(k);
          final p = chunk.plan(k);
          final h = b.handleOfSite(id);
          if (h == null || p.flags & kPlanNetwork == 0) continue;
          rows++;
          final row = sites.rowOfBuilding(_slotOf(b, id));
          expect(row, greaterThanOrEqualTo(0), reason: id);
          expect(sites.lotCap[row], p.stallCount, reason: id);
          expect(sites.rev[row], p.rev, reason: id);
          expect(sites.bookSlot[row], src.slotOf(id), reason: id);
          expect(sites.laneCount[row], 2 * p.segCount, reason: id);
          expect(sites.rowFlags[row] & kRowNotCurrent, 0, reason: id);
          // Every stall of a real plan is reachable from its in-join.
          final g = sites.lanes[row]!;
          for (var j = 0; j < p.joinCount; j++) {
            final from = g.inLane(j);
            if (!p.joinCanIn(j) || from < 0) continue;
            for (var t = 0; t < sites.targetCount[row]; t++) {
              expect(sites.nextLane(row, from, t), greaterThanOrEqualTo(0),
                  reason: '$id join $j target $t');
            }
          }
        }
      }
      expect(rows, 5,
          reason: 'lot-m0..m3 and the founding car park, all built');
      for (final id in const [
        'lot-m0', 'lot-m1', 'lot-m2', 'lot-m3', 'lot-r0x0-r0', //
      ]) {
        expect(sites.rowOfBuilding(_slotOf(b, id)), greaterThanOrEqualTo(0),
            reason: id);
      }
    });
  });

  group('the digest and the buffers', () {
    test('an empty table folds nothing, so the old digests stand', () {
      expect(SiteTable().digest(kFnvOffset32), kFnvOffset32);
    });

    test('every stall, reservation and revision is folded', () {
      final w = world();
      final s = w.sites;
      final row = w.rowOf(strip);
      final base = s.digest(kFnvOffset32);
      expect(base, isNot(kFnvOffset32), reason: 'rows fold');

      for (final turn in <void Function()>[
        () => s.reserve(row, 0, 5),
        () => s.occupy(row, 1, 6),
        () => s.rev[row]++,
        () => s.lotCap[row]--,
        () => s.rowFlags[row] |= kRowNotCurrent,
        () => s.bookSlot[row]++,
      ]) {
        final was = s.digest(kFnvOffset32);
        turn();
        expect(s.digest(kFnvOffset32), isNot(was),
            reason: 'a twin run that differs anywhere must diverge');
      }

      // Put it back, and the digest comes back with it.
      s.bookSlot[row]--;
      s.rowFlags[row] &= ~kRowNotCurrent;
      s.lotCap[row]++;
      s.rev[row]--;
      s.vacate(row, 1);
      s.unreserve(row, 0);
      expect(s.digest(kFnvOffset32), base, reason: 'one state, one digest');
    });

    test('collectBuffers names every buffer, and a step replaces none', () {
      final w = world();
      final into = <String, Object>{};
      w.sites.collectBuffers(into, 'sites');
      expect(into, isNotEmpty);
      expect(into.containsKey('sites.stallRes'), isTrue);
      expect(into.containsKey('sites.hop'), isTrue);
      expect(into.containsKey('sites.elemHead'), isTrue);
      final after = <String, Object>{};
      w.sites
        ..reserve(w.rowOf(strip), 0, 3)
        ..occupy(w.rowOf(strip), 0, 3)
        ..vacate(w.rowOf(strip), 0)
        ..endStep();
      w.sites.collectBuffers(after, 'sites');
      expect(after.length, into.length);
      for (final name in into.keys) {
        expect(identical(after[name], into[name]), isTrue,
            reason: '$name was replaced outside a sync');
      }
    });
  });

  group('site geometry', () {
    test('a lane runs where its segment does, a lane width to its right', () {
      final w = world();
      final g = w.lanesOf(strip);
      final p = w.planOf(strip);
      final out = Float64List(SiteGeometry.poseStride);
      // The aisle: segment 1, two-way and 6 m wide, so 1.5 m each side.
      const aisle = 1;
      final fwd = SiteLaneGraph.laneOf(aisle, forward: true);
      final bwd = SiteLaneGraph.laneOf(aisle, forward: false);
      expect(g.laneOffsetM(fwd), closeTo(1.5, 1e-9));

      SiteGeometry.pointAt(g, fwd, 0, out, 0);
      final e0 = out[0], n0 = out[1], de = out[2], dn = out[3];
      expect(out[4], 0);
      // On the centreline's start node, moved a lane width to the right of
      // travel: right is the direction turned a quarter clockwise.
      final node = p.nodePt(p.segFrom(aisle));
      expect(e0 - dn * 1.5, closeTo(p.ptE(node), 1e-6));
      expect(n0 + de * 1.5, closeTo(p.ptN(node), 1e-6));

      SiteGeometry.pointAt(g, fwd, p.segLenM(aisle), out, 0);
      expect(out[4], closeTo(p.segLenM(aisle), 1e-3));
      SiteGeometry.pointAt(g, fwd, 1e6, out, 0);
      expect(out[4], closeTo(p.segLenM(aisle), 1e-3),
          reason: 'an overrun is clamped to the lane, never off the plan');

      // The two lanes of a two-way segment run opposite ways, a full width
      // apart.
      SiteGeometry.pointAt(g, bwd, p.segLenM(aisle), out, 0);
      expect(out[2], closeTo(-de, 1e-6));
      expect(out[3], closeTo(-dn, 1e-6));
      expect(_dist(out[0], out[1], e0, n0), closeTo(3.0, 1e-3));
    });

    test('a point on a lane projects back onto it', () {
      final w = world();
      final g = w.lanesOf(strip);
      final at = Float64List(SiteGeometry.poseStride);
      final back = Float64List(SiteGeometry.poseStride);
      const aisle = 1;
      final fwd = SiteLaneGraph.laneOf(aisle, forward: true);
      for (final s in const [0.0, 7.5, 21.0, 41.0]) {
        SiteGeometry.pointAt(g, fwd, s, at, 0);
        final d = SiteGeometry.project(g, fwd, at[0], at[1], back, 0);
        expect(d, closeTo(0, 1e-6), reason: 'at $s');
        expect(back[4], closeTo(s, 1e-3), reason: 'at $s');
      }
      // A metre off to the side is a metre off.
      SiteGeometry.pointAt(g, fwd, 20, at, 0);
      final off = SiteGeometry.project(
          g, fwd, at[0] + at[3], at[1] - at[2], back, 0);
      expect(off, closeTo(1.0, 1e-6));
      expect(back[4], closeTo(20, 1e-3));
    });

    test('the snap takes the nearest lane going the same way (§7.6 row 1)',
        () {
      final w = world();
      final g = w.lanesOf(strip);
      final at = Float64List(SiteGeometry.poseStride);
      final got = Float64List(SiteGeometry.poseStride);
      const aisle = 1;
      final fwd = SiteLaneGraph.laneOf(aisle, forward: true);
      final bwd = SiteLaneGraph.laneOf(aisle, forward: false);
      SiteGeometry.pointAt(g, fwd, 18, at, 0);

      expect(SiteGeometry.snap(g, at[0], at[1], at[2], at[3], 3, 0.5, got, 0),
          fwd);
      expect(got[4], closeTo(18, 1e-3));

      // The same place, facing the other way: the forward lane is nearer but
      // it is against the traffic, so the snap crosses to the other lane.
      expect(SiteGeometry.snap(g, at[0], at[1], -at[2], -at[3], 4, 0.5, got, 0),
          bwd);
      expect(SiteGeometry.snap(g, at[0], at[1], -at[2], -at[3], 1, 0.5, got, 0),
          -1, reason: 'and not when the other lane is out of reach');

      // Far enough away and there is nothing to snap to at all.
      expect(
          SiteGeometry.snap(
              g, at[0] + 500, at[1] + 500, at[2], at[3], 3, 0.5, got, 0),
          -1);
    });
  });
}

double _dist(double ae, double an, double be, double bn) {
  final de = be - ae, dn = bn - an;
  return math.sqrt(de * de + dn * dn);
}

int _slotOf(BuildingTable b, String id) {
  final h = b.handleOfSite(id);
  return h == null ? -1 : SlotPool.slotOf(h);
}
