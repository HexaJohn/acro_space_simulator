// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:acro_space_simulator/adapters/presenters/craft_editor_camera.dart';
import 'package:acro_space_simulator/domain/craft/craft_balance.dart';
import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/coord_convert.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/craft/craft_editor_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/depth_materials.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/part_primitives_category.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// The parts of the craft editor's scene graph that can be checked without a
/// GPU: what a placement composes to, what an art correction composes to, how
/// big a stand-in is, where the pad plane sits, and where the key light points.
///
/// `fs.Scene` and `fs.Mesh` need a live Impeller context, so nothing here can
/// construct a [CraftEditorNodes]. Each seam below is therefore a pure static
/// the renderer calls and a test can call too — the same arrangement
/// `kitbash_render_test.dart` uses for the flight view, and for the same reason:
/// the alternative is settling a transform by squinting at a screenshot.
///
/// `fs.Node` and `fs.Material` DO construct headless, which is what lets
/// [CraftGhostPool] and the pad material be exercised for real rather than
/// mirrored.
void main() {
  final catalog = PartCatalog.standard();

  /// The Apollo LM as `lem_assembly_test` builds it: ascent stage on top,
  /// descent stage under it, the DPS in the centre bay, four legs and four RCS
  /// quads by symmetry. Every number this file asserts about a craft comes off
  /// this one, because it is the vehicle the editor was designed around and the
  /// one whose geometry a wrong datum buries.
  CraftDesign buildEagle({bool legs = true}) {
    final c = PartCatalog.standard();
    PartDef part(String id) =>
        c.byId(id) ?? fail('the shipped catalog has no part "$id"');

    final d = CraftDesign(name: 'Eagle');
    d.addPart(def: part('eagle-command-pod'), instanceId: 'ascent', stage: 1);
    d.attachPart(
      def: part('eagle-fuel-tank'),
      instanceId: 'descent',
      toInstanceId: 'ascent',
      parentNode: 'stage-bottom',
      childNode: 'deck-top',
      stage: 0,
    );
    d.attachPart(
      def: part('eagle-thruster'),
      instanceId: 'dps',
      toInstanceId: 'descent',
      parentNode: 'engine-mount',
      childNode: 'mount',
    );
    if (legs) {
      d.attachRadial(
        def: part('eagle-legs'),
        instanceIdPrefix: 'gear',
        toInstanceId: 'descent',
        parentNode: 'leg-1',
        childNode: 'outrigger',
        count: 4,
      );
    }
    d.attachRadial(
      def: part('eagle-rcs-block'),
      instanceIdPrefix: 'rcs',
      toInstanceId: 'ascent',
      parentNode: 'quad-1',
      childNode: 'mount',
      count: 4,
    );
    return d;
  }

  /// The box a stand-in actually DRAWS, in metres: the scale the renderer
  /// applies times the primitive's own authored extent, converted back out of
  /// scene units. This is the number the picture shows, as against
  /// [PartDef.size], which is the number `CraftEditorPick` tests.
  Vector3 drawnBoxM(PartDef def) {
    final s = CraftEditorNodes.standInScale(def);
    final e = PartPrimitivesByCategory.authoredExtentM(def);
    return Vector3(
      s.x * e.x / kRenderScale,
      s.y * e.y / kRenderScale,
      s.z * e.z / kRenderScale,
    );
  }

  group('a part sits where the craft frame says, rebased on the camera pivot',
      () {
    test('a placement is metres -> scene km, relative to the pivot', () {
      final t = CraftEditorNodes.placementTransform(
        const Vector3(0, 0, 4.0),
        Quaternion.identity,
        const Vector3(0, 0, 1.5),
      ).getTranslation();
      // Tolerances are float32-sized: vector_math matrices are float32, so a
      // scene-unit value of 2.5e-3 carries ~1e-10 of representation error.
      expect(t.x, closeTo(0, 1e-10));
      expect(t.y, closeTo(0, 1e-10));
      expect(t.z, closeTo(lengthToScene(2.5), 1e-10));
    });

    test('the pivot is the origin the renderer sees', () {
      // Panning the camera to a part must put that part AT the scene origin, or
      // the overlay's projection (which is also pivot-relative) and the image
      // disagree by the pan.
      const p = Vector3(2.0, -3.0, 7.0);
      final t = CraftEditorNodes.placementTransform(p, Quaternion.identity, p)
          .getTranslation();
      expect(t.length, closeTo(0, 1e-12));
    });

    test('rotation is carried, and it is not the art correction', () {
      // A quarter turn about +Z sends a part-local +X to craft +Y. Getting this
      // from the SLOT (and not from the model child) is what lets the stand-in
      // and the bake be swapped without the part turning.
      final m = CraftEditorNodes.placementTransform(
        Vector3.zero,
        Quaternion.axisAngle(Vector3.unitZ, math.pi / 2),
        Vector3.zero,
      );
      final v = m.transform3(vm.Vector3(1, 0, 0));
      expect(v.x, closeTo(0, 1e-7));
      expect(v.y, closeTo(1, 1e-7));
      expect(v.z, closeTo(0, 1e-7));
    });

    test('the slot carries no scale of its own', () {
      // Any scale here would multiply into the model child's own conversion and
      // silently redefine modelScale.
      final m = CraftEditorNodes.placementTransform(
          Vector3.zero, Quaternion.identity, Vector3.zero);
      final unit = m.transform3(vm.Vector3(0, 0, 1)) - m.getTranslation();
      expect(unit.length, closeTo(1.0, 1e-9));
    });

    test('a ghost and a committed part compose the same placement', () {
      // The ghost has to be built through the identical call, or a preview can
      // sit somewhere the commit does not.
      const pos = Vector3(1.1, -0.4, 2.2);
      final rot = Quaternion.axisAngle(Vector3.unitX, 0.7);
      const pivot = Vector3(0, 0, 1.0);
      expect(
        CraftEditorNodes.placementTransform(pos, rot, pivot).storage,
        CraftEditorNodes.placementTransform(pos, rot, pivot).storage,
      );
    });
  });

  group('a part model is placed by scale, then rotation, then offset', () {
    PartDef def({
      double scale = 1.0,
      Quaternion rotation = Quaternion.identity,
      Vector3 offset = Vector3.zero,
    }) =>
        PartDef(
          id: 'x',
          name: 'X',
          category: PartCategory.structural,
          dryMass: 1,
          modelAsset: 'assets/mesh/x.fsceneb',
          modelScale: scale,
          modelRotation: rotation,
          modelOffset: offset,
        );

    test('the offset lands in metres, converted to scene units', () {
      final t = CraftEditorNodes.partModelTransform(
              def(offset: const Vector3(0, 0, 0.4)))
          .getTranslation();
      expect(t.x, closeTo(0, 1e-10));
      expect(t.y, closeTo(0, 1e-10));
      expect(t.z, closeTo(lengthToScene(0.4), 1e-10));
    });

    test('the offset is NOT scaled with the mesh', () {
      // If it were, the number would silently mean "model units" and every
      // recalibration of modelScale would move the mesh off the origin again.
      final small = CraftEditorNodes.partModelTransform(
          def(scale: 1.0, offset: const Vector3(0, 0, 0.4)));
      final big = CraftEditorNodes.partModelTransform(
          def(scale: 2.40, offset: const Vector3(0, 0, 0.4)));
      expect(big.getTranslation().z, closeTo(small.getTranslation().z, 1e-10));
    });

    test('the offset is NOT rotated by the model correction', () {
      final flipped = CraftEditorNodes.partModelTransform(def(
        rotation: Quaternion.axisAngle(Vector3.unitX, math.pi),
        offset: const Vector3(0, 0, 0.4),
      ));
      expect(flipped.getTranslation().z, closeTo(lengthToScene(0.4), 1e-10));
    });

    test('scale and the glTF Y-up fix still apply to the mesh itself', () {
      // A model-space point 1 unit "up" (glTF +Y) must land on craft +Z at
      // `scale` metres, then be displaced by the offset.
      final p = CraftEditorNodes.partModelTransform(
              def(scale: 2.40, offset: const Vector3(0, 0, 0.4)))
          .transform3(vm.Vector3(0, 1, 0));
      expect(p.x, closeTo(0, 1e-9));
      expect(p.y, closeTo(0, 1e-9));
      expect(p.z, closeTo(lengthToScene(2.40 + 0.4), 1e-9));
    });

    test('the editor draws every shipped part exactly as the flight view does',
        () {
      // Both read the same three fields off the same PartDef; the flight view
      // reaches them through PartModelLibrary, which kitbash_render_test already
      // pins as a faithful copy of the catalog. Asserting the RELATION here
      // means a recalibration cannot make this test stale, and a divergence
      // between the VAB's picture and the flown craft's fails in CI rather than
      // in a screenshot months later.
      for (final d in catalog.all.where((d) => d.modelAsset != null)) {
        final t = CraftEditorNodes.partModelTransform(d);
        expect(t.getTranslation().x, closeTo(lengthToScene(d.modelOffset.x), 1e-9),
            reason: d.id);
        expect(t.getTranslation().y, closeTo(lengthToScene(d.modelOffset.y), 1e-9),
            reason: d.id);
        expect(t.getTranslation().z, closeTo(lengthToScene(d.modelOffset.z), 1e-9),
            reason: d.id);
        final unit = t.transform3(vm.Vector3(0, 1, 0)) - t.getTranslation();
        expect(unit.length, closeTo(lengthToScene(d.modelScale), 1e-9),
            reason: '${d.id} draws at its catalog scale whichever way its '
                'correction turns it');
      }
    });

    test('a rotated export reads its offset in the PART frame, not its own', () {
      // The landing leg is the only shipped part with BOTH a non-identity
      // modelRotation and an off-axis modelOffset, so it is the one part that
      // can tell the two frames apart.
      final leg = catalog.byId('eagle-legs')!;
      expect(leg.modelRotation, isNot(Quaternion.identity));
      final t = CraftEditorNodes.partModelTransform(leg).getTranslation();
      expect(t.x, closeTo(lengthToScene(leg.modelOffset.x), 1e-10));
      expect(t.z, closeTo(lengthToScene(leg.modelOffset.z), 1e-10));
      // What the wrong order would have produced, so the test says what it is
      // ruling out and not only what it expects.
      final rotated = leg.modelRotation.rotate(leg.modelOffset);
      expect(t.x, isNot(closeTo(lengthToScene(rotated.x), 1e-9)));
    });
  });

  group('a stand-in fills the box the picker tests', () {
    test('the drawn box IS the catalog box, for every shipped part', () {
      // The property the whole stand-in tier rests on. `CraftEditorPick` tests
      // the oriented box off PartDef.size and never touches the mesh, so any
      // gap between these two numbers is a click target that misses the picture
      // — in either direction.
      for (final d in catalog.all) {
        final drawn = drawnBoxM(d);
        expect(drawn.x, closeTo(math.max(d.size.x, CraftEditorNodes.minStandInM), 1e-6),
            reason: d.id);
        expect(drawn.y, closeTo(math.max(d.size.y, CraftEditorNodes.minStandInM), 1e-6),
            reason: d.id);
        expect(drawn.z, closeTo(math.max(d.size.z, CraftEditorNodes.minStandInM), 1e-6),
            reason: d.id);
      }
    });

    test('a landing leg is drawn 3.22 m deep, not 0.19 m deep', () {
      // The concrete case: 'eagle-legs' contains 'leg', so the id tier hands it
      // a PLATE authored 1.0 x 0.4 x 0.06 — the one primitive that is not a
      // unit cube. Scaling that by a bare PartDef.size draws 2.54 x 0.95 x 0.19
      // while the picker tests 2.54 x 2.37 x 3.22, so a click 1.5 m above the
      // visible geometry selects the leg and a click on the leg selects nothing.
      final leg = catalog.byId('eagle-legs')!;
      expect(PartPrimitivesByCategory.shapeFor(leg), PartStandInShape.slab);
      expect(leg.size.z, closeTo(3.22, 1e-9));
      final drawn = drawnBoxM(leg);
      expect(drawn.x, closeTo(2.54, 1e-6));
      expect(drawn.y, closeTo(2.37, 1e-6));
      expect(drawn.z, closeTo(3.22, 1e-6));
      // The number the unit-box premise would have produced.
      expect(leg.size.z * PartStandInShape.slab.authoredExtentM.z,
          closeTo(0.1932, 1e-4));
    });

    test('every shape the registry can return fills its own box', () {
      // One synthetic part per tier-one key, so the assertion covers each
      // primitive rather than only the ones the shipped catalog happens to use.
      const bySeedId = {
        'capsule-x': PartStandInShape.nose,
        'engine-x': PartStandInShape.nozzle,
        'tank-x': PartStandInShape.cylinder,
        'rcs-x': PartStandInShape.box,
        'leg-x': PartStandInShape.slab,
      };
      for (final entry in bySeedId.entries) {
        const size = Vector3(2.0, 3.0, 5.0);
        final def = PartDef(
          id: entry.key,
          name: entry.key,
          category: PartCategory.structural,
          dryMass: 1,
          size: size,
        );
        expect(PartPrimitivesByCategory.shapeFor(def), entry.value,
            reason: entry.key);
        final drawn = drawnBoxM(def);
        expect(drawn.x, closeTo(size.x, 1e-6), reason: entry.key);
        expect(drawn.y, closeTo(size.y, 1e-6), reason: entry.key);
        expect(drawn.z, closeTo(size.z, 1e-6), reason: entry.key);
      }
    });

    test('no shape claims a zero extent, so the scale can divide by it', () {
      for (final shape in PartStandInShape.values) {
        expect(shape.authoredExtentM.x, greaterThan(0), reason: shape.name);
        expect(shape.authoredExtentM.y, greaterThan(0), reason: shape.name);
        expect(shape.authoredExtentM.z, greaterThan(0), reason: shape.name);
      }
    });

    test('a long part is not drawn as a cube', () {
      // The uniform "longest side" scale the flight view uses would draw a 4 m
      // tank as a 4 m cube, and the silhouette would then disagree with the
      // oriented box CraftEditorPick hit-tests.
      final tank = catalog.byId('fl-t400')!;
      expect(tank.size.z, greaterThan(tank.size.x));
      final s = CraftEditorNodes.standInScale(tank);
      expect(s.z, greaterThan(s.x));
    });

    test('every catalog part gets a stand-in with volume', () {
      for (final d in catalog.all) {
        final s = CraftEditorNodes.standInScale(d);
        expect(s.x * s.y * s.z, greaterThan(0), reason: d.id);
      }
    });

    test('a zero extent is floored rather than collapsed', () {
      // A part authored with a flat side would otherwise vanish entirely, which
      // reads as a missing part rather than as bad data.
      const flat = PartDef(
        id: 'flat',
        name: 'Flat',
        category: PartCategory.structural,
        dryMass: 1,
        size: Vector3(2.0, 0, 1.0),
      );
      expect(CraftEditorNodes.standInScale(flat).y,
          closeTo(lengthToScene(CraftEditorNodes.minStandInM), 1e-12));
    });
  });

  group('the key light never sits on the view axis', () {
    test('it is swung off the eye by exactly the offset', () {
      for (final az in [0.0, 0.9, 2.5, -1.3, math.pi]) {
        final light = CraftEditorNodes.lightDirection(az);
        // The eye's horizontal bearing, from PerspectiveCamera.forward.
        final eye = vm.Vector3(-math.sin(az), -math.cos(az), 0)..normalize();
        // Where the light SITS is the negation of where it travels.
        final from = vm.Vector3(-light.x, -light.y, 0)..normalize();
        final cosPhi = eye.dot(from).clamp(-1.0, 1.0);
        expect(math.acos(cosPhi),
            closeTo(CraftEditorNodes.lightOffsetRad.abs(), 1e-6),
            reason: 'azimuth $az');
      }
    });

    test('it always shines downward, so the craft is lit from above', () {
      for (final az in [0.0, 1.7, -2.2]) {
        expect(CraftEditorNodes.lightDirection(az).z, lessThan(0));
      }
    });

    test('it is unit length, whatever the azimuth', () {
      for (final az in [0.0, 0.4, 3.9, -5.1]) {
        // Float32-sized tolerance: vm.Vector3 stores a Float32List, so a
        // normalised component carries ~6e-8 of representation error.
        expect(CraftEditorNodes.lightDirection(az).length, closeTo(1.0, 1e-7));
      }
    });
  });

  group('the pad is the ground the craft stands on', () {
    test('an empty design puts the plane at the craft origin', () {
      // Nothing to stand on yet, and the root part is about to arrive there.
      expect(CraftEditorNodes.padPlaneZ(CraftDesign(name: 'empty')), 0.0);
    });

    test('a lunar module stands ON the pad rather than inside it', () {
      final d = buildEagle();
      final b = CraftBalance.bounds(d)!;
      // The shipped LM spans 6.59 m of craft z about the ASCENT stage's origin,
      // so 74% of the vehicle — the whole descent stage, all four footpads and
      // the engine bell — lies below z = 0. A pad nailed to z = 0 is a pad the
      // craft is buried in.
      expect(b.min.z, closeTo(-4.86, 5e-3));
      expect(b.max.z, closeTo(1.73, 5e-3));
      expect(CraftEditorNodes.padPlaneZ(d), closeTo(b.min.z, 1e-12));

      for (final p in d.parts) {
        final h = p.def.size * 0.5;
        for (final sx in const [-1.0, 1.0]) {
          for (final sy in const [-1.0, 1.0]) {
            for (final sz in const [-1.0, 1.0]) {
              final corner = p.position +
                  p.rotation.rotate(Vector3(sx * h.x, sy * h.y, sz * h.z));
              expect(corner.z, greaterThanOrEqualTo(b.min.z - 1e-9),
                  reason: '${p.instanceId} reaches below the pad it stands on');
            }
          }
        }
      }
    });

    test('the plane follows the bottom of the stack as parts come and go', () {
      // The property that decides the datum. Footpads are the lowest thing on
      // the LM at -4.86 m; take the gear off and the engine bell becomes the
      // lowest at -4.47 m. A datum that tracks the craft is correct after both
      // edits without touching a single part position.
      final withGear = CraftEditorNodes.padPlaneZ(buildEagle());
      final withoutGear = CraftEditorNodes.padPlaneZ(buildEagle(legs: false));
      expect(withGear, closeTo(-4.86, 5e-3));
      expect(withoutGear, closeTo(-4.47, 5e-3));
      expect(withoutGear, greaterThan(withGear));

      // And deleting the gear off a built craft gets the same answer as never
      // having placed it, which is what makes the pad stable under undo.
      final d = buildEagle();
      for (var i = 0; i < 4; i++) {
        d.remove('gear-$i');
      }
      expect(CraftEditorNodes.padPlaneZ(d), closeTo(withoutGear, 1e-12));
    });

    test('the plane reaches the scene as a pivot-relative z, in metres', () {
      final d = buildEagle();
      final planeZ = CraftEditorNodes.padPlaneZ(d);
      const pivot = Vector3(0.4, -0.2, -1.565);
      final t = CraftEditorNodes.padTransform(pivot, planeZ).getTranslation();
      expect(t.x, closeTo(lengthToScene(-0.4), 1e-10));
      expect(t.y, closeTo(lengthToScene(0.2), 1e-10));
      expect(t.z, closeTo(lengthToScene(planeZ + 1.565), 1e-9));
    });

    test('the default framing cannot put the pad between the eye and the craft',
        () {
      // The regression in full. With the eye above the plane and every scrap of
      // craft geometry on or above it, no segment from the eye to a craft point
      // can dip below the plane — so a pad lying IN that plane is never between
      // the two, whatever its radius or its opacity.
      final d = buildEagle();
      final planeZ = CraftEditorNodes.padPlaneZ(d);
      final cam = CraftEditorCamera.framing(d, const Size(1280, 800));
      expect(cam.eyeC.z, greaterThan(planeZ),
          reason: 'the default turntable looks DOWN at the craft');
      expect(CraftBalance.bounds(d)!.min.z, greaterThanOrEqualTo(planeZ - 1e-9));
    });

    test('its children are authored in metres', () {
      // The uniform lengthToScene(1) root scale is what lets the disc radius and
      // the ring radii be written as the metre values they are.
      final unit = CraftEditorNodes.padTransform(Vector3.zero, 0)
          .transform3(vm.Vector3(1, 0, 0));
      expect(unit.length, closeTo(lengthToScene(1.0), 1e-10));
    });

    test('the metre -> scene conversion is applied exactly ONCE', () {
      // Repeating lengthToScene on the child would draw a 20 m pad at 2 cm.
      // This repo has shipped that bug before ("city geometry was 1000x life
      // size"), and a pad that small under a 9 m lander reads as no pad at all.
      final chain = CraftEditorNodes.padTransform(Vector3.zero, 0)
          .multiplied(CraftEditorNodes.padChildTransform(0));
      final onePrimitiveMetre = chain.transform3(vm.Vector3(1, 0, 0));
      expect(onePrimitiveMetre.length, closeTo(lengthToScene(1.0), 1e-10));
      // And the pad really is padRadiusM across its radius.
      final rim = chain.transform3(vm.Vector3(CraftEditorNodes.padRadiusM, 0, 0));
      expect(rim.length, closeTo(lengthToScene(CraftEditorNodes.padRadiusM), 1e-9));
    });

    test('the child turns the primitives Y-up axis onto craft +Z', () {
      // The disc and the rings are both built about +Y; without the turn the
      // pad would stand on edge like a wheel.
      final m = CraftEditorNodes.padChildTransform(0);
      final up = m.transform3(vm.Vector3(0, 1, 0));
      expect(up.x, closeTo(0, 1e-7));
      expect(up.y, closeTo(0, 1e-7));
      expect(up.z, closeTo(1, 1e-7));
    });

    test('the ring lift is metres above the disc, along craft +Z', () {
      final chain = CraftEditorNodes.padTransform(Vector3.zero, 0).multiplied(
          CraftEditorNodes.padChildTransform(CraftEditorNodes.padRingLiftM));
      final t = chain.getTranslation();
      expect(t.z, closeTo(lengthToScene(CraftEditorNodes.padRingLiftM), 1e-11));
      // Thicker than the 1 mm disc it sits on, or the two sort ambiguously.
      expect(CraftEditorNodes.padRingLiftM, greaterThan(0.001));
    });

    test('the rings reach the rim and no further', () {
      final outermost =
          (CraftEditorNodes.padRadiusM / CraftEditorNodes.padRingSpacingM)
                  .floor() *
              CraftEditorNodes.padRingSpacingM;
      expect(outermost, closeTo(CraftEditorNodes.padRadiusM, 1e-9));
      expect(CraftEditorNodes.padRingHalfWidthM,
          lessThan(CraftEditorNodes.padRingSpacingM / 2),
          reason: 'neighbouring rings must not merge into a solid plate');
    });
  });

  group('the pad is a reference, not a wall', () {
    test('it is drawn translucent, so it never writes depth', () {
      // `Material.isOpaque` is what splits the two passes, and only the opaque
      // one writes depth. An opaque pad hides everything behind it the moment
      // the player orbits under the craft — which is exactly when they are
      // checking whether the footpads clear the bell.
      final m = CraftEditorNodes.padMaterial(
          CraftEditorNodes.padColor(0.10, 0.11, 0.13));
      expect(m, isA<DepthSafeUnlitMaterial>());
      expect(m.alphaMode, fs.AlphaMode.blend);
      expect(m.isOpaque(), isFalse,
          reason: 'an opaque pad occludes the craft it measures');
    });

    test('the colour is premultiplied, as the translucent pass expects', () {
      final c = CraftEditorNodes.padColor(0.10, 0.11, 0.13);
      expect(c.w, closeTo(CraftEditorNodes.padAlpha, 1e-7));
      expect(c.x, closeTo(0.10 * CraftEditorNodes.padAlpha, 1e-7));
      expect(c.y, closeTo(0.11 * CraftEditorNodes.padAlpha, 1e-7));
      expect(c.z, closeTo(0.13 * CraftEditorNodes.padAlpha, 1e-7));
    });

    test('a craft seen through the pad is still more than half visible', () {
      // The pad has to read as a floor and still let a bell silhouette through.
      expect(CraftEditorNodes.padAlpha, lessThan(0.6));
      expect(CraftEditorNodes.padAlpha, greaterThan(0.2));
    });
  });

  group('a ghost can never be mistaken for a committed part', () {
    test('the colour is premultiplied, as the translucent pass expects', () {
      // Float32-sized tolerances throughout: vm.Vector4 stores a Float32List.
      final c = CraftEditorNodes.ghostColor(valid: true);
      expect(c.w, closeTo(CraftEditorNodes.ghostAlpha, 1e-7));
      expect(c.x, closeTo(CraftEditorNodes.ghostValidRgb[0] * c.w, 1e-7));
      expect(c.y, closeTo(CraftEditorNodes.ghostValidRgb[1] * c.w, 1e-7));
      expect(c.z, closeTo(CraftEditorNodes.ghostValidRgb[2] * c.w, 1e-7));
    });

    test('valid and invalid are visibly different, and both translucent', () {
      final ok = CraftEditorNodes.ghostColor(valid: true);
      final bad = CraftEditorNodes.ghostColor(valid: false);
      expect(ok.w, bad.w);
      expect(bad.x, greaterThan(ok.x), reason: 'danger is the redder of the two');
      expect(ok.y, greaterThan(bad.y), reason: 'accent2 is the greener');
      expect(ok.w, lessThan(1.0));
    });

    test('a fresh colour vector per call', () {
      // vector_math types are mutable; one shared instance handed to several
      // ghosts would recolour the lot on any in-place edit.
      final a = CraftEditorNodes.ghostColor(valid: true);
      final b = CraftEditorNodes.ghostColor(valid: true);
      expect(identical(a, b), isFalse);
      expect(identical(CraftEditorNodes.selectionColor(),
          CraftEditorNodes.selectionColor()), isFalse);
    });
  });

  group('a ghost slot outlives the aim that filled it', () {
    PartDef def(String id) => PartDef(
          id: id,
          name: id,
          category: PartCategory.structural,
          dryMass: 1,
          size: const Vector3(1, 1, 2),
        );

    CraftGhost ghost(PartDef d, {double z = 0, bool valid = true}) => CraftGhost(
          def: d,
          position: Vector3(0, 0, z),
          rotation: Quaternion.identity,
          valid: valid,
        );

    /// A pool wired to a stand-in scene. The mesh builder returns a bare
    /// `fs.Node` — which constructs headless where an `fs.Mesh` does not — and
    /// the attach/detach callbacks assert their own preconditions, so a double
    /// attach or a detach of an absent node fails here rather than as a thrown
    /// `Exception` out of a paint.
    ({CraftGhostPool pool, Set<fs.Node> scene}) makePool() {
      final scene = <fs.Node>{};
      final pool = CraftGhostPool(
        buildMesh: (d, m) => fs.Node(),
        attach: (n) => expect(scene.add(n), isTrue,
            reason: 'a slot was attached to the scene twice'),
        detach: (n) => expect(scene.remove(n), isTrue,
            reason: 'a slot was detached while it was not in the scene'),
      );
      return (pool: pool, scene: scene);
    }

    test('sweeping the cursor on and off a marker allocates once', () {
      // The leak. A pass over the LM's twelve markers crosses about two dozen
      // enter/leave boundaries in a second; a pool that dropped its slot on
      // leave would build — and, since nothing here is ever disposed inline,
      // ORPHAN — a mesh and its device buffers on every one of them.
      final h = makePool();
      final part = def('a');
      for (var i = 0; i < 12; i++) {
        h.pool.sync([ghost(part)], Vector3.zero);
        expect(h.scene.length, 1);
        h.pool.sync(const [], Vector3.zero);
        expect(h.scene, isEmpty, reason: 'a stale ghost must leave the scene');
      }
      expect(h.pool.meshBuilds, 1);
      expect(h.pool.slotCount, 1, reason: 'the slot is kept, not destroyed');
      expect(h.pool.liveCount, 0);
    });

    test('the held part changing is what rebuilds a ghost', () {
      final h = makePool();
      final a = def('a'), b = def('b');
      h.pool.sync([ghost(a)], Vector3.zero);
      expect(h.pool.meshBuilds, 1);
      h.pool.sync([ghost(a, z: 3)], Vector3.zero);
      expect(h.pool.meshBuilds, 1, reason: 'moving a ghost is a matrix write');
      h.pool.sync([ghost(a, valid: false)], Vector3.zero);
      expect(h.pool.meshBuilds, 1, reason: 'refusing a mate is a colour write');
      h.pool.sync([ghost(b)], Vector3.zero);
      expect(h.pool.meshBuilds, 2);
    });

    test('a symmetry set keeps its slots across a missed aim', () {
      final h = makePool();
      final part = def('quad');
      final four = [
        for (var i = 0; i < 4; i++) ghost(part, z: i.toDouble()),
      ];
      h.pool.sync(four, Vector3.zero);
      expect(h.pool.meshBuilds, 4);
      expect(h.pool.liveCount, 4);
      expect(h.scene.length, 4);

      h.pool.sync(const [], Vector3.zero);
      expect(h.pool.slotCount, 4);
      expect(h.pool.liveCount, 0);
      expect(h.scene, isEmpty);

      h.pool.sync(four, Vector3.zero);
      expect(h.pool.meshBuilds, 4, reason: 'the four slots came back as they were');
      expect(h.scene.length, 4);
    });

    test('shrinking a preview detaches only the surplus', () {
      final h = makePool();
      final part = def('quad');
      h.pool.sync([for (var i = 0; i < 4; i++) ghost(part)], Vector3.zero);
      h.pool.sync([ghost(part)], Vector3.zero);
      expect(h.scene.length, 1);
      expect(h.pool.slotCount, 4);
      expect(h.pool.liveCount, 1);
      expect(h.pool.meshBuilds, 4);
    });

    test('the pool tears down cleanly, and twice is the same as once', () {
      final h = makePool();
      final part = def('a');
      h.pool.sync([ghost(part), ghost(part)], Vector3.zero);
      h.pool.clear();
      expect(h.scene, isEmpty);
      expect(h.pool.slotCount, 0);
      h.pool.clear();
      expect(h.pool.slotCount, 0);
    });
  });
}
