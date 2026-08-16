// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:ui' show Offset, Size;

import 'package:acro_space_simulator/adapters/presenters/craft_editor_camera.dart';
import 'package:acro_space_simulator/adapters/presenters/craft_editor_pick.dart';
import 'package:acro_space_simulator/domain/craft/attach_targets.dart';
import 'package:acro_space_simulator/domain/craft/craft_balance.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_viewport.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/coord_convert.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/craft/craft_editor_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/part_primitives_category.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// The seams BETWEEN the craft editor fixes, which no single fix's own suite
/// can see.
///
/// Three rules were written independently and have to describe ONE object:
/// the box `CraftEditorNodes.standInScale` draws, the box
/// `CraftEditorPick.pickPart` hit-tests, and the circle
/// `CraftEditorPick.markerRadiusPx` both draws and accepts. A change to any one
/// of them is invisible to the other two — a stand-in can be drawn a fifth of
/// its clickable depth and every existing test still passes, because nothing
/// compares a drawn NUMBER to a picked NUMBER.
///
/// Likewise the pad plane is derived from the design, while the controller
/// caches the reads the overlay makes from that same design; the pad is
/// therefore the one thing that can go stale without any read looking wrong.
///
/// Units are METRES in the craft body frame (right-handed, Z-up, +Z = nose)
/// unless a name says px or scene.
void main() {
  final catalog = PartCatalog.standard();

  PartDef part(String id) =>
      catalog.byId(id) ??
      fail('the shipped catalog has no part "$id" — the roster moved');

  /// Azimuth 0 / elevation 0 gives the basis `forward +Y, right +X, up +Z`, so
  /// a metre offset in x or z maps to a pixel offset by focal length alone and
  /// every assertion below can be re-derived by hand.
  CraftEditorCamera cam({double distanceM = 30.0}) => CraftEditorCamera(
        azimuth: 0,
        elevation: 0,
        distanceM: distanceM,
        pivot: Vector3.zero,
        viewport: const Size(1280, 720),
      );

  /// The stand-in's drawn box in METRES: the primitive's own authored extent
  /// scaled by [CraftEditorNodes.standInScale] and converted back out of scene
  /// units. This is the number a player sees; [PartDef.size] is the number the
  /// picker tests.
  vm.Vector3 drawnBoxM(PartDef def) {
    final extent = PartPrimitivesByCategory.shapeFor(def).authoredExtentM;
    final s = CraftEditorNodes.standInScale(def);
    return vm.Vector3(
      s.x * extent.x / kRenderScale,
      s.y * extent.y / kRenderScale,
      s.z * extent.z / kRenderScale,
    );
  }

  group('the drawn box, the clicked box and the picker are one box', () {
    test('every catalog part draws the box the picker hit-tests', () {
      // The whole roster, not a sample: the defect this closes was one
      // primitive out of five whose authored extent was not a unit cube, and a
      // sample would have to happen to contain a part that uses it.
      var checked = 0;
      for (final def in catalog.all) {
        final drawn = drawnBoxM(def);
        expect(drawn.x, closeTo(def.size.x, 1e-6),
            reason: '${def.id} is drawn ${drawn.x}m wide and clicked at '
                '${def.size.x}m');
        expect(drawn.y, closeTo(def.size.y, 1e-6),
            reason: '${def.id} is drawn ${drawn.y}m deep and clicked at '
                '${def.size.y}m');
        expect(drawn.z, closeTo(def.size.z, 1e-6),
            reason: '${def.id} is drawn ${drawn.z}m tall and clicked at '
                '${def.size.z}m');
        checked++;
      }
      expect(checked, greaterThan(15),
          reason: 'the roster shrank; this sweep is only worth anything over '
              'the whole catalog');
    });

    test('a click on the drawn silhouette of a stand-in lands on that part',
        () {
      // eagle-legs is the concrete case: it is a `slab`, the one primitive
      // authored 1.0 x 0.4 x 0.06 rather than as a unit cube, so it is the part
      // whose drawn box and clicked box are free to disagree.
      final legs = part('eagle-legs');
      expect(PartPrimitivesByCategory.shapeFor(legs).authoredExtentM.z,
          closeTo(0.06, 1e-9),
          reason: 'the premise: this part draws through the non-cube slab');

      final c = cam(distanceM: 12.0);
      final editor = CraftEditorController(catalog: catalog);
      editor.hold(legs);
      expect(editor.placeRoot(), isTrue, reason: editor.blocked ?? '');
      final placed = editor.design.parts.single;

      // Eight corners of the DRAWN box. Every one of them must resolve to this
      // part, which is the same statement as "the silhouette is clickable".
      final drawn = drawnBoxM(legs);
      final h = Vector3(drawn.x / 2, drawn.y / 2, drawn.z / 2);
      for (final sx in const [-1.0, 1.0]) {
        for (final sy in const [-1.0, 1.0]) {
          for (final sz in const [-1.0, 1.0]) {
            final corner = placed.position +
                placed.rotation.rotate(Vector3(sx * h.x, sy * h.y, sz * h.z));
            final px = c.project(corner);
            expect(px, isNotNull, reason: 'the corner is on screen');
            expect(CraftEditorPick.pickPart(c, editor.design, px!),
                placed.instanceId,
                reason: 'a corner of the box the player SEES, drawn '
                    '${drawn.z.toStringAsFixed(2)}m deep, must be clickable');
          }
        }
      }
    });

    test('a marker on a stand-in accepts a click at the radius it is drawn at',
        () {
      // The two rules meet on one part: G3 decides how big the hull looks, G1
      // decides how big its seats look and how far a click may miss. A seat
      // drawn at the floor radius on a hull drawn to the wrong box is the exact
      // combination neither suite covers.
      final legs = part('eagle-legs');
      final c = cam(distanceM: 12.0);
      final editor = CraftEditorController(catalog: catalog);
      editor.hold(legs);
      expect(editor.placeRoot(), isTrue, reason: editor.blocked ?? '');

      final targets = AttachTargets.openNodes(editor.design);
      expect(targets, isNotEmpty, reason: 'the leg has seats to aim at');

      for (final t in targets) {
        final depth = c.depthOf(t.positionInCraft);
        if (depth <= c.nearM) continue;
        // Skip a seat whose normal points away — the picker refuses those by
        // design and a click there is meant to miss.
        if (t.directionInCraft.dot(c.viewDirTo(t.positionInCraft)) >
            CraftEditorPick.awayFacingDot) {
          continue;
        }
        final drawnPx = CraftEditorPick.markerRadiusPx(c, t.size, depth);
        final centre = c.project(t.positionInCraft);
        if (centre == null) continue;
        // One pixel inside the painted edge, on the horizontal, which is where
        // a player aiming at the chevron actually clicks.
        final onEdge = centre + Offset(drawnPx - 1.0, 0);
        final picked = CraftEditorPick.pickTarget<AttachTarget>(
          c,
          targets,
          onEdge,
          touch: false,
          markerOf: (x) => (
            position: x.positionInCraft,
            direction: x.directionInCraft,
            size: x.size,
          ),
        );
        expect(picked, isNotNull,
            reason: '${t.nodeName} is painted at '
                '${drawnPx.toStringAsFixed(1)}px and must accept a click '
                'inside that circle');
      }
    });
  });

  group('the pad plane follows the craft the controller reports', () {
    test('adding a part BELOW the root drops the pad to meet it', () {
      // The controller memoises the reads the overlay makes each frame. The pad
      // plane is derived from the design directly, so a cache that outlived an
      // edit would show as a craft standing in mid-air rather than as a wrong
      // number anywhere a read can be inspected.
      final editor = CraftEditorController(catalog: catalog);
      editor.hold(part('eagle-command-pod'));
      expect(editor.placeRoot(), isTrue, reason: editor.blocked ?? '');

      final podFloor = CraftEditorNodes.padPlaneZ(editor.design);
      expect(podFloor, closeTo(CraftBalance.bounds(editor.design)!.min.z, 1e-12),
          reason: 'the pad plane IS the lowest point of the craft');

      // Warm every cached read at the pre-edit revision, the way one hover
      // frame does, so a stale cache would have something to serve.
      editor.openTargets;
      editor.looseParts;
      editor.selection;

      final seat = AttachTargets.pairingsFor(
              editor.design, part('eagle-fuel-tank'))
          .firstWhere((p) => p.target.nodeName == 'stage-bottom',
              orElse: () => fail('the pod no longer offers stage-bottom'));
      editor.hold(part('eagle-fuel-tank'));
      expect(editor.attachAt(seat), isTrue, reason: editor.blocked ?? '');

      final withStage = CraftEditorNodes.padPlaneZ(editor.design);
      expect(withStage, lessThan(podFloor - 1.0),
          reason: 'a descent stage under the pod puts the craft on a lower '
              'floor; the pad has to come down to it');
      expect(withStage,
          closeTo(CraftBalance.bounds(editor.design)!.min.z, 1e-12));

      // And back, through the history the controller keeps.
      editor.undo();
      expect(CraftEditorNodes.padPlaneZ(editor.design), closeTo(podFloor, 1e-12),
          reason: 'undo restores the craft, so it restores the floor');
      editor.redo();
      expect(
          CraftEditorNodes.padPlaneZ(editor.design), closeTo(withStage, 1e-12));
    });

    test('the pad never sits above the craft, however the craft is built', () {
      // The invariant, stated once: no part may be below the plane it stands
      // on. Checked after every edit of a build that grows in both directions.
      final editor = CraftEditorController(catalog: catalog);

      void padIsUnderEverything(String after) {
        final planeZ = CraftEditorNodes.padPlaneZ(editor.design);
        for (final p in editor.design.parts) {
          final low = p.position.z - p.def.size.z / 2;
          expect(planeZ, lessThanOrEqualTo(low + 1e-9),
              reason: 'after $after, ${p.instanceId} reaches down to '
                  '${low.toStringAsFixed(3)}m and the pad is at '
                  '${planeZ.toStringAsFixed(3)}m');
        }
      }

      editor.hold(part('fl-t400'));
      expect(editor.placeRoot(), isTrue, reason: editor.blocked ?? '');
      padIsUnderEverything('the root tank');

      for (var i = 0; i < 3; i++) {
        final next = AttachTargets.pairingsFor(editor.design, part('fl-t400'))
            .where((p) => p.target.nodeName == 'bottom')
            .toList(growable: false);
        if (next.isEmpty) break;
        // Lowest seat, so each tank extends the stack downward.
        next.sort((a, b) => a.target.positionInCraft.z
            .compareTo(b.target.positionInCraft.z));
        editor.hold(part('fl-t400'));
        expect(editor.attachAt(next.first), isTrue,
            reason: editor.blocked ?? '');
        padIsUnderEverything('tank ${i + 2}');
      }
      expect(editor.design.partCount, greaterThan(1),
          reason: 'the sweep has to have actually grown the stack');
    });
  });

  group('the ghost preview and the commit describe the same placement', () {
    test('every seat the plan lists is previewed, at the pose it commits to',
        () {
      // The ghosts live only inside the flutter_scene graph, which no headless
      // test can build; `craftGhostPlan` exists so the plan itself can be read.
      // Without it a preview can silently drop a seat of a x4 ring and the
      // player learns about it by clicking.
      final editor = CraftEditorController(catalog: catalog);
      editor.hold(part('eagle-command-pod'));
      expect(editor.placeRoot(), isTrue, reason: editor.blocked ?? '');
      final rootId = editor.design.rootId ?? fail('no root recorded');

      final quad = part('eagle-rcs-block');
      editor.hold(quad);
      editor.setSymmetryCount(4);
      final pairing = AttachTargets.pairingsFor(editor.design, quad).firstWhere(
          (p) =>
              p.target.ownerInstanceId == rootId &&
              p.target.nodeName == 'quad-1',
          orElse: () => fail('quad-1 is no longer offered'));

      final plan = craftGhostPlan(editor, pairing);
      expect(plan.seats, hasLength(4),
          reason: 'x4 on the pod ring is four seats');
      expect(plan.ghosts, hasLength(plan.seats.length),
          reason: 'a seat with no ghost is a hole in the preview that reads as '
              'a broken renderer, not as a refusal');
      expect(plan.ghosts.every((g) => g.valid), isTrue,
          reason: 'every seat of a legal surface ring is legal');

      // The pose the preview promised must be the pose the commit produces.
      final promised = {
        for (var i = 0; i < plan.seats.length; i++)
          plan.seats[i].nodeName: plan.ghosts[i].position,
      };
      expect(editor.attachAt(pairing), isTrue, reason: editor.blocked ?? '');
      for (final p in editor.design.parts) {
        final mate = p.attachment;
        if (mate == null || p.def.id != quad.id) continue;
        final want = promised[mate.parentNode] ??
            fail('${mate.parentNode} was committed but never previewed');
        expect((p.position - want).length, lessThan(1e-9),
            reason: 'the ghost on ${mate.parentNode} stood at $want and the '
                'part landed at ${p.position}');
      }
    });

    test('an empty design previews the root at the origin placeRoot uses', () {
      final editor = CraftEditorController(catalog: catalog);
      editor.hold(part('mk1-capsule'));
      final plan = craftGhostPlan(editor, null);
      expect(plan.ghosts, hasLength(1));
      expect(plan.ghosts.single.position, Vector3.zero);
      expect(plan.seats, isEmpty);

      expect(editor.placeRoot(), isTrue, reason: editor.blocked ?? '');
      expect(editor.design.parts.single.position, Vector3.zero,
          reason: 'the preview stood where the commit put the part');
    });
  });
}
