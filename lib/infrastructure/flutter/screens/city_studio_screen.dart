// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A city on demand, for profiling and for looking at.
///
/// The colony sibling of the scatter lab and the cloudscape: the same problem,
/// which is that judging a change to how cities look — or measuring what one
/// costs to draw — first requires a city, and laying out something big enough
/// to be representative takes far longer than the change being judged.
///
/// The knobs drive [CityGenSpec]; GENERATE builds the colony and draws it in
/// this screen's OWN scene — a patch of ground with the camera on it, and
/// nothing else in the world. Iterating in the flight universe meant flying to
/// the thing every time and waiting for a solar system to spin up around it.
///
/// The scene is dedicated but the machinery is not: the colony is a real
/// [CitySim], drawn by the real [CityNodes] through the real snapshot, so the
/// meshers, the traffic pass and the terrain shaper all run exactly as the
/// game runs them. A frame time measured here means something, and a colony
/// that looks wrong here looks wrong in the game.
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../adapters/presenters/rover_buggy.dart';
import '../../../adapters/repositories/in_memory_repositories.dart';
import '../../../adapters/repositories/in_memory_world_repositories.dart';
import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/colony/city/city_building_spec.dart';
import '../../../domain/colony/city/city_generator.dart';
import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/colony/city/city_terrain_shaper.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/shared/quaternion.dart';
import '../../../domain/shared/vector3.dart';
import '../../../domain/universe/real_solar_system.dart';
import '../../../domain/universe/star_system.dart';
import '../../flutter_scene/atmosphere_nodes.dart';
import '../../flutter_scene/city/city_nodes.dart';
import '../../flutter_scene/scatter/scatter_prop_library.dart';
import '../../../domain/architecture/building_generator.dart';
import '../../../domain/terrain/terrain_field.dart';
import '../../flutter_scene/city/city_materials.dart';
import '../../flutter_scene/city/road_mesher.dart';
import '../../flutter_scene/city/street_furniture.dart';
import '../../flutter_scene/city/scale_rig.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../flutter_scene/coord_convert.dart';
import '../../flutter_scene/debug_camera_rig.dart';
import '../../flutter_scene/graphics_quality.dart';
import '../../flutter_scene/lod_probe_camera.dart';
import '../../flutter_scene/rover_nodes.dart';
import 'city_plat_view.dart';
import '../../flutter_scene/terrain/terrain_nodes.dart';
import 'app_theme.dart';
import 'city_model.dart';
import 'city_site_actions.dart';

class CityStudioScreen extends StatefulWidget {
  const CityStudioScreen({super.key});

  @override
  State<CityStudioScreen> createState() => _CityStudioScreenState();
}

/// Remote-control hooks for the dev harness ([SimViewControl]'s pattern,
/// scoped to this screen): `main_city_studio_dev.dart` exposes these over the
/// VM service so a script can GENERATE a city and read the perf panel's
/// numbers headlessly — the same measure-first loop the flight view got.
/// Registered by the live State, cleared on dispose; null means no studio is
/// mounted.
class CityStudioDevHooks {
  CityStudioDevHooks._();
  /// Optional [blocks] overrides the "Blocks across" slider and [voxelM] the
  /// "City voxel floor" slider before the build, so a script can size the
  /// colony it measures and A/B the ground resolution under it.
  static Future<void> Function({int? blocks, double? voxelM, double? sprawlMiles})?
      generate;
  static Map<String, Object?> Function()? status;

  /// Flip the panel's ISOLATE switches remotely — the A/B the perf panel's
  /// own "unaccounted" annotation prescribes (shadows and atmosphere first).
  static void Function({bool? shadows, bool? atmosphere})? setIsolate;

  /// Hide or show the perf panel and the control column, so a screenshot
  /// can show the scene they cover.
  static void Function({bool? perf, bool? controls})? setPanels;

  /// Aim the orbit camera, so a screenshot can frame the outskirts.
  static void Function({double? distanceM, double? azimuth, double? elevation})?
      setCamera;

  /// Click at a viewport fraction (0..1 each way) and say what was hit —
  /// the picker's ray math, checked without a mouse.
  static String? Function(double fx, double fy)? pick;

  /// Put the walker somewhere (colony-local metres), looking [yaw] radians
  /// from north and [pitch] up, at [eyeM] above the ground — a hovering eye
  /// for a screenshot of one thing.
  static void Function(
      {required double e,
      required double n,
      required double yaw,
      required double pitch,
      double? eyeM})? walkTo;

  /// Put the dune buggy somewhere (colony-local metres) heading [yaw]
  /// radians from north, and hold [throttle] / [steer] for [seconds] — a
  /// drive with no keyboard, for a screenshot of the suspension and the
  /// dust at work. The status reports the buggy under 'rover'.
  static void Function(
      {required double e,
      required double n,
      required double yaw,
      double throttle,
      double steer,
      double seconds})? drive;
}

