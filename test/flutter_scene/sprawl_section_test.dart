// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/sprawl_plan.dart';
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/sprawl_section.dart';
import 'package:flutter_test/flutter_test.dart';

/// A section on the equator of a 6371 km world, its frame turned so local
/// up is the radial: z -> x, x -> -z.
SprawlSectionSnapshot section(SprawlUse use, {double density = 0.8, int seed = 7}) =>
    SprawlSectionSnapshot(
      colonyId: 'c',
      body: 'earth',
      px: 6371000,
      py: 0,
      pz: 0,
      qw: 0.7071067811865476,
      qx: 0,
      qy: 0.7071067811865476,
      qz: 0,
      sizeM: 1609,
      use: use.index,
      density: density,
      seed: seed,
    );

typedef Tris = ({int ground, int road, int walk, int solid, int glass});

Tris build(SprawlSectionSnapshot s, SprawlTier tier,
    {List<List<Vector3>> corridors = const []}) {
  final b = SprawlSectionBuilder(s, Vector3(6371000, 0, 0), null, corridors);
  final ground = MeshBuilder(),
      road = MeshBuilder(),
      walk = MeshBuilder(),
      solid = MeshBuilder(),
      glass = MeshBuilder();
  // The renderer pops parts from the end.
  final steps = b.steps(tier, ground, road, walk, solid, glass);
  while (steps.isNotEmpty) {
    steps.removeLast()();
  }
  int tris(MeshBuilder m) => m.build().indices.length ~/ 3;
  return (
    ground: tris(ground),
    road: tris(road),
    walk: tris(walk),
    solid: tris(solid),
    glass: tris(glass)
  );
}

