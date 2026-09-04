// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Terrain on the operating table.
///
/// The city studio answers "what does a whole colony cost"; this screen
/// answers "what does the GROUND cost, one edit at a time". Every brush you
/// paint records a real [TerrainBrush] into a real edits repository and
/// recaptures a real snapshot — so each click exercises exactly the pipeline
/// a crater, a pad or a road corridor exercises in the game: the scoped
/// chunk invalidation, the forced refinement around edits, the drape
/// queries that march the brush list. The frame panel updates live, which
/// is the whole point: when terrain is slow, you can FEEL which act made it
/// slow, instead of deducing it from a finished colony's wreckage.
///
/// Roads and buildings here are the real machinery too — a [CitySim] takes
/// the commits, the shaper grades the ground under them — just placed by
/// hand, one at a time.
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
import '../../../domain/colony/city/city_building_spec.dart';
import '../../../domain/colony/city/city_config.dart';
import '../../../domain/colony/city/city_generator.dart';
import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/colony/city/city_terrain_shaper.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/shared/quaternion.dart';
import '../../../domain/shared/vector3.dart';
import '../../../domain/terrain/terrain_brush.dart';
import '../../../domain/terrain/terrain_field.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/universe/real_solar_system.dart';
import '../../../domain/universe/star_system.dart';
import '../../flutter_scene/atmosphere_nodes.dart';
import '../../flutter_scene/city/city_materials.dart';
import '../../flutter_scene/city/city_nodes.dart';
import '../../flutter_scene/coord_convert.dart';
import '../../flutter_scene/debug_camera_rig.dart';
import '../../flutter_scene/terrain/terrain_nodes.dart';
import 'app_theme.dart';

/// What a click on the ground does. [camera] is the hands-off mode: drags
/// orbit and clicks do nothing — every other tool CAPTURES the drag for
/// painting, so sculpting never wrestles the camera for the mouse.
enum TerrainTool {
  camera,
  raise,
  lower,
  flatten,
  crater,
  noise,
  erode,
  road,
  building,
}

class TerrainStudioScreen extends StatefulWidget {
  const TerrainStudioScreen({super.key});

  @override
  State<TerrainStudioScreen> createState() => _TerrainStudioScreenState();
}

