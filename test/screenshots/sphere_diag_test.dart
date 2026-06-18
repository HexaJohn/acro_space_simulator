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

  // A craft sits at a FIXED surface foot point P; local-up = P (normalised),
  // independent of where the camera looks. The body centre is one radius below
  // the foot. The `elevation` param here is reinterpreted as TILT-FROM-NADIR:
  // pi/2 = look straight down local-up; smaller = tilt up toward the horizon.
  //
  // We put the foot on the EQUATOR (+Y), NOT the +Z texture pole, so the normal
  // ascent view never sits on the pole singularity (a separate test stresses the
  // pole). The camera azimuth/elevation are chosen so forward aims from the eye
  // toward the foot, tilted by (pi/2 - elevation) up off nadir within the
  // foot's local vertical plane.
  final tiltFromNadir = math.pi / 2 - elevation; // 0 = nadir
  // Foot local frame: up=+Y, "north"=+Z, "east"=+X.
  // Camera forward = look direction = tilt the down-vector (-Y) toward north
  // (+Z) by tiltFromNadir.
  final fwd = Vector3(
    0,
    -math.cos(tiltFromNadir),
    math.sin(tiltFromNadir),
  ).normalized;
  // Recover the azimuth/elevation the PerspectiveCamera needs for this forward.
  // forward = (cos e * sin a, cos e * cos a, -sin e)  =>  e = asin(-fwd.z)... but
  // our fwd.z>=0, so elevation = -asin(fwd.z); azimuth from x,y.
  final camElev = math.asin((-fwd.z).clamp(-1.0, 1.0));
  final camAzim = math.atan2(fwd.x, fwd.y);
  final cam = PerspectiveCamera(
    azimuth: camAzim,
    elevation: camElev,
    range: altM,
    fovY: fovDeg * math.pi / 180,
    viewportH: size.height,
  );
  final localUp = Vector3(0, 1, 0); // foot at the equator, +Y
  final worldRel = localUp * -kEarthR; // body centre = foot - up*R, foot at focus
  // Spin so the sub-camera longitude isn't on the antimeridian seam (lon=±pi).
  const bodySpin = 0.7;
  final relScreen = cam.projectPx(worldRel);
  final bx = relScreen?.x ?? 0, by = relScreen?.y ?? 0;

  final body = BodyView(
    'Earth', bx, by, kEarthR, false,
    hasAtmosphere: true,
    textureKey: 'earth',
    sunWorldX: 0, sunWorldY: 1, sunWorldZ: 0,
    radiusPx: cam.radiusPx(worldRel, kEarthR),
    worldRel: worldRel,
    spin: bodySpin,
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

  // ASCENT-scenario repro: 10 km alt, fov 75, panning the camera through a few
  // tilt angles toward the horizon. The reported bug: surface triangles drop out
  // at some angles, and the atmosphere halo drifts off the limb.
  for (final spec in <(String, double)>[
    ('10km_down', math.pi / 2), // straight down (nadir)
    ('10km_tilt30', math.pi / 2 - 0.52), // ~30 deg up off nadir
    ('10km_tilt60', math.pi / 2 - 1.05), // ~60 deg up
    ('10km_horizon', math.pi / 2 - 1.40), // near the horizon
    ('10km_grazing', math.pi / 2 - 1.52), // grazing, horizon high in frame
  ]) {
    testWidgets('sphere @ 10km ${spec.$1}', (t) async {
      await _shootSphere(t, 'ascent_${spec.$1}',
          altM: 10000, elevation: spec.$2, fovDeg: 75);
    });
  }

  // ORBIT-TRACKING repro — the DEFAULT in-game ascent start: camera focuses the
  // orbiter at 3000 km altitude and the eye is pulled back a small range (the
  // "10K m" zoom readout is the eye->focus RANGE, not the surface altitude).
  // Earth is a distant disc below; this is the path where the SCREEN-SPACE
  // atmosphere halo (a circle at the projected centre) is active and can drift
  // off the limb. Pan the camera so Earth moves across / off frame.
  for (final spec in <(String, double, double)>[
    ('centre', 0.0, 0.6), // Earth centred below
    ('limb', 0.9, 0.3), // Earth's limb across frame
    ('offaxis', 1.3, 0.2), // Earth pushed toward the edge
  ]) {
    testWidgets('sphere orbit-track 3000km ${spec.$1}', (t) async {
      await _shootOrbitTrack(t, 'orbit_${spec.$1}',
          focusAltM: 3000000, rangeM: 10000, azimuth: spec.$2, elevation: spec.$3);
    });
  }
}

/// Orbit-tracking shot: the camera focuses a point at [focusAltM] above the
/// surface (an orbiter), with the eye pulled back [rangeM] (the zoom readout).
/// The body is the full Earth, [focusAltM]+R below the focus.
Future<void> _shootOrbitTrack(
  WidgetTester t,
  String name, {
  required double focusAltM,
  required double rangeM,
  required double azimuth,
  required double elevation,
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

  final cam = PerspectiveCamera(
    azimuth: azimuth,
    elevation: elevation,
    range: rangeM,
    fovY: 75 * math.pi / 180,
    viewportH: size.height,
  );
  // Focus is the orbiter; Earth centre sits (R + focusAlt) straight below the
  // focus along the world -Z (nadir of the focus).
  final worldRel = Vector3(0, 0, -(kEarthR + focusAltM));
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
