// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Scatter on the REAL catalogue bodies, through the SAME field construction
// the renderer uses (BodyDescriptorSnapshot.buildTerrainField — what
// ScatterNodes hands to ScatterPlacement).
//
// The synthetic-fixture tests in scatter_placement_test.dart prove the
// placement maths; this file proves the WIRING: that on the Moon and Earth —
// DEM'd, detail-layered, the bodies a player actually lands on — props
// generate at all, and every one of them stands on the sim's COLLISION
// ground. ScatterNodes once rebuilt the field by hand and dropped the detail
// layer, which passed every fixture test while seating props tens of metres
// inside crater rims on the real Moon.

import 'dart:math' as math;

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/scatter/scatter_instance.dart';
import 'package:acro_space_simulator/domain/scatter/scatter_layer.dart';
import 'package:acro_space_simulator/domain/scatter/scatter_placement.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// Well-spread sample directions (fibonacci sphere).
List<Vector3> _directions(int n) {
  final golden = math.pi * (3.0 - math.sqrt(5.0));
  return [
    for (var i = 0; i < n; i++)
      () {
        final z = 1.0 - 2.0 * (i + 0.5) / n;
        final r = math.sqrt(math.max(0.0, 1.0 - z * z));
        final t = golden * i;
        return Vector3(math.cos(t) * r, math.sin(t) * r, z);
      }(),
  ];
}

void main() {
  final system = SampleWorld.realSystem();

  for (final id in ['moon', 'earth']) {
    test('$id: props generate and stand on the sim collision ground', () {
      final body = system.require(BodyId(id));
      final descriptor = BodyDescriptorSnapshot.of(body, system);
      // The exact field ScatterNodes builds (shared builder, detail included).
      final field = descriptor.buildTerrainField()!;
      final simField = body.terrainField!;
      final placement = ScatterPlacement(
        field: field,
        surface: body.surface!,
        bodySeed: descriptor.terrainSeed,
        vegetationCap: descriptor.terrainGrassAmount,
      );

      var placed = 0;
      final byLayer = <String, int>{};
      for (final dir in _directions(16)) {
        for (final layer in ScatterLayers.all) {
          final cell = chunkAt(dir, layer.levelFor(field.radius));
          final instances = placement.instancesFor(cell, layer);
          placed += instances.length;
          byLayer[layer.name] =
              (byLayer[layer.name] ?? 0) + instances.length;

          for (final ScatterInstance p in instances) {
            final d = p.positionBF.normalized;
            // Pristine body: the placement ground and the collision ground
            // are the same surface, so a prop off it means the scatter field
            // has drifted from the sim's — the ScatterNodes bug class.
            final ground = simField.groundRadiusAt(d.x, d.y, d.z);
            expect((p.positionBF.length - ground).abs(), lessThan(0.5),
                reason: '$id/${layer.name}: prop at $d floats/buries '
                    '(${(p.positionBF.length - ground).toStringAsFixed(1)} m '
                    'off the collision ground)');
          }
        }
      }

      expect(placed, greaterThan(0),
          reason: '$id placed nothing anywhere — scatter is effectively off '
              'on a real body ($byLayer)');
      if (id == 'moon') {
        // The rock layer is the one that populates airless bodies; the Moon
        // without rocks means its gates (biome/vegetation) regressed.
        expect(byLayer['rocks'] ?? 0, greaterThan(0),
            reason: 'no rocks on the Moon ($byLayer)');
      }
    });
  }
}
