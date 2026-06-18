// TRUE-PIPELINE render harness. Unlike sphere_diag_test.dart (which hand-builds
// a BodyView + checker), this drives the REAL in-game rendering pipeline end to
// end: the real solar system + a real landed craft + the real
// TopDownSnapshotPresenter.present() -> TopDownSnapshot -> TopDownPainter, with
// the SAME PerspectiveCamera the live SimulationView builds, and the REAL Earth
// surface texture decoded from assets.
//
//   flutter test test/screenshots/pipeline_harness_test.dart
//
// Writes test_out/pipe_*.png — one per (azimuth, elevation, range) combo, for
// both the atmosphere and surface goals. Each shot is also analysed for the two
// failure modes (atmosphere gap above the horizon; missing surface wedges) and
// the verdict is printed, so regressions are caught without eyeballing.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
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

const Size kSize = Size(1280, 800);
const double kLatDeg = 12, kLonDeg = 220; // craft surface position (day side @ epoch0)

/// Camera (azimuth, elevation) that looks at the craft's GROUND, tilted [tilt]
/// radians off straight-down-nadir toward the local horizon, with [azOff] swing
/// around the local vertical. tilt=0 looks straight down the craft's local up;
/// tilt->pi/2 looks at the horizon. This is what actually frames the planet
/// surface — the raw PerspectiveCamera elevation is ecliptic-relative and does
/// NOT point at an off-equator landed craft's ground.
({double azimuth, double elevation}) _groundLook(double azOff, double tilt) {
  final lat = kLatDeg * math.pi / 180, lon = kLonDeg * math.pi / 180;
  // Local up (outward radial) at the craft, body frame == world frame here.
  final up = Vector3(
    math.cos(lat) * math.cos(lon),
    math.cos(lat) * math.sin(lon),
    math.sin(lat),
  ).normalized;
  // Tangent frame: east = z_axis x up, north = up x east.
  final zAxis = Vector3(0, 0, 1);
  var east = zAxis.cross(up);
  east = east.length < 1e-6 ? Vector3(1, 0, 0) : east.normalized;
  final north = up.cross(east).normalized;
  // Forward = look direction = tilt the down-vector toward a tangent heading.
  final tangent = north * math.cos(azOff) + east * math.sin(azOff);
  final fwd =
      ((up * -math.cos(tilt)) + (tangent * math.sin(tilt))).normalized;
  // Recover the PerspectiveCamera angles from forward:
  //   forward = (cos e sin a, cos e cos a, -sin e)
  final elevation = math.asin((-fwd.z).clamp(-1.0, 1.0));
  final azimuth = math.atan2(fwd.x, fwd.y);
  return (azimuth: azimuth, elevation: elevation);
}

/// Loads the real Earth surface map from the asset bundle and decodes it, so the
/// harness samples the EXACT texels the game does (a black-pole / continent-edge
/// region was where the textured wedge first showed).
Future<ui.Image> _loadEarthTexture(WidgetTester t) async {
  late ui.Image img;
  await t.runAsync(() async {
    final data = await rootBundle.load('assets/textures/earth.jpg');
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    img = (await codec.getNextFrame()).image;
  });
  return img;
}

/// Loads the atmosphere fragment shader (null if shaders aren't available here).
Future<ui.FragmentShader?> _loadAtmoShader(WidgetTester t) async {
  ui.FragmentShader? s;
  await t.runAsync(() async {
    try {
      final program =
          await ui.FragmentProgram.fromAsset('shaders/atmosphere.frag');
      s = program.fragmentShader();
    } catch (_) {
      s = null; // fall back to the radial halo
    }
  });
  return s;
}

/// One render of the true pipeline at a camera (azimuth, elevation, range) on a
/// landed craft at (latDeg, lonDeg). Returns the captured RGBA bytes + size for
/// analysis, and writes the PNG.
Future<_Shot> _renderPipeline(
  WidgetTester t,
  String name, {
  required StaticUniverseRepository universe,
  required InMemoryVesselRepository vessels,
  required Vessel craft,
  required ui.Image earthTex,
  required ui.FragmentShader? atmoShader,
  required double azimuth,
  required double elevation,
  required double rangeM,
  double fovDeg = 75,
}) async {
  t.view.physicalSize = kSize;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);

  // The SAME camera the live SimulationView builds. Focus is the landed VESSEL,
  // so _focusBodyRadius is 0 there and range == eye->vessel distance (an altitude
  // above the surface, since the vessel sits on it).
  final cam = PerspectiveCamera(
    azimuth: azimuth,
    elevation: elevation,
    range: rangeM,
    fovY: fovDeg * math.pi / 180,
    viewportH: kSize.height,
  );

  final presenter = TopDownSnapshotPresenter(
    vessels: vessels,
    universe: universe,
  );
  final snapshot = presenter.present(focus: craft.id, camera: cam);

  final textures = TextureCache()..seed('earth', earthTex);
  final painter = TopDownPainter(
    snapshot,
    textures: textures,
    view: cam,
    atmoShader: atmoShader,
    // Skybox + orbit rails OFF so space reads pure black and no thin rail lines
    // confuse the pixel analysis. Only the sphere + atmosphere + vessel marker +
    // HUD remain; the detector masks the HUD + marker regions.
    layers: const DebugLayers(skybox: false, orbitRails: false),
  );

  final key = GlobalKey();
  await t.pumpWidget(MaterialApp(
    home: RepaintBoundary(
      key: key,
      child: CustomPaint(size: kSize, painter: painter),
    ),
  ));
  await t.pump();

  late Uint8List rgba;
  await t.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.0);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('test_out/pipe_$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(png!.buffer.asUint8List());
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    rgba = raw!.buffer.asUint8List();
  });
  return _Shot(name, rgba, kSize.width.toInt(), kSize.height.toInt());
}

