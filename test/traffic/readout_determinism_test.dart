// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic_readout.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// Looking at the colony changes nothing in it (docs/plans/agent-traffic.md
/// §17.4, D47).
///
/// The views ask the readout whenever they draw: the road tool's Routes view
/// on the render side, a panel on a rebuild, a click's inspector. Those
/// moments depend on the frame rate and on what the player has open, never
/// on the simulation. So a colony whose views ask every question about
/// every lot and road between every two ticks, and one nobody looks at, must
/// keep one history: the same agents to the bit, the same pictures, and the
/// same answer to every question at every tick.
///
/// Fed the same ticks and the same player edits, three colonies with their
/// own agents on, ticked through their own advance so the growth, tax and
/// fire gates read the agents:
///
/// - BUSY asks everything, three times over, after each tick and BEFORE the
///   tick's edit is handled — a frame drawn before the click;
/// - STILL is asked only once, after the edit, where its own next tick's tax
///   line would ask anyway, to compare its answers;
/// - SILENT is never asked a readout question until the end.
///
/// A pass pumped by its readers ran its work when the first of them asked,
/// on the colony as it stood then: BUSY's pass read the lots before the edit
/// and STILL's after it. Against that readout this test failed at the first
/// picture (2 s, the average land value), and the agents themselves had
/// parted by 151.5 s, through the growth the noise gate let through.
void main() {
  // Ten times the design's demand, so the town has traffic to measure.
  setUp(() => AgentTuning.commuteRatePerResident = 0.004);
  tearDown(AgentTuning.reset);

  test('asking every readout question between every tick changes neither '
      'the agents, nor the pictures, nor any answer', () {
    final busy = town(agentTraffic: true);
    final still = town(agentTraffic: true);
    final silent = town(agentTraffic: true);
    final colonies = [busy, still, silent];
    for (final c in colonies) {
      expect(identical(c.trafficReadout, c.agents.readout), isTrue);
      // Growth under full demand, so what the gates read reaches the lots,
      // the building table and the commuters.
      c.infiniteDemand = true;
    }
    // The lots the edits toggle, and every id a view could ask about — an
    // unknown lot and road among them — the same in all three.
    final toggled = [
      for (final p in busy.layout.autoParcels)
        if (p.use != ParcelUse.unzoned) p.id,
    ];
    expect(toggled.length, greaterThan(10));

    var edits = 0, differed = 0;
    for (var tick = 0; tick < _ticks; tick++) {
      for (final c in colonies) {
        c.advance(0.5);
      }
      for (var k = 0; k < 3; k++) {
        _answers(busy);
      }
      if (tick % 3 == 0) {
        final id = toggled[(tick ~/ 3) % toggled.length];
        for (final c in colonies) {
          _toggle(c, id, edits);
        }
        edits++;
      }
      final at = 'tick $tick (${(tick + 1) * 0.5} s)';
      expect(still.agents.digest(), busy.agents.digest(), reason: at);
      expect(silent.agents.digest(), busy.agents.digest(), reason: at);
      expect(still.trafficReadout.passes, busy.trafficReadout.passes,
          reason: at);
      expect(silent.trafficReadout.passes, busy.trafficReadout.passes,
          reason: at);
      final b = _answers(busy), s = _answers(still);
      expect(s.length, b.length, reason: at);
      for (var i = 0; i < b.length; i++) {
        if (s[i] != b[i]) {
          fail('$at: answer $i differs: ${s[i]} vs ${b[i]} '
              '(${_label(busy, i)})');
        }
      }
      if (tick > 0 && b.join() != _last) differed++;
      _last = b.join();
    }
    final b = _answers(busy), q = _answers(silent);
    for (var i = 0; i < b.length; i++) {
      if (q[i] != b[i]) {
        fail('at the end: answer $i differs: ${q[i]} vs ${b[i]} '
            '(${_label(busy, i)})');
      }
    }
    // A test of nothing if nothing moved.
    expect(busy.agents.stats.spawned, greaterThan(20));
    expect(busy.agents.readout.reach.hasFields, isTrue);
    expect(edits, greaterThan(100));
    expect(differed, greaterThan(10),
        reason: 'the answers moved with the traffic and the edits');
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// Colony ticks the test runs: twenty minutes of colony time in 0.5 s ticks,
/// past the ten-minute flow window.
const int _ticks = 2400;

String _last = '';

/// The player's edit on lot [id], the [n]th: whatever stands there torn
/// down and the lot unzoned; or, unzoned, zoned again — homes or shops by
/// turns — to grow under demand past the noise and delivery gates, which
/// read the agents.
void _toggle(CitySim c, String id, int n) {
  final lot = c.layout.parcelById(id);
  if (lot == null) return;
  if (lot.use != ParcelUse.unzoned) {
    c.clearParcel(id);
  } else {
    c.layout.setUse(
        id, n.isEven ? ParcelUse.residential : ParcelUse.commercial);
  }
}

/// Every question the readout answers, about every lot and road of [c] and
/// an id of each it never saw, in one fixed order.
List<Object> _answers(CitySim c) {
  final r = c.trafficReadout;
  final out = <Object>[
    r.hasRun,
    r.passes,
    r.peakCongestion,
    r.averageCongestion,
    r.averageLandValue,
    r.taxLandValueFactor,
  ];
  for (final id in [..._roads(c), 'road-nowhere']) {
    out
      ..add(r.congestionOf(id))
      ..add(r.volumeOf(id));
    for (final kinds in _kinds) {
      final routes = r.routesThrough(id, kinds: kinds);
      out.add(routes.length);
      for (final t in routes) {
        out
          ..add(t.kind.index)
          ..add(t.weight)
          ..add(t.roadIds.join('>'));
        for (final p in t.polyline) {
          out
            ..add(p.e)
            ..add(p.n);
        }
      }
    }
    out.add(r.routesThrough(id, limit: 1).length);
  }
  for (final id in [..._lots(c), 'lot-nowhere']) {
    out
      ..add(r.serviceReach(id))
      ..add(r.fireReach(id))
      ..add(r.deliveryReach(id))
      ..add(r.noiseOf(id))
      ..add(r.landValueOf(id));
  }
  return out;
}

const List<Set<TripKind>?> _kinds = [
  null,
  {TripKind.commuter},
  {TripKind.goods, TripKind.service},
];

List<String> _roads(CitySim c) => [for (final r in c.layout.roads) r.id];

List<String> _lots(CitySim c) => [for (final p in c.layout.parcels) p.id];

/// Which question answer [i] of [_answers] is, for a failure message.
String _label(CitySim c, int i) {
  const head = 6;
  if (i < head) return 'a colony-wide answer';
  final roads = [..._roads(c), 'road-nowhere'];
  // A road's answers vary in length with its routes: walked, not computed.
  final r = c.trafficReadout;
  var at = head;
  for (final id in roads) {
    final start = at;
    at += 2;
    for (final kinds in _kinds) {
      final routes = r.routesThrough(id, kinds: kinds);
      at += 1;
      for (final t in routes) {
        at += 3 + 2 * t.polyline.length;
      }
    }
    at += 1;
    if (i < at) return 'road $id, answer ${i - start}';
  }
  final lots = [..._lots(c), 'lot-nowhere'];
  final k = (i - at) ~/ 5;
  const names = ['service', 'fire', 'delivery', 'noise', 'land value'];
  return k < lots.length ? 'lot ${lots[k]}, ${names[(i - at) % 5]}' : '?';
}
