// Diagnostic capture of the textured planet sphere at a chosen camera state,
// so the renderer can be inspected as a PNG instead of described. Renders the
// real TopDownPainter with a hand-built snapshot + a synthetic checkerboard
// texture (so mesh gaps / missing tiles are obvious).
//
//   flutter test test/screenshots/sphere_diag_test.dart
//
// Writes test_out/sphere_*.png.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:acro_space_simulator/adapters/presenters/top_down_snapshot.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter/debug_layers.dart';
import 'package:acro_space_simulator/infrastructure/flutter/texture_cache.dart';
import 'package:acro_space_simulator/infrastructure/flutter/top_down_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const double kEarthR = 6371000.0;

/// A green/blue checkerboard so the sphere's UV + mesh tiling are visible and
/// any hole in the mesh reads as the dark background.
Future<ui.Image> _checker(int w, int h) async {
  final rec = ui.PictureRecorder();
  final cv = Canvas(rec);
  cv.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = const Color(0xFF103040));
  const cells = 24;
  final cw = w / cells, ch = h / (cells ~/ 2);
  for (var y = 0; y < cells ~/ 2; y++) {
    for (var x = 0; x < cells; x++) {
      if ((x + y).isEven) continue;
      cv.drawRect(Rect.fromLTWH(x * cw, y * ch, cw, ch),
          Paint()..color = const Color(0xFF40C080));
    }
  }
  final pic = rec.endRecording();
  return pic.toImage(w, h);
}

Future<void> _shootSphere(
  WidgetTester t,
  String name, {
  required double altM, // eye altitude above the surface
  required double elevation, // camera tilt (0 = look at horizon)
  required double fovDeg,
}) async {
  const size = Size(1280, 800);
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);

  late ui.Image tex;
  await t.runAsync(() async {
    tex = await _checker(512, 256);
  });
  final textures = TextureCache()..seed('earth', tex);

  // Camera focus sits on the surface; the body centre is one radius "below"
  // (along -Z, the local up). range = altitude above the surface.
  final cam = PerspectiveCamera(
    azimuth: 0,
    elevation: elevation,
    range: altM,
    fovY: fovDeg * math.pi / 180,
    viewportH: size.height,
  );
  // Body centre straight "below" the focus (along -Z). Looking down (elev pi/2)
  // centres on the +Z body axis = the equirect texture's pole; the tests below
  // mostly view it from an angle so the smear-prone pole isn't frame-centre.
  final worldRel = Vector3(0, 0, -kEarthR);
  final relScreen = cam.projectPx(worldRel);
  final bx = relScreen?.x ?? 0, by = relScreen?.y ?? 0;

  final body = BodyView(
    'Earth', bx, by, kEarthR, false,
    hasAtmosphere: true,
    textureKey: 'earth',
    sunWorldX: 0, sunWorldY: 1, sunWorldZ: 0,
    radiusPx: cam.radiusPx(worldRel, kEarthR),
    worldRel: worldRel,
  );
  final snapshot = TopDownSnapshot(
    bodies: [body],
    vessels: const [],
    hud: const HudView([]),
  );
  final painter = TopDownPainter(
    snapshot,
    textures: textures,
    view: cam,
    layers: const DebugLayers(skybox: false),
  );

  final key = GlobalKey();
  await t.pumpWidget(MaterialApp(
    home: RepaintBoundary(
      key: key,
      child: CustomPaint(size: size, painter: painter),
    ),
  ));
  await t.pump();

  await t.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('test_out/sphere_$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  // Sanity: far away the whole disc + checker must be visible. View from an
  // angle (elev 0.9) so the frame centre isn't the equirect texture pole.
  testWidgets('sphere far (3000 km up)', (t) async {
    await _shootSphere(t, 'far_3000km',
        altM: 3000000, elevation: 0.9, fovDeg: 60);
  });
  // elevation pi/2 = straight down at the nadir; less = tilt up toward the
  // horizon (the body centre is straight below, so the horizon is a small dip
  // off pi/2 at these low altitudes).
  testWidgets('sphere @ 3km looking at horizon', (t) async {
    await _shootSphere(t, 'surface_3km_horizon',
        altM: 3000, elevation: math.pi / 2 - 0.12, fovDeg: 75);
  });
  testWidgets('sphere @ 3km straight down', (t) async {
    await _shootSphere(t, 'surface_3km_down',
        altM: 3000, elevation: math.pi / 2, fovDeg: 75);
  });
  testWidgets('sphere @ 100m looking at horizon', (t) async {
    await _shootSphere(t, 'surface_100m_horizon',
        altM: 100, elevation: math.pi / 2 - 0.03, fovDeg: 75);
  });
}
