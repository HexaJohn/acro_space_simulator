// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:math' as math;

import 'package:acro_space_simulator/domain/craft/attach_targets.dart';
import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/craft/craft_design_codec.dart';
import 'package:acro_space_simulator/domain/parts/attach_node.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_design_store.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The regression suite for the craft editor's mutation funnel.
///
/// Undo in this editor is TOTAL — every edit, including the Clear the old
/// assembly screen could never take back — and that property rests on exactly
/// one thing: no code path touches the design except through
/// `CraftEditorController.edit`. So the tests below never assert a part count
/// and call it undone. They compare the CODEC ENCODING of the whole craft,
/// character for character, because that is the only comparison that catches
/// the failures that matter: a part restored at the right place with the wrong
/// roll, a symmetry group that came back three-quarters intact, a staging
/// assignment silently squeezed by a renumber.
///
/// Where a test drives the domain directly it does so INSIDE an `edit` closure,
/// which is the sanctioned use — that is the funnel, not a way around it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const codec = CraftDesignCodec();
  late PartCatalog catalog;
  late CraftEditorController editor;

  /// The comparison every assertion in this file is built on: the craft as the
  /// save file would hold it, as one string.
  String snap(CraftDesign design) => json.encode(codec.encode(design));

  PartDef part(String id) =>
      catalog.byId(id) ??
      fail('the shipped catalog has no part "$id" — the LM roster moved');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    catalog = PartCatalog.standard();
    editor = CraftEditorController(
        catalog: catalog, craftName: 'Eagle', undoDepth: 1000);
  });

  tearDown(() => editor.dispose());

  /// The pairing for one named seat, taken from the controller's own offer —
  /// so a test can only ask for a mate the editor would actually present.
  TargetPairing seat(String ownerInstanceId, String nodeName) =>
      editor.pairings.firstWhere(
        (p) =>
            p.target.ownerInstanceId == ownerInstanceId &&
            p.target.nodeName == nodeName,
        orElse: () => fail('the editor offers no pairing for '
            '"$ownerInstanceId.$nodeName" holding ${editor.held?.def.id}'),
      );

  /// pod -> descent stage, the two-part spine every other flow hangs off.
  /// Returns the instance ids in placement order.
  List<String> twoStage() {
    editor.hold(part('eagle-command-pod'));
    expect(editor.placeRoot(), isTrue);
    editor.hold(part('eagle-fuel-tank'));
    expect(editor.attachAt(seat('eagle-command-pod-0', 'stage-bottom')), isTrue);
    editor.clearHeld();
    return ['eagle-command-pod-0', 'eagle-fuel-tank-1'];
  }

  group('the funnel', () {
    test('an edit that throws part way leaves the craft exactly as it was', () {
      twoStage();
      final before = snap(editor.design);
      final steps = editor.undoCount;

      // A symmetry op is N attachPart calls; the domain commits each as it
      // goes, so a refusal on the third would leave two thirds of a ring
      // bolted on. The funnel restores the pre-edit snapshot instead.
      final ok = editor.edit('half a ring', () {
        editor.design.attachPart(
          def: part('eagle-rcs-block'),
          instanceId: 'partial@quad-1',
          toInstanceId: 'eagle-command-pod-0',
          parentNode: 'quad-1',
          childNode: 'mount',
        );
        editor.design.attachPart(
          def: part('eagle-rcs-block'),
          instanceId: 'partial@quad-2',
          toInstanceId: 'eagle-command-pod-0',
          parentNode: 'quad-2',
          childNode: 'mount',
        );
        throw StateError('the third seat was taken');
      });

      expect(ok, isFalse);
      expect(snap(editor.design), before,
          reason: 'a refused edit must leave no trace of its first half');
      expect(editor.undoCount, steps,
          reason: 'a refused edit is not a step to undo');
      expect(editor.blocked, 'the third seat was taken');
    });

    test('a mate the domain refuses reports a sentence and changes nothing', () {
      twoStage();
      final before = snap(editor.design);
      final steps = editor.undoCount;

      // 0.81 m docking bore against a 1.5 m engine mount: the editor never
      // OFFERS this, so it is built by hand to prove the funnel still guards it.
      editor.hold(part('eagle-thruster'));
      final impossible = TargetPairing(
        target: const AttachTarget(
          ownerInstanceId: 'eagle-command-pod-0',
          nodeName: 'dock-top',
          positionInCraft: Vector3(0, 0, 1.73),
          directionInCraft: Vector3.unitZ,
          size: 0.81,
          kind: AttachKind.stack,
        ),
        childNodeName: 'mount',
      );

      expect(editor.attachAt(impossible), isFalse);
      expect(editor.blocked, contains('size mismatch'));
      expect(snap(editor.design), before);
      expect(editor.undoCount, steps);
    });

    test('a refusal before the domain is reached is not an undo step', () {
      final steps = editor.undoCount;
      expect(editor.placeRoot(), isFalse,
          reason: 'nothing is held and no def was passed');
      expect(editor.blocked, isNotNull);
      expect(editor.undoCount, steps);
    });
  });

  group('every mutating action', () {
    /// Run one action and prove the round trip on the WHOLE craft: the encoding
    /// before, after, undone, and redone.
    void reversible(String what, bool Function() action,
        {bool changes = true}) {
      final before = snap(editor.design);
      final steps = editor.undoCount;

      expect(action(), isTrue, reason: what);
      final after = snap(editor.design);
      if (changes) {
        expect(after, isNot(before), reason: '$what must change the craft');
      }
      expect(editor.undoCount, steps + 1,
          reason: '$what must be exactly one step');

      expect(editor.undo(), isTrue, reason: 'undo $what');
      expect(snap(editor.design), before,
          reason: 'undoing $what must restore the craft exactly');

      expect(editor.redo(), isTrue, reason: 'redo $what');
      expect(snap(editor.design), after,
          reason: 'redoing $what must restore the craft exactly');
    }

    test('is undoable and redoable, over a whole LM build', () {
      editor.hold(part('eagle-command-pod'));
      reversible('place the ascent stage', editor.placeRoot);

      editor.hold(part('eagle-fuel-tank'));
      reversible('stack the descent stage',
          () => editor.attachAt(seat('eagle-command-pod-0', 'stage-bottom')));

      editor.hold(part('eagle-rcs-block'));
      editor.setSymmetryCount(4);
      reversible('mount four RCS quads',
          () => editor.attachAt(seat('eagle-command-pod-0', 'quad-1')));

      editor.hold(part('eagle-legs'));
      reversible('mount four landing legs',
          () => editor.attachAt(seat('eagle-fuel-tank-1', 'leg-1')));

      editor.hold(part('eagle-thruster'));
      editor.setSymmetryCount(1);
      reversible('bolt on the descent engine',
          () => editor.attachAt(seat('eagle-fuel-tank-1', 'engine-mount')));
      editor.clearHeld();

      expect(editor.design.partCount, 11,
          reason: 'pod + descent + engine + 4 quads + 4 legs');

      editor.select('eagle-rcs-block-2@quad-1');
      reversible('roll the quad ring',
          () => editor.rollSelection(math.pi / 8));
      editor.endGesture();

      reversible('re-stage the quad ring',
          () => editor.assignStage('eagle-rcs-block-2@quad-1', 3));

      reversible('renumber the stages', editor.renumberStages, changes: false);

      reversible('detach the engine', () => editor.detach('eagle-thruster-4'));
      reversible('delete the engine',
          () => editor.deletePart('eagle-thruster-4'));

      reversible('rename the craft', () => editor.rename('Snoopy'));
      editor.endGesture();

      reversible('clear the craft', editor.clear);
      expect(editor.design.isEmpty, isTrue);
    });

    test('quick-stacking from the catalog row is a step like any other', () {
      reversible('quick-stack the ascent stage',
          () => editor.quickStack(part('eagle-command-pod')));
      reversible('quick-stack the descent stage',
          () => editor.quickStack(part('eagle-fuel-tank')));
      expect(editor.design.partCount, 2);
      expect(editor.design.partById('eagle-fuel-tank-1')!.attachment!.parentNode,
          'stage-bottom',
          reason: 'quick-stack seats on the lowest free stack node');
    });

    test('re-mating a branch is one step and carries the subtree back', () {
      twoStage();
      editor.hold(part('eagle-rcs-block'));
      editor.setSymmetryCount(1);
      expect(editor.attachAt(seat('eagle-command-pod-0', 'quad-1')), isTrue);
      editor.clearHeld();

      final moved = 'eagle-rcs-block-2';
      final options = editor.pairingsForMove(moved);
      final target = options.firstWhere(
          (p) => p.target.nodeName == 'leg-3',
          orElse: () => fail('no pairing onto the descent stage leg ring'));

      reversible('move the quad onto a leg outrigger',
          () => editor.remate(moved, target));
      expect(editor.design.partById(moved)!.attachment!.parentInstanceId,
          'eagle-fuel-tank-1');
    });
  });

  group('moving a part', () {
    /// tank -> tank -> engine, the shape that makes occupancy two-sided: the
    /// middle tank's `bottom` is spent by the engine under it, while its `top`
    /// is spent only by the joint a move would replace.
    void falconStack() {
      editor.hold(part('fl-t400'));
      expect(editor.placeRoot(), isTrue);
      editor.hold(part('fl-t400'));
      expect(editor.attachAt(seat('fl-t400-0', 'bottom')), isTrue);
      editor.hold(part('merlin-1d'));
      expect(editor.attachAt(seat('fl-t400-1', 'bottom')), isTrue);
      editor.clearHeld();
    }

    test('every move the editor offers is one the domain accepts', () {
      falconStack();
      const moved = 'fl-t400-1';
      final offers = editor.pairingsForMove(moved);
      expect(offers, isNotEmpty);

      // Walked through the funnel rather than the domain, because the offer set
      // and the commit are what have to agree — a marker the player can aim at
      // and a refusal they cannot act on is the failure being pinned.
      for (final p in offers) {
        expect(editor.remate(moved, p), isTrue,
            reason: 'the editor offered ${p.target.ownerInstanceId}.'
                '${p.target.nodeName} <- ${p.childNodeName} and the domain '
                'answered "${editor.blocked}"');
        expect(editor.undo(), isTrue);
      }
    });

    test('the node a move would free is still offered', () {
      falconStack();
      final offers = editor
          .pairingsForMove('fl-t400-1')
          .map((p) => '${p.target.ownerInstanceId}.${p.target.nodeName}'
              '<-${p.childNodeName}');
      expect(offers, contains('fl-t400-0.top<-top'),
          reason: 'a filter that counted the tank\'s own joint against it '
              'would leave a stacked part with no way off the stack');
    });
  });

  group('symmetry and coalescing', () {
    test('a x4 placement is one undo step and four real mates', () {
      twoStage();
      final steps = editor.undoCount;

      editor.setSymmetryCount(4);
      editor.hold(part('eagle-rcs-block'));
      expect(editor.attachAt(seat('eagle-command-pod-0', 'quad-1')), isTrue);

      expect(editor.design.partCount, 6);
      expect(editor.undoCount, steps + 1, reason: 'four parts, one step');

      final seats = {
        for (final p in editor.design.parts)
          if (p.def.id == 'eagle-rcs-block') p.attachment!.parentNode
      };
      expect(seats, {'quad-1', 'quad-2', 'quad-3', 'quad-4'},
          reason: 'each copy names its OWN authored node, which is what makes '
              'the design reloadable');

      expect(editor.undo(), isTrue);
      expect(editor.design.partCount, 2, reason: 'one undo takes all four back');
    });

    test('a symmetry group deletes and comes back whole', () {
      twoStage();
      editor.setSymmetryCount(4);
      editor.hold(part('eagle-rcs-block'));
      expect(editor.attachAt(seat('eagle-command-pod-0', 'quad-1')), isTrue);
      editor.clearHeld();
      final whole = snap(editor.design);

      expect(editor.deletePart('eagle-rcs-block-2@quad-3'), isTrue);
      expect(editor.design.partCount, 2,
          reason: 'deleting one of a ring deletes the ring');

      expect(editor.undo(), isTrue);
      expect(snap(editor.design), whole);
    });

    test('a roll drag coalesces to one step, and endGesture opens the next', () {
      twoStage();
      editor.setSymmetryCount(4);
      editor.hold(part('eagle-rcs-block'));
      expect(editor.attachAt(seat('eagle-command-pod-0', 'quad-1')), isTrue);
      editor.clearHeld();

      final beforeDrag = snap(editor.design);
      final steps = editor.undoCount;
      editor.select('eagle-rcs-block-2@quad-1');

      for (var i = 0; i < 20; i++) {
        expect(editor.rollSelection(0.02), isTrue);
      }
      expect(editor.undoCount, steps + 1,
          reason: '20 frames of a drag is one thing the player did');
      final afterDrag = snap(editor.design);
      expect(afterDrag, isNot(beforeDrag));

      // Pointer up.
      editor.endGesture();
      expect(editor.rollSelection(0.02), isTrue);
      expect(editor.undoCount, steps + 2,
          reason: 'the next drag is its own step');

      expect(editor.undo(), isTrue);
      expect(snap(editor.design), afterDrag);
      expect(editor.undo(), isTrue);
      expect(snap(editor.design), beforeDrag,
          reason: 'one undo unwinds the whole drag, not one frame of it');
    });

    test('selecting another part closes an open coalescing run', () {
      twoStage();
      editor.setSymmetryCount(4);
      editor.hold(part('eagle-rcs-block'));
      expect(editor.attachAt(seat('eagle-command-pod-0', 'quad-1')), isTrue);
      editor.clearHeld();

      editor.select('eagle-rcs-block-2@quad-1');
      expect(editor.rollSelection(0.1), isTrue);
      final steps = editor.undoCount;

      editor.select('eagle-fuel-tank-1');
      editor.select('eagle-rcs-block-2@quad-1');
      expect(editor.rollSelection(0.1), isTrue);
      expect(editor.undoCount, steps + 1,
          reason: 'a selection change ends the gesture');
    });

    test('a ring that cannot express the count places one copy, not four', () {
      twoStage();
      editor.setSymmetryCount(4);
      editor.hold(part('eagle-thruster'));
      // engine-mount is a lone stack node: it has no ring at all.
      expect(editor.attachAt(seat('eagle-fuel-tank-1', 'engine-mount')), isTrue);
      expect(editor.design.partCount, 3);

      final deflector = editor.openTargets.firstWhere(
          (t) => t.nodeName == 'deflector-1',
          orElse: () => fail('the descent stage lost its deflector ring'));
      expect(editor.symmetryCountsAt(deflector), [1, 2, 4],
          reason: 'a four-member ring offers exactly its divisors');
      final lone = editor.openTargets
          .firstWhere((t) => t.nodeName == 'dock-top');
      expect(editor.symmetryCountsAt(lone), [1],
          reason: 'a lone node can express nothing but one copy');
    });
  });

  group('history', () {
    test('the redo stack is dropped by a new edit after an undo', () {
      twoStage();
      expect(editor.canRedo, isFalse);

      expect(editor.undo(), isTrue);
      expect(editor.canRedo, isTrue, reason: 'the descent stage is redoable');
      expect(editor.design.partCount, 1);

      editor.setSymmetryCount(1);
      editor.hold(part('eagle-rcs-block'));
      expect(editor.attachAt(seat('eagle-command-pod-0', 'quad-1')), isTrue);

      expect(editor.canRedo, isFalse,
          reason: 'the timeline forked; the old branch cannot be re-applied '
              'against a craft that has moved past it');
      expect(editor.redoCount, 0);
    });

    test('clear is undoable, which it never was in the old screen', () {
      twoStage();
      editor.setSymmetryCount(4);
      editor.hold(part('eagle-legs'));
      expect(editor.attachAt(seat('eagle-fuel-tank-1', 'leg-1')), isTrue);
      editor.clearHeld();
      final built = snap(editor.design);
      expect(editor.design.partCount, 6);

      expect(editor.clear(), isTrue);
      expect(editor.design.isEmpty, isTrue);

      expect(editor.undo(), isTrue);
      expect(snap(editor.design), built,
          reason: 'an hour of work must survive one wrong click');
    });

    test('undo past the beginning and redo past the end are no-ops', () {
      final empty = snap(editor.design);
      expect(editor.undo(), isFalse);
      expect(editor.redo(), isFalse);
      expect(snap(editor.design), empty);

      twoStage();
      final built = snap(editor.design);
      while (editor.undo()) {}
      expect(snap(editor.design), empty);
      expect(editor.undo(), isFalse);
      while (editor.redo()) {}
      expect(snap(editor.design), built);
      expect(editor.redo(), isFalse);
    });

    test('200 random ops then 200 undos is byte identical to the start', () {
      final rng = math.Random(20260816);
      final defs = [
        part('eagle-command-pod'),
        part('eagle-fuel-tank'),
        part('eagle-thruster'),
        part('eagle-legs'),
        part('eagle-rcs-block'),
        part('eagle-rcs-solo'),
      ];
      final start = snap(editor.design);

      String? anyPartId() {
        final parts = editor.design.parts;
        return parts.isEmpty
            ? null
            : parts[rng.nextInt(parts.length)].instanceId;
      }

      var applied = 0;
      for (var op = 0; op < 200; op++) {
        final def = defs[rng.nextInt(defs.length)];
        var did = false;
        switch (rng.nextInt(10)) {
          case 0:
          case 1:
            did = editor.quickStack(def);
          case 2:
          case 3:
            editor.setSymmetryCount(const [1, 2, 4][rng.nextInt(3)]);
            editor.hold(def);
            final offers = editor.pairings;
            if (offers.isNotEmpty) {
              did = editor.attachAt(offers[rng.nextInt(offers.length)]);
            }
            editor.clearHeld();
          case 4:
            final id = anyPartId();
            if (id != null) did = editor.deletePart(id);
          case 5:
            editor.select(anyPartId());
            did = editor.rollSelection(rng.nextDouble() * 2 - 1);
          case 6:
            did = editor.autoStage();
          case 7:
            editor.select(anyPartId());
            did = editor.nudgeStage(rng.nextBool() ? 1 : -1);
          case 8:
            final id = anyPartId();
            if (id != null) did = editor.detach(id);
          case 9:
            did = editor.rename('Craft ${rng.nextInt(1 << 20)}');
        }
        // Close every run: this loop is measuring STEPS, and a coalesced pair
        // of rolls would make the arithmetic below lie about what it proved.
        editor.endGesture();
        if (did) applied++;
      }

      expect(applied, greaterThan(60),
          reason: 'the walk has to actually build and wreck a craft');
      expect(editor.design.partCount, greaterThan(0),
          reason: 'and it has to leave something standing to unwind');

      var undone = 0;
      while (editor.undo()) {
        undone++;
      }
      expect(undone, applied, reason: 'one step per applied edit, no more');
      expect(snap(editor.design), start,
          reason: 'unwinding the whole session must reproduce the empty craft '
              'character for character');

      var redone = 0;
      while (editor.redo()) {
        redone++;
      }
      expect(redone, applied);
    });
  });

  group('what one pointer move costs', () {
    // A hover repaints the viewport, and one repaint reads `openTargets` once
    // and `looseParts` three times. None of those answers can change without an
    // edit, so the sweep between two edits must allocate nothing — measured
    // here by IDENTITY, which is the only claim about allocation a test can
    // make without a profiler.

    /// Distinct objects among [xs], by identity. Every reference stays reachable
    /// for the whole count, so nothing can be collected and its slot reissued.
    int distinct(List<Object> xs) {
      final seen = <Object>[];
      for (final x in xs) {
        if (!seen.any((y) => identical(y, x))) seen.add(x);
      }
      return seen.length;
    }

    /// The finished LM: 11 parts over 5 defs, the craft the editor was sized
    /// for and the one a hover sweeps across.
    void lm() {
      editor.hold(part('eagle-command-pod'));
      expect(editor.placeRoot(), isTrue);
      editor.hold(part('eagle-fuel-tank'));
      expect(editor.attachAt(seat('eagle-command-pod-0', 'stage-bottom')),
          isTrue);
      editor.setSymmetryCount(4);
      editor.hold(part('eagle-rcs-block'));
      expect(editor.attachAt(seat('eagle-command-pod-0', 'quad-1')), isTrue);
      editor.hold(part('eagle-legs'));
      expect(editor.attachAt(seat('eagle-fuel-tank-1', 'leg-1')), isTrue);
      editor.setSymmetryCount(1);
      editor.hold(part('eagle-thruster'));
      expect(editor.attachAt(seat('eagle-fuel-tank-1', 'engine-mount')), isTrue);
      editor.clearHeld();
      expect(editor.design.partCount, 11);
    }

    test('a 120-frame hover sweep re-derives nothing', () {
      lm();
      editor.select('eagle-rcs-block-2@quad-1');

      // One second of hover at 120 Hz. The overlay reads openTargets once and
      // looseParts three times per build.
      final targets = [for (var i = 0; i < 120; i++) editor.openTargets];
      final loose = [for (var i = 0; i < 360; i++) editor.looseParts];
      final groups = [for (var i = 0; i < 120; i++) editor.selection];

      // What the same second costs re-derived from the design every time: the
      // yardstick the cached reads above are measured a win against.
      final rederived = [
        for (var i = 0; i < 120; i++) AttachTargets.openNodes(editor.design)
      ];
      final regrouped = [
        for (var i = 0; i < 120; i++)
          AttachTargets.symmetryGroupOf(editor.design, 'eagle-rcs-block-2@quad-1')
      ];
      expect(distinct(rederived), 120);
      expect(distinct(regrouped), 120);
      expect(targets.first, hasLength(21),
          reason: 'the LM offers 21 open seats over 25 authored nodes, and '
              'every one of them is an AttachTarget plus the vectors under it');

      expect(distinct(targets), 1,
          reason: '120 frames over an unchanged craft must build the open-node '
              'list once, not 120 times');
      expect(distinct(loose), 1,
          reason: '360 reads of a list nothing can have changed');
      expect(distinct(groups), 1,
          reason: 'and one symmetry group for one unchanged selection');
    });

    test('an edit drops every cached answer', () {
      lm();
      final targets = editor.openTargets;
      final loose = editor.looseParts;
      expect(loose, isEmpty);

      expect(editor.detach('eagle-thruster-4'), isTrue);
      expect(identical(editor.openTargets, targets), isFalse);
      expect(editor.openTargets.where((t) => t.nodeName == 'engine-mount'),
          hasLength(1),
          reason: 'the seat the engine vacated is offered again');
      expect(identical(editor.looseParts, loose), isFalse);
      expect(editor.looseParts.map((p) => p.instanceId), ['eagle-thruster-4'],
          reason: 'a detached engine is connected to nothing and gates LAUNCH');

      expect(editor.undo(), isTrue);
      expect(editor.looseParts, isEmpty);
      expect(editor.openTargets.where((t) => t.nodeName == 'engine-mount'),
          isEmpty);
    });

    test('the selection follows a pick that is not an edit', () {
      lm();
      editor.select('eagle-rcs-block-2@quad-1');
      expect(editor.selection, hasLength(4));

      editor.select('eagle-fuel-tank-1');
      expect(editor.selection, {'eagle-fuel-tank-1'},
          reason: 'select() is view state and bumps no revision, so an answer '
              'cached on the revision alone would keep highlighting the ring '
              'the player just clicked away from');

      editor.select(null);
      expect(editor.selection, isEmpty);
    });
  });

  group('the store', () {
    test('save and load round-trip a whole craft through the editor', () async {
      final store = CraftDesignStore(namespace: 'craftDesignTest');
      final saver = CraftEditorController(
          catalog: catalog, store: store, craftName: 'Eagle');
      addTearDown(saver.dispose);

      saver.hold(part('eagle-command-pod'));
      expect(saver.placeRoot(), isTrue);
      saver.hold(part('eagle-fuel-tank'));
      expect(
          saver.attachAt(saver.pairings.firstWhere(
              (p) => p.target.nodeName == 'stage-bottom')),
          isTrue);
      saver.setSymmetryCount(4);
      saver.hold(part('eagle-legs'));
      expect(
          saver.attachAt(
              saver.pairings.firstWhere((p) => p.target.nodeName == 'leg-1')),
          isTrue);
      saver.clearHeld();
      expect(saver.rename('Eagle LM-5'), isTrue);
      saver.endGesture();

      final built = snap(saver.design);
      expect(await saver.save('apollo-11'), isTrue);

      expect(saver.clear(), isTrue);
      expect(saver.design.isEmpty, isTrue);

      expect(await saver.load('apollo-11'), isTrue);
      expect(snap(saver.design), built,
          reason: 'a save must come back as the craft that went in, rotations '
              'and staging included');

      final slots = await saver.savedSlots();
      expect(slots, hasLength(1));
      expect(slots.single.slot, 'apollo-11');
      expect(slots.single.craftName, 'Eagle LM-5');
      expect(slots.single.partCount, 6);

      // Opening a craft is itself a step: one keystroke gets the unsaved one
      // back.
      expect(saver.undo(), isTrue);
      expect(saver.design.isEmpty, isTrue);
    });

    test('loading a slot that is not there refuses without touching the craft',
        () async {
      twoStage();
      final before = snap(editor.design);
      expect(await editor.load('no-such-craft'), isFalse);
      expect(editor.blocked, contains('no-such-craft'));
      expect(snap(editor.design), before);
    });

    test('the autosave is a separate, reserved slot', () async {
      final store = CraftDesignStore(namespace: 'craftDesignTest');
      final crashed = CraftEditorController(
          catalog: catalog, store: store, craftName: 'Eagle');
      addTearDown(crashed.dispose);
      final owner = CraftEditorController(
          catalog: catalog, store: store, craftName: 'Recovered');
      addTearDown(owner.dispose);

      crashed.hold(part('eagle-command-pod'));
      expect(crashed.placeRoot(), isTrue);
      crashed.hold(part('eagle-fuel-tank'));
      expect(
          crashed.attachAt(crashed.pairings
              .firstWhere((p) => p.target.nodeName == 'stage-bottom')),
          isTrue);
      crashed.clearHeld();
      await crashed.autosave();
      final autosaved = snap(crashed.design);

      expect(await owner.restoreAutosave(), isTrue);
      expect(snap(owner.design), autosaved);
      expect(owner.canUndo, isFalse,
          reason: 'recovery is a new baseline, not a step into a craft the '
              'player has already left');

      expect(await store.list(), isEmpty,
          reason: 'the recovery copy is not a named save');
      expect(() => store.save(CraftDesignStore.autosaveSlot, crashed.design),
          throwsArgumentError);
    });

    test('a named slot can be deleted and stops being offered', () async {
      final store = CraftDesignStore(namespace: 'craftDesignTest');
      twoStage();
      await store.save('scratch', editor.design);
      expect(await store.list(), hasLength(1));

      expect(await store.delete('scratch'), isTrue);
      expect(await store.list(), isEmpty);
      expect(await store.load('scratch', catalog: catalog), isNull);
      expect(await store.delete('scratch'), isFalse);
    });

    test('a blank slot name is refused rather than saved somewhere unfindable',
        () async {
      final store = CraftDesignStore(namespace: 'craftDesignTest');
      twoStage();
      expect(() => store.save('   ', editor.design), throwsArgumentError);
      expect(() => store.load('', catalog: catalog), throwsArgumentError);
    });
  });

  group('state objects', () {
    test('UndoStack amends a run instead of stacking it', () {
      final stack = UndoStack<String>(initial: 'a');
      stack.record('first', 'b');
      stack.amend('c');
      stack.amend('d');
      expect(stack.undoCount, 1);
      expect(stack.present, 'd');
      expect(stack.undo(), 'a', reason: 'the whole run unwinds at once');
      expect(stack.redo(), 'd');
    });

    test('UndoStack drops the oldest step past its depth', () {
      final stack = UndoStack<int>(initial: 0, depth: 3);
      for (var i = 1; i <= 6; i++) {
        stack.record('step $i', i);
      }
      expect(stack.undoCount, 3);
      while (stack.undo() != null) {}
      expect(stack.present, 3, reason: 'steps 1-3 aged out of the window');
    });

    test('HeldPart cycles its own nodes and folds roll into (-pi, pi]', () {
      final decoupler = part('tr-18a-decoupler');
      var held = HeldPart(def: decoupler);
      expect(held.childNodeName, isNull);
      held = held.cycleNode(1);
      expect(held.childNodeName, decoupler.attachNodes.first.name);
      held = held.cycleNode(-1);
      expect(held.childNodeName, decoupler.attachNodes.last.name,
          reason: 'the cycle wraps');

      expect(HeldPart.normaliseRoll(3 * math.pi), closeTo(math.pi, 1e-12));
      expect(HeldPart.normaliseRoll(-math.pi / 2), closeTo(-math.pi / 2, 1e-12));
      expect(held.rolledBy(2 * math.pi).roll, closeTo(0, 1e-12));
    });

    test('SymmetryChoice reports what a ring can actually express', () {
      final ring = AttachTargets.ringContaining(part('eagle-fuel-tank'), 'leg-1');
      expect(ring, isNotNull);
      expect(const SymmetryChoice.radial(4).seatsOn(ring), 4);
      expect(const SymmetryChoice.radial(3).seatsOn(ring), 1,
          reason: 'three copies on a four-ring have nowhere even to sit');
      expect(const SymmetryChoice.mirrored().seatsOn(ring), 2);
      expect(SymmetryChoice.single.seatsOn(null), 1);
    });
  });
}
