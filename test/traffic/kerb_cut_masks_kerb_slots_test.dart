// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Kerb slots, and the cut masks over them — A12's traffic half
/// (docs/plans/site-access.md §5.5, §7.5, §7.9 A12; agent-traffic.md §7.1,
/// §7.3 step 2; t4a-implementation.md §0 Q1, §1.7).
///
/// Three things are pinned here.
///
/// - **Capacities** are §7.1's, off the lane graph and nothing else: the
///   right kerb of every directed edge that parks at the kerb, both kerbs of
///   a one-way road, and none at all where a road has no kerb parking.
/// - **Masks** go through the road side's `KerbCuts.parkingBlocked`, on the
///   canonical entries of real plans and the canonical arc a slot converts
///   to. There is no copy of the formula on this side, so every bound below
///   is asserted in TRAVEL terms — `[T − 12, T + 3]` around a home join on
///   each served kerb, 3.25 m each way around any other program — and the
///   conversion is what is under test.
/// - **A12's cross-check**: the same cuts, masked in the canonical arc the
///   agents work in and in the drawn arc the renderer works in
///   (`KerbCuts.toDrawn`), agree within 0.5 m per cut. The road side owns
///   the baked half (`kerb_cut_masks_baked_test`).
///
/// And the rule the parking search leans on: a reservation is BINDING, so
/// two vehicles never get one slot.
library;

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/kerb_cuts.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/kerb_mask.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/kerb_slots.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import '../colony/site_access/site_plan_fixtures.dart';
import 'site_fixture.dart';

/// One road, 400 m east from the origin, with its lots cut: the plainest
/// network a kerb slot can stand on.
typedef Road = ({RoadGraph graph, LaneGraph lanes, double lengthM});