class _TerrainStudioScreenState extends State<TerrainStudioScreen>
    with SingleTickerProviderStateMixin {
  static final Future<void> _staticInit = fs.Scene.initializeStaticResources();
  static final Future<void> _resourceInit = Future.wait([
    TerrainNodes.loadShader(),
    TerrainNodes.loadTextures(),
    AtmosphereNodes.loadShader(),
    CityMaterials.loadShader(),
  ]);
  late final Future<void> _ready = Future.wait([_staticInit, _resourceInit]);

  // ---- Site ---------------------------------------------------------------
  String _body = 'earth';
  static const List<String> _bodies = ['earth', 'moon', 'mars'];
  int _seed = 1;

  StarSystem? _system;
  CitySim? _sim;
  WorldSnapshot? _snap;
  InMemoryTerrainEditsRepository _edits = InMemoryTerrainEditsRepository();
  TerrainField? _groundField;
  int _tick = 1;

  // ---- Tools --------------------------------------------------------------
  TerrainTool _tool = TerrainTool.camera;
  double _radiusM = 40;
  double _strengthM = 12;

  /// Where the last stroke landed, for drag-paint spacing: a drag re-applies
  /// only after moving most of a radius, so a slow stroke is a line of
  /// brushes rather than a recapture per pointer event.
  Vector3? _lastPaintBF;

  /// Hover picking is a ray march through the edited field — against a
  /// thousand brushes that is real work — so the preview re-picks on a small
  /// clock, not on every pointer event.
  final Stopwatch _hoverSw = Stopwatch()..start();

  /// Grade the ground under roads and buildings, the way the tick would.
  bool _shapeGround = true;

  /// Evaluate terrain LOD against the FOCAL POINT instead of the camera.
  /// Zooming the camera out then stops coarsening the ground: selection
  /// keeps refining around the spot being worked, which is what lets you
  /// inspect a fine subdivision island from far enough away to see it
  /// whole. The trade is honest — the far field is now finer than the
  /// camera would ever ask for, so chunk counts rise.
  bool _lodFromFocus = false;

  /// Draw the focal-point marker and the per-level LOD transition rings.
  bool _showLodRings = true;

  /// Viewport height, captured each layout — the LOD probe's pixel budget
  /// and the ring radii both derive from it.
  double _viewportH = 600;
  final List<fs.Node> _ringNodes = [];
  String _ringsKey = '';

  /// The road being drawn: first click arms it, second commits.
  Vec2? _roadStart;

  // ---- Scene --------------------------------------------------------------
  fs.Scene? _scene;
  TerrainNodes? _terrain;
  CityNodes? _city;
  AtmosphereNodes? _atmo;
  final FloatingOrigin _origin = FloatingOrigin();
  Vector3 _anchorWorld = Vector3.zero;
  Vector3 _bodyCentreWorld = Vector3.zero;
  Vector3 _upWorld = Vector3.unitZ;
  double _sunTurnH = 0;
  bool _shadows = true;

  // ---- Camera -------------------------------------------------------------
  double _azimuth = 0.9;
  double _elevation = 0.55;
  double _distanceM = 1600;
  bool _firstPerson = false;
  double _walkE = 0, _walkN = 0, _walkYaw = 0, _walkPitch = 0;
  static const double _eyeHeightM = 1.7;
  static const double _walkSpeedMs = 2.0;
  static const double _runSpeedMs = 8.0;
  final Set<LogicalKeyboardKey> _held = {};

  /// The debug rig: freeze the lens the streamer selects and culls through
  /// (F), keep flying the camera, and draw the frozen lens as a frustum.
  final DebugCameraRig _rig = DebugCameraRig();
  DebugCameraGizmo? _rigGizmo;
  bool _showRig = true;
  double _viewportW = 800;

  // ---- Frame + timings ----------------------------------------------------
  final ValueNotifier<double> _epoch = ValueNotifier<double>(0);
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  final List<double> _frameMs = [];
  double _terrainMs = 0;
  double _cityMs = 0;

  /// What the LAST tool action cost, split into its two real halves: applying
  /// the edit to the sim/repo, and recapturing the snapshot (whose drape
  /// marches every brush — the documented killer once brushes pile up).
  double _applyMs = 0;
  double _captureMs = 0;

  final List<double> _uiMs = [];
  final List<double> _rasterMs = [];
  TimingsCallback? _timingsCb;
  int _censusDraws = 0, _censusInstances = 0, _censusNodes = 0;
  int _censusCountdown = 0;
  bool _panel = true;

  @override
  void initState() {
    super.initState();
    TerrainNodes.profile = true;
    _ticker = createTicker(_onFrame)..start();
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
  }

  @override
  void dispose() {
    // The cursor statics are shared with the flight editor — leave nothing
    // pointing at this screen's ground.
    CityNodes.cursorBF = null;
    CityNodes.pendingRouteBF = const [];
    final cb = _timingsCb;
    if (cb != null) SchedulerBinding.instance.removeTimingsCallback(cb);
    _ticker?.dispose();
    _epoch.dispose();
    super.dispose();
  }

  void _onFrame(Duration elapsed) {
    if (_scene == null || _snap == null) return;
    if (_lastTick != Duration.zero) {
      final dt = (elapsed - _lastTick).inMicroseconds / 1000.0;
      if (dt > 0 && dt < 500) {
        _frameMs.add(dt);
        if (_frameMs.length > 90) _frameMs.removeAt(0);
      }
      _stepWalker((dt / 1000.0).clamp(0.0, 0.1));
      _stepOrbit((dt / 1000.0).clamp(0.0, 0.1));
    }
    _lastTick = elapsed;
    _epoch.value = elapsed.inMicroseconds / 1e6;
    if (++_censusCountdown >= 30) {
      _censusCountdown = 0;
      _censusDraws = 0;
      _censusInstances = 0;
      _censusNodes = 0;
      final scene = _scene;
      if (scene != null) _censusWalk(scene.root);
    }
  }

  static double _avgOf(List<double> xs) =>
      xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;

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

  // ---- Site setup ---------------------------------------------------------

  /// Open a fresh site: bare ground, no edits, a bare [CitySim] waiting for
  /// hand-placed roads and buildings.
  void _openSite() {
    final system = RealSolarSystem.build();
    final bodies = system.all.where((b) => !b.isStar).toList();
    final body = bodies.firstWhere((b) => b.id.value == _body);
    final site = CityGenerator.dryLandNear(body, seed: _seed);
    final sim = CitySim.found(
      CityConfig(
        bodyId: _body,
        gridSize: 20,
        latitude: site.lat,
        longitude: site.lon,
      ),
      bodies: bodies,
      id: 'terrain-studio-$_seed',
      name: 'Terrain Studio $_seed',
    );
    sim.stock['ore'] = 1e9;
    sim.funds = 1e9;

    _system = system;
    _sim = sim;
    _edits = InMemoryTerrainEditsRepository();
    _tick = 1;
    _roadStart = null;
    _groundField = body.terrainFieldWith(null);
    _recapture();

    // Anchor on the real ground over the site centre — the same maths the
    // city studio's preview uses, for the same reason: the datum sphere can
    // sit hundreds of metres from the ground.
    final snap = _snap!;
    final b = snap.bodies[_body]!;
    final centreBF =
        sim.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: body.radius);
    final dir = centreBF.normalized;
    final field = _groundField;
    final anchorBF = dir *
        (field == null ? body.radius : field.groundRadiusAt(dir.x, dir.y, dir.z));
    final bodyCentre = Vector3(b.px, b.py, b.pz);
    _bodyCentreWorld = bodyCentre;
    _anchorWorld =
        bodyCentre + Quaternion(b.qw, b.qx, b.qy, b.qz).rotate(anchorBF);
    _origin.focusWorld = _anchorWorld;
    final radial = _anchorWorld - bodyCentre;
    _upWorld = radial.length > 1 ? radial.normalized : Vector3.unitZ;
    _walkE = 0;
    _walkN = 0;
    _focusLiftM = 0;
    _sunTurnH = _middayTurnH(snap, sim);
    setState(() {});
  }

  /// Recapture the frame — the act whose cost grows with the brush count.
  void _recapture() {
    final system = _system;
    final sim = _sim;
    if (system == null || sim == null) return;
    final sw = Stopwatch()..start();
    _snap = WorldSnapshot.capture(
      _tick++,
      InMemoryVesselRepository(const []),
      system: system,
      cities: InMemoryCityRepository([sim]),
      terrainEdits: _edits,
    );
    _captureMs = sw.elapsedMicroseconds / 1000;
    final body = system.body(sim.body.id)!;
    _groundField = body.terrainFieldWith(_edits.forBody(body.id));
  }

  // ---- Picking ------------------------------------------------------------

  /// The ground point under a screen tap, in BODY-FIXED metres, or null when
  /// the ray leaves without landing. Coarse march + bisect against the same
  /// edited field the walker samples.
  Vector3? _pickGroundBF(Offset local, Size size) {
    final sim = _sim;
    final snap = _snap;
    if (sim == null || snap == null || size.isEmpty) return null;
    final b = snap.bodies[_body];
    if (b == null) return null;
    final quat = Quaternion(b.qw, b.qx, b.qy, b.qz);

    final eyeWorld = _anchorWorld + _cameraEyeM();
    final Vector3 fwd;
    final Vector3 upCam;
    final double fovY;
    if (_firstPerson) {
      fwd = _walkerLook();
      final radial = eyeWorld - _bodyCentreWorld;
      upCam = radial.length > 1 ? radial.normalized : _upWorld;
      fovY = 0.9;
    } else {
      fwd = (_anchorWorld - eyeWorld).normalized;
      upCam = _upWorld;
      fovY = 0.8;
    }
    final right = fwd.cross(upCam).normalized;
    final upv = right.cross(fwd);
    final tanY = math.tan(fovY / 2);
    final tanX = tanY * size.width / size.height;
    // Screen X is NEGATED against the right vector: the engine's camera
    // basis is X-mirrored (see coord_convert.dart — the same mirror the
    // mesh builders flip their winding for), so a ray built right-handed
    // picked the ground on the wrong side of centre.
    final ndcX = -(local.dx / size.width * 2 - 1);
    final ndcY = 1 - local.dy / size.height * 2;
    final dir =
        (fwd + right * (ndcX * tanX) + upv * (ndcY * tanY)).normalized;

    final field = _groundField;
    if (field == null) return null;
    double altAt(double t) {
      final rel = eyeWorld + dir * t - _bodyCentreWorld;
      final bf = quat.conjugate.rotate(rel);
      final u = bf.normalized;
      return bf.length - field.groundRadiusAt(u.x, u.y, u.z);
    }

    var t = 0.0;
    var prevT = 0.0;
    var prevAlt = altAt(0);
    if (prevAlt <= 0) return null; // eye underground — nothing sensible
    for (var i = 0; i < 400 && t < 60000; i++) {
      t += math.max(prevAlt * 0.5, 1.5);
      final alt = altAt(t);
      if (alt <= 0) {
        // Bisect the crossing.
        var lo = prevT, hi = t;
        for (var k = 0; k < 24; k++) {
          final mid = (lo + hi) / 2;
          if (altAt(mid) > 0) {
            lo = mid;
          } else {
            hi = mid;
          }
        }
        final rel = eyeWorld + dir * hi - _bodyCentreWorld;
        return quat.conjugate.rotate(rel);
      }
      prevT = t;
      prevAlt = alt;
    }
    return null;
  }

  /// Body-fixed ground point -> the sim's local east/north plane. The inverse
  /// [CitySim.localToBodyFixed] never needed until a screen wanted to CLICK
  /// on the ground; a tangent-plane projection is exact enough at studio
  /// scale (kilometres against a planetary radius).
  Vec2 _bfToLocal(Vector3 bf) {
    final sim = _sim!;
    final lat = sim.cityLat * math.pi / 180.0;
    final lon = sim.cityLon * math.pi / 180.0;
    final up = Vector3(
        math.cos(lat) * math.cos(lon), math.cos(lat) * math.sin(lon), math.sin(lat));
    final east = Vector3(-math.sin(lon), math.cos(lon), 0);
    final north = up.cross(east);
    final body = _system!.body(_sim!.body.id)!;
    final centre = up * body.radius;
    final rel = bf - centre;
    return Vec2(rel.dot(east), rel.dot(north));
  }

  // ---- Tools --------------------------------------------------------------

  /// Whether the active tool paints on drag (everything but the modes with
  /// click semantics of their own).
  bool get _isBrush =>
      _tool != TerrainTool.camera &&
      _tool != TerrainTool.road &&
      _tool != TerrainTool.building;

  void _applyTool(Offset local, Size size) {
    if (_tool == TerrainTool.camera) return;
    final hitBF = _pickGroundBF(local, size);
    if (hitBF == null) return;
    _applyAt(hitBF);
  }

  /// A drag stroke: re-apply once the pointer has travelled most of a brush
  /// radius along the ground, so a slow stroke lays a LINE of brushes
  /// instead of a recapture per pointer event.
  void _dragPaint(Offset local, Size size) {
    final hitBF = _pickGroundBF(local, size);
    if (hitBF == null) return;
    _syncCursor(hitBF);
    final last = _lastPaintBF;
    if (last != null && (hitBF - last).length < math.max(_radiusM * 0.7, 6)) {
      return;
    }
    _applyAt(hitBF);
  }

  void _applyAt(Vector3 hitBF) {
    _lastPaintBF = hitBF;
    final sw = Stopwatch()..start();
    switch (_tool) {
      case TerrainTool.camera:
        return;
      case TerrainTool.raise:
        _pad(hitBF, _radiusM, _strengthM);
      case TerrainTool.lower:
        _pad(hitBF, _radiusM, -_strengthM);
      case TerrainTool.flatten:
        _pad(hitBF, _radiusM, 0);
      case TerrainTool.crater:
        _record(TerrainBrush.crater(
          contactBF: hitBF,
          normalBF: hitBF.normalized,
          radiusM: _radiusM,
          depthM: _strengthM,
          rimHeightM: _strengthM * 0.25,
          tick: _tick,
        ));
      case TerrainTool.noise:
        // A handful of small offset pads either way — cheap fractal detail,
        // and a pile of small brushes is exactly the load a colony's pads
        // put on the invalidation and refinement paths.
        final rnd = math.Random(hitBF.x.hashCode ^ _tick);
        for (var i = 0; i < 8; i++) {
          final a = rnd.nextDouble() * math.pi * 2;
          final r = math.sqrt(rnd.nextDouble()) * _radiusM;
          final off = _tangentOffset(hitBF, math.cos(a) * r, math.sin(a) * r);
          _pad(off, _radiusM * (0.2 + rnd.nextDouble() * 0.25),
              (rnd.nextDouble() - 0.5) * _strengthM);
        }
      case TerrainTool.erode:
        // Diffusion, crudely: pull ring samples toward the ring's mean, a
        // little downhill of it. Smooths ridges, softens brush scars.
        final field = _groundField;
        if (field == null) break;
        final rnd = math.Random(hitBF.y.hashCode ^ _tick);
        var mean = 0.0;
        final pts = <Vector3>[];
        for (var i = 0; i < 6; i++) {
          final a = i * math.pi / 3 + rnd.nextDouble() * 0.5;
          final p = _tangentOffset(hitBF, math.cos(a) * _radiusM * 0.6,
              math.sin(a) * _radiusM * 0.6);
          final u = p.normalized;
          mean += field.groundRadiusAt(u.x, u.y, u.z);
          pts.add(p);
        }
        mean /= 6;
        for (final p in pts) {
          final u = p.normalized;
          final g = field.groundRadiusAt(u.x, u.y, u.z);
          _record(
            TerrainBrush.pad(
              centreBF: u * g,
              radiusM: _radiusM * 0.45,
              datumRadiusM: g + (mean - g) * 0.55 - _strengthM * 0.05,
              falloffM: _radiusM * 0.35,
              tick: _tick,
            ),
          );
        }
      case TerrainTool.road:
        _placeRoad(hitBF);
      case TerrainTool.building:
        _placeBuilding(hitBF);
    }
    _applyMs = sw.elapsedMicroseconds / 1000;
    _recapture();
    setState(() {});
  }

  /// Point the editor cursor — the same ground quad the flight editor draws
  /// — at [hit], sized to the active brush. Null flags an un-pickable spot.
  void _syncCursor(Vector3? hit) {
    CityNodes.cursorBF = hit;
    CityNodes.cursorBodyId = _body;
    CityNodes.cursorBad = hit == null;
    final s = switch (_tool) {
      TerrainTool.building => 24.0,
      TerrainTool.road => 8.0,
      _ => _radiusM * 2,
    };
    CityNodes.cursorSizeM = s;
    CityNodes.cursorDepthM = _tool == TerrainTool.building ? 30.0 : s;

    // The road ghost: armed start to hover, on the real ground.
    final start = _roadStart;
    final field = _groundField;
    final sim = _sim;
    final system = _system;
    if (_tool == TerrainTool.road &&
        start != null &&
        hit != null &&
        field != null &&
        sim != null &&
        system != null) {
      final body = system.body(sim.body.id)!;
      final sDir = sim
          .localToBodyFixed(start, bodyRadiusM: body.radius)
          .normalized;
      CityNodes.pendingRouteBF = [
        sDir * field.groundRadiusAt(sDir.x, sDir.y, sDir.z),
        hit,
      ];
    } else {
      CityNodes.pendingRouteBF = const [];
    }
  }

  /// Hover: keep the preview under the mouse. Throttled — the pick marches
  /// the edited field, which is real work against a thousand brushes.
  void _updateHover(Offset local, Size size) {
    if (_snap == null || _tool == TerrainTool.camera) {
      _syncCursor(null);
      return;
    }
    if (_hoverSw.elapsedMilliseconds < 33) return;
    _hoverSw.reset();
    _syncCursor(_pickGroundBF(local, size));
  }

  /// A point [e]/[n] metres along the local tangent from [atBF], re-seated on
  /// its own radius so offsets stay on the shell.
  Vector3 _tangentOffset(Vector3 atBF, double e, double n) {
    final up = atBF.normalized;
    final seed = up.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
    final east = up.cross(seed).normalized;
    final north = up.cross(east);
    final p = atBF + east * e + north * n;
    return p.normalized * atBF.length;
  }

  /// A pad at [hitBF]'s own ground, datum shifted [deltaM]: positive mounds,
  /// negative digs, zero flattens.
  void _pad(Vector3 hitBF, double radiusM, double deltaM) {
    final field = _groundField;
    if (field == null) return;
    final u = hitBF.normalized;
    final g = field.groundRadiusAt(u.x, u.y, u.z);
    _record(
      TerrainBrush.pad(
        centreBF: u * g,
        radiusM: radiusM,
        datumRadiusM: g + deltaM,
        falloffM: math.max(6, radiusM * 0.4),
        maxCutM: math.max(20, deltaM.abs() * 2),
        tick: _tick,
      ),
    );
  }

  void _record(TerrainBrush brush) => _edits.record(_sim!.body.id, brush);

  void _placeRoad(Vector3 hitBF) {
    final sim = _sim!;
    final at = _bfToLocal(hitBF);
    final start = _roadStart;
    if (start == null) {
      _roadStart = at;
      return;
    }
    _roadStart = null;
    if ((at - start).length < 20) return;
    sim.commitRoad([start, at], RoadClass.street);
    if (_shapeGround) _shape();
  }

  void _placeBuilding(Vector3 hitBF) {
    final sim = _sim!;
    final at = _bfToLocal(hitBF);
    const hw = 12.0, hd = 15.0;
    final p = sim.layout.addManualParcel([
      Vec2(at.e - hw, at.n - hd),
      Vec2(at.e + hw, at.n - hd),
      Vec2(at.e + hw, at.n + hd),
      Vec2(at.e - hw, at.n + hd),
    ]);
    if (p == null) return;
    sim.placeOnParcel(p.id, kZoneSpecs['residential']![Density.medium]!);
    if (_shapeGround) _shape();
  }

  /// Grade the ground under everything not yet shaped — the tick's own
  /// incremental shaper, so a placed road costs here what it costs in game.
  void _shape() {
    final sim = _sim!;
    final body = _system!.body(sim.body.id)!;
    for (final p in const CityTerrainShaper().pending(
      sim,
      bodyRadiusM: body.radius,
      groundRadiusAt: (d) {
        final f = body.terrainFieldWith(_edits.forBody(body.id));
        return f == null ? body.radius : f.groundRadiusAt(d.x, d.y, d.z);
      },
    )) {
      _edits.record(body.id, p.brush);
      sim.shapedTerrain.add(p.key);
    }
  }

  /// Drop every edit and start the ground fresh — and exercise the terrain
  /// renderer's wholesale-invalidation path while doing it.
  void _clearEdits() {
    _edits = InMemoryTerrainEditsRepository();
    _sim?.shapedTerrain.clear();
    _recapture();
    setState(() {});
  }

  // ---- Sun (trimmed copy of the city studio's) ----------------------------

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

  WorldSnapshot _withSunTurned(WorldSnapshot frame) {
    if (_sunTurnH.abs() < 1e-3) return frame;
    final body = frame.bodies[_body];
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
      sprawlSections: frame.sprawlSections,
      sprawlRoads: frame.sprawlRoads,
      sprawlNodes: frame.sprawlNodes,
      sprawlClearings: frame.sprawlClearings,
    );
  }

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

  static const double _sunIntensity = 2.2;

  void _syncSun(fs.Scene scene, Vector3? starWorld) {
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
    var light = scene.directionalLight;
    if (light == null) {
      light = fs.DirectionalLight(direction: dir, intensity: _sunIntensity);
      scene.directionalLight = light;
    } else {
      light.direction = dir;
      light.intensity = _sunIntensity;
    }
    final eyeWorld = _anchorWorld + _cameraEyeM();
    final groundR = (_anchorWorld - _bodyCentreWorld).length;
    final altM =
        groundR < 1 ? 0.0 : (eyeWorld - _bodyCentreWorld).length - groundR;
    if (!_shadows || groundR < 1 || altM > 8000) {
      light.castsShadow = false;
      return;
    }
    light.castsShadow = true;
    light.shadowCasterFaces = fs.ShadowCasterFaces.back;
    light.shadowCascadeCount = 2;
    final rangeM = (altM * 3.0 + 300.0).clamp(300.0, 6000.0);
    light.shadowMaxDistance = lengthToScene(rangeM);
    light.shadowFadeRange = lengthToScene(rangeM * 0.12);
    light.shadowMapResolution = 2048;
    light.shadowSoftness = lengthToScene(1.5);
    light.shadowNormalBias = lengthToScene(1.0);
    light.shadowDepthBias = lengthToScene(1.0);
  }

  // ---- Camera (the city studio's, verbatim where possible) ----------------

  (Vector3 east, Vector3 north) _tangentFrame() {
    final seed = _upWorld.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
    final east = _upWorld.cross(seed).normalized;
    return (east, _upWorld.cross(east));
  }

  Vector3 _cameraEyeM() {
    if (_firstPerson) return _walkerEyeM();
    final (east, north) = _tangentFrame();
    final ce = math.cos(_elevation), se = math.sin(_elevation);
    final dir = east * (math.cos(_azimuth) * ce) +
        north * (math.sin(_azimuth) * ce) +
        _upWorld * se;
    return dir * _distanceM;
  }

  Vector3 _walkerEyeM() {
    final (east, north) = _tangentFrame();
    final flat = _anchorWorld + east * _walkE + north * _walkN;
    final radial = flat - _bodyCentreWorld;
    if (radial.length < 1) return _upWorld * _eyeHeightM;
    final dir = radial.normalized;
    final field = _groundField;
    final b = _snap?.bodies[_body];
    var ground = radial.length;
    if (field != null && b != null) {
      final bf = Quaternion(b.qw, b.qx, b.qy, b.qz).conjugate.rotate(dir);
      ground = field.groundRadiusAt(bf.x, bf.y, bf.z);
    }
    return _bodyCentreWorld + dir * (ground + _eyeHeightM) - _anchorWorld;
  }

  Vector3 _walkerLook() {
    final (east, north) = _tangentFrame();
    final radial =
        (_anchorWorld + east * _walkE + north * _walkN) - _bodyCentreWorld;
    final up = radial.length < 1 ? _upWorld : radial.normalized;
    final fwd = (north * math.cos(_walkYaw) + east * math.sin(_walkYaw));
    final flat = (fwd - up * fwd.dot(up));
    final ahead = flat.length < 1e-9 ? north : flat.normalized;
    final cp = math.cos(_walkPitch), sp = math.sin(_walkPitch);
    return (ahead * cp + up * sp).normalized;
  }

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
    final cy = math.cos(_walkYaw), sy = math.sin(_walkYaw);
    _walkN += (fwd * cy - side * sy) * step;
    _walkE += (fwd * sy + side * cy) * step;
  }

  /// How far the orbit focus floats above the ground, metres. Q/E drive it;
  /// zero is the surface.
  double _focusLiftM = 0;

  /// WASD pans the orbit FOCAL POINT across the ground, screen-relative;
  /// Q/E lower and raise its ALTITUDE over the ground. The anchor is the
  /// render origin, so moving it drags everything measured against it —
  /// picking, the sun, the atmosphere, the terrain streamer's focus — along
  /// for free. Both rates scale with zoom: crossing the view, or doubling
  /// your height, takes about the same wrist at any range.
  void _stepOrbit(double dtS) {
    if (_firstPerson || _snap == null || _held.isEmpty) return;
    var fwd = 0.0, side = 0.0, lift = 0.0;
    if (_held.contains(LogicalKeyboardKey.keyW)) fwd += 1;
    if (_held.contains(LogicalKeyboardKey.keyS)) fwd -= 1;
    if (_held.contains(LogicalKeyboardKey.keyD)) side += 1;
    if (_held.contains(LogicalKeyboardKey.keyA)) side -= 1;
    if (_held.contains(LogicalKeyboardKey.keyQ)) lift -= 1;
    if (_held.contains(LogicalKeyboardKey.keyE)) lift += 1;
    if (fwd == 0 && side == 0 && lift == 0) return;
    if (lift != 0) {
      _focusLiftM =
          (_focusLiftM + lift * _distanceM * 0.4 * dtS).clamp(0.0, 50000.0);
    }

    final (east, north) = _tangentFrame();
    // W pushes the focus AWAY from the camera; screen-right comes from the
    // same X-mirrored basis the pick ray corrects for (up cross forward).
    final ahead =
        (east * -math.cos(_azimuth) + north * -math.sin(_azimuth));
    final rightD = _upWorld.cross(ahead);
    final len = math.max(1.0, math.sqrt(fwd * fwd + side * side));
    final move = (ahead * fwd + rightD * side) *
        (_distanceM * 0.6 * dtS / len);

    // Re-seat over the real ground under the new spot — the walker's own
    // body-fixed sampling — then float the lift above it.
    final next = _anchorWorld + move;
    final radial = next - _bodyCentreWorld;
    if (radial.length > 1) {
      final dir = radial.normalized;
      final b = _snap?.bodies[_body];
      final field = _groundField;
      var ground = radial.length - _focusLiftM;
      if (b != null && field != null) {
        final bf = Quaternion(b.qw, b.qx, b.qy, b.qz).conjugate.rotate(dir);
        ground = field.groundRadiusAt(bf.x, bf.y, bf.z);
      }
      _anchorWorld = _bodyCentreWorld + dir * (ground + _focusLiftM);
      _origin.focusWorld = _anchorWorld;
      _upWorld = dir;
    }
  }

  /// What the streamers look through this frame when the rig is live: the
  /// probe eye (focus-relative; the focal point itself under LOD-from-focus),
  /// the view direction, and screen up — the same numbers [_camera] renders
  /// with, so a freeze captures exactly the lens in use.
  ({Vector3 eyeRel, Vector3 forward, Vector3 up}) _liveLens() {
    final eyeM = _cameraEyeM();
    final eyeRel = _lodFromFocus ? Vector3.zero : eyeM;
    if (_firstPerson) {
      final radial = (_anchorWorld + eyeM) - _bodyCentreWorld;
      return (
        eyeRel: eyeRel,
        forward: _walkerLook(),
        up: radial.length < 1 ? _upWorld : radial.normalized,
      );
    }
    return (
      eyeRel: eyeRel,
      forward: eyeM.length > 1 ? eyeM.normalized * -1 : Vector3.unitZ,
      up: _upWorld,
    );
  }

  Quaternion _bodyQuat(WorldSnapshot snap) {
    final b = snap.bodies[_body];
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
          fovRadiansY: _firstPerson ? 0.9 : 0.8,
          aspect: _viewportW / _viewportH,
          bodyCentreWorld: _bodyCentreWorld,
          bodyQuat: _bodyQuat(snap),
        ));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.keyG && _snap != null) {
        setState(() => _firstPerson = !_firstPerson);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyF && _snap != null) {
        _toggleRigFreeze();
        return KeyEventResult.handled;
      }
      _held.add(event.logicalKey);
    } else if (event is KeyUpEvent) {
      _held.remove(event.logicalKey);
    }
    return KeyEventResult.ignored;
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
        fovNear: lengthToScene(0.15),
        fovFar: lengthToScene(400000),
      );
    }
    final target = vm.Vector3.zero();
    return fs.PerspectiveCamera(
      fovRadiansY: 0.8,
      position: target + vm.Vector3(eye.x, eye.y, eye.z) * kRenderScale,
      target: target,
      up: vm.Vector3(_upWorld.x, _upWorld.y, _upWorld.z),
      fovNear: lengthToScene(math.max(_distanceM * 0.01, 1.0)),
      fovFar: lengthToScene(math.max(_distanceM * 20 + 20000, 400000)),
    );
  }

  // ---- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return AppTheme.scaffold(
      context: context,
      title: 'TERRAIN STUDIO',
      accentColor: AppTheme.accent2,
      actions: [
        IconButton(
          icon: Icon(_firstPerson ? Icons.videocam : Icons.directions_walk,
              color: _firstPerson ? AppTheme.accent2 : AppTheme.text),
          tooltip: _firstPerson
              ? 'Back to the orbit camera  (G)'
              : 'Walk the ground  (G) — WASD, shift to run, drag to look',
          onPressed: _snap == null
              ? null
              : () => setState(() => _firstPerson = !_firstPerson),
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
        if (_panel) SizedBox(width: 340, child: _controls()),
      ]),
    );
  }

  Widget _preview() {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
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
        final scene = _scene ??= (fs.Scene()..environmentIntensity = 0.05);
        _terrain ??= TerrainNodes(scene);
        _city ??= CityNodes(scene);
        _atmo ??= AtmosphereNodes(scene);
        return ValueListenableBuilder<double>(
          valueListenable: _epoch,
          builder: (context, epoch, _) => _sceneStack(scene, epoch),
        );
      },
    );
  }

  Widget _sceneStack(fs.Scene scene, double epoch) {
    final snap = _snap;
    final cam = _camera();
    if (snap != null) {
      final frame = _withSunTurned(snap.copyWithEpoch(epoch));
      final starWorld = _starWorld(frame);
      final sw = Stopwatch()..start();
      // LOD-from-focus: hand the streamer a zero eye offset, so every
      // distance it budgets against is measured from the focal point the
      // WASD keys carry — the camera can then stand back to watch the
      // subdivision it would otherwise collapse by looking at it.
      //
      // The probe CAMERA is what was missing before: with `camera: null`
      // the screen-space budget returned zero pixels for everything, so
      // nothing ever split except forced-refinement islands — detail was a
      // cliff at the edit-refine range and root-coarse beyond it. The probe
      // gives selection a real projection to budget against, and splitPx
      // (the slider below) is its whole personality.
      //
      // The rig sits between: frozen, it hands back the lens pinned by F
      // instead of the live one, and the camera is free to go and look at
      // what that lens selected.
      final lens = _liveLens();
      final bodyQuat = _bodyQuat(frame);
      final probe = _rig.probe(
        liveEyeRel: lens.eyeRel,
        liveForward: lens.forward,
        liveFocalPx: _focalPx,
        focusWorld: _origin.focusWorld,
        bodyCentreWorld: _bodyCentreWorld,
        bodyQuat: bodyQuat,
      );
      _terrain!.update(
        frame,
        _origin,
        cameraEye: probe.eyeRel,
        camera: probe,
        focusBodyId: _body,
        starWorld: starWorld,
      );
      _terrainMs = sw.elapsedMicroseconds / 1000;
      sw.reset();
      _city!.update(frame, _origin, focusWorld: _anchorWorld + _cameraEyeM());
      _cityMs = sw.elapsedMicroseconds / 1000;
      _syncSun(scene, starWorld);
      _atmo!.update(frame, _origin,
          cameraEye: _cameraEyeM(), starWorld: starWorld);
      _syncLodRings(scene);
      // The frozen lens, drawn for the RENDER camera. Frustum length scales
      // with the frozen eye's height so it reads at any altitude.
      if (_rigGizmo?.scene != scene) _rigGizmo = DebugCameraGizmo(scene);
      var farM = 2000.0;
      if (_rig.frozen) {
        final eyeW = _rig.frozenEyeWorld(
            bodyCentreWorld: _bodyCentreWorld, bodyQuat: bodyQuat);
        final altM = (eyeW - _bodyCentreWorld).length -
            (_anchorWorld - _bodyCentreWorld).length;
        farM = (altM.abs() * 3).clamp(300.0, 40000.0);
      }
      _rigGizmo!.sync(
        _rig,
        focusWorld: _origin.focusWorld,
        renderCamera: cam,
        viewport: Size(_viewportW, _viewportH),
        visible: _showRig,
        bodyCentreWorld: _bodyCentreWorld,
        bodyQuat: bodyQuat,
        farM: farM,
      );
    }

    return Stack(children: [
      Positioned.fill(
        child: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: LayoutBuilder(builder: (context, constraints) {
            final size = constraints.biggest;
            _viewportH = math.max(1, size.height);
            _viewportW = math.max(1, size.width);
            return Listener(
              onPointerSignal: (e) {
                if (e is PointerScrollEvent && !_firstPerson) {
                  setState(() => _distanceM = (_distanceM *
                          (e.scrollDelta.dy > 0 ? 1.15 : 1 / 1.15))
                      .clamp(60.0, 60000.0));
                }
              },
              child: MouseRegion(
                onHover: (e) => _updateHover(e.localPosition, size),
                onExit: (_) => _syncCursor(null),
                child: GestureDetector(
                onTapUp: (d) {
                  if (_snap != null) _applyTool(d.localPosition, size);
                },
                onScaleEnd: (_) => _lastPaintBF = null,
                onScaleUpdate: (d) {
                  // Walk mode always looks with the mouse; otherwise a drag
                  // belongs to the camera ONLY in camera mode — the paint
                  // tools own it, which is what stops a stroke orbiting the
                  // world out from under the brush.
                  if (_firstPerson) {
                    setState(() {
                      _walkYaw += d.focalPointDelta.dx * 0.004;
                      _walkPitch = (_walkPitch - d.focalPointDelta.dy * 0.004)
                          .clamp(-1.45, 1.45);
                    });
                  } else if (_tool == TerrainTool.camera) {
                    setState(() {
                      _azimuth -= d.focalPointDelta.dx * 0.008;
                      _elevation = (_elevation + d.focalPointDelta.dy * 0.008)
                          .clamp(0.08, 1.5);
                    });
                  } else if (_isBrush && _snap != null) {
                    _dragPaint(d.localFocalPoint, size);
                  }
                },
                child: _snap == null
                    ? Center(
                        child: Text(
                            'Pick a world, then OPEN SITE.\n'
                            'Click the ground to use the active tool.',
                            style: AppTheme.dim,
                            textAlign: TextAlign.center))
                    : fs.SceneView(scene, camera: cam),
                ),
              ),
            );
          }),
        ),
      ),
      Positioned(left: 10, top: 10, child: _perfPanel()),
    ]);
  }

  /// The probe's pixel budget: half the viewport over the tangent of half
  /// the field of view — a sphere of radius r at distance d projects
  /// r * this / d pixels tall.
  double get _focalPx =>
      _viewportH * 0.5 / math.tan((_firstPerson ? 0.9 : 0.8) / 2);

  /// The focal-point marker and the LOD transition rings, draped on the
  /// ground around the focus.
  ///
  /// Each ring sits where a chunk of one LEVEL projects exactly [splitPx]
  /// pixels — cross a ring moving inward and that level's chunks split.
  /// With the ring set on screen, "high detail to nothing" stops being a
  /// mystery: either the rings are bunched close in (raise the split
  /// budget, or the level cap is biting) or the ground is refusing to
  /// follow them (streaming, not selection). Rebuilt only when a knob, the
  /// viewport, the zoom bucket or the focus moves.
  void _syncLodRings(fs.Scene scene) {
    final key = !_showLodRings || _snap == null
        ? 'off'
        : '${TerrainNodes.splitPx.round()}|${_viewportH.round()}'
            '|${_firstPerson ? 1 : 0}'
            '|${(_anchorWorld.x / 5).round()},${(_anchorWorld.y / 5).round()},'
            '${(_anchorWorld.z / 5).round()}'
            '|${(math.log(_distanceM) / math.ln2).round()}'
            '|${identityHashCode(_rig.pose)}';
    if (key == _ringsKey) return;
    _ringsKey = key;
    for (final n in _ringNodes) {
      scene.remove(n);
    }
    _ringNodes.clear();
    if (key == 'off') return;

    final b = _snap!.bodies[_body];
    final field = _groundField;
    if (b == null || field == null) return;
    final quat = Quaternion(b.qw, b.qx, b.qy, b.qz);
    final (east, north) = _tangentFrame();
    // The rings stay on the focal point whatever the rig does — pressing F
    // must move nothing on the ground. What the pin changes is the pixel
    // budget the radii are derived from: the frozen lens's, not the live
    // camera's, so zooming the free camera no longer re-spaces them.
    final focal = _rig.pose?.focalPx ?? _focalPx;

    // Anchor-relative metres, re-seated on the real ground plus a lift.
    Vector3 drape(Vector3 offset, double liftM) {
      final p = _anchorWorld + offset;
      final radial = p - _bodyCentreWorld;
      final dir = radial.length > 1 ? radial.normalized : _upWorld;
      final bf = quat.conjugate.rotate(dir);
      final g = field.groundRadiusAt(bf.x, bf.y, bf.z);
      return _bodyCentreWorld + dir * (g + liftM) - _anchorWorld;
    }

    final m = MeshBuilder();
    const u = 5.5 / kGroundSwatches; // the cursor-cyan swatch
    void quadBothSides(Vector3 a, Vector3 b2, Vector3 c, Vector3 d) {
      final i = [
        for (final p in [a, b2, c, d])
          m.vertex(p * kRenderScale, _upWorld, u, 0.5)
      ];
      m.quad(i[0], i[1], i[2], i[3]);
      m.quad(i[3], i[2], i[1], i[0]);
    }

    // The marker: a mast at the focus, sized to the view.
    final mastH = (_distanceM * 0.05).clamp(3.0, 500.0);
    final mastW = mastH * 0.02;
    final base = drape(Vector3.zero, 0);
    for (final axis in [east, north]) {
      final w = axis * mastW;
      quadBothSides(base - w, base + w, base + w + _upWorld * mastH,
          base - w + _upWorld * mastH);
    }

    // One ring per level: the distance at which a level-L chunk projects
    // splitPx pixels. Circumradius approximated as 1.2 R / 2^L — a
    // diagnostic marker, not a survey.
    for (var level = 2; level <= 12; level++) {
      final rL = field.radius * 1.2 / math.pow(2, level);
      final dL = rL * focal / TerrainNodes.splitPx;
      if (dL < 10 || dL > 120000) continue;
      final halfW = math.max(dL * 0.006, 0.5);
      const segs = 64;
      for (var s = 0; s < segs; s++) {
        final a0 = s * 2 * math.pi / segs;
        final a1 = (s + 1) * 2 * math.pi / segs;
        Vector3 rim(double a, double d) =>
            east * (math.cos(a) * d) + north * (math.sin(a) * d);
        final lift = 2.0 + dL * 0.001;
        quadBothSides(
          drape(rim(a0, dL - halfW), lift),
          drape(rim(a0, dL + halfW), lift),
          drape(rim(a1, dL + halfW), lift),
          drape(rim(a1, dL - halfW), lift),
        );
      }
    }

    final mesh = m.build();
    final geometry = CityNodes.geometryOf(mesh);
    if (geometry == null) return;
    final node = fs.Node(
      mesh: fs.Mesh.primitives(primitives: [
        fs.MeshPrimitive(geometry, CityMaterials.ground),
      ]),
    );
    scene.add(node);
    _ringNodes.add(node);
  }

  // ---- Panels -------------------------------------------------------------

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
    final accounted = _terrainMs + _cityMs;

    Widget row(String label, String value, {Color? colour}) => Text(
        '${label.padRight(15)}$value',
        style:
            AppTheme.mono.copyWith(fontSize: 11, color: colour ?? AppTheme.text));

    var brushes = 0;
    final snap = _snap;
    if (snap != null) {
      for (final e in snap.terrainEdits) {
        if (e.body == _body) brushes++;
      }
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.panelBox(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        row('FRAME', '${ms(avg)} ms  ${fps.toStringAsFixed(0)} fps',
            colour: fps < 30 ? AppTheme.danger : AppTheme.accent2),
        row('worst 90', '${ms(worst)} ms', colour: AppTheme.textDim),
        row('ui build', '${ms(_avgOf(_uiMs))} ms', colour: AppTheme.textDim),
        row('raster', '${ms(_avgOf(_rasterMs))} ms',
            colour: _avgOf(_rasterMs) > 16 ? AppTheme.warn : AppTheme.textDim),
        row('scene draws',
            '$_censusDraws  ($_censusInstances inst, $_censusNodes nodes)',
            colour: AppTheme.accent),
        row('lod camera', _rig.frozen ? 'FROZEN  (F releases)' : 'live',
            colour: _rig.frozen ? AppTheme.warn : AppTheme.textDim),
        const SizedBox(height: 6),
        row('terrain', '${ms(_terrainMs)} ms',
            colour: _terrainMs > 4 ? AppTheme.warn : AppTheme.text),
        if (TerrainNodes.profileLine.isNotEmpty)
          Text('  ${TerrainNodes.profileLine.replaceFirst('terrain: ', '')}',
              style:
                  AppTheme.mono.copyWith(fontSize: 10, color: AppTheme.textDim)),
        if (TerrainNodes.debugLine.isNotEmpty)
          Text('  ${TerrainNodes.debugLine.replaceFirst('terrain: ', '')}',
              style:
                  AppTheme.mono.copyWith(fontSize: 10, color: AppTheme.textDim)),
        if (TerrainNodes.levelHistogramLine.isNotEmpty)
          Text('  lvls: ${TerrainNodes.levelHistogramLine}',
              style:
                  AppTheme.mono.copyWith(fontSize: 10, color: AppTheme.textDim)),
        row('  chunks', '${TerrainNodes.counters['chunks'] ?? 0}',
            colour: AppTheme.textDim),
        row('  brushes', '$brushes',
            colour: brushes > 400 ? AppTheme.danger : AppTheme.textDim),
        row('  forced refine',
            '${TerrainNodes.counters['refineTargets'] ?? 0}',
            colour: (TerrainNodes.counters['refineTargets'] ?? 0) > 2000
                ? AppTheme.danger
                : AppTheme.textDim),
        row('  near brushes', '${TerrainNodes.counters['nearBrushes'] ?? 0}',
            colour: AppTheme.textDim),
        row('city', '${ms(_cityMs)} ms'),
        row('last apply', '${ms(_applyMs)} ms', colour: AppTheme.textDim),
        row('last capture', '${ms(_captureMs)} ms',
            colour: _captureMs > 100 ? AppTheme.warn : AppTheme.textDim),
        row('unaccounted', '${ms((avg - accounted).clamp(0, 1e9))} ms',
            colour: AppTheme.warn),
      ]),
    );
  }

  Widget _controls() {
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
          ElevatedButton.icon(
            icon: const Icon(Icons.terrain),
            label: const Text('OPEN SITE'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accent2,
              foregroundColor: AppTheme.bg,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: _openSite,
          ),
          const SizedBox(height: 12),
          const Text('TOOL', style: AppTheme.heading),
          Text(
              'WASD pans the focus, Q/E lowers/raises its altitude, scroll '
              'zooms — any tool. camera: drag orbits. Brushes: hover '
              'previews the footprint, click applies, drag paints a stroke. '
              'Road takes two clicks and ghosts the run.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in TerrainTool.values)
              ChoiceChip(
                label: Text(t.name, style: const TextStyle(fontSize: 12)),
                selected: _tool == t,
                selectedColor: AppTheme.accent2,
                backgroundColor: AppTheme.panelLight,
                onSelected: (_) => setState(() {
                  _tool = t;
                  _roadStart = null;
                }),
              ),
          ]),
          _slider('Radius', _radiusM, 5, 200,
              'Brush footprint on the ground, metres.',
              (v) => setState(() => _radiusM = v), unit: 'm'),
          _slider('Strength', _strengthM, 1, 40,
              'Metres of lift, cut, crater depth, or noise amplitude.',
              (v) => setState(() => _strengthM = v), unit: 'm'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _shapeGround,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Grade under placements', style: AppTheme.body),
            subtitle: Text(
                'Run the tick\'s terrain shaper after each road or building '
                '— one brush per pad, one per 24 m of corridor. THIS is '
                'where a colony\'s brush count comes from.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() => _shapeGround = v),
          ),
          TextButton.icon(
            icon: const Icon(Icons.delete_sweep, color: AppTheme.warn),
            label:
                const Text('Clear all edits', style: TextStyle(color: AppTheme.warn)),
            onPressed: _snap == null ? null : _clearEdits,
          ),
          const SizedBox(height: 8),
          const Text('LIGHTING', style: AppTheme.heading),
          _slider('Sun time', _sunTurnH, -12, 12,
              'Hours around the captured moment.',
              (v) => setState(() => _sunTurnH = v), unit: 'h'),
          const SizedBox(height: 8),
          const Text('TERRAIN DIALS', style: AppTheme.heading),
          Text('The knobs that decide what an edit costs the renderer.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          _slider('LOD split budget', TerrainNodes.splitPx, 60, 600,
              'Split a chunk once it projects wider than this many pixels. '
                  'Lower = finer ground further out; the rings redraw to '
                  'match.',
              (v) => setState(() => TerrainNodes.splitPx = v), unit: 'px'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _showLodRings,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Focus marker + LOD rings', style: AppTheme.body),
            subtitle: Text(
                'A mast at the focal point, and one draped ring per level at '
                'the distance where that level\'s chunks split. Rings '
                'bunched close in = the split budget is starving detail; '
                'ground ignoring them = streaming, not selection.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() => _showLodRings = v),
          ),
          _slider('LOD level step', TerrainNodes.levelStep.toDouble(), 0, 8,
              'Levels a streaming pass may climb at once.',
              (v) => setState(() => TerrainNodes.levelStep = v.round()),
              divisions: 8),
          _slider('Edit refine range', TerrainNodes.editRefineRangeM / 1000,
              0.5, 20,
              'How far out an edit still forces deep chunks.',
              (v) => setState(() => TerrainNodes.editRefineRangeM = v * 1000),
              unit: 'km'),
          _slider('Edit voxels across', TerrainNodes.editVoxelsAcross, 2, 12,
              'Voxels demanded across each edit.',
              (v) => setState(() => TerrainNodes.editVoxelsAcross = v),
              divisions: 10),
          const SizedBox(height: 8),
          const Text('ISOLATE', style: AppTheme.heading),
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
            value: _lodFromFocus,
            activeThumbColor: AppTheme.accent2,
            title: const Text('LOD from focus', style: AppTheme.body),
            subtitle: Text(
                'Evaluate terrain LOD at the focal point instead of the '
                'camera — zooming out stops coarsening the ground, so a '
                'refinement island can be inspected from far enough away '
                'to see it whole.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() => _lodFromFocus = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _rig.frozen,
            activeThumbColor: AppTheme.warn,
            title: const Text('Freeze LOD camera  (F)', style: AppTheme.body),
            subtitle: Text(
                'Pin the lens the streamer selects and culls through where '
                'the camera stands now, then fly the camera away to watch '
                'what it chose — the horizon cull, the resident set — from '
                'outside. The focal point and rings stay put; LOD-from-focus '
                'is baked into the pin.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (_) => _toggleRigFreeze(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _showRig,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Draw frozen camera', style: AppTheme.body),
            subtitle: Text(
                'Frustum (cyan), view axis (yellow) and eye cross of the '
                'frozen lens.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() => _showRig = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: TerrainNodes.gridOnly,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Quadtree grid only', style: AppTheme.body),
            subtitle: Text(
                'Hide the ground, draw every selected chunk as its wireframe '
                'patch, coloured by level (coarse blue, deep red). Streaming '
                'keeps running — what appears and vanishes IS the selection '
                'deciding.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            onChanged: (v) => setState(() => TerrainNodes.gridOnly = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: CityNodes.enabled,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Roads + buildings', style: AppTheme.body),
            onChanged: (v) => setState(() => CityNodes.enabled = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _shadows,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Shadows', style: AppTheme.body),
            onChanged: (v) => setState(() => _shadows = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: !AtmosphereNodes.hidden,
            activeThumbColor: AppTheme.accent2,
            title: const Text('Atmosphere', style: AppTheme.body),
            onChanged: (v) => setState(() => AtmosphereNodes.hidden = !v),
          ),
        ],
      ),
    );
  }

  Widget _slider(String label, double value, double lo, double hi, String hint,
      ValueChanged<double> onCh,
      {int? divisions, String unit = ''}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(label, style: AppTheme.body)),
        Text('${value.toStringAsFixed(unit == 'm' || unit == 'h' ? 0 : 1)}'
            '$unit',
            style: AppTheme.mono.copyWith(fontSize: 12)),
      ]),
      Slider(
        value: value.clamp(lo, hi),
        min: lo,
        max: hi,
        divisions: divisions,
        activeColor: AppTheme.accent2,
        onChanged: onCh,
      ),
      Text(hint, style: AppTheme.dim.copyWith(fontSize: 11)),
      const SizedBox(height: 6),
    ]);
  }
}

// The LOD probe camera lives in flutter_scene/lod_probe_camera.dart now,
// shared with the city studio.
