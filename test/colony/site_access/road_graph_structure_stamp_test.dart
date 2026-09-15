// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';

/// `RoadGraph.structureStamp` (docs/plans/site-access.md §2.3, §4.1, slice
/// R2): the stamp a plan's `graphStamp` holds. Equal across copies that share
/// the graph's structure, different after any structure change, and the same
/// number on every run.
void main() {
  test('copies sharing the structure stamp alike', () {
    final city = starterKit();
    final g = city.roadGraph;
    final junctions = [for (final n in g.nodes) if (n.legs.length >= 3) n];
    expect(junctions, isNotEmpty);
    final lit = g.withOverrides(
        [for (final n in junctions) JunctionOverride(at: n.at, lights: true)]);
    expect(identical(lit, g), isFalse);
    expect(lit.sharesStructureWith(g), isTrue);
    expect(lit.structureStamp, g.structureStamp);
    final stops = lit.withOverrides([
      for (final n in junctions)
        JunctionOverride(
            at: n.at, stopHeadings: [for (final l in n.legs) l.heading])
    ]);
    expect(stops.sharesStructureWith(g), isTrue);
    expect(stops.structureStamp, g.structureStamp);
    final refreshed = g.refreshedFor(city.layout);
    expect(refreshed, isNotNull);
    expect(refreshed!.structureStamp, g.structureStamp);
  });

  test('a road or a lot changed stamps differently', () {
    final city = starterKit();
    final before = city.roadGraph.structureStamp;
    // A new street: pieces, nodes, lots and slots all change.
    commit(city, const FixtureRoad([Vec2(-200, 150), Vec2(-100, 150)]));
    final after = city.roadGraph;
    expect(after.structureStamp, isNot(before));

    // Only a lot added, the roads as they were.
    final layout = city.layout;
    final g0 = RoadGraph.of(layout);
    expect(g0.structureStamp, after.structureStamp,
        reason: 'a rebuild of the same layout stamps the same');
    final added = layout.addManualParcel(const [
      Vec2(2000, 2000), Vec2(2040, 2000), Vec2(2040, 2040), Vec2(2000, 2040),
    ]);
    expect(added, isNotNull);
    final g1 = RoadGraph.of(layout);
    expect(g1.lotCount, g0.lotCount + 1);
    expect(g1.sharesStructureWith(g0), isFalse);
    expect(g1.structureStamp, isNot(g0.structureStamp));
  });

  test('the stamp is signed 32-bit and the same on every run', () {
    final a = starterKit().roadGraph.structureStamp;
    final b = starterKit().roadGraph.structureStamp;
    expect(a, b);
    expect(a, inInclusiveRange(-0x80000000, 0x7FFFFFFF));
    expect(town().roadGraph.structureStamp, a,
        reason: 'building on lots changes no structure');
  });
}
