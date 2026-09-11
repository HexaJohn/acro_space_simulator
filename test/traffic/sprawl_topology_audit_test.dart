// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_mesher.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// What the generator's sprawl looks like to a vehicle (docs/plans/
/// agent-traffic.md §17.5, C6).
///
/// Generated colonies get agents only in slice 11, and that slice is gated
/// on this audit reaching its targets. Until then it PINS today's figures as
/// upper bounds — a change to the generator or to the road graph that makes
/// the network worse for traffic fails here — and prints what it found for
/// the road agent, whose network it is.
///
/// The sprawl is city_generator_test's: a four-block core and twelve miles
/// of sprawl round it.
void main() {
  late CitySim city;
  late RoadGraph g;
  late LaneGraph lg;
  setUpAll(() {
    city = const CityGenerator().generate(
        const CityGenSpec(blocksAcross: 4, seed: 5, sprawlMiles: 12),
        bodies: fixtureBodies);
    g = city.roadGraph;
    lg = LaneGraphBuilder.build(g);
  });

  test('the lane graph of a whole sprawl has a lane, and a way on, everywhere',
      () {
    expect(lg.edgeCount, g.edgeCount);
    for (var e = 0; e < lg.edgeCount; e++) {
      expect(lg.edgeLaneCount[e], greaterThan(0), reason: 'edge $e');
      if (lg.moveStart[e + 1] == lg.moveStart[e]) continue;
      for (var k = 0; k < lg.edgeLaneCount[e]; k++) {
        final l = lg.laneOf(e, k);
        expect(lg.laneConStart[l + 1], greaterThan(lg.laneConStart[l]),
            reason: 'lane $k of edge $e can leave by no connector');
      }
    }
  });

  test('topology, against today\'s figures', () {
    var rampEnds = 0, unjoinedMerges = 0, decks = 0;
    final gaps = <double>[];
    for (final node in g.nodes) {
      if (node.legs.length != 1) continue;
      final kind = lg.kindOf(node.id);
      if (kind == NodeControlKind.danglingDeck) decks++;
      final leg = node.legs.single;
      if (leg.roadClass != RoadClass.ramp) continue;
      rampEnds++;
      // A ramp that ARRIVES at a dead end is a merge that never joined its
      // mainline; one that leaves from a dead end, a diverge.
      if (leg.inbound) unjoinedMerges++;
      gaps.add(_gapBeside(g, node));
    }
    var lotsWithout = 0;
    for (var i = 0; i < g.lotCount; i++) {
      if (g.lotPiece[i] < 0) lotsWithout++;
    }
    var sitesWithout = 0;
    for (final cell in city.occupiedCells()) {
      final fp = city.parcelForCell(cell.key, cell.value);
      if (g.attachFootprint(fp.polygon, centroid: fp.centroid) == null) {
        sitesWithout++;
      }
    }
    var stranded = 0;
    for (var e = 0; e < lg.edgeCount; e++) {
      if (lg.edgeInMainScc[e] == 0) stranded++;
    }
    gaps.sort();
    final buckets = <String, int>{};
    for (final d in gaps) {
      final b = d < 4
          ? '0-4 m'
          : d < 8
              ? '4-8 m'
              : d < 16
                  ? '8-16 m'
                  : d < 32
                      ? '16-32 m'
                      : '32 m+';
      buckets[b] = (buckets[b] ?? 0) + 1;
    }
    // ignore: avoid_print
    print('sprawl topology (for the road agent, C6): '
        '$rampEnds dangling ramp ends ($unjoinedMerges unjoined merges), '
        '$decks dangling decks, $lotsWithout of ${g.lotCount} lots and '
        '$sitesWithout grid sites with no road, $stranded of '
        '${lg.edgeCount} edges outside the main strongly connected part.\n'
        'Gap from each dangling ramp end to the nearest other road\'s edge: '
        '$buckets (${gaps.map((d) => d.toStringAsFixed(1)).join(', ')} m)');

    // Targets are 0; the bounds are what the sprawl has today.
    expect(rampEnds, lessThanOrEqualTo(8), reason: 'target 0');
    expect(unjoinedMerges, lessThanOrEqualTo(4), reason: 'target 0');
    expect(decks, lessThanOrEqualTo(0));
    expect(lotsWithout, lessThanOrEqualTo(2));
    expect(sitesWithout, lessThanOrEqualTo(0));
  });

  test('where the tiles and the graph see one junction\'s legs alike, they '
      'plan it alike', () {
    Vector3 v(Vec2 p) => Vector3(p.e, p.n, 0);
    final ends = <RoadEnd>[];
    for (final r in city.layout.roads) {
      final cls = r.roadClass;
      if (!cls.joinsJunctions) continue;
      final s = city.layout.roadIndex.byId(r.id)!.samples;
      final pts = r.reversed ? s.reversed.toList() : s;
      ends.add(RoadEnd(v(pts.first), v(pts[1]), r.halfWidth, cls,
          paved: cls.paved, collector: r.collector, isStart: true));
      ends.add(RoadEnd(v(pts.last), v(pts[pts.length - 2]), r.halfWidth, cls,
          paved: cls.paved, collector: r.collector));
    }
    var sameLegs = 0;
    final report = <String>[];
    for (final j in RoadMesher.junctionsFromEnds(ends)) {
      final node = g.nodeNear(Vec2(j.at.x, j.at.y), withinM: 8);
      if (node == null) {
        report.add('the tiles draw ${j.control.name} at '
            '(${j.at.x.toStringAsFixed(1)}, ${j.at.y.toStringAsFixed(1)}), '
            'where the graph has no node');
        continue;
      }
      final a = [for (final l in j.legs) l.roadClass.index]..sort();
      final b = [for (final l in node.legs) l.roadClass.index]..sort();
      if (a.length == b.length &&
          [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x)) {
        expect(node.control, j.control, reason: 'at ${node.at}');
        sameLegs++;
      } else if (node.control != j.control) {
        report.add('at ${node.at}: the graph plans ${node.control.name} over '
            '${[for (final l in node.legs) l.roadClass.name]}, the tiles draw '
            '${j.control.name} over ${[for (final l in j.legs) l.roadClass.name]}');
      }
    }
    // ignore: avoid_print
    print('junction plans, tiles against the graph (for the road agent, C1): '
        '$sameLegs agree; ${report.length} differ:\n${report.join('\n')}');
    expect(sameLegs, greaterThan(1000));
    expect(report.length, lessThanOrEqualTo(4),
        reason: 'the viaduct\'s ends, joined to the crossings under them');
  });
}

/// Metres from [node] to the edge of the nearest road that is not its own.
double _gapBeside(RoadGraph g, RoadNode node) {
  final own = node.legRoadIds.single;
  var best = double.infinity;
  for (var r = 0; r < g.roadCount; r++) {
    if (g.roads[r].id == own) continue;
    final rec = g.roadRecs[r];
    final box = rec.box.grow(64);
    final p = node.at;
    if (p.e < box.minE || p.e > box.maxE || p.n < box.minN || p.n > box.maxN) {
      continue;
    }
    final d = rec.distanceTo(p) - g.roads[r].halfWidth;
    if (d < best) best = d;
  }
  return best;
}
