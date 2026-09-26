// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A15 (docs/plans/site-access.md §7.9; agent-traffic.md §5.5, §17.2): the
/// lane-change property, extended with sites.
///
/// `lane_changes_only_at_nodes_test` pins the road half on the mover alone.
/// This is the same law over a whole colony with STRIP, LOOP and HOME plans
/// on it, where a vehicle may also leave the carriageway altogether:
///
/// - **a road element changes** only by handing over along the vehicle's own
///   route, through a connector — never sideways onto a sibling lane;
/// - **the road↔site change** is legal only with an access event logged in
///   that very sub-step, whose `(edge, T)` is the join's (within 1.5 m, or
///   11 m for a home back-out's EXIT) and whose lane is the one the car left
///   (ENTER) or joined (EXIT);
/// - **inside a site** the lane changes only along a §2.5 link, or not at
///   all while a stall manoeuvre runs — and a site sync may move a car to
///   another ROW, which is §7.6's snap and is allowed;
/// - **no vehicle is ever on two lists**: a car on a road element is on no
///   site lane, and a car on a site lane is on no road element.
library;

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/access_events.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/parked_cars.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import '../colony/site_access/site_plan_fixtures.dart';
import 'site_fixture.dart';
import 'traffic_fixture.dart';

void main() {
  // Enough demand to fill the roads and keep the lots busy.
  setUp(() => AgentTuning.commuteRatePerResident = 0.12);
  tearDown(AgentTuning.reset);

  test('500 agents, 2,000 sub-steps with STRIP and LOOP sites: every element '
      'change is a connector or an access event, and nothing is on two lists',
      () {
    // A 5 x 5 grid of streets, every free lot zoned and built: a colony big
    // enough to hold five hundred cars at once, with STRIP, LOOP and HOME
    // plans placed on lots of it (A15 "on the grid").
    final city = grid(5);
    zoneAll(city);
    buildAll(city);
    final a = agentsOn(city, settle: kSettled);
    final byLot = _place(city, const [
      SyntheticTemplate.strip,
      SyntheticTemplate.loop,
      SyntheticTemplate.home,
    ]);
    expect(byLot.length, 3, reason: 'a lot for each template');
    a.debugPlans = FixturePlanSource(city.roadGraph, byLot);

    // Three lots among hundreds are rarely drawn by the demand, so trips to
    // them are forced on a steady beat: what is under test is the kerb
    // crossing, not how often a job draw picks a site.
    final targets = byLot.keys.toList();
    final origins = [for (final id in targets) _neighbourOf(city, byLot, id)];
    final watch = _SiteWatch();
    final bad = <String>[];
    var peak = 0;
    for (var k = 0; k < 2000 && bad.length < 20; k++) {
      if (k % 4 == 0) {
        final n = k ~/ 4;
        final k2 = n % targets.length;
        a.forceTrip(origins[k2], targets[k2]);
      }
      // And one car sent back out of a stall now and again, so the EXIT half
      // of the law is under the same watch as the ENTER half.
      if (k % 50 == 25) _departOne(a);
      a.advance(kStepS);
      bad.addAll(watch.check(a));
      if (a.liveVehicles > peak) peak = a.liveVehicles;
    }

    // ignore: avoid_print
    print('A15: $peak agents at the peak, ${a.siteStats.enters} ENTERs, '
        '${a.siteStats.exits} EXITs, ${watch.handOvers} hand-overs, '
        '${watch.siteHops} site lane changes, '
        '${a.siteStats.parkedLot} parked in lots, '
        '${a.siteStats.parkedKerb} at kerbs');
    expect(bad, isEmpty);
    expect(peak, greaterThanOrEqualTo(500), reason: 'a colony under load');
    expect(a.siteStats.enters, greaterThan(20),
        reason: 'cars crossed the kerb often enough to prove something');
    expect(a.siteStats.exits, greaterThan(0));
    expect(watch.siteHops, greaterThan(20), reason: 'and drove the aisles');
    expect(watch.handOvers, greaterThan(1000));
    expect(a.accessEvents!.dropped, 0, reason: 'no event was ever lost');
  });
}

/// Sends the first car standing on a lot stall away again
/// (`CityAgents.debugDepart`).
void _departOne(CityAgents a) {
  final cars = a.parkedCars!;
  for (var i = 0; i < cars.pool.highWater; i++) {
    if (!cars.pool.isSlotLive(i)) continue;
    if (cars.where[i] != CarWhere.lot.index) continue;
    if (a.debugDepart(cars.pool.handleOf(i)) != SlotPool.none) return;
  }
}