void main() {
  tearDown(AgentTuning.reset);

  Road road(RoadClass cls, {bool reversed = false}) {
    final layout = CityLayout()
      ..commitRoad(
          controls: const [Vec2(0, 0), Vec2(400, 0)],
          roadClass: cls,
          reversed: reversed);
    final g = RoadGraph.of(layout);
    return (
      graph: g,
      lanes: LaneGraphBuilder.build(g),
      lengthM: g.roadRecs[0].lengthM
    );
  }

  /// [template] on the first lot of [r], as the plans traffic reads, and the
  /// mask its cuts make.
  ///
  /// The road side's synthetic chunks carry no graph stamp (their builder
  /// leaves it 0), so `canonicalOf` takes them for sites resolved against an
  /// older graph and asks for that graph's road ids. This graph's ids ARE
  /// theirs — they were drafted on it — so the answer is the table a book's
  /// stamped chunk would give, cut for cut.
  (FixturePlanSource, CutKerbMask) planOn(Road r, SyntheticTemplate template) {
    final src = FixturePlanSource(r.graph, {r.graph.lotIds.first: template});
    final ids = [for (final road in r.graph.roads) road.id];
    return (
      src,
      CutKerbMask.of(r.lanes, src,
          roadIdsAt: (stamp) => stamp == 0 ? ids : null)
    );
  }

  /// The cut join of [src]'s only site: its road arc and cut half.
  (double, double) cutOf(FixturePlanSource src) {
    final chunk = src.chunks.first;
    final j = chunk.joinStart(0);
    return (chunk.joinRoadS(j), chunk.joinCutHalfM(j));
  }

  /// The travel arcs of every masked slot of [edge], in order.
  List<double> maskedOn(KerbTable k, CutKerbMask mask, int edge, int side) => [
        for (var s = k.slotStart(edge); s < k.slotEnd(edge); s++)
          if (k.slotSide(s) == side &&
              mask.parkingBlocked(k.slotEdge(s), k.slotT(s), side == 1))
            k.slotT(s),
      ];

  group('capacities are §7.1\'s, off the lane graph', () {
    test('a 400 m street: the right kerb of each way, 6.5 m apart', () {
      final r = road(RoadClass.street);
      final lg = r.lanes;
      final k = KerbTable()..bind(lg);
      expect(lg.edgeCount, 2, reason: 'one stretch, both ways');
      expect(k.slotCount, 118);
      for (var e = 0; e < 2; e++) {
        final span = lg.edgeLaneS1[e] - lg.edgeLaneS0[e];
        expect(k.capOf(e), ((span - kKerbEndClearM) / kKerbSlotPitchM).floor());
        expect(k.capOf(e), 59, reason: '(400 − 12) / 6.5');
        expect(k.rightCount(e), k.capOf(e),
            reason: 'a two-way road: this edge owns its right kerb only');
        for (var s = k.slotStart(e); s < k.slotEnd(e); s++) {
          final i = s - k.slotStart(e);
          expect(k.slotT(s),
              closeTo(lg.edgeLaneS0[e] + 6 + (i + 0.5) * kKerbSlotPitchM, 1e-9));
          expect(k.slotSide(s), 1);
          expect(k.slotLane(s), lg.laneOf(e, 0), reason: 'the kerb lane');
          expect(k.slotEdge(s), e);
          expect(k.slotT(s), greaterThan(lg.edgeLaneS0[e]));
          expect(k.slotT(s), lessThan(lg.edgeLaneS1[e]));
          expect(k.isFree(s), isTrue);
        }
      }
    });

    test('a one-way street owns both its kerbs, on the lanes that serve them',
        () {
      final r = road(RoadClass.streetOneWay);
      final lg = r.lanes;
      final k = KerbTable()..bind(lg);
      expect(lg.edgeCount, 1);
      expect(lg.edgeReverse[0], -1, reason: 'no other way round');
      expect(k.capOf(0), 118, reason: '59 a kerb, both kerbs on one edge');
      expect(k.rightCount(0), 59);
      final lanes = lg.edgeLaneCount[0];
      for (var s = 0; s < k.slotCount; s++) {
        final right = s < k.rightCount(0);
        expect(k.slotSide(s), right ? 1 : 0);
        expect(k.slotLane(s), lg.laneOf(0, right ? 0 : lanes - 1),
            reason: 'lane 0 serves the right kerb, lane L − 1 the left');
      }
      // The two kerbs stand at the same arcs, one run after the other.
      for (var i = 0; i < 59; i++) {
        expect(k.slotT(i), k.slotT(59 + i));
      }
    });

    test('a road with no kerb parking has no slots', () {
      for (final cls in [RoadClass.alley, RoadClass.highway]) {
        final r = road(cls);
        final k = KerbTable()..bind(r.lanes);
        expect(k.slotCount, 0, reason: '$cls');
        for (var e = 0; e < r.lanes.edgeCount; e++) {
          expect(k.capOf(e), 0);
          expect(r.lanes.hasFlag(e, kEdgeParking), isFalse,
              reason: 'an alley has no pavement; a highway kerb is a '
                  'shoulder (road-agent trap 11)');
        }
      }
    });
  });

  group('masks come from KerbCuts, and land in travel terms', () {
    test('a home join masks [T − 12, T + 3] on BOTH kerbs of a 1+1 street',
        () {
      final r = road(RoadClass.street);
      final (src, mask) = planOn(r, SyntheticTemplate.home);
      final (c, half) = cutOf(src);
      expect(half, kHomeCutHalfM);
      final lg = r.lanes;
      final k = KerbTable()..bind(lg);

      // One entry a kerb: the lot's own, and the far kerb a back-out swings
      // over on a street served both ways (§5.5).
      final entries = mask.entriesOf(0)!;
      expect(entries, hasLength(2 * KerbCuts.stride));
      expect(entries[4], KerbCuts.kindHomeLot);
      expect(entries[9], KerbCuts.kindHomeFarSwing);

      for (var e = 0; e < 2; e++) {
        // The join's arc in THIS edge's travel terms, and the slots masked
        // on the right kerb of that travel.
        final t = lg.travelArc(e, c);
        final masked = maskedOn(k, mask, e, 1);
        expect(masked, isNotEmpty, reason: 'edge $e');
        for (var s = k.slotStart(e); s < k.slotEnd(e); s++) {
          final inSwing = k.slotT(s) > t - half - kHomeSwingUpM &&
              k.slotT(s) < t + half + kHomeSwingDownM;
          expect(masked.contains(k.slotT(s)), inSwing,
              reason: 'edge $e slot at ${k.slotT(s)}, join at $t');
        }
        // 12 m upstream and 3 m down, whichever way this edge runs.
        expect(masked.first, greaterThan(t - half - kHomeSwingUpM));
        expect(masked.first, lessThan(t - half - kHomeSwingUpM + kKerbSlotPitchM));
        expect(masked.last, lessThan(t + half + kHomeSwingDownM));
        expect(masked.last,
            greaterThan(t + half + kHomeSwingDownM - kKerbSlotPitchM));
      }
    });

    test('on a reversed one-way road the arc and the side both flip', () {
      final r = road(RoadClass.streetOneWay, reversed: true);
      final (src, mask) = planOn(r, SyntheticTemplate.home);
      final (c, half) = cutOf(src);
      final lg = r.lanes;
      expect(lg.edgeForward[0], 0, reason: 'travel runs last point to first');
      final k = KerbTable()..bind(lg);
      final t = lg.travelArc(0, c);
      expect(t, closeTo(r.lengthM - c, 1e-9));

      // The lot's kerb is canonical side 0 here (joinRight is false), and on
      // a backward edge canonical side 0 IS the right of travel.
      expect(mask.sideOf(0, true), 0);
      expect(mask.sideOf(0, false), 1);
      expect(mask.arcOf(0, t), closeTo(c, 1e-9));

      final masked = maskedOn(k, mask, 0, 1);
      expect(masked, isNotEmpty);
      for (final at in masked) {
        expect(at, greaterThan(t - half - kHomeSwingUpM));
        expect(at, lessThan(t + half + kHomeSwingDownM));
      }
      expect(maskedOn(k, mask, 0, 0), isEmpty,
          reason: 'a one-way road has no far-direction back-out, so the '
              'other kerb keeps its parking');
    });

    test('every other program masks 3.25 m each way, on its own kerb only',
        () {
      final r = road(RoadClass.street);
      final (src, mask) = planOn(r, SyntheticTemplate.strip);
      final (c, half) = cutOf(src);
      final lg = r.lanes;
      final k = KerbTable()..bind(lg);
      expect(mask.entriesOf(0), hasLength(KerbCuts.stride));
      expect(mask.entriesOf(0)![4], KerbCuts.kindDropped);
      expect(kKerbMaskM, 3.25);

      // The lot is south of the road, so its kerb is the right of the
      // BACKWARD edge; the forward edge's kerb is the other side of the
      // street and a car park swings over nothing.
      expect(maskedOn(k, mask, 0, 1), isEmpty);
      final masked = maskedOn(k, mask, 1, 1);
      expect(masked, isNotEmpty);
      final t = lg.travelArc(1, c);
      for (var s = k.slotStart(1); s < k.slotEnd(1); s++) {
        expect(masked.contains(k.slotT(s)), (k.slotT(s) - t).abs() < half + kKerbMaskM,
            reason: 'slot at ${k.slotT(s)}, join at $t');
      }
    });

    test('a kerbside join masks nothing at all', () {
      final r = road(RoadClass.street);
      final (src, mask) = planOn(r, SyntheticTemplate.kerbside);
      expect(src.chunks.first.stallCountOf(0), 0, reason: 'lotCap = 0');
      expect(mask.entriesOf(0), isNull, reason: 'a kerbside join is no cut');
      final k = KerbTable()..bind(r.lanes);
      for (var s = 0; s < k.slotCount; s++) {
        expect(
            mask.parkingBlocked(
                k.slotEdge(s), k.slotT(s), k.slotSide(s) == 1),
            isFalse);
      }
    });

    test('an avenue home is served one way, so only its own kerb is masked',
        () {
      // §7.5: avenues allow a back-out in the near direction only, so the
      // far kerb gets no swing mask.
      final r = road(RoadClass.avenue);
      final (_, mask) = planOn(r, SyntheticTemplate.home);
      expect(mask.entriesOf(0), hasLength(KerbCuts.stride));
      final k = KerbTable()..bind(r.lanes);
      expect(maskedOn(k, mask, 0, 1), isEmpty);
      expect(maskedOn(k, mask, 1, 1), isNotEmpty);
    });

    test('applyMasks takes the slots out of the search, and moves cars off',
        () {
      final r = road(RoadClass.street);
      final (_, mask) = planOn(r, SyntheticTemplate.home);
      final k = KerbTable()..bind(r.lanes);
      final sites = SiteTable();

      // A car parked on a slot a later plan masks is one the facade has to
      // relocate, exactly as a car on a stall that vanished.
      var doomed = -1;
      for (var s = 0; s < k.slotCount && doomed < 0; s++) {
        if (mask.parkingBlocked(k.slotEdge(s), k.slotT(s), k.slotSide(s) == 1)) {
          doomed = s;
        }
      }
      expect(doomed, greaterThanOrEqualTo(0));
      k.occupy(doomed, 77);
      expect(k.relocateCount, 0, reason: 'nothing masks it yet');

      k.applyMasks(sites, r.lanes, mask);
      expect(k.isMasked(doomed), isTrue);
      expect(k.isFree(doomed), isFalse);
      expect(k.relocateCount, 1);
      expect(k.relocateCar(0), 77);
      k.clearRelocations();
      expect(k.relocateCount, 0);

      // And a car that parks on an already masked slot is marked at once.
      k.release(doomed);
      k.occupy(doomed, 78);
      expect(k.relocateCount, 1);
      expect(k.relocateCar(0), 78);

      // Masking again with nothing to mask frees every slot for the search.
      k.clearRelocations();
      k.release(doomed);
      k.applyMasks(sites, r.lanes, const OpenKerbs());
      expect(k.isMasked(doomed), isFalse);
      expect(k.isFree(doomed), isTrue);
      expect(k.relocateCount, 0);
    });
  });

  test('A12: the canonical arc and the drawn arc mask the same ground', () {
    // The agents mask in the road's index arc; the renderer masks the same
    // cuts rescaled to the arc it draws them along, and mirrored for a road
    // the frame sends reversed. The two must agree within 0.5 m per cut —
    // not bit for bit, because the drape is not the index polyline (§10.1).
    final r = road(RoadClass.street);
    final (_, mask) = planOn(r, SyntheticTemplate.home);
    final canon = mask.entriesOf(0)!;
    final k = KerbTable()..bind(r.lanes);
    final l = r.lengthM;

    var worst = 0.0;
    var cuts = 0;
    for (final reversed in [false, true]) {
      // A drape that runs a full percent longer than the index polyline is
      // far past anything a real road shows (the road side pins its own cut
      // arcs to 0.5 m against the drawn kerb points, site_capture_test).
      for (final stretch in [1.0, 1.01]) {
        final drawnLen = l * stretch;
        final drawn = KerbCuts.toDrawn(canon,
            indexLengthM: l, drawnLengthM: drawnLen, reversed: reversed);
        double toDrawnArc(double s) =>
            reversed ? drawnLen - s * stretch : s * stretch;
        int toDrawnSide(int side) => reversed ? 1 - side : side;

        for (final side in [0, 1]) {
          // Where each frame says the mask starts and stops, walked in the
          // canonical arc at a centimetre.
          final canonRuns = _runs(
              (s) => KerbCuts.parkingBlocked(canon, side, s), l);
          final drawnRuns = _runs(
              (s) => KerbCuts.parkingBlocked(
                  drawn, toDrawnSide(side), toDrawnArc(s)),
              l);
          expect(drawnRuns, hasLength(canonRuns.length),
              reason: 'side $side, reversed $reversed, stretch $stretch');
          for (var i = 0; i < canonRuns.length; i++) {
            final dLo = (canonRuns[i].$1 - drawnRuns[i].$1).abs();
            final dHi = (canonRuns[i].$2 - drawnRuns[i].$2).abs();
            if (dLo > worst) worst = dLo;
            if (dHi > worst) worst = dHi;
            expect(dLo, lessThanOrEqualTo(0.5));
            expect(dHi, lessThanOrEqualTo(0.5));
            cuts++;
          }
          if (stretch == 1.0) {
            expect(canonRuns, drawnRuns,
                reason: 'a drape of the index length is the index arc');
          }
        }

        // And the slots themselves: every one whose centre is clear of a
        // boundary by more than the bound gets the same answer either way.
        for (var s = 0; s < k.slotCount; s++) {
          final arc = mask.arcOf(k.slotEdge(s), k.slotT(s));
          final side = mask.sideOf(k.slotEdge(s), k.slotSide(s) == 1);
          final here = KerbCuts.parkingBlocked(canon, side, arc);
          final near = KerbCuts.parkingBlocked(canon, side, arc - 0.5) != here ||
              KerbCuts.parkingBlocked(canon, side, arc + 0.5) != here;
          if (near) continue;
          expect(
              KerbCuts.parkingBlocked(
                  drawn, toDrawnSide(side), toDrawnArc(arc)),
              here,
              reason: 'slot ${k.slotT(s)} on edge ${k.slotEdge(s)}');
        }
      }
    }
    expect(cuts, greaterThanOrEqualTo(8), reason: 'both kerbs, both frames');
    // Reported so the merge has the number: the worst boundary disagreement
    // over every cut, both kerbs, mirrored and not, at a 1% stretch.
    expect(worst, lessThanOrEqualTo(0.5), reason: 'worst $worst');
    expect(worst, closeTo(0.15, 0.02),
        reason: 'a stretched drape does move the bounds, by the swing mask '
            'times the stretch: 16 m × 0.01 / 1.01 ≈ 0.158 m, read off a '
            'centimetre walk as 0.15; measured $worst');
  });

  group('a reservation is binding', () {
    test('two vehicles never get one slot, and a released slot comes back',
        () {
      final r = road(RoadClass.street);
      final lg = r.lanes;
      final k = KerbTable()..bind(lg);
      final lane = lg.laneOf(0, 0);

      final first = k.reserveAhead(lane, 20, 101);
      expect(first, greaterThanOrEqualTo(0));
      expect(k.slotT(first), greaterThanOrEqualTo(20.0));
      expect(k.reservationOf(first), 101);
      expect(k.isFree(first), isFalse, reason: 'binding at once (§7.3)');

      final second = k.reserveAhead(lane, 20, 102);
      expect(second, isNot(first));
      expect(k.slotT(second), greaterThan(k.slotT(first)));
      expect(k.usedOf(0), 2);

      // The first car parks on what it was promised; the second gives up.
      k.occupy(first, 7);
      expect(k.carOf(first), 7);
      expect(k.reservationOf(first), -1);
      k.release(second);
      expect(k.isFree(second), isTrue);
      expect(k.reserveAhead(lane, 20, 103), second,
          reason: 'a released slot is the nearest free one again');
    });

    test('ahead on this edge, within kerbAheadM, and never a masked slot',
        () {
      final r = road(RoadClass.street);
      final (_, mask) = planOn(r, SyntheticTemplate.home);
      final lg = r.lanes;
      final k = KerbTable()..bind(lg);
      k.applyMasks(SiteTable(), lg, mask);
      final lane = lg.laneOf(1, 0);

      // The masked run on edge 1 is the home's swing path: a search that
      // starts just before it steps over it.
      final masked = maskedOn(k, mask, 1, 1);
      expect(masked, isNotEmpty);
      final from = masked.first - 3;
      final got = k.reserveAhead(lane, from, 1);
      expect(got, greaterThanOrEqualTo(0));
      expect(k.slotT(got), greaterThan(masked.last));
      expect(k.isMasked(got), isFalse);

      // Nothing behind the car, and nothing past the 60 m reach.
      expect(k.reserveAhead(lane, lg.edgeLaneS1[1] - 1, 2), -1,
          reason: 'no slot is left ahead');
      AgentTuning.kerbAheadM = 3;
      expect(k.reserveAhead(lane, 16, 3), -1,
          reason: 'the next slot is farther than the reach');
      AgentTuning.kerbAheadM = 60;
      expect(k.reserveAhead(lane, 16, 4), greaterThanOrEqualTo(0));
    });

    test('nearestFree serves the tandem shuffle', () {
      final r = road(RoadClass.street);
      final lg = r.lanes;
      final k = KerbTable()..bind(lg);
      final at = k.nearestFree(0, 200, 1);
      expect(at, greaterThanOrEqualTo(0));
      expect((k.slotT(at) - 200).abs(), lessThan(kKerbSlotPitchM));
      expect(k.nearestFree(0, 200, 0), -1,
          reason: 'a two-way road has no left-kerb slots on this edge');
      k.occupy(at, 5);
      final next = k.nearestFree(0, 200, 1);
      expect(next, isNot(at));
      expect((k.slotT(next) - 200).abs(),
          greaterThanOrEqualTo((k.slotT(at) - 200).abs()));
    });
  });

  test('the digest and the buffers: state, and nothing reallocated', () {
    final r = road(RoadClass.street);
    final (_, mask) = planOn(r, SyntheticTemplate.home);
    final a = KerbTable()..bind(r.lanes);
    final b = KerbTable()..bind(r.lanes);
    expect(a.digest(0), b.digest(0));
    a.occupy(4, 9);
    expect(a.digest(0), isNot(b.digest(0)));
    b.occupy(4, 9);
    expect(a.digest(0), b.digest(0));
    a.applyMasks(SiteTable(), r.lanes, mask);
    expect(a.digest(0), isNot(b.digest(0)), reason: 'a mask is state too');

    final before = <String, Object>{};
    a.collectBuffers(before, 'kerbs');
    expect(before, isNotEmpty);
    for (var i = 0; i < 200; i++) {
      final s = a.reserveAhead(r.lanes.laneOf(0, 0), 10.0 + i, i);
      if (s >= 0) {
        a.occupy(s, i);
        a.release(s);
      }
      a.applyMasks(SiteTable(), r.lanes, mask);
      a.clearRelocations();
    }
    final after = <String, Object>{};
    a.collectBuffers(after, 'kerbs');
    for (final name in before.keys) {
      expect(identical(before[name], after[name]), isTrue,
          reason: '$name was reallocated');
    }
  });
}

/// The runs of arc over `0 .. length` where [blocked] holds, walked at a
/// centimetre: each is `(first blocked, last blocked)`.
List<(double, double)> _runs(bool Function(double) blocked, double length) {
  final out = <(double, double)>[];
  const step = 0.01;
  var lo = -1.0;
  var prev = -1.0;
  for (var s = 0.0; s <= length; s += step) {
    final at = (s * 100).round() / 100;
    if (blocked(at)) {
      if (lo < 0) lo = at;
      prev = at;
    } else if (lo >= 0) {
      out.add((lo, prev));
      lo = -1;
    }
  }
  if (lo >= 0) out.add((lo, prev));
  return out;
}
