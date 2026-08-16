// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Spec risk R2: the craft editor is one sign away from placing every part on the
// wrong side of the craft, and it would look almost right.
//
//   flutter test test/screenshots/craft_editor_chirality_test.dart
//
// Writes test_out/craft_editor_chirality_*.png.
//
// ## Why this file exists at all when the camera already has a unit test
//
// flutter_scene's `_matrix4LookAt` and the domain `PerspectiveCamera` derive
// their bases from opposite cross products, so the raw render is a mirror image
// and the viewport's `Transform.flip(flipX: true)` cancels it exactly. That
// makes the flipped image literally `PerspectiveCamera.projectPx`, which is why
// `CraftEditorCamera.project` carries no mirror term. The unit test in
// `test/presenters/craft_editor_camera_test.dart` pins the ARITHMETIC.
//
// It cannot pin the WIDGET TREE. If the overlay painter is nested under the flip
// instead of beside it, or a gesture recogniser ends up inside it — the obvious
// result of someone tidying the nesting — the maths stays correct and the editor
// silently mirrors. And a mirror is nearly invisible on a rocket: a bare stack
// is symmetric about its axis, and so is a four-way RCS ring, so the bug only
// surfaces the day somebody places ONE asymmetric part, by which time a lot has
// been built on the assumption.
//
// So every case below is built around an ASYMMETRIC arrangement, and each one
// asserts something a machine can measure rather than something a human would
// have to eyeball:
//
//   * a single RCS quad on `quad-1` and nothing on the other three seats;
//   * a pose (azimuth 0) in which the domain camera's screen-right axis IS the
//     craft's +X, so `quad-1` is unambiguously on the right of frame;
//   * `quad-2` sitting at the exact mirror image of `quad-1`'s pixel, which
//     turns "the picture is flipped" into "the editor mated to the wrong node"
//     — a difference no antialiasing change can blur.
//
// Each case is paired with a NEGATIVE CONTROL that wraps the same tree in a real
// `Transform.flip` and asserts the measurement moves to the mirrored position.
// Without those, a green run would only prove the assertions are satisfiable.
//
// ## The honest residual
//
// Headless there is no GPU context, so `fs.Scene.initializeStaticResources()`
// never completes and the `SceneView` — and with it the production
// `Transform.flip`, which is written `if (_scene != null)` — is absent from the
// tree. These tests therefore measure the OVERLAY and the GESTURE path against
// the camera, not the rendered 3D image against the overlay. They catch a flip
// wrapped around the gesture stack or around the whole `Stack` (both
// unconditional in any plausible rewrite) and they catch an overlay moved inside
// the scene-only branch (it would vanish here). What they cannot catch is a
// mirror that exists only when a scene is live. That one needs
// `lib/main_craft_dev.dart` on a real device, which is what it is for.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/app_theme.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_painter.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Odd multiples of nothing: a width whose half is a round number keeps every
/// "left of centre / right of centre" claim in this file arithmetic rather than
/// approximate.
const Size _size = Size(1000, 800);

/// Azimuth 0 makes `PerspectiveCamera.right` exactly the craft's +X
/// (`right = (cos a, -sin a, 0)`), so "screen right" and "craft +X" are the same
/// claim and the test needs no basis algebra of its own.
const double _azimuth = 0.0;
const double _elevation = 0.28;
const double _distanceM = 9.0;

