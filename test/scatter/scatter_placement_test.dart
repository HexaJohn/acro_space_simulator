// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/planetary/planet_surface.dart';
import 'package:acro_space_simulator/domain/scatter/scatter_instance.dart';
import 'package:acro_space_simulator/domain/scatter/scatter_layer.dart';
import 'package:acro_space_simulator/domain/scatter/scatter_placement.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_edits.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:flutter_test/flutter_test.dart';

/// A small, temperate, Earth-like world — small enough that a cell holds a
/// manageable number of props but large enough that the level maths is real.
TerrainField _field({TerrainEdits? edits}) => TerrainField(
      radius: 300000,
      amplitude: 900,
      featureScale: 40000,
      seed: 4242,
      edits: edits,
    );

const _surface = PlanetSurface(
  seed: 11,
  meanSurfaceTemperature: 288,
  albedo: 0.3,
  solarFlux: 1361,
);

ScatterPlacement _placement({TerrainEdits? edits, double vegetation = 1.0}) =>
    ScatterPlacement(
      field: _field(edits: edits),
      surface: _surface,
      bodySeed: 99,
      vegetationCap: vegetation,
    );

/// Cells at [layer]'s generation level, walked across one face.
List<ChunkKey> _cells(ScatterLayer layer, double radius, int count) {
  final level = layer.levelFor(radius);
  final side = 1 << level;
  return [
    for (var i = 0; i < count; i++)
      ChunkKey(CubeFace.posX, level, (side ~/ 2 + i) % side, side ~/ 2),
  ];
}