void main() {
  test('far, a suburb is silhouettes on bare ground, not a coloured parcel',
      () {
    for (final use in [SprawlUse.residential, SprawlUse.commercial, SprawlUse.industrial]) {
      final far = build(section(use), SprawlTier.far);
      expect(far.ground, 0, reason: '${use.name} painted the ground');
      expect(far.road, 0, reason: '${use.name} drew streets from afar');
      expect(far.solid, greaterThan(200), reason: '${use.name} has no silhouettes');
    }
    // Fields ARE coloured parcels; a park is nothing from a height.
    expect(build(section(SprawlUse.farmland), SprawlTier.far).ground, greaterThan(0));
    final park = build(section(SprawlUse.parkland), SprawlTier.far);
    expect(park.solid + park.ground, 0);
  });

  test('every tier nearer adds detail', () {
    final s = section(SprawlUse.residential);
    final far = build(s, SprawlTier.far);
    final mid = build(s, SprawlTier.mid);
    final near = build(s, SprawlTier.near);
    final close = build(s, SprawlTier.close);
    expect(mid.solid, greaterThan(far.solid));
    expect(near.solid, greaterThan(mid.solid));
    expect(close.solid, greaterThan(near.solid));
    // Windows from near; nothing lit in a flat block.
    expect(mid.glass, 0);
    expect(near.glass, greaterThan(0));
    // Trees take their green off the ground palette from near; pools join
    // them up close, and driveways and the paths to the doors go on the
    // road material.
    expect(mid.ground, 0);
    expect(near.ground, greaterThan(0));
    expect(close.ground, greaterThanOrEqualTo(near.ground));
    expect(close.road, greaterThan(near.road + 100));
    // Streets whenever there are houses on them — lanes painted and every
    // crossing plated from mid, stop bars and signs from near; sidewalks
    // from near.
    expect(mid.road, greaterThan(0));
    expect(near.road, greaterThan(mid.road));
    expect(mid.walk, 0);
    expect(near.walk, greaterThan(1000));
    expect(far.walk, 0);
  });

  test('a section is the same every time it is grown', () {
    final s = section(SprawlUse.commercial, seed: 12);
    expect(build(s, SprawlTier.close), build(s, SprawlTier.close));
    expect(build(s, SprawlTier.far), build(s, SprawlTier.far));
    expect(build(section(SprawlUse.commercial, seed: 13), SprawlTier.far),
        isNot(build(s, SprawlTier.far)));
  });

  test('a corridor keeps the rows and the clutter out', () {
    final s = section(SprawlUse.residential);
    // An interstate east-west through the middle: in the section frame east
    // is -z, so the line runs along z at the section's centre.
    final corridor = [
      for (var z = -1000.0; z <= 1000; z += 100) Vector3(6371000, 0, z),
    ];
    for (final tier in SprawlTier.values) {
      final open = build(s, tier);
      final cut = build(s, tier, corridors: [corridor]);
      expect(cut.solid, lessThan(open.solid), reason: tier.name);
    }
  });

  test('a staked plot on the section stays empty', () {
    final s = section(SprawlUse.residential);
    // Half the section, in colony-local metres (this section is at the
    // origin): everything east of the middle is somebody's plot.
    final plot = [0.0, -900.0, 900.0, -900.0, 900.0, 900.0, 0.0, 900.0];
    final b = SprawlSectionBuilder(s, Vector3(6371000, 0, 0), null, const [],
        clearings: [plot]);
    final ground = MeshBuilder(),
        road = MeshBuilder(),
        walk = MeshBuilder(),
        solid = MeshBuilder(),
        glass = MeshBuilder();
    final steps = b.steps(SprawlTier.mid, ground, road, walk, solid, glass);
    while (steps.isNotEmpty) {
      steps.removeLast()();
    }
    final open = build(s, SprawlTier.mid);
    expect(solid.build().indices.length ~/ 3, lessThan(open.solid * 0.6));
    expect(b.inCorridor(400, 0), isTrue);
    expect(b.inCorridor(-400, 0), isFalse);
  });

  test('the streets are a network: turning circles, stops, a roundabout, '
      'and collectors that reach the highway only where the plan has a '
      'junction', () {
    final s = section(SprawlUse.residential);
    // The section is at the colony origin, so its section lines are at
    // ±half; the plan's junction for the south collector at e = -size/4.
    final b = SprawlSectionBuilder(s, Vector3(6371000, 0, 0), null, const []);
    final half = s.sizeM / 2;
    final nodeAt = b.at(-s.sizeM / 4, -half) + Vector3(6371000, 0, 0);
    final withNode = SprawlSectionBuilder(s, Vector3(6371000, 0, 0), null, const [],
        nodePoints: [nodeAt]);
    expect(withNode.hasNodeAt(-s.sizeM / 4, -half), isTrue);
    expect(withNode.hasNodeAt(s.sizeM / 4, -half), isFalse);
    expect(b.hasNodeAt(-s.sizeM / 4, -half), isFalse);
    // With the junction, the collector runs the extra distance to the
    // section line: more road, and no turning circle at that end.
    final road = MeshBuilder(), roadN = MeshBuilder();
    final steps = b.steps(SprawlTier.mid, MeshBuilder(), road, MeshBuilder(),
        MeshBuilder(), MeshBuilder());
    while (steps.isNotEmpty) {
      steps.removeLast()();
    }
    final stepsN = withNode.steps(SprawlTier.mid, MeshBuilder(), roadN,
        MeshBuilder(), MeshBuilder(), MeshBuilder());
    while (stepsN.isNotEmpty) {
      stepsN.removeLast()();
    }
    final tris = road.build().indices.length ~/ 3;
    final trisN = roadN.build().indices.length ~/ 3;
    // One turning circle fewer (12 triangles), less whatever the extra
    // forty-five metres of street add in samples.
    expect(trisN, lessThan(tris));
    expect(trisN, greaterThanOrEqualTo(tris - 12));
    // Twelve streets each way: 121 crossings, four of them roundabouts.
    expect(SprawlSection.streetsAcrossFor(SprawlUse.residential), 12);
  });

  test('next to the core, the streets are the plat\'s lines and start just '
      'inside its outline', () {
    // A section at the origin with a 600 m core in its middle, carrying a
    // 200 x 100 m grid.
    final linesE = [for (var k = -3; k <= 3; k++) k * 200.0];
    final linesN = [for (var k = -7; k <= 7; k++) k * 100.0];
    final s = SprawlSectionSnapshot(
      colonyId: 'c',
      body: 'earth',
      px: 6371000,
      py: 0,
      pz: 0,
      qw: 0.7071067811865476,
      qx: 0,
      qy: 0.7071067811865476,
      qz: 0,
      sizeM: 1609,
      use: SprawlUse.residential.index,
      density: 0.8,
      seed: 7,
      coreRadiusM: 600,
      linesE: linesE,
      linesN: linesN,
      collectorsE: [-400, 400],
      collectorsN: [-400, 400],
    );
    final b = SprawlSectionBuilder(s, Vector3(6371000, 0, 0), null, const []);
    expect(b.continuesCoreGrid, isTrue);
    final road = MeshBuilder();
    final steps = b.steps(SprawlTier.mid, MeshBuilder(), road, MeshBuilder(),
        MeshBuilder(), MeshBuilder());
    while (steps.isNotEmpty) {
      steps.removeLast()();
    }
    final mesh = road.build();
    expect(mesh.triangleCount, greaterThan(0));
    // The street vertex nearest the core sits just INSIDE the outline —
    // overlapping the downtown street it carries on — and none is deeper.
    var nearest = double.infinity;
    for (var v = 0; v < mesh.vertexCount; v++) {
      // Section frame: local e is -z, local n is y (see [section]).
      final e = -mesh.positions[v * 3 + 2] / 1e-3;
      final n = mesh.positions[v * 3 + 1] / 1e-3;
      final r = math.sqrt(e * e + n * n);
      if (r < nearest) nearest = r;
    }
    // The centreline starts twelve metres in; the ribbon's inner corner on
    // an oblique line is up to a half width nearer the centre than that.
    expect(nearest, greaterThan(600 - 12 - 3.5 - 1));
    expect(nearest, lessThan(600 - 12 + 12), reason: 'the start is found to the metre');
  });

  test('an industrial park: sheds in the blocks, off the streets, with a '
      'yard, a driveway and a path each', () {
    final s = section(SprawlUse.industrial, density: 1.0);
    final b = SprawlSectionBuilder(s, Vector3(6371000, 0, 0), null, const []);
    final road = MeshBuilder(), solid = MeshBuilder();
    final steps = b.steps(SprawlTier.mid, MeshBuilder(), road, MeshBuilder(),
        solid, MeshBuilder());
    while (steps.isNotEmpty) {
      steps.removeLast()();
    }
    // Four streets each way: lines at -402, 0, 402 on each axis. No shed
    // vertex lies within a street's half width and sidewalk of a line.
    final lines = [-1609 / 4, 0.0, 1609 / 4];
    final mesh = solid.build();
    expect(mesh.triangleCount, greaterThan(0));
    for (var v = 0; v < mesh.vertexCount; v++) {
      final e = -mesh.positions[v * 3 + 2] / 1e-3;
      final n = mesh.positions[v * 3 + 1] / 1e-3;
      for (final l in lines) {
        expect((e - l).abs(), greaterThan(5.0), reason: 'a shed on a street');
        expect((n - l).abs(), greaterThan(5.0), reason: 'a shed on a street');
      }
    }
    // Yards, driveways and paths are paving: on the road material, beyond
    // the streets themselves.
    final streetsOnly = MeshBuilder();
    final s2 = section(SprawlUse.industrial, density: 0.0);
    final steps2 = SprawlSectionBuilder(s2, Vector3(6371000, 0, 0), null, const [])
        .steps(SprawlTier.mid, MeshBuilder(), streetsOnly, MeshBuilder(),
            MeshBuilder(), MeshBuilder());
    while (steps2.isNotEmpty) {
      steps2.removeLast()();
    }
    expect(road.build().triangleCount,
        greaterThan(streetsOnly.build().triangleCount + 50));
  });

  test('a park is trees near and nothing from a height', () {
    final s = section(SprawlUse.parkland);
    final mid = build(s, SprawlTier.mid);
    expect(mid.solid + mid.ground, 0);
    final near = build(s, SprawlTier.near);
    expect(near.ground, greaterThan(500), reason: 'crowns');
    expect(near.solid, greaterThan(0), reason: 'trunks');
  });
}
