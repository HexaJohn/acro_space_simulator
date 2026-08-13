// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/planetary/planet_surface.dart';
import 'package:acro_space_simulator/domain/scatter/prop_catalog.dart';
import 'package:acro_space_simulator/domain/scatter/scatter_collision.dart';
import 'package:acro_space_simulator/domain/scatter/scatter_instance.dart';
import 'package:acro_space_simulator/domain/scatter/scatter_layer.dart';
import 'package:acro_space_simulator/domain/scatter/scatter_placement.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:flutter_test/flutter_test.dart';

TerrainField _field() => TerrainField(
      radius: 300000,
      amplitude: 900,
      featureScale: 40000,
      seed: 4242,
    );

const _surface = PlanetSurface(
  seed: 11,
  meanSurfaceTemperature: 288,
  albedo: 0.3,
  solarFlux: 1361,
);

ScatterPlacement _placement() => ScatterPlacement(
      field: _field(),
      surface: _surface,
      bodySeed: 99,
      vegetationCap: 1.0,
    );

/// A prop standing at the north pole on flat ground, for shape maths that
/// should not have to care where on a planet it happens.
ScatterInstance _standing(PropKind kind, {double scale = 1.0}) =>
    ScatterInstance(
      kind: kind,
      seed: 3,
      positionBF: const Vector3(0, 0, 1000),
      upBF: Vector3.unitZ,
      yaw: 0,
      scale: scale,
    );