/// A built lot near [id] in layout order — the same road, a few doors
/// down — so a forced trip to it is a short one.
String _neighbourOf(
    CitySim city, Map<String, SyntheticTemplate> byLot, String id) {
  final ids = [
    for (final p in city.layout.autoParcels)
      if (city.parcelBuildings.containsKey(p.id)) p.id,
  ];
  final at = ids.indexOf(id);
  for (var d = 1; d < ids.length; d++) {
    for (final k in [at - d, at + d]) {
      if (k < 0 || k >= ids.length) continue;
      if (byLot.containsKey(ids[k])) continue;
      return ids[k];
    }
  }
  throw StateError('no neighbour for $id');
}

/// The first built lot of [city] each of [want] can stand on: the fixtures
/// need room for their own geometry, and a template refused by one lot's
/// shape is simply tried on the next.
Map<String, SyntheticTemplate> _place(
    CitySim city, List<SyntheticTemplate> want) {
  final out = <String, SyntheticTemplate>{};
  final ids = [for (final p in city.layout.autoParcels) p.id];
  for (final t in want) {
    for (final id in ids) {
      if (out.containsKey(id)) continue;
      if (!city.parcelBuildings.containsKey(id)) continue;
      try {
        FixturePlanSource(city.roadGraph, {id: t});
      } catch (_) {
        continue;
      }
      out[id] = t;
      break;
    }
  }
  return out;
}

/// One vehicle's place, as the law is written over it.
typedef _Place = ({int elem, int cur, int row, int lane, int phase});

/// The §5.5 law, checked after every sub-step. See the library comment.
class _SiteWatch {
  final Map<int, _Place> _last = {};

  /// Road hand-overs and site lane changes seen.
  int handOvers = 0, siteHops = 0;

  List<String> check(CityAgents a) {
    final t = a.vehicles!;
    final cols = a.siteVehicles!;
    final sites = a.sites!;
    final lg = a.laneGraph!;
    final log = a.accessEvents!;
    final nL = lg.laneCount;
    final bad = <String>[];
    final now = <int, _Place>{};

    // This sub-step's events, by handle: at most one per vehicle (a throat
    // is 7 m, V5), which is itself worth saying out loud.
    final events = <int, int>{};
    for (var e = 0; e < log.count; e++) {
      final h = log.handle[e];
      if (events.containsKey(h)) {
        bad.add('handle $h crossed the kerb twice in one sub-step');
      }
      events[h] = e;
    }

    for (var sl = 0; sl < t.highWater; sl++) {
      if (!t.isSlotLive(sl)) continue;
      final h = t.handleOf(sl);
      final place = (
        elem: t.elem[sl],
        cur: t.routeCur[sl],
        row: cols.row[sl],
        lane: cols.lane[sl],
        phase: cols.phase[sl],
      );
      now[h] = place;

      // Never both: a car on a road element is on no site lane.
      if (place.elem >= 0 && place.lane >= 0) {
        bad.add('handle $h is on road element ${place.elem} AND site lane '
            '${place.lane} of row ${place.row}');
      }

      final was = _last[h];
      if (was == null) continue;
      final e = events[h];
      if (was.elem >= 0 && place.elem < 0) {
        // Off the road and into a site: an ENTER at that join.
        bad.addAll(_enter(a, lg, sites, log, e, h, was.elem));
        continue;
      }
      if (was.elem < 0 && place.elem >= 0) {
        // Out of a site and onto the road: an EXIT at that join.
        bad.addAll(_exit(a, lg, sites, log, e, h, place.elem));
        continue;
      }
      if (place.elem < 0) {
        bad.addAll(_inside(sites, was, place, h));
        continue;
      }
      if (was.elem == place.elem) continue;
      handOvers++;
      if (was.elem < nL &&
          place.elem < nL &&
          lg.laneEdge[was.elem] == lg.laneEdge[place.elem]) {
        bad.add('handle $h moved sideways from lane ${was.elem} to '
            '${place.elem}');
        continue;
      }
      if (!_onRoute(t, sl, lg, was.elem, was.cur, place.elem, place.cur)) {
        bad.add('handle $h jumped from element ${was.elem} (route edge '
            '${was.cur}) to ${place.elem} (${place.cur}) off its route');
      }
    }

    // Every car on a site list is off the road, and listed where it says.
    for (var el = 0; el < sites.elemHead.length; el++) {
      for (var sl = sites.elemHead[el]; sl >= 0; sl = cols.sNext[sl]) {
        if (!t.isSlotLive(sl)) {
          bad.add('dead slot $sl on site element $el');
          break;
        }
        if (t.elem[sl] >= 0) {
          bad.add('slot $sl is on site element $el and road element '
              '${t.elem[sl]}');
        }
        final row = sites.elemRow[el];
        if (cols.row[sl] != row || sites.elemBase[row] + cols.lane[sl] != el) {
          bad.add('slot $sl listed on site element $el, says row '
              '${cols.row[sl]} lane ${cols.lane[sl]}');
          break;
        }
      }
    }

    _last
      ..clear()
      ..addAll(now);
    return bad;
  }

