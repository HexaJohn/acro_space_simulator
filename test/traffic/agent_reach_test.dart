// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_traffic_model.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// The agents' reach fields (docs/plans/agent-traffic.md §17.1
/// `agent_reach_test`, §12.3, D47): reach follows the one-way streets, fire
/// cover counts only stations with safety cover, a works' own goods are no
/// delivery, and a lot the picture does not know is reached. Where the lane
/// graph turns the way the road graph does, the fields agree with the
/// routed model's to the metre.
void main() {
  setUp(() => AgentTuning.commuteRatePerResident = 0);
  tearDown(AgentTuning.reset);

  group('reach follows one-way streets', () {
    /// The routed model's 400 × 100 m block (road_traffic_model_test.dart:
    /// 65-91): the bottom street of [bottom]'s class, drawn east; a police
    /// station on its south kerb at 288 m and a house at 96 m. Route metres
    /// from one to the other, the agents' and the routed model's.
    ({double? agents, double? routed}) loop(RoadClass bottom) {
      final c = foundFlat(id: 'loop');
      final s1 = commit(
        c,
        FixtureRoad(const [Vec2(0, 0), Vec2(400, 0)], roadClass: bottom),
      );
      commit(c, const FixtureRoad([Vec2(0, 100), Vec2(400, 100)]));
      commit(c, const FixtureRoad([Vec2(0, 0), Vec2(0, 100)]));
      commit(c, const FixtureRoad([Vec2(400, 0), Vec2(400, 100)]));
      final station = lotOn(c, s1, const Vec2(288, -20), north: false);
      final house = lotOn(c, s1, const Vec2(96, -20), north: false);
      expect(c.placeOnParcel(station.id, util('Police Station')), isTrue);
      final a = pictured(c);
      return (
        agents: a.readout.reach.serviceDistanceTo(house.id),
        routed: settledRouted(c).model.serviceDistanceTo(house.id),
      );
    }

    test(
      'two-way, straight back along the street; one-way, round the block',
      () {
        final two = loop(RoadClass.street);
        expect(two.agents, closeTo(177, 2));
        expect(two.agents, two.routed);
        final one = loop(RoadClass.streetOneWay);
        expect(
          one.agents,
          closeTo(823, 2),
          reason: 'on to the corner, round the block, back in at the start',
        );
        expect(one.agents, one.routed);
      },
    );

    test('past four kilometres of route a lot is out of reach', () {
      final c = foundFlat(id: 'bigloop');
      final s1 = commit(
        c,
        const FixtureRoad([
          Vec2(0, 0),
          Vec2(3000, 0),
        ], roadClass: RoadClass.streetOneWay),
      );
      commit(c, const FixtureRoad([Vec2(0, 1000), Vec2(3000, 1000)]));
      commit(c, const FixtureRoad([Vec2(0, 0), Vec2(0, 1000)]));
      commit(c, const FixtureRoad([Vec2(3000, 0), Vec2(3000, 1000)]));
      final station = lotOn(c, s1, const Vec2(2904, -20), north: false);
      final behind = lotOn(c, s1, const Vec2(96, -20), north: false);
      final ahead = lotOn(c, s1, const Vec2(2976, -20), north: false);
      expect(c.placeOnParcel(station.id, util('Police Station')), isTrue);
      final r = pictured(c).readout;
      expect(
        r.serviceReach(behind.id),
        isFalse,
        reason: '2.8 km back the wrong way; 5.2 km round',
      );
      expect(r.fireReach(behind.id), isFalse);
      expect(r.serviceReach(ahead.id), isTrue);
      expect(r.fireReach(ahead.id), isTrue);
      expect(r.reach.serviceDistanceTo(ahead.id), closeTo(72, 2));
    });

    test('reversing a one-way road cuts off the lots it runs away from', () {
      ({bool service, bool goods, bool home}) reach({required bool reversed}) {
        final c = foundFlat(id: 'rev');
        final s = commit(c, const FixtureRoad([Vec2(-100, 0), Vec2(100, 0)]));
        final o = commit(
          c,
          FixtureRoad(
            const [Vec2(100, 0), Vec2(400, 0)],
            roadClass: RoadClass.streetOneWay,
            reversed: reversed,
          ),
        );
        final station = lotOn(c, s, const Vec2(-52, 20), north: true);
        final shop = lotOn(c, o, const Vec2(220, 20), north: true);
        final home = lotOn(c, s, const Vec2(28, -20), north: false);
        expect(c.placeOnParcel(station.id, util('Police Station')), isTrue);
        expect(c.placeOnParcel(shop.id, mall), isTrue);
        final r = pictured(c).readout;
        final m = settledRouted(c);
        expect(r.serviceReach(shop.id), m.serviceReach(shop.id));
        expect(r.deliveryReach(shop.id), m.deliveryReach(shop.id));
        return (
          service: r.serviceReach(shop.id),
          goods: r.deliveryReach(shop.id),
          home: r.serviceReach(home.id) && r.deliveryReach(home.id),
        );
      }

      final east = reach(reversed: false);
      expect(east.service, isTrue);
      expect(
        east.goods,
        isTrue,
        reason: 'in off-world through the landing site',
      );
      expect(east.home, isTrue);
      final west = reach(reversed: true);
      expect(west.service, isFalse);
      expect(west.goods, isFalse);
      expect(west.home, isTrue);
    });
  });

  test("fire reach counts only stations with safety cover: a clinic's "
      'ambulance is no fire cover', () {
    // A one-way street east, a house on it, and a police station down the
    // street that cannot reach it: nothing leads back. In one colony a
    // clinic stands up the street from the house; in another, the police.
    ({bool service, bool fire, double burn}) house(String upstream) {
      final c = foundFlat(id: 'fire');
      final s = commit(
        c,
        const FixtureRoad([
          Vec2(0, 0),
          Vec2(600, 0),
        ], roadClass: RoadClass.streetOneWay),
      );
      final station = lotOn(c, s, const Vec2(504, -20), north: false);
      final home = lotOn(c, s, const Vec2(144, -20), north: false);
      expect(c.placeOnParcel(station.id, util('Police Station')), isTrue);
      expect(c.placeOnParcel(home.id, homes), isTrue);
      if (upstream.isNotEmpty) {
        final at = lotOn(c, s, const Vec2(48, -20), north: false);
        expect(c.placeOnParcel(at.id, util(upstream)), isTrue);
      }
      // The colony's own agents, so the lot-fire line reads their answers.
      c.agents.enabled = true;
      runAgents(c.agents, 3);
      c.agents.readout.settle();
      expect(identical(c.trafficReadout, c.agents.readout), isTrue);
      expect(c.trafficReadout.hasRun, isTrue);
      // Cover enough to put the fire out, if an engine could get there.
      c.population = 100;
      c.services['safety'] = 100;
      c.lotFires[home.id] = 0.5;
      c.advanceParcelFires(0.1);
      return (
        service: c.trafficReadout.serviceReach(home.id),
        fire: c.trafficReadout.fireReach(home.id),
        burn: c.lotFires[home.id] ?? 0,
      );
    }

    final alone = house('');
    expect(alone.service, isFalse);
    expect(alone.fire, isFalse);
    expect(alone.burn, greaterThan(0.5), reason: 'out of reach, it spreads');
    final clinic = house('Clinic');
    expect(clinic.service, isTrue, reason: 'the ambulance gets there');
    expect(clinic.fire, isFalse, reason: 'but no engine does');
    expect(
      clinic.burn,
      closeTo(alone.burn, 1e-12),
      reason: 'an ambulance puts no fire out',
    );
    final police = house('Police Station');
    expect(police.service, isTrue);
    expect(police.fire, isTrue, reason: 'safety cover up the street');
    expect(police.burn, lessThan(alone.burn));
  });

  group("a works' own goods are no delivery", () {
    test('a works on a street nothing reaches is not its own delivery', () {
      // A one-way street running INTO the junction from a dead end: a works
      // grown on it ships goods only away, never back to its own door.
      ({bool goods, bool routed, double grown}) works({
        required bool reversed,
      }) {
        final c = foundFlat(
          id: 'selfsupply',
          roads: const [
            FixtureRoad([Vec2(-100, 0), Vec2(100, 0)]),
          ],
        );
        final o = commit(
          c,
          FixtureRoad(
            const [Vec2(100, 0), Vec2(400, 0)],
            roadClass: RoadClass.streetOneWay,
            reversed: reversed,
          ),
        );
        final lot = lotOn(c, o, const Vec2(220, 20), north: true);
        c.layout.setUse(lot.id, ParcelUse.industrial);
        c.grownParcels[lot.id] = 1.5;
        c.infiniteDemand = true;
        final routed = settledRouted(c).deliveryReach(lot.id);
        c.agents.enabled = true;
        runAgents(c.agents, 3);
        c.agents.readout.settle();
        final goods = c.trafficReadout.deliveryReach(lot.id);
        c.advanceParcelGrowth(10);
        return (
          goods: goods,
          routed: routed,
          grown: c.grownParcels[lot.id] ?? 0,
        );
      }

      final east = works(reversed: false);
      expect(
        east.goods,
        isTrue,
        reason: 'in off-world through the landing site',
      );
      expect(east.goods, east.routed);
      expect(east.grown, greaterThan(1.5));
      final west = works(reversed: true);
      expect(west.goods, isFalse, reason: 'its own goods only leave');
      expect(west.goods, west.routed);
      expect(west.grown, lessThan(1.5), reason: 'what stands declines');
    });

    test("its own lorries turning at the node beside it are no delivery", () {
      // A two-way street past the reversed one-way, and a spur off its far
      // end with a dead end to turn at. A works on the street ships both
      // ways, and its lorries come back to its door by turning at the end of
      // the spur: its own still. A second works up the spur is a delivery.
      ({bool goods, bool routed, double grown}) works({
        required bool reversed,
        bool neighbour = false,
      }) {
        final c = foundFlat(
          id: 'selfturn',
          roads: const [
            FixtureRoad([Vec2(-100, 0), Vec2(100, 0)]),
          ],
        );
        commit(
          c,
          FixtureRoad(
            const [Vec2(100, 0), Vec2(400, 0)],
            roadClass: RoadClass.streetOneWay,
            reversed: reversed,
          ),
        );
        final s = commit(c, const FixtureRoad([Vec2(400, 0), Vec2(700, 0)]));
        final spur = commit(
          c,
          const FixtureRoad([Vec2(700, 0), Vec2(700, 300)]),
        );
        final lot = lotOn(c, s, const Vec2(550, 20), north: true);
        c.layout.setUse(lot.id, ParcelUse.industrial);
        c.grownParcels[lot.id] = 1.5;
        if (neighbour) {
          final next = lotOn(c, spur, const Vec2(720, 200), north: true);
          c.layout.setUse(next.id, ParcelUse.industrial);
          c.grownParcels[next.id] = 1.5;
        }
        c.infiniteDemand = true;
        final routed = settledRouted(c).deliveryReach(lot.id);
        c.agents.enabled = true;
        runAgents(c.agents, 3);
        c.agents.readout.settle();
        final goods = c.trafficReadout.deliveryReach(lot.id);
        c.advanceParcelGrowth(10);
        return (
          goods: goods,
          routed: routed,
          grown: c.grownParcels[lot.id] ?? 0,
        );
      }

      final open = works(reversed: false);
      expect(
        open.goods,
        isTrue,
        reason: 'in off-world through the landing site',
      );
      expect(open.goods, open.routed);
      expect(open.grown, greaterThan(1.5));
      final alone = works(reversed: true);
      expect(alone.goods, isFalse, reason: 'only its own lorries come back');
      expect(alone.goods, alone.routed);
      expect(alone.grown, lessThan(1.5), reason: 'what stands declines');
      final paired = works(reversed: true, neighbour: true);
      expect(
        paired.goods,
        isTrue,
        reason:
            "the spur's works delivers, past the dead end its own "
            'lorries turn at first',
      );
      expect(paired.goods, paired.routed);
    });
  });

  group('a lot the picture does not know is reached', () {
    test('before any picture, every lot is reached', () {
      final c = foundFlat(
        id: 'early',
        roads: const [
          FixtureRoad([
            Vec2(0, 0),
            Vec2(600, 0),
          ], roadClass: RoadClass.streetOneWay),
        ],
      );
      final a = agentsOn(c)..advance(0.02);
      final r = a.readout;
      expect(r.hasRun, isFalse);
      for (final lot in c.layout.autoParcels) {
        expect(r.serviceReach(lot.id), isTrue);
        expect(r.fireReach(lot.id), isTrue);
        expect(r.deliveryReach(lot.id), isTrue);
      }
    });

    test('an id it never saw, and a lot cut after it, are reached', () {
      final c = foundFlat(
        id: 'unknown',
        roads: const [
          FixtureRoad([
            Vec2(0, 0),
            Vec2(600, 0),
          ], roadClass: RoadClass.streetOneWay),
        ],
      );
      final a = pictured(c);
      final r = a.readout;
      final known = c.layout.autoParcels.first.id;
      expect(
        r.serviceReach(known),
        isFalse,
        reason: 'no station: a lot the picture knows is not reached',
      );
      expect(r.fireReach(known), isFalse);
      expect(r.serviceReach('lot-nowhere'), isTrue);
      expect(r.fireReach('lot-nowhere'), isTrue);
      expect(r.deliveryReach('lot-nowhere'), isTrue);

      // A new street: its lots are cut now, and no picture has seen them.
      final added = commit(
        c,
        const FixtureRoad([Vec2(300, 0), Vec2(300, 400)]),
      );
      final fresh = c.layout.autoParcels
          .where((p) => p.roadId == added)
          .map((p) => p.id)
          .where((id) => r.reach.laneGraph!.graph.lotNoOf(id) == null)
          .toList();
      expect(fresh, isNotEmpty);
      for (final id in fresh) {
        expect(r.serviceReach(id), isTrue);
        expect(r.fireReach(id), isTrue);
        expect(r.deliveryReach(id), isTrue);
      }
    });
  });

  group('parity with the routed model where the rules coincide', () {
    test('the starter town with a police station and a clinic', () {
      final c = starterKit();
      final free = freeLots(c);
      expect(c.placeOnParcel(free[3].id, util('Police Station')), isTrue);
      expect(c.placeOnParcel(free[free.length - 4].id, util('Clinic')), isTrue);
      zoneAll(c);
      buildAll(c);
      _expectParity(c);
    });

    test('a three-by-three grid of streets, stations and works round it', () {
      final c = grid(3);
      final lots = c.layout.autoParcels.toList();
      expect(c.placeOnParcel(lots[5].id, util('Police Station')), isTrue);
      expect(
        c.placeOnParcel(lots[lots.length ~/ 2].id, util('Clinic')),
        isTrue,
      );
      zoneAll(c);
      buildAll(c);
      _expectParity(c);
    });

    test('where they differ, on purpose: no U-turn at a plain junction', () {
      // A four-lane avenue east–west through a crossing with a street, dead
      // ends all round. A lot on the avenue is met from its own side only
      // (the median), so a station on the north kerb, east of the crossing,
      // leaves westbound; the house on the south kerb is met eastbound. The
      // routed model turns at the crossing and comes straight back; a car
      // may not (§3.6), and goes down the street to its dead end to turn.
      final c = foundFlat(id: 'uturn');
      final avenue = commit(
        c,
        const FixtureRoad([
          Vec2(-400, 0),
          Vec2(400, 0),
        ], roadClass: RoadClass.avenue),
      );
      commit(c, const FixtureRoad([Vec2(0, -300), Vec2(0, 300)]));
      final station = lotNearest(c, const Vec2(200, 30));
      final house = lotNearest(c, const Vec2(100, -30));
      expect(station.roadId, startsWith(avenue));
      expect(house.roadId, startsWith(avenue));
      expect(c.placeOnParcel(station.id, util('Police Station')), isTrue);
      final agents = pictured(c).readout.reach.serviceDistanceTo(house.id)!;
      final routed = settledRouted(c).model.serviceDistanceTo(house.id)!;
      expect(
        routed,
        closeTo(300, 12),
        reason: 'back to the crossing, a U-turn, and out to the house',
      );
      expect(
        agents,
        closeTo(routed + 600, 2),
        reason: 'the same, less the U-turn, plus 300 m down the street and back',
      );
    });
  });

  test('roadTraffic.advance never runs in an agent colony (E3a), and runs in '
      'any other', () {
    AgentTuning.reset();
    final agents = town(agentTraffic: true);
    final routed = town();
    var agentsPhases = 0, routedPhases = 0;
    agents.debugTickProbe = (p) {
      if (p == 'roadTraffic.advance') agentsPhases++;
    };
    routed.debugTickProbe = (p) {
      if (p == 'roadTraffic.advance') routedPhases++;
    };
    final agentsPasses = agents.roadTraffic.passes;
    for (var i = 0; i < 240; i++) {
      agents.advance(0.5);
      routed.advance(0.5);
    }
    expect(agentsPhases, 0);
    expect(agents.roadTraffic.passes, agentsPasses,
        reason: 'the routed model never republished in the agent colony');
    expect(agents.trafficReadout, same(agents.agents.readout));
    expect(agents.trafficReadout.hasRun, isTrue);
    expect(routedPhases, 240);
    expect(routed.roadTraffic.passes, greaterThan(0));
  });
}