/// A captured frame + helpers to detect the two failure modes by scanning pixels.
class _Shot {
  final String name;
  final Uint8List rgba;
  final int w, h;
  _Shot(this.name, this.rgba, this.w, this.h);

  ({int r, int g, int b, int a}) px(int x, int y) {
    final i = (y * w + x) * 4;
    return (r: rgba[i], g: rgba[i + 1], b: rgba[i + 2], a: rgba[i + 3]);
  }

  /// HUD text (top-left block) + the vessel marker (centre) are UI, not the
  /// sphere — mask them so they don't read as surface in the gap analysis.
  bool _isUi(int x, int y) {
    if (x < 380 && y < 140) return true; // top-left HUD text block
    if (x < 200 && y > h - 20) return true; // bottom-left build stamp
    if (x > w - 260 && y > h - 20) return true; // bottom-right credits
    if (x > 615 && x < 800 && y > 388 && y < 418) return true; // vessel marker
    return false;
  }

  bool _isSpace(int x, int y) {
    if (_isUi(x, y)) return false; // treat UI as "not surface" -> space-like
    final p = px(x, y);
    return p.r < 16 && p.g < 16 && p.b < 16; // near-black background
  }

  bool _isSurfaceOrAtmo(int x, int y) {
    if (_isUi(x, y)) return false;
    final p = px(x, y);
    return !(p.r < 16 && p.g < 16 && p.b < 16);
  }

  /// SURFACE WEDGE TEST: a wedge reads as a patch of SPACE fully enclosed by
  /// surface/atmosphere on a column. Scan each column; within the body's vertical
  /// span (first→last non-space pixel), count interior space runs. Any interior
  /// gap (space between two surface pixels in a column) is a wedge/hole.
  /// Returns the worst (largest) interior gap height in px (0 = clean).
  int worstInteriorGap() {
    var worst = 0;
    for (var x = 0; x < w; x += 2) {
      int? first, last;
      for (var y = 0; y < h; y++) {
        if (_isSurfaceOrAtmo(x, y)) {
          first ??= y;
          last = y;
        }
      }
      if (first == null || last == null || last - first < 4) continue;
      var run = 0;
      for (var y = first; y <= last; y++) {
        if (_isSpace(x, y)) {
          run++;
          if (run > worst) worst = run;
        } else {
          run = 0;
        }
      }
    }
    return worst;
  }

  /// ATMOSPHERE GAP TEST: above the surface horizon there must be NO band of pure
  /// space between the surface and the atmosphere glow — the haze must touch the
  /// horizon. We look for the atmosphere as pixels that are bluish/glowy (b
  /// noticeably above r, low-to-mid brightness) and the surface as brighter/お
  /// textured. Heuristic: along columns crossing the limb, find the transition
  /// from surface to space; require atmosphere-tinted pixels immediately at/above
  /// that transition (within a few px). Returns the count of limb columns that
  /// have a CLEAN space gap (>3px of pure black) between surface and any atmo —
  /// i.e. atmosphere detached from the horizon. 0 = good.
  int detachedAtmoColumns() {
    var bad = 0;
    for (var x = 0; x < w; x += 4) {
      // Find the topmost surface pixel in this column (the horizon from above).
      int? surfTop;
      for (var y = 0; y < h; y++) {
        if (_isSurfaceOrAtmo(x, y) && !_isAtmoTint(x, y)) {
          surfTop = y;
          break;
        }
      }
      if (surfTop == null || surfTop < 6) continue;
      // Walk UP from the surface top: are the pixels just above it atmosphere,
      // or pure space? A run of pure space before any atmo = a detached gap.
      var spaceRun = 0;
      var sawAtmo = false;
      for (var y = surfTop - 1; y >= 0 && y > surfTop - 120; y--) {
        if (_isAtmoTint(x, y)) {
          sawAtmo = true;
          break;
        } else if (_isSpace(x, y)) {
          spaceRun++;
        }
      }
      // Only count columns that DO have atmosphere somewhere above (so we're on
      // the lit limb), but with a pure-space gap before it.
      if (sawAtmo && spaceRun > 3) bad++;
    }
    return bad;
  }

