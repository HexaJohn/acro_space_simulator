// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_join.dart';
import 'package:flutter_test/flutter_test.dart';

/// Join slot placement (docs/plans/site-access.md §3.2, §3.7a, slice R1).
void main() {
  /// Slot k of lot [id]: road id, arc, flags, crossed lot ids.
  ({String road, double s, int flags, int dirs, bool right, List<String> cross})
      slot(RoadGraph g, String id, [int k = 0]) {
    final i = g.lotNoOf(id)!;
    final j = g.lotJoinStart[i] + k;
    expect(j, lessThan(g.lotJoinStart[i + 1]), reason: '$id has slot $k');
    return (
      road: g.roads[g.pieceRoad[g.joinPiece[j]]].id,
      s: g.joinS[j],
      flags: g.joinFlags[j],
      dirs: g.joinDirs[j],
      right: g.joinRight[j] == 1,
      cross: [
        for (var c = g.joinCrossStart[j]; c < g.joinCrossStart[j + 1]; c++)
          g.lotIds[g.joinCrossLot[c]]
      ],
    );
  }

  int slotCount(RoadGraph g, String id) {
    final i = g.lotNoOf(id)!;
    return g.lotJoinStart[i + 1] - g.lotJoinStart[i];
  }

  /// A layout of raw roads (no splitting), lots cut.
  CityLayout layoutOf(List<RoadSpline> roads) {
    final layout = CityLayout();
    for (final r in roads) {
      layout.addRoad(r);
    }
    return layout;
  }

  group('narrow lots join at their drive end', () {
    test('4.5 m in from the lot line, at the end away from the nearer node',
        () {
      // A street 0..400 m east, dead ends both ends: lots every 24 m from
      // 12 m. The lot 84..108 is nearer the west end: its slot is at 103.5.
      // The lot 276..300 is nearer the east end: 280.5.
      final g = RoadGraph.of(layoutOf(const [
        RoadSpline(id: 'r0', controls: [Vec2(0, 0), Vec2(400, 0)]),
      ]));
      for (final side in ['l', 'r']) {
        final west = slot(g, 'lot-r0-${side}3');
        expect(west.s, 103.5);
        expect(west.flags, kJoinCut);
        final east = slot(g, 'lot-r0-${side}11');
        expect(east.s, 280.5);
        expect(east.flags, kJoinCut);
        // Room: the nearer window end, the dead end's 12 + 6 m.
        final i = g.lotNoOf('lot-r0-${side}3')!;
        expect(g.joinRoomM[g.lotJoinStart[i]], closeTo(103.5 - 18, 1e-4));
      }
    });

    test('a corner projected a hair off its metre is still on it', () {
      // 492 / 600 × 600 is 491.99999999999994: the lot 492..516 is at its
      // drive end 496.5 all the same, not pushed to its other end.
      final g = RoadGraph.of(layoutOf(const [
        RoadSpline(id: 'r0', controls: [Vec2(0, 0), Vec2(600, 0)]),
      ]));
      for (final side in ['l', 'r']) {
        expect(slot(g, 'lot-r0-${side}20').s, 496.5);
        expect(slot(g, 'lot-r0-${side}20').flags, kJoinCut);
        expect(slot(g, 'lot-r0-${side}22').s, 544.5);
      }
    });

    test('equidistant from both nodes within 2 m: the larger-s end', () {
      // 432 m: lot 204..228 is centred at 216, the middle.
      final g = RoadGraph.of(layoutOf(const [
        RoadSpline(id: 'r0', controls: [Vec2(0, 0), Vec2(432, 0)]),
      ]));
      expect(slot(g, 'lot-r0-l8').s, 223.5);
      expect(slot(g, 'lot-r0-r8').s, 223.5);
      // One lot further west is nearer the west end, and joins at its east
      // end all the same; one further east joins at its west end.
      expect(slot(g, 'lot-r0-l7').s, 199.5);
      expect(slot(g, 'lot-r0-l9').s, 232.5);
    });

    test('a lot pushed off its drive end takes the other end, else the '
        'nearest room, flagged clamped', () {
      // A bridge at 109..111 keeps cuts off [106, 114]. The lot 84..108 wants
      // its east end, 103.5, whose cut would reach 107.5: it takes its west
      // end, 88.5.
      final g = RoadGraph.of(layoutOf(const [
        RoadSpline(
            id: 'r0',
            controls: [Vec2(0, 0), Vec2(400, 0)],
            bridges: [(109, 111)]),
      ]));
      for (final side in ['l', 'r']) {
        final pushed = slot(g, 'lot-r0-${side}3');
        expect(pushed.s, 88.5);
        expect(pushed.flags, kJoinCut | kJoinClamped);
      }
      // On a 52 m street the one lot (12..36) wants 31.5 and has 16.5 at its
      // other end; cuts fit only in [22, 30]: the nearest room, 30.
      final short = RoadGraph.of(layoutOf(const [
        RoadSpline(id: 's', controls: [Vec2(0, 0), Vec2(52, 0)]),
      ]));
      for (final side in ['l', 'r']) {
        final only = slot(short, 'lot-s-${side}0');
        expect(only.s, 30);
        expect(only.flags, kJoinCut | kJoinClamped);
      }
    });
  });

  group('directions', () {
    test('a two-lane street both ways; a one-way street its way; a four-lane '
        'road its own side', () {
      final g = RoadGraph.of(layoutOf(const [
        RoadSpline(id: 'st', controls: [Vec2(0, 0), Vec2(400, 0)]),
        RoadSpline(
            id: 'ow',
            controls: [Vec2(0, 1000), Vec2(400, 1000)],
            roadClass: RoadClass.streetOneWay),
        RoadSpline(
            id: 'rev',
            controls: [Vec2(0, 2000), Vec2(400, 2000)],
            roadClass: RoadClass.streetOneWay,
            reversed: true),
        RoadSpline(
            id: 'av',
            controls: [Vec2(0, 3000), Vec2(400, 3000)],
            roadClass: RoadClass.avenue),
      ]));
      const both = RoadGraph.forwardBit | RoadGraph.backwardBit;
      for (final side in ['l', 'r']) {
        expect(slot(g, 'lot-st-${side}3').dirs, both);
        expect(slot(g, 'lot-ow-${side}3').dirs, RoadGraph.forwardBit);
        expect(slot(g, 'lot-rev-${side}3').dirs, RoadGraph.backwardBit);
      }
      // Drawn east: the 'r' lots (named the other way round) lie north, on
      // the left of the polyline; the side comes from geometry.
      final north = slot(g, 'lot-av-r3'), south = slot(g, 'lot-av-l3');
      expect(north.right, isFalse);
      expect(north.dirs, RoadGraph.backwardBit);
      expect(south.right, isTrue);
      expect(south.dirs, RoadGraph.forwardBit);
    });
  });

  group('slots 1 and 2', () {
    test('a corner lot is offered its side street, on request', () {
      final layout = CityLayout();
      layout.commitRoad(controls: const [Vec2(0, -300), Vec2(0, 300)]);
      layout.commitRoad(controls: const [Vec2(-300, 0), Vec2(300, 0)]);
      final g = RoadGraph.of(layout);
      var corners = 0;
      for (final p in layout.autoParcels) {
        final i = g.lotNoOf(p.id)!;
        if (p.sideStreet == null) {
          expect(g.sideStreetJoinOf(i), isNull, reason: p.id);
          continue;
        }
        corners++;
        final s0 = slot(g, p.id);
        expect(s0.road, p.roadId, reason: '${p.id}: its own road first');
        expect(s0.flags & kJoinSideStreet, 0);
        // Not packed among the lot's slots: a sprawl's corner lots would pay
        // for it on every build (R-B1).
        expect(slotCount(g, p.id), 1, reason: p.id);
        final s2 = g.sideStreetJoinOf(i)!;
        expect(identical(g.sideStreetJoinOf(i), s2), isTrue,
            reason: '${p.id}: placed once, then kept');
        expect(s2.flags & kJoinSideStreet, kJoinSideStreet, reason: p.id);
        expect(s2.flags & kJoinCut, kJoinCut, reason: p.id);
        expect(g.roads[g.pieceRoad[s2.piece]].id, isNot(p.roadId),
            reason: p.id);
        expect(s2.dirs, joinDirsFor(g.roads[g.pieceRoad[s2.piece]], s2.right),
            reason: p.id);
        expect(g.kerbWindows.roomAt(s2.piece, s2.s), closeTo(s2.roomM, 1e-4),
            reason: p.id);
      }
      expect(corners, greaterThan(0), reason: 'the plat marks corner lots');
    });

    test('a hand-drawn lot no corner or edge midpoint of which is within '
        'reach keeps no slot, though a road faces an edge', () {
      // A 400 m site; a street dead-ends 50 m short of its south edge at
      // e = 100. Nearest corner (0, 0): 112 m; nearest edge midpoint
      // (200, 0): 112 m; the reach is 90 + 4. Today's rule finds no road,
      // so the lot is without access, as it was.
      final layout = layoutOf(const [
        RoadSpline(id: 'r0', controls: [Vec2(100, -50), Vec2(100, -600)]),
      ]);
      final site = layout.addManualParcel(const [
        Vec2(0, 0), Vec2(400, 0), Vec2(400, 400), Vec2(0, 400),
      ])!;
      final g = RoadGraph.of(layout);
      final i = g.lotNoOf(site.id)!;
      expect(slotCount(g, site.id), 0);
      expect(g.lotPiece[i], -1);
      expect(g.accessOf(site.id), isNull);
      // The same street ending 20 m short of the corner (0, 0) (22 m off):
      // the lot is reached, and its slot stands.
      final near = layoutOf(const [
        RoadSpline(id: 'r0', controls: [Vec2(10, -20), Vec2(10, -600)]),
      ]);
      final nearSite = near.addManualParcel(const [
        Vec2(0, 0), Vec2(400, 0), Vec2(400, 400), Vec2(0, 400),
      ])!;
      final gn = RoadGraph.of(near);
      expect(slotCount(gn, nearSite.id), greaterThan(0),
          reason: 'corner (0, 0) is 22 m off');
      expect(gn.accessOf(nearSite.id), isNotNull);
    });

    test('a wide manual lot is offered the far end of its span', () {
      final layout = layoutOf(const [
        RoadSpline(id: 'r0', controls: [Vec2(0, 0), Vec2(0, 600)]),
      ]);
      final lot = layout.addManualParcel(
        const [Vec2(7, 100), Vec2(87, 100), Vec2(87, 300), Vec2(7, 300)],
        frontage: (Vec2(7, 100), Vec2(7, 300)),
      )!;
      final g = RoadGraph.of(layout);
      // Not set back: its frontage is the pavement line, 3 m behind the kerb.
      final s0 = slot(g, lot.id);
      expect(s0.s, 200, reason: 'the frontage midpoint');
      expect(s0.flags, kJoinCut);
      expect(slotCount(g, lot.id), 2);
      final s1 = slot(g, lot.id, 1);
      expect(s1.flags, kJoinCut);
      // The span [100 + 4.5 + 5, 300 − 9.5]: 200 lies 90.5 from both ends,
      // and the far end of a tie is the high one.
      expect(s1.s, 290.5);
      expect((s1.s - s0.s).abs(), greaterThanOrEqualTo(kSecondSlotMinGapM));
    });
  });

  group('set-back lots: the access corridor (§3.7a)', () {
    /// A street 0..600 m north, and a 100 × 200 m site 56 m back from its
    /// east kerb, fronting it; [extra] roads laid first.
    (CityLayout, String) setBack({List<RoadSpline> extra = const []}) {
      final layout = layoutOf([
        const RoadSpline(id: 'r0', controls: [Vec2(0, 0), Vec2(0, 600)]),
        ...extra,
      ]);
      final site = layout.addManualParcel(
        const [Vec2(60, 200), Vec2(160, 200), Vec2(160, 400), Vec2(60, 400)],
        frontage: (Vec2(60, 200), Vec2(60, 400)),
      )!;
      return (layout, site.id);
    }

    test('a centred single easement lot beats an off-centre one', () {
      final (layout, id) = setBack();
      final g = RoadGraph.of(layout);
      final s0 = slot(g, id);
      // The target is the midpoint, 300, on the lot boundary 300 (lots every
      // 24 m from 12): 300 ± 4.5 crosses two lots; the lot 276..300 and the
      // lot 300..324 centre at 288 and 312, equidistant: the smaller s.
      expect(s0.s, 288);
      expect(s0.flags, kJoinCut | kJoinClamped | kJoinEasement);
      expect(s0.cross, ['lot-r0-l11']);
    });

    test('a manual parcel across every corridor blocks the site', () {
      final layout = layoutOf(const [
        RoadSpline(id: 'r0', controls: [Vec2(0, 0), Vec2(0, 600)]),
      ]);
      expect(
          layout.addManualParcel(const [
            Vec2(20, 20), Vec2(50, 20), Vec2(50, 580), Vec2(20, 580),
          ]),
          isNotNull);
      final site = layout.addManualParcel(
        const [Vec2(60, 200), Vec2(160, 200), Vec2(160, 400), Vec2(60, 400)],
        frontage: (Vec2(60, 200), Vec2(60, 400)),
      )!;
      final g = RoadGraph.of(layout);
      final s0 = slot(g, site.id);
      expect(s0.flags & kJoinCorridorBlocked, kJoinCorridorBlocked);
      expect(s0.flags & kJoinEasement, 0);
      expect(s0.cross, isEmpty);
      expect(s0.s, 300, reason: 'at the clamped target');
    });

    test('a road at grade across the corridor blocks it; one in the air, on '
        'its piers or in its tunnel does not', () {
      RoadSpline across(String id, RoadClass c, {RoadDeck? deck}) =>
          RoadSpline(
              id: id,
              controls: const [Vec2(30, -100), Vec2(30, 700)],
              roadClass: c,
              deck: deck);
      final atGrade = setBack(extra: [across('rail', RoadClass.rail)]);
      expect(
          slot(RoadGraph.of(atGrade.$1), atGrade.$2).flags &
              kJoinCorridorBlocked,
          kJoinCorridorBlocked);
      for (final (name, road) in [
        ('elevated', across('el', RoadClass.elevated)),
        (
          'on piers',
          across('piers', RoadClass.rail,
              deck: const RoadDeck(startM: 8, endM: 8, structures: [(0, 800)]))
        ),
        (
          'in a tunnel',
          across('tube', RoadClass.rail,
              deck: const RoadDeck(startM: -8, endM: -8, tunnels: [(0, 800)]))
        ),
      ]) {
        final (layout, id) = setBack(extra: [road]);
        final s0 = slot(RoadGraph.of(layout), id);
        expect(s0.flags & kJoinCorridorBlocked, 0, reason: name);
        expect(s0.road, 'r0', reason: name);
      }
    });

    test('a site past a road end doglegs (off frontage); a clamped one does '
        'not', () {
      final layout = layoutOf(const [
        RoadSpline(id: 'r0', controls: [Vec2(0, 0), Vec2(0, 300)]),
      ]);
      final site = layout.addManualParcel(
        const [Vec2(20, 350), Vec2(120, 350), Vec2(120, 450), Vec2(20, 450)],
        frontage: (Vec2(20, 350), Vec2(20, 450)),
      )!;
      final g = RoadGraph.of(layout);
      final s0 = slot(g, site.id);
      expect(s0.road, 'r0');
      expect(s0.flags & kJoinOffFrontage, kJoinOffFrontage);
      expect(s0.flags & kJoinCut, kJoinCut);
      // The nearest window point to the road end: [18, 288] less 4.5.
      expect(s0.s, lessThanOrEqualTo(277.5));
      final g2 = RoadGraph.of(setBack().$1);
      final clamped = slot(g2, setBack().$2);
      expect(clamped.flags & kJoinOffFrontage, 0);
    });
  });

  test('slots are quantised to 0.25 m', () {
    final layout = CityLayout();
    layout.commitRoad(
        controls: const [Vec2(0, 0), Vec2(173.3, 41.7), Vec2(401.9, 13.1)]);
    final g = RoadGraph.of(layout);
    var cuts = 0;
    for (var j = 0; j < g.joinCount; j++) {
      if (g.joinFlags[j] & kJoinCut == 0) continue;
      cuts++;
      expect((g.joinS[j] * 4) % 1, 0, reason: 'slot $j at ${g.joinS[j]}');
    }
    expect(cuts, greaterThan(10));
  });
}
