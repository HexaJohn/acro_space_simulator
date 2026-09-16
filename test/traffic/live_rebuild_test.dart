// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_table.dart';
import 'package:flutter_test/flutter_test.dart';

import 'movement_fixture.dart';
import 'routing_fixture.dart';
import 'traffic_fixture.dart';

/// A road drawn across a town whose cars are on the move (docs/plans/
/// agent-traffic.md §3.8, §3.9, §13.2): the lane graph is rebuilt under
/// them, and every vehicle is carried onto the new graph where it was.
///
/// - A car on a lane stays on the same road (or the piece of it the split
///   cut), in the same direction and lane, at the same place — or, if it
///   stood where the new street's junction box now is, on the connector
///   straight through that box, on its road's own movement, still where it
///   stood.
/// - A car crossing a junction stays on that movement, as far through it
///   as it was, on the new graph's connector for it.
/// - Every element's list is relinked in order ([VehicleTable.relinkAll]),
///   and no car had to be moved off another to get there.
/// - A frame is published on the new ids before any sub-step runs.
///
/// Then they all drive on, and none is re-planned or taken off for it. A
/// trip whose lot the new street re-cut may find its building's access
/// moved on from where its route stops, and drive on to it by an appended
/// leg (D36's `siteRetarget`) — never a re-plan.
void main() {
  setUp(() => AgentTuning.commuteRatePerResident = 0.002);
  tearDown(AgentTuning.reset);

  test('rebuilt under moving traffic: every car remapped in place, those '
      'in a junction still on their movement, every list relinked', () {
    final a = agentsOn(town());
    runAgents(a, 240);
    final t = a.vehicles!;
    final lg0 = a.laneGraph!;
    // The north arm, which the new street will cut in two.
    final north = lg0.graph.roads[
            lg0.edgeRoad[edgeNear(lg0, const Vec2(0, 150), const Vec2(0, 1))]]
        .id;

    // Run on until two cars are crossing junctions — one of them into or
    // out of the north arm — and one is on the arm itself.
    var ready = false;
    for (var i = 0; i < 6000 && !ready; i++) {
      a.advance(kStepS);
      var crossing = 0;
      var intoNorth = false, onNorth = false;
      for (var sl = 0; sl < t.highWater; sl++) {
        // A car inside a site is on no element of the road graph at all
        // (T4a, D49): it holds no place a rebuild could carry.
        if (!t.isSlotLive(sl) || t.elem[sl] < 0) continue;
        final p = _Place.of(lg0, t, sl);
        if (p.onConnector) {
          crossing++;
          if (_descends(p.road, north) || _descends(p.toRoad, north)) {
            intoNorth = true;
          }
        } else if (_descends(p.road, north)) {
          onNorth = true;
        }
      }
      ready = crossing >= 2 && intoNorth && onNorth;
    }
    expect(ready, isTrue, reason: 'traffic through the north arm');

    final before = <int, _Place>{
      for (var sl = 0; sl < t.highWater; sl++)
        if (t.isSlotLive(sl) && t.elem[sl] >= 0)
          t.handleOf(sl): _Place.of(lg0, t, sl),
    };
    final rev = a.graphRev;
    commit(a.city, const FixtureRoad([Vec2(-250, 150), Vec2(250, 150)]));
    a.advance(0); // the poll alone: rebuilt and remapped, no sub-step run

    final lg = a.laneGraph!;
    expect(a.graphRev, rev + 1);
    expect(identical(lg, lg0), isFalse);
    expect(a.stats.replans, 0, reason: 'a crossing street makes no route '
        'impossible');
    expect(a.stats.despawnEdit, 0);
    expect(occupancyErrors(t), isEmpty, reason: 'every list relinked');
    expect(a.stats.remapNudges, 0, reason: 'every car kept its own place');
    var intoBox = 0;
    for (final e in before.entries) {
      final h = e.key;
      expect(t.isLive(h), isTrue, reason: 'handle $h');
      final now = _Place.of(lg, t, h & 0xFFFFF);
      if (!e.value.onConnector && now.onConnector) intoBox++;
      e.value.expectCarriedTo(now, 'handle $h');
    }
    final f = a.frame;
    expect(f.graphRev, a.graphRev, reason: 'a frame on the new ids at once');
    for (var sl = 0; sl < t.highWater; sl++) {
      if (!t.isSlotLive(sl)) continue;
      expect(f.elem[sl], t.elem[sl]);
      expect(f.s[sl], t.s[sl]);
    }

    // And on they drive: every one of them off the road by arriving. The
    // town is saturated by then — its spawn queue full — and the new street
    // re-hangs some of the starter kit's hand-drawn lots on other roads
    // (their nearest-road rule sees the split pieces afresh), so trips to
    // them drive on round the block by an appended leg: half an hour of
    // agent time, not a quarter.
    final stuck = a.stats.despawnStuck + a.stats.despawnWedge;
    for (var i = 0; i < 3600 && before.keys.any(t.isLive); i++) {
      a.advance(0.5);
    }
    expect(before.keys.where(t.isLive), isEmpty, reason: 'all arrived');
    expect(a.stats.despawnEdit, 0);
    expect(a.stats.replans, 0, reason: 'an appended leg is not a re-plan');
    expect(a.stats.remapNudges, 0);
    expect(a.stats.despawnStuck + a.stats.despawnWedge, stuck);
    // ignore: avoid_print
    print('live rebuild: $intoBox of ${before.length} cars carried into the '
        'new box, ${a.stats.appendedLegs} legs appended, '
        '${a.stats.remapNudges} nudged');
  });
}

