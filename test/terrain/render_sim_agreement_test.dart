// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/dem_pyramid.dart';
import 'package:acro_space_simulator/domain/terrain/dem_registry.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_profile.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/register_baked_dems.dart';

/// The sim and the renderer build `TerrainField` INDEPENDENTLY — the sim from
/// `CelestialBody`, the renderer from the wire descriptor. Nothing forces them
/// to agree, and when they drifted apart the failure was silent and total: the
/// renderer drew plain fBm relief while collision resolved against eroded,
/// cratered ground, so a craft sank through the visible surface chasing one
/// that was drawn nowhere.
///
/// These tests reconstruct the field the way `TerrainNodes` does and demand it
/// match the sim's, sample for sample.
void main() {
  registerBakedDemsForTest();

  /// Rebuild the render-side field from a descriptor, mirroring
  /// `TerrainNodes.update`. If that code changes, this must change with it.
  TerrainField renderField(BodyDescriptorSnapshot d) {
    final dem = d.terrainDemBodyId == null
        ? null
        : DemRegistry.require(d.terrainDemBodyId!);
    return TerrainField(
      radius: d.referenceRadius,
      amplitude: d.terrainAmplitude,
      featureScale: d.terrainFeatureScale,
      seaLevel: d.terrainSeaLevel,
      seed: d.terrainSeed,
      octaves: d.terrainOctaves,
      dem: dem,
      detail: d.terrainErodedDetail
          ? (d.terrainProfile ?? TerrainProfile.barren).detailFor(
              seed: d.terrainSeed,
              radiusM: d.referenceRadius,
              amplitudeM: d.terrainAmplitude,
              featureScaleM: d.terrainFeatureScale,
              octaves: d.terrainOctaves + 1,
              control: dem == null ? null : DemDerivedControl(dem),
            )
          : null,
    );
  }

  List<Vector3> directions(int n) {
    final golden = math.pi * (3.0 - math.sqrt(5.0));
    return [
      for (var i = 0; i < n; i++)
        () {
          final y = 1.0 - 2.0 * (i + 0.5) / n;
          final r = math.sqrt(math.max(0.0, 1.0 - y * y));
          final t = golden * i;
          return Vector3(math.cos(t) * r, y, math.sin(t) * r);
        }(),
    ];
  }

  final system = SampleWorld.realSystem();

  for (final id in ['moon', 'earth']) {
    group('$id: render and sim agree', () {
      final body = system.require(BodyId(id));
      final descriptor = BodyDescriptorSnapshot.of(body, system);

      test('the descriptor carries the generator recipe, not just its scale',
          () {
        expect(descriptor.hasTerrain, isTrue);
        expect(descriptor.terrainErodedDetail, isTrue,
            reason: '$id is migrated to the detail layer');
        expect(descriptor.terrainProfile, isNotNull,
            reason: 'without the profile the renderer cannot rebuild the '
                'surface physics uses');
        // Both bodies are surveyed now: moon (LOLA), earth (GEBCO_08).
        expect(descriptor.terrainDemBodyId, id,
            reason: 'a surveyed body must ship its DEM reference, or the '
                'renderer meshes procedural ground under real collision');
      });

      test('heights match EXACTLY across the whole body', () {
        final sim = body.terrainField!;
        final render = renderField(descriptor);
        for (final d in directions(600)) {
          expect(render.heightInDirection(d.x, d.y, d.z),
              sim.heightInDirection(d.x, d.y, d.z),
              reason: 'surfaces diverge at $d');
        }
      });

      test('ground radius matches, so a craft lands on what it can see', () {
        final sim = body.terrainField!;
        final render = renderField(descriptor);
        for (final d in directions(300)) {
          expect(render.groundRadiusAt(d.x, d.y, d.z),
              sim.groundRadiusAt(d.x, d.y, d.z));
        }
      });

      test('survives a JSON round-trip of the descriptor', () {
        // The engine bridge reconstitutes descriptors from the wire, so the
        // recipe has to survive serialisation too.
        final round = BodyDescriptorSnapshot.fromJson(descriptor.toJson());
        expect(round.terrainErodedDetail, descriptor.terrainErodedDetail);
        expect(round.terrainProfile?.archetype,
            descriptor.terrainProfile?.archetype);
        expect(round.terrainDemBodyId, descriptor.terrainDemBodyId);
        final sim = body.terrainField!;
        final render = renderField(round);
        for (final d in directions(200)) {
          expect(render.heightInDirection(d.x, d.y, d.z),
              sim.heightInDirection(d.x, d.y, d.z));
        }
      });

      test('relief stays within the body\'s own scale', () {
        // The symptom that made the collision bug visible: ground tens of km
        // below the datum, far outside anything the body was configured for.
        final sim = body.terrainField!;
        final demId = body.terrain!.demBodyId;
        // A surveyed body's contract is the field's own DEM-derived amplitude
        // (elevation span + detail headroom); the config scalar is superseded.
        // Procedural bodies keep the profile-derived bound.
        final bound = demId != null
            ? sim.amplitude
            : body.terrain!.profile!
                .detailFor(
                  seed: body.terrain!.seed,
                  radiusM: body.radius,
                  amplitudeM: body.terrain!.amplitude,
                  featureScaleM: body.terrain!.featureScale,
                )
                .maxMagnitude(body.terrain!.amplitude);
        var deepest = 0.0;
        for (final d in directions(2000)) {
          final h = sim.heightInDirection(d.x, d.y, d.z);
          expect(h.abs(), lessThanOrEqualTo(bound));
          if (h < deepest) deepest = h;
        }
        // And that bound must itself be sane — proportionate to the source
        // relief, not an order of magnitude past it.
        if (demId != null) {
          final dem = DemRegistry.require(demId);
          expect(bound, lessThan((dem.maxElevM - dem.minElevM) * 2),
              reason: '$id derived bound ${bound.toStringAsFixed(0)} m must '
                  'stay proportionate to the DEM span');
        } else {
          expect(bound, lessThan(body.terrain!.amplitude * 4),
              reason: '$id bound ${bound.toStringAsFixed(0)} m against '
                  'amplitude ${body.terrain!.amplitude}');
        }
      });
    });
  }
}
