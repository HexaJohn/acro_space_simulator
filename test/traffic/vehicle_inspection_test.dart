// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_inspection.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// The route inspector's domain half (docs/plans/agent-traffic.md §13.9,
/// §18 slice 2): its words are `CityAgents.describe`'s — the map the
/// `vehicle=` dev hook dumps — so the sheet and the hook agree; the pick
/// finds the car the frame drew; the road ahead starts where the car is.
void main() {
  tearDown(AgentTuning.reset);

  /// A built town whose own agents have run long enough for cars to be out
  /// on its streets, and the frame row of one of them, on a lane.
  (CitySim, CityAgents, int row) townWithCars() {
    final city = town(agentTraffic: true);
    final a = city.agents;
    for (var i = 0; i < 400; i++) {
      city.advance(0.5);
      final f = a.frame;
      for (var row = 0; row < f.count; row++) {
        if (f.handle[row] >= 0 &&
            f.elem[row] >= 0 &&
            f.elem[row] < a.laneGraph!.laneCount &&
            a.describe(f.handle[row]) != null) {
          return (city, a, row);
        }
      }
    }
    fail('no car took to the streets in 200 s');
  }

  test('the inspection reads CityAgents.describe, and the vehicle= hook\'s '
      'JSON of it reads the same', () {
    final (city, a, row) = townWithCars();
    final h = a.frame.handle[row];
    final v = VehicleInspection.of(a, h, roadName: city.roadNameOf)!;
    expect(v.describe, equals(a.describe(h)),
        reason: 'the one domain function, unchanged');

    // What `ext.acro.citygame?vehicle=H` sends: `did.vehicle` is
    // `a.describe(h)`, JSON-encoded with the rest of the status.
    final wire = jsonDecode(jsonEncode({
      'did': {'vehicle': a.describe(h)},
    })) as Map<String, Object?>;
    final hook = VehicleInspection.fromDescribe(
        (wire['did']! as Map)['vehicle'] as Map<String, Object?>,
        roadName: city.roadNameOf)!;
    expect(hook.text, v.text, reason: 'the sheet and the hook agree');
    expect(hook.lines, hasLength(5));

    final d = a.describe(h)!;
    expect(v.handle, h);
    expect(v.kind, d['kind']);
    expect(v.state, d['state']);
    expect(v.from, d['from']);
    expect(v.to, d['to']);
    expect(v.speedMps, d['v']);
    expect(v.text, contains(VehicleInspection.words(d['kind']! as String)));
    expect(v.text, contains('${d['from']} → ${d['to']}'));
    expect(v.text, contains('${((d['v']! as double) * 3.6).round()} km/h'));
    final firstRoad = ((d['route']! as List).first as Map)['road']! as String;
    expect(v.remainingRoads.first, city.roadNameOf(firstRoad));
    for (var i = 1; i < v.remainingRoads.length; i++) {
      expect(v.remainingRoads[i], isNot(v.remainingRoads[i - 1]),
          reason: 'one entry per stretch of road');
    }
    expect(VehicleInspection.of(a, -5), isNull, reason: 'no such vehicle');
  });

  test('words: an enum name as the inspector says it', () {
    expect(VehicleInspection.words('car'), 'Car');
    expect(VehicleInspection.words('garbageTruck'), 'Garbage truck');
    expect(VehicleInspection.words('holdAtEdgeEnd'), 'Hold at edge end');
  });

  test('the pick finds the car the frame drew, and nothing off the road', () {
    final (_, a, row) = townWithCars();
    final f = a.frame;
    final h = f.handle[row];
    final at = Float64List(4);
    expect(VehiclePicker.positionOn(a.laneGraph!, f.elem[row], f.s[row], at),
        isTrue);
    final picker = VehiclePicker();
    final p = Vec2(at[0], at[1]);
    // Every car within a metre of where this one stands — two cars can.
    final near = <int>{};
    for (var r = 0; r < f.count; r++) {
      if (f.handle[r] < 0 || f.elem[r] < 0) continue;
      final q = Float64List(4);
      VehiclePicker.positionOn(a.laneGraph!, f.elem[r], f.s[r], q);
      if (Vec2(q[0], q[1]).distanceTo(p) < 1) near.add(f.handle[r]);
    }
    expect(near, contains(h));
    expect(near, contains(picker.pick(a, p)));
    expect(near, contains(picker.pick(a, p + const Vec2(2, 1))),
        reason: 'within the reach');
    expect(picker.pick(a, p + const Vec2(5000, 5000)), -1, reason: 'far off');
    // On the lane it stands on: its centreline passes within a metre.
    final line = a.laneSpeeds.laneLine(f.elem[row], stepM: 1);
    final gap = line.map((q) => q.distanceTo(p)).reduce((x, y) => x < y ? x : y);
    expect(gap, lessThan(1.0));
  });

  test('the road ahead starts at the car\'s lane and runs on to its goal', () {
    final (_, a, row) = townWithCars();
    final f = a.frame;
    final h = f.handle[row];
    final ahead = VehiclePicker.routeAhead(a, h);
    expect(ahead.length, greaterThanOrEqualTo(2));
    final lane = a.laneSpeeds.laneLine(f.elem[row]);
    expect(ahead.first.distanceTo(lane.first), lessThan(1e-6),
        reason: 'from the stop bar behind it, on its own lane');
    expect(VehiclePicker.routeAhead(a, -5), isEmpty);
  });

  test('with agents off the pick asks nothing', () {
    final city = town();
    expect(VehiclePicker().pick(city.agents, const Vec2(0, 0)), -1);
  });
}