class _CityStudioScreenState extends State<CityStudioScreen>
    with SingleTickerProviderStateMixin {
  /// Shared flutter_scene resources; geometry CONSTRUCTION throws without it.
  static final Future<void> _staticInit = fs.Scene.initializeStaticResources();

  int _seed = 1;
  double _blocks = 4;
  double _blockM = 220;
  double _blockDepthM = 104;
  double _bend = 34;
  bool _alleys = true;
  double _transit = 1;
  double _viaducts = 1;
  double _build = 0.85;
  double _installations = 4;
  double _megatowers = 1;

  /// The outskirts: how far the outline departs from the grid, how far the
  /// trunk roads and the railway run out, how many farms line them, and
  /// whether there is a railway at all.
  double _taper = 1.0;
  double _outreachM = 4000;
  double _farms = 8;
  bool _railway = true;

  /// How far across the sprawl runs, miles. Twenty is Chicago.
  double _sprawlMiles = 20;
  String _body = 'earth';

  /// Worlds worth generating on: one breathable, the rest not, because the
  /// airless branch is a different city — sealed roads, pedestrian tubes and
  /// rovers instead of pavements and cars.
  static const _bodies = ['earth', 'moon', 'mars', 'titan'];

  // ---- Scene ------------------------------------------------------------
  fs.Scene? _scene;
  CityNodes? _city;

  final List<fs.Node> _rigNodes = [];
  bool _showRig = true;
  TerrainNodes? _terrain;
  AtmosphereNodes? _atmo;

  /// The terrain shader and its material tiles. Static and shared: the same
  /// two futures the flight renderer awaits, so the studio draws the SAME
  /// ground rather than a stand-in for it.
  static final Future<void> _terrainInit = Future.wait([
    TerrainNodes.loadShader(),
    TerrainNodes.loadTextures(),
    // The same raymarched sky the flight scene flies through — same shader,
    // same per-body styles — so the studio's daylight is the game's.
    AtmosphereNodes.loadShader(),
    // Bark and foliage: street trees are the scatter system's broadleaf.
    ScatterPropLibrary.loadTextures(),
    // The city's custom surface shader (per-fragment night skyglow).
    CityMaterials.loadShader(),
  ]);

  /// Everything the scene needs before it can draw, as ONE future built once.
  ///
  /// Built here and not in `build`: a [FutureBuilder] compares futures by
  /// IDENTITY, and this screen rebuilds every frame off its ticker. Composing
  /// the wait inside `build` handed it a brand-new future each time, which it
  /// dutifully reported as still waiting — the spinner never stopped, however
  /// long ago the resources had actually finished loading.
  late final Future<void> _ready = Future.wait([_staticInit, _terrainInit]);
  Ticker? _ticker;
  CitySim? _sim;
  WorldSnapshot? _snap;
  final FloatingOrigin _origin = FloatingOrigin();

  /// Hours the sun is turned about the body's spin axis, relative to the
  /// moment the site was captured. The generator picks whatever time of day
  /// the epoch happens to land on — which is night half the time — so each
  /// generate resets this to local midday and the slider takes it from there.
  double _sunTurnH = 0;
  Vector3 _anchorWorld = Vector3.zero;

  /// LOCAL up at the colony — the radial from the body's centre through it.
  ///
  /// Not world +Z. A colony sits on a sphere at some arbitrary lat/lon, so its
  /// ground plane is only level with the world axes at one point on the whole
  /// planet. Orbiting about +Z put the camera under the horizon and stood the
  /// city on its side everywhere else.
  Vector3 _upWorld = Vector3.unitZ;

  // ---- First person -------------------------------------------------------
  //
  // Everything about a street is judged from the pavement. An orbit camera
  // looking down at a block tells you the massing is plausible and nothing
  // about whether the storefronts are the right height, whether the awnings
  // clear your head, or whether the L actually passes over the carriageway —
  // which are the questions the whole masonry kit exists to answer.
  bool _firstPerson = false;

  /// Where the walker stands, in the colony's tangent plane: metres east and
  /// north of the anchor. Height is not stored — it is sampled from the ground
  /// every frame, so the walker follows the terrain the colony was cut into.
  double _walkE = 0, _walkN = -40;
  double _walkYaw = math.pi / 2, _walkPitch = 0;

  /// Eye height. The same 1.7 m the scale rig stands a person at, so the two
  /// agree about what human scale is.
  double _eyeHeightM = 1.7;

  /// Brisk-walk and hard-run speeds. Real ones (a stroll is 1.4 m/s), give or
  /// take a nudge for a tool — the old 6 and 22 crossed a block in four
  /// seconds, and nothing sells "the blocks are too small" like moving
  /// through them at forty miles an hour.
  static const double _walkSpeedMs = 2.0;
  static const double _runSpeedMs = 8.0;

  final Set<LogicalKeyboardKey> _held = {};

  /// The dune buggy (R): drive the streets instead of walking them. `_rover`
  /// is the live physics state; the chase camera hangs behind `_chaseYaw`,
  /// which eases toward the heading, plus a drag-around offset that relaxes
  /// while the throttle is held. No collision with buildings yet — it is a
  /// way to cover ground and feel the grading, not a traffic sim.
  bool _driving = false;
  RoverState? _rover;
  RoverNodes? _roverNodes;
  double _chaseYaw = 0;
  double _chaseOrbit = 0;
  double _chasePitch = 0.30;
  double _chaseDistM = 9;

  /// On the ground, one way or the other: the camera is a head (or a chase
  /// eye) with a radial up and the walk lens, not the orbit lens.
  bool get _groundView => _firstPerson || _driving;
  double get _fovY => _groundView ? 0.9 : 0.8;

  /// The ground sampler for the generated colony, kept so the walker can
  /// stand ON the terrain rather than at a fixed radius.
  TerrainField? _groundField;
  Vector3 _bodyCentreWorld = Vector3.zero;

  double _azimuth = 0.9;
  double _elevation = 0.55;
  double _distanceM = 1400;

  /// Viewport height, recorded where the scene lays out — the LOD probe's
  /// focal length needs it, same as the terrain studio.
  double _viewportH = 600;
  double _viewportW = 800;

  /// The debug rig (shared with the terrain studio): F pins the lens the
  /// streamer selects and culls through, the camera flies on, and the
  /// pinned lens is drawn as a frustum.
  final DebugCameraRig _rig = DebugCameraRig();
  DebugCameraGizmo? _rigGizmo;
  bool _showLensRig = true;

  /// The building last clicked on, with where the click landed, or null.
  ({String site, Parcel parcel, CityBuildingSpec spec, Offset at})? _picked;

  double get _focalPx =>
      LodProbeCamera.focalPxFor(_viewportH, _fovY);
  (double, double) _dragBase = (0, 0);
  /// Scene clock, as a notifier rather than plain state.
  ///
  /// The ticker used to `setState` the whole screen, which re-laid-out and
  /// re-rasterised every glyph in the control panel sixty times a second while
  /// the GPU was busy uploading scene geometry. Text came back with holes in
  /// it — missing glyphs drawn as hatched boxes. Only the scene needs to
  /// repaint on a tick, so only the scene listens.
  final ValueNotifier<double> _epoch = ValueNotifier<double>(0);

  /// The perf panel's own clock, bumped every [_perfTickEvery] ticks.
  ///
  /// The panel is fifty-odd text rows, and it used to sit inside the epoch
  /// builder with the scene — so every one of those paragraphs was rebuilt,
  /// re-laid-out and re-shaped at the frame rate, on the same UI thread the
  /// engine encodes the scene on. Numbers averaged over 90 frames do not
  /// change legibly between two frames; four times a second reads the same
  /// and costs a fifteenth as much.
  final ValueNotifier<int> _perfTick = ValueNotifier<int>(0);
  static const int _perfTickEvery = 15;
  int _perfCountdown = 0;

  // ---- Frame timing ------------------------------------------------------
  //
  // A frame counter says the city is slow; it does not say WHY. These split
  // the frame into the parts that can each be turned off, so the panel names
  // the culprit instead of implying one.
  final List<double> _frameMs = [];
  Duration _lastTick = Duration.zero;
  double _terrainMs = 0;
  double _cityMs = 0;

  // ---- Engine pipeline timings -------------------------------------------
  //
  // REAL per-frame numbers from the engine, not stopwatches around update():
  // build is the UI-thread frame, raster is the raster thread — encode,
  // submit, driver, and any blocking the GPU causes. This backend exposes no
  // GPU timer query, so "raster far above the CPU phase totals" is the
  // honest in-app GPU-bound signal; per-draw GPU timing needs an external
  // capture (see wiki/GPU-Profiling.md).
  final List<double> _uiMs = [];
  final List<double> _rasterMs = [];
  TimingsCallback? _timingsCb;

  /// Whole-scene draw census, walked from the scene root every 30 frames:
  /// what the ENGINE will submit, not just what the city pass reports.
  int _censusDraws = 0;
  int _censusInstances = 0;
  int _censusNodes = 0;
  int _censusCountdown = 0;

  /// The first per-frame failure, kept so the panel can name it.
  ///
  /// A studio that throws from inside its own build loop reports a hundred
  /// identical lines a second, each one attributed to the
  /// `ValueListenableBuilder` that happens to wrap the scene and none of them
  /// carrying a stack — which says only "something in the frame threw" and is
  /// very nearly useless. Guarding each phase separately names the phase,
  /// prints ONE stack, and lets the rest of the frame carry on drawing.
  ({String phase, Object error, StackTrace stack})? _fault;

  /// Run one phase of the frame, attributing anything it throws.
  void _phase(String name, void Function() body) {
    try {
      body();
    } catch (e, st) {
      if (_fault == null) {
        _fault = (phase: name, error: e, stack: st);
        debugPrint('CITY STUDIO: phase "$name" threw $e\n$st');
      }
    }
  }

  bool _busy = false;

  /// The cascaded shadow pass, as an isolate switch. Every cascade re-draws
  /// the whole scene into the shadow map, and the engine ENCODES that pass on
  /// the UI thread, inside SceneView's painter — so it is the biggest line
  /// item the phase timers cannot see (it lands in "ui build", not in
  /// "raster"). Flip it and watch the panel's "unaccounted" figure to
  /// attribute that cost.
  bool _shadows = true;

  /// Watch the colony being built: during zoning the frame is recaptured
  /// every few buildings and the loop paced, so buildings visibly arrive
  /// instead of the whole city appearing at once. Costs real wall time —
  /// that is the point — so the build-time calibration skips these runs.
  bool _slowBuild = false;

  /// Whether the running slow-mode build has aimed the camera yet.
  bool _previewAnchored = false;

  /// Where the running build has got to. Null when nothing is building.
  CityGenProgress? _progress;

  /// The last build, phase by phase and by cost — what the console printed,
  /// kept for the perf panel.
  List<String> _buildLog = const [];

  /// The plat view (M): the colony flat, in its own metres, drawn from the
  /// layout alone. While it is up the 3D streamers rest, and a build stops
  /// after the generator — the ground cut and the frame drape, minutes on a
  /// big colony, wait in [_pendingFrame] until the view goes 3D.
  bool _view2D = false;
  final CityPlatCamera _platCam = CityPlatCamera();
  ({CitySim sim, StarSystem system, Stopwatch sw})? _pendingFrame;

  /// Wall clock of the running build, so the readout is a measurement rather
  /// than the estimate it used to be.
  final Stopwatch _genClock = Stopwatch();
  String? _lastStats;
  bool _panel = true;

  /// Voxel floor (m) the colony's terrain brushes carry — see
  /// [CityTerrainShaper.voxelM]. 0 derives it from each brush's radius (the
  /// pre-floor behaviour: level 15-17 under every street). Applied at the
  /// next generate, since the brushes are cut then.
  double _cityVoxelM = 15;

  /// Perf panel collapsed to its FRAME line, so the scene behind it can be
  /// inspected. Toggled by tapping that line.
  bool _perfCollapsed = false;

  /// Milliseconds per lot squared, learned from the last real build.
  ///
  /// A hard-coded formula was wrong by an order of magnitude — it was fitted
  /// against `flutter test`, and a debug app build is roughly ten times
  /// slower, so the button promised 0.8 s for work that took 8. Calibrating
  /// from what actually happened makes the estimate honest on whatever build
  /// it is running on, and it self-corrects after one generate.
  static double _msPerLotSq = 5.0e-5;

  CityGenSpec get _spec => CityGenSpec(
        seed: _seed,
        bodyId: _body,
        blocksAcross: _blocks.round(),
        blockM: _blockM,
        blockDepthM: _blockDepthM,
        bendM: _bend,
        alleys: _alleys,
        transitLines: _transit.round(),
        elevatedHighways: _viaducts.round(),
        buildFraction: _build,
        installations: _installations.round(),
        megatowers: _megatowers.round(),
        taper: _taper,
        outreachM: _outreachM,
        farms: _farms.round(),
        railway: _railway,
        sprawlMiles: _sprawlMiles,
      );

  /// Lots the current spec will cut, roughly — the input to the build-time
  /// estimate. Follows the RECTANGULAR grid: frontage streets are spaced by
  /// the block's short dimension, so halving that doubles the street count and
  /// the lot count with it.
  double get _estimatedLots =>
      _blocks * (_blocks * _blockM / _blockDepthM) * 10;

  double get _estimateSec =>
      0.05 + _estimatedLots * _estimatedLots * _msPerLotSq / 1000;

  @override
  void initState() {
    super.initState();
    // The studio exists to profile, so terrain's own phase timers are on.
    TerrainNodes.profile = true;
    _ticker = createTicker(_onFrame)..start();
    // The engine's own frame report, per frame. No setState: the values are
    // read whenever the panel next paints, and the scene repaints every tick.
    _timingsCb = (timings) {
      for (final t in timings) {
        _uiMs.add(t.buildDuration.inMicroseconds / 1000);
        _rasterMs.add(t.rasterDuration.inMicroseconds / 1000);
      }
      while (_uiMs.length > 90) {
        _uiMs.removeAt(0);
      }
      while (_rasterMs.length > 90) {
        _rasterMs.removeAt(0);
      }
    };
    SchedulerBinding.instance.addTimingsCallback(_timingsCb!);
    CityStudioDevHooks.generate =
        ({int? blocks, double? voxelM, double? sprawlMiles}) async {
      if (_busy) return;
      if (blocks != null || voxelM != null || sprawlMiles != null) {
        setState(() {
          if (blocks != null) _blocks = blocks.toDouble();
          if (voxelM != null) _cityVoxelM = voxelM;
          if (sprawlMiles != null) _sprawlMiles = sprawlMiles;
        });
      }
      await _generate();
    };
    CityStudioDevHooks.setIsolate = ({bool? shadows, bool? atmosphere}) {
      if (!mounted) return;
      setState(() {
        if (shadows != null) _shadows = shadows;
        if (atmosphere != null) AtmosphereNodes.hidden = !atmosphere;
      });
    };
    CityStudioDevHooks.setPanels = ({bool? perf, bool? controls}) {
      if (!mounted) return;
      setState(() {
        if (perf != null) _perfCollapsed = !perf;
        if (controls != null) _panel = controls;
      });
    };
    CityStudioDevHooks.setCamera =
        ({double? distanceM, double? azimuth, double? elevation}) {
      if (!mounted) return;
      setState(() {
        if (distanceM != null) _distanceM = distanceM.clamp(40.0, 60000.0);
        if (azimuth != null) _azimuth = azimuth;
        if (elevation != null) _elevation = elevation.clamp(0.02, 1.55);
      });
    };
    CityStudioDevHooks.walkTo = (
        {required double e,
        required double n,
        required double yaw,
        required double pitch,
        double? eyeM}) {
      if (!mounted) return;
      final spot = _walkerFrameOf(e, n, yaw);
      if (spot == null) return;
      setState(() {
        if (_driving) _toggleDriving();
        _firstPerson = true;
        _walkE = spot.e;
        _walkN = spot.n;
        _walkYaw = spot.yaw;
        _walkPitch = pitch.clamp(-1.45, 1.45);
        _eyeHeightM = eyeM ?? 1.7;
      });
    };
    CityStudioDevHooks.drive = (
        {required double e,
        required double n,
        required double yaw,
        double throttle = 0,
        double steer = 0,
        double seconds = 0}) {
      if (!mounted) return;
      final spot = _walkerFrameOf(e, n, yaw);
      if (spot == null) return;
      setState(() {
        // Park any buggy already out, stand the walker on the spot, and let
        // the ordinary toggle put the buggy where the walker stands.
        if (_driving) _toggleDriving();
        _firstPerson = true;
        _walkE = spot.e;
        _walkN = spot.n;
        _walkYaw = spot.yaw;
        _walkPitch = 0;
        _toggleDriving();
        _autoInput = RoverInput(throttle: throttle, steer: steer);
        _autoUntilS = _epoch.value + seconds;
      });
    };
    CityStudioDevHooks.pick = (fx, fy) {
      if (!mounted) return null;
      _pickAt(Offset(fx * _viewportW, fy * _viewportH));
      return _picked?.spec.label;
    };
    CityStudioDevHooks.status = () => {
          'busy': _busy,
          'installations': _installationsStatus(),
          'interchanges': [
            for (final x in _sim?.sprawlSpec?.interchanges ?? const <List<double>>[])
              if (x.length >= 2) {'e': x[0], 'n': x[1]},
          ],
          'sprawlSections': _sim?.sprawl?.sections.length ?? 0,
          'cityDebug': CityNodes.debugLine,
          'frameMs': _avgOf(_frameMs),
          'uiMs': _avgOf(_uiMs),
          'rasterMs': _avgOf(_rasterMs),
          'terrainMs': _terrainMs,
          'cityMs': _cityMs,
          'censusDraws': _censusDraws,
          'censusInstances': _censusInstances,
          'censusNodes': _censusNodes,
          'engine': {
            'colourDraws': fs.Scene.lastFrameStats.colourDraws,
            'shadowDraws': fs.Scene.lastFrameStats.shadowDraws,
            'materialBinds': fs.Scene.lastFrameStats.materialBinds,
            'packedInstances': fs.Scene.lastFrameStats.packedInstances,
            'instancesEmplaced': fs.Scene.lastFrameStats.instancesEmplaced,
            'bvhRebuilds': fs.Scene.lastFrameStats.bvhRebuilds,
            'prePassMs': fs.Scene.lastFrameStats.prePassMs,
            'bvhMs': fs.Scene.lastFrameStats.bvhMs,
            'shadowMs': fs.Scene.lastFrameStats.shadowMs,
            'colourMs': fs.Scene.lastFrameStats.colourMs,
          },
          'shadows': _shadows,
          'rover': _roverStatus(),
          'stats': _lastStats,
          'fault': _fault == null
              ? null
              : '${_fault!.phase}: ${_fault!.error}',
        };
  }

  @override
  void dispose() {
    CityStudioDevHooks.generate = null;
    CityStudioDevHooks.setIsolate = null;
    CityStudioDevHooks.setPanels = null;
    CityStudioDevHooks.setCamera = null;
    CityStudioDevHooks.pick = null;
    CityStudioDevHooks.walkTo = null;
    CityStudioDevHooks.drive = null;
    CityStudioDevHooks.status = null;
    final cb = _timingsCb;
    if (cb != null) SchedulerBinding.instance.removeTimingsCallback(cb);
    _ticker?.dispose();
    _epoch.dispose();
    _perfTick.dispose();
    super.dispose();
  }

  static double _avgOf(List<double> xs) =>
      xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;

  /// Count what the engine will actually submit: one draw per mesh
  /// primitive, one per instanced mesh (however many instances ride it).
  void _censusWalk(fs.Node n) {
    _censusNodes++;
    for (final c in n.getComponents<fs.MeshComponent>()) {
      _censusDraws += c.mesh.primitives.length;
    }
    for (final c in n.getComponents<fs.InstancedMeshComponent>()) {
      _censusDraws += 1;
      _censusInstances += c.instancedMesh.instanceCount;
    }
    for (final child in n.children) {
      _censusWalk(child);
    }
  }

  void _onFrame(Duration elapsed) {
    // Nothing generated yet, or nothing that moves: a colony with traffic off
    // is a static frame, and repainting it sixty times a second only makes the
    // profiler harder to read.
    if (_scene == null || _sim == null) return;
    if (_lastTick != Duration.zero) {
      final dt = (elapsed - _lastTick).inMicroseconds / 1000.0;
      if (dt > 0 && dt < 500) {
        _frameMs.add(dt);
        if (_frameMs.length > 90) _frameMs.removeAt(0);
      }
      // Clamped: a dropped frame or a rebuild pause must not teleport the
      // walker across the colony.
      _stepWalker((dt / 1000.0).clamp(0.0, 0.1));
      _lastGroundMs = _groundMs;
      _lastGroundSamples = _groundSamples;
      _groundMs = 0;
      _groundSamples = 0;
      _stepRover((dt / 1000.0).clamp(0.0, 0.1));
    }
    _lastTick = elapsed;
    // Traffic off means a static frame, but the clock still ticks so the
    // counter keeps reading — a frozen number is worse than a slow one.
    _epoch.value = elapsed.inMicroseconds / 1e6;
    // The perf panel, at a quarter of the frame rate: it reads whatever the
    // timers hold when it next paints, so a slower clock loses nothing but
    // the relayout of fifty rows of text per frame.
    if (++_perfCountdown >= _perfTickEvery) {
      _perfCountdown = 0;
      _perfTick.value++;
    }
    // The scene-wide draw census, twice a second — a few hundred nodes, so
    // the walk itself never shows up in the frame it measures.
    if (++_censusCountdown >= 30) {
      _censusCountdown = 0;
      _censusDraws = 0;
      _censusInstances = 0;
      _censusNodes = 0;
      final scene = _scene;
      if (scene != null) _censusWalk(scene.root);
    }
  }

  /// Build the colony and its frame.
  Future<void> _generate() async {
    setState(() => _busy = true);
    // Let the button paint its spinner: generation is synchronous and can run
    // to seconds, and without the yield the app simply stops responding.
    await Future<void>.delayed(const Duration(milliseconds: 16));

    final sw = Stopwatch()..start();
    _genClock
      ..reset()
      ..start();
    final system = RealSolarSystem.build();
    final bodies = system.all.where((b) => !b.isStar).toList();

    // Step the build rather than blocking on it, yielding to the event loop
    // between chunks so the bar and the label actually paint. Every 6 steps:
    // often enough that the longest gap is a fraction of a second, rare enough
    // that the yields themselves are not the cost — a plat step is a whole
    // road's worth of lots, so this is a repaint every few dozen parcels.
    // The bar covers the WHOLE operation, not just the generator.
    //
    // Laying the colony out is the smaller half. Measured on a four-block
    // city: 2.6 s to build it, 0.1 s to cut the ground under it, and 17 s to
    // capture the frame — because capturing drapes every road and lot onto
    // ground that now carries 1,768 brushes, and each of those queries marches
    // radially through all of them. Showing a bar that finished at 13% and
    // then froze for seventeen seconds would be worse than showing none.
    const buildShare = 0.13;
    final build = CityBuild(_spec, bodies: bodies);
    _previewAnchored = false;
    var step = 0;
    var lastPhase = '';
    // Slow-mode cadence: how many zoning steps between frame recaptures, set
    // from the lot count at the first one so any city gets ~90 visible
    // updates. A capture rebuilds the whole city frame, so per-lot would be
    // quadratic in buildings and a four-block colony would take minutes.
    var zoned = 0;
    var previewEvery = 1;
    // What the build is actually doing. The console names each phase as it
    // starts and every step over a quarter second as it ends; the summary at
    // the end (also in the perf panel) is what to read when "it hung at
    // 12%": the bar scales the generator's 0..1 by buildShare, so the whole
    // zoning band is one percent wide on screen and looks like a stall.
    final phaseMs = <String, int>{};
    final phaseSteps = <String, int>{};
    final phaseMaxMs = <String, int>{};
    var frames = 0;
    var prevPhase = 'start';
    final stepSw = Stopwatch()..start();
    final sinceYield = Stopwatch()..start();
    for (final p in build.run()) {
      if (!mounted) return;
      // The time since the last item is the PREVIOUS item's phase at work.
      final ms = stepSw.elapsedMilliseconds;
      stepSw.reset();
      phaseMs[prevPhase] = (phaseMs[prevPhase] ?? 0) + ms;
      phaseSteps[prevPhase] = (phaseSteps[prevPhase] ?? 0) + 1;
      if (ms > (phaseMaxMs[prevPhase] ?? 0)) phaseMaxMs[prevPhase] = ms;
      if (ms > 250) {
        debugPrint('city build: "$prevPhase" step took ${ms}ms');
      }
      final phaseChanged = p.phase != lastPhase;
      if (phaseChanged) {
        debugPrint('city build → ${p.phase}  '
            '(generator ${(p.fraction * 100).toStringAsFixed(1)}%, '
            'bar ${(p.fraction * buildShare * 100).round()}%)');
      }
      lastPhase = p.phase;
      prevPhase = p.phase;
      step++;
      // Yield to the event loop by TIME, not by step count. Every sixth
      // step painted a full frame — scene and all — per six lots, and the
      // zoning phase yields once per lot: a 127,000-lot colony was 21,000
      // frames, minutes of vsync waits at idle CPU, read as a hang.
      if (phaseChanged ||
          sinceYield.elapsedMilliseconds >= 40 ||
          p.fraction >= 1.0) {
        setState(() => _progress =
            (phase: p.phase, fraction: p.fraction * buildShare));
        await Future<void>.delayed(Duration.zero);
        sinceYield.reset();
        stepSw.reset(); // the frame is not the phase's doing
        frames++;
      }
      if (_slowBuild && p.phase == 'zoning and building') {
        final live = build.partial!;
        if (zoned == 0) {
          previewEvery =
              math.max(1, (live.layout.autoParcels.length / 90).round());
        }
        if (zoned++ % previewEvery == 0) {
          _previewBuild(live, system);
          await Future<void>.delayed(const Duration(milliseconds: 33));
        }
      }
    }
    final sim = build.city!;
    final byCost = phaseMs.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    _buildLog = [
      'generator ${sw.elapsedMilliseconds}ms, $step steps, $frames frames',
      for (final e in byCost)
        '${e.key}: ${e.value}ms / ${phaseSteps[e.key]} steps, '
            'max ${phaseMaxMs[e.key]}ms',
    ];
    debugPrint('city build summary:\n  ${_buildLog.join('\n  ')}');

    if (_view2D) {
      // The plat is on screen now. The ground cut and the frame drape wait
      // until the view goes 3D (see [_toggleView2D]).
      if (!mounted) return;
      sw.stop();
      _genClock.stop();
      setState(() {
        _progress = null;
        _fault = null;
        _sim = sim;
        _busy = false;
        _pendingFrame = (sim: sim, system: system, sw: sw);
        _platCam.fit(math.max(2000.0, _spec.extentM * 1.6));
        _lastStats = '${sim.cityLat.toStringAsFixed(1)}°, '
            '${sim.cityLon.toStringAsFixed(1)}° · '
            '${sw.elapsedMilliseconds} ms · '
            '${sim.layout.roads.length} roads · '
            '${sim.layout.parcels.length} lots · '
            '${sim.parcelBuildings.length} buildings · '
            'frame not draped yet (switch to 3D)';
      });
      return;
    }
    await _finishFrame(sim, system, sw);
  }

  /// Switch between the plat and the scene. Going 3D with a build that
  /// stopped after the generator finishes it now: the ground cut and the
  /// frame drape it skipped.
  Future<void> _toggleView2D() async {
    setState(() => _view2D = !_view2D);
    final pending = _pendingFrame;
    if (_view2D || pending == null || _busy) return;
    _pendingFrame = null;
    setState(() => _busy = true);
    await Future<void>.delayed(const Duration(milliseconds: 16));
    if (!mounted) return;
    await _finishFrame(pending.sim, pending.system, pending.sw);
  }

  /// The second half of a build: the ground cut into, the frame captured
  /// (draped onto that ground), the camera anchored on the colony.
  Future<void> _finishFrame(
      CitySim sim, StarSystem system, Stopwatch sw) async {
    const buildShare = 0.13;
    setState(() =>
        _progress = (phase: 'cutting the ground', fraction: buildShare));
    await Future<void>.delayed(Duration.zero);

    // Shape the ground under it, exactly as the tick would.
    final groundSw = Stopwatch()..start();
    final edits = InMemoryTerrainEditsRepository();
    final body = system.body(sim.body.id)!;
    for (final p in CityTerrainShaper(voxelM: _cityVoxelM).pending(
      sim,
      bodyRadiusM: body.radius,
      groundRadiusAt: (d) {
        final f = body.terrainFieldWith(edits.forBody(body.id));
        return f == null ? body.radius : f.groundRadiusAt(d.x, d.y, d.z);
      },
    )) {
      edits.record(body.id, p.brush);
      sim.shapedTerrain.add(p.key);
    }
    _buildLog.add('cutting the ground: ${groundSw.elapsedMilliseconds}ms, '
        '${edits.forBody(body.id)?.length ?? 0} brushes');
    debugPrint('city build: ${_buildLog.last}');

    // The long one, and it cannot report from inside: `capture` is a core
    // function used on every tick by everything, and threading a progress
    // channel through it to serve one screen would be the tail wagging the
    // dog. Naming it is what the panel can honestly do.
    setState(() => _progress =
        (phase: 'draping roads and lots on the ground', fraction: 0.16));
    await Future<void>.delayed(Duration.zero);

    // Keep the sampler the colony was cut into, so a walker stands on the
    // graded ground — pads, road corridors, mined holes and all — rather than
    // on the datum sphere under it.
    _groundField = body.terrainFieldWith(edits.forBody(body.id));

    final captureSw = Stopwatch()..start();
    final snap = WorldSnapshot.capture(
      1,
      InMemoryVesselRepository(const []),
      system: system,
      cities: InMemoryCityRepository([sim]),
      terrainEdits: edits,
    );
    _buildLog.add('draping the frame: ${captureSw.elapsedMilliseconds}ms, '
        '${snap.buildings.length} buildings, ${snap.roads.length} roads');
    debugPrint('city build: ${_buildLog.last}');
    sw.stop();
    _genClock.stop();

    // Calibrate: what this build ACTUALLY cost, per lot squared. Not from a
    // slow-mode run — those are paced on purpose, and a calibration taken
    // from one would promise minutes for a build that takes seconds.
    // Nor from a build that waited in the plat view: its clock stopped.
    final lots = sim.layout.parcels.length.toDouble();
    if (lots > 20 && !_slowBuild && sw.isRunning) {
      _msPerLotSq = sw.elapsedMilliseconds / (lots * lots);
    }

    // Anchor the render origin on where the colony ACTUALLY IS — the mean of
    // its own building positions in the frame, which is exactly how CityNodes
    // anchors its batches.
    //
    // Deriving it from the colony's lat/lon at the DATUM radius put the camera
    // kilometres off: the ground sits hundreds of metres to kilometres away
    // from the datum sphere, and the buildings stand on the ground. The city
    // was rendering fine — just nowhere near where the camera was looking.
    final b = snap.bodies[body.id.value]!;
    var sum = Vector3.zero;
    var count = 0;
    for (final bs in snap.buildings.values) {
      if (bs.body != body.id.value) continue;
      sum = sum + Vector3(bs.px, bs.py, bs.pz);
      count++;
    }
    for (final p in snap.patches) {
      if (p.body != body.id.value) continue;
      sum = sum + Vector3(p.px, p.py, p.pz);
      count++;
    }
    final anchorBF = count == 0
        ? sim.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: body.radius)
        : sum * (1.0 / count);
    final bodyCentre = Vector3(b.px, b.py, b.pz);
    _bodyCentreWorld = bodyCentre;
    _anchorWorld =
        bodyCentre + Quaternion(b.qw, b.qx, b.qy, b.qz).rotate(anchorBF);
    _origin.focusWorld = _anchorWorld;
    final radial = _anchorWorld - bodyCentre;
    _upWorld = radial.length > 1 ? radial.normalized : Vector3.unitZ;

    if (!mounted) return;
    setState(() {
      _progress = null;
      _fault = null;
      _sim = sim;
      _snap = snap;
      _sunTurnH = _middayTurnH(snap, sim);
      _busy = false;
      _distanceM = math.max(600, _spec.extentM * 1.5);
      _lastStats = '${sim.cityLat.toStringAsFixed(1)}°, '
          '${sim.cityLon.toStringAsFixed(1)}° · '
          '${sw.elapsedMilliseconds} ms · '
          '${sim.layout.roads.length} roads · '
          '${sim.layout.parcels.length} lots · '
          '${sim.parcelBuildings.length} buildings · '
          '${sim.jobs} jobs · ${sim.housing} hab';
    });
  }

  /// Point the scene at the half-built colony and hand it a fresh frame.
  ///
  /// Slow mode only, called between zoning steps. The capture is the cheap
  /// kind — no terrain edits yet, so the drape samples the raw field — and
  /// the anchor comes from the ground over the city's CENTRE rather than the
  /// mean of its buildings: the mean walks as buildings arrive, and a camera
  /// that re-aims every chunk reads as a broken gimbal, not a growing city.
  /// The finished build recomputes the real anchor over this one.
  void _previewBuild(CitySim sim, StarSystem system) {
    final body = system.body(sim.body.id)!;
    final snap = WorldSnapshot.capture(
      1,
      InMemoryVesselRepository(const []),
      system: system,
      cities: InMemoryCityRepository([sim]),
    );
    if (!_previewAnchored) {
      _previewAnchored = true;
      final b = snap.bodies[body.id.value]!;
      final centreBF =
          sim.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: body.radius);
      final dir = centreBF.normalized;
      final field = body.terrainField;
      final anchorBF = dir *
          (field == null
              ? body.radius
              : field.groundRadiusAt(dir.x, dir.y, dir.z));
      final bodyCentre = Vector3(b.px, b.py, b.pz);
      _bodyCentreWorld = bodyCentre;
      _anchorWorld =
          bodyCentre + Quaternion(b.qw, b.qx, b.qy, b.qz).rotate(anchorBF);
      _origin.focusWorld = _anchorWorld;
      final radial = _anchorWorld - bodyCentre;
      _upWorld = radial.length > 1 ? radial.normalized : Vector3.unitZ;
      _groundField = field;
      _distanceM = math.max(600, _spec.extentM * 1.5);
    }
    setState(() {
      _sim = sim;
      _snap = snap;
    });
  }

  // ---- Sun and sky -------------------------------------------------------

  /// The frame's star body id, from its descriptor. Null before the first
  /// generate or on a frame without descriptors.
  String? _starId(WorldSnapshot frame) {
    for (final e in frame.descriptors.entries) {
      if (e.value.kind == BodyKind.star) return e.key;
    }
    return null;
  }

  Vector3? _starWorld(WorldSnapshot frame) {
    final star = frame.bodies[_starId(frame)];
    return star == null ? null : Vector3(star.px, star.py, star.pz);
  }

  /// The frame with its star swung [_sunTurnH] hours about the body's spin
  /// axis. Moving the star IN the frame — rather than overriding a light
  /// direction — is what keeps every consumer honest at once: the terrain
  /// shader, the atmosphere raymarch, and the city's window night-factor all
  /// derive their sun from the frame's own star body.
  WorldSnapshot _withSunTurned(WorldSnapshot frame) {
    if (_sunTurnH.abs() < 1e-3) return frame;
    final body = frame.bodies[_sim?.body.id.value];
    final starId = _starId(frame);
    final star = starId == null ? null : frame.bodies[starId];
    if (body == null || star == null) return frame;

    final axis =
        Quaternion(body.qw, body.qx, body.qy, body.qz).rotate(Vector3.unitZ);
    final angle = 2 * math.pi * _sunTurnH / 24.0;
    final centre = Vector3(body.px, body.py, body.pz);
    final turned = Quaternion.axisAngle(axis, angle)
            .rotate(Vector3(star.px, star.py, star.pz) - centre) +
        centre;

    final bodies = Map<String, BodySnapshot>.of(frame.bodies);
    bodies[starId!] = BodySnapshot(
      id: star.id,
      px: turned.x,
      py: turned.y,
      pz: turned.z,
      qw: star.qw,
      qx: star.qx,
      qy: star.qy,
      qz: star.qz,
      radius: star.radius,
      orbit: star.orbit,
    );
    return WorldSnapshot(
      tick: frame.tick,
      vessels: frame.vessels,
      epoch: frame.epoch,
      bodies: bodies,
      buildings: frame.buildings,
      roads: frame.roads,
      patches: frame.patches,
      descriptors: frame.descriptors,
      events: frame.events,
      terrainEdits: frame.terrainEdits,
      megastructures: frame.megastructures,
    );
  }

  /// Intensity tuned against the tonemapper — the flight scene's number, for
  /// the flight scene's reason (see SceneSync._sunIntensity).
  static const double _sunIntensity = 2.2;

  /// The directional sun, plus shadows when the camera is low enough for
  /// there to be ground in frame to receive them. A trimmed copy of
  /// SceneSync's sun: aimed from the frame's star through the colony, light
  /// travelling AWAY from the star.
  ///
  /// The night skyglow does NOT live here any more. A directional light is
  /// one direction and one strength for the whole scene, and a camera-height
  /// fade was tried and was wrong the other way round — the glow belongs to
  /// each SURFACE's height, pavement bright and parapet dark, and that is
  /// per-fragment work. The city's custom surface shader carries it now
  /// (CityGlow in city_surface.frag); this light is just the sun again.
  void _syncSun(fs.Scene scene, WorldSnapshot frame, Vector3? starWorld) {
    vm.Vector3 dir;
    if (starWorld == null) {
      dir = vm.Vector3(-1.0, -0.2, -0.1);
    } else {
      final rel = _origin.worldToRel(starWorld);
      final len = rel.length;
      dir = len < 1.0
          ? vm.Vector3(-1.0, -0.2, -0.1)
          : vm.Vector3(-rel.x / len, -rel.y / len, -rel.z / len);
    }
    final night = CityMaterials.nightFactor.clamp(0.0, 1.0);
    var light = scene.directionalLight;
    if (light == null) {
      light = fs.DirectionalLight(direction: dir, intensity: _sunIntensity);
      scene.directionalLight = light;
    } else {
      light.direction = dir;
      light.intensity = _sunIntensity;
    }

    // Altitude above the COLONY's ground shell, not the datum — the anchor
    // stands on the real ground, which can sit hundreds of metres off datum.
    final eyeWorld = _anchorWorld + _cameraEyeM();
    final groundR = (_anchorWorld - _bodyCentreWorld).length;
    final altM =
        groundR < 1 ? 0.0 : (eyeWorld - _bodyCentreWorld).length - groundR;
    // Deep night: the glow comes from everywhere, so a sharp shadow from one
    // direction would be the tell that it is fake. Drop the pass.
    if (!_shadows || groundR < 1 || altM > 8000 || night > 0.6) {
      light.castsShadow = false;
      return;
    }
    // The flight scene's landing-shadow tuning (see SceneSync._tuneShadows
    // for each number's story) — with one studio divergence below.
    light.castsShadow = true;
    light.shadowCasterFaces = fs.ShadowCasterFaces.back;
    // ONE cascade, not the engine's four. Every cascade re-draws every
    // caster into its 2048^2 tile, and that encode lands on the UI thread
    // (the engine records the shadow pass inside the painter, so it shows
    // in "ui build", not the phase timers): measured on an 8-block colony,
    // two cascades cost 2.7-3.8 ms of a 10-13 ms UI frame. The studio
    // frames ONE colony at short range, which a single cascade covers —
    // softer at the far edge of the range than two would be, and that is
    // the trade.
    light.shadowCascadeCount = 1;
    // How far the cascade reaches from the EYE. On foot or driving the eye
    // is on the ground and the altitude formula sizes the box to what a
    // head can see. In the orbit view the eye is the distance out, looking
    // AT the focus: sizing by altitude there made a 4.7 km light box at the
    // default 1320 m orbit, centred on the colony's anchor, and the shadow
    // pass encoded every near tile in it — the ones behind the camera
    // included. Sized to the focus instead: reach the colony and a little
    // past it, and nothing further. Quantised to 100 m so the cascade
    // sphere does not resize (and the shadow texels swim) with every
    // wheel notch and drag frame.
    final double rangeM;
    if (_groundView) {
      rangeM = (altM * 3.0 + 300.0).clamp(300.0, 6000.0);
    } else {
      final toFocus = (1.25 * _distanceM).clamp(400.0, 2400.0);
      rangeM = (toFocus / 100.0).round() * 100.0;
    }
    light.shadowMaxDistance = lengthToScene(rangeM);
    light.shadowFadeRange = lengthToScene(rangeM * 0.12);
    light.shadowMapResolution = 2048;
    light.shadowSoftness = lengthToScene(1.5);
    // The lander tuning's metre of bias (back-face casting hides the offset
    // inside a solid craft) means nothing under a metre tall can shadow the
    // ground — a buggy then reads as floating, whatever its wheels touch.
    // Driving, the biases come down to what a 1.6 m vehicle needs.
    light.shadowNormalBias = lengthToScene(_driving ? 0.15 : 1.0);
    light.shadowDepthBias = lengthToScene(_driving ? 0.15 : 1.0);
  }

  /// Hours that put the sun at local NOON over the colony: the turn that
  /// swings the star's around-the-axis component onto the site's. Every
  /// generate lands at whatever time of day the epoch dictates — night, half
  /// the time — and a studio that opens on a black screen reads as broken,
  /// not as accurate.
  double _middayTurnH(WorldSnapshot snap, CitySim sim) {
    final body = snap.bodies[sim.body.id.value];
    final star = snap.bodies[_starId(snap)];
    if (body == null || star == null) return 0;
    final axis =
        Quaternion(body.qw, body.qx, body.qy, body.qz).rotate(Vector3.unitZ);
    final centre = Vector3(body.px, body.py, body.pz);
    final s = Vector3(star.px, star.py, star.pz) - centre;
    final sPerp = s - axis * s.dot(axis);
    final uPerp = _upWorld - axis * _upWorld.dot(axis);
    if (sPerp.length < 1e-6 || uPerp.length < 1e-6) return 0;
    final a = sPerp.normalized, b = uPerp.normalized;
    final theta = math.atan2(axis.dot(a.cross(b)), a.dot(b));
    return theta * 24.0 / (2 * math.pi);
  }

  /// A tangent basis at the colony: east and north on its own ground plane.
  (Vector3 east, Vector3 north) _tangentFrame() {
    final seed =
        _upWorld.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
    final east = _upWorld.cross(seed).normalized;
    return (east, _upWorld.cross(east));
  }

  /// The camera eye in FOCUS-RELATIVE metres, which is what the terrain
  /// streamer measures its LOD budget against.
  ///
  /// Built in the colony's OWN frame: elevation is the angle above its ground,
  /// azimuth a turn about its local up.
  Vector3 _cameraEyeM() {
    if (_driving) return _chaseEyeM();
    if (_firstPerson) return _walkerEyeM();
    final (east, north) = _tangentFrame();
    final ce = math.cos(_elevation), se = math.sin(_elevation);
    final dir = east * (math.cos(_azimuth) * ce) +
        north * (math.sin(_azimuth) * ce) +
        _upWorld * se;
    return dir * _distanceM;
  }

  /// The walker's eye, anchor-relative metres.
  ///
  /// Placed RADIALLY off the real ground rather than on the anchor's tangent
  /// plane: a colony is a patch of a sphere, and a walker who kept the
  /// anchor's height would sink into the ground crossing it and float at the
  /// far side. Sampling the terrain field is also what makes a mined hole
  /// something you can walk into.
  Vector3 _walkerEyeM() {
    final (east, north) = _tangentFrame();
    final flat = _anchorWorld + east * _walkE + north * _walkN;
    final radial = flat - _bodyCentreWorld;
    if (radial.length < 1) return _upWorld * _eyeHeightM;
    final dir = radial.normalized;
    final field = _groundField;
    // The field samples in the BODY-FIXED frame and `dir` is a world
    // direction. The snapshot's body orientation carries Earth's axial tilt,
    // so sampling with the world direction read the ground of a point over
    // twenty degrees away — the walker stood in the right place on the wrong
    // location's altitude, tens of metres under (or above) the terrain that
    // was actually drawn. The same trap the flight walker hit.
    final b = _snap?.bodies[_sim?.body.id.value];
    var ground = radial.length;
    if (field != null && b != null) {
      final bf = Quaternion(b.qw, b.qx, b.qy, b.qz).conjugate.rotate(dir);
      ground = field.groundRadiusAt(bf.x, bf.y, bf.z);
    }
    return _bodyCentreWorld + dir * (ground + _eyeHeightM) - _anchorWorld;
  }

  /// Where the walker is looking, as a unit vector in world axes.
  Vector3 _walkerLook() {
    final (east, north) = _tangentFrame();
    // Up at the WALKER, not at the anchor — same reason the eye is radial.
    final radial = (_anchorWorld + east * _walkE + north * _walkN) -
        _bodyCentreWorld;
    final up = radial.length < 1 ? _upWorld : radial.normalized;
    final fwd = (north * math.cos(_walkYaw) + east * math.sin(_walkYaw));
    final flat = (fwd - up * fwd.dot(up));
    final ahead = flat.length < 1e-9 ? north : flat.normalized;
    final cp = math.cos(_walkPitch), sp = math.sin(_walkPitch);
    return (ahead * cp + up * sp).normalized;
  }

  /// Advance the walker for [dtS] seconds from whatever is held down.
  void _stepWalker(double dtS) {
    if (!_firstPerson || _held.isEmpty) return;
    var fwd = 0.0, side = 0.0;
    if (_held.contains(LogicalKeyboardKey.keyW)) fwd += 1;
    if (_held.contains(LogicalKeyboardKey.keyS)) fwd -= 1;
    if (_held.contains(LogicalKeyboardKey.keyD)) side += 1;
    if (_held.contains(LogicalKeyboardKey.keyA)) side -= 1;
    if (fwd == 0 && side == 0) return;
    final speed = _held.contains(LogicalKeyboardKey.shiftLeft) ||
            _held.contains(LogicalKeyboardKey.shiftRight)
        ? _runSpeedMs
        : _walkSpeedMs;
    final len = math.sqrt(fwd * fwd + side * side);
    final step = speed * dtS / len;
    // Heading in the tangent plane: yaw 0 faces north.
    final cy = math.cos(_walkYaw), sy = math.sin(_walkYaw);
    _walkN += (fwd * cy - side * sy) * step;
    _walkE += (fwd * sy + side * cy) * step;
  }

  /// The hooks speak the sim's colony-local frame; the walker lives in the
  /// studio's world tangent frame at the anchor, which is turned from it by
  /// the body's spin and tilt. Convert through body-fixed.
  ({double e, double n, double yaw})? _walkerFrameOf(
      double e, double n, double yaw) {
    final sim = _sim;
    final snap = _snap;
    if (sim == null || snap == null) return null;
    final b = snap.bodies[sim.body.id.value];
    if (b == null) return null;
    final bodyWorld = Vector3(b.px, b.py, b.pz);
    final quat = Quaternion(b.qw, b.qx, b.qy, b.qz);
    final (east, north) = _tangentFrame();
    Vector3 worldOf(double le, double ln) =>
        bodyWorld +
        quat.rotate(sim.localToBodyFixed(Vec2(le, ln),
            bodyRadiusM: sim.body.radius));
    final at = worldOf(e, n) - _anchorWorld;
    final ahead = worldOf(e + math.sin(yaw) * 100, n + math.cos(yaw) * 100) -
        _anchorWorld;
    final look = ahead - at;
    return (
      e: at.dot(east),
      n: at.dot(north),
      yaw: math.atan2(look.dot(east), look.dot(north)),
    );
  }

  // ---- Rover ----------------------------------------------------------------

  /// A scripted drive (the dev hook): held in place of the keys until
  /// `_autoUntilS` on the studio clock.
  RoverInput? _autoInput;
  double _autoUntilS = -1;

  Map<String, Object?>? _roverStatus() {
    final r = _rover;
    if (!_driving || r == null) return null;
    // The ground under the centre read both ways — drawn mesh and analytic
    // field — so a headless run can see the gap the wheels would sit in.
    final (east, north) = _tangentFrame();
    final flat = _anchorWorld + east * r.e + north * r.n;
    final radial = flat - _bodyCentreWorld;
    double? meshR, fieldR;
    final b = _snap?.bodies[_sim?.body.id.value];
    final field = _groundField;
    final quat = b == null ? null : Quaternion(b.qw, b.qx, b.qy, b.qz);
    Vector3? bf;
    if (radial.length > 1 && quat != null && field != null) {
      bf = quat.conjugate.rotate(radial.normalized);
      meshR = _terrain?.drawnGroundRadiusAt(bf);
      fieldR = field.surfaceRadiusAt(bf.x, bf.y, bf.z);
    }
    final probe = <String, Object?>{};
    double? liftM;
    List<double>? wheelLifts;
    if (bf != null && fieldR != null && quat != null) {
      final fr = fieldR;
      liftM = _citySurface(_bfToLocal(bf * fr), debug: probe).liftM;
      // Each wheel's own surface, the way _groundRadiusAtEN sees it.
      const spec = RoverSpec();
      final sy = math.sin(r.yaw), cy = math.cos(r.yaw);
      wheelLifts = [
        for (var i = 0; i < RoverSpec.wheelCount; i++)
          () {
            final (x, y) = spec.wheelOffset(i);
            final wf = _anchorWorld +
                east * (r.e + cy * x + sy * y) +
                north * (r.n - sy * x + cy * y);
            final wd = (wf - _bodyCentreWorld).normalized;
            final wbf = quat.conjugate.rotate(wd);
            return _citySurface(_bfToLocal(wbf * fr)).liftM;
          }(),
      ];
    }
    return {
      'cityLiftM': liftM,
      'wheelLiftM': wheelLifts,
      'roadProbe': probe,
      'groundMeshM': meshR,
      'groundFieldM': fieldR,
      'meshMinusFieldM':
          meshR == null || fieldR == null ? null : meshR - fieldR,
      'e': r.e,
      'n': r.n,
      'yaw': r.yaw,
      'speed': r.speed,
      'height': r.height,
      'pitch': r.pitch,
      'roll': r.roll,
      'wheelsDown': r.wheelsDown,
      'compression': r.compression,
      'dust': r.dust,
      'chaseDistM': _chaseDistM,
      'groundMs': _lastGroundMs,
      'groundSamples': _lastGroundSamples,
    };
  }

  double _lastGroundMs = 0;
  int _lastGroundSamples = 0;

  /// R: into and out of the dune buggy. It takes over where the walker
  /// stands (or the walker's entry spot, just outside the colony looking
  /// in) with its springs settled, and leaves the walker where it parked.
  void _toggleDriving() {
    _driving = !_driving;
    _held.clear();
    _chaseEyeCache = null;
    if (_driving) {
      if (!_firstPerson) {
        _walkE = 0;
        _walkN = -_spec.blockDepthM * 0.6;
        _walkYaw = 0;
        _walkPitch = 0;
      }
      _firstPerson = false;
      _rover = RoverState.resting(
        e: _walkE,
        n: _walkN,
        yaw: _walkYaw,
        groundHeight: _groundRadiusAtEN(_walkE, _walkN),
        gravity: _surfaceGravity(),
      );
      _chaseYaw = _walkYaw;
      _chaseOrbit = 0;
      _chasePitch = 0.30;
    } else {
      final r = _rover;
      if (r != null) {
        _walkE = r.e;
        _walkN = r.n;
        _walkYaw = r.yaw;
      }
      _rover = null;
    }
  }

  /// Ground RADIUS under a tangent-plane point — the buggy's height datum,
  /// sampled under every wheel. In the BODY-FIXED frame, like the walker's
  /// eye: the world direction reads the wrong location's altitude.
  double _groundRadiusAtEN(double e, double n) {
    final (east, north) = _tangentFrame();
    final flat = _anchorWorld + east * e + north * n;
    final radial = flat - _bodyCentreWorld;
    if (radial.length < 1) return (_anchorWorld - _bodyCentreWorld).length;
    final dir = radial.normalized;
    final field = _groundField;
    final b = _snap?.bodies[_sim?.body.id.value];
    if (field == null || b == null) return radial.length;
    final bf = Quaternion(b.qw, b.qx, b.qy, b.qz).conjugate.rotate(dir);
    final sw = Stopwatch()..start();
    // The ground AS DRAWN wherever a chunk is resident — the wheels sit on
    // the triangles on screen, not on a field the mesh only approximates —
    // else the field's FAST surface query (the full one marches every brush
    // on the ray at ~16 ms a sample in a graded town; five a frame was the
    // frame).
    var r = _terrain?.drawnGroundRadiusAt(bf) ??
        field.surfaceRadiusAt(bf.x, bf.y, bf.z);
    // Then whatever the city laid on top: a carriageway and its pavements
    // are built off the road's CENTRELINE ground, flat across, so on them
    // the wheel stands on that ground plus the lift — not on whatever the
    // terrain does under the kerb.
    final sim = _sim;
    if (sim != null) {
      final s = _citySurface(_bfToLocal(bf * r));
      if (s.liftM > 0) {
        final cbf = sim
            .localToBodyFixed(s.centre, bodyRadiusM: sim.body.radius)
            .normalized;
        final cr = _terrain?.drawnGroundRadiusAt(cbf) ??
            field.surfaceRadiusAt(cbf.x, cbf.y, cbf.z);
        r = cr + s.liftM;
      }
    }
    _groundMs += sw.elapsedMicroseconds / 1000;
    _groundSamples++;
    return r;
  }

  /// What the city laid over the ground under a colony-local point: a
  /// carriageway rides [RoadMesher.ribbonLiftM] over the drape, a raised
  /// pavement a curb higher, open ground nothing — the road mesher's own
  /// numbers — and the centreline point it was built from. [debug] carries
  /// the probe's reasoning for the dev status.
  ({double liftM, Vec2 centre}) _citySurface(Vec2 local,
      {Map<String, Object?>? debug}) {
    final sim = _sim;
    const none = (liftM: 0.0, centre: Vec2(0, 0));
    if (sim == null) return none;
    final hit = sim.layout.roadIndex.nearest(local, startM: 16, maxM: 64);
    debug?['roads'] = sim.layout.roads.length;
    debug?['local'] = [local.e, local.n];
    if (hit == null) {
      debug?['found'] = false;
      return none;
    }
    final road = hit.road.road;
    final cls = road.roadClass;
    // The class's curb-to-curb half width, overridden per road end and
    // tapered between them along the arc (a plat that widened a road).
    final base = road.halfWidth;
    final rec = hit.road;
    final t = rec.lengthM <= 0 || hit.seg <= 0
        ? 0.0
        : (rec.cum[hit.seg - 1] / rec.lengthM).clamp(0.0, 1.0);
    final h0 = road.startHalfWidthM ?? base;
    final h1 = road.endHalfWidthM ?? base;
    final half = h0 + (h1 - h0) * t;
    final walked = cls.paved && cls.hasPavement && !road.sealed;
    debug?['found'] = true;
    debug?['distance'] = hit.distance;
    debug?['half'] = half;
    debug?['cls'] = cls.name;
    debug?['walked'] = walked;
    // A tyre does not step up a kerb, it rolls up it: the contact climbs
    // over about sqrt(2·r·h) of travel, so a kerb is a short ramp rather
    // than a wall the springs slam into at speed. The tarmac's own 12 cm
    // is a render lift (the ribbon floats clear of the drape), not a real
    // edge, so off the carriageway it eases out over a shoulder's width.
    const kerbM = 0.35;
    const shoulderM = 1.5;
    double ramp(double from, double to, double x, double x0, double w) =>
        from + (to - from) * ((x - x0) / w).clamp(0.0, 1.0);
    final d = hit.distance;
    const ribbon = RoadMesher.ribbonLiftM;
    const walk = RoadMesher.walkTopLiftM;
    double lift;
    if (d <= half) {
      lift = ribbon;
    } else if (walked) {
      final outer = half + 3.0;
      if (d <= half + kerbM) {
        lift = ramp(ribbon, walk, d, half, kerbM);
      } else if (d <= outer) {
        lift = walk;
      } else {
        lift = ramp(walk, 0.0, d, outer, shoulderM);
      }
    } else {
      lift = ramp(ribbon, 0.0, d, half, shoulderM);
    }
    return lift <= 0 ? none : (liftM: lift, centre: hit.point);
  }

  /// What the buggy's ground sampling cost this frame (ms, count) — the
  /// perf hook reports it, because it is the one per-frame cost driving
  /// adds that scales with the town's brush count.
  double _groundMs = 0;
  int _groundSamples = 0;

  /// Surface gravity at the colony from the body's mu, m/s².
  double _surfaceGravity() {
    final sim = _sim;
    final r = (_anchorWorld - _bodyCentreWorld).length;
    if (sim == null || r < 1) return 9.81;
    return sim.body.mu / (r * r);
  }

  /// The buggy's mount-plane centre, anchor-relative metres: radially off
  /// the body through its tangent-plane spot, at its own height.
  Vector3 _roverPosRel(RoverState r) {
    final (east, north) = _tangentFrame();
    final flat = _anchorWorld + east * r.e + north * r.n;
    final radial = flat - _bodyCentreWorld;
    final dir = radial.length < 1 ? _upWorld : radial.normalized;
    return _bodyCentreWorld + dir * r.height - _anchorWorld;
  }

  /// The chase eye is asked for several times a frame (camera, lens, look,
  /// atmosphere) and each answer samples the ground once — in a town cut by
  /// a thousand grading brushes, THE expensive part. One computation per
  /// tick; a drag lands on the next tick.
  Vector3? _chaseEyeCache;
  double _chaseEyeEpoch = double.nan;

  Vector3 _chaseEyeM() {
    final cached = _chaseEyeCache;
    if (cached != null && _chaseEyeEpoch == _epoch.value) return cached;
    final eye = _computeChaseEyeM();
    _chaseEyeCache = eye;
    _chaseEyeEpoch = _epoch.value;
    return eye;
  }

  /// The chase eye, anchor-relative metres: behind the eased heading (plus
  /// the drag-around offset), up by the pitch, and never under the ground.
  Vector3 _computeChaseEyeM() {
    final r = _rover;
    if (r == null) return _walkerEyeM();
    final (east, north) = _tangentFrame();
    final pos = _roverPosRel(r);
    final radial = _anchorWorld + pos - _bodyCentreWorld;
    final up = radial.length < 1 ? _upWorld : radial.normalized;
    final yaw = _chaseYaw + _chaseOrbit;
    var heading = north * math.cos(yaw) + east * math.sin(yaw);
    heading = heading - up * heading.dot(up);
    heading = heading.length < 1e-9 ? north : heading.normalized;
    final cp = math.cos(_chasePitch), sp = math.sin(_chasePitch);
    var eye =
        pos - heading * (_chaseDistM * cp) + up * (_chaseDistM * sp + 1.0);
    final ground = _groundRadiusAtEN(eye.dot(east), eye.dot(north));
    final eyeRadial = _anchorWorld + eye - _bodyCentreWorld;
    if (eyeRadial.length < ground + 1.2) {
      eye = _bodyCentreWorld +
          eyeRadial.normalized * (ground + 1.2) -
          _anchorWorld;
    }
    return eye;
  }

  /// Where the chase camera looks: at the buggy, a little above its floor.
  Vector3 _roverLook() {
    final r = _rover;
    if (r == null) return _walkerLook();
    final pos = _roverPosRel(r);
    final radial = _anchorWorld + pos - _bodyCentreWorld;
    final up = radial.length < 1 ? _upWorld : radial.normalized;
    final look = (pos + up * 1.2) - _chaseEyeM();
    return look.length < 1e-9 ? up * -1 : look.normalized;
  }

  Vector3 _groundLook() => _driving ? _roverLook() : _walkerLook();

  /// Drive the buggy from whatever is held: W/S throttle, A/D steer, space
  /// brakes. Then ease the chase camera in behind the heading; a look
  /// around (drag) relaxes while the throttle is held, so it ends on its
  /// own.
  void _stepRover(double dtS) {
    final r = _rover;
    if (!_driving || r == null) return;
    var throttle = 0.0, steer = 0.0;
    if (_held.contains(LogicalKeyboardKey.keyW)) throttle += 1;
    if (_held.contains(LogicalKeyboardKey.keyS)) throttle -= 1;
    if (_held.contains(LogicalKeyboardKey.keyD)) steer += 1;
    if (_held.contains(LogicalKeyboardKey.keyA)) steer -= 1;
    final brake = _held.contains(LogicalKeyboardKey.space);
    var input = RoverInput(throttle: throttle, steer: steer, brake: brake);
    final auto = _autoInput;
    if (auto != null) {
      if (_epoch.value < _autoUntilS) {
        input = auto;
        throttle = auto.throttle;
      } else {
        _autoInput = null;
      }
    }
    stepRover(
      r,
      input,
      dt: dtS,
      gravity: _surfaceGravity(),
      heightAt: _groundRadiusAtEN,
    );
    final k = 1 - math.exp(-dtS / 0.35);
    _chaseYaw += wrapAngle(r.yaw - _chaseYaw) * k;
    if (throttle != 0) _chaseOrbit *= math.exp(-dtS / 1.5);
  }

  /// Place the buggy in the scene — heading, then pitch and roll — or take
  /// it out. The dust is tinted from the ground under it.
  void _syncRover(fs.Scene scene, WorldSnapshot frame, Quaternion bodyQuat) {
    var nodes = _roverNodes;
    if (nodes == null || nodes.scene != scene) {
      nodes = _roverNodes = RoverNodes(scene);
    }
    final r = _rover;
    final bodyId = _sim?.body.id.value;
    if (!_driving || r == null || bodyId == null) {
      nodes.hide();
      return;
    }
    final (east, north) = _tangentFrame();
    final pos = _roverPosRel(r);
    final radial = _anchorWorld + pos - _bodyCentreWorld;
    final up = radial.length < 1 ? _upWorld : radial.normalized;
    var f0 = north * math.cos(r.yaw) + east * math.sin(r.yaw);
    f0 = f0 - up * f0.dot(up);
    f0 = f0.length < 1e-9 ? north : f0.normalized;
    final r0 = f0.cross(up).normalized;
    // Pitch about the right axis (nose up = forward tilts toward up), then
    // roll about the new forward (right side down = right tilts away from
    // up) — the presenter's own sign conventions.
    final cp = math.cos(r.pitch), sp = math.sin(r.pitch);
    final f1 = f0 * cp + up * sp;
    final u1 = up * cp - f0 * sp;
    final cr = math.cos(r.roll), sr = math.sin(r.roll);
    final r2 = r0 * cr - u1 * sr;
    final u2 = u1 * cr + r0 * sr;
    var sand = 0.0;
    for (final d in frame.descriptors.values) {
      if (d.id == bodyId) sand = d.terrainSandAmount;
    }
    nodes.update(
      state: r,
      originRel: pos,
      right: r2,
      forward: f1,
      up: u2,
      timeS: _epoch.value,
      tint: RoverNodes.groundTint(
          bodyId: bodyId, dirBF: bodyQuat.conjugate.rotate(up), sand: sand),
      gravity: _surfaceGravity(),
    );
  }

  /// The driving hint bar, with the speedo.
  Widget _driveHint() {
    final r = _rover;
    final kmh = r == null ? 0 : (r.speed * 3.6).abs().round();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 16,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: AppTheme.panelBox(),
          child: Text(
              '$kmh km/h · W/S drive · A/D steer · space brake · '
              'drag to swing · wheel to zoom · R to fly',
              style: AppTheme.mono
                  .copyWith(fontSize: 11, color: AppTheme.textDim)),
        ),
      ),
    );
  }

  String? _bodyIdOfFrame(WorldSnapshot frame) =>
      frame.bodies.isEmpty ? null : _sim?.body.id.value;

  /// Plant the known-size reference in the middle of the colony.
  ///
  /// Rebuilt only when toggled — it never moves, so it is not per-frame work.
  void _syncRig(fs.Scene scene) {
    final want = _showRig && _sim != null;
    if (want == _rigNodes.isNotEmpty) return;
    for (final n in _rigNodes) {
      scene.remove(n);
    }
    _rigNodes.clear();
    if (!want) return;

    final solid = MeshBuilder();
    final glow = MeshBuilder();
    // At the render origin, which IS the colony's own centre here: the anchor
    // is the mean of every building and patch, so zero is the middle of town,
    // at ground level.
    final (_, north) = _tangentFrame();
    ScaleRig.emit(solid, glow, Vector3.zero, north, _upWorld);

    for (final (builder, material) in [
      (solid, CityMaterials.facade),
      (glow, CityMaterials.glazing),
    ]) {
      final mesh = builder.build();
      if (mesh.isEmpty) continue;
      final node = fs.Node(
        mesh: fs.Mesh.primitives(primitives: [
          fs.MeshPrimitive(CityNodes.geometryOf(mesh)!, material),
        ]),
      );
      scene.add(node);
      _rigNodes.add(node);
    }
  }

  fs.PerspectiveCamera _camera() {
    final eye = _cameraEyeM();
    if (_groundView) {
      final look = _groundLook();
      final p = vm.Vector3(eye.x, eye.y, eye.z) * kRenderScale;
      final radial = (_anchorWorld + eye) - _bodyCentreWorld;
      final up = radial.length < 1 ? _upWorld : radial.normalized;
      return fs.PerspectiveCamera(
        fovRadiansY: 0.9,
        position: p,
        target: p + vm.Vector3(look.x, look.y, look.z) * kRenderScale * 50,
        up: vm.Vector3(up.x, up.y, up.z),
        // Metres from the eye, not a fraction of an orbit range: on foot the
        // nearest thing is the pavement and the far plane still has to reach
        // the far side of the colony.
        // (The chase eye stands metres off the buggy, so it can afford the
        // depth precision a farther near plane buys.)
        fovNear: lengthToScene(_driving ? 0.3 : 0.15),
        // Far enough to rasterize the atmosphere's camera-enclosing inner
        // shell: a near-horizon sky ray crosses it around sqrt(2*R*lift) ~
        // 300 km out, and clipping there cut the haze off in a band above
        // the horizon. Costs no depth precision — D24 error grows with
        // distance-from-eye and the near plane, not with the far plane.
        fovFar: lengthToScene(400000),
      );
    }
    final target = vm.Vector3.zero();
    // Directions map to scene space by a pure scale, so a unit vector in world
    // metres is a unit vector here.
    return fs.PerspectiveCamera(
      fovRadiansY: 0.8,
      position: target +
          vm.Vector3(eye.x, eye.y, eye.z) * kRenderScale,
      target: target,
      // The colony's own up, NOT world +Z.
      up: vm.Vector3(_upWorld.x, _upWorld.y, _upWorld.z),
      fovNear: lengthToScene(math.max(_distanceM * 0.01, 1.0)),
      // The floor exists for the atmosphere's inner shell — see the walk
      // camera's far plane for the arithmetic.
      fovFar: lengthToScene(math.max(_distanceM * 20 + 20000, 400000)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppTheme.scaffold(
      context: context,
      title: 'CITY STUDIO',
      accentColor: AppTheme.accent2,
      actions: [
        IconButton(
          icon: Icon(_view2D ? Icons.view_in_ar : Icons.map,
              color: _view2D ? AppTheme.accent2 : AppTheme.text),
          tooltip: _view2D
              ? 'Back to the 3D scene  (M)'
                  '${_pendingFrame != null ? ' — drapes the frame first' : ''}'
              : 'The plat, flat  (M) — drag to pan, wheel to zoom. A build '
                  'made here skips the drape until you come back.',
          onPressed: _busy ? null : _toggleView2D,
        ),
        IconButton(
          icon: Icon(_firstPerson ? Icons.videocam : Icons.directions_walk,
              color: _firstPerson ? AppTheme.accent2 : AppTheme.text),
          tooltip: _firstPerson
              ? 'Back to the orbit camera  (G)'
              : 'Walk the streets  (G) — WASD, shift to run, drag to look',
          onPressed: _sim == null || _snap == null || _view2D
              ? null
              : () => setState(_toggleFirstPerson),
        ),
        IconButton(
          icon: Icon(_driving ? Icons.videocam : Icons.directions_car,
              color: _driving ? AppTheme.accent2 : AppTheme.text),
          tooltip: _driving
              ? 'Park the buggy, back to the orbit camera  (R)'
              : 'Drive the streets  (R) — W/S drive, A/D steer, space brakes',
          onPressed: _sim == null || _snap == null || _view2D
              ? null
              : () => setState(_toggleDriving),
        ),
        IconButton(
          icon: Icon(_panel ? Icons.chevron_right : Icons.tune,
              color: AppTheme.text),
          tooltip: _panel ? 'Hide controls' : 'Show controls',
          onPressed: () => setState(() => _panel = !_panel),
        ),
      ],
      body: Row(children: [
        Expanded(child: _preview()),
        if (_panel)
          SizedBox(width: 340, child: _controls()),
      ]),
    );
  }

  Widget _preview() {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          // A missing shader bundle is a build-step problem, not a hang. The
          // flight view tolerates it and draws no terrain; say so instead of
          // spinning forever.
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Scene resources failed to load:\n${snapshot.error}',
                  style: AppTheme.dim, textAlign: TextAlign.center),
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
              child: CircularProgressIndicator(color: AppTheme.accent2));
        }
        // Ambient IBL down to the flight scene's level: at the default 1.0
        // everything is washed in white and the directional sun cannot show
        // a lit side — the same lesson SceneSync already carries.
        final scene = _scene ??= (fs.Scene()..environmentIntensity = 0.05);
        _city ??= CityNodes(scene);
        _terrain ??= TerrainNodes(scene);
        _atmo ??= AtmosphereNodes(scene);

        return _sceneStack(scene);
      },
    );
  }

  /// The preview: the scene, and everything laid over it.
  ///
  /// Only the scene subtree listens to the epoch. The overlays used to sit
  /// inside the same builder, which meant the perf panel's fifty rows and
  /// the pick card were rebuilt and re-laid-out on every tick — the card
  /// even re-ran `citySiteStatus` per frame — on the UI thread the engine
  /// encodes the scene on. Now the panel rides [_perfTick] (~4 Hz) behind a
  /// repaint boundary, the card rebuilds only with the screen (a pick is a
  /// `setState`), and the static hints rebuild with the screen too. The
  /// one exception is the drive hint, a single line that IS a speedometer;
  /// it keeps its own listener on the epoch.
  Widget _sceneStack(fs.Scene scene) {
    return Stack(children: [
      Positioned.fill(
        child: ValueListenableBuilder<double>(
          valueListenable: _epoch,
          builder: (context, epoch, _) => _sceneSurface(scene, epoch),
        ),
      ),
      // The plat, on top of the scene's pointer surface: an opaque hit
      // target, so drags and the wheel are its pan and zoom, not the
      // orbit camera's underneath.
      if (_view2D)
        Positioned.fill(
          child: CityPlatView(
            sim: _sim,
            camera: _platCam,
            extentM: _spec.extentM,
          ),
        ),
      if (_sim == null)
        const Center(
          child: Text('Set the knobs, then GENERATE.', style: AppTheme.dim),
        ),
      if (_driving)
        ValueListenableBuilder<double>(
          valueListenable: _epoch,
          builder: (context, epoch, _) => _driveHint(),
        ),
      if (_firstPerson)
        Positioned(
          left: 0,
          right: 0,
          bottom: 16,
          child: Center(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: AppTheme.panelBox(),
              child: Text(
                  'WASD to walk · shift to run · drag to look · G to fly',
                  style: AppTheme.mono
                      .copyWith(fontSize: 11, color: AppTheme.textDim)),
            ),
          ),
        ),
      Positioned(
        left: 12,
        top: 12,
        child: RepaintBoundary(
          child: ValueListenableBuilder<int>(
            valueListenable: _perfTick,
            builder: (context, tick, _) => _perfPanel(),
          ),
        ),
      ),
      if (_picked != null)
        Positioned(right: 12, top: 12, width: 300, child: _pickCard()),
    ]);
  }

  /// A camera-pose edit from a pointer handler.
  ///
  /// With a colony up, the ticker already repaints the scene every frame and
  /// reads the pose fields as it goes — a `setState` here would only add a
  /// rebuild of the app bar and the whole control column for every drag
  /// event, thirty-odd paragraphs relaid for a mouse move. Nothing outside
  /// the epoch builder reads the pose at build time (the perf panel's "cam"
  /// row rides its own 4 Hz clock), so assigning is enough. Before there is
  /// a scene to tick nothing else would repaint it, and `setState` stays.
  void _nudgePose(void Function() edit) {
    if (_scene != null && _sim != null) {
      edit();
    } else {
      setState(edit);
    }
  }

  /// The scene itself, and its pointer surface: the one subtree the epoch
  /// rebuilds. The per-frame phases run here, BEFORE [fs.SceneView] paints,
  /// so what it encodes is this frame's terrain, city, sun and rig.
  Widget _sceneSurface(fs.Scene scene, double epoch) {
    {
        final snap = _snap;
        final cam = _camera();
        // In the plat view the streamers rest: nothing 3D is on screen.
        if (snap != null && !_view2D) {
          // Advance the frame's clock so the traffic pass has something to
          // move against — it derives vehicle positions from the epoch.
          // Then turn the sun: everything downstream — terrain shading, the
          // atmosphere, the city's night factor — reads the star out of the
          // FRAME, so moving it in the frame is what keeps them agreeing.
          final frame = _withSunTurned(snap.copyWithEpoch(epoch));
          final starWorld = _starWorld(frame);
          // Ground FIRST: the colony is cut into it, and without it the city
          // hangs in space with its levelled pads describing nothing.
          final sw = Stopwatch()..start();
          // The real LOD lens (shared with the terrain studio). With
          // `camera: null` the screen-space budget was zero pixels for
          // everything: nothing split except the city's forced-refinement
          // island, so the colony sat on a cliff of detail with root-coarse
          // ground beyond it, and the streamer's zoom probe never saw the
          // camera move.
          //
          // The rig sits between: frozen (F), it hands back the pinned lens
          // instead of the live one, and the camera is free to go and look
          // at what that lens selected and culled.
          final lens = _liveLens();
          final bodyQuat = _bodyQuatOf(frame);
          final probe = _rig.probe(
            liveEyeRel: lens.eyeRel,
            liveForward: lens.forward,
            liveFocalPx: _focalPx,
            focusWorld: _origin.focusWorld,
            bodyCentreWorld: _bodyCentreWorld,
            bodyQuat: bodyQuat,
          );
          final cone = !GraphicsQuality.terrainFrustumCull
              ? null
              : _rig.viewCone(
                  liveForward: lens.forward,
                  liveFovRadiansY: _fovY,
                  liveAspect: _viewportW / _viewportH,
                  marginRad: TerrainNodes.frustumMarginRad,
                  bodyQuat: bodyQuat,
                );
          _phase(
              'terrain',
              () => _terrain!.update(
                    frame,
                    _origin,
                    cameraEye: probe.eyeRel,
                    camera: probe,
                    viewCone: cone,
                    focusBodyId: _bodyIdOfFrame(frame),
                    starWorld: starWorld,
                  ));
          _terrainMs = sw.elapsedMicroseconds / 1000;
          sw.reset();
          // The CAMERA, not the colony's centre. `_anchorWorld` is where the
          // city is, which never moves — so per-building LOD measured every
          // distance from the middle of town and never changed however far
          // the camera flew. `_cameraEyeM` is already in world axes about the
          // anchor, so this is the eye in world space.
          //
          // And from the SAME LENS as the terrain: once the rig is frozen the
          // tiers and the view cull are judged from the pinned eye, so the
          // camera can fly round and see what the pin left coarse.
          final lensEyeWorld = _rig.frozen
              ? _rig.frozenEyeWorld(
                  bodyCentreWorld: _bodyCentreWorld, bodyQuat: bodyQuat)
              : _anchorWorld + _cameraEyeM();
          _phase(
              'city',
              () => _city!.update(frame, _origin,
                  focusWorld: lensEyeWorld, viewCone: cone));
          _cityMs = sw.elapsedMicroseconds / 1000;
          sw.reset();
          _phase('sun', () => _syncSun(scene, frame, starWorld));
          _phase(
              'atmosphere',
              () => _atmo!.update(frame, _origin,
                  cameraEye: _cameraEyeM(), starWorld: starWorld));
          _phase('scale rig', () => _syncRig(scene));
          _phase('rover', () => _syncRover(scene, frame, bodyQuat));
          // The frozen lens, drawn for the RENDER camera; frustum length
          // scales with the frozen eye's height so it reads at any range.
          if (_rigGizmo?.scene != scene) _rigGizmo = DebugCameraGizmo(scene);
          var farM = 2000.0;
          if (_rig.frozen) {
            final eyeW = _rig.frozenEyeWorld(
                bodyCentreWorld: _bodyCentreWorld, bodyQuat: bodyQuat);
            final altM = (eyeW - _bodyCentreWorld).length -
                (_anchorWorld - _bodyCentreWorld).length;
            farM = (altM.abs() * 3).clamp(300.0, 40000.0);
          }
          _phase(
              'lens rig',
              () => _rigGizmo!.sync(
                    _rig,
                    focusWorld: _origin.focusWorld,
                    renderCamera: cam,
                    viewport: Size(_viewportW, _viewportH),
                    visible: _showLensRig,
                    bodyCentreWorld: _bodyCentreWorld,
                    bodyQuat: bodyQuat,
                    farM: farM,
                  ));
        }

        return Focus(
              autofocus: true,
              onKeyEvent: _onKey,
              child: GestureDetector(
              // A tap and a drag live on ONE detector: a sibling would take
              // the pan away from the orbit camera.
              onTapUp: (d) => _pickAt(d.localPosition),
              onScaleStart: (_) => _dragBase = (_azimuth, _elevation),
              onScaleUpdate: (d) => _nudgePose(() {
                if (_driving) {
                  // Swing the chase camera round the buggy; it drifts back
                  // behind the heading once the throttle is on.
                  _chaseOrbit -= d.focalPointDelta.dx * 0.005;
                  _chasePitch = (_chasePitch + d.focalPointDelta.dy * 0.004)
                      .clamp(0.05, 1.2);
                  return;
                }
                if (_firstPerson) {
                  // Mouse-look. Pitch stops just short of straight up and
                  // down, where the up vector degenerates.
                  _walkYaw -= d.focalPointDelta.dx * 0.005;
                  _walkPitch = (_walkPitch - d.focalPointDelta.dy * 0.004)
                      .clamp(-1.45, 1.45);
                  return;
                }
                if (d.pointerCount > 1) {
                  _distanceM =
                      (_distanceM / d.scale.clamp(0.2, 5.0)).clamp(40.0, 60000.0);
                } else {
                  _azimuth = _dragBase.$1 - d.focalPointDelta.dx * 0.008;
                  _elevation = (_dragBase.$2 + d.focalPointDelta.dy * 0.006)
                      .clamp(-0.2, 1.45);
                  _dragBase = (_azimuth, _elevation);
                }
              }),
              child: Listener(
                    onPointerSignal: (e) {
                  // On foot the eye IS the head: zooming would pull it out of
                  // the walker, so the wheel does nothing.
                  if (_firstPerson) return;
                  if (_driving) {
                    // Behind the buggy the wheel is the chase range.
                    if (e is PointerScrollEvent) {
                      _nudgePose(() => _chaseDistM =
                          (_chaseDistM * (1 + e.scrollDelta.dy * 0.0016))
                              .clamp(4.0, 40.0));
                    }
                    return;
                  }
                  if (e is PointerScrollEvent) {
                    _nudgePose(() => _distanceM =
                        (_distanceM * (1 + e.scrollDelta.dy * 0.0016))
                            .clamp(40.0, 60000.0));
                  }
                },
                // CHIRALITY: the app's world-to-scene mapping is a mirror the
                // renderer corrects by flipping the finished image. The studio
                // flips too, so what is tuned here is what the sim shows.
                child: LayoutBuilder(builder: (context, constraints) {
                  _viewportH = math.max(1, constraints.maxHeight);
                  _viewportW = math.max(1, constraints.maxWidth);
                  return Transform.flip(
                    flipX: true,
                    child: _view2D
                        ? const SizedBox.expand()
                        : fs.SceneView(scene, camera: cam),
                  );
                }),
              ),
            ),
            );
    }
  }

  // ---- Identify: click a building, read what it is ----------------------

  /// Every installation's type, label, colony-local centre and site size,
  /// for the harness to aim a camera at.
  List<Map<String, Object?>> _installationsStatus() {
    final sim = _sim;
    if (sim == null) return const [];
    return [
      for (final e in sim.parcelBuildings.entries)
        if (e.value.claimsOwnSite)
          {
            'type': e.value.type,
            'label': e.value.label,
            'e': sim.parcelById(e.key)?.centroid.e ?? 0,
            'n': sim.parcelById(e.key)?.centroid.n ?? 0,
            'w': e.value.siteMetres().width,
            'd': e.value.siteMetres().depth,
          },
    ];
  }

  /// What stands under a click, as a card — the installations especially:
  /// from the studio's framing distance a refinery and a data centre are
  /// both a flat grey slab, and the only way to tell which is to ask.
  void _pickAt(Offset local) {
    final sim = _sim;
    if (sim == null) return;
    final bf = _pickGroundBF(local);
    if (bf == null) {
      setState(_clearPick);
      return;
    }
    final hit = sim.siteAt(_bfToLocal(bf));
    setState(() {
      if (hit == null) {
        _clearPick();
        return;
      }
      final (site, parcel, spec) = hit;
      _picked = (site: site, parcel: parcel, spec: spec, at: local);
      // Outline the plot on the ground, through the cursor the placement
      // editor already draws.
      final extent = parcel.buildableExtent;
      final dir = sim
          .localToBodyFixed(parcel.centroid, bodyRadiusM: sim.body.radius)
          .normalized;
      final ground = _groundField?.groundRadiusAt(dir.x, dir.y, dir.z) ??
          sim.body.radius;
      CityNodes.cursorBF = dir * ground;
      CityNodes.cursorBodyId = sim.body.id.value;
      CityNodes.cursorSizeM = math.max(8.0, extent.width);
      CityNodes.cursorDepthM = math.max(8.0, extent.depth);
      CityNodes.cursorBad = false;
    });
  }

  void _clearPick() {
    _picked = null;
    CityNodes.cursorBF = null;
  }

  /// The ground under a viewport point, body-fixed metres, or null when the
  /// ray misses the planet.
  ///
  /// The same march the terrain studio uses, with ONE difference: this
  /// studio flips the finished image (see the SceneView above), so screen
  /// right is the domain's own right and there is no mirror term — the
  /// terrain studio does not flip and negates its screen x instead.
  Vector3? _pickGroundBF(Offset local) {
    final sim = _sim;
    final snap = _snap;
    final field = _groundField;
    if (sim == null || snap == null || field == null) return null;
    final b = snap.bodies[sim.body.id.value];
    if (b == null) return null;
    final quat = Quaternion(b.qw, b.qx, b.qy, b.qz);

    final eyeWorld = _anchorWorld + _cameraEyeM();
    final Vector3 fwd;
    final Vector3 upCam;
    if (_groundView) {
      fwd = _groundLook();
      final radial = eyeWorld - _bodyCentreWorld;
      upCam = radial.length > 1 ? radial.normalized : _upWorld;
    } else {
      fwd = (_anchorWorld - eyeWorld).normalized;
      upCam = _upWorld;
    }
    final right = fwd.cross(upCam).normalized;
    final upv = right.cross(fwd);
    // One focal length for both axes: the projection has square pixels, and
    // deriving a second horizontal focal from the aspect is the classic bug
    // that leaves picking exact on a square viewport and drifting on a wide
    // one.
    final sx = local.dx - _viewportW / 2;
    final sy = _viewportH / 2 - local.dy;
    final dir = (fwd * _focalPx + right * sx + upv * sy).normalized;

    double altAt(double t) {
      final rel = eyeWorld + dir * t - _bodyCentreWorld;
      final bf = quat.conjugate.rotate(rel);
      final u = bf.normalized;
      return bf.length - field.groundRadiusAt(u.x, u.y, u.z);
    }

    var t = 0.0;
    var prevT = 0.0;
    var prevAlt = altAt(0);
    if (prevAlt <= 0) return null;
    for (var i = 0; i < 400 && t < 60000; i++) {
      t += math.max(prevAlt * 0.5, 1.5);
      final alt = altAt(t);
      if (alt <= 0) {
        var lo = prevT, hi = t;
        for (var k = 0; k < 24; k++) {
          final mid = (lo + hi) / 2;
          if (altAt(mid) > 0) {
            lo = mid;
          } else {
            hi = mid;
          }
        }
        return quat.conjugate.rotate(eyeWorld + dir * hi - _bodyCentreWorld);
      }
      prevT = t;
      prevAlt = alt;
    }
    return null;
  }

  /// Body-fixed point -> the colony's local east/north metres: a tangent-
  /// plane projection, exact enough at studio scale.
  Vec2 _bfToLocal(Vector3 bf) {
    final sim = _sim!;
    final lat = sim.cityLat * math.pi / 180.0;
    final lon = sim.cityLon * math.pi / 180.0;
    final up = Vector3(math.cos(lat) * math.cos(lon),
        math.cos(lat) * math.sin(lon), math.sin(lat));
    final east = Vector3(-math.sin(lon), math.cos(lon), 0);
    final north = up.cross(east);
    final rel = bf - up * sim.body.radius;
    return Vec2(rel.dot(east), rel.dot(north));
  }

  Widget _pickCard() {
    final p = _picked!;
    final sim = _sim!;
    final spec = p.spec;
    final status = citySiteStatus(sim, p.site, spec);
    final site = spec.claimsOwnSite
        ? spec.siteMetres()
        : (width: p.parcel.buildableExtent.width,
            depth: p.parcel.buildableExtent.depth);
    final kind = switch (spec.siteKind) {
      SiteKind.building => 'Enclosed building',
      SiteKind.field => 'Open installation, covering its site',
      SiteKind.pit => 'Excavation: the site is the hole',
      SiteKind.pad => 'Paved apron',
    };
    final io = <String>[];
    spec.inputs.forEach(
        (k, v) => io.add('−${v.toStringAsFixed(1)} ${Commodity.name(k)}/s'));
    spec.outputs.forEach(
        (k, v) => io.add('+${v.toStringAsFixed(1)} ${Commodity.name(k)}/s'));
    if (spec.powerOutput > 0) {
      io.add('+${spec.powerOutput.toStringAsFixed(0)} power');
    }
    if (spec.powerDraw > 0) io.add('−${spec.powerDraw.toStringAsFixed(0)} power');
    if (spec.jobs > 0) io.add('${spec.jobs} jobs');
    if (spec.housing > 0) io.add('${spec.housing} housing');
    if (spec.storageBonus > 0) {
      io.add('+${spec.storageBonus.toStringAsFixed(0)} storage');
    }
    Widget line(String text, {Color? colour}) => Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(text,
              style: AppTheme.mono
                  .copyWith(fontSize: 11, color: colour ?? AppTheme.textDim)),
        );
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.panelBox(border: AppTheme.accent2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(spec.icon, size: 18, color: spec.color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(spec.label,
                style: AppTheme.body.copyWith(fontWeight: FontWeight.w600)),
          ),
          InkWell(
            onTap: () => setState(_clearPick),
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(Icons.close, size: 16, color: AppTheme.textDim),
            ),
          ),
        ]),
        line(kGroupLabels[spec.group] ?? spec.group.toUpperCase(),
            colour: AppTheme.accent2),
        line(kind),
        line('${site.width.round()} × ${site.depth.round()} m'
            '${p.parcel.manual ? ', its own plot' : ', a street lot'}'),
        line(status.label, colour: status.color),
        if (io.isNotEmpty) line(io.join(' · ')),
        const SizedBox(height: 4),
        line('Click another building, or Esc.',
            colour: AppTheme.textDim.withValues(alpha: 0.7)),
      ]),
    );
  }

  /// WASD while on foot. Held keys are tracked rather than acted on directly,
  /// so movement happens on the TICK — a key-repeat rate is not a frame rate,
  /// and driving the walker off one makes it stutter.
  /// What the streamers look through this frame when the rig is live: the
  /// probe eye (anchor-relative), the view direction, and screen up — the
  /// same numbers [_camera] renders with, so a freeze captures the lens in
  /// use exactly.
  ({Vector3 eyeRel, Vector3 forward, Vector3 up}) _liveLens() {
    final eyeM = _cameraEyeM();
    if (_groundView) {
      final radial = (_anchorWorld + eyeM) - _bodyCentreWorld;
      return (
        eyeRel: eyeM,
        forward: _groundLook(),
        up: radial.length < 1 ? _upWorld : radial.normalized,
      );
    }
    return (
      eyeRel: eyeM,
      forward: eyeM.length > 1 ? eyeM.normalized * -1 : Vector3.unitZ,
      up: _upWorld,
    );
  }

  Quaternion _bodyQuatOf(WorldSnapshot frame) {
    final b = frame.bodies[_bodyIdOfFrame(frame)];
    return b == null
        ? Quaternion.identity
        : Quaternion(b.qw, b.qx, b.qy, b.qz);
  }

  /// F: pin the streamer's lens where it stands, or let it go.
  void _toggleRigFreeze() {
    if (_rig.frozen) {
      setState(_rig.release);
      return;
    }
    final snap = _snap;
    if (snap == null) return;
    final lens = _liveLens();
    setState(() => _rig.freeze(
          eyeWorld: _anchorWorld + lens.eyeRel,
          forwardWorld: lens.forward,
          upWorld: lens.up,
          focalPx: _focalPx,
          fovRadiansY: _fovY,
          aspect: _viewportW / _viewportH,
          bodyCentreWorld: _bodyCentreWorld,
          bodyQuat: _bodyQuatOf(snap),
        ));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.keyG) {
      setState(_toggleFirstPerson);
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.keyF) {
      _toggleRigFreeze();
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.keyM) {
      _toggleView2D();
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent &&
        e.logicalKey == LogicalKeyboardKey.keyR &&
        _sim != null &&
        _snap != null &&
        !_view2D) {
      setState(_toggleDriving);
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent &&
        e.logicalKey == LogicalKeyboardKey.escape &&
        _picked != null) {
      setState(_clearPick);
      return KeyEventResult.handled;
    }
    if (!_groundView) return KeyEventResult.ignored;
    final move = {
      LogicalKeyboardKey.keyW,
      LogicalKeyboardKey.keyA,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyD,
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight,
      LogicalKeyboardKey.space,
    };
    if (!move.contains(e.logicalKey)) return KeyEventResult.ignored;
    if (e is KeyDownEvent) {
      _held.add(e.logicalKey);
    } else if (e is KeyUpEvent) {
      _held.remove(e.logicalKey);
    }
    return KeyEventResult.handled;
  }

  /// Step on and off the pavement.
  ///
  /// Entering, the walker is placed just outside the colony looking in, so the
  /// first thing on screen is a street rather than the inside of a building.
  void _toggleFirstPerson() {
    // Out of the buggy first: it hands its spot to the walker, who then
    // steps out where it was parked rather than back at the entry.
    final fromRover = _driving;
    if (fromRover) _toggleDriving();
    _firstPerson = !_firstPerson;
    _held.clear();
    if (_firstPerson && !fromRover) {
      _walkE = 0;
      _walkN = -_spec.blockDepthM * 0.6;
      _walkYaw = 0; // facing north, into the colony
      _walkPitch = 0;
    }
  }

  /// What is eating the frame.
  ///
  /// CPU time only, and it says so: this measures the work this screen does to
  /// prepare a frame, not what the GPU then spends drawing it. When the totals
  /// here are small but the frame is long, the cost is in the draw — which is
  /// what the draw-call and instance counts are for.
  ///
  /// Built off [_perfTick], not the scene's epoch, and behind a
  /// [RepaintBoundary]: a rebuild here must not be what the scene's frame
  /// waits on.
  Widget _perfPanel() {
    final n = _frameMs.length;
    var avg = 0.0, worst = 0.0;
    for (final f in _frameMs) {
      avg += f;
      if (f > worst) worst = f;
    }
    if (n > 0) avg /= n;
    final fps = avg > 0 ? 1000 / avg : 0;

    String ms(double v) => v.toStringAsFixed(2).padLeft(6);
    final phase = CityNodes.phaseMs;
    final count = CityNodes.phaseCount;
    final accounted = _terrainMs + _cityMs;

    Widget row(String label, String value, {Color? colour}) => Text(
        '${label.padRight(16)}$value',
        style: AppTheme.mono
            .copyWith(fontSize: 11, color: colour ?? AppTheme.text));

    // The FRAME row is the collapse toggle: collapsed, the panel is one
    // line and the scene behind it is inspectable.
    final header = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _perfCollapsed = !_perfCollapsed),
      child: row(
          '${_perfCollapsed ? '▸' : '▾'} FRAME',
          '${ms(avg)} ms  ${fps.toStringAsFixed(0)} fps',
          colour: fps < 30 ? AppTheme.danger : AppTheme.accent2),
    );
    if (_perfCollapsed) {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: AppTheme.panelBox(),
        child: header,
      );
    }
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.panelBox(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_fault != null) ...[
          row('FAULT', _fault!.phase, colour: AppTheme.danger),
          SizedBox(
            width: 320,
            child: Text('${_fault!.error}',
                style: AppTheme.mono
                    .copyWith(fontSize: 10, color: AppTheme.danger)),
          ),
          const SizedBox(height: 6),
        ],
        header,
        row('worst 90', '${ms(worst)} ms', colour: AppTheme.textDim),
        // The engine's own pipeline report. `raster` is the thread that
        // encodes and submits the GPU work — when it dwarfs the CPU phase
        // rows below, the frame is GPU/driver-bound and the per-draw story
        // needs an external capture (wiki/GPU-Profiling.md).
        row('ui build', '${ms(_avgOf(_uiMs))} ms', colour: AppTheme.textDim),
        row('raster', '${ms(_avgOf(_rasterMs))} ms',
            colour: _avgOf(_rasterMs) > 16 ? AppTheme.warn : AppTheme.textDim),
        row(
            'scene draws',
            '$_censusDraws  ($_censusInstances inst, '
            '$_censusNodes nodes)',
            colour: AppTheme.accent),
        Text(
            '  whole scene, per colour pass. Shadow cascades re-draw '
            'casters on top.',
            style: AppTheme.dim.copyWith(fontSize: 10)),
        // What the engine actually ENCODED last frame (post-cull), against
        // the census above (pre-cull), and where its UI-thread time went.
        row(
            '  encoded',
            'colour ${fs.Scene.lastFrameStats.colourDraws}  '
            'shadow ${fs.Scene.lastFrameStats.shadowDraws}  '
            'binds ${fs.Scene.lastFrameStats.materialBinds}  '
            'packed ${fs.Scene.lastFrameStats.packedInstances}'
            '/${fs.Scene.lastFrameStats.instancesEmplaced}',
            colour: AppTheme.textDim),
        row(
            '  engine ms',
            'pre ${ms(fs.Scene.lastFrameStats.prePassMs)}  '
            'bvh ${ms(fs.Scene.lastFrameStats.bvhMs)}  '
            'shadow ${ms(fs.Scene.lastFrameStats.shadowMs)}  '
            'colour ${ms(fs.Scene.lastFrameStats.colourMs)}  '
            'rebuilds ${fs.Scene.lastFrameStats.bvhRebuilds}',
            colour: fs.Scene.lastFrameStats.bvhRebuilds > 0
                ? AppTheme.warn
                : AppTheme.textDim),
        const SizedBox(height: 6),
        row('terrain', '${ms(_terrainMs)} ms',
            colour: _terrainMs > 4 ? AppTheme.warn : AppTheme.text),
        // Terrain's own phases: preparation, LOD selection, chunk streaming.
        // `sel` climbing means it is choosing chunks; `stream` means it is
        // meshing and uploading them.
        if (TerrainNodes.profileLine.isNotEmpty)
          Text('  ${TerrainNodes.profileLine.replaceFirst('terrain: ', '')}',
              style: AppTheme.mono
                  .copyWith(fontSize: 10, color: AppTheme.textDim)),
        row('  chunks', '${TerrainNodes.counters['chunks'] ?? 0}',
            colour: AppTheme.textDim),
        row('  brushes', '${TerrainNodes.counters['brushes'] ?? 0}',
            colour: (TerrainNodes.counters['brushes'] ?? 0) > 400
                ? AppTheme.danger
                : AppTheme.textDim),
        row('  forced refine', '${TerrainNodes.counters['refineTargets'] ?? 0}',
            colour: (TerrainNodes.counters['refineTargets'] ?? 0) > 2000
                ? AppTheme.danger
                : AppTheme.textDim),
        row('  near brushes', '${TerrainNodes.counters['nearBrushes'] ?? 0}',
            colour: AppTheme.textDim),
        row(
            '  out of view',
            GraphicsQuality.terrainFrustumCull
                ? '${TerrainNodes.counters['outOfView'] ?? 0} leaves coarsened'
                : 'culling off',
            colour: AppTheme.textDim),
        row('  lod camera', _rig.frozen ? 'FROZEN  (F releases)' : 'live',
            colour: _rig.frozen ? AppTheme.warn : AppTheme.textDim),
        row('  loading', '${TerrainNodes.counters['gridPatches'] ?? 0}',
            colour: AppTheme.textDim),
        // Tiles that failed their band check often enough to be given up on.
        // Any non-zero value here is a hole in the ground that will not fill.
        row('  retired', '${_terrain?.retiredClipped ?? 0}',
            colour: (_terrain?.retiredClipped ?? 0) > 0
                ? AppTheme.danger
                : AppTheme.textDim),
        row('city', '${ms(_cityMs)} ms'),
        row(
            '  out of view',
            GraphicsQuality.terrainFrustumCull
                ? '${CityNodes.outOfViewTiles} tiles stepped down'
                : 'culling off',
            colour: AppTheme.textDim),
        row(
            '  lod mix',
            [
              'full ${CityNodes.lodCounts[BuildingDetail.full] ?? 0}',
              'ext ${CityNodes.lodCounts[BuildingDetail.exterior] ?? 0}',
              'blk ${CityNodes.lodCounts[BuildingDetail.block] ?? 0}',
            ].join('  '),
            colour: (CityNodes.lodCounts[BuildingDetail.full] ?? 0) > 400
                ? AppTheme.danger
                : AppTheme.textDim),
        // The tiles: how many at each tier, how many wait to build, and
        // how many finished this frame. A queue that never drains is a
        // camera moving faster than the budget can follow.
        row(
            '  tiles',
            'near ${count['near'] ?? 0}  mid ${count['mid'] ?? 0}  '
            'far ${count['far'] ?? 0}  queued ${count['queued'] ?? 0}  '
            'built ${count['builtThisFrame'] ?? 0}',
            colour: (count['queued'] ?? 0) > 40
                ? AppTheme.warn
                : AppTheme.textDim),
        row('  build', '${ms(phase['city.build'] ?? 0)} ms',
            colour: AppTheme.textDim),
        row('  bucket', '${ms(phase['city.bucket'] ?? 0)} ms',
            colour: (phase['city.bucket'] ?? 0) > 4
                ? AppTheme.warn
                : AppTheme.textDim),
        row('  tier', '${ms(phase['city.tier'] ?? 0)} ms',
            colour: AppTheme.textDim),
        row('  anchors', '${ms(phase['city.anchors'] ?? 0)} ms',
            colour: AppTheme.textDim),
        row('  traffic', '${ms(phase['city.traffic'] ?? 0)} ms',
            colour: (phase['city.traffic'] ?? 0) > 2
                ? AppTheme.warn
                : AppTheme.textDim),
        row('  cursor', '${ms(phase['city.cursor'] ?? 0)} ms',
            colour: AppTheme.textDim),
        const SizedBox(height: 4),
        // The gap is what the phase timers do not wrap: the engine's own
        // encode of the scene (shadow cascades, the colour pass), which runs
        // on the UI thread inside SceneView's painter, plus the GPU and
        // Flutter's own frame. If it dominates, tuning the phases above will
        // not help — the isolate switches will say which pass it is.
        if (_buildLog.isNotEmpty) ...[
          const SizedBox(height: 6),
          row('last build', '', colour: AppTheme.accent),
          for (final line in _buildLog)
            Text('  $line',
                style: AppTheme.mono
                    .copyWith(fontSize: 10, color: AppTheme.textDim)),
        ],
        row('unaccounted', '${ms((avg - accounted).clamp(0, 1e9))} ms',
            colour: AppTheme.warn),
        Text(
            '  GPU + the engine\'s encode on the UI thread: no phase timer '
            'sees it. Attribute by A/B with the ISOLATE switches — shadows '
            'and atmosphere first, they are the usual bulk.',
            style: AppTheme.dim.copyWith(fontSize: 10)),
        const SizedBox(height: 6),
        row('draws', '${count['draws'] ?? 0}', colour: AppTheme.accent),
        row('batches', '${count['batches'] ?? 0}', colour: AppTheme.accent),
        row('meshes', '${count['meshes'] ?? 0}', colour: AppTheme.accent),
        row('buildings', '${count['buildings'] ?? 0}', colour: AppTheme.accent),
        row('traffic nodes', '${count['trafficNodes'] ?? 0}',
            colour: AppTheme.accent),
        const SizedBox(height: 4),
        row('cam', '${_distanceM.round()} m', colour: AppTheme.textDim),
      ]),
    );
  }

  Widget _controls() {
    // A Material, not a coloured Container. The switch below is a ListTile,
    // and a ListTile paints its background and ink onto the nearest Material
    // ancestor — put a ColoredBox in between and Flutter asserts about it on
    // every single frame.
    return Material(
      color: AppTheme.panel,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text('WORLD', style: AppTheme.heading),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final b in _bodies)
              ChoiceChip(
                label: Text(b, style: const TextStyle(fontSize: 12)),
                selected: _body == b,
                selectedColor: AppTheme.accent2,
                backgroundColor: AppTheme.panelLight,
                onSelected: (_) => setState(() => _body = b),
              ),
          ]),
          const SizedBox(height: 6),
          Text(
              _body == 'earth'
                  ? 'Breathable: open roads, pavements, cars. Sited on dry '
                      'land — the seed picks where.'
                  : 'No air: sealed roads, pedestrian tubes, six-wheeled rovers.',
              style: AppTheme.dim),
          const SizedBox(height: 16),
          const Text('LAYOUT', style: AppTheme.heading),
          _slider('Blocks across', _blocks, 1, 8,
              'The performance dial — roads, lots and buildings all grow with '
                  'its square, and so does the time to build one.',
              (v) => setState(() => _blocks = v),
              divisions: 7),
          _slider('Block length', _blockM, 90, 400,
              'Metres between the CROSS streets — the long way round a block.',
              (v) => setState(() => _blockM = v), unit: 'm'),
          _slider('Block depth', _blockDepthM, 60, 260,
              'Metres between the streets lots front onto. Wants to be about '
                  'twice the lot depth plus an alley: any deeper and the '
                  'middle of every block is ground nothing can reach.',
              (v) => setState(() => _blockDepthM = v), unit: 'm'),
          _slider('Street bend', _bend, 0, 90,
              'How far streets wander off true. Zero is a grid; bends are what '
                  'produce tapered lots.',
              (v) => setState(() => _bend = v), unit: 'm'),
          _slider('Built fraction', _build, 0.1, 1.0,
              'Share of lots that get a building.',
              (v) => setState(() => _build = v)),
          _slider('Installations', _installations, 0, 10,
              'Sprawling sites — farms, quarries, ports — staked outside the '
                  'streets.',
              (v) => setState(() => _installations = v), divisions: 10),
          _slider('Megatowers', _megatowers, 0, 4,
              'Block-filling towers, 90 to 150 storeys, staked over whole '
                  'block interiors near the centre — the only buildings '
                  'allowed past the ordinary height ceiling.',
              (v) => setState(() => _megatowers = v), divisions: 4),
          const SizedBox(height: 8),
          const Text('OUTSKIRTS', style: AppTheme.heading),
          Text('Where the town stops, and what lies past it.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          _slider('Taper', _taper, 0, 1,
              'How far the edge of town departs from the block grid. 0 is '
                  'the old square, built to every corner; 1 is a rounded, '
                  'ragged edge that frays into suburbs.',
              (v) => setState(() => _taper = v), divisions: 10),
          _slider('Outreach', _outreachM / 1000, 0, 10,
              'How far the trunk roads and the railway run on past the last '
                  'street. Farms line the roads out there.',
              (v) => setState(() => _outreachM = v * 1000),
              unit: 'km', divisions: 20),
          _slider('Farms', _farms, 0, 24,
              'Farmsteads scattered along the trunk roads: a field, a house '
                  'and a barn each, or now and then a wind farm.',
              (v) => setState(() => _farms = v), divisions: 24),
          _slider('Sprawl', _sprawlMiles, 0, 30,
              'How far across the SPRAWL runs: mile-square sections of '
                  'subdivisions, strips, industrial parks and farms past the '
                  'core, with county highways and interstates. Twenty is '
                  'Chicago. Zero lays none.',
              (v) => setState(() => _sprawlMiles = v),
              unit: 'mi', divisions: 30),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _railway,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Railway', style: AppTheme.body),
            subtitle: Text(
                'A mainline past one side of town: a station at the edge, a '
                'freight yard by the works, passenger and freight trains.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() => _railway = v),
          ),
          const SizedBox(height: 8),
          const Text('NETWORK', style: AppTheme.heading),
          Text('The tiers that are not just a wider street.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _alleys,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Alleys', style: AppTheme.body),
            subtitle: Text('A service road down the spine of every block. '
                'Lots run back to it, so the STREET frontage can stay '
                'unbroken — turn it off and watch the block hollow out.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() => _alleys = v),
          ),
          _slider('Elevated rail', _transit, 0, 3,
              'Lines on a steel trestle over the street, with a train.',
              (v) => setState(() => _transit = v), divisions: 3),
          _slider('Elevated highway', _viaducts, 0, 3,
              'Concrete viaducts on hammerhead piers, round the outside.',
              (v) => setState(() => _viaducts = v), divisions: 3),
          const SizedBox(height: 8),
          Row(children: [
            const Text('Seed', style: AppTheme.body),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.casino, color: AppTheme.accent2),
              tooltip: 'Reroll',
              onPressed: () => setState(() => _seed++),
            ),
            Text('$_seed', style: AppTheme.mono),
          ]),
          const SizedBox(height: 8),
          const Text('LIGHTING', style: AppTheme.heading),
          _slider('Sun time', _sunTurnH, -12, 12,
              'Hours around the captured moment. Each generate resets this '
                  'to local noon; drag for golden hour, night, and the '
                  'windows coming on.',
              (v) => setState(() => _sunTurnH = v), unit: 'h'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: !AtmosphereNodes.hidden,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Atmosphere', style: AppTheme.body),
            subtitle: Text(
                'The flight scene\'s raymarched sky. Airless worlds keep '
                    'their black one either way.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() => AtmosphereNodes.hidden = !v),
          ),
          const SizedBox(height: 8),
          const Text('TERRAIN COST', style: AppTheme.heading),
          Text('A city hands the terrain one brush per building, and each one '
              'forces its own island of deep quadtree. This is the dial.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          const SizedBox(height: 4),
          const Text('DRAW CALLS', style: AppTheme.heading),
          Text('Every distinct building archetype is its own mesh and its own '
              'draw. These collapse that — watch "draws" and "meshes" in the '
              'frame panel.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          _slider('LOD level step', TerrainNodes.levelStep.toDouble(), 0, 8,
              'Levels a streaming pass may climb at once. Low sharpens the '
                  'whole view together; 0 leaps straight to full detail, one '
                  'tile at a time.',
              (v) => setState(() => TerrainNodes.levelStep = v.round()),
              divisions: 8),
          _slider('Edit refine range', TerrainNodes.editRefineRangeM / 1000,
              0.5, 20,
              'How far out a terrain edit still forces deep chunks. A colony '
                  'emits one brush per building — this is what makes terrain '
                  'expensive near one.',
              (v) => setState(() => TerrainNodes.editRefineRangeM = v * 1000),
              unit: 'km'),
          _slider('Edit voxels across', TerrainNodes.editVoxelsAcross, 2, 12,
              'Voxels demanded across each edit. Fewer means shallower forced '
                  'refinement, and far fewer chunks.',
              (v) => setState(() => TerrainNodes.editVoxelsAcross = v),
              divisions: 10),
          _slider('City voxel floor', _cityVoxelM, 0, 30,
              'Coarsest voxel the colony\'s pads and road cuts are meshed at. '
                  '0 derives it from each brush (1 m under a street: level '
                  '17). Takes effect at the next GENERATE.',
              (v) => setState(() => _cityVoxelM = v),
              unit: 'm', divisions: 30),
          const SizedBox(height: 8),
          _slider('Lot bucket', CityNodes.archetypeBucketM, 4, 40,
              'Lot-size quantisation. Coarser buckets reuse more meshes.',
              (v) => setState(() => CityNodes.archetypeBucketM = v),
              unit: 'm'),
          _slider('Variants', CityNodes.archetypeVariants.toDouble(), 1, 6,
              'Different buildings per bucket. One makes a street identical.',
              (v) => setState(() => CityNodes.archetypeVariants = v.round()),
              divisions: 5),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _showRig,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Scale reference', style: AppTheme.body),
            subtitle: Text(
                'Mast banded 1 m to 10 m then 10 m to 100 m, a person, a car, '
                    'a 3 m storey, a 3.5 m lane and a 10 m ruler.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() => _showRig = v),
          ),
          const SizedBox(height: 8),
          const Text('ISOLATE', style: AppTheme.heading),
          Text('Turn a layer off and watch the frame panel — the fastest way '
              'to find what is actually costing you.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: TerrainNodes.enabled,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Terrain', style: AppTheme.body),
            onChanged: (v) => setState(() => TerrainNodes.enabled = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _rig.frozen,
            activeThumbColor: AppTheme.warn,
            title: const Text('Freeze LOD camera  (F)', style: AppTheme.body),
            subtitle: Text(
                'Pin the lens the terrain streamer selects and culls through '
                'where the camera stands now, then fly the camera away to '
                'watch what it chose from outside.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (_) => _toggleRigFreeze(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _showLensRig,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Draw frozen camera', style: AppTheme.body),
            subtitle: Text(
                'Frustum (cyan), view axis (yellow) and eye cross of the '
                'frozen lens.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() => _showLensRig = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: GraphicsQuality.terrainFrustumCull,
            activeThumbColor: AppTheme.accent2,
            title: const Text('View culling', style: AppTheme.body),
            subtitle: Text(
                'Terrain chunks and city tiles outside the lens\'s view cone '
                'select coarser (never vanish). Same switch as Options > '
                'Graphics quality.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) =>
                setState(() => GraphicsQuality.terrainFrustumCull = v),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Tiles outside the view', style: AppTheme.body),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final v in CityOutOfView.values)
                  ChoiceChip(
                    label: Text(v.label,
                        style: AppTheme.dim.copyWith(fontSize: 11)),
                    selected: GraphicsQuality.cityOutOfView == v,
                    onSelected: (_) =>
                        setState(() => GraphicsQuality.cityOutOfView = v),
                  ),
              ]),
            ]),
          ),
          Text(
              'Step down: one tier coarser, nothing pops in. Far: '
              'silhouettes. Hidden: not drawn — built nodes are kept and '
              'return instantly, unbuilt ones pop in on a turn, and nothing '
              'behind the camera casts a shadow.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: CityNodes.enabled,
            activeThumbColor: AppTheme.accent2,
            title: const Text('City (all of it)', style: AppTheme.body),
            onChanged: (v) => setState(() => CityNodes.enabled = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _shadows,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Shadows', style: AppTheme.body),
            subtitle: Text(
                'The cascaded shadow pass re-draws the whole scene per '
                    'cascade, encoded on the UI thread inside the painter — '
                    'it shows in "ui build" and "unaccounted", not in the '
                    'phase timers.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() => _shadows = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: CityNodes.onStreetParking,
            activeThumbColor: AppTheme.accent2,
            title: const Text('On-street parking', style: AppTheme.body),
            subtitle: Text('Curbside bays. Off reads newer, or stricter.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() => CityNodes.onStreetParking = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: CityNodes.lotFeatures,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Fences, signs, car parks', style: AppTheme.body),
            subtitle: Text('Lot furniture derived from each building\'s zone.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() => CityNodes.lotFeatures = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: CityNodes.traffic,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Road traffic', style: AppTheme.body),
            subtitle: Text('Rebuilt every frame — turn off when profiling.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() => CityNodes.traffic = v),
          ),
          const SizedBox(height: 8),
          const Text('LEVEL OF DETAIL', style: AppTheme.heading),
          Text('Buildings are generated at one of three tiers. The visualiser '
              'replaces each with a box its own size, coloured by the tier it '
              'actually got: red = full (interiors), amber = exterior, '
              'green = block silhouette.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: CityNodes.lodDebug,
            activeThumbColor: AppTheme.accent2,
            title: const Text('LOD visualiser', style: AppTheme.body),
            subtitle: Text('A city drawn entirely at full detail looks exactly '
                'like one drawn sensibly — it just costs ten times as much.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() {
              CityNodes.lodDebug = v;
              _city?.invalidate();
            }),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: CityNodes.perBuildingLod,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Per-building LOD', style: AppTheme.body),
            subtitle: Text('Off picks ONE tier for the whole colony from '
                'whichever building is nearest — so standing in a city builds '
                'every tower in it at full detail.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() {
              CityNodes.perBuildingLod = v;
              _city?.invalidate();
            }),
          ),
          _slider('Interior range', CityNodes.interiorRangeM, 50, 2000,
              'Closer than this a building gets slabs, a core and full '
                  'facade detail.',
              (v) => setState(() {
                    CityNodes.interiorRangeM = v;
                    _city?.invalidate();
                  }),
              unit: 'm'),
          _slider('Block range', CityNodes.blockRangeM, 300, 8000,
              'Beyond this a building is one silhouette box.',
              (v) => setState(() {
                    CityNodes.blockRangeM = v;
                    _city?.invalidate();
                  }),
              unit: 'm'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: StreetFurniture.enabled,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Street furniture', style: AppTheme.body),
            subtitle: Text('Hydrants, bins, benches, meters, planters, '
                'shelters and street trees on the pavements.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() {
              StreetFurniture.enabled = v;
              _city?.invalidate();
            }),
          ),
          const SizedBox(height: 8),
          if (_lastStats != null) ...[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: AppTheme.panelBox(),
              child: Text(_lastStats!,
                  style: AppTheme.mono.copyWith(fontSize: 11)),
            ),
            const SizedBox(height: 10),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _slowBuild,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Watch it build', style: AppTheme.body),
            subtitle: Text(
                'Slow mode: during zoning the scene recaptures every few '
                    'buildings, so you see them arrive one block at a time. '
                    'Deliberately slower — the estimate below stops applying.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: _busy ? null : (v) => setState(() => _slowBuild = v),
          ),
          const SizedBox(height: 8),
          // While it builds, the button becomes the readout: what the
          // generator is doing, how far through it is, and how long it has
          // actually taken. The estimate is only shown BEFORE the fact, which
          // is the only time a guess is worth anything.
          if (_busy && _progress != null) ...[
            Text(_progress!.phase, style: AppTheme.body),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: _progress!.fraction.clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: AppTheme.panel,
                color: AppTheme.accent2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
                '${(_progress!.fraction * 100).round()}%   '
                '${(_genClock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s',
                style: AppTheme.mono
                    .copyWith(fontSize: 11, color: AppTheme.textDim)),
            const SizedBox(height: 8),
          ],
          ElevatedButton.icon(
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppTheme.bg))
                : const Icon(Icons.location_city),
            label: Text(_busy
                ? 'BUILDING…'
                : 'GENERATE  (~${_estimateSec.toStringAsFixed(1)} s)'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accent2,
              foregroundColor: AppTheme.bg,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _busy ? null : _generate,
          ),
          const SizedBox(height: 6),
          Text(
              _lastStats == null
                  ? 'The estimate calibrates itself from the first build.'
                  : 'Estimate calibrated from the last build.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
        ],
      ),
    );
  }

  Widget _slider(String label, double value, double lo, double hi, String hint,
      ValueChanged<double> onCh,
      {int? divisions, String unit = ''}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label, style: AppTheme.body)),
          Text(
              unit.isEmpty ? value.toStringAsFixed(2) : '${value.round()}$unit',
              style: AppTheme.mono.copyWith(color: AppTheme.accent)),
        ]),
        Slider(
          value: value,
          min: lo,
          max: hi,
          divisions: divisions,
          activeColor: AppTheme.accent2,
          onChanged: onCh,
        ),
        Text(hint, style: AppTheme.dim.copyWith(fontSize: 11)),
      ]),
    );
  }
}
