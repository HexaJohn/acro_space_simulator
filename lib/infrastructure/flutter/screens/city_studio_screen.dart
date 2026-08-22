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

import '../../../adapters/repositories/in_memory_repositories.dart';
import '../../../adapters/repositories/in_memory_world_repositories.dart';
import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/colony/city/city_generator.dart';
import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/colony/city/city_terrain_shaper.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/shared/quaternion.dart';
import '../../../domain/shared/vector3.dart';
import '../../../domain/universe/real_solar_system.dart';
import '../../flutter_scene/city/city_nodes.dart';
import '../../../domain/architecture/building_generator.dart';
import '../../../domain/terrain/terrain_field.dart';
import '../../flutter_scene/city/city_materials.dart';
import '../../flutter_scene/city/street_furniture.dart';
import '../../flutter_scene/city/scale_rig.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../flutter_scene/coord_convert.dart';
import '../../flutter_scene/terrain/terrain_nodes.dart';
import 'app_theme.dart';

class CityStudioScreen extends StatefulWidget {
  const CityStudioScreen({super.key});

  @override
  State<CityStudioScreen> createState() => _CityStudioScreenState();
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

  /// The terrain shader and its material tiles. Static and shared: the same
  /// two futures the flight renderer awaits, so the studio draws the SAME
  /// ground rather than a stand-in for it.
  static final Future<void> _terrainInit = Future.wait([
    TerrainNodes.loadShader(),
    TerrainNodes.loadTextures(),
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
  static const double _eyeHeightM = 1.7;
  static const double _walkSpeedMs = 6.0;
  static const double _runSpeedMs = 22.0;

  final Set<LogicalKeyboardKey> _held = {};

  /// The ground sampler for the generated colony, kept so the walker can
  /// stand ON the terrain rather than at a fixed radius.
  TerrainField? _groundField;
  Vector3 _bodyCentreWorld = Vector3.zero;

  double _azimuth = 0.9;
  double _elevation = 0.55;
  double _distanceM = 1400;
  (double, double) _dragBase = (0, 0);
  /// Scene clock, as a notifier rather than plain state.
  ///
  /// The ticker used to `setState` the whole screen, which re-laid-out and
  /// re-rasterised every glyph in the control panel sixty times a second while
  /// the GPU was busy uploading scene geometry. Text came back with holes in
  /// it — missing glyphs drawn as hatched boxes. Only the scene needs to
  /// repaint on a tick, so only the scene listens.
  final ValueNotifier<double> _epoch = ValueNotifier<double>(0);

  // ---- Frame timing ------------------------------------------------------
  //
  // A frame counter says the city is slow; it does not say WHY. These split
  // the frame into the parts that can each be turned off, so the panel names
  // the culprit instead of implying one.
  final List<double> _frameMs = [];
  Duration _lastTick = Duration.zero;
  double _terrainMs = 0;
  double _cityMs = 0;

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

  /// Where the running build has got to. Null when nothing is building.
  CityGenProgress? _progress;

  /// Wall clock of the running build, so the readout is a measurement rather
  /// than the estimate it used to be.
  final Stopwatch _genClock = Stopwatch();
  String? _lastStats;
  bool _panel = true;

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
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _epoch.dispose();
    super.dispose();
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
    }
    _lastTick = elapsed;
    // Traffic off means a static frame, but the clock still ticks so the
    // counter keeps reading — a frozen number is worse than a slow one.
    _epoch.value = elapsed.inMicroseconds / 1e6;
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
    var step = 0;
    for (final p in build.run()) {
      if (!mounted) return;
      if (step++ % 6 == 0 || p.fraction >= 1.0) {
        setState(() => _progress =
            (phase: p.phase, fraction: p.fraction * buildShare));
        await Future<void>.delayed(Duration.zero);
      }
    }
    final sim = build.city!;

    setState(() =>
        _progress = (phase: 'cutting the ground', fraction: buildShare));
    await Future<void>.delayed(Duration.zero);

    // Shape the ground under it, exactly as the tick would.
    final edits = InMemoryTerrainEditsRepository();
    final body = system.body(sim.body.id)!;
    for (final p in const CityTerrainShaper().pending(
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

    final snap = WorldSnapshot.capture(
      1,
      InMemoryVesselRepository(const []),
      system: system,
      cities: InMemoryCityRepository([sim]),
      terrainEdits: edits,
    );
    sw.stop();
    _genClock.stop();

    // Calibrate: what this build ACTUALLY cost, per lot squared.
    final lots = sim.layout.parcels.length.toDouble();
    if (lots > 20) {
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
    final ground = field == null
        ? radial.length
        : field.groundRadiusAt(dir.x, dir.y, dir.z);
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
    if (_firstPerson) {
      final look = _walkerLook();
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
        fovNear: lengthToScene(0.15),
        fovFar: lengthToScene(40000),
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
      fovFar: lengthToScene(_distanceM * 20 + 20000),
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
          icon: Icon(_firstPerson ? Icons.videocam : Icons.directions_walk,
              color: _firstPerson ? AppTheme.accent2 : AppTheme.text),
          tooltip: _firstPerson
              ? 'Back to the orbit camera  (G)'
              : 'Walk the streets  (G) — WASD, shift to run, drag to look',
          onPressed: _sim == null ? null : () => setState(_toggleFirstPerson),
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
        final scene = _scene ??= fs.Scene();
        _city ??= CityNodes(scene);
        _terrain ??= TerrainNodes(scene);

        return ValueListenableBuilder<double>(
          valueListenable: _epoch,
          builder: (context, epoch, _) => _sceneStack(scene, epoch),
        );
      },
    );
  }

  Widget _sceneStack(fs.Scene scene, double epoch) {
    {
        final snap = _snap;
        if (snap != null) {
          // Advance the frame's clock so the traffic pass has something to
          // move against — it derives vehicle positions from the epoch.
          final frame = snap.copyWithEpoch(epoch);
          // Ground FIRST: the colony is cut into it, and without it the city
          // hangs in space with its levelled pads describing nothing.
          final sw = Stopwatch()..start();
          _phase(
              'terrain',
              () => _terrain!.update(
                    frame,
                    _origin,
                    cameraEye: _cameraEyeM(),
                    camera: null,
                    focusBodyId: _bodyIdOfFrame(frame),
                  ));
          _terrainMs = sw.elapsedMicroseconds / 1000;
          sw.reset();
          // The CAMERA, not the colony's centre. `_anchorWorld` is where the
          // city is, which never moves — so per-building LOD measured every
          // distance from the middle of town and never changed however far
          // the camera flew. `_cameraEyeM` is already in world axes about the
          // anchor, so this is the eye in world space.
          _phase(
              'city',
              () => _city!.update(frame, _origin,
                  focusWorld: _anchorWorld + _cameraEyeM()));
          _cityMs = sw.elapsedMicroseconds / 1000;
          _phase('scale rig', () => _syncRig(scene));
        }

        return Stack(children: [
          Positioned.fill(
            child: Focus(
              autofocus: true,
              onKeyEvent: _onKey,
              child: GestureDetector(
              onScaleStart: (_) => _dragBase = (_azimuth, _elevation),
              onScaleUpdate: (d) => setState(() {
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
                  if (e is PointerScrollEvent) {
                    setState(() => _distanceM =
                        (_distanceM * (1 + e.scrollDelta.dy * 0.0016))
                            .clamp(40.0, 60000.0));
                  }
                },
                // CHIRALITY: the app's world-to-scene mapping is a mirror the
                // renderer corrects by flipping the finished image. The studio
                // flips too, so what is tuned here is what the sim shows.
                child: Transform.flip(
                  flipX: true,
                  child: fs.SceneView(scene, camera: _camera()),
                ),
              ),
            ),
            ),
          ),
          if (_sim == null)
            const Center(
              child: Text('Set the knobs, then GENERATE.',
                  style: AppTheme.dim),
            ),
          if (_firstPerson)
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: AppTheme.panelBox(),
                  child: Text(
                      'WASD to walk · shift to run · drag to look · G to fly',
                      style: AppTheme.mono
                          .copyWith(fontSize: 11, color: AppTheme.textDim)),
                ),
              ),
            ),
          Positioned(left: 12, top: 12, child: _perfPanel()),
        ]);
    }
  }

  /// WASD while on foot. Held keys are tracked rather than acted on directly,
  /// so movement happens on the TICK — a key-repeat rate is not a frame rate,
  /// and driving the walker off one makes it stutter.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.keyG) {
      setState(_toggleFirstPerson);
      return KeyEventResult.handled;
    }
    if (!_firstPerson) return KeyEventResult.ignored;
    final move = {
      LogicalKeyboardKey.keyW,
      LogicalKeyboardKey.keyA,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyD,
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight,
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
    _firstPerson = !_firstPerson;
    _held.clear();
    if (_firstPerson) {
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
        row('FRAME',
            '${ms(avg)} ms  ${fps.toStringAsFixed(0)} fps',
            colour: fps < 30 ? AppTheme.danger : AppTheme.accent2),
        row('worst 90', '${ms(worst)} ms', colour: AppTheme.textDim),
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
            '  lod mix',
            [
              'full ${CityNodes.lodCounts[BuildingDetail.full] ?? 0}',
              'ext ${CityNodes.lodCounts[BuildingDetail.exterior] ?? 0}',
              'blk ${CityNodes.lodCounts[BuildingDetail.block] ?? 0}',
            ].join('  '),
            colour: (CityNodes.lodCounts[BuildingDetail.full] ?? 0) > 400
                ? AppTheme.danger
                : AppTheme.textDim),
        row('  rebuild', '${ms(phase['city.rebuild'] ?? 0)} ms',
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
        // The gap is the GPU plus Flutter's own frame — if it dominates, no
        // amount of CPU tuning here will help.
        row('unaccounted', '${ms((avg - accounted).clamp(0, 1e9))} ms',
            colour: AppTheme.warn),
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
            value: CityNodes.enabled,
            activeThumbColor: AppTheme.accent2,
            title: const Text('City (all of it)', style: AppTheme.body),
            onChanged: (v) => setState(() => CityNodes.enabled = v),
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
