// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_lod.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// Refinement for a CITY, not for a crater.
///
/// Forced refinement was built for impacts: a handful of small edits, each
/// deserving its own island of deep quadtree. A colony hands it one brush per
/// building — a six-block city emits 1,719 and asked for 15,471 targets down
/// to level 17, which is a great deal of very fine ground to mesh for
/// somewhere that ends up under a house.
void main() {
  final system = RealSolarSystem.build();
  final bodies = system.all.where((b) => !b.isStar).toList();

  List<TerrainBrush> cityBrushes({int blocks = 6}) {
    final sim = const CityGenerator().generate(
        CityGenSpec(blocksAcross: blocks, buildFraction: 1.0),
        bodies: bodies);
    final body = system.body(sim.body.id)!;
    final edits = InMemoryTerrainEditsRepository();
    for (final p in const CityTerrainShaper().pending(
      sim,
      bodyRadiusM: body.radius,
      groundRadiusAt: (d) {
        final f = body.terrainFieldWith(edits.forBody(body.id));
        return f == null ? body.radius : f.groundRadiusAt(d.x, d.y, d.z);
      },
    )) {
      edits.record(body.id, p.brush);
      sim.shapedTerrain.add(p.key);
    }
    return edits.forBody(body.id)!.all.toList();
  }

  test('a city asks for a fraction of what it used to', () {
    final body = system.all.firstWhere((b) => b.id.value == 'earth');
    final brushes = cityBrushes();
    expect(brushes.length, greaterThan(500), reason: 'a real city, not a toy');

    var unmerged = 0;
    for (final b in brushes) {
      unmerged += refinementsFor(b, body.radius, 128,
              voxelsAcrossBrush: 8, maxLevel: 20)
          .length;
    }
    final merged = mergedRefinementsFor(brushes, body.radius, 128,
        voxelsAcrossBrush: 8, maxLevel: 20);

    // Measured: 1,719 brushes, 13,753 targets unmerged, 325 merged — a 42x
    // collapse. The bound is deliberately loose; the point is the order of
    // magnitude, not the exact figure, which moves with the layout.
    expect(merged.length, lessThan(unmerged ~/ 8),
        reason: 'merging must collapse the target set, not tidy it');
  });

  test('a levelled pad refines its EDGE, not its flat middle', () {
    // A plane meshes exactly at any level. Only the falloff ring, where the
    // pad bends back into natural ground, needs resolution.
    final centre = Vector3(6371000, 0, 0);
    final pad = TerrainBrush.pad(
        centreBF: centre,
        radiusM: 30,
        datumRadiusM: 6371000,
        falloffM: 8,
        maxCutM: 20);
    final targets = refinementsFor(pad, 6371000, 128, maxLevel: 20);
    expect(targets, isNotEmpty, reason: 'the rim still needs refining');
    for (final t in targets) {
      // Nothing sits at the centre any more.
      expect((t.direction - centre.normalized).length, greaterThan(1e-9),
          reason: 'the flat interior was refined');
    }
  });

  test('a crater keeps its fine interior', () {
    // Curved throughout, so the middle genuinely needs the resolution.
    final centre = Vector3(6371000, 0, 0);
    final crater = TerrainBrush.crater(
        contactBF: centre,
        normalBF: Vector3(1, 0, 0),
        radiusM: 30,
        depthM: 8,
        rimHeightM: 2);
    final targets = refinementsFor(crater, 6371000, 128, maxLevel: 20);
    final atCentre = targets
        .where((t) => (t.direction - centre.normalized).length < 1e-9)
        .length;
    expect(atCentre, 1, reason: 'a crater must still refine its bowl');
  });

  test('merging keeps the deepest level asked for a leaf', () {
    final centre = Vector3(6371000, 0, 0);
    final shallow = TerrainBrush.crater(
        contactBF: centre,
        normalBF: Vector3(1, 0, 0),
        radiusM: 400,
        depthM: 40);
    final deep = TerrainBrush.crater(
        contactBF: centre, normalBF: Vector3(1, 0, 0), radiusM: 12, depthM: 3);
    final merged =
        mergedRefinementsFor([shallow, deep], 6371000, 128, maxLevel: 20);
    final deepest = merged.map((t) => t.level).reduce((a, b) => a > b ? a : b);
    final alone = refinementsFor(deep, 6371000, 128, maxLevel: 20)
        .map((t) => t.level)
        .reduce((a, b) => a > b ? a : b);
    expect(deepest, greaterThanOrEqualTo(alone),
        reason: 'a merge must never refine LESS than a brush needed');
  });
}
