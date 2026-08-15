// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../planetary/planet_surface.dart';
import '../shared/vector3.dart';
import '../terrain/cubed_sphere.dart';
import '../terrain/terrain_field.dart';
import 'prop_catalog.dart';
import 'scatter_instance.dart';
import 'scatter_layer.dart';
import 'scatter_placement.dart';

/// The scene-free half of the scatter lab's sample-scene diorama: a fixture
/// world, a deterministic hunt for a habitat-rich patch, and the placed
/// instances plus ground heights for that patch — everything the renderer
/// needs, with no renderer in sight, so the whole layout is testable headless.
///
/// The fixture mirrors the placement tests' world (small temperate body,
/// vegetation enabled): the point of the diorama is to show the REAL
/// placement rules producing a natural mix, and this world is the one place
/// all the habitat gates can pass at once.
class SampleSceneLayout {
  SampleSceneLayout._({
    required this.centreDir,
    required this.east,
    required this.north,
    required this.groundR0,
    required this.instances,
  });

  /// Half-size of the shown ground patch (m). Props are clipped a little
  /// inside so nothing pops at the mesh edge.
  static const double patchHalfM = 60.0;

  static final TerrainField field = TerrainField(
    radius: 300000,
    amplitude: 900,
    featureScale: 40000,
    seed: 4242,
  );

  static const PlanetSurface surface = PlanetSurface(
    seed: 11,
    meanSurfaceTemperature: 288,
    albedo: 0.3,
    solarFlux: 1361,
  );

  static final ScatterPlacement placement = ScatterPlacement(
    field: field,
    surface: surface,
    bodySeed: 99,
    vegetationCap: 1.0,
  );

  /// Body-fixed patch frame.
  final Vector3 centreDir;
  final Vector3 east;
  final Vector3 north;
  final double groundR0;

  /// Every prop of every layer inside the patch circle, body-fixed.
  final List<ScatterInstance> instances;

  /// The patch centre's biome name, for the HUD.
  String get biomeName => surface
      .biomeAt(
          latitude: math.asin(centreDir.z.clamp(-1.0, 1.0)),
          longitude: math.atan2(centreDir.y, centreDir.x))
      .name;

  /// Body-fixed point -> patch-local metres (x east, y north, z up off the
  /// centre's ground level).
  Vector3 toLocal(Vector3 bf) {
    final rel = bf - centreDir * groundR0;
    return Vector3(rel.dot(east), rel.dot(north), rel.dot(centreDir));
  }

  /// Direction under the patch-local point (x east, y north).
  Vector3 dirAt(double eastM, double northM) =>
      (centreDir + east * (eastM / field.radius) + north * (northM / field.radius))
          .normalized;

  /// Ground height (m) at a patch-local point, relative to the centre's
  /// ground — what the diorama's terrain mesh is built from.
  double groundHeightAt(double eastM, double northM) {
    final d = dirAt(eastM, northM);
    return field.baseGroundRadiusAt(d.x, d.y, d.z) - groundR0;
  }

  /// Build the layout: hunt a patch whose habitat produces the full mix (the
  /// demo is pointless on open ground with two rocks), then gather every
  /// layer's instances inside it. Fully deterministic — the same layout every
  /// time.
  factory SampleSceneLayout.resolve() {
    final golden = math.pi * (3.0 - math.sqrt(5.0));
    Vector3? best;
    var bestScore = -1;
    for (var i = 0; i < 400; i++) {
      final z = 1.0 - 2.0 * (i + 0.5) / 400;
      final r = math.sqrt(math.max(0.0, 1.0 - z * z));
      final t = golden * i;
      final dir = Vector3(math.cos(t) * r, math.sin(t) * r, z);

      final trees = _countAt(dir, ScatterLayers.forest);
      if (trees < 3) continue;
      final cover = _countAt(dir, ScatterLayers.groundCover);
      final rocks = _countAt(dir, ScatterLayers.rocks);
      final score = trees + cover ~/ 10 + rocks * 2;
      if (score > bestScore) {
        bestScore = score;
        best = dir;
      }
      if (trees >= 6 && cover >= 40) break; // good enough — stop hunting
    }
    final centre = (best ?? Vector3.unitX).normalized;
    final ref = centre.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
    final east = ref.cross(centre).normalized;
    final north = centre.cross(east);
    final groundR0 = field.baseGroundRadiusAt(centre.x, centre.y, centre.z);

    final layout = SampleSceneLayout._(
      centreDir: centre,
      east: east,
      north: north,
      groundR0: groundR0,
      instances: [],
    );
    layout.instances.addAll(layout._gather());
    return layout;
  }

  static int _countAt(Vector3 dir, ScatterLayer layer) {
    final cell = chunkAt(dir, layer.levelFor(field.radius));
    return placement.instancesFor(cell, layer).length;
  }

  List<ScatterInstance> _gather() {
    final out = <ScatterInstance>[];
    for (final layer in ScatterLayers.all) {
      final level = layer.levelFor(field.radius);
      // Cells covering the patch: sample a grid of directions across it and
      // dedupe — the patch is at most a few cells wide at any layer's level.
      final cells = <ChunkKey>{};
      const steps = 7;
      for (var j = 0; j < steps; j++) {
        for (var i = 0; i < steps; i++) {
          final x = (i / (steps - 1) - 0.5) * 2 * patchHalfM;
          final y = (j / (steps - 1) - 0.5) * 2 * patchHalfM;
          cells.add(chunkAt(dirAt(x, y), level));
        }
      }
      for (final cell in cells) {
        for (final p in placement.instancesFor(cell, layer)) {
          final local = toLocal(p.positionBF);
          if (local.x * local.x + local.y * local.y >
              (patchHalfM - 4) * (patchHalfM - 4)) {
            continue;
          }
          out.add(p);
        }
      }
    }
    return out;
  }

  /// The layer a prop kind belongs to, for the HUD's per-layer counts.
  static String layerOf(PropKind kind) {
    for (final layer in ScatterLayers.all) {
      if (layer.kinds.contains(kind)) return layer.name;
    }
    return 'other';
  }
}
