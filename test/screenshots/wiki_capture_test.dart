// Captures clean, lit, in-game scenes for the WIKI / release gallery, rendered
// through the REAL pipeline (real solar system + real camera + real Earth
// texture). Unlike the diagnostic harnesses these are framed for presentation:
// day-lit Earth, an orbiter and a landed craft, from orbital and surface views.
//
//   flutter test test/screenshots/wiki_capture_test.dart
//
// Writes wiki/images/*.png.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:acro_space_simulator/adapters/presenters/top_down_snapshot.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/flutter/debug_layers.dart';
import 'package:acro_space_simulator/infrastructure/flutter/texture_cache.dart';
import 'package:acro_space_simulator/infrastructure/flutter/top_down_painter.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

const Size kSize = Size(1600, 900);

Future<ui.Image> _tex(WidgetTester t, String key) async {
  late ui.Image img;
  await t.runAsync(() async {
    final data = await rootBundle.load('assets/textures/$key.jpg');
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    img = (await codec.getNextFrame()).image;
  });
  return img;
}

({double azimuth, double elevation}) _groundLook(
    double latDeg, double lonDeg, double azOff, double tilt) {
  final lat = latDeg * math.pi / 180, lon = lonDeg * math.pi / 180;
  final up = Vector3(math.cos(lat) * math.cos(lon),
          math.cos(lat) * math.sin(lon), math.sin(lat))
      .normalized;
  var east = Vector3(0, 0, 1).cross(up);
  east = east.length < 1e-6 ? Vector3(1, 0, 0) : east.normalized;
  final north = up.cross(east).normalized;
  final tangent = north * math.cos(azOff) + east * math.sin(azOff);
  final fwd = ((up * -math.cos(tilt)) + (tangent * math.sin(tilt))).normalized;
  return (
    azimuth: math.atan2(fwd.x, fwd.y),
    elevation: math.asin((-fwd.z).clamp(-1.0, 1.0)),
  );
}

Future<void> _shoot(
  WidgetTester t,
  String name, {
  required StaticUniverseRepository universe,
  required InMemoryVesselRepository vessels,
  required VesselId focus,
  required Map<String, ui.Image> textures,
  required double azimuth,
  required double elevation,
  required double rangeM,
  double fovDeg = 70,
}) async {
  t.view.physicalSize = kSize;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);

  final cam = PerspectiveCamera(
    azimuth: azimuth,
    elevation: elevation,
    range: rangeM,
    fovY: fovDeg * math.pi / 180,
    viewportH: kSize.height,
  );
  final presenter =
      TopDownSnapshotPresenter(vessels: vessels, universe: universe);
  final snapshot = presenter.present(focus: focus, camera: cam);

  final cache = TextureCache();
  textures.forEach(cache.seed);
  final painter = TopDownPainter(
    snapshot,
    textures: cache,
    view: cam,
    layers: const DebugLayers(),
  );

  final key = GlobalKey();
  await t.pumpWidget(MaterialApp(
    home: RepaintBoundary(
      key: key,
      child: CustomPaint(size: kSize, painter: painter),
    ),
  ));
  await t.pump();
  await t.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.0);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('wiki/images/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(png!.buffer.asUint8List());
  });
}

void main() {
  late StaticUniverseRepository universe;
  late InMemoryVesselRepository vessels;
  late Vessel orbiter;
  late Vessel craft;
  late Map<String, ui.Image> tex;

  setUpAll(() {
    final system = SampleWorld.realSystem();
    universe = StaticUniverseRepository(system);
    orbiter = SampleWorld.buildEarthOrbiter(altitude: 1.2e6);
    craft = SampleWorld.buildSurfaceCraft(
      system.require(SampleWorld.earth),
      latDeg: 10,
      lonDeg: 220, // day side at epoch 0
    );
    vessels = InMemoryVesselRepository([orbiter, craft]);
  });

  testWidgets('wiki: earth from orbit', (t) async {
    tex = {'earth': await _tex(t, 'earth'), 'starfield': await _tex(t, 'starfield')};
    final look = _groundLook(10, 220, 0.4, 1.40);
    await _shoot(t, 'hero_earth_orbit',
        universe: universe,
        vessels: vessels,
        focus: craft.id,
        textures: tex,
        azimuth: look.azimuth,
        elevation: look.elevation,
        rangeM: 2.4e6,
        fovDeg: 70);
  });

  testWidgets('wiki: atmosphere limb', (t) async {
    tex = {'earth': await _tex(t, 'earth'), 'starfield': await _tex(t, 'starfield')};
    final look = _groundLook(10, 220, 1.2, 1.30);
    await _shoot(t, 'atmosphere_limb',
        universe: universe,
        vessels: vessels,
        focus: craft.id,
        textures: tex,
        azimuth: look.azimuth,
        elevation: look.elevation,
        rangeM: 2.0e6,
        fovDeg: 70);
  });

  testWidgets('wiki: surface horizon', (t) async {
    tex = {'earth': await _tex(t, 'earth'), 'starfield': await _tex(t, 'starfield')};
    final look = _groundLook(10, 220, 0.0, 1.40);
    await _shoot(t, 'surface_horizon',
        universe: universe,
        vessels: vessels,
        focus: craft.id,
        textures: tex,
        azimuth: look.azimuth,
        elevation: look.elevation,
        rangeM: 4.0e4,
        fovDeg: 75);
  });

  testWidgets('wiki: nadir surface over land', (t) async {
    tex = {'earth': await _tex(t, 'earth'), 'starfield': await _tex(t, 'starfield')};
    // Lower, slightly tilted, over a land mass (lon ~285 = the Americas).
    final landCraft = SampleWorld.buildSurfaceCraft(
      universe.current().require(SampleWorld.earth),
      latDeg: 20,
      lonDeg: 185,
      id: 'land-craft',
    );
    final v = InMemoryVesselRepository([landCraft]);
    final look = _groundLook(20, 185, 0.3, 0.7);
    await _shoot(t, 'surface_nadir',
        universe: universe,
        vessels: v,
        focus: landCraft.id,
        textures: tex,
        azimuth: look.azimuth,
        elevation: look.elevation,
        rangeM: 6.0e4,
        fovDeg: 75);
  });

  testWidgets('wiki: orbiter over earth', (t) async {
    tex = {'earth': await _tex(t, 'earth'), 'starfield': await _tex(t, 'starfield')};
    // Focus the LANDED craft (on the day side) but pull far back along a near-
    // horizon tilt so the full lit Earth + the orbiter are framed together.
    final look = _groundLook(10, 220, 0.7, 1.46);
    await _shoot(t, 'orbiter_over_earth',
        universe: universe,
        vessels: vessels,
        focus: craft.id,
        textures: tex,
        azimuth: look.azimuth,
        elevation: look.elevation,
        rangeM: 5.0e6,
        fovDeg: 60);
  });
}