  bool _isAtmoTint(int x, int y) {
    final p = px(x, y);
    // Bluish glow: blue channel clearly leads, not pure black, not bright white
    // surface. Tuned for the Earth atmosphere tint (0xFF6FB4FF-ish) over space.
    final lum = (p.r + p.g + p.b) / 3;
    return lum > 12 && lum < 200 && p.b > p.r + 12 && p.b > 40;
  }
}

void main() {
  // The real solar system + a landed Ascent Vehicle on Earth's equator at a
  // mid-longitude (avoid the texture pole/antimeridian special cases; those are
  // covered separately). The presenter projects everything through the live cam.
  late StaticUniverseRepository universe;
  late InMemoryVesselRepository vessels;
  late Vessel craft;
  late ui.Image earthTex;

  setUpAll(() {
    final system = SampleWorld.realSystem();
    universe = StaticUniverseRepository(system);
    craft = SampleWorld.buildSurfaceCraft(
      system.require(SampleWorld.earth),
      latDeg: kLatDeg,
      lonDeg: kLonDeg,
    );
    vessels = InMemoryVesselRepository([craft]);
  });

  // ---- ATMOSPHERE GOAL: 10 (azOff, tilt-from-nadir, range) combos ----
  // The eye is well above the surface (large range) and tilted near the horizon
  // (tilt ~1.2-1.5 rad) so the limb arc against space is on screen — that's where
  // the haze must be soft + touch the horizon with no gap. azOff swings the look
  // direction around the local vertical so every heading is covered.
  final atmoCombos = <(String, double, double, double)>[
    ('atmo_01', 0.0, 1.35, 1.2e6),
    ('atmo_02', 0.63, 1.42, 1.5e6),
    ('atmo_03', 1.26, 1.28, 2.0e6),
    ('atmo_04', 1.88, 1.46, 1.0e6),
    ('atmo_05', 2.51, 1.20, 2.5e6),
    ('atmo_06', 3.14, 1.40, 8.0e5),
    ('atmo_07', 3.77, 1.33, 1.8e6),
    ('atmo_08', 4.40, 1.48, 3.0e6),
    ('atmo_09', 5.03, 1.25, 1.3e6),
    ('atmo_10', 5.65, 1.44, 2.2e6),
  ];

  for (final (n, azOff, tilt, rng) in atmoCombos) {
    testWidgets('PIPE atmosphere $n', (t) async {
      earthTex = await _loadEarthTexture(t);
      final shader = await _loadAtmoShader(t);
      final look = _groundLook(azOff, tilt);
      final shot = await _renderPipeline(t, n,
          universe: universe,
          vessels: vessels,
          craft: craft,
          earthTex: earthTex,
          atmoShader: shader,
          azimuth: look.azimuth,
          elevation: look.elevation,
          rangeM: rng);
      final detached = shot.detachedAtmoColumns();
      // ignore: avoid_print
      print('ATMO $n: detachedAtmoColumns=$detached  '
          '(0 = haze touches the horizon everywhere)');
    });
  }

  // ---- SURFACE GOAL: 10 (azOff, tilt-from-nadir, range) combos ----
  // Low ranges + a spread of tilts from near-nadir (tilt 0.1) to near-horizon
  // (tilt 1.4) — the landed/grazing regime where the textured wedge appeared.
  // azOff covers every heading.
  final surfCombos = <(String, double, double, double)>[
    ('surf_01', 0.0, 0.10, 5.0e3),
    ('surf_02', 0.63, 0.55, 1.0e4),
    ('surf_03', 1.26, 0.95, 2.0e4),
    ('surf_04', 1.88, 1.25, 8.0e3),
    ('surf_05', 2.51, 0.30, 1.5e4),
    ('surf_06', 3.14, 1.40, 3.0e4),
    ('surf_07', 3.77, 0.75, 6.0e3),
    ('surf_08', 4.40, 1.15, 1.2e4),
    ('surf_09', 5.03, 0.45, 2.5e4),
    ('surf_10', 5.65, 1.30, 5.0e4),
  ];

  for (final (n, azOff, tilt, rng) in surfCombos) {
    testWidgets('PIPE surface $n', (t) async {
      earthTex = await _loadEarthTexture(t);
      final shader = await _loadAtmoShader(t);
      final look = _groundLook(azOff, tilt);
      final shot = await _renderPipeline(t, n,
          universe: universe,
          vessels: vessels,
          craft: craft,
          earthTex: earthTex,
          atmoShader: shader,
          azimuth: look.azimuth,
          elevation: look.elevation,
          rangeM: rng);
      final gap = shot.worstInteriorGap();
      // ignore: avoid_print
      print('SURF $n: worstInteriorGap=${gap}px  (0 = no wedge/hole)');
    });
  }
}
