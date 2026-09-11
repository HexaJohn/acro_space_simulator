// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/node_control.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:flutter_test/flutter_test.dart';

/// The signal clock (docs/plans/agent-traffic.md §3.7): a pure function of
/// agent time in whole microseconds, which the arbiter and the renderer both
/// call — so it must never let two crossing streams go at once, and must
/// tell every caller the same thing at the same instant.
void main() {
  /// Two avenues crossing at the origin: the class-only warrant lights it.
  RoadGraph crossing([void Function(CityLayout)? more]) {
    final layout = CityLayout();
    layout.commitRoad(
        controls: const [Vec2(0, -300), Vec2(0, 300)],
        roadClass: RoadClass.avenue,
        regenerateLots: false);
    layout.commitRoad(
        controls: const [Vec2(-300, 0), Vec2(300, 0)],
        roadClass: RoadClass.avenue,
        regenerateLots: false);
    more?.call(layout);
    return RoadGraph.of(layout);
  }

  SignalPlan planAt(RoadGraph g, Vec2 p) {
    final node = g.nodeNear(p)!;
    expect(node.control, JunctionControl.signals);
    return SignalPlan.of(node);
  }

  const second = 1000000;

  test('a four-way crossing is two phases, 32 s round', () {
    final plan = planAt(crossing(), const Vec2(0, 0));
    expect(plan.phaseCount, 2);
    expect(plan.cycleUs, 32 * second);
    // Opposite legs share a phase; crossing legs do not.
    final node = crossing().nodeNear(const Vec2(0, 0))!;
    for (var a = 0; a < node.legs.length; a++) {
      for (var b = 0; b < node.legs.length; b++) {
        final da = node.legs[a].heading, db = node.legs[b].heading;
        final opposite = ((da - db).abs() - 3.14159).abs() < 0.1 || a == b;
        expect(plan.legPhase[a] == plan.legPhase[b], opposite);
      }
    }
  });

  test('the state is periodic in the cycle', () {
    final plan = planAt(crossing(), const Vec2(0, 0));
    for (var t = 0; t < 3 * plan.cycleUs; t += 700000) {
      for (var p = 0; p < plan.phaseCount; p++) {
        expect(plan.stateAt(p, t), plan.stateAt(p, t + plan.cycleUs));
        expect(plan.stateAt(p, t), plan.stateAt(p, t + 5 * plan.cycleUs));
      }
    }
  });

  test('two phases are never green, or amber, together', () {
    final plan = planAt(crossing(), const Vec2(0, 0));
    bool moving(SignalState s) =>
        s == SignalState.green || s == SignalState.amber;
    for (var t = 0; t < plan.cycleUs; t += 50000) {
      final a = plan.stateAt(0, t), b = plan.stateAt(1, t);
      expect(moving(a) && moving(b), isFalse, reason: 'at $t µs');
    }
  });

  test('each phase is 12 s green, 3 s amber and 1 s all-red, then red', () {
    final plan = planAt(crossing(), const Vec2(0, 0));
    for (var p = 0; p < plan.phaseCount; p++) {
      final spent = <SignalState, int>{};
      const step = 100000;
      for (var t = 0; t < plan.cycleUs; t += step) {
        final s = plan.stateAt(p, t);
        spent[s] = (spent[s] ?? 0) + step;
      }
      expect(spent[SignalState.green], SignalPlan.greenUs);
      expect(spent[SignalState.amber], SignalPlan.amberUs);
      expect(spent[SignalState.allRed], SignalPlan.allRedUs);
      expect(spent[SignalState.red], plan.cycleUs - SignalPlan.phaseUs);
    }
    // Amber follows green, all-red follows amber, exactly on the
    // microsecond.
    final t0 = (plan.cycleUs - plan.offsetUs) % plan.cycleUs;
    expect(plan.stateAt(0, t0), SignalState.green);
    expect(plan.stateAt(0, t0 + SignalPlan.greenUs - 1), SignalState.green);
    expect(plan.stateAt(0, t0 + SignalPlan.greenUs), SignalState.amber);
    expect(plan.stateAt(0, t0 + SignalPlan.greenUs + SignalPlan.amberUs),
        SignalState.allRed);
    expect(plan.stateAt(0, t0 + SignalPlan.phaseUs), SignalState.red);
    expect(plan.stateAt(1, t0 + SignalPlan.phaseUs), SignalState.green);
  });

  test('the offset is keyed by where the junction is, so a split elsewhere '
      'keeps it', () {
    final before = planAt(crossing(), const Vec2(0, 0));
    expect(
        before.offsetUs,
        fnv1a32(JunctionOverride.keyFor(
                crossing().nodeNear(const Vec2(0, 0))!.at)) %
            before.cycleUs);
    // A street across the east arm splits it: the crossing's roads are new
    // pieces with new ids, and its light keeps its phase.
    final after = planAt(
        crossing((l) => l.commitRoad(
            controls: const [Vec2(150, -200), Vec2(150, 200)],
            regenerateLots: false)),
        const Vec2(0, 0));
    expect(after.offsetUs, before.offsetUs);
    for (var t = 0; t < before.cycleUs; t += 900000) {
      expect(after.stateAt(0, t), before.stateAt(0, t));
    }
  });

  test('a Y gives each leg a phase of its own; a T two', () {
    // Three avenues meeting at 120°: no two of them run on one axis.
    final y = CityLayout();
    for (final (i, p) in const [Vec2(0, 200), Vec2(173, -100), Vec2(-173, -100)]
        .indexed) {
      y.addRoad(RoadSpline(
          id: 'y$i', controls: [const Vec2(0, 0), p], roadClass: RoadClass.avenue));
    }
    final yPlan = planAt(RoadGraph.of(y), const Vec2(0, 0));
    expect(yPlan.phaseCount, 3);
    expect(yPlan.cycleUs, 48 * second);
    expect({for (var k = 0; k < 3; k++) yPlan.legPhase[k]}, {0, 1, 2});

    final t = CityLayout();
    t.addRoad(const RoadSpline(
        id: 'w', controls: [Vec2(-200, 0), Vec2(0, 0)], roadClass: RoadClass.avenue));
    t.addRoad(const RoadSpline(
        id: 'e', controls: [Vec2(0, 0), Vec2(200, 0)], roadClass: RoadClass.avenue));
    t.addRoad(const RoadSpline(
        id: 's', controls: [Vec2(0, 0), Vec2(0, -200)], roadClass: RoadClass.avenue));
    expect(planAt(RoadGraph.of(t), const Vec2(0, 0)).phaseCount, 2);
  });

  test('a leg nothing arrives along has no phase', () {
    final layout = CityLayout();
    layout.addRoad(const RoadSpline(
        id: 'w', controls: [Vec2(-200, 0), Vec2(0, 0)], roadClass: RoadClass.avenue));
    layout.addRoad(const RoadSpline(
        id: 'e', controls: [Vec2(0, 0), Vec2(200, 0)], roadClass: RoadClass.avenue));
    layout.addRoad(const RoadSpline(
        id: 'n', controls: [Vec2(0, 0), Vec2(0, 200)], roadClass: RoadClass.avenue));
    // A one-way road leaving the crossing southwards.
    layout.addRoad(const RoadSpline(
        id: 's',
        controls: [Vec2(0, 0), Vec2(0, -200)],
        roadClass: RoadClass.streetOneWay));
    final node = RoadGraph.of(layout).nodeNear(const Vec2(0, 0))!;
    final plan = SignalPlan.of(node);
    final out = node.legRoadIds.indexOf('s');
    expect(node.legs[out].outgoing, isTrue);
    expect(plan.legPhase[out], -1);
    expect(plan.legStateAt(out, 0), SignalState.red);
  });
}
