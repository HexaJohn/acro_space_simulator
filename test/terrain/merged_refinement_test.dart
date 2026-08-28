// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
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

  test('a cutFill corridor refines its SHOULDERS, not a circle around it', () {
    // REGRESSION: cutFill's lateralReachM includes the corridor half-length,
    // and the generic edge ring used it as a circle radius around the
    // midpoint — every target landed on untouched ground a half-length away
    // while the falloff shoulders along the corridor got nothing.
    const r = 6371000.0;
    final start = Vector3(r, -120, 0);
    final end = Vector3(r, 120, 90);
    final road = TerrainBrush.cutFill(
        startBF: start,
        endBF: end,
        radiusM: 6,
        datumRadiusM: r,
        datumRadiusEndM: r,
        falloffM: 8);
    final targets = refinementsFor(road, r, 128, maxLevel: 20);
    expect(targets, isNotEmpty);

    final a = (end - start).normalized;
    final len = (end - start).length;
    final lat = 6.0 + 8.0; // radiusM + falloffM
    var minProj = double.infinity, maxProj = double.negativeInfinity;
    for (final t in targets) {
      // Where the target's ray meets the corridor's altitude shell.
      final p = t.direction * r;
      final rel = p - start;
      final along = rel.dot(a);
      final off = (rel - a * along).length;
      expect(off, lessThan(lat * 2.5),
          reason: 'target sits ${off.toStringAsFixed(0)} m off-axis — the '
              'ring is circumscribing the corridor again');
      minProj = math.min(minProj, along);
      maxProj = math.max(maxProj, along);
    }
    expect(maxProj - minProj, greaterThan(len * 0.8),
        reason: 'targets must run the corridor\'s length, not cluster');
  });

  test('a same-lineage shallower target is subsumed by the deeper one', () {
    // REGRESSION: the dedup key embedded the level, so a big crater's centre
    // target (shallow) and a small crater's centre target (deep) at the same
    // spot never collided and BOTH were kept, even though splitting to the
    // deep cell passes through the shallow one's cell on the way down.
    final centre = Vector3(6371000, 0, 0);
    final big = TerrainBrush.crater(
        contactBF: centre, normalBF: Vector3(1, 0, 0), radiusM: 400, depthM: 40);
    final small = TerrainBrush.crater(
        contactBF: centre, normalBF: Vector3(1, 0, 0), radiusM: 12, depthM: 3);
    final merged = mergedRefinementsFor([big, small], 6371000, 128, maxLevel: 20);
    final cells = [
      for (final t in merged) chunkAt(t.direction, t.level),
    ];
    for (final c in cells) {
      final ancestors = c.ancestors.toSet();
      for (final other in cells) {
        expect(ancestors.contains(other), isFalse,
            reason: '$other is an ancestor of $c — the deeper target already '
                'subsumes it and it should have been collapsed');
      }
    }
  });

  test('the cap starves old edits, never the newest', () {
    // REGRESSION: hitting the cap used to `break` out of the whole brush
    // loop, so a fresh impact AFTER a dense colony contributed zero targets —
    // the newest, most player-visible edit was the one dropped.
    const r = 6371000.0;
    final pads = [
      for (var i = 0; i < 40; i++)
        TerrainBrush.pad(
            centreBF: Vector3(r, (i % 8) * 300.0 - 1000, (i ~/ 8) * 300.0 - 500),
            radiusM: 4, // small pad -> deep level -> many distinct cells
            datumRadiusM: r,
            falloffM: 8,
            maxCutM: 10),
    ];
    final freshDir = Vector3(0.9, 0.42, 0.11).normalized;
    final fresh = TerrainBrush.crater(
        contactBF: freshDir * r,
        normalBF: freshDir,
        radiusM: 16,
        depthM: 6,
        rimHeightM: 1);
    final merged = mergedRefinementsFor([...pads, fresh], r, 128,
        maxLevel: 20, cap: 8);
    final nearFresh =
        merged.where((t) => t.direction.dot(freshDir) > 0.9999).length;
    expect(nearFresh, greaterThan(0),
        reason: 'the newest edit lost all its refinement to the cap');
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
