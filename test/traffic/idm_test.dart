// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_mover.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_table.dart';
import 'package:flutter_test/flutter_test.dart';

import 'movement_fixture.dart';
import 'routing_fixture.dart';

/// Car-following (docs/plans/agent-traffic.md §5.3; §17.1 idm_test): the
/// model's own arithmetic, then cars on a road — held to the limit, queued
/// without overlap, stable at the 0.2 s sub-step, and never touching the
/// car ahead however suddenly it stops.
void main() {
  final car = AgentKind.car.index;
  final a = VehicleKinds.accel[car], hw = VehicleKinds.headwayS[car];
  final s0 = VehicleKinds.jamM[car], sab = VehicleKinds.sqrtAb[car];

  group('the model', () {
    test('the design table: a car pulls away at 1.4, brakes at 2.0, keeps '
        '1.2 s and 2 m; a semi 0.7, 1.6, 1.8 s and 3 m', () {
      expect(a, 1.4);
      expect(VehicleKinds.brake[car], 2.0);
      expect(hw, 1.2);
      expect(s0, 2.0);
      expect(sab, closeTo(math.sqrt(1.4 * 2.0), 1e-12));
      final semi = AgentKind.semi.index;
      expect(VehicleKinds.accel[semi], 0.7);
      expect(VehicleKinds.brake[semi], 1.6);
      expect(VehicleKinds.headwayS[semi], 1.8);
      expect(VehicleKinds.jamM[semi], 3.0);
      expect(VehicleKinds.speedFactor[semi], 0.90);
      expect(VehicleKinds.speedFactor[AgentKind.truck.index], 0.95);
      expect(VehicleKinds.speedFactor[AgentKind.bus.index], 0.95);
    });

    test('on a free road it pulls away at a, holds v0, and slows above it',
        () {
      expect(Idm.accel(0, 13.9, double.infinity, 0, a, hw, s0, sab), a);
      expect(Idm.accel(13.9, 13.9, double.infinity, 0, a, hw, s0, sab),
          closeTo(0, 1e-12));
      expect(Idm.accel(16, 13.9, double.infinity, 0, a, hw, s0, sab),
          lessThan(0));
    });

    test('at rest exactly s0 behind a standing car it neither creeps nor '
        'backs off, and closer it brakes', () {
      expect(Idm.accel(0, 13.9, s0, 0, a, hw, s0, sab), closeTo(0, 1e-12));
      expect(Idm.accel(0, 13.9, s0 / 2, 0, a, hw, s0, sab), lessThan(0));
      // Closing fast on a car ahead brakes harder than following it.
      final follow = Idm.accel(10, 13.9, 20, 0, a, hw, s0, sab);
      final closing = Idm.accel(10, 13.9, 20, 5, a, hw, s0, sab);
      expect(closing, lessThan(follow));
    });

    test('a stop inside the step is exact, and a step without one is the '
        'trapezium', () {
      final st = IdmStep()..run(1.0, -10, kStepS);
      expect(st.v, 0);
      expect(st.ds, closeTo(1.0 / 20, 1e-15), reason: 'v²/(2·10)');
      st.run(10, 1, kStepS);
      expect(st.v, closeTo(10.2, 1e-12));
      expect(st.ds, closeTo(2.02, 1e-12));
      st.run(0, -3, kStepS);
      expect(st.v, 0);
      expect(st.ds, 0);
    });
  });

  group('on the road', () {
    test('the speed limit is respected, and reached', () {
      final lg = straightRoad(lengthM: 2000);
      final e = edgeOf(lg, 'r0');
      final d = Drive(lg);
      final h = d.trip(e, 10, e, 1990, speedFactor: 1.05);
      final sl = d.slot(h);
      final v0 = lg.edgeLimit[e] * 1.05;
      var top = 0.0;
      while (d.table.isLive(h)) {
        d.step();
        if (!d.table.isLive(h)) break;
        final v = d.table.v[sl].toDouble();
        expect(v, lessThanOrEqualTo(v0 + 1e-4),
            reason: 't=${secondsOf(d.nowUs)} s');
        if (v > top) top = v;
      }
      expect(top, greaterThan(0.98 * v0));
      expect(d.arrivedHandles, [h], reason: 'it drove the length and stopped');
      expect(d.mover.lineStops, 0);
    });

    test('a single-lane queue settles behind a standing car without '
        'overlap, stable at h = 0.2 s', () {
      final lg = straightRoad(lengthM: 1500);
      final e = edgeOf(lg, 'r0');
      final d = Drive(lg);
      final block = d.trip(e, 1200, e, 1450);
      d.table.stall(block);
      final queue = <int>[
        for (var i = 0; i < 12; i++) d.trip(e, 1100.0 - 45 * i, e, 1450, speed: 8),
      ];
      expect(queue, everyElement(greaterThanOrEqualTo(0)));
      final v0 = lg.edgeLimit[e];
      // Long enough for the last to arrive and every one to settle; short
      // of the first stopper's 120 s stuck despawn.
      d.run(100, () {
        expect(occupancyErrors(d.table), isEmpty,
            reason: 't=${secondsOf(d.nowUs)} s');
        for (final h in queue) {
          final v = d.table.v[d.slot(h)];
          expect(v, inInclusiveRange(0, v0 + 1e-4));
        }
      });
      // Settled: all at rest, each s0 behind the one ahead.
      var ahead = block;
      for (final h in queue) {
        final sl = d.slot(h), p = d.slot(ahead);
        expect(d.table.isLive(h), isTrue);
        expect(d.table.v[sl], lessThan(0.05));
        final gap = d.table.s[p] - d.table.len[p] - d.table.s[sl];
        expect(gap, inInclusiveRange(s0 - 0.2, s0 + 0.6),
            reason: 'gap behind handle $ahead');
        ahead = h;
      }
    });

    test('a car ahead that stops dead: nobody behind ever touches it', () {
      final lg = straightRoad(lengthM: 2000);
      final e = edgeOf(lg, 'r0');
      final d = Drive(lg);
      final lead = d.trip(e, 400, e, 1950, speed: 11);
      final followers = <int>[
        for (var i = 1; i <= 8; i++) d.trip(e, 400.0 - 22 * i, e, 1950, speed: 11),
      ];
      expect(followers, everyElement(greaterThanOrEqualTo(0)));
      d.run(15, () => expect(occupancyErrors(d.table), isEmpty));
      d.table.stall(lead);
      var minGap = double.infinity;
      d.run(40, () {
        expect(occupancyErrors(d.table), isEmpty,
            reason: 't=${secondsOf(d.nowUs)} s');
        var ahead = lead;
        for (final h in followers) {
          final sl = d.slot(h), p = d.slot(ahead);
          final gap = d.table.s[p] - d.table.len[p] - d.table.s[sl];
          if (gap < minGap) minGap = gap;
          expect(d.table.v[sl], greaterThanOrEqualTo(0));
          ahead = h;
        }
      });
      expect(minGap, greaterThanOrEqualTo(0.1 - 1e-4));
      for (final h in followers) {
        expect(d.table.v[d.slot(h)], lessThan(0.05));
      }
    });
  });
}
