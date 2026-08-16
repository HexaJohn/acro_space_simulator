// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The four UX flows of spec section 6, driven through the REAL screen.
//
// Nothing here reaches for the controller to make a change: every part is
// picked out of the catalog pane by name, every mate is a `tapAt` on a pixel
// that `CraftEditorCamera.project` says an attach node occupies, and every
// undo, symmetry choice and delete goes through a toolbar control. What is
// asserted afterwards is the resulting `CraftDesign` — which node each part
// names, that four copies name four DIFFERENT ring members, and that the whole
// thing still round-trips through `CraftDesignCodec`.
//
// That last assertion is the point of the ring-based symmetry decision. The two
// rejected designs synthesised node names for surface mounts, and
// `CraftDesign.fromParts` re-validates every attachment against its parent's
// def on load — so a craft with four landing legs would have saved cleanly and
// then been permanently unopenable. Flows 3 and 4 are exactly the flows that
// would have produced one.
//
// Headless: `fs.SceneView` never appears (the shader bundle needs a GPU
// context), so the whole editor here is the overlay plus oriented-box picking
// off `PartDef.size`. That is the claim, not a limitation of the harness.
import 'package:acro_space_simulator/domain/craft/attach_solver.dart';
import 'package:acro_space_simulator/domain/craft/craft_design_codec.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_catalog_pane.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_painter.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_viewport.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_staging_pane.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_stats_pane.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_tree_pane.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft_assembly_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const double _pi = 3.1415926535897932;

