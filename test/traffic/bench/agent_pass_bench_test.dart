// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/city_traffic_frame.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_frame.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/agent_traffic_pass.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic_fixture.dart';
import 'bench_support.dart';

/// §15.5 benchmark 5 (docs/plans/agent-traffic.md §13.3–13.8, §15.1): the
/// agent pose pass with 1,500 vehicles, its render cap, all in range:
/// microseconds a frame, at 60 Hz against a sample every 0.2 s of agent
/// time, so most frames interpolate and one in twelve takes a new sample.
///
/// The rows are laid the way a running town lays them: most on lanes, each
/// heading for the connector out of its lane, and a quarter on connectors,
/// heading for the lane each leads to. Between samples the pass rolls a row
/// past its element's end into the next — so the connector poses and the
/// roll-on, not only the lane poses, are what is weighed.
///
/// The design point adds 800 pedestrians; slice 1 has none, so there are
/// none here. §15.1 holds the pass to 1 ms a frame: under ACRO_PERF, the
/// 95th percentile frame.
void main() {
  test('bench: the agent pass, 1,500 vehicles (§15.5 #5)', () {
    final city = grid(6)..agents.enabled = true;
    city.agents.advance(0.5);
    final captured = WorldSnapshot.capture(
      0,
      InMemoryVesselRepository(const []),
      system: SampleWorld.realSystem(),
      cities: InMemoryCityRepository([city]),
    ).cityTraffic.single;
    final g = captured.geometry;
    final pts = g.pts;
    final r = math.sqrt(pts[0] * pts[0] + pts[1] * pts[1] + pts[2] * pts[2]);
    final anchor = city.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: r);
    final lanes = g.laneCount, cons = g.connectorCount;
    expect(cons, greaterThan(0), reason: 'the grid has junctions to cross');

    // The first connector out of each lane, for the lane rows to roll on to.
    final outCon = Int32List(lanes)..fillRange(0, lanes, -1);
    for (var c = 0; c < cons; c++) {
      final from = g.conFromLane[c];
      if (outCon[from] < 0) outCon[from] = c;
    }

    const n = 1500;
    final elem = Int32List(n), next = Int32List(n);
    final len = Float32List(n), speed = Float32List(n), s0 = Float32List(n);
    var onConnectors = 0;
    for (var i = 0; i < n; i++) {
      if (i % 4 == 3) {
        final c = (i * 11) % cons;
        elem[i] = lanes + c;
        next[i] = g.conToLane[c];
        len[i] = g.conLen[c];
        onConnectors++;
      } else {
        final l = (i * 7) % lanes;
        elem[i] = l;
        next[i] = outCon[l] < 0 ? -1 : lanes + outCon[l];
        len[i] = g.laneLen[l];
      }
      speed[i] = 8.0 + i % 5;
      s0[i] = ((i * 37) % 997) / 997 * math.max(0.0, len[i] - 0.5);
    }
    AgentFrame sample(int k) {
      final s = Float32List(n);
      for (var i = 0; i < n; i++) {
        s[i] = len[i] <= 0 ? 0 : (s0[i] + speed[i] * kStepS * k) % len[i];
      }
      return AgentFrame.fromColumns(
        count: n,
        timeUs: (k * kStepUs).toDouble(),
        graphRev: g.graphRev,
        handle: Int32List.fromList([for (var i = 0; i < n; i++) i + 1]),
        elem: elem,
        next: next,
        s: s,
        v: speed,
        a: Float32List(n),
        lat: Float32List(n),
        kind: Uint8List(n)..fillRange(0, n, AgentKind.car.index),
        variant: Uint8List.fromList([for (var i = 0; i < n; i++) i & 3]),
        flags: Uint8List(n),
      );
    }

    final pass = AgentTrafficPass();
    var frame = sample(0);
    final us = <double>[];
    var placed = 0;
    for (var i = 0; i < 720; i++) {
      if (i % 12 == 0) frame = sample(i ~/ 12);
      final f0 = CityTrafficFrame(
          colonyId: city.id,
          bodyId: 'earth',
          agents: frame,
          geometry: g,
          net: captured.net);
      final sw = Stopwatch()..start();
      placed = pass.place(f0, anchor, anchor, wallNowS: i / 60);
      final t = sw.elapsedMicroseconds.toDouble();
      if (i >= 120) us.add(t);
    }
    report('agent pass, $n vehicles ($onConnectors on connectors) over '
        '$lanes lanes and $cons connectors (no pedestrians in slice 1): '
        '$placed placed; a frame median ${f(percentile(us, 0.5), 0)} us, p95 '
        '${f(percentile(us, 0.95), 0)} us, p99 ${f(percentile(us, 0.99), 0)} '
        'us, worst ${f(percentile(us, 1), 0)} us');
    expect(placed, n, reason: 'every vehicle in range and under the cap');
    if (kPerf) {
      expect(percentile(us, 0.95), lessThanOrEqualTo(1000),
          reason: '§15.1: the render pass ≤ 1 ms');
    }
  }, skip: benchSkip, timeout: benchTimeout);
}
