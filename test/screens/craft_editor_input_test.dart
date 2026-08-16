// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The craft editor's INPUT MAP, asserted through a real widget tree.
//
// Headless, so `fs.SceneView` draws nothing — and that is the point. Every
// pixel this suite computes comes from `CraftEditorCamera.project`, the same
// pure function the overlay paints through, so the tests exercise the whole
// stack from a raw pointer event to a committed mate without an Impeller
// context anywhere in the process. What they cannot see is the RENDERED image;
// a flip that lives in the widget tree (a gesture recogniser nested inside
// `Transform.flip`) needs the screenshot test to catch it, and nothing here
// should be read as clearing that risk.
//
// The mouse-button cases are a regression suite. This codebase has already
// shipped the bug once: the stock `GestureDetector` scale/tap recognisers
// accept EVERY mouse button, so a middle drag orbited twice — once through the
// gesture, once through the `Listener` — and a right press orbited on the few
// pixels of jitter a physical click carries. In this editor the primary button
// also places parts, so a button leak is a craft with parts on it nobody asked
// for.
import 'dart:ui' as ui;

import 'package:acro_space_simulator/adapters/presenters/craft_editor_camera.dart';
import 'package:acro_space_simulator/adapters/presenters/craft_editor_pick.dart';
import 'package:acro_space_simulator/domain/craft/attach_targets.dart';
import 'package:acro_space_simulator/domain/craft/craft_balance.dart';
import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_catalog_pane.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_painter.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_state.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_viewport.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const double _pi = 3.1415926535897932;

/// The catalog row this suite drags, spelled once.
const String _quad = 'Eagle RCS Quad (4 x R-4D)';

