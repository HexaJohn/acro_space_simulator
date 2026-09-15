// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_join.dart';
// Traffic is read here, never changed: the windows are road side's promise
// to the lane graph traffic builds.
import 'package:acro_space_simulator/domain/colony/city/traffic/access_points.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';

/// Acceptance test A2 (docs/plans/site-access.md §7.9, V1, slice R1): every
/// kerb cut lies inside `[edgeLaneS0 + 6, edgeLaneS1 − 6]` of every edge
/// that serves its piece, on the lane graph of every override the player can
/// set; `AccessPoint.sOn` never clamps a cut join; and every node's reserve
/// covers the stop line of the control it takes.
void main() {
  /// Every way the Junctions view can say something about a junction, laid
  /// over every junction of [g] at once.
  Map<String, List<JunctionOverride>> overridesOf(RoadGraph g) {
    final junctions = [for (final n in g.nodes) if (n.legs.length >= 3) n];
    return {
      'the warrant': const [],
      'lights on': [
        for (final n in junctions) JunctionOverride(at: n.at, lights: true)
      ],
      'lights off': [
        for (final n in junctions) JunctionOverride(at: n.at, lights: false)
      ],
      'every leg stops': [
        for (final n in junctions)
          JunctionOverride(
              at: n.at, stopHeadings: [for (final l in n.legs) l.heading])
      ],
      'no leg stops': [
        for (final n in junctions)
          JunctionOverride(at: n.at, lights: false, stopHeadings: const [])
      ],
    };
  }

  void check(String name, RoadGraph built) {
    for (final MapEntry(key: kind, value: overrides)
        in overridesOf(built).entries) {
      final g = built.withOverrides(overrides);
      final lg = LaneGraphBuilder.build(g);
      final why = '$name, $kind';
      expect(identical(g.kerbWindows, built.kerbWindows), isTrue, reason: why);

      // The reserve covers whatever stop line the node now has.
      for (var n = 0; n < g.nodeCount; n++) {
        expect(nodeReserveM(g.nodes[n]),
            greaterThanOrEqualTo(lg.controls.stopBack[n] - 1e-4),
            reason: '$why: node $n ${lg.kindOf(n)}');
      }

      var cuts = 0;
      for (var j = 0; j < g.joinCount; j++) {
        if (g.joinFlags[j] & kJoinCut == 0) continue;
        cuts++;
        final p = g.joinPiece[j];
        final s = g.joinS[j], m = g.joinRoomM[j];
        expect(m, greaterThanOrEqualTo(kJoinMinRoomM - 1e-4));
        for (final e in [g.pieceFwdEdge[p], g.pieceBwdEdge[p]]) {
          if (e < 0) continue;
          final t = lg.travelArc(e, s);
          expect(t - m, greaterThanOrEqualTo(lg.edgeLaneS0[e] + 6 - 1e-3),
              reason: '$why: slot $j at $s ± $m on edge $e');
          expect(t + m, lessThanOrEqualTo(lg.edgeLaneS1[e] - 6 + 1e-3),
              reason: '$why: slot $j at $s ± $m on edge $e');
        }
      }
      expect(cuts, greaterThan(0), reason: why);

      // A lot's access point meets its lane where its slot is: sOn never
      // clamps a cut join.
      for (var i = 0; i < g.lotCount; i++) {
        final k = g.lotJoinStart[i];
        if (k == g.lotJoinStart[i + 1]) continue;
        if (g.joinFlags[k] & kJoinCut == 0) continue;
        final a = AccessPoints.ofLotIndex(lg, i)!;
        for (final e in [a.fwdEdge, a.bwdEdge]) {
          if (e < 0) continue;
          expect(a.sOn(lg, e), lg.travelArc(e, g.joinS[k]),
              reason: '$why: ${g.lotIds[i]}');
        }
      }
    }
  }

  test('the starter kit, a signalised crossing and a grid', () {
    check('starter kit', starterKit().roadGraph);
    check('signalised', signalised().roadGraph);
    check('grid', grid(3).roadGraph);
  });

  test('a generated core and its sprawl, roundabouts and all', () {
    final core = const CityGenerator()
        .generate(const CityGenSpec(blocksAcross: 4, seed: 5),
            bodies: fixtureBodies)
        .roadGraph;
    check('4-block core', core);
    final sprawl = const CityGenerator()
        .generate(const CityGenSpec(blocksAcross: 4, seed: 5, sprawlMiles: 2),
            bodies: fixtureBodies)
        .roadGraph;
    expect(sprawl.nodes.where((n) => n.control == JunctionControl.roundabout),
        isNotEmpty);
    check('2-mile sprawl', sprawl);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
