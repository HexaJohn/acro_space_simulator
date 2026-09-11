// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_table.dart';
import 'package:flutter_test/flutter_test.dart';

import 'routing_fixture.dart';
import 'traffic_fixture.dart';

/// §17.3 #23, `fixed_start_feasibility`: the avenue example of §3.5, run
/// live by a colony's agents (docs/plans/agent-traffic.md §3.5, §3.9, §4.5,
/// D34).
///
/// A car drives east along an avenue in its kerb lane, to a lot at the far
/// end. The stretch of avenue ahead of it is taken up. Its route is now
/// impossible, so it re-plans from where it is, held in lane 0. Lane 0
/// turns only right or goes straight on, and every way that is left needs
/// a left somewhere. An edge plan could ask lane 0 for that left; the
/// (edge, lane) search cannot, because it moves only along real connectors.
/// It shifts into lane 1 at a junction and turns from there, or turns right
/// and goes round a block. Whichever it takes, the route can be driven, it
/// starts in the lane the car is in, and the car arrives.
void main() {
  setUp(() => AgentTuning.commuteRatePerResident = 0);
  tearDown(AgentTuning.reset);

  test('held in lane 0 by a failed remap, it re-plans to a drivable route '
      'and arrives', () {
    final city = foundFlat(roads: [
      for (var i = 0; i < 4; i++)
        FixtureRoad([Vec2(i * 200.0, -200), Vec2(i * 200.0, 200)]),
      const FixtureRoad([Vec2(-200, 0), Vec2(800, 0)],
          roadClass: RoadClass.avenue),
      // Along the streets' north ends: the way round once the avenue is
      // cut.
      const FixtureRoad([Vec2(0, 200), Vec2(600, 200)]),
    ]);
    zoneAll(city, const [ParcelUse.residential]);
    buildAll(city);
    final a = agentsOn(city);
    final trip = forceTrip(a, lotNearest(city, const Vec2(-100, -25)).id,
        lotNearest(city, const Vec2(700, -25)).id);
    final lg0 = a.laneGraph!;
    final second = _piece(lg0, 100), fourth = _piece(lg0, 500);

    // On the avenue's second piece, in the kerb lane it will keep to the
    // end: a kerb arrival, and nothing to turn for on the way.
    var h = -1;
    for (var i = 0; i < 1200; i++) {
      a.advance(kStepS);
      h = vehicleOfTrip(a, trip);
      if (h >= 0 && roadOf(a, h) == second) break;
    }
    expect(h, greaterThanOrEqualTo(0), reason: 'the car pulled out');
    expect(roadOf(a, h), second);
    final planned = routeOf(a, h);
    expect(planned.every((w) => w.endsWith('+0')), isTrue,
        reason: 'east along the kerb lane to the end: $planned');
    expect(planned.any((w) => w.startsWith(fourth)), isTrue);

    // The fourth piece is taken up: the only road east of x = 400.
    city.layout.removeRoad(fourth, regenerateLots: false);
    a.advance(kStepS);
    expect(a.stats.replans, 1, reason: 'its route is impossible');
    expect(a.stats.despawnEdit, 0, reason: 'its own road is still there');
    final t = a.vehicles!;
    final sl = h & 0xFFFFF;
    expect(t.isLive(h), isTrue);
    expect(t.state[sl], VehicleState.driving.index,
        reason: 'the re-plan came back within the sub-step');

    final lg = a.laneGraph!;
    final route = [
      for (var i = 0; i < t.routeLen[sl]; i++) t.arena.data[t.routeOff[sl] + i],
    ];
    expectDrivable(lg, route);
    expect(route.first, t.elem[sl], reason: 'from the lane it is in');
    expect(lg.laneIdx[route.first], 0, reason: 'held in the kerb lane');
    expect(lg.graph.roads[lg.edgeRoad[lg.laneEdge[route.first]]].id, second);
    final words = routeOf(a, h);
    expect(words.any((w) => w.startsWith(fourth)), isFalse);
    // ignore: avoid_print
    print('fixed-start re-plan from $second lane 0: $words');

    final arrived = a.stats.arrived;
    for (var i = 0; i < 2400 && t.isLive(h); i++) {
      a.advance(0.5);
    }
    expect(t.isLive(h), isFalse);
    expect(a.stats.arrived, arrived + 1, reason: 'it arrived');
    expect(a.stats.replans, 1, reason: 'and never re-planned again');
    expect(a.stats.despawnStuck + a.stats.despawnWedge + a.stats.despawnEdit,
        0);
  });
}

/// The id of the avenue piece running east past x = [x].
String _piece(LaneGraph lg, double x) =>
    lg.graph.roads[lg.edgeRoad[edgeNear(lg, Vec2(x, 0), const Vec2(1, 0))]]
        .id;
