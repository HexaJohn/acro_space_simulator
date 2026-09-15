// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_noise.dart';
import 'package:acro_space_simulator/domain/colony/city/road_traffic_model.dart'
    show CityRoadTraffic, TrafficTuning;
import 'package:acro_space_simulator/domain/colony/city/traffic_readout.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_traffic_readout.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// The traffic readout's contract (docs/plans/agent-traffic.md §12.3, D46,
/// D47; §17.1 traffic_readout_test): before a picture it punishes nothing;
/// pictures come every congestion epoch and never go back, not even across
/// the colony's switch to the agents and back; the routes through a road
/// are the locked routes of the vehicles driving it; switched off, every
/// answer is the routed model's; and live (slice 2), reach is the agents'
/// own and noise, land value and the tax factor are the routed model's
/// formulas over the loads the agents measured piece by piece, changing
/// only when the pass count does.
void main() {
  setUp(() => AgentTuning.commuteRatePerResident = 0.004);
  tearDown(AgentTuning.reset);

  test('before the first picture the readout punishes nothing', () {
    final city = town();
    final a = agentsOn(city)..advance(0.02);
    final r = a.readout;
    expect(r.hasRun, isFalse);
    expect(r.passes, city.roadTraffic.passes,
        reason: 'no picture of ours yet: the routed count the colony '
            'answered with, never less');
    expect(r.peakCongestion, 0);
    expect(r.averageCongestion, 0);
    for (final road in city.layout.roads) {
      expect(r.congestionOf(road.id), 0);
      expect(r.volumeOf(road.id), 0);
      expect(r.routesThrough(road.id), isEmpty);
    }
    final quiet = RoadNoise.landValue(noise: 0, pollution: city.pollution);
    for (final lot in city.layout.autoParcels) {
      expect(r.serviceReach(lot.id), isTrue);
      expect(r.fireReach(lot.id), isTrue);
      expect(r.deliveryReach(lot.id), isTrue);
      expect(r.noiseOf(lot.id), 0);
      expect(r.landValueOf(lot.id), quiet,
          reason: 'a quiet plain street in the colony\'s air, as the routed '
              'model values a lot before its first pass');
    }
    expect(r.averageLandValue,
        (RoadNoise.baseLandValue - RoadNoise.pollutionPenalty(city.pollution))
            .clamp(0.0, 1.0));
    expect(r.taxLandValueFactor, 1.0);
  });

  test('a picture every congestion epoch from the first, and the count never '
      'goes back', () {
    final a = agentsOn(town());
    final r = a.readout;
    var prevT = a.timeUs, prevP = 0;
    for (var i = 0; i < 600; i++) {
      a.advance(0.5);
      final t = a.timeUs, p = r.passes;
      expect(p, greaterThanOrEqualTo(prevP));
      if (prevP > 0) {
        expect(p - prevP, t ~/ 2000000 - prevT ~/ 2000000,
            reason: 'one picture per 2 s of agent time');
      }
      expect(r.hasRun, p > 0);
      prevT = t;
      prevP = p;
    }
    expect(r.hasRun, isTrue);
    expect(r.peakCongestion, inInclusiveRange(0.0, 1.0));
    expect(r.averageCongestion, a.stats.congestionIndex,
        reason: 'the network index, as the last picture took it');
    var busy = 0;
    for (final road in a.city.layout.roads) {
      expect(r.congestionOf(road.id), inInclusiveRange(0.0, r.peakCongestion));
      if (r.volumeOf(road.id) > 0) busy++;
    }
    expect(busy, greaterThan(0), reason: 'vehicles went through some road');
  });

  test('the routes through a road are the locked routes of the vehicles '
      'driving it now', () {
    final a = agentsOn(town());
    runAgents(a, 150);
    final t = a.vehicles!, lg = a.laneGraph!;
    var sl = 0;
    while (!t.isSlotLive(sl) || t.elem[sl] >= lg.laneCount) {
      sl++;
    }
    final road = lg.graph.roads[lg.edgeRoad[lg.laneEdge[t.elem[sl]]]].id;
    var users = 0;
    for (var s = 0; s < t.highWater; s++) {
      if (!t.isSlotLive(s)) continue;
      for (var i = 0; i < t.routeLen[s]; i++) {
        final e = lg.laneEdge[t.laneOfRouteEdge(s, i)];
        if (lg.graph.roads[lg.edgeRoad[e]].id == road) {
          users++;
          break;
        }
      }
    }
    final routes = a.readout.routesThrough(road);
    expect(routes.length, math.min(users, 64));
    for (final tr in routes) {
      expect(tr.kind, TripKind.commuter, reason: 'commutes, both ways');
      expect(tr.weight, 1);
      expect(tr.roadIds, contains(road));
      for (var i = 1; i < tr.roadIds.length; i++) {
        expect(tr.roadIds[i], isNot(tr.roadIds[i - 1]),
            reason: 'each road once per visit');
      }
      expect(tr.polyline.length, greaterThanOrEqualTo(2));
    }
    expect(a.readout.routesThrough(road, kinds: {TripKind.goods}), isEmpty);
    expect(a.readout.routesThrough(road, kinds: {TripKind.commuter}).length,
        routes.length);
    expect(a.readout.routesThrough(road, limit: 1), hasLength(1));
    expect(a.readout.routesThrough('no-such-road'), isEmpty);
  });

  test('switched off, reach, noise, land value and the tax factor are the '
      'routed model\'s, answer for answer', () {
    final city = town();
    final a = agentsOn(city);
    for (var i = 0; i < 400; i++) {
      city.roadTraffic.advance(0.5);
      a.advance(0.5);
    }
    a.enabled = false;
    final r = a.readout, m = city.roadTraffic;
    expect(m.hasRun, isTrue, reason: 'the routed model has a picture too');
    for (final lot in city.layout.autoParcels) {
      expect(r.serviceReach(lot.id), m.serviceReach(lot.id));
      expect(r.fireReach(lot.id), m.fireReach(lot.id));
      expect(r.deliveryReach(lot.id), m.deliveryReach(lot.id));
      expect(r.noiseOf(lot.id), m.noiseOf(lot.id));
      expect(r.landValueOf(lot.id), m.landValueOf(lot.id));
    }
    expect(r.averageLandValue, m.averageLandValue);
    expect(r.taxLandValueFactor, m.taxLandValueFactor);
  });

  test('live, reach is the agents\' own fields, and noise and land value '
      'are the routed formulas over the measured loads (slice 2)', () {
    final city = town();
    final a = agentsOn(city);
    runAgents(a, 200);
    final r = a.readout..settle();
    expect(r.hasRun, isTrue);
    final lg = a.laneGraph!, g = lg.graph;
    expect(identical(r.reach.laneGraph, lg), isTrue);

    // Every piece's emission from its own load in the last picture.
    final stats = a.stats;
    expect(identical(stats.pictureGraph, g), isTrue);
    final emission = Float64List(g.pieceCount);
    var loud = 0;
    for (var road = 0; road < g.roadCount; road++) {
      for (var p = g.roadFirstPiece[road]; p < g.roadFirstPiece[road + 1]; p++) {
        final load = AgentTrafficReadout.measuredLoad(
            stats.pieceCongestion[p].toDouble(),
            stats.pieceFlowPerMin[p].toDouble(),
            g.roadLanes[road]);
        if (load > 0) loud++;
        emission[p] = g.roadEmission[road] * RoadNoise.volumeFactor(load);
      }
    }
    expect(loud, greaterThan(0), reason: 'the commuters loaded some piece');
    final sampler = RoadNoiseSampler(g);
    var sum = 0.0, built = 0;
    for (final lot in city.layout.autoParcels) {
      final id = lot.id;
      expect(r.serviceReach(id), r.reach.serviceReach(id));
      expect(r.fireReach(id), r.reach.fireReach(id));
      expect(r.deliveryReach(id), r.reach.deliveryReach(id));
      final i = g.lotNoOf(id)!;
      // The lots an access easement crosses (the road side's R2) take no
      // zoning and stand empty: unzoned ground, whose noise nobody asks
      // about, reads as quiet plain ground — the routed model's rule.
      if (!city.parcelBuildings.containsKey(id) &&
          lot.use == ParcelUse.unzoned) {
        expect(city.layout.easementOf?.call(id), isNotNull);
        expect(r.noiseOf(id), 0);
        expect(r.landValueOf(id),
            RoadNoise.landValue(noise: 0, pollution: city.pollution));
        continue;
      }
      final noise = sampler.noiseAt(Vec2(g.lotE[i], g.lotN[i]), emission);
      final piece = g.lotPiece[i];
      final bonus = piece < 0 ? 0.0 : g.roadBonus[g.pieceRoad[piece]];
      expect(r.noiseOf(id), closeTo(noise, 1e-6));
      expect(
          r.landValueOf(id),
          closeTo(
              RoadNoise.landValue(
                  noise: noise, bonus: bonus, pollution: city.pollution),
              1e-6));
      sum += RoadNoise.baseLandValue + bonus - RoadNoise.noiseWeight * noise;
      built++;
    }
    // The town's every street lot is built, and so are the kit's own lots.
    for (var i = 0; i < g.lotCount; i++) {
      final id = g.lotIds[i];
      if (city.layout.autoParcels.any((p) => p.id == id)) continue;
      if (!city.parcelBuildings.containsKey(id)) continue;
      final piece = g.lotPiece[i];
      final bonus = piece < 0 ? 0.0 : g.roadBonus[g.pieceRoad[piece]];
      final noise = sampler.noiseAt(Vec2(g.lotE[i], g.lotN[i]), emission);
      sum += RoadNoise.baseLandValue + bonus - RoadNoise.noiseWeight * noise;
      built++;
    }
    final average = sum / built;
    expect(
        r.averageLandValue,
        closeTo(
            (average - RoadNoise.pollutionPenalty(city.pollution))
                .clamp(0.0, 1.0),
            1e-9));
    expect(r.taxLandValueFactor,
        closeTo(RoadNoise.taxFactor(average.clamp(0.0, 1.0)), 1e-9));
  });

  test('with no traffic on either, noise, land value and the tax factor are '
      'the routed model\'s to the bit: the formulas are one', () {
    // Nobody commutes on the agents' side, and the routed model is tuned to
    // send no trip of any kind: both load every road at 0.
    AgentTuning.commuteRatePerResident = 0;
    final city = town();
    final a = agentsOn(city);
    runAgents(a, 30);
    final r = a.readout..settle();
    expect(a.stats.spawned, 0);
    final m = CityRoadTraffic(city,
        tuning: const TrafficTuning(
          workPerStep: 1 << 30,
          commuteTripsPerResident: 0,
          shopTripsPerResident: 0,
          goodsTripsPerJob: 0,
          goodsTripsPerStore: 0,
          serviceTripsPerStation: 0,
        ))
      ..advance(1);
    expect(m.hasRun, isTrue);
    expect(m.model.builtLots, greaterThan(0));
    for (var i = 0; i < a.laneGraph!.graph.lotCount; i++) {
      final id = a.laneGraph!.graph.lotIds[i];
      expect(r.noiseOf(id), m.noiseOf(id), reason: id);
      expect(r.landValueOf(id), m.landValueOf(id), reason: id);
    }
    expect(r.averageLandValue, m.averageLandValue);
    expect(r.taxLandValueFactor, m.taxLandValueFactor);
    expect(r.taxLandValueFactor, isNot(1.0),
        reason: 'built lots valued: the factor is the land\'s, not the '
            'placeholder');
  });

  test('the agents\' answers change only when passes moves (D47)', () {
    final city = town();
    final a = agentsOn(city);
    final r = a.readout;
    final lots = [for (final p in city.layout.autoParcels) p.id];
    String answers() => [
          r.taxLandValueFactor,
          r.averageLandValue,
          for (final id in lots) ...[
            r.noiseOf(id),
            r.landValueOf(id),
            r.deliveryReach(id),
            r.fireReach(id),
            r.serviceReach(id),
          ],
        ].join(',');
    var passes = r.passes;
    var seen = answers();
    var moved = 0;
    for (var i = 0; i < 400; i++) {
      a.advance(0.25);
      final now = answers();
      if (r.passes == passes) {
        expect(now, seen, reason: 'no picture since, at tick $i');
      } else if (now != seen) {
        moved++;
      }
      passes = r.passes;
      seen = now;
    }
    expect(moved, greaterThan(0), reason: 'the noise followed the traffic');
    expect(r.publishedPasses, greaterThan(1));
  });

  test('passes count the routed model\'s pictures with ours, and never go '
      'back; switched off, fire reach is the routed model\'s fire reach, not '
      'its service reach', () {
    final a = agentsOn(town());
    final routed = _Routed()..passes = 5;
    final r = AgentTrafficReadout(a, routed);
    final lot = a.city.layout.autoParcels.first.id;
    expect(r.fireReach(lot), isTrue,
        reason: 'live, the agents answer — and before a picture they punish '
            'nothing');

    expect(r.passes, 5,
        reason: 'no picture of ours yet: the routed count, so the switch to '
            'the agents takes no view\'s key back');
    runAgents(a, 60);
    final own = a.pictures;
    expect(own, greaterThan(0));
    expect(r.passes, own + 5);
    routed.passes = 6;
    expect(r.passes, own + 6,
        reason: 'the forwarded answers moved, so a view must redraw');

    // Off: every answer forwarded — and the routed model's fire reach, not
    // its service reach: an ambulance reaching a lot is no fire cover.
    a.enabled = false;
    expect(r.serviceReach(lot), isTrue);
    expect(r.fireReach(lot), isFalse);
    expect(r.passes, own + 6);

    // On again: the tables start afresh, and the count stands.
    a.enabled = true;
    expect(r.hasRun, isFalse);
    expect(r.passes, own + 6);
    expect(r.fireReach(lot), isTrue,
        reason: 'nothing of the old tables\' picture stands');
  });

  test('a town no car has driven still publishes pictures, so the Routes view '
      'is never left waiting for the first car', () {
    // The starter kit as founded, nothing zoned: ticked through the colony's
    // own advance, as the running game ticks it.
    final city = starterKit(agentTraffic: true);
    final r = city.trafficReadout;
    expect(identical(r, city.agents.readout), isTrue);
    for (var i = 0; i < 20 && !r.hasRun; i++) {
      city.advance(0.5);
    }
    expect(r.hasRun, isTrue,
        reason: 'a picture at the first congestion epoch, cars or no cars');
    expect(r.passes, greaterThan(city.roadTraffic.passes));
    if (city.agents.stats.spawned == 0) {
      expect(r.peakCongestion, 0, reason: 'an empty picture punishes nothing');
      expect(r.averageCongestion, 0);
      for (final road in city.layout.roads) {
        expect(r.congestionOf(road.id), 0);
        expect(r.routesThrough(road.id), isEmpty);
      }
    }
  });

  test('the colony\'s count never goes back across the switch to the agents '
      'and back again (D47, E37)', () {
    final city = town();
    for (var i = 0; i < 40; i++) {
      city.roadTraffic.advance(0.5);
    }
    expect(identical(city.trafficReadout, city.roadTraffic), isTrue,
        reason: 'no agents yet: the routed model answers');
    final before = city.trafficReadout.passes;

    city.agents.enabled = true;
    expect(identical(city.trafficReadout, city.agents.readout), isTrue);
    expect(city.trafficReadout.passes, greaterThanOrEqualTo(before),
        reason: 'the switch to the agents takes no view\'s key back');
    runAgents(city.agents, 60);
    final on = city.trafficReadout.passes;
    expect(on, greaterThan(before));

    city.agents.enabled = false;
    expect(identical(city.trafficReadout, city.agents.readout), isTrue,
        reason: 'once they have published, the colony answers through them');
    expect(city.trafficReadout.passes, greaterThanOrEqualTo(on),
        reason: 'nor does the switch back');
    final r = city.trafficReadout, m = city.roadTraffic;
    expect(r.hasRun, m.hasRun,
        reason: 'switched off, every answer is the routed model\'s');
    expect(r.peakCongestion, m.peakCongestion);
    expect(r.averageCongestion, m.averageCongestion);
    for (final road in city.layout.roads) {
      expect(r.congestionOf(road.id), m.congestionOf(road.id));
      expect(r.volumeOf(road.id), m.volumeOf(road.id));
    }
  });
}

/// A routed model that tells fire reach from service reach, with a pass
/// count the test moves by hand.
class _Routed implements CityTrafficReadout {
  @override
  int passes = 0;

  @override
  bool get hasRun => true;

  @override
  double get peakCongestion => 0;

  @override
  double get averageCongestion => 0;

  @override
  double congestionOf(String roadId) => 0;

  @override
  double volumeOf(String roadId) => 0;

  @override
  List<TripRoute> routesThrough(String roadId,
          {Set<TripKind>? kinds, int limit = 64}) =>
      const [];

  @override
  bool serviceReach(String lotId) => true;

  @override
  bool fireReach(String lotId) => false;

  @override
  bool deliveryReach(String lotId) => true;

  @override
  double noiseOf(String lotId) => 0;

  @override
  double landValueOf(String lotId) => 0.5;

  @override
  double get averageLandValue => 0.5;

  @override
  double get taxLandValueFactor => 1;
}
