// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Live signal heads (docs/plans/agent-traffic.md §13.6).
///
/// Each mast stands where the tiles stand theirs; each head lights exactly
/// the colour the plan the arbiter reads shows at that agent time, and never
/// two phases green at once; a head whose light did not change is not
/// written, and no draw's count ever changes.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/city_traffic_frame.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/node_control.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/signal_head_layer.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/coord_convert.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../traffic/traffic_fixture.dart';

void main() {
  late CitySim city;
  late CityTrafficFrame f;
  late LaneGraph lg;
  late Vector3 anchor;

  setUpAll(() {
    city = signalised();
    city.agents.enabled = true;
    city.agents.advance(0.5);
    f = WorldSnapshot.capture(
      0,
      InMemoryVesselRepository(const []),
      system: SampleWorld.realSystem(),
      cities: InMemoryCityRepository([city]),
    ).cityTraffic.single;
    lg = city.agents.laneGraph!;
    final p = f.geometry.nodePts;
    final r = math.sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
    // A body root's anchor is a building's place: somewhere in the colony.
    anchor = city.localToBodyFixed(const Vec2(40, 60), bodyRadiusM: r);
  });

  bool off(vm.Matrix4 m) => m.storage.sublist(0, 12).every((x) => x == 0);

  Vector3 centreOf(vm.Matrix4 m) => Vector3(m.storage[12], m.storage[13],
          m.storage[14]) *
      (1 / kRenderScale);

  test('every mast stands where the tiles stand theirs', () {
    final net = f.net;
    final heads = SignalHeadPlacement(net, f.geometry, anchor);
    expect(heads.headCount, 4);
    for (var h = 0; h < heads.headCount; h++) {
      final n = net.headNode[h];
      final node = lg.graph.nodes[n];
      final leg = node.legs[net.headLeg[h]];
      final g = f.geometry;
      // The radius the node was put down at: its height along the colony's
      // up (`SurfacePlacement.place` lays out a tangent plane).
      final up0 = city.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: 1);
      final r = Vector3(g.nodePts[3 * n], g.nodePts[3 * n + 1],
              g.nodePts[3 * n + 2])
          .dot(up0);
      final at0 = city.localToBodyFixed(node.at, bodyRadiusM: r);
      final up = at0.normalized;
      // Out of the junction along the leg's heading (north toward east), on
      // the ground: ten metres along it, less the rise.
      final ahead = city.localToBodyFixed(
              node.at + Vec2(math.sin(leg.heading), math.cos(leg.heading)) * 10,
              bodyRadiusM: r) -
          at0;
      final dir = (ahead - up * ahead.dot(up)).normalized;
      final side = dir.cross(up).normalized;
      // road_mesher.dart, `_crossing`: the plate lifted, the mast at 0.98 of
      // its radius (maxHalfWidth × 1.45), beside the leg by 0.92 of its half
      // width plus 1.6 m, and 4.6 m tall.
      final at = at0 - anchor + up * (RoadMesher.plateLiftM + g.nodeLift[n]);
      final plate = junctionHalfWidthOf(node) * 1.45;
      final corner = at +
          dir * (plate * 0.98) +
          side * (leg.roadClass.halfWidth * 0.92 + 1.6);
      final top = corner + up * 4.6;
      final got = Vector3(
          heads.top[3 * h], heads.top[3 * h + 1], heads.top[3 * h + 2]);
      expect((got - top).length, lessThan(1e-3), reason: 'head $h');
    }
  });

  test('each head lights one lamp: the colour its plan shows', () {
    final net = f.net;
    final heads = SignalHeadPlacement(net, f.geometry, anchor);
    final changed = Int32List(heads.headCount);
    final seen = <int>{};
    for (var t = 0; t <= 64000000; t += 250000) {
      heads.update(t, changed);
      final greenPhases = <int>{};
      for (var h = 0; h < heads.headCount; h++) {
        final lit = [
          for (var c = 0; c < 3; c++)
            if (!off(heads.matricesOf(c)[h])) c,
        ];
        final state = net.stateOf(h, t);
        expect(lit, [SignalHeadPlacement.colourOf(state)], reason: 'head $h, $t µs');
        seen.addAll(lit);
        if (state == SignalState.green) greenPhases.add(net.headPhase[h]);
      }
      expect(greenPhases.length, lessThanOrEqualTo(1), reason: '$t µs');
    }
    expect(seen, {SignalHeadLayer.red, SignalHeadLayer.amber, SignalHeadLayer.green});
  });

  test('a light that did not change writes nothing, and no count changes',
      () {
    final net = f.net;
    final heads = SignalHeadPlacement(net, f.geometry, anchor);
    final n = heads.headCount;
    final changed = Int32List(n);
    expect(heads.update(0, changed), n, reason: 'every head, the first time');
    expect(heads.update(0, changed), 0);
    final cycle = net.plans.single.cycleUs;
    final before = [for (var h = 0; h < n; h++) net.stateOf(h, 0)];
    for (var t = 100000; t <= 2 * cycle; t += 100000) {
      final want = [
        for (var h = 0; h < n; h++)
          if (net.stateOf(h, t) != before[h]) h,
      ];
      final got = heads.update(t, changed);
      expect(changed.sublist(0, got), want, reason: '$t µs');
      for (var h = 0; h < n; h++) {
        before[h] = net.stateOf(h, t);
      }
      for (var c = 0; c < 3; c++) {
        expect(heads.matricesOf(c), hasLength(n));
      }
    }
  });

  test('the lamps hang beside the baked head, in toward the road', () {
    final net = f.net;
    final heads = SignalHeadPlacement(net, f.geometry, anchor);
    final changed = Int32List(heads.headCount);
    for (var h = 0; h < heads.headCount; h++) {
      // A time the head shows red, so its red lamp is lit.
      var t = 0;
      while (net.stateOf(h, t) != SignalState.red) {
        t += 500000;
      }
      heads.update(t, changed);
      final top = Vector3(
          heads.top[3 * h], heads.top[3 * h + 1], heads.top[3 * h + 2]);
      final fr = heads.frame;
      final side = Vector3(fr[9 * h], fr[9 * h + 1], fr[9 * h + 2]);
      final dir = Vector3(fr[9 * h + 3], fr[9 * h + 4], fr[9 * h + 5]);
      final up = Vector3(fr[9 * h + 6], fr[9 * h + 7], fr[9 * h + 8]);
      for (var c = 0; c < 3; c++) {
        final offset = centreOf(heads.matricesOf(c)[h]) - top;
        // On the mast, in the head's place (the tiles bake no head under
        // agent traffic); an unlit lamp keeps its place, only its scale
        // goes. (An instance matrix is single precision: good to a
        // hundredth of a millimetre this near the anchor.)
        expect(offset.dot(side).abs(), lessThan(1e-4));
        expect(offset.dot(up), closeTo(SignalHeadPlacement.lampRiseM[c], 1e-4));
        expect(offset.dot(dir).abs(), lessThan(1e-4));
      }
      expect(off(heads.red[h]), isFalse);
    }
  });
}