void main() {
  group('generation level', () {
    test('each layer lands on a level with a workable per-cell count', () {
      const radius = 6371000.0; // Earth
      for (final layer in ScatterLayers.all) {
        final level = layer.levelFor(radius);
        final cells = 6.0 * (1 << level) * (1 << level);
        final area = 4 * math.pi * radius * radius / cells;
        final perCell = area * layer.densityPerKm2 / 1e6;
        // Rounding the level moves this by at most 2x either way from the
        // target; anything outside that means the solve is wrong.
        expect(perCell, greaterThan(ScatterLayer.targetPerCell / 2.5),
            reason: '${layer.name} generates too few per cell ($perCell)');
        expect(perCell, lessThan(ScatterLayer.targetPerCell * 2.5),
            reason: '${layer.name} generates too many per cell ($perCell)');
      }
    });

    test('denser layers generate at finer levels', () {
      const radius = 6371000.0;
      expect(ScatterLayers.groundCover.levelFor(radius),
          greaterThan(ScatterLayers.forest.levelFor(radius)));
    });
  });

  group('determinism', () {
    test('the same cell always yields the same props', () {
      final cell = _cells(ScatterLayers.rocks, 300000, 1).single;
      final a = _placement().instancesFor(cell, ScatterLayers.rocks);
      final b = _placement().instancesFor(cell, ScatterLayers.rocks);
      expect(a.length, b.length);
      expect(a.isNotEmpty, isTrue, reason: 'nothing placed; test is vacuous');
      for (var i = 0; i < a.length; i++) {
        expect(a[i].positionBF.x, b[i].positionBF.x);
        expect(a[i].positionBF.y, b[i].positionBF.y);
        expect(a[i].positionBF.z, b[i].positionBF.z);
        expect(a[i].kind, b[i].kind);
        expect(a[i].seed, b[i].seed);
        expect(a[i].yaw, b[i].yaw);
        expect(a[i].scale, b[i].scale);
      }
    });

    test('a different body seed yields a different field', () {
      final cell = _cells(ScatterLayers.rocks, 300000, 1).single;
      final a = _placement().instancesFor(cell, ScatterLayers.rocks);
      final b = ScatterPlacement(
        field: _field(),
        surface: _surface,
        bodySeed: 100,
        vegetationCap: 1.0,
      ).instancesFor(cell, ScatterLayers.rocks);
      final same = a.length == b.length &&
          (a.isEmpty || a.first.positionBF.x == b.first.positionBF.x);
      expect(same, isFalse);
    });

    test('neighbouring cells do not influence each other', () {
      // Each candidate draws from its own stream, so generating a cell in
      // isolation must match generating it alongside its neighbours. This is
      // what lets cells stream in and out in any order.
      final cells = _cells(ScatterLayers.rocks, 300000, 3);
      final placement = _placement();
      final middleAlone =
          placement.instancesFor(cells[1], ScatterLayers.rocks);
      for (final c in cells) {
        placement.instancesFor(c, ScatterLayers.rocks);
      }
      final middleAgain =
          placement.instancesFor(cells[1], ScatterLayers.rocks);
      expect(middleAgain.length, middleAlone.length);
    });
  });

  group('placement geometry', () {
    test('props sit on the ground and stand along the surface normal', () {
      final placement = _placement();
      final field = _field();
      for (final cell in _cells(ScatterLayers.rocks, 300000, 2)) {
        for (final p in placement.instancesFor(cell, ScatterLayers.rocks)) {
          final dir = p.positionBF.normalized;
          final ground = field.groundRadiusAt(dir.x, dir.y, dir.z);
          expect((p.positionBF.length - ground).abs(), lessThan(0.5),
              reason: 'prop is not on the ground');
          expect(p.upBF.length, closeTo(1.0, 1e-6));
          // The normal must lean off radial, but never past horizontal.
          expect(p.upBF.dot(dir), greaterThan(0.5));
        }
      }
    });

    test('props land inside the cell that generated them', () {
      // If they did not, a cell unloading would leave orphans behind and
      // reloading would double up.
      final placement = _placement();
      for (final cell in _cells(ScatterLayers.rocks, 300000, 3)) {
        for (final p in placement.instancesFor(cell, ScatterLayers.rocks)) {
          expect(cell.contains(p.positionBF.normalized), isTrue,
              reason: 'prop escaped its cell $cell');
        }
      }
    });

    test('a layer only generates at its own level', () {
      final placement = _placement();
      final level = ScatterLayers.rocks.levelFor(300000);
      final wrong = ChunkKey(CubeFace.posX, level + 1, 0, 0);
      expect(placement.instancesFor(wrong, ScatterLayers.rocks), isEmpty);
    });
  });

  group('habitat gates', () {
    test('an airless body grows rock but no vegetation', () {
      final barren = _placement(vegetation: 0.0);
      var plants = 0, rocks = 0;
      for (final cell in _cells(ScatterLayers.rocks, 300000, 3)) {
        rocks += barren.instancesFor(cell, ScatterLayers.rocks).length;
      }
      for (final layer in [
        ScatterLayers.forest,
        ScatterLayers.groundCover,
        ScatterLayers.palms,
        ScatterLayers.reeds,
      ]) {
        for (final cell in _cells(layer, 300000, 3)) {
          plants += barren.instancesFor(cell, layer).length;
        }
      }
      expect(rocks, greaterThan(0), reason: 'no rock on an airless body');
      expect(plants, 0, reason: 'vegetation grew without a vegetation cap');
    });

    test('steep ground is rejected', () {
      // suitability() is the gate every candidate goes through; drive it
      // directly rather than hunting for a cliff on a procedural planet.
      const layer = ScatterLayers.forest;
      expect(
        layer.suitability(
            biome: Biome.forest,
            slopeCos: 0.99,
            altitudeM: 0,
            vegetationCap: 1),
        greaterThan(0.0),
      );
      expect(
        layer.suitability(
            biome: Biome.forest,
            slopeCos: 0.3, // ~72 degrees
            altitudeM: 0,
            vegetationCap: 1),
        0.0,
      );
    });

    test('the tree line stops forest but not rock', () {
      expect(
        ScatterLayers.forest.suitability(
            biome: Biome.mountains,
            slopeCos: 0.95,
            altitudeM: 9000,
            vegetationCap: 1),
        0.0,
      );
      expect(
        ScatterLayers.rocks.suitability(
            biome: Biome.mountains,
            slopeCos: 0.95,
            altitudeM: 9000,
            vegetationCap: 0),
        greaterThan(0.0),
      );
    });

    test('a biome with no weight grows nothing from that layer', () {
      expect(
        ScatterLayers.palms.suitability(
            biome: Biome.iceCap,
            slopeCos: 1.0,
            altitudeM: 0,
            vegetationCap: 1),
        0.0,
      );
    });
  });

  group('terrain deformation', () {
    /// Find a cell that actually has rock in it, and a prop to aim a brush at.
    (ChunkKey, ScatterInstance) populatedCell() {
      final placement = _placement();
      for (final cell in _cells(ScatterLayers.rocks, 300000, 12)) {
        final props = placement.instancesFor(cell, ScatterLayers.rocks);
        if (props.isNotEmpty) return (cell, props[props.length ~/ 2]);
      }
      fail('no populated cell found; the fixture places nothing');
    }

    test('a subtractive brush removes the props standing on what it carved',
        () {
      final (cell, victim) = populatedCell();
      final before = _placement().instancesFor(cell, ScatterLayers.rocks);

      // Sized to sit INSIDE one cell (~100 m across at the rock layer's
      // level), so the cell keeps survivors to check against.
      final edits = TerrainEdits()
        ..add(TerrainBrush.sphere(centreBF: victim.positionBF, radiusM: 25));
      final after =
          _placement(edits: edits).instancesFor(cell, ScatterLayers.rocks);

      expect(after.length, lessThan(before.length),
          reason: 'the excavation took nothing with it');
      // Every survivor must still be standing on real ground.
      final field = _field(edits: edits);
      for (final p in after) {
        final dir = p.positionBF.normalized;
        final ground = field.groundRadiusAt(dir.x, dir.y, dir.z);
        expect((p.positionBF.length - ground).abs(), lessThan(1.0),
            reason: 'a survivor is floating over the hole');
      }
    });

    test('ground far from an edit is untouched by it', () {
      // The analytic fast path must stay bit-identical, or every deformation
      // would silently reshuffle the scatter across the whole planet.
      final (cell, victim) = populatedCell();
      final before = _placement().instancesFor(cell, ScatterLayers.rocks);
      // A brush on the far side of the body.
      final edits = TerrainEdits()
        ..add(TerrainBrush.sphere(
            centreBF: victim.positionBF * -1.0, radiusM: 400));
      final after =
          _placement(edits: edits).instancesFor(cell, ScatterLayers.rocks);
      expect(after.length, before.length);
      for (var i = 0; i < after.length; i++) {
        expect(after[i].positionBF.x, before[i].positionBF.x);
        expect(after[i].positionBF.z, before[i].positionBF.z);
      }
    });

    test('surviving props next to an edit sit on the DEFORMED ground', () {
      final (cell, victim) = populatedCell();
      // A rim-raising crater lifts the ground just outside the bowl, so props
      // there must move up with it rather than staying buried at the old
      // height.
      final brush = TerrainBrush(
        kind: TerrainBrushKind.crater,
        centreBF: victim.positionBF,
        axisBF: victim.positionBF,
        radiusM: 30,
        depthM: 7,
        rimHeightM: 4,
      );
      final edits = TerrainEdits()..add(brush);
      final field = _field(edits: edits);
      final after =
          _placement(edits: edits).instancesFor(cell, ScatterLayers.rocks);

      final pristine = _field();
      var lifted = 0;
      for (final p in after) {
        final dir = p.positionBF.normalized;
        if (edits.at(dir).isEmpty) continue; // outside the edit's influence
        final ground = field.groundRadiusAt(dir.x, dir.y, dir.z);
        expect((p.positionBF.length - ground).abs(), lessThan(1.0),
            reason: 'prop near an edit is not on the deformed surface');
        final base = pristine.baseGroundRadiusAt(dir.x, dir.y, dir.z);
        if (p.positionBF.length > base + 1.0) lifted++;
      }
      // The rim raises ground, and props standing on it must ride UP rather
      // than be destroyed — the case that a naive "any brush touches this
      // point" test gets wrong.
      expect(lifted, greaterThan(0),
          reason: 'nothing rode up onto the raised rim');
    });
  });

  test('density is roughly what the layer asked for', () {
    // Averaged over many cells so biome and slope variation evens out. This is
    // a sanity bound, not a precision claim — the cube-to-sphere map is not
    // equal-area (see ScatterPlacement._cellAreaM2) and habitat gates cut into
    // it, so the realised density is legitimately BELOW the nominal one.
    const layer = ScatterLayers.rocks;
    final placement = _placement();
    final level = layer.levelFor(300000);
    final side = 1 << level;
    var count = 0, cells = 0;
    for (var i = 0; i < 24; i++) {
      final cell = ChunkKey(CubeFace.posX, level, side ~/ 2 + i, side ~/ 2);
      count += placement.instancesFor(cell, layer).length;
      cells++;
    }
    final area = 4 * math.pi * 300000 * 300000 / (6.0 * side * side) * cells;
    final realised = count / area * 1e6; // per km^2
    expect(realised, greaterThan(layer.densityPerKm2 * 0.05),
        reason: 'realised $realised/km2 vs nominal ${layer.densityPerKm2}');
    expect(realised, lessThanOrEqualTo(layer.densityPerKm2 * 1.2));
  });

  test('generationLevels reports every level a streamer must watch', () {
    final placement = _placement();
    final levels = placement.generationLevels();
    expect(levels.length, greaterThan(1));
    for (final layer in ScatterLayers.all) {
      expect(levels, contains(layer.levelFor(300000)));
    }
  });
}