/// Whether road [id] is [root] or a piece a split cut from it.
bool _descends(String id, String root) =>
    id == root || id.startsWith('${root}x');

/// Where a vehicle is, in terms two builds of one network share: on a lane
/// by road, direction, lane index and place; on a connector by the lane it
/// left and the lane it is taking, the node it crosses and how far through.
class _Place {
  _Place._(this.onConnector, this.road, this.forward, this.lane, this.toRoad,
      this.toForward, this.toLane, this.e, this.n, this.s, this.len);

  factory _Place.of(LaneGraph lg, VehicleTable t, int sl) {
    final el = t.elem[sl];
    final s = t.s[sl].toDouble();
    final at = elementPoint(lg, el, s);
    if (el < lg.laneCount) {
      final e = lg.laneEdge[el];
      return _Place._(false, _roadOf(lg, e), lg.edgeForward[e] == 1,
          lg.laneIdx[el], '', false, -1, at.e, at.n, s, 0);
    }
    final c = el - lg.laneCount;
    final from = lg.conFromLane[c], to = lg.conToLane[c];
    return _Place._(
        true,
        _roadOf(lg, lg.laneEdge[from]),
        lg.edgeForward[lg.laneEdge[from]] == 1,
        lg.laneIdx[from],
        _roadOf(lg, lg.laneEdge[to]),
        lg.edgeForward[lg.laneEdge[to]] == 1,
        lg.laneIdx[to],
        at.e,
        at.n,
        s,
        lg.conLen[c].toDouble());
  }

  final bool onConnector;
  final String road;
  final bool forward;
  final int lane;
  final String toRoad;
  final bool toForward;
  final int toLane;

  /// Where its front is, on its lane or its connector's path, colony
  /// metres ([elementPoint]).
  final double e, n;

  /// Metres along the element, and a connector's length.
  final double s, len;

  static String _roadOf(LaneGraph lg, int e) =>
      lg.graph.roads[lg.edgeRoad[e]].id;

  /// Checks [now], this vehicle on the rebuilt graph, is where it was.
  void expectCarriedTo(_Place now, String who) {
    final moved = math.sqrt(
        (now.e - e) * (now.e - e) + (now.n - n) * (now.n - n));
    if (!onConnector && now.onConnector) {
      // It stood in the new junction's box: on the movement straight
      // through it from one piece of its road to the next, in its own lane
      // on one side of the node or the other.
      expect(_descends(now.road, road) && _descends(now.toRoad, road), isTrue,
          reason: '$who: ${now.road} → ${now.toRoad} is not along $road');
      expect(now.forward, forward, reason: who);
      expect(now.toForward, forward, reason: who);
      expect(now.lane == lane || now.toLane == lane, isTrue,
          reason: '$who: lane ${now.lane} → ${now.toLane}, not $lane');
      expect(moved, lessThan(1), reason: '$who: moved $moved m into the box');
      return;
    }
    expect(now.onConnector, onConnector, reason: '$who: element kind');
    expect(_descends(now.road, road), isTrue,
        reason: '$who: ${now.road} is not $road or a piece of it');
    expect(now.forward, forward, reason: who);
    expect(now.lane, lane, reason: '$who: lane');
    if (!onConnector) {
      expect(moved, lessThan(0.5), reason: '$who: moved $moved m on $road');
      return;
    }
    expect(_descends(now.toRoad, toRoad), isTrue,
        reason: '$who: into ${now.toRoad}, not $toRoad');
    expect(now.toForward, toForward, reason: who);
    expect(now.toLane, toLane, reason: '$who: lane taken');
    expect(moved, lessThan(1), reason: '$who: moved $moved m on its movement');
    expect(now.s, closeTo(math.min(s, now.len - 0.01), 1e-3),
        reason: '$who: as far through the junction');
  }
}