void main() {
  late CraftEditorController controller;
  late GlobalKey<CraftEditorViewportState> viewportKey;
  late GlobalKey shotKey;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    viewportKey = GlobalKey<CraftEditorViewportState>();
    shotKey = GlobalKey();
  });

  tearDown(() => controller.dispose());

  /// An ascent stage on the pad, with [withQuad] deciding whether a single RCS
  /// quad is already bolted to `quad-1`.
  ///
  /// One quad, not four. Four would restore the axial symmetry this whole file
  /// depends on being broken.
  CraftEditorController editor({required bool withQuad}) {
    final catalog = PartCatalog.standard();
    final design = CraftDesign(name: 'Chirality');
    design.addPart(
        def: catalog.byId('eagle-command-pod')!,
        instanceId: 'ascent',
        position: Vector3.zero);
    if (withQuad) {
      design.attachPart(
        def: catalog.byId('eagle-rcs-block')!,
        instanceId: 'quad',
        toInstanceId: 'ascent',
        parentNode: 'quad-1',
        childNode: 'mount',
      );
    }
    return CraftEditorController(catalog: catalog, design: design);
  }

  /// Pump the real viewport, optionally through a deliberate horizontal flip.
  ///
  /// [mirrored] is the negative control: it reproduces, from outside, exactly
  /// what a `Transform.flip` wrapped around the gesture stack would do from
  /// inside. Everything the upright case asserts, the mirrored case asserts the
  /// opposite of, so neither can pass by accident.
  Future<CraftEditorViewportState> pump(WidgetTester t,
      {bool mirrored = false}) async {
    t.view.physicalSize = _size;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final viewport = CraftEditorViewport(
      key: viewportKey,
      controller: controller,
      // No asset bundle worth warming headlessly, and a parse isolate would
      // only be something this test then had to wait on.
      prewarmModels: false,
    );
    await t.pumpWidget(MaterialApp(
      home: RepaintBoundary(
        key: shotKey,
        child: mirrored
            ? Transform.flip(flipX: true, child: viewport)
            : viewport,
      ),
    ));
    await t.pump();

    final state = viewportKey.currentState!;
    // Fixed pose, so every pixel below is reproducible. setPose also latches
    // `_framed`, which stops the first controller notification from re-framing
    // the camera out from under the measurement.
    state.setPose(
      azimuth: _azimuth,
      elevation: _elevation,
      distanceM: _distanceM,
      pivot: Vector3.zero,
    );
    await t.pump();
    expect(state.camera.viewport, _size,
        reason: 'the viewport did not lay out at the size this file projects '
            'pixels against');
    return state;
  }

  Future<_Shot> capture(WidgetTester t, String name) async {
    late _Shot shot;
    await t.runAsync(() async {
      final boundary =
          shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.0);
      final width = image.width, height = image.height;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      final bytes = png!.buffer.asUint8List();
      final file = File('test_out/craft_editor_chirality_$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      shot = _Shot(width, height, raw!.buffer.asUint8List());
    });
    return shot;
  }

  /// Strip the overlay down to the one asymmetric thing on the craft.
  ///
  /// With the node markers and the balance readout off, and nothing held, the
  /// ONLY ink the painter produces is the selected quad's outline and its label
  /// — so "all the ink is on the right" is a statement about that part and not
  /// about a HUD line that happens to start at the top left corner.
  void isolateTheQuad() {
    controller
      ..setShowNodes(false)
      ..setShowBalance(false)
      ..select('quad');
  }

  group('the rendered overlay', () {
    testWidgets('an asymmetric part at craft +X paints in the RIGHT half',
        (t) async {
      controller = editor(withQuad: true);
      isolateTheQuad();
      final state = await pump(t);

      final quad = controller.design.partById('quad')!;
      final expected = state.camera.project(quad.position)!;
      // The setup's own precondition: if this fails the pose is wrong and the
      // rest of the test would be measuring nothing.
      expect(expected.dx, greaterThan(_size.width / 2 + 80),
          reason: 'quad-1 must project decisively right of centre for this '
              'test to mean anything');

      final shot = await capture(t, 'upright');
      final bounds = shot.inkBounds;
      expect(shot.inkCount, greaterThan(200),
          reason: 'nothing was painted, so nothing was measured');
      expect(bounds, isNotNull);
      expect(bounds!.left, greaterThan(_size.width / 2),
          reason: 'ink appeared left of centre for a part at craft +X: the '
              'overlay is mirrored. Ink spans $bounds.');
      expect(bounds.contains(expected), isTrue,
          reason: 'the ink does not cover the pixel project() names for the '
              'part: $expected is outside $bounds');
    });

    testWidgets('a mirrored tree moves that ink to the LEFT half', (t) async {
      // The control. It is what makes the assertion above evidence rather than
      // a coincidence: the same craft, the same camera, one flip, and every
      // claim reverses.
      controller = editor(withQuad: true);
      isolateTheQuad();
      final state = await pump(t, mirrored: true);

      final quad = controller.design.partById('quad')!;
      final upright = state.camera.project(quad.position)!;
      final flipped = Offset(_size.width - upright.dx, upright.dy);

      final shot = await capture(t, 'mirrored');
      final bounds = shot.inkBounds;
      expect(shot.inkCount, greaterThan(200));
      expect(bounds, isNotNull);
      expect(bounds!.right, lessThan(_size.width / 2),
          reason: 'a horizontal flip did not move the ink, so the upright case '
              'proves nothing');
      expect(bounds.contains(flipped), isTrue,
          reason: 'the flipped ink is not at the mirrored pixel $flipped: '
              '$bounds');
    });
  });

  group('the gesture path', () {
    /// Hold an RCS quad and tap one absolute screen pixel.
    ///
    /// Absolute rather than relative to the viewport's box: `Transform` does not
    /// move a child's layout box but does transform its coordinate mapping, so
    /// asking the mirrored tree where its top-left corner is would return the
    /// far side of the screen and quietly undo the control.
    Future<String?> tapAndReadMate(WidgetTester t, Offset at) async {
      await t.tapAt(at);
      await t.pump();
      final placed = [
        for (final p in controller.design.parts)
          if (p.def.id == 'eagle-rcs-block') p
      ];
      if (placed.isEmpty) return null;
      expect(placed, hasLength(1));
      return placed.single.attachment?.parentNode;
    }

    testWidgets('a tap on quad-1 pixel mates to quad-1, not its mirror image',
        (t) async {
      controller = editor(withQuad: false);
      controller.hold(controller.catalog.byId('eagle-rcs-block')!);
      final state = await pump(t);

      final seat = controller.openTargets
          .firstWhere((x) => x.nodeName == 'quad-1')
          .positionInCraft;
      final mirrorSeat = controller.openTargets
          .firstWhere((x) => x.nodeName == 'quad-2')
          .positionInCraft;
      final at = state.camera.project(seat)!;
      final mirrored = state.camera.project(mirrorSeat)!;

      // THE SETUP THAT GIVES THIS TEST ITS EDGE. quad-1 and quad-2 sit either
      // side of the craft's YZ plane at the same height and depth, so at
      // azimuth 0 they project to exact mirror images about the frame centre.
      // A flipped gesture coordinate therefore does not miss — it lands
      // confidently on the wrong seat, which is precisely the failure that
      // looks right until someone measures the craft.
      expect(mirrored.dx, closeTo(_size.width - at.dx, 0.001));
      expect(mirrored.dy, closeTo(at.dy, 0.001));
      expect(t.getTopLeft(find.byType(CraftEditorViewport)), Offset.zero);

      expect(await tapAndReadMate(t, at), 'quad-1');
    });

    testWidgets('through a mirrored tree the same tap mates to quad-2',
        (t) async {
      controller = editor(withQuad: false);
      controller.hold(controller.catalog.byId('eagle-rcs-block')!);
      final state = await pump(t, mirrored: true);

      final seat = controller.openTargets
          .firstWhere((x) => x.nodeName == 'quad-1')
          .positionInCraft;
      final at = state.camera.project(seat)!;

      // Not "nothing was placed" — the wrong seat, on the other side of the
      // craft, with no complaint. That is what a gesture recogniser nested
      // inside `Transform.flip` would ship.
      expect(await tapAndReadMate(t, at), 'quad-2',
          reason: 'a mirrored tree did not move the pick, so the upright case '
              'is not evidence of anything');
    });
  });

  testWidgets('the overlay is a sibling of the flip, never a descendant',
      (t) async {
    controller = editor(withQuad: true);
    final state = await pump(t);

    final overlay = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is CraftEditorPainter);
    expect(overlay, findsOneWidget);

    // Precondition 3: every gesture widget is an ANCESTOR of the flip, and the
    // overlay lives in the same subtree beneath them.
    expect(find.ancestor(of: overlay, matching: find.byType(RawGestureDetector)),
        findsOneWidget);
    // ...and the overlay never eats a click, whatever it draws over.
    expect(find.ancestor(of: overlay, matching: find.byType(IgnorePointer)),
        findsWidgets);

    // Precondition 2, as far as a headless tree can state it. The production
    // flip is inside `if (_scene != null)` and there is no scene here, so this
    // is a guard against a Transform being introduced unconditionally around
    // the overlay rather than proof about the flip itself — see the file header.
    expect(state.sceneReady, isFalse);
    expect(
      find.descendant(
        of: find.descendant(
            of: find.byType(CraftEditorViewport),
            matching: find.byType(Transform)),
        matching: overlay,
      ),
      findsNothing,
    );
  });
}

/// A captured frame, measured in ink.
class _Shot {
  _Shot(this.width, this.height, this.rgba);

  final int width;
  final int height;
  final Uint8List rgba;

  /// Anything meaningfully brighter than [AppTheme.bg] (5, 8, 15) — every
  /// colour the overlay paints in clears this by a wide margin.
  static const int _inkThreshold = 96;

  bool _isInk(int x, int y) {
    final i = (y * width + x) * 4;
    return rgba[i] + rgba[i + 1] + rgba[i + 2] > _inkThreshold;
  }

  int get inkCount {
    var n = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (_isInk(x, y)) n++;
      }
    }
    return n;
  }

  /// The smallest rectangle containing every lit pixel, or null when the frame
  /// is empty. Used instead of a centroid because a label chip drags a centroid
  /// sideways while the extent stays an honest statement about WHERE the ink is.
  Rect? get inkBounds {
    var minX = width, minY = height, maxX = -1, maxY = -1;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (!_isInk(x, y)) continue;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
    if (maxX < 0) return null;
    return Rect.fromLTRB(
        minX.toDouble(), minY.toDouble(), maxX + 1.0, maxY + 1.0);
  }
}