/// Catalog names, spelled once. A part renamed in `lem_parts.dart` should break
/// this file in one place with a readable message, not in six taps.
const String _ascent = 'Eagle Ascent Stage';
const String _descent = 'Eagle Descent Stage';
const String _quad = 'Eagle RCS Quad (4 x R-4D)';
const String _leg = 'Eagle Landing Gear Leg';
const String _engine = 'Eagle Descent Engine (DPS)';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Pump the whole screen at [size] and hand back its viewport state, which is
  /// the only thing a test needs that the widget tree does not expose: the live
  /// camera, so a node's pixel can be computed rather than guessed.
  Future<CraftEditorViewportState> pumpEditor(
    WidgetTester t, {
    Size size = const Size(1280, 800),
    List<LaunchSite> sites = const [],
  }) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: CraftAssemblyScreen(launchSites: sites)));
    await t.pump();
    return t.state<CraftEditorViewportState>(find.byType(CraftEditorViewport));
  }

  /// Tear the tree down INSIDE the test.
  ///
  /// The screen debounces its autosave on a real `Timer`, and the widget
  /// binding checks for pending timers before any `addTearDown` registered in a
  /// test body runs. Disposing here is what cancels it — and it also exercises
  /// the dispose path, which writes the recovery copy.
  Future<void> closeEditor(WidgetTester t) => t.pumpWidget(const SizedBox());

  CraftEditorController controllerOf(CraftEditorViewportState vp) =>
      vp.controller;

  /// Reveal a widget inside one of the horizontally scrolling strips and tap it.
  ///
  /// The category chips do not all fit in a 280 px catalog column, which is what
  /// the strip scrolls for; a test that tapped them blind would pass or fail on
  /// the column width.
  Future<void> revealAndTap(WidgetTester t, Finder finder) async {
    await t.ensureVisible(finder);
    await t.pump();
    await t.tap(finder);
    await t.pump();
  }

  Finder inCatalog(Finder matching) => find.descendant(
      of: find.byType(CraftCatalogPane), matching: matching);

  /// Pick [name] up off the catalog: the chip for its category, then the row.
  ///
  /// The roster is a lazy `ListView` and the narrow sheet can be two rows tall,
  /// so a part further down the category has simply not been built yet. A
  /// player scrolls to it; so does this.
  Future<void> holdPart(
      WidgetTester t, String category, String name) async {
    await revealAndTap(t, inCatalog(find.text(category)));
    final row = inCatalog(find.text(name));
    if (row.evaluate().isEmpty) {
      await t.scrollUntilVisible(row, 80,
          // The chip strip is the pane's first scrollable; the roster is its
          // last.
          scrollable: inCatalog(find.byType(Scrollable)).last);
      await t.pump();
    }
    await revealAndTap(t, row);
  }

  /// Where an open attach node lands on screen, in GLOBAL coordinates.
  Offset pixelOf(
      WidgetTester t, CraftEditorViewportState vp, String nodeName) {
    final target = controllerOf(vp)
        .openTargets
        .where((x) => x.nodeName == nodeName)
        .toList();
    expect(target, hasLength(1),
        reason: 'exactly one open node called "$nodeName" must be on the craft');
    final local = vp.camera.project(target.single.positionInCraft);
    expect(local, isNotNull,
        reason: '"$nodeName" must be in front of the near plane');
    return t.getTopLeft(find.byType(CraftEditorViewport)) + local!;
  }

  /// Point the turntable, then mate the held part onto [nodeName] by tapping the
  /// pixel that node projects to — and assert the mate landed on THAT node.
  ///
  /// The assertion is the flow's real content. Every marker on a rocket is a
  /// small circle among other small circles, so "a part appeared" is not
  /// evidence that the editor put it where the player aimed.
  Future<void> mateOnto(
    WidgetTester t,
    CraftEditorViewportState vp,
    String nodeName, {
    required double azimuth,
    required double elevation,
    required double distanceM,
    required Vector3 pivot,
  }) async {
    vp.setPose(
        azimuth: azimuth,
        elevation: elevation,
        distanceM: distanceM,
        pivot: pivot);
    await t.pump();
    final before = controllerOf(vp).design.partCount;
    await t.tapAt(pixelOf(t, vp, nodeName));
    await t.pump();
    final design = controllerOf(vp).design;
    expect(design.partCount, greaterThan(before),
        reason: 'the tap on "$nodeName" placed nothing — '
            '${controllerOf(vp).blocked ?? "no target was under the cursor"}');
    expect(design.parts.last.attachment?.parentNode, isNotNull);
  }

  /// Park the mouse on a GLOBAL pixel without pressing anything: the only way
  /// to get a live pick, since hover and tap share one path.
  Future<void> hoverAt(WidgetTester t, Offset at) async {
    await t.sendEventToBinding(
        TestPointer(7, PointerDeviceKind.mouse).hover(at));
    await t.pump();
  }

  /// The overlay painter currently mounted, out of the several `CustomPaint`s
  /// any `MaterialApp` carries. Its snapshot is the 2D half of the editor —
  /// the half that keeps working with no renderer at all.
  CraftEditorOverlay overlayOf(WidgetTester t) => t
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((w) => w.painter)
      .whereType<CraftEditorPainter>()
      .single
      .data;

  // ------------------------------------------------------------------
  group('the four flows build a Lunar Module', () {
    testWidgets('flow 1 — the ascent stage becomes the craft root',
        (t) async {
      final vp = await pumpEditor(t);
      final c = controllerOf(vp);
      expect(c.design.isEmpty, isTrue);

      await holdPart(t, 'Command', _ascent);
      expect(c.held?.def.id, 'eagle-command-pod',
          reason: 'tapping a catalog row puts the part on the cursor');

      // An empty craft has nothing to aim at: the first part goes on the pad at
      // the craft origin and any click in the view places it.
      await t.tapAt(t.getCenter(find.byType(CraftEditorViewport)));
      await t.pump();

      expect(c.design.partCount, 1);
      final root = c.design.root!;
      expect(root.def.id, 'eagle-command-pod');
      expect(root.position, Vector3.zero);
      expect(root.attachment, isNull);
      expect(c.held, isNull, reason: 'a craft has exactly one root');
      expect(c.selectedId, root.instanceId);
      expect(t.takeException(), isNull);

      await closeEditor(t);
    });

    testWidgets('flow 2 — the descent stage stacks under it', (t) async {
      final vp = await pumpEditor(t);
      final c = controllerOf(vp);

      await holdPart(t, 'Command', _ascent);
      await t.tapAt(t.getCenter(find.byType(CraftEditorViewport)));
      await t.pump();

      await holdPart(t, 'Fuel', _descent);
      // From below, so the pod's aft seat faces the eye.
      await mateOnto(t, vp, 'stage-bottom',
          azimuth: -3 * _pi / 4,
          elevation: -0.5,
          distanceM: 12,
          pivot: const Vector3(0, 0, -1));

      expect(c.design.partCount, 2);
      final stage = c.design.parts.last;
      expect(stage.def.id, 'eagle-fuel-tank');
      expect(stage.attachment!.parentInstanceId, c.design.rootId);
      expect(stage.attachment!.parentNode, 'stage-bottom');
      // `dock-top` is 0.81 m and `engine-mount` is 1.5 m; only `deck-top`
      // shares the pod's 4.2 m stack class, so the pairing had one answer.
      expect(stage.attachment!.childNode, 'deck-top');
      expect(c.held?.def.id, 'eagle-fuel-tank',
          reason: 'the held part persists so the next click stacks another');

      // The seat is spent from BOTH ends now.
      expect(c.design.isStackNodeOccupied(c.design.rootId!, 'stage-bottom'),
          isTrue);
      expect(
          c.openTargets.where((x) => x.nodeName == 'stage-bottom'), isEmpty);

      await closeEditor(t);
    });

    testWidgets('flow 3 — x4 mounts four RCS quads on four real nodes',
        (t) async {
      final vp = await pumpEditor(t);
      final c = controllerOf(vp);

      await holdPart(t, 'Command', _ascent);
      await t.tapAt(t.getCenter(find.byType(CraftEditorViewport)));
      await t.pump();

      await holdPart(t, 'RCS', _quad);
      // The chip is disabled until something on the craft carries a ring that
      // can express it — the pod's quad-1..4 do.
      await revealAndTap(t, find.byKey(const ValueKey('symmetry-4')));
      expect(c.symmetry.count, 4);

      await mateOnto(t, vp, 'quad-1',
          azimuth: -3 * _pi / 4,
          elevation: 0.35,
          distanceM: 9,
          pivot: Vector3.zero);

      final quads = c.design.parts
          .where((p) => p.def.id == 'eagle-rcs-block')
          .toList();
      expect(quads, hasLength(4), reason: 'one click, four parts, one step');
      expect(c.undoCount, 2, reason: 'place root + mount x4');

      // EACH copy names its OWN authored node. This is the whole symmetry
      // model: four attachments claiming one node would be a design that never
      // loads again.
      expect(
        {for (final q in quads) q.attachment!.parentNode},
        {'quad-1', 'quad-2', 'quad-3', 'quad-4'},
      );
      for (final q in quads) {
        expect(q.attachment!.childNode, 'mount');
        expect(q.attachment!.parentInstanceId, c.design.rootId);
      }

      // And the geometry is a ring, not four parts in a heap: one radius, one
      // height, evenly spaced.
      final radii = [
        for (final q in quads)
          Vector3(q.position.x, q.position.y, 0).length,
      ];
      for (final r in radii) {
        expect(r, closeTo(radii.first, 1e-9));
      }
      for (final q in quads) {
        expect(q.position.z, closeTo(quads.first.position.z, 1e-9));
      }
      expect(radii.first, greaterThan(1.5));

      // Selecting one selects the group, which is what makes Q/E and staging
      // one action instead of four.
      expect(c.symmetryGroupOf(quads.first.instanceId), hasLength(4));

      // The regression the ring design exists for: a saved craft with radial
      // mounts must decode again.
      const codec = CraftDesignCodec();
      final reopened =
          codec.decode(codec.encode(c.design), catalog: PartCatalog.standard());
      expect(reopened.partCount, 5);
      expect(
        {
          for (final p in reopened.parts)
            if (p.def.id == 'eagle-rcs-block') p.attachment!.parentNode
        },
        {'quad-1', 'quad-2', 'quad-3', 'quad-4'},
      );

      await closeEditor(t);
    });

    testWidgets('flow 4 — four legs, an engine, and staging', (t) async {
      final vp = await pumpEditor(t);
      final c = controllerOf(vp);

      // --- the whole vehicle, entirely through the widget layer ---
      await holdPart(t, 'Command', _ascent);
      await t.tapAt(t.getCenter(find.byType(CraftEditorViewport)));
      await t.pump();

      await holdPart(t, 'Fuel', _descent);
      await mateOnto(t, vp, 'stage-bottom',
          azimuth: -3 * _pi / 4,
          elevation: -0.5,
          distanceM: 12,
          pivot: const Vector3(0, 0, -1));

      await holdPart(t, 'RCS', _quad);
      await revealAndTap(t, find.byKey(const ValueKey('symmetry-4')));
      await mateOnto(t, vp, 'quad-1',
          azimuth: -3 * _pi / 4,
          elevation: 0.35,
          distanceM: 13,
          pivot: const Vector3(0, 0, -1));

      await holdPart(t, 'Gear', _leg);
      // The gear ring starts at azimuth 0, unlike the RCS ring's 45 degrees —
      // the front leg is the one under the hatch that carries the ladder.
      await mateOnto(t, vp, 'leg-1',
          azimuth: -_pi / 2,
          elevation: 0.30,
          distanceM: 13,
          pivot: const Vector3(0, 0, -2));

      await holdPart(t, 'Rocket', _engine);
      await mateOnto(t, vp, 'engine-mount',
          azimuth: -3 * _pi / 4,
          elevation: -0.55,
          distanceM: 15,
          pivot: const Vector3(0, 0, -2));

      expect(c.design.partCount, 11,
          reason: 'pod + descent + 4 quads + 4 legs + engine');

      final legs =
          c.design.parts.where((p) => p.def.id == 'eagle-legs').toList();
      expect(legs, hasLength(4));
      expect(
        {for (final l in legs) l.attachment!.parentNode},
        {'leg-1', 'leg-2', 'leg-3', 'leg-4'},
      );
      for (final l in legs) {
        expect(l.attachment!.childNode, 'outrigger');
        expect(l.attachment!.parentInstanceId,
            isNot(c.design.rootId)); // they hang off the descent stage
      }

      final engine = c.design.parts
          .firstWhere((p) => p.def.id == 'eagle-thruster');
      expect(engine.attachment!.parentNode, 'engine-mount');
      expect(engine.attachment!.childNode, 'mount');

      // --- staging ---
      // The descent engine is engine number two (the ascent stage carries the
      // APS), so the one-shot auto-stage has already fired inside the attaching
      // edit. The pane's AUTO STAGE is the player's way to ask again.
      expect(c.autoStaged, isTrue);
      expect(c.design.stages.length, greaterThan(1),
          reason: 'a craft whose parts all sit in group 0 reports the delta-v '
              'of the whole vehicle under the label of one stage');

      await revealAndTap(t, find.byKey(const ValueKey('tab-staging')));
      expect(find.byType(CraftStagingPane), findsOneWidget);
      await revealAndTap(t, find.text('AUTO STAGE'));
      expect(c.design.stages.length, greaterThan(1));
      expect(c.design.stages, List.generate(c.design.stages.length, (i) => i),
          reason: 'auto-staging renumbers dense, so the list has no holes');

      // Every stage a part claims exists, which is what `fromParts` re-checks.
      const codec = CraftDesignCodec();
      final reopened =
          codec.decode(codec.encode(c.design), catalog: PartCatalog.standard());
      expect(reopened.partCount, 11);

      await closeEditor(t);
    });
  });

  // ------------------------------------------------------------------
  group('the shell around the flows', () {
    testWidgets('deleting one quad takes the group, and undo brings it back',
        (t) async {
      final vp = await pumpEditor(t);
      final c = controllerOf(vp);

      await holdPart(t, 'Command', _ascent);
      await t.tapAt(t.getCenter(find.byType(CraftEditorViewport)));
      await t.pump();
      await holdPart(t, 'RCS', _quad);
      await revealAndTap(t, find.byKey(const ValueKey('symmetry-4')));
      await mateOnto(t, vp, 'quad-1',
          azimuth: -3 * _pi / 4,
          elevation: 0.35,
          distanceM: 9,
          pivot: Vector3.zero);
      expect(c.design.partCount, 5);

      const codec = CraftDesignCodec();
      final whole = codec.encode(c.design);

      // Select through the TREE pane, which collapses the four quads to one row
      // — the same grouping the delete then acts on.
      await revealAndTap(t, find.byKey(const ValueKey('tab-tree')));
      await revealAndTap(
          t, find.descendant(of: find.byType(CraftTreePane), matching: find.text(_quad)));
      expect(c.selection, hasLength(4));

      await revealAndTap(t, find.byKey(const ValueKey('delete-selection')));
      expect(c.design.partCount, 1,
          reason: 'deleting one of four RCS quads and leaving three is almost '
              'never what the player meant');

      await revealAndTap(t, find.byKey(const ValueKey('editor-undo')));
      expect(c.design.partCount, 5);
      expect(codec.encode(c.design), whole,
          reason: 'undo must restore the craft exactly, not approximately');

      await revealAndTap(t, find.byKey(const ValueKey('editor-redo')));
      expect(c.design.partCount, 1);

      await closeEditor(t);
    });

    testWidgets('Clear is one undoable step', (t) async {
      final vp = await pumpEditor(t);
      final c = controllerOf(vp);

      await holdPart(t, 'Command', _ascent);
      await t.tapAt(t.getCenter(find.byType(CraftEditorViewport)));
      await t.pump();
      expect(find.byKey(const ValueKey('craft-clear')), findsOneWidget);

      await revealAndTap(t, find.byKey(const ValueKey('craft-clear')));
      expect(c.design.isEmpty, isTrue);
      // Gone, so the action is gone with it.
      expect(find.byKey(const ValueKey('craft-clear')), findsNothing);

      await revealAndTap(t, find.byKey(const ValueKey('editor-undo')));
      expect(c.design.partCount, 1);

      await closeEditor(t);
    });

    testWidgets('Esc drops the held part after the viewport is clicked',
        (t) async {
      final vp = await pumpEditor(t);
      final c = controllerOf(vp);

      await holdPart(t, 'Command', _ascent);
      await t.tapAt(t.getCenter(find.byType(CraftEditorViewport)));
      await t.pump();

      await holdPart(t, 'RCS', _quad);
      expect(c.held, isNotNull);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(c.held, isNull);

      await closeEditor(t);
    });

    testWidgets('the symmetry chips say what the craft can actually express',
        (t) async {
      final vp = await pumpEditor(t);
      final c = controllerOf(vp);

      // An empty craft has no rings at all, so only x1 is on offer. Greying it
      // is the honest answer; placing one part while the chip reads x4 is not.
      expect(
          t.widget<ChoiceChip>(find.byKey(const ValueKey('symmetry-4'))).onSelected,
          isNull);

      await holdPart(t, 'Command', _ascent);
      await t.tapAt(t.getCenter(find.byType(CraftEditorViewport)));
      await t.pump();

      expect(
          t.widget<ChoiceChip>(find.byKey(const ValueKey('symmetry-4'))).onSelected,
          isNotNull,
          reason: 'the pod carries a four-member quad ring');
      await revealAndTap(t, find.byKey(const ValueKey('symmetry-2')));
      expect(c.symmetry.count, 2);
      await revealAndTap(t, find.byKey(const ValueKey('symmetry-mirror')));
      expect(c.symmetry.mirror, isTrue);
      await revealAndTap(t, find.byKey(const ValueKey('symmetry-mirror')));
      expect(c.symmetry.mirror, isFalse);
      expect(c.symmetry.isSingle, isTrue,
          reason: 'mirror and radial are alternatives, so turning mirror off '
              'returns to one copy rather than to the previous count');

      await closeEditor(t);
    });
  });

  // ------------------------------------------------------------------
  group('both layouts', () {
    testWidgets('wide puts the catalog, the viewport and the inspector side by '
        'side with no overflow', (t) async {
      await pumpEditor(t);
      expect(find.byType(CraftCatalogPane), findsOneWidget);
      expect(find.byType(CraftEditorViewport), findsOneWidget);
      // The inspector opens on STATS; TREE and STAGING are behind it and are
      // reached by their tabs, which the delete case above drives.
      expect(find.byType(CraftStatsPane), findsOneWidget);

      final view = t.getRect(find.byType(CraftEditorViewport));
      final catalog = t.getRect(find.byType(CraftCatalogPane));
      expect(catalog.right, lessThanOrEqualTo(view.left + 1));
      expect(view.width, greaterThan(300),
          reason: 'the viewport is the subject of this screen');
      expect(view.height, greaterThan(400));
      expect(t.takeException(), isNull);

      await closeEditor(t);
    });

    testWidgets('narrow stacks the viewport over a tabbed sheet and collapses '
        'it to place', (t) async {
      final vp =
          await pumpEditor(t, size: const Size(400, 800));
      final c = controllerOf(vp);

      final view = t.getRect(find.byType(CraftEditorViewport));
      final sheet = t.getRect(find.byType(CraftCatalogPane));
      expect(view.bottom, lessThanOrEqualTo(sheet.top + 1),
          reason: 'the viewport is above the sheet, not beside it');
      expect(view.height, greaterThan(sheet.height),
          reason: 'a 40%-tall view of a 10 m craft is unusable, so the split '
              'the old narrow layout used is deliberately broken');

      // Picking a part folds the sheet away so the placing tap has the whole
      // craft to aim at — two taps to place a part on a phone.
      await holdPart(t, 'Command', _ascent);
      expect(find.byKey(const ValueKey('placing-bar')), findsOneWidget);
      final placingView = t.getRect(find.byType(CraftEditorViewport));
      expect(placingView.height, greaterThan(view.height));

      await t.tapAt(t.getCenter(find.byType(CraftEditorViewport)));
      await t.pump();
      expect(c.design.partCount, 1);
      // Nothing is held any more, so the sheet comes back on its own.
      expect(find.byKey(const ValueKey('placing-bar')), findsNothing);
      expect(t.takeException(), isNull);

      await closeEditor(t);
    });

    testWidgets('the narrowest wide window still fits three columns',
        (t) async {
      // One pixel past the breakpoint is where the three columns are tightest:
      // both side columns sit on their floors and the viewport gets what is
      // left. A craft is built first, because every readout that can overflow
      // only exists once there is something to read out.
      final vp = await pumpEditor(t, size: const Size(961, 800));
      await holdPart(t, 'Command', _ascent);
      await t.tapAt(t.getCenter(find.byType(CraftEditorViewport)));
      await t.pump();
      expect(controllerOf(vp).design.partCount, 1);

      for (final tab in const ['tree', 'staging', 'stats']) {
        await revealAndTap(t, find.byKey(ValueKey('tab-$tab')));
        expect(t.takeException(), isNull,
            reason: 'the $tab tab overflowed a 961 px window');
      }
      expect(t.getRect(find.byType(CraftEditorViewport)).width,
          greaterThan(320),
          reason: 'below this the three-column layout is not worth having, '
              'which is what the breakpoint is set from');
      await closeEditor(t);
    });

    for (final size in const [Size(400, 800), Size(800, 600)]) {
      testWidgets('every pane is reachable in the narrow sheet at '
          '${size.width}x${size.height}', (t) async {
        // 800x600 is the harness default and the band this screen deliberately
        // treats as narrow: three columns do not fit a 3D view between them at
        // that width, so a tablet in portrait gets the stacked layout.
        final vp = await pumpEditor(t, size: size);
        await holdPart(t, 'Command', _ascent);
        await t.tapAt(t.getCenter(find.byType(CraftEditorViewport)));
        await t.pump();
        expect(controllerOf(vp).design.partCount, 1);

        for (final tab in const ['stats', 'tree', 'staging', 'parts']) {
          await revealAndTap(t, find.byKey(ValueKey('tab-$tab')));
          expect(t.takeException(), isNull,
              reason: 'the $tab tab overflowed at ${size.width} px');
        }
        await closeEditor(t);
      });
    }
  });

  // ------------------------------------------------------------------
  // Moving a part is RE-MATING it: there is no free placement to drag to, so
  // the flow is "select the part, choose another compatible seat" and the
  // domain carries the whole subtree. The offer set and the commit live on the
  // controller; what is exercised here is that a player can reach them, in
  // BOTH layouts, from the pane that has to keep working when the 3D view does
  // not.
  group('a part placed on the wrong node can be moved', () {
    /// Pod root, one RCS quad on `quad-1`, nothing held, TREE showing.
    Future<CraftEditorViewportState> pumpQuadOnPod(
        WidgetTester t, Size size) async {
      final vp = await pumpEditor(t, size: size);
      await holdPart(t, 'Command', _ascent);
      await t.tapAt(t.getCenter(find.byType(CraftEditorViewport)));
      await t.pump();

      await holdPart(t, 'RCS', _quad);
      await mateOnto(t, vp, 'quad-1',
          azimuth: -3 * _pi / 4,
          elevation: 0.35,
          distanceM: 9,
          pivot: Vector3.zero);
      // The held part persists after a mate, and in the narrow layout that
      // keeps the sheet folded to the placing bar — so the TREE tab is behind
      // one Esc, exactly as it is for a player.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await revealAndTap(t, find.byKey(const ValueKey('tab-tree')));
      return vp;
    }

    Finder inTree(Finder matching) =>
        find.descendant(of: find.byType(CraftTreePane), matching: matching);

    for (final size in const [Size(1280, 800), Size(400, 800)]) {
      testWidgets('the quad re-seats onto quad-3 at ${size.width} px',
          (t) async {
        final vp = await pumpQuadOnPod(t, size);
        final c = controllerOf(vp);
        final rootId = c.design.rootId!;
        final quad =
            c.design.parts.firstWhere((p) => p.def.id == 'eagle-rcs-block');
        final wasAt = quad.position;
        final steps = c.undoCount;

        await revealAndTap(
            t, inTree(find.byKey(ValueKey('part-menu-${quad.instanceId}'))));
        await t.pumpAndSettle();
        await t.tap(find.text('Move to...'));
        await t.pumpAndSettle();

        // The offer set is FILTERED, not a copy of the node list. `dock-top` is
        // the pod's FIRST authored node — so a pane that listed open nodes
        // instead of pairings would put it at the top of this list — and it is
        // a 0.81 m stack seat, which the quad's single 0.25 m surface mount
        // cannot take.
        expect(find.byKey(ValueKey('move-to-$rootId-dock-top-mount')),
            findsNothing);
        // The offer list is a lazy `ListView`, and the narrow sheet is a few
        // rows tall; a player scrolls to the seat they want, so does this.
        final seat = find.byKey(ValueKey('move-to-$rootId-quad-3-mount'));
        if (seat.evaluate().isEmpty) {
          await t.scrollUntilVisible(seat, 60,
              scrollable: find
                  .descendant(
                      of: find.byType(CraftTreePane),
                      matching: find.byType(Scrollable))
                  .first);
          await t.pump();
        }
        expect(seat, findsOneWidget,
            reason: 'quad-3 is an open ring peer and must be offered');

        await revealAndTap(t, seat);

        expect(c.design.partCount, 2,
            reason: 'a move re-seats a part, it does not add or drop one');
        final moved =
            c.design.parts.firstWhere((p) => p.def.id == 'eagle-rcs-block');
        expect(moved.attachment!.parentNode, 'quad-3');
        expect(moved.attachment!.childNode, 'mount');

        // Where the seat actually is, not merely "somewhere else": the commit
        // must land on the same solve the ghost preview uses.
        final want = AttachSolver.standard.solveMate(
          parentNodeInBody: c.design.partById(rootId)!.nodeInBody('quad-3')!,
          childNodeLocal: moved.def.node('mount')!,
        );
        expect((moved.position - want.position).length, lessThan(1e-9));
        expect((moved.position - wasAt).length, greaterThan(1.0),
            reason: 'quad-1 and quad-3 are opposite corners of a 1.80 m ring');

        // One step, named, and reversible — the move went through the same
        // funnel every other edit does.
        expect(c.undoCount, steps + 1);
        expect(c.undoLabel, startsWith('move '));
        // The offer list closes on a commit; it is not a mode to escape from.
        expect(find.byKey(const ValueKey('move-cancel')), findsNothing);

        await revealAndTap(t, find.byKey(const ValueKey('editor-undo')));
        expect(
            c.design.parts
                .firstWhere((p) => p.def.id == 'eagle-rcs-block')
                .attachment!
                .parentNode,
            'quad-1');

        await closeEditor(t);
      });
    }

    testWidgets('a refused move says why instead of doing nothing', (t) async {
      final vp = await pumpEditor(t);
      final c = controllerOf(vp);

      await holdPart(t, 'Command', _ascent);
      await t.tapAt(t.getCenter(find.byType(CraftEditorViewport)));
      await t.pump();
      await holdPart(t, 'RCS', _quad);
      await mateOnto(t, vp, 'quad-1',
          azimuth: -3 * _pi / 4,
          elevation: 0.35,
          distanceM: 9,
          pivot: Vector3.zero);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await holdPart(t, 'Fuel', _descent);
      await mateOnto(t, vp, 'stage-bottom',
          azimuth: -3 * _pi / 4,
          elevation: -0.5,
          distanceM: 12,
          pivot: const Vector3(0, 0, -1));
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await revealAndTap(t, find.byKey(const ValueKey('tab-tree')));

      final quad =
          c.design.parts.firstWhere((p) => p.def.id == 'eagle-rcs-block');
      final descent =
          c.design.parts.firstWhere((p) => p.def.id == 'eagle-fuel-tank');

      await revealAndTap(t, inTree(find.byKey(ValueKey('part-menu-${quad.instanceId}'))));
      await t.pumpAndSettle();
      await t.tap(find.text('Move to...'));
      await t.pumpAndSettle();

      final seat = find.byKey(
          ValueKey('move-to-${descent.instanceId}-leg-1-mount'));
      expect(seat, findsOneWidget,
          reason: 'the descent stage carries a surface leg ring the quad fits');
      await t.ensureVisible(seat);
      await t.pump();

      // Every row in this list is a mate the domain agreed to WHEN THE LIST WAS
      // BUILT. Deleting the seat's owner without pumping leaves the row on
      // screen for exactly as long as a real frame would — the touch sheet's
      // Delete, or a Delete key, landing between the build and the tap.
      c.deletePart(descent.instanceId);
      await t.tap(seat);
      await t.pump();

      expect(c.design.partCount, 2, reason: 'the pod and the quad remain');
      expect(c.design.parts.firstWhere((p) => p.def.id == 'eagle-rcs-block')
          .attachment!.parentNode, 'quad-1',
          reason: 'a refused move leaves the craft exactly as it was');
      expect(c.blocked, isNotNull);
      // The sentence is in the pane, not only on the controller: this list is
      // the path that has to keep working when the viewport does not, and in
      // the narrow layout the viewport's HUD is off screen while it is open.
      expect(inTree(find.text(c.blocked!)), findsOneWidget);
      expect(find.byKey(const ValueKey('move-cancel')), findsOneWidget,
          reason: 'the offer stays open so the refusal is read beside the '
              'alternatives');

      await closeEditor(t);
    });
  });

  // ------------------------------------------------------------------
  group('an aim with no legal mate', () {
    testWidgets('previews the refusal in red where the part would have landed',
        (t) async {
      final vp = await pumpEditor(t);
      final c = controllerOf(vp);

      await holdPart(t, 'Command', _ascent);
      await t.tapAt(t.getCenter(find.byType(CraftEditorViewport)));
      await t.pump();

      await holdPart(t, 'RCS', _quad);
      // The quad authors one node: a 0.25 m SURFACE mount. `stage-bottom` is a
      // 4.20 m STACK seat, so the two cannot mate under any aim.
      expect(c.pairings.where((p) => p.target.nodeName == 'stage-bottom'),
          isEmpty);

      vp.setPose(
          azimuth: -3 * _pi / 4,
          elevation: -0.5,
          distanceM: 12,
          pivot: const Vector3(0, 0, -1));
      await t.pump();
      await hoverAt(t, pixelOf(t, vp, 'stage-bottom'));

      expect(vp.hoveredPairing, isNull,
          reason: 'nothing the quad can mate is under the cursor');
      expect(vp.refusedTarget?.nodeName, 'stage-bottom');

      // The scene contains ONE ghost and it is the refused one. An aim that
      // draws nothing at all reads as a broken preview; this is the branch
      // `CraftGhost.valid` and `ghostInvalidRgb` exist for.
      expect(vp.ghosts, hasLength(1));
      expect(vp.ghosts.single.valid, isFalse);
      expect(vp.ghosts.single.def.id, 'eagle-rcs-block');

      // Posed by the same solve a legal preview uses, so the red ghost stands
      // exactly where the part would have gone had the mate been allowed.
      final want = AttachSolver.standard.solveMate(
        parentNodeInBody:
            c.design.root!.nodeInBody('stage-bottom')!,
        childNodeLocal: c.held!.def.node('mount')!,
      );
      expect((vp.ghosts.single.position - want.position).length,
          lessThan(1e-9));

      // And the same refusal in words, for the 2D half of the editor — which
      // is all there is on a machine with no shader bundle.
      expect(
          overlayOf(t).hud.any((line) =>
              line.contains('stage-bottom') && line.contains(_quad)),
          isTrue,
          reason: 'the HUD lines were ${overlayOf(t).hud}');

      // Clicking a refusal commits nothing.
      await t.tapAt(pixelOf(t, vp, 'stage-bottom'));
      await t.pump();
      expect(c.design.partCount, 1);
      expect(c.held?.def.id, 'eagle-rcs-block',
          reason: 'a near miss must not cost the player the held part');

      await closeEditor(t);
    });

    testWidgets('picking up a different part re-answers the parked cursor',
        (t) async {
      // Holding a part is view state and bumps no revision, so nothing about
      // the craft changed — but the question the cursor is asking did. A stale
      // answer here is a red ghost of a part that fits the seat perfectly.
      final vp = await pumpEditor(t);
      final c = controllerOf(vp);

      await holdPart(t, 'Command', _ascent);
      await t.tapAt(t.getCenter(find.byType(CraftEditorViewport)));
      await t.pump();

      await holdPart(t, 'RCS', _quad);
      vp.setPose(
          azimuth: -3 * _pi / 4,
          elevation: -0.5,
          distanceM: 12,
          pivot: const Vector3(0, 0, -1));
      await t.pump();
      await hoverAt(t, pixelOf(t, vp, 'stage-bottom'));
      expect(vp.refusedTarget?.nodeName, 'stage-bottom');

      // The descent stage's `deck-top` is the same 4.20 m stack class, so the
      // very seat that refused the quad accepts this one.
      await holdPart(t, 'Fuel', _descent);
      expect(vp.refusedTarget, isNull);
      expect(vp.hoveredTarget?.nodeName, 'stage-bottom');
      expect(vp.ghosts, hasLength(1));
      expect(vp.ghosts.single.def.id, 'eagle-fuel-tank');
      expect(vp.ghosts.single.valid, isTrue);
      expect(c.design.partCount, 1);

      await closeEditor(t);
    });

    testWidgets('a legal aim is still previewed in green, once per seat',
        (t) async {
      final vp = await pumpEditor(t);
      final c = controllerOf(vp);

      await holdPart(t, 'Command', _ascent);
      await t.tapAt(t.getCenter(find.byType(CraftEditorViewport)));
      await t.pump();

      await holdPart(t, 'RCS', _quad);
      await revealAndTap(t, find.byKey(const ValueKey('symmetry-4')));
      vp.setPose(
          azimuth: -3 * _pi / 4,
          elevation: 0.35,
          distanceM: 9,
          pivot: Vector3.zero);
      await t.pump();
      await hoverAt(t, pixelOf(t, vp, 'quad-1'));

      expect(vp.refusedTarget, isNull);
      expect(vp.ghosts, hasLength(4),
          reason: 'x4 on the pod ring previews four seats');
      expect(vp.ghosts.every((g) => g.valid), isTrue,
          reason: 'every member of a surface ring the aim was approved on is '
              'legal, so a red one here would be a lie');
      expect(c.blocked, isNull);

      await closeEditor(t);
    });
  });
}