/// Every graph lot's reach, the agents' against the routed model's: the
/// same answers, and the same service and fire distances to the metre.
void _expectParity(CitySim c) {
  final a = pictured(c);
  final m = settledRouted(c);
  final g = a.laneGraph!.graph;
  var finite = 0;
  final diffs = <String>[];
  for (var i = 0; i < g.lotCount; i++) {
    final id = g.lotIds[i];
    final r = a.readout;
    if (r.serviceReach(id) != m.serviceReach(id)) diffs.add('service $id');
    if (r.fireReach(id) != m.fireReach(id)) diffs.add('fire $id');
    if (r.deliveryReach(id) != m.deliveryReach(id)) diffs.add('goods $id');
    final da = r.reach.serviceDistanceTo(id);
    final dm = m.model.serviceDistanceTo(id);
    if ((da == null) != (dm == null) ||
        (da != null && (da - dm!).abs() > 1e-6)) {
      diffs.add('distance $id: $da vs $dm');
    }
    if (da != null) finite++;
  }
  expect(diffs, isEmpty);
  expect(finite, greaterThan(0), reason: 'some lot is in a station\'s reach');
}

/// Agents of the test's own on [c], advanced past their first picture, and
/// the readout's pass on that picture run to its end.
CityAgents pictured(CitySim c) {
  final a = agentsOn(c);
  runAgents(a, 3);
  expect(a.stats.hasRun, isTrue);
  a.readout.settle();
  expect(a.readout.reach.hasFields, isTrue);
  return a;
}

/// A routed model over [c] run to the end of one pass.
CityRoadTraffic settledRouted(CitySim c) {
  final t = CityRoadTraffic(
    c,
    tuning: const TrafficTuning(workPerStep: 1 << 30),
  );
  t.advance(1);
  expect(t.hasRun, isTrue);
  return t;
}

CityBuildingSpec util(String label) =>
    kUtilCatalog.firstWhere((s) => s.label == label);

final homes = kZoneSpecs['residential']![Density.low]!;
final mall = kZoneSpecs['commercial']![Density.medium]!;

/// The auto lot on [roadId] whose centroid is nearest [p], north or south of
/// the line n = 0 as [north] says (road_traffic_model_test.dart:37-48).
Parcel lotOn(CitySim c, String roadId, Vec2 p, {required bool north}) {
  final lots =
      c.layout.autoParcels
          .where((l) => l.roadId == roadId && (l.centroid.n > 0) == north)
          .toList()
        ..sort(
          (a, b) =>
              a.centroid.distanceTo(p).compareTo(b.centroid.distanceTo(p)),
        );
  return lots.first;
}