  /// The ENTER rule (§5.5): logged this sub-step, at that join's `(edge, T)`
  /// within 1.5 m, leaving the lane the car was locked into.
  List<String> _enter(CityAgents a, LaneGraph lg, dynamic sites,
      AccessEventLog log, int? e, int h, int wasElem) {
    if (e == null) return ['handle $h left the road with no access event'];
    if (log.kind[e] != AccessEventKind.enter.index) {
      return ['handle $h left the road on a ${log.kind[e]} event'];
    }
    if (log.lane[e] != wasElem) {
      return ['handle $h entered from lane ${log.lane[e]}, was on $wasElem'];
    }
    return _atJoin(lg, sites, log, e, h, 1.5);
  }

  /// The EXIT rule: logged this sub-step, into the lane the car is now in,
  /// at that join's `(edge, T)` — within 1.5 m, or 11 m for a back-out.
  List<String> _exit(CityAgents a, LaneGraph lg, dynamic sites,
      AccessEventLog log, int? e, int h, int elem) {
    if (e == null) return ['handle $h joined the road with no access event'];
    if (log.kind[e] == AccessEventKind.enter.index) {
      return ['handle $h joined the road on an ENTER'];
    }
    if (log.lane[e] != elem) {
      return ['handle $h exited into lane ${log.lane[e]}, is on $elem'];
    }
    final back = log.kind[e] == AccessEventKind.backOutExit.index;
    return _atJoin(lg, sites, log, e, h, back ? 11.0 : 1.5);
  }

  /// Whether event [e] was logged at its own join's `(edge, T)`, within
  /// [tolM].
  List<String> _atJoin(LaneGraph lg, dynamic sites, AccessEventLog log, int e,
      int h, double tolM) {
    final row = log.row[e], join = log.join[e];
    final plan = sites.plan[row];
    if (plan == null) return ['handle $h crossed at row $row, which has none'];
    final at = lg.travelArc(log.edge[e], plan.joinRoadS(join) as double);
    final off = (log.t[e] - at).abs();
    if (off > tolM) {
      return ['handle $h crossed ${off.toStringAsFixed(2)} m from join $join '
          'of row $row (allowed $tolM)'];
    }
    return const [];
  }

  /// Inside a site: the lane changed along a §2.5 link, or the car moved to
  /// another row, which is §7.6's snap.
  List<String> _inside(dynamic sites, _Place was, _Place place, int h) {
    if (was.lane == place.lane && was.row == place.row) {
      return const [];
    }
    if (was.row != place.row) return const [];
    if (was.lane < 0 || place.lane < 0) return const [];
    siteHops++;
    final g = sites.lanes[place.row];
    if (g == null) return const [];
    for (var i = g.linkStart[was.lane] as int;
        i < (g.linkStart[was.lane + 1] as int);
        i++) {
      if (g.linkTo[i] == place.lane) return const [];
    }
    return ['handle $h moved from site lane ${was.lane} to ${place.lane} of '
        'row ${place.row} along no link'];
  }

  /// Whether [to] is where [from] leads on the vehicle's own route, within
  /// the hand-overs one sub-step allows.
  bool _onRoute(dynamic t, int sl, LaneGraph lg, int from, int fromCur, int to,
      int toCur) {
    final nL = lg.laneCount;
    var x = from, i = fromCur;
    for (var k = 0; k < AgentTuning.maxHandOversPerStep; k++) {
      if (x < nL) {
        if (i + 1 >= (t.routeLen[sl] as int)) return false;
        i++;
        x = nL + (t.connectorOfRouteEdge(sl, i) as int);
      } else {
        x = lg.conToLane[x - nL];
      }
      if (x == to && i == toCur) return true;
    }
    return false;
  }
}
