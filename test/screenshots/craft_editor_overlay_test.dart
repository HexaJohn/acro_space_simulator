// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Diagnostic capture of the craft editor's 2D OVERLAY, so the thing a player
// actually aims with can be inspected as a PNG instead of described.
//
//   flutter test test/screenshots/craft_editor_overlay_test.dart
//
// Writes test_out/craft_editor_overlay_*.png — six camera poses over a fully
// assembled Apollo Lunar Module, plus two isolation shots.
//
// ## Why the overlay is worth photographing on its own
//
// `CraftEditorPainter` takes a plain `CraftEditorOverlay` value and projects
// every point itself, so it renders with no Impeller context, no shader bundle
// and no widget tree of consequence. That makes it the one part of the editor
// whose exact output can be captured in CI, and it is also the part carrying the
// information a placement depends on: which nodes are open, which of them the
// held part can use, which one a click would commit to, and where the mass and
// the thrust line actually are.
//
// What a human is looking for in these images: markers standing off the hull
// they belong to rather than buried in it; the chevron on a surface node
// pointing OUT; the four `quad-*` markers evenly spaced; labels that do not pile
// up; and the centre-of-mass disc on the vehicle's axis, which is the visible
// confirmation that a four-way symmetric mount is really symmetric.
//
// The assertions are deliberately mechanical rather than golden-image
// comparisons. A golden would fail on every font and antialiasing change; what
// is pinned instead is that ink exists, that the six poses are six different
// pictures, and — the sharp one — that the centre-of-mass marker lands within a
// couple of pixels of where `CraftEditorCamera.project` says it should.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:acro_space_simulator/adapters/presenters/craft_editor_camera.dart';
import 'package:acro_space_simulator/domain/craft/attach_targets.dart';
import 'package:acro_space_simulator/domain/craft/craft_balance.dart';
import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/app_theme.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const Size _size = Size(1280, 800);

/// The flown Apollo Lunar Module: ascent stage, descent stage, DPS bell, four
/// landing gear legs and four RCS quads.
///
/// Built through the domain directly rather than through the editor's
/// controller, because this file is about what gets DRAWN and a craft built by
/// tapping would make every image depend on the input map as well.
CraftDesign _eagle() {
  final catalog = PartCatalog.standard();
  final design = CraftDesign(name: 'Eagle');
  design.addPart(
      def: catalog.byId('eagle-command-pod')!,
      instanceId: 'ascent',
      position: Vector3.zero);
  design.attachPart(
    def: catalog.byId('eagle-fuel-tank')!,
    instanceId: 'descent',
    toInstanceId: 'ascent',
    parentNode: 'stage-bottom',
    childNode: 'deck-top',
  );
  design.attachPart(
    def: catalog.byId('eagle-thruster')!,
    instanceId: 'dps',
    toInstanceId: 'descent',
    parentNode: 'engine-mount',
    childNode: 'mount',
  );
  for (var i = 1; i <= 4; i++) {
    design.attachPart(
      def: catalog.byId('eagle-legs')!,
      instanceId: 'leg-$i',
      toInstanceId: 'descent',
      parentNode: 'leg-$i',
      childNode: 'outrigger',
    );
    design.attachPart(
      def: catalog.byId('eagle-rcs-block')!,
      instanceId: 'quad-$i',
      toInstanceId: 'ascent',
      parentNode: 'quad-$i',
      childNode: 'mount',
    );
  }
  return design;
}

AttachTarget _node(CraftDesign design, String nodeName) =>
    AttachTargets.openNodes(design).firstWhere((t) => t.nodeName == nodeName);

/// The overlay as it looks mid-placement: a held RCS quad, `quad-1` hovered
/// under x4 symmetry, one of the legs selected, and the balance markers on.
///
/// One busy state rather than six sparse ones, so a pose that hides a marker
/// behind a hull or piles two labels on top of each other shows up in the
/// capture rather than in a player's session.
CraftEditorOverlay _busyOverlay(CraftDesign design, CraftEditorCamera cam) {
  final quadDef = PartCatalog.standard().byId('eagle-rcs-block')!;
  final pairings = AttachTargets.pairingsFor(design, quadDef);
  final hovered = _node(design, 'quad-1');
  final thrust = CraftBalance.thrust(design);
  final com = CraftBalance.centreOfMass(design);
  return CraftEditorOverlay(
    camera: cam,
    design: design,
    targets: AttachTargets.openNodes(design),
    compatible: {
      for (final p in pairings) (p.target.ownerInstanceId, p.target.nodeName)
    },
    hovered: hovered,
    seats: [for (var i = 1; i <= 4; i++) _node(design, 'quad-$i')],
    cursor: cam.project(hovered.positionInCraft)?.translate(26, 18),
    selection: AttachTargets.symmetryGroupOf(design, 'leg-1'),
    selectionLabel: 'Eagle Landing Gear Leg - S0 - x4',
    centreOfMass: com,
    thrustOrigin: thrust?.origin,
    thrustAxis: thrust?.direction,
    thrustOffAxisDeg: 0,
    hud: const [
      'Placing: Eagle RCS Quad (4 x R-4D) - Esc to stop',
      'Symmetry: x4',
    ],
  );
}