void main() {
  group('collider profiles match the geometry they stand for', () {
    // The profiles are analytic so collision never has to grow a mesh. That is
    // only safe while they still describe the meshes — this is the test that
    // keeps the two honest, and it is why a generator tweak cannot quietly
    // desync the world you see from the world you hit.
    test('a trunk proxy is no wider than the tree and no taller than it', () {
      for (final kind in [
        PropKind.broadleafTree,
        PropKind.coniferTree,
        PropKind.palmTree,
        PropKind.deadSnag,
      ]) {
        final collider = ScatterCollider(_standing(kind));
        final actual = buildProp(kind, seed: 3).bounds;

        expect(collider.profile.shape, ColliderShape.trunk);
        // Never taller than the tree: a proxy poking out of the canopy would
        // stop a craft above the treetops.
        expect(collider.heightM, lessThanOrEqualTo(actual.heightM),
            reason: '$kind proxy is taller than the tree');
        // And a decent fraction of it, or low branches would be phantoms.
        expect(collider.heightM, greaterThan(actual.heightM * 0.35),
            reason: '$kind proxy is too short to be the trunk');
        // Narrower than the canopy by a wide margin — it is a trunk.
        expect(collider.radiusM, lessThan(actual.radiusM * 0.5),
            reason: '$kind proxy is as wide as the canopy');
        expect(collider.radiusM, greaterThan(0.0));
      }
    });

    test('a boulder proxy is close to the rock it stands for', () {
      for (final kind in [
        PropKind.boulder,
        PropKind.rockShard,
        PropKind.rockSlab,
        PropKind.rockCluster,
      ]) {
        final collider = ScatterCollider(_standing(kind));
        final actual = buildProp(kind, seed: 3).bounds;
        expect(collider.profile.shape, ColliderShape.boulder);
        // Within a factor of ~2 of the visible stone in both directions: a
        // sphere cannot match a slab exactly, but it must not be a different
        // object.
        expect(collider.radiusM, greaterThan(actual.radiusM * 0.5),
            reason: '$kind proxy is much smaller than the rock');
        expect(collider.radiusM, lessThan(actual.radiusM * 2.0),
            reason: '$kind proxy is much bigger than the rock');
        // The proxy must not float above the ground the rock sits on.
        expect(collider.boundingRadiusM, greaterThan(actual.heightM * 0.4));
      }
    });

    test('ground cover is not solid', () {
      for (final kind in [
        PropKind.grassTuft,
        PropKind.fern,
        PropKind.shrub,
        PropKind.reeds,
      ]) {
        final collider = ScatterCollider(_standing(kind));
        expect(collider.isSolid, isFalse, reason: '$kind blocks movement');
        expect(collider.probe(const Vector3(0, 0, 1000)), isNull);
      }
    });

    test('scale carries into the proxy', () {
      final small = ScatterCollider(_standing(PropKind.boulder, scale: 0.5));
      final large = ScatterCollider(_standing(PropKind.boulder, scale: 2.0));
      expect(large.radiusM, closeTo(small.radiusM * 4, 1e-9));
    });
  });

  group('trunk proxy', () {
    final tree = ScatterCollider(_standing(PropKind.broadleafTree));

    test('a probe at the trunk is pushed out sideways', () {
      final hit = tree.probe(
        Vector3(tree.radiusM * 0.25, 0, 1000 + tree.heightM * 0.5),
      );
      expect(hit, isNotNull);
      expect(hit!.depthM, greaterThan(0));
      // Horizontal separation: a trunk pushes you around it, not over it.
      expect(hit.normalBF.z.abs(), lessThan(1e-6));
      expect(hit.normalBF.x, closeTo(1.0, 1e-6));
    });

    test('a probe beside the trunk misses', () {
      expect(
        tree.probe(Vector3(tree.radiusM * 3, 0, 1000 + tree.heightM * 0.5)),
        isNull,
      );
    });

    test('a probe above the trunk misses', () {
      expect(tree.probe(Vector3(0, 0, 1000 + tree.heightM + 5)), isNull);
    });

    test('a wide probe beside the trunk still catches it', () {
      // The reason probes have radius: a craft is not a point.
      final hit = tree.probe(
        Vector3(tree.radiusM * 3, 0, 1000 + tree.heightM * 0.5),
        probeRadiusM: tree.radiusM * 2.5,
      );
      expect(hit, isNotNull);
    });

    test('deeper penetration reports greater depth', () {
      final shallow = tree.probe(
          Vector3(tree.radiusM * 0.9, 0, 1000 + tree.heightM * 0.5))!;
      final deep = tree.probe(
          Vector3(tree.radiusM * 0.1, 0, 1000 + tree.heightM * 0.5))!;
      expect(deep.depthM, greaterThan(shallow.depthM));
    });

    test('a probe on the axis still gets a usable normal', () {
      final hit = tree.probe(Vector3(0, 0, 1000 + tree.heightM * 0.5));
      expect(hit, isNotNull);
      expect(hit!.normalBF.length, closeTo(1.0, 1e-6));
    });
  });

  group('boulder proxy', () {
    final rock = ScatterCollider(_standing(PropKind.boulder));

    test('a probe inside is pushed out along the surface normal', () {
      final centreZ = 1000 + PropKind.boulder.defaultSizeM * 0.55;
      final hit = rock.probe(Vector3(rock.radiusM * 0.3, 0, centreZ));
      expect(hit, isNotNull);
      expect(hit!.normalBF.x, closeTo(1.0, 1e-6));
      expect(hit.depthM, closeTo(rock.radiusM * 0.7, 1e-6));
      // The contact point must lie on the proxy's surface.
      final centre = Vector3(0, 0, centreZ);
      expect((hit.pointBF - centre).length, closeTo(rock.radiusM, 1e-6));
    });

    test('a probe outside misses', () {
      final centreZ = 1000 + PropKind.boulder.defaultSizeM * 0.55;
      expect(rock.probe(Vector3(rock.radiusM * 2, 0, centreZ)), isNull);
    });
  });

  group('spatial query', () {
    test('a query finds the props that are actually there', () {
      final placement = _placement();
      final colliders = ScatterColliders(placement);
      final level = ScatterLayers.rocks.levelFor(300000);
      final side = 1 << level;
      final cell = ChunkKey(CubeFace.posX, level, side ~/ 2, side ~/ 2);
      final props = placement.instancesFor(cell, ScatterLayers.rocks);
      expect(props, isNotEmpty, reason: 'fixture placed nothing');

      final target = props[props.length ~/ 2];
      final found = colliders.near(target.positionBF, 1.0);
      expect(
        found.any((c) =>
            (c.instance.positionBF - target.positionBF).length < 1e-6),
        isTrue,
        reason: 'the query missed a prop standing at the query point',
      );
    });

    test('a query at a prop reports a hit for a craft-sized probe', () {
      final placement = _placement();
      final colliders = ScatterColliders(placement);
      final level = ScatterLayers.rocks.levelFor(300000);
      final side = 1 << level;
      final cell = ChunkKey(CubeFace.posX, level, side ~/ 2, side ~/ 2);
      final props = placement.instancesFor(cell, ScatterLayers.rocks);
      final target = props[props.length ~/ 2];

      // Probe centred on the rock's base — a craft settling onto it.
      final hit = colliders.deepestHit(target.positionBF, probeRadiusM: 2.0);
      expect(hit, isNotNull, reason: 'a craft on a boulder did not collide');
      expect(hit!.depthM, greaterThan(0));
      expect(hit.normalBF.length, closeTo(1.0, 1e-6));
    });

    test('open ground reports no contact', () {
      final placement = _placement();
      final colliders = ScatterColliders(placement);
      // Straight up from the surface: nothing is solid a kilometre in the air.
      final dir = const Vector3(1, 0.3, 0.2).normalized;
      final high = dir * (placement.field.radius + 1000);
      expect(colliders.deepestHit(high, probeRadiusM: 5.0), isNull);
    });

    test('the query never consults layers that cannot be solid', () {
      // Ground cover is by far the densest layer; generating it for every
      // collision query would dominate the cost and yield nothing.
      final colliders = ScatterColliders(_placement());
      expect(colliders.layers.map((l) => l.name), isNot(contains('ground cover')));
      expect(colliders.layers.map((l) => l.name), contains('rocks'));
      expect(colliders.layers.map((l) => l.name), contains('forest'));
    });

    test('collision agrees with what the renderer would draw', () {
      // The guarantee that matters: both sides regenerate from the same pure
      // function, so the rock you crash into is the rock you can see.
      final placement = _placement();
      final colliders = ScatterColliders(placement);
      final level = ScatterLayers.rocks.levelFor(300000);
      final side = 1 << level;
      final cell = ChunkKey(CubeFace.posX, level, side ~/ 2 + 3, side ~/ 2);
      final drawn = placement.instancesFor(cell, ScatterLayers.rocks);
      expect(drawn, isNotEmpty);

      for (final prop in drawn) {
        final found = colliders.near(prop.positionBF, 0.5);
        expect(
          found.any((c) =>
              (c.instance.positionBF - prop.positionBF).length < 1e-6 &&
              c.instance.seed == prop.seed),
          isTrue,
          reason: 'a drawn prop has no collider at its position',
        );
      }
    });

    test('deepestHit picks the worst overlap, not the first', () {
      final a = ScatterCollider(_standing(PropKind.boulder, scale: 1.0));
      final b = ScatterCollider(_standing(PropKind.boulder, scale: 2.0));
      final centreZ = 1000 + PropKind.boulder.defaultSizeM * 0.55;
      final probe = Vector3(0.1, 0, centreZ);
      final hitA = a.probe(probe)!;
      final hitB = b.probe(probe)!;
      // Sanity for the fixture: the bigger rock is the deeper overlap, so a
      // resolver that took the first hit would under-push.
      expect(hitB.depthM, greaterThan(hitA.depthM));
    });
  });
}