void main() {
  late CraftEditorController controller;
  late GlobalKey<CraftEditorViewportState> key;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = CraftEditorController(catalog: PartCatalog.standard());
    key = GlobalKey<CraftEditorViewportState>();
  });

  tearDown(() => controller.dispose());

  /// Pump the viewport at a fixed 1200x800 so every projected pixel in this
  /// file is reproducible.
  Future<CraftEditorViewportState> pumpViewport(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: CraftEditorViewport(
        key: key,
        controller: controller,
        // No asset bundle worth warming here, and a parse isolate would only be
        // something the test then had to wait on.
        prewarmModels: false,
      ),
    ));
    await t.pump();
    return key.currentState!;
  }

  Offset origin(WidgetTester t) =>
      t.getTopLeft(find.byType(CraftEditorViewport));

  /// The ascent stage on the pad, held RCS quad, and a camera looking straight
  /// down the `quad-1` / `quad-3` axis unless told otherwise.
  ///
  /// That axial pose is deliberately the WORST case for projection picking:
  /// the two nodes land on the same pixel, which is exactly the ambiguity the
  /// ring ranking, the facing demotion and the cycle exist to survive.
  Future<CraftEditorViewportState> pumpWithPod(
    WidgetTester t, {
    double azimuth = -3 * 3.141592653589793 / 4,
    double elevation = 0,
    double distanceM = 8,
    bool holdQuad = true,
  }) async {
    final state = await pumpViewport(t);
    controller.placeRoot(def: controller.catalog.byId('eagle-command-pod')!);
    await t.pump();
    if (holdQuad) {
      controller.hold(controller.catalog.byId('eagle-rcs-block')!);
      await t.pump();
    }
    state.setPose(
      azimuth: azimuth,
      elevation: elevation,
      distanceM: distanceM,
      pivot: Vector3.zero,
    );
    await t.pump();
    return state;
  }

  /// Where an open attach node lands on screen, in GLOBAL coordinates.
  Offset pixelOf(WidgetTester t, CraftEditorViewportState state, String node) {
    final target =
        controller.openTargets.firstWhere((x) => x.nodeName == node);
    final local = state.camera.project(target.positionInCraft);
    expect(local, isNotNull, reason: '$node must be in front of the near plane');
    return origin(t) + local!;
  }

  /// The overlay painter currently mounted, out of the several `CustomPaint`s
  /// any `MaterialApp` carries.
  CraftEditorPainter painterOf(WidgetTester t) => t
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((w) => w.painter)
      .whereType<CraftEditorPainter>()
      .single;

  /// Park the mouse on a pixel without pressing anything, which is how every
  /// hover assertion in this file gets a live pick.
  Future<void> hoverAt(WidgetTester t, int pointerId, Offset at) async {
    await t.sendEventToBinding(
        TestPointer(pointerId, PointerDeviceKind.mouse).hover(at));
    await t.pump();
  }

  group('mouse buttons', () {
    testWidgets('a bare middle press and release moves nothing', (t) async {
      final state = await pumpWithPod(t, holdQuad: false);
      final before = state.camera;
      final g = await t.createGesture(
          kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
      await g.down(origin(t) + const Offset(600, 400));
      await t.pump();
      await g.up();
      await t.pump();
      expect(state.camera.azimuth, before.azimuth);
      expect(state.camera.elevation, before.elevation);
      expect(state.camera.distanceM, before.distanceM);
      expect(state.camera.pivot, before.pivot);
    });

    testWidgets('a bare right press and release moves nothing', (t) async {
      final state = await pumpWithPod(t, holdQuad: false);
      final before = state.camera;
      final g = await t.createGesture(
          kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await g.down(origin(t) + const Offset(600, 400));
      await t.pump();
      await g.up();
      await t.pump();
      expect(state.camera.azimuth, before.azimuth);
      expect(state.camera.elevation, before.elevation);
      expect(state.camera.distanceM, before.distanceM);
      expect(state.camera.pivot, before.pivot);
    });

    testWidgets('a 10 px middle drag orbits exactly once', (t) async {
      final state = await pumpWithPod(t, holdQuad: false);
      final before = state.camera.azimuth;
      final g = await t.createGesture(
          kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
      await g.down(origin(t) + const Offset(600, 400));
      await t.pump();
      await g.moveBy(const Offset(10, 0));
      await t.pump();
      await g.up();
      await t.pump();
      // Double-firing (Listener AND a scale recogniser that accepted the middle
      // button) would land on 0.10 rad, which is the bug this pins.
      expect(state.camera.azimuth - before,
          closeTo(10 * CraftEditorViewportState.orbitRadPerPx, 1e-12));
    });

    testWidgets('a 10 px right drag pans and never orbits', (t) async {
      final state = await pumpWithPod(t, holdQuad: false);
      final before = state.camera;
      final expected = before.panned(const Offset(10, 0)).pivot;

      final g = await t.createGesture(
          kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await g.down(origin(t) + const Offset(600, 400));
      await t.pump();
      await g.moveBy(const Offset(10, 0));
      await t.pump();
      await g.up();
      await t.pump();

      expect(state.camera.azimuth, before.azimuth);
      expect(state.camera.elevation, before.elevation);
      expect(state.camera.pivot.x, closeTo(expected.x, 1e-12));
      expect(state.camera.pivot.y, closeTo(expected.y, 1e-12));
      expect(state.camera.pivot.z, closeTo(expected.z, 1e-12));
    });

    testWidgets('a 10 px left drag orbits through the scale recogniser',
        (t) async {
      final state = await pumpWithPod(t, holdQuad: false);
      final before = state.camera.azimuth;
      final g = await t.createGesture(
          kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
      await g.down(origin(t) + const Offset(600, 400));
      await t.pump();
      await g.moveBy(const Offset(10, 0));
      await t.pump();
      await g.up();
      await t.pump();
      expect(state.camera.azimuth - before,
          closeTo(10 * CraftEditorViewportState.orbitRadPerPx, 1e-9));
    });

    testWidgets('the wheel zooms', (t) async {
      final state = await pumpWithPod(t, holdQuad: false);
      final before = state.camera.distanceM;
      final pointer = TestPointer(9, PointerDeviceKind.mouse);
      await t.sendEventToBinding(
          pointer.hover(origin(t) + const Offset(600, 400)));
      await t.pump();
      await t.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
      await t.pump();
      expect(
        state.camera.distanceM,
        closeTo(
            before * (1 + 120 * CraftEditorViewportState.zoomPerScrollUnit),
            1e-9),
      );
    });
  });

  group('a drag is never a placement', () {
    testWidgets('a middle drag across a live target places nothing', (t) async {
      final state = await pumpWithPod(t);
      final at = pixelOf(t, state, 'quad-1');
      expect(controller.design.partCount, 1);

      final g = await t.createGesture(
          kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
      await g.down(at);
      await t.pump();
      await g.moveBy(const Offset(12, 6));
      await t.pump();
      await g.up();
      await t.pump();

      expect(controller.design.partCount, 1);
      expect(controller.held, isNotNull, reason: 'the part stays on the cursor');
    });

    testWidgets('a right click drops the held part instead of placing it',
        (t) async {
      final state = await pumpWithPod(t);
      final at = pixelOf(t, state, 'quad-1');
      final g = await t.createGesture(
          kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await g.down(at);
      await t.pump();
      await g.up();
      await t.pump();
      expect(controller.held, isNull);
      expect(controller.design.partCount, 1);
    });

    testWidgets('the lingering finger of a pinch does not place', (t) async {
      final state = await pumpWithPod(t);
      final at = pixelOf(t, state, 'quad-1');

      // Control: one finger, one tap, one part — so the negative case below is
      // about the pinch taint and not about the tap never arriving.
      await t.tapAt(at);
      await t.pump();
      expect(controller.design.partCount, 2);

      final first = await t.createGesture(pointer: 11);
      await first.down(at);
      await t.pump();
      final second = await t.createGesture(pointer: 12);
      await second.down(at + const Offset(80, 0));
      await t.pump();
      // The second finger lifts first — they never release together — and the
      // release of the first is an ordinary tap as far as the arena knows.
      await second.up();
      await t.pump();
      await first.up();
      await t.pump();

      expect(controller.design.partCount, 2,
          reason: 'the pinch taint must survive the last finger coming up');

      // And it must not stick: the taint is per gesture, cleared by the first
      // pointer of the next one, or the view would be dead to touch after any
      // zoom.
      await t.tapAt(at + const Offset(0, 1));
      await t.pump();
      expect(controller.design.partCount, 3);
    });
  });

  group('a tap at a known pixel', () {
    testWidgets('mounts the quad on the node the camera says is there',
        (t) async {
      // Off the axial pose, so exactly one candidate is under the cursor.
      final state = await pumpWithPod(t, elevation: 0.35, distanceM: 9);
      final at = pixelOf(t, state, 'quad-1');
      await t.tapAt(at);
      await t.pump();

      expect(controller.design.partCount, 2);
      final placed = controller.design.parts.last;
      expect(placed.def.id, 'eagle-rcs-block');
      expect(placed.attachment!.parentNode, 'quad-1');
      expect(placed.attachment!.childNode, 'mount');
    });

    testWidgets('names the node BEFORE the click, and commits that node',
        (t) async {
      // R1 layer (c), the visible commitment: hover and tap run the same pure
      // pick, so what the overlay named is what the click used. A wrong pick is
      // then a three-pixel correction rather than a discovery.
      final state = await pumpWithPod(t, elevation: 0.35, distanceM: 9);
      final at = pixelOf(t, state, 'quad-1');
      final pointer = TestPointer(21, PointerDeviceKind.mouse);
      await t.sendEventToBinding(pointer.hover(at));
      await t.pump();

      expect(state.hoveredTarget?.nodeName, 'quad-1');
      final promised = state.hoveredTarget!.nodeName;

      await t.tapAt(at);
      await t.pump();
      expect(controller.design.parts.last.attachment!.parentNode, promised);
    });

    testWidgets('selects the part under the cursor when nothing is held',
        (t) async {
      final state =
          await pumpWithPod(t, elevation: 0.4, distanceM: 20, holdQuad: false);
      final centre = state.camera.project(Vector3.zero)!;
      await t.tapAt(origin(t) + centre);
      await t.pump();
      expect(controller.selectedId, 'eagle-command-pod-0');
    });

    testWidgets('clears the selection on empty space', (t) async {
      final state =
          await pumpWithPod(t, elevation: 0.4, distanceM: 60, holdQuad: false);
      controller.select('eagle-command-pod-0');
      await t.pump();
      await t.tapAt(origin(t) + const Offset(20, 20));
      await t.pump();
      expect(controller.selectedId, isNull);
      expect(state.hoveredPartId, isNull);
    });
  });

  group('the axial view is survivable (R1)', () {
    testWidgets('reports itself edge-on and still picks the near node',
        (t) async {
      // Looking exactly down the quad-1/quad-3 axis: both project onto the same
      // pixel and no pixel-distance ranking can separate them.
      final state = await pumpWithPod(t);
      final at = pixelOf(t, state, 'quad-1');
      final pointer = TestPointer(31, PointerDeviceKind.mouse);
      await t.sendEventToBinding(pointer.hover(at));
      await t.pump();

      expect(state.alternatives, 2);
      expect(state.edgeOn, isTrue,
          reason: 'the HUD has to say why picking is ambiguous here');
      expect(state.hoveredTarget?.nodeName, 'quad-1',
          reason: 'the near, front-facing node wins the tie');
    });

    testWidgets('Tab reaches the far node without orbiting', (t) async {
      final state = await pumpWithPod(t);
      final at = pixelOf(t, state, 'quad-1');
      final pointer = TestPointer(32, PointerDeviceKind.mouse);
      await t.sendEventToBinding(pointer.hover(at));
      await t.pump();
      expect(state.hoveredTarget?.nodeName, 'quad-1');

      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(state.pickCycle, 1);
      expect(state.hoveredTarget?.nodeName, 'quad-3');

      await t.tapAt(at);
      await t.pump();
      expect(controller.design.parts.last.attachment!.parentNode, 'quad-3');
    });
  });

  group('the overlay is the editor, not decoration', () {
    testWidgets('every layer paints with no renderer behind it', (t) async {
      // Headless there is no Impeller context, so `fs.SceneView` never appears
      // and the overlay is the entire picture. That is the spec's claim that
      // the editor keeps working with no bakes: picking is oriented-box
      // arithmetic off `PartDef.size` and the overlay is pure Canvas. This
      // drives the branches the other cases do not reach — stage badges, the
      // loose-part outline, the balance markers and a selected symmetry group.
      final state = await pumpWithPod(t, elevation: 0.35, distanceM: 9);
      await t.sendKeyEvent(LogicalKeyboardKey.digit4);
      await t.pump();
      await t.tapAt(pixelOf(t, state, 'quad-1'));
      await t.pump();

      controller.hold(controller.catalog.byId('eagle-thruster')!);
      await t.pump();
      controller.clearHeld();
      // A detached quad is a loose part: it still has mass and is bolted to
      // nothing, which is what the dashed danger outline is for.
      controller.detach(controller.design.parts.last.instanceId);
      controller.select(controller.design.parts.first.instanceId);
      controller.setTool(EditorTool.stage);
      await t.pump();

      expect(state.sceneReady, isFalse,
          reason: 'the shader bundle needs a GPU context, so no SceneView is '
              'ever built here — if this ever flips, the suite is quietly '
              'exercising a renderer and the timings above stop meaning what '
              'they say');
      expect(controller.hasLooseParts, isTrue);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(t.takeException(), isNull);
    });

    test('a hand-built overlay paints with no widget anywhere', () {
      // The overlay's whole input is one immutable value, so it can be painted
      // straight to a recorder. That is what lets the screenshot suite render
      // the editor's HUD with no Impeller context in the process, and it pins
      // that no layer here quietly needs a `BuildContext`.
      final catalog = PartCatalog.standard();
      final design = CraftDesign(name: 'probe');
      design.addPart(
          def: catalog.byId('eagle-command-pod')!, instanceId: 'pod');
      final camera = CraftEditorCamera(
        azimuth: 0.7,
        elevation: 0.3,
        distanceM: 12,
        pivot: Vector3.zero,
        viewport: const Size(1200, 800),
      );
      final targets = AttachTargets.openNodes(design);
      final thrust = CraftBalance.thrust(design);
      final overlay = CraftEditorOverlay(
        camera: camera,
        design: design,
        targets: targets,
        compatible: {
          for (final t in targets) (t.ownerInstanceId, t.nodeName),
        },
        hovered: targets.first,
        seats: targets.take(2).toList(),
        cursor: const Offset(600, 400),
        selection: const {'pod'},
        selectionLabel: 'Eagle Ascent Stage - S0',
        looseIds: const {'pod'},
        centreOfMass: CraftBalance.centreOfMass(design),
        thrustOrigin: thrust?.origin,
        thrustAxis: thrust?.direction,
        thrustOffAxisDeg: 12.0,
        showStages: true,
        rootGhost: true,
        alternatives: 3,
        cycle: 1,
        edgeOn: true,
        hud: const ['Placing: Eagle RCS Quad - Esc to stop'],
        blocked: 'that node is taken',
      );

      expect(() {
        final recorder = ui.PictureRecorder();
        CraftEditorPainter(overlay)
            .paint(ui.Canvas(recorder), const Size(1200, 800));
        recorder.endRecording().dispose();
      }, returnsNormally);
    });
  });

  group('keys', () {
    testWidgets('Esc drops the held part, then the selection', (t) async {
      await pumpWithPod(t);
      controller.select('eagle-command-pod-0');
      await t.pump();

      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(controller.held, isNull);
      expect(controller.selectedId, 'eagle-command-pod-0');

      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(controller.selectedId, isNull);
    });

    testWidgets('the symmetry chips are on the number row', (t) async {
      await pumpWithPod(t);
      await t.sendKeyEvent(LogicalKeyboardKey.digit4);
      await t.pump();
      expect(controller.symmetry.count, 4);
      await t.sendKeyEvent(LogicalKeyboardKey.digit1);
      await t.pump();
      expect(controller.symmetry.isSingle, isTrue);
    });

    testWidgets('x4 places four quads on four real nodes in one step',
        (t) async {
      final state = await pumpWithPod(t, elevation: 0.35, distanceM: 9);
      await t.sendKeyEvent(LogicalKeyboardKey.digit4);
      await t.pump();
      final at = pixelOf(t, state, 'quad-1');
      await t.tapAt(at);
      await t.pump();

      expect(controller.design.partCount, 5);
      final seats = {
        for (final p in controller.design.parts)
          if (p.def.id == 'eagle-rcs-block') p.attachment!.parentNode,
      };
      expect(seats, {'quad-1', 'quad-2', 'quad-3', 'quad-4'});
      expect(controller.undoCount, 2, reason: 'root, then one mount step');
    });

    testWidgets('G and C toggle the overlay layers', (t) async {
      await pumpWithPod(t);
      expect(controller.showNodes, isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.keyG);
      await t.pump();
      expect(controller.showNodes, isFalse);
      await t.sendKeyEvent(LogicalKeyboardKey.keyC);
      await t.pump();
      expect(controller.showBalance, isFalse);
    });

    testWidgets('the bracket keys zoom', (t) async {
      final state = await pumpWithPod(t, holdQuad: false);
      final before = state.camera.distanceM;
      await t.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await t.pump();
      expect(state.camera.distanceM,
          closeTo(before * CraftEditorViewportState.keyZoomStep, 1e-9));
      await t.sendKeyEvent(LogicalKeyboardKey.bracketRight);
      await t.pump();
      expect(state.camera.distanceM, closeTo(before, 1e-9));
    });

    testWidgets('an unclaimed chord is passed through to the platform',
        (t) async {
      await pumpWithPod(t);
      // No onSave handler is wired, so Ctrl+S must not be swallowed: a viewport
      // that ate the chord without acting on it would delete the shortcut.
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final handled = await t.sendKeyEvent(LogicalKeyboardKey.keyS);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(handled, isFalse);
    });
  });

  group('a catalog row dragged into the view', () {
    /// The catalog BESIDE the viewport, which is the only arrangement the drag
    /// gesture exists in. The size matters to the case: a catalog row is the
    /// full width of its pane, and the node it is dropped onto is a 6 px marker
    /// in the other pane.
    Future<CraftEditorViewportState> pumpCatalogAndViewport(
      WidgetTester t, {
      double catalogWidth = 300,
    }) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(children: [
            SizedBox(
              width: catalogWidth,
              child: CraftCatalogPane(
                controller: controller,
                initialCategory: PartCategory.rcsThruster,
              ),
            ),
            Expanded(
              child: CraftEditorViewport(
                  key: key, controller: controller, prewarmModels: false),
            ),
          ]),
        ),
      ));
      await t.pump();
      final state = key.currentState!;
      controller.placeRoot(def: controller.catalog.byId('eagle-command-pod')!);
      await t.pump();
      state.setPose(
        azimuth: -3 * _pi / 4,
        elevation: 0.35,
        distanceM: 9,
        pivot: Vector3.zero,
      );
      await t.pump();
      return state;
    }

    testWidgets('mounts on the node under the POINTER, not under the row corner',
        (t) async {
      // `DragTargetDetails.offset` is `globalPosition - dragStartPoint`, and
      // the child anchor makes `dragStartPoint` wherever inside the row the
      // player grabbed it. Grabbing a 284 px row near its right end and
      // dropping on a marker therefore picks most of a pane away from the
      // cursor, misses everything, and does nothing at all — the silent
      // failure this drives.
      final state = await pumpCatalogAndViewport(t);
      final row = find.ancestor(
          of: find.text(_quad), matching: find.byType(Draggable<PartDef>));
      expect(row, findsOneWidget);
      final rowRect = t.getRect(row);
      final grab = rowRect.topLeft + const Offset(180, 24);
      expect(rowRect.contains(grab), isTrue,
          reason: 'the grab point has to be a real point on the row');

      final drop = pixelOf(t, state, 'quad-1');
      expect((drop - grab).distance, greaterThan(CraftEditorPick.grabPxMouse),
          reason: 'premise: the row corner and the marker are nowhere near '
              'each other, so picking at the wrong one of them cannot pass '
              'by luck');

      final g = await t.startGesture(grab, kind: PointerDeviceKind.mouse);
      await t.pump();
      // Past the horizontal slop first: the row's Draggable has a horizontal
      // affinity so that a vertical drag still scrolls the roster.
      await g.moveBy(const Offset(40, 0));
      await t.pump();
      await g.moveTo(drop);
      await t.pump();
      await g.up();
      await t.pump();

      expect(controller.design.partCount, 2,
          reason: 'the drop must place exactly as a tap on that pixel does');
      expect(controller.design.parts.last.attachment!.parentNode, 'quad-1');
    });
  });

  group('Tab belongs to focus traversal unless there is something to cycle', () {
    /// The viewport with ONE focusable neighbour under it — the toolbar, the
    /// catalog rows and the NODES list are all this, as far as traversal is
    /// concerned.
    Future<(CraftEditorViewportState, FocusNode)> pumpWithNeighbour(
      WidgetTester t, {
      bool holdQuad = true,
      double elevation = 0,
      double distanceM = 8,
    }) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      final next = FocusNode(debugLabel: 'toolbar');
      addTearDown(next.dispose);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            Expanded(
              child: CraftEditorViewport(
                  key: key, controller: controller, prewarmModels: false),
            ),
            TextButton(
                focusNode: next, onPressed: () {}, child: const Text('LAUNCH')),
          ]),
        ),
      ));
      await t.pump();
      final state = key.currentState!;
      controller.placeRoot(def: controller.catalog.byId('eagle-command-pod')!);
      await t.pump();
      if (holdQuad) {
        controller.hold(controller.catalog.byId('eagle-rcs-block')!);
        await t.pump();
      }
      state.setPose(
        azimuth: -3 * _pi / 4,
        elevation: elevation,
        distanceM: distanceM,
        pivot: Vector3.zero,
      );
      await t.pump();
      return (state, next);
    }

    testWidgets('with nothing to cycle, Tab reaches the next control',
        (t) async {
      final (state, next) = await pumpWithNeighbour(t, holdQuad: false);
      expect(state.alternatives, 0, reason: 'premise: nothing is under the '
          'cursor, so the cycle has nothing to offer');
      expect(next.hasFocus, isFalse);

      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();

      expect(next.hasFocus, isTrue,
          reason: 'the viewport autofocuses and sits under the app shortcuts, '
              'so swallowing Tab traps the keyboard here and puts every other '
              'control out of reach');
    });

    testWidgets('with candidates under the cursor, Tab cycles and keeps focus',
        (t) async {
      final (state, next) = await pumpWithNeighbour(t);
      await hoverAt(t, 41, pixelOf(t, state, 'quad-1'));
      expect(state.alternatives, 2, reason: 'premise: the axial view stacks '
          'quad-1 and quad-3 on one pixel');

      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();

      expect(state.pickCycle, 1);
      expect(state.hoveredTarget?.nodeName, 'quad-3');
      expect(next.hasFocus, isFalse,
          reason: 'the cycle owns Tab while there is a stack to walk');
    });
  });

  group('the candidate count is what the player can see', () {
    /// A tank on the pad and an identical one held. Both carry a four-member
    /// surface ring, so every chevron on the parent pairs against all four of
    /// the held tank's own ring nodes: four legal mates behind ONE marker.
    Future<CraftEditorViewportState> pumpTankOnTank(
      WidgetTester t, {
      required double azimuth,
      double elevation = 0,
      double distanceM = 6,
    }) async {
      final state = await pumpViewport(t);
      controller.placeRoot(def: controller.catalog.byId('fl-t400')!);
      await t.pump();
      controller.hold(controller.catalog.byId('fl-t400')!);
      await t.pump();
      state.setPose(
        azimuth: azimuth,
        elevation: elevation,
        distanceM: distanceM,
        pivot: Vector3.zero,
      );
      await t.pump();
      expect(
          controller.pairings
              .where((p) => p.target.nodeName == 'srf-1')
              .length,
          4,
          reason: 'premise: one chevron, four legal pairings');
      return state;
    }

    testWidgets('one chevron under the cursor is one candidate', (t) async {
      final state = await pumpTankOnTank(t, azimuth: -_pi / 2 + 0.6,
          elevation: 0.35);
      await hoverAt(t, 51, pixelOf(t, state, 'srf-1'));

      expect(state.hoveredTarget?.nodeName, 'srf-1');
      expect(state.alternatives, 1,
          reason: 'the HUD counts markers: promising four candidates where the '
              'player sees one node makes the hint noise');
    });

    testWidgets('every Tab press moves the snap ring to a different node',
        (t) async {
      // Down the srf-1/srf-3 axis, which is where cycling is the only way to
      // reach the far node. Whatever the count is, walking it must visit that
      // many DIFFERENT markers: a press that changes only which of the held
      // part's nodes seats moves nothing on screen, and W/S is already that
      // control.
      final state = await pumpTankOnTank(t, azimuth: -_pi / 2);
      await hoverAt(t, 52, pixelOf(t, state, 'srf-1'));
      expect(state.alternatives, greaterThan(1),
          reason: 'premise: the axial view really does stack two chevrons');

      final visited = <String>{};
      for (var i = 0; i < state.alternatives; i++) {
        visited.add(state.hoveredTarget!.nodeName);
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
      }

      expect(visited, hasLength(state.alternatives));
      expect(visited, {'srf-1', 'srf-3'});
      expect(state.pickCycle, 0, reason: 'the cycle wraps in as many presses '
          'as the HUD said there were candidates');
    });
  });

  group('what is painted is what can be clicked', () {
    /// Azimuth 0 / elevation 0 makes the basis exactly `forward +Y, right +X,
    /// up +Z`, so a marker can be placed at a chosen PIXEL offset and a chosen
    /// view depth in closed form. 1280x720 is the geometry the radius numbers
    /// in these cases were measured at.
    CraftEditorCamera unitCam({required double distanceM}) => CraftEditorCamera(
          azimuth: 0,
          elevation: 0,
          distanceM: distanceM,
          pivot: Vector3.zero,
          viewport: const Size(1280, 720),
        );

    TargetMarker markerAt(
      CraftEditorCamera cam, {
      required double depthM,
      required double dxPx,
      required double size,
    }) =>
        (
          position:
              Vector3(dxPx * depthM / cam.focalPx, depthM - cam.distanceM, 0),
          direction: const Vector3(0, -1, 0),
          size: size,
        );

    PickedTarget<TargetMarker>? pickOne(
            CraftEditorCamera cam, TargetMarker m) =>
        CraftEditorPick.pickTarget<TargetMarker>(
            cam, [m], const Offset(640, 360),
            markerOf: (x) => x, touch: false);

    test('a marker at 150 m accepts a click inside the circle it draws', () {
      // Past about 55 m of eye distance the world cap on the accept radius
      // falls under the floor the marker is PAINTED at, so a 0.25 m node keeps
      // its full size and its compatible colouring while refusing clicks well
      // inside its own outline. Nothing in the HUD says so, which is what makes
      // it read as a dead editor rather than as a zoom problem.
      final cam = unitCam(distanceM: 150);
      final drawn = CraftEditorPick.markerRadiusPx(cam, 0.25, 150);
      expect(drawn, CraftEditorPick.minMarkerPx);
      expect(1.5 * 0.25 * cam.pxPerMetreAt(150), lessThan(drawn),
          reason: 'premise: out here the world cap is the tighter of the two '
              'rules');

      expect(pickOne(cam, markerAt(cam, depthM: 150, dxPx: 4, size: 0.25)),
          isNotNull);
    });

    test('the drawn radius and the accept radius are one number at every zoom',
        () {
      // The invariant, swept rather than sampled: whatever a marker paints, a
      // click anywhere inside it lands. It holds because the accept radius is
      // floored by the drawn radius and capped by the grab radius, and the
      // drawn radius can never exceed the grab radius.
      expect(CraftEditorPick.maxMarkerPx,
          lessThanOrEqualTo(CraftEditorPick.grabPxMouse),
          reason: 'a marker painted wider than the mouse can reach would be a '
              'target that refuses clicks inside its own outline');
      for (final depthM in [3.0, 12.0, 55.0, 150.0, 400.0]) {
        for (final size in [0.25, 1.25, 4.2]) {
          final cam = unitCam(distanceM: depthM);
          final drawn = CraftEditorPick.markerRadiusPx(cam, size, depthM);
          expect(
              pickOne(cam,
                  markerAt(cam, depthM: depthM, dxPx: drawn - 0.01, size: size)),
              isNotNull,
              reason: 'a ${size}m node at ${depthM}m draws at $drawn px and '
                  'must accept a click there');
        }
      }
    });
  });

  group('the overlay snapshot', () {
    testWidgets('is rebuilt on every build, which is what shouldRepaint tests',
        (t) async {
      // The painter diffs its snapshot by IDENTITY, and the viewport builds a
      // fresh one every time it builds — including for a rebuild that changed
      // nothing. Anything claiming otherwise is describing a gate that is not
      // there.
      final state = await pumpWithPod(t, elevation: 0.35, distanceM: 9);
      final before = painterOf(t);
      state.setPose(azimuth: state.camera.azimuth);
      await t.pump();
      final after = painterOf(t);

      expect(identical(before.data, after.data), isFalse);
      expect(after.shouldRepaint(before), isTrue);
    });
  });
}