void main() {
  /// Paint [painter] over the app background at [_size] and write the PNG.
  Future<_Shot> shoot(
      WidgetTester t, CustomPainter painter, String name) async {
    t.view.physicalSize = _size;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final key = GlobalKey();
    await t.pumpWidget(MaterialApp(
      home: RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: AppTheme.bg,
          child: CustomPaint(size: _size, painter: painter),
        ),
      ),
    ));
    await t.pump();

    late _Shot shot;
    await t.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.0);
      final width = image.width, height = image.height;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      final bytes = png!.buffer.asUint8List();
      final file = File('test_out/craft_editor_overlay_$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      shot = _Shot(width, height, raw!.buffer.asUint8List(), bytes);
    });
    return shot;
  }

  group('the overlay over an assembled Lunar Module', () {
    testWidgets('six poses, six different pictures', (t) async {
      final design = _eagle();
      final framed = CraftEditorCamera.framing(design, _size);
      final pivot = framed.pivot;
      final engine = design.partById('dps')!.position;

      // Front / three-quarter / top / underside / zoomed nozzle / whole craft.
      // The underside and the nozzle are the two that matter most: they are
      // where a player checks that the footpads clear the bell, which is the
      // judgement a list UI cannot support and the reason the editor is 3D.
      final poses = <String, CraftEditorCamera>{
        'front': CraftEditorCamera(
            azimuth: 0, elevation: 0, distanceM: 14, pivot: pivot, viewport: _size),
        'three_quarter': CraftEditorCamera(
            azimuth: 0.9,
            elevation: 0.28,
            distanceM: 14,
            pivot: pivot,
            viewport: _size),
        'top': CraftEditorCamera(
            azimuth: 0.9,
            elevation: 1.4,
            distanceM: 14,
            pivot: pivot,
            viewport: _size),
        'underside': CraftEditorCamera(
            azimuth: 0.9,
            elevation: -1.0,
            distanceM: 12,
            pivot: pivot,
            viewport: _size),
        'nozzle': CraftEditorCamera(
            azimuth: 0.6,
            elevation: -0.35,
            distanceM: 3.5,
            pivot: engine,
            viewport: _size),
        'whole': framed,
      };

      final digests = <String, int>{};
      for (final entry in poses.entries) {
        final shot = await shoot(
            t,
            CraftEditorPainter(_busyOverlay(design, entry.value)),
            entry.key);
        expect(shot.inkCount, greaterThan(200),
            reason: 'pose "${entry.key}" drew almost nothing');
        digests[entry.key] = shot.digest;
      }

      // Six identical images would mean the harness is ignoring the pose it was
      // handed, which is the failure that makes a capture suite worthless
      // without anyone noticing.
      expect(digests.values.toSet(), hasLength(poses.length),
          reason: 'two poses produced byte-identical images: $digests');
    });

    testWidgets('the centre-of-mass marker is painted where project() puts it',
        (t) async {
      final design = _eagle();
      final cam = CraftEditorCamera.framing(design, _size);
      final com = CraftBalance.centreOfMass(design);

      // A four-way symmetric mount puts the mass on the axis. This is the
      // domain fact the marker exists to make visible, so it is worth stating
      // here: if it stops holding, the picture below is drawing the truth and
      // the craft is the thing that is wrong.
      expect(com.x, closeTo(0, 1e-6));
      expect(com.y, closeTo(0, 1e-6));

      // Nothing but the disc: every other layer is off, so ANY ink in this
      // image is the marker and its centroid is the marker's centre.
      final shot = await shoot(
        t,
        CraftEditorPainter(CraftEditorOverlay(
          camera: cam,
          design: design,
          showNodes: false,
          centreOfMass: com,
        )),
        'centre_of_mass',
      );

      final expected = cam.project(com)!;
      expect(shot.inkCount, greaterThan(60),
          reason: 'the centre-of-mass disc did not draw at all');
      expect((shot.inkCentroid! - expected).distance, lessThan(2.0),
          reason: 'the disc landed at ${shot.inkCentroid} but project() says '
              '$expected');
    });

    testWidgets('a craft entirely behind the near plane draws no markers',
        (t) async {
      // The overlay culls on exactly the number `toSceneCamera` clips on, so a
      // marker the renderer has thrown away must not be left painted over empty
      // space. Looking the other way is the cheapest way to ask for that.
      final design = _eagle();
      final away = CraftEditorCamera(
        azimuth: 0,
        elevation: 0,
        distanceM: CraftEditorCamera.minDistanceM,
        pivot: Vector3(0, 400, 0),
        viewport: _size,
      );
      final shot = await shoot(
        t,
        CraftEditorPainter(CraftEditorOverlay(
          camera: away,
          design: design,
          targets: AttachTargets.openNodes(design),
          centreOfMass: CraftBalance.centreOfMass(design),
        )),
        'behind_camera',
      );
      expect(shot.inkCount, 0,
          reason: 'markers were painted for a craft behind the near plane');
    });
  });
}

/// A captured frame: raw pixels for measuring, PNG bytes for the human.
class _Shot {
  _Shot(this.width, this.height, this.rgba, this.png);

  final int width;
  final int height;
  final Uint8List rgba;
  final Uint8List png;

  /// Anything meaningfully brighter than [AppTheme.bg] (5, 8, 15). Every colour
  /// the painter uses clears this by a wide margin, and the dark half of the
  /// centre-of-mass disc (16, 20, 27) deliberately does not.
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

  /// Centre of mass of the ink, or null when the frame is empty.
  Offset? get inkCentroid {
    var sx = 0.0, sy = 0.0, n = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (!_isInk(x, y)) continue;
        sx += x + 0.5;
        sy += y + 0.5;
        n++;
      }
    }
    return n == 0 ? null : Offset(sx / n, sy / n);
  }

  /// FNV-1a over the PNG bytes. Only ever compared for equality — enough to say
  /// "these two captures are the same picture" without a hashing dependency.
  int get digest {
    var h = 0x811c9dc5;
    for (final b in png) {
      h = ((h ^ b) * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  @override
  String toString() =>
      '_Shot(${width}x$height, ink $inkCount, ${math.max(png.length, 0)} B)';
}
