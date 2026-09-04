// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:async' show StreamSubscription, unawaited;
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' as ui show Image;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/gestures.dart'
    show
        PointerScrollEvent,
        ScaleGestureRecognizer,
        kMiddleMouseButton,
        kPrimaryButton;
import 'package:flutter/services.dart'
    show
        HardwareKeyboard,
        LogicalKeyboardKey,
        KeyEvent,
        KeyDownEvent,
        KeyUpEvent;

import '../../domain/autonomy/pilot_input.dart';
import '../../domain/autonomy/landing_target.dart';
import '../../domain/colony/city/city_building_spec.dart';
import '../../domain/colony/city/city_config.dart';
import '../../domain/colony/city/city_sim.dart';
import '../../domain/colony/city/parcel.dart';
import '../../adapters/presenters/surface_picker.dart';
import '../flutter_scene/city/city_nodes.dart';
import 'flight_session.dart';
import 'screens/city_edit_overlay.dart';
import 'screens/city_site_actions.dart';
import 'screens/craft_assembly_screen.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';

import '../../adapters/presenters/camera_ground_clamp.dart';
import '../../adapters/presenters/first_person_walker.dart';
import '../../adapters/presenters/top_down_snapshot.dart';
import '../../adapters/wire/flatbuffer_codec.dart';
import '../../application/snapshot/world_snapshot.dart';
import '../../domain/multiplayer/command.dart';
import '../bridge/sim_bridge.dart';
import '../../adapters/repositories/in_memory_repositories.dart';
import '../../adapters/repositories/in_memory_world_repositories.dart';
import '../../application/persistence/game_state_codec.dart';
import '../../application/snapshot/planner_overlay.dart';
import '../../application/usecases/advance_simulation_tick.dart';
import '../../domain/autonomy/flight_plan.dart' show ManeuverNode;
import '../../domain/dynamics/state_vector.dart';
import '../../domain/orbits/encounter_planner.dart';
import '../../domain/orbits/patched_conic_service.dart' show PatchEndKind;
import '../../adapters/presenters/eva_pack.dart';
import '../../domain/mining/hand_drill.dart';
import '../../domain/orbits/spawn_presets.dart';
import '../../domain/orbits/state_vector_converter.dart';
import '../../domain/simulation/epoch.dart';
import '../../domain/science/research_ledger.dart';
import '../../domain/simulation/simulation_clock.dart';
import '../../domain/simulation/domain_event.dart';
import '../../domain/planetary/atmospheric_composition.dart';
import '../../domain/universe/celestial_body.dart' show BodyId, CelestialBody;
import '../../domain/vessel/part.dart';
import '../../domain/vessel/stage.dart';
import '../../domain/vessel/vessel.dart';
import '../sample_world.dart';
import '../flutter_scene/atmosphere_nodes.dart';
import '../flutter_scene/cloud_nodes.dart';
import '../flutter_scene/environment_baker.dart';
import '../flutter_scene/gravity_grid_nodes.dart';
import '../flutter_scene/halo_ring_nodes.dart';
import '../flutter_scene/line_nodes.dart';
import '../flutter_scene/render_backend.dart';
import '../flutter_scene/ring_nodes.dart';
import '../flutter_scene/scene_camera_adapter.dart';
import '../flutter_scene/scene_sync.dart';
import '../flutter_scene/scene_hud_overlay.dart';
import '../flutter_scene/terrain/terrain_nodes.dart';
import '../flutter_scene/vessel_nodes.dart';
import '../flutter_scene/walker_nodes.dart';
import '../flutter_scene/scene_render_view.dart';
import 'sim_view_control.dart';
import 'debug_layers.dart';
import 'nav_ball.dart';
import 'texture_cache.dart';
import 'top_down_painter.dart';

part 'simulation_view_debug_panel.dart';
part 'simulation_view_colony.dart';
part 'simulation_view_planner.dart';

/// Build stamp shown bottom-left so a deploy can be confirmed live (cache
/// busting check). Bump this every rebuild.
const String kBuildStamp = 'build 0.3.3.271-cull';

/// What the camera treats as "up" while orbiting the focus.
enum CameraUpMode {
  /// Orbit in the ecliptic (world) frame — the default free camera.
  free,

  /// Gimbal in the focused body's tilted spin frame: azimuth circles its
  /// equator, the pole reads upright on screen.
  axis,

  /// Gimbal about the local vertical (the gravity direction) at the focused
  /// vessel: azimuth circles the horizon and the ground reads down —
  /// the surface-flying view. Falls back to [axis] when a body (not a
  /// vessel) is focused: a body focus has no single surface point.
  gravity,
}

/// Infrastructure widget: owns the game loop (a Flutter [Ticker]), drives the
/// [AdvanceSimulationTick] use case, and repaints the [TopDownPainter] from a
/// fresh snapshot each frame. This is the ONLY place Flutter touches the sim;
/// everything it calls is a port/use case.
class SimulationView extends StatefulWidget {
  /// The PRIMARY vessel to spawn + focus (e.g. an ascent craft on a body's
  /// surface at a city's lat/long). Added alongside the demo fleet so the real
  /// 3D sphere renderer flies it, and locked at start.
  final Vessel? injectedVessel;

  /// Extra traffic vessels to also spawn (cargo shuttles, other players) — they
  /// show as named craft with their own orbits/trajectories in the sim.
  final List<Vessel> trafficVessels;

  /// World-viewport backend to start with. Software remains the default;
  /// dev entrypoints (main_scene_dev.dart) boot straight into flutter_scene.
  final RenderBackend initialBackend;

  /// Whether to also spawn the built-in demo orbiter (a generic craft in low
  /// lunar orbit). Dev scenarios that inject their OWN full fleet set this
  /// false so the scene is exactly the injected/traffic craft.
  final bool spawnDemoOrbiter;

  /// A colony to register with the world and open the camera on.
  ///
  /// The city studio's way in: it generates a real [CitySim] and hands it
  /// over, so the studio profiles the same scene, the same shaper and the same
  /// renderer a played colony uses rather than a lookalike of them.
  final CitySim? injectedCity;

  const SimulationView({
    super.key,
    this.injectedVessel,
    this.trafficVessels = const [],
    this.initialBackend = RenderBackend.software,
    this.spawnDemoOrbiter = true,
    this.injectedCity,
  });

  @override
  State<SimulationView> createState() => _SimulationViewState();
}

class _SimulationViewState extends State<SimulationView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  /// The world this screen is looking at. Everything below forwards to it,
  /// so the ~200 call sites in this library keep their original vocabulary
  /// while the state itself lives somewhere a test can build without a
  /// widget.
  late final FlightSession _session;

  SimulationClock get _clock => _session.clock;
  AdvanceSimulationTick get _advance => _session.advance;
  // Stashed tick deps so _advance can be rebuilt when a debug cheat toggles.
  // Debug cheats: skip overheat / aero-stress / craft destruction. ON by
  // default so flight testing isn't cut short; toggle off in the debug panel.
  bool get _disableOverheat => _session.cheats.disableOverheat;
  set _disableOverheat(bool v) =>
      _session.cheats = _session.cheats.copyWith(disableOverheat: v);
  bool get _disableAeroStress => _session.cheats.disableAeroStress;
  set _disableAeroStress(bool v) =>
      _session.cheats = _session.cheats.copyWith(disableAeroStress: v);
  bool get _disableCraftDestruction => _session.cheats.disableCraftDestruction;
  set _disableCraftDestruction(bool v) =>
      _session.cheats = _session.cheats.copyWith(disableCraftDestruction: v);
  // Orthogonal to destruction: hard impacts crater the ground even while the
  // craft itself is destruction-cheated. Deformation is the payoff of a
  // crash, so it defaults ON.
  bool get _disableCrater => _session.cheats.disableCrater;
  set _disableCrater(bool v) =>
      _session.cheats = _session.cheats.copyWith(disableCrater: v);
  late final TopDownSnapshotPresenter _presenter;
  StaticUniverseRepository get _universe => _session.universe;
  InMemoryVesselRepository get _vessels => _session.vessels;
  InMemoryColonyRepository get _colonies => _session.colonies;

  /// City-builder colonies this world owns. Founding writes here, the tick
  /// advances them, and the scene draws them — so a colony founded from the
  /// cockpit exists in the same world the craft is standing in, rather than in
  /// a screen that happens to be open.
  InMemoryCityRepository get _cities => _session.cities;
  InMemoryDepositRepository get _deposits => _session.deposits;
  ResearchLedger get _research => _session.research;

  /// Craters and excavation, accumulated for the life of the session. Owned
  /// here rather than by the tick, which gets rebuilt whenever a debug cheat
  /// toggles.
  InMemoryTerrainEditsRepository get _terrainEdits => _session.terrainEdits;

  // ---- Engine bridge ----
  // Serves THIS in-process sim to an external renderer (Unreal) over the
  // socket protocol, reusing the same repos the Flutter views render from. On
  // web this is a no-op (no dart:io), so the game just runs in-process.
  late final SimBridge _bridge;
  static const FlatBufferCodec _wire = FlatBufferCodec();
  StreamSubscription<Uint8List>? _bridgeCommands;
  int _bridgeTick = 0;
  // Ticker time of the last frame that carried body descriptors. Starts in the
  // past so the very first published frame includes them (a new client gets the
  // static catalog at once); thereafter they ride along ~once a second.
  Duration _lastDescriptorAt = const Duration(seconds: -2);

  // ---- Camera target + view ----
  // The locked target cycles through vessels and major bodies. Exactly one of
  // these is non-null at a time; the other is cleared when the cycle advances.
  VesselId? _focusVessel; // active vessel lock (null when a body is locked)
  BodyId? _focusBody; // active body lock (null when a vessel is locked)
  String? _focusMega; // active megastructure lock (both above null then)
  BodyId? _lastFocusBody; // dominant body of the focused vessel, last seen
  late final List<({String label, VesselId? v, BodyId? b, String? m})>
      _targets;
  int _targetIndex = 0;
  CameraOrbit _view = CameraOrbit.top;
  // MAP = wide orbit view + lock dropdown. CRAFT = tight chase cam on the focus
  // vessel (close zoom, camera tracks heading).
  bool _craftCam = false;
  double _mapMpp = 25000; // remembers the map zoom while in craft cam
  bool _mmbDragging = false; // middle-mouse free-orbit in progress
  Offset _lastMmb = Offset.zero;

  // Perspective camera (independent toggle, any mode). On by default.
  bool _perspectiveMode = true;
  double _range = 2.0e7; // perspective eye distance from target, metres
  double _fovDeg = 75; // perspective vertical field of view (wide enough that
  // the horizon frames naturally at low altitude; 50 felt like a long lens)
  double _screenH = 800; // last viewport height (for the perspective focal len)

  /// Last viewport WIDTH. Only the height mattered while the focal length was
  /// the sole consumer; ground picking needs both to find the screen centre.
  double _screenW = 1200;

  /// Rebuild hook for the extensions in this library's part files.
  ///
  /// `setState` is `@protected`, so it may only be called from inside the State
  /// subclass itself — an extension calling it is a lint warning on every use.
  /// One explicit method keeps the parts honest about what they are doing and
  /// leaves a single place to instrument if a rebuild storm ever needs finding.
  void rebuild(VoidCallback fn) => setState(fn);

  // ---- Encounter planner ----
  // A trial maneuver node the player drags against a target: burn epoch +
  // PNR delta-v. The plan/overlay are recomputed (throttled) each frame while
  // active; the overlay feeds the 3D plane + planned-trajectory render.
  bool _plannerActive = false;
  int _plannerTargetIndex = -1; // index into _targets; -1 = no target
  Epoch? _plannerBurnEpoch;
  double _dvPrograde = 0, _dvNormal = 0, _dvRadial = 0;
  EncounterPlan? _plan;
  PlannerOverlay? _plannerOverlay;
  bool _plannerDirty = true;
  int _plannerComputedMs = 0;

  /// The colony being edited in-world, and the tool held over it.
  CitySim? _editingCity;
  final CityEditController _cityEdit = CityEditController();

  /// Where the placement heatmap was last surveyed, and for which building.
  /// Held here rather than in the colony extension, which cannot own fields.
  Vec2? _heatAt;
  String? _heatSpec;
  bool _controlsExpanded = true; // collapsible FAB stack

  /// Radius (m) of the body the camera is locked on, or 0 (vessel / none). Lets
  /// the perspective eye measure its range from the SURFACE, not the centre.
  double get _focusBodyRadius {
    // Freecam: the range measures from the FREE ANCHOR, not a body surface
    // (leaving the locked body's radius in put the eye 58,000 km from the
    // anchor at "range 250 m" over Saturn).
    if (_freecam) return 0;
    if (_focusMega != null) {
      // A ring's "surface" is its band: range measures from the ring circle,
      // so zooming all the way in lands the eye at the structure, not stalled
      // a ring-radius away from its empty centre.
      for (final m in _session.megastructures.all()) {
        if (m.id == _focusMega) return m.ringSpec?.radiusM ?? 0;
      }
      return 0;
    }
    if (_focusBody == null) return 0;
    return _universe.current().body(_focusBody!)?.radius ?? 0;
  }

  /// World position of the locked megastructure, from the same snapshot the
  /// scene renders — pose is derived per frame (orbit + spin), so reading the
  /// snapshot keeps the camera glued to the structure without re-deriving it.
  Vector3? get _megaFocusWorld {
    final id = _focusMega;
    final world = _sceneWorld;
    if (id == null || world == null) return null;
    for (final m in world.megastructures) {
      if (m.id == id) return Vector3(m.px, m.py, m.pz);
    }
    return null;
  }

  /// The active camera for this frame: ortho or perspective, both driven by the
  /// shared `_view` orientation (azimuth/elevation/roll). In perspective the
  /// eye sits [_range] from the body's SURFACE (range + radius from centre), so
  /// _range is an altitude that can shrink to near-zero — you keep zooming all
  /// the way down to the surface instead of stalling at centre-distance==radius.
  SceneCamera get _camera => _perspectiveMode
      ? _clampEyeAboveTerrain(PerspectiveCamera(
          azimuth: _view.azimuth,
          elevation: _view.elevation,
          roll: _view.roll,
          frame: _view.frame,
          // WALK puts the eye exactly AT the anchor (range 0) — first person,
          // no third-person boom to push through the walls of a habitat.
          range: _walkMode
              ? (_thirdPerson ? _walkBoomM : 0.0)
              : _range + _focusBodyRadius,
          // Range can go to 1 m; a fixed 1 m near plane would clip the
          // whole craft there. Track the range down (never above 1 m so
          // nothing else changes).
          //
          // Walk's range is zero, so the adaptive near plane (range/20) would
          // sit ON the eye. It gets a fixed floor instead, and that floor is a
          // DEPTH-PRECISION decision, not a clipping one: the far plane stays
          // at 5e12 m, and with a 24-bit buffer the quantum runs d²/(n·2²⁴) —
          // at n = 0.1 m the terrain a kilometre out lands in the same depth
          // bucket as the starfield backdrop and the sky paints over it. Half
          // a metre is 5x finer and still clips nothing a standing figure can
          // see: looking level, the nearest ground in a 75° frame is ~2.8 m
          // away, and straight down it is the 1.7 m under their boots.
          near: _walkMode ? 0.5 : math.min(1.0, _range * 0.05),
          fovY: _fovDeg * math.pi / 180,
          viewportH: _screenH,
        ))
      : OrthoCamera(_view, _metresPerPixel);

  /// Keep the perspective EYE above the focused body's terrain — the transient
  /// per-frame clamp in [clampPerspectiveEyeAboveTerrain]. This wrapper only
  /// resolves WHICH body sits under the camera (the locked body, else the
  /// locked craft's dominant body) and its crater edits; `_view` / `_range`
  /// are never written, so the camera returns to the user's own pose the
  /// moment it clears the ground.
  PerspectiveCamera _clampEyeAboveTerrain(PerspectiveCamera cam) {
    // Freecam orbits a free anchor, not a body — the body-centred geometry
    // doesn't apply (and the anchor is the player's own flying problem).
    // The third-person boom is the one freecam pose that must respect the
    // ground: swing it downhill and it would otherwise sink into the slope
    // behind the walker and frame the planet's insides.
    if (_walkMode && _thirdPerson) {
      final body = _walkBody;
      if (body == null) return cam;
      return clampPerspectiveEyeAboveTerrain(
        cam,
        body: body,
        focusRelBody: _freecamRelLocal.length > 0
            ? _refBodyQuat().rotate(_freecamRelLocal)
            : Vector3.zero,
        epoch: _clock.epoch,
        edits: _terrainEdits.forBody(body.id),
        clearance: 0.5,
      );
    }
    if (_freecam) return cam;

    final system = _universe.current();
    CelestialBody? body;
    var focusRelBody = Vector3.zero;
    if (_focusBody != null) {
      body = system.body(_focusBody!);
    } else if (_focusVessel != null) {
      final v = _vessels.byId(_focusVessel!);
      if (v != null) {
        body = system.body(v.dominantBody);
        focusRelBody = v.state.position;
      }
    }
    if (body == null) return cam;

    return clampPerspectiveEyeAboveTerrain(
      cam,
      body: body,
      focusRelBody: focusRelBody,
      epoch: _clock.epoch,
      edits: _terrainEdits.forBody(body.id),
    );
  }
  // Tilted-view distance-cull kicks in above this zoom (m/px). 1e6 == 100 px /
  // 100,000 km. Configurable via the debug panel.
  double _tiltedCullMpp = 1e6;
  static const double _orbitStep = 0.1309; // ~7.5 deg per arrow press
  DebugLayers _layers = const DebugLayers();
  bool _showDebugPanel = false;

  // ---- Custom spawn (debug panel) ----
  // Body pick + typed altitude for the "any body, any altitude, or landed"
  // teleport. Null body = follow the camera (the panel resolves a default).
  BodyId? _spawnBody;
  final TextEditingController _spawnAltCtrl = TextEditingController(text: '200');

  // Impact tester: mass/speed of a throwaway impactor dropped beside the
  // focused craft (debug panel). Defaults sized to dig an obvious ~10 m
  // crater on the Moon.
  final TextEditingController _impactMassCtrl =
      TextEditingController(text: '9000');
  final TextEditingController _impactSpeedCtrl =
      TextEditingController(text: '300');
  int _impactorCount = 0;
  // World-viewport backend. Software (TopDownPainter) is the default; the
  // flutter_scene 3D backend mounts in its place when toggled. Camera state,
  // input handling, and every HUD overlay stay shared between the two.
  // Persisted: the FAB toggle saves the choice; the saved value wins over
  // [SimulationView.initialBackend] once loaded (dev entrypoints that pass
  // an explicit backend skip persistence entirely).
  late RenderBackend _renderBackend = widget.initialBackend;
  static const String _backendPrefKey = 'renderBackend';

  Future<void> _loadBackendPref() async {
    if (widget.initialBackend != RenderBackend.software) return; // dev override
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_backendPrefKey);
    final saved = RenderBackend.values
        .where((b) => b.name == name)
        .firstOrNull;
    if (saved != null && mounted && saved != _renderBackend) {
      setState(() => _renderBackend = saved);
    }
  }

  void _setBackend(RenderBackend backend) {
    setState(() => _renderBackend = backend);
    // Fire-and-forget: preference loss is cosmetic.
    unawaited(SharedPreferences.getInstance()
        .then((p) => p.setString(_backendPrefKey, backend.name)));
  }

  /// Wire the programmatic control surface (VM-service extensions in
  /// main_scene_dev.dart drive these). Every mutation goes through
  /// setState, exactly like user input.
  void _registerControl() {
    final c = SimViewControl.instance;
    c.orbit = ({double? azimuth, double? elevation, double? roll}) {
      if (!mounted) return;
      setState(() {
        _view = _view.copyWith(
          azimuth: azimuth,
          elevation: elevation,
          roll: roll,
        );
      });
    };
    c.zoom = ({double? rangeM, double? metresPerPixel}) {
      if (!mounted) return;
      setState(() {
        if (rangeM != null) _range = rangeM.clamp(1.0, 1e13);
        if (metresPerPixel != null) {
          _metresPerPixel = metresPerPixel.clamp(1e-3, 1e12);
        }
      });
    };
    c.setPerspective = (perspective) {
      if (!mounted) return;
      setState(() => _perspectiveMode = perspective);
    };
    c.setBackend = (backend) {
      if (!mounted) return;
      _setBackend(backend);
    };
    c.focusBody = (bodyId) {
      if (!mounted) return;
      // Route through the SAME path as the LOOK AT dropdown: setting
      // _focusBody directly skips its bookkeeping (_targetIndex, dropping
      // manual mode for an unpilotable body) and crashed downstream.
      final idx = _targets.indexWhere((t) => t.b?.value == bodyId);
      if (idx >= 0) _selectTarget(idx);
    };
    c.dropImpactor =
        ({double massKg = 9000, double speedMs = 300, bool destroy = true}) {
      if (!mounted) return;
      _impactMassCtrl.text = massKg.toString();
      _impactSpeedCtrl.text = speedMs.toString();
      if (destroy && _disableCraftDestruction) {
        setState(() {
          _disableCraftDestruction = false;
          _buildAdvance();
        });
      }
      _dropImpactor();
    };
    c.spawnLanded = (bodyId) {
      if (!mounted) return;
      setState(() => _spawnBody = BodyId(bodyId));
      _spawnCustom(landed: true);
    };
    c.warpToApsis = (periapsis) {
      if (!mounted) return;
      _warpToApsis(periapsis: periapsis);
    };
    c.setUpMode = (mode) {
      if (!mounted) return;
      final m = CameraUpMode.values.where((v) => v.name == mode).firstOrNull;
      if (m != null) setState(() => _upMode = m);
    };
    c.setFreecam = (on, pos) {
      if (!mounted) return;
      setState(() {
        if (on != _freecam) _toggleFreecam();
        if (pos != null) {
          _freecamRelLocal =
              _refBodyQuat().conjugate.rotate(pos - _refBodyWorld());
        }
      });
    };
    c.setWalk = (on) {
      if (!mounted) return;
      if (on != _walkMode) _toggleWalk();
    };
    c.setDrill = (on) {
      if (!mounted) return;
      setState(() => _drillLatched = on);
    };
    c.setLamp = (on) {
      if (!mounted) return;
      setState(() => TerrainNodes.lampOn = on);
    };
    c.setThirdPerson = (on) {
      if (!mounted) return;
      setState(() => _thirdPerson = on);
    };
    c.setEvaPack = (on) {
      if (!mounted) return;
      setState(() {
        _evaPack = on;
        _evaVel = on
            ? _freecamRelLocal.normalized * _walkVertVel
            : Vector3.zero;
      });
    };
    c.freecamToRing = (bodyId, radialMult, zM) {
      if (!mounted) return;
      final snap = _sceneWorld;
      final b = snap?.bodies[bodyId];
      if (b == null) return;
      setState(() {
        if (!_freecam) _toggleFreecam();
        _freecamRef = BodyId(bodyId);
        // Body-local IS the ring frame — no rotation needed.
        _freecamRelLocal = Vector3(radialMult * b.radius, 0, zM);
      });
    };
    c.status = () => {
          'azimuth': _view.azimuth,
          'elevation': _view.elevation,
          'roll': _view.roll,
          'rangeM': _range,
          'metresPerPixel': _metresPerPixel,
          'perspective': _perspectiveMode,
          'backend': _renderBackend.name,
          'focusVessel': _focusVessel?.value,
          'focusBody': _focusBody?.value,
          'warpFactor': _clock.warpFactor,
          'warpTarget': _warpTargetLabel,
          'epochS': _clock.epoch.seconds,
          'upMode': _upMode.name,
          'freecam': _freecam,
          'walk': _walkMode,
          // Frame economics, harness-readable (mirrors the perf panel): mean
          // ticker frame, Flutter's own build/raster means, and the last
          // TopDownSnapshotPresenter.present() — the one big per-frame cost
          // that is NOT inside SceneSync.stageMs.
          'frameMs': _avgOfList(_frameMs),
          'uiMs': _avgOfList(_uiMs),
          'rasterMs': _avgOfList(_rasterMs),
          'presentMs': _presentMs,
          'walkGrounded': _walkGrounded,
          'lamp': TerrainNodes.lampOn,
          'thirdPerson': _thirdPerson,
          'evaPack': _evaPack,
          'evaSpeedMs': _evaVel.length,
          'evaFuelKg': _evaFuelKg,
          'drilling': _bore != null,
          'drillLatched': _drillLatched,
          // Diagnostics for "the trigger is held and nothing happens": which
          // way the drill is actually pointing in the frame the anchor lives
          // in (-1 = straight down the radial), and whether the march found
          // ground inside its reach.
          'drillAimDot': () {
            if (!_walkMode || _freecamRelLocal.length <= 0) return null;
            final aim = _refBodyQuat().conjugate.rotate(_camera.forward);
            return aim.normalized.dot(_freecamRelLocal.normalized);
          }(),
          'drillContact': () {
            final body = _walkBody;
            if (body == null || !_walkMode) return false;
            return _drill.contact(
                  eyeBF: _freecamRelLocal,
                  aimDirBF: _refBodyQuat().conjugate.rotate(_camera.forward),
                  groundRadiusAt: (p) => _walkGroundRadius(body, p),
                ) !=
                null;
          }(),
          'boreRadiusM': _bore?.radiusM,
          'drilledM3': _drilledM3,
          'terrainEditCount':
              _walkBody == null ? 0 : (_terrainEdits.forBody(_walkBody!.id)?.length ?? 0),
          // Eye height above the terrain under the walker, metres (null when
          // not on foot) — the readout a surface capture is framed by.
          'walkEyeAltM': () {
            final body = _walkBody;
            if (!_walkMode || body == null) return null;
            final r = _freecamRelLocal.length;
            if (r <= 0) return null;
            return r - _walkGroundRadius(body, _freecamRelLocal);
          }(),
          'freePos': () {
            final p = _freecamWorld;
            return [p.x, p.y, p.z];
          }(),
          'focusWorld': () {
            final f = _currentFocusWorld();
            return [f.x, f.y, f.z];
          }(),
          'autoExposure': SceneSync.autoExposure,
          'exposure': SceneSync.lastExposure,
          'exposureTarget': SceneSync.lastTarget,
          'manualExposure': SceneSync.manualExposure,
          'expMin': SceneSync.minExposure,
          'expMax': SceneSync.maxExposure,
          'expUp': SceneSync.adaptUpS,
          'expDown': SceneSync.adaptDownS,
        };
  }
  // Latest world snapshot for the flutter_scene backend (null when the
  // software backend is active — capture cost is zero when unused).
  WorldSnapshot? _sceneWorld;
  int _sceneTick = 0;
  // Camera up alignment: FREE orbits the ecliptic, AXIS gimbals in the
  // focused body's tilted spin frame, GRAVITY gimbals about the local
  // vertical at the focused vessel (surface flying: the ground reads down).
  CameraUpMode _upMode = CameraUpMode.free;
  // Gravity-mode frame state for the INCREMENTAL update (see the frame
  // block): fresh shortest-arc per frame flips when the radial nears -Z.
  Quaternion? _gravFrame;
  Vector3? _gravRadial;

  // Freecam: the camera orbits a FREE ANCHOR flown with WASD/QE (Shift
  // boosts) instead of the locked target; MMB orbit and wheel zoom keep
  // working around it. 3D backend only (the software painter still centres
  // on the locked target). Mutually exclusive with manual flight — both
  // want WASD.
  //
  // The anchor is stored in the reference body's ROTATING frame (body-
  // local coordinates, spin included). Two reasons: an absolute anchor
  // near Saturn fell out of its 9.7 km/s ring plane within a second of
  // hovering, and an inertial (non-spinning) anchor watched the ring
  // debris — which rides the spin frame — sweep past at ~16 km/s (real
  // B-ring orbital speed: "they zip through the screen"). Co-rotating
  // makes hovering read like station-keeping: the rocks sit still and
  // flying through them is YOUR motion.
  bool _freecam = false;
  BodyId? _freecamRef;
  Vector3 _freecamRelLocal = Vector3.zero;

  /// Freecam flight-speed multiplier, driven by the scroll wheel while the
  /// freecam is active (wheel = speed, not zoom, when flying).
  double _freecamSpeedMul = 1.0;

  // WALK: first person on foot. A sub-mode of the freecam — it reuses the
  // anchor (body-fixed, spin-carried) and the FPS-style look in [_orbitCamera]
  // wholesale, and only replaces the FLIGHT with surface-bound motion: the
  // anchor is pinned to terrain height + eye height, WASD moves in the tangent
  // plane at human pace, and Space hops under the body's own gravity. The eye
  // sits AT the anchor (range 0), so the anchor IS the head.
  bool _walkMode = false;
  double _walkVertVel = 0; // m/s along local up
  bool _walkGrounded = false;

  // EVA pack: J lifts off, and the walker flies velocity-controlled until the
  // ground catches them again. Held ACROSS the walk/float switch so a hop into
  // a burn and back down is continuous.
  bool _evaPack = false;
  Vector3 _evaVel = Vector3.zero;
  double _evaFuelKg = evaPropellantKg;

  /// Third person: the camera pulls back onto a boom and the walker's own body
  /// is drawn. The anchor is unchanged — it is still the head — so switching
  /// views mid-stride moves nothing but the eye.
  bool _thirdPerson = false;
  static const double _walkBoomM = 3.5;
  double _rangeBeforeWalk = 100.0; // orbit range restored when walk ends
  CameraUpMode _upModeBeforeWalk = CameraUpMode.free;

  /// The body being walked on — the freecam's reference body, resolved in the
  /// domain (the snapshot carries no terrain field).
  CelestialBody? get _walkBody {
    final ref = _freecamRef?.value;
    return ref == null ? null : _universe.current().body(BodyId(ref));
  }

  /// Terrain radius (m from centre) under a body-FIXED position, craters and
  /// all.
  ///
  /// Samples the field DIRECTLY in body-fixed coordinates. An earlier version
  /// rotated the position out to the inertial frame with the snapshot's
  /// orientation and let `CelestialBody.terrainGroundRadius` rotate it back
  /// with `orientationAt(epoch)` — and those two are never quite the same
  /// quaternion, because the snapshot is a frame behind the clock. On a
  /// spinning body that mismatch slides the sample point across the surface
  /// every frame, so the ground under a standing walker kept moving and they
  /// fell forever, landing and un-landing a couple of metres at a time.
  double _walkGroundRadius(CelestialBody body, Vector3 posBF) {
    final field = body.terrainFieldWith(_terrainEdits.forBody(body.id));
    if (field == null) return body.radius;
    return field.groundRadiusAt(posBF.x, posBF.y, posBF.z);
  }


  /// Toggle first-person walk. Entering implies freecam (walk owns the same
  /// anchor) and DROPS the anchor onto the ground beneath wherever the camera
  /// is looking from — so it doubles as "put me on the surface here".
  void _toggleWalk() {
    setState(() {
      _walkMode = !_walkMode;
      if (_walkMode) {
        // Stand where the user is looking FROM, not at what they are looking
        // AT: a body lock focuses the body's CENTRE, so anchoring on the focus
        // buried the walker at the core of the planet. The EYE is already
        // outside, above the ground it is looking down at.
        final eyeWorld = _currentFocusWorld() + _camera.eyeOffset;
        _rangeBeforeWalk = _range;
        // A walker's horizon has to be level, which means the camera gimbal
        // has to be the local vertical — see the walk branch in the frame
        // block. FREE mode skips that block entirely, so walking owns the
        // up-mode and hands it back on the way out.
        _upModeBeforeWalk = _upMode;
        _upMode = CameraUpMode.gravity;
        _gravFrame = null;
        _gravRadial = null;
        if (!_freecam) {
          _toggleFreecamInner();
        }
        _walkVertVel = 0;
        _walkGrounded = false;
        final body = _walkBody;
        if (body != null) {
          var dir = _refBodyQuat().conjugate.rotate(eyeWorld - _refBodyWorld());
          // Eye exactly on the axis of a body (or no snapshot yet to place one)
          // leaves no radial to stand on — start at the north pole rather than
          // divide by zero.
          if (dir.length < 1.0) dir = Vector3.unitZ;
          dir = dir.normalized;
          _freecamRelLocal = dir * (_walkGroundRadius(body, dir) + walkEyeHeight);
          _walkGrounded = true;
        }
      } else {
        _range = _rangeBeforeWalk;
        _upMode = _upModeBeforeWalk;
        _gravFrame = null;
        _gravRadial = null;
        _evaPack = false;
        _evaVel = Vector3.zero;
        WalkerNodes.visible = false;
      }
    });
  }

  /// One frame of on-foot motion: WASD in the tangent plane, Space jumps,
  /// Shift runs. Pure motion lives in [stepFirstPersonWalk]; this only feeds
  /// it the camera heading (rotated into the body-fixed frame the anchor lives
  /// in), the local gravity, and the terrain sampler.
  ///
  /// Runs every frame even with no key down — gravity, the ground clamp and a
  /// jump in flight all need to keep integrating.
  void _stepWalk(double moveForward, double moveRight, double frameDt) {
    final body = _walkBody;
    if (body == null) return;
    final dt = frameDt.clamp(0.0, 0.1);
    if (dt <= 0) return;

    final r = _freecamRelLocal.length;
    if (r <= 0) return;
    final gravity = body.mu / (r * r);

    // Camera basis is INERTIAL; the anchor is body-fixed. Rotate the heading
    // into the rotating frame or the walk direction drifts with the spin.
    final cam = _camera;
    final qc = _refBodyQuat().conjugate;
    final running = _keysDown.contains(LogicalKeyboardKey.shiftLeft) ||
        _keysDown.contains(LogicalKeyboardKey.shiftRight);

    final step = stepFirstPersonWalk(
      posLocal: _freecamRelLocal,
      vertVel: _walkVertVel,
      grounded: _walkGrounded,
      forwardLocal: qc.rotate(cam.forward),
      rightLocal: qc.rotate(cam.right),
      moveForward: moveForward,
      moveRight: moveRight,
      jump: _keysDown.contains(LogicalKeyboardKey.space),
      dt: dt,
      gravity: gravity,
      groundRadiusAt: (p) => _walkGroundRadius(body, p),
      // The freecam's scroll-wheel speed knob doubles as the walk pace, so a
      // 40 km hike across a moon does not have to happen at 1.4 m/s.
      speed: (running ? walkRunSpeed : walkSpeed) * _freecamSpeedMul,
    );
    _freecamRelLocal = step.posLocal;
    _walkVertVel = step.vertVel;
    _walkGrounded = step.grounded;
  }

  /// One frame on the thruster pack. Takes over from [_stepWalk] entirely
  /// while [_evaPack] is on: the two integrate the same anchor in the same
  /// frame, so control hands back and forth without a seam.
  ///
  /// Touching down does NOT switch the pack off — you can hop, burn, land and
  /// burn again. J is the only thing that stows it.
  void _stepEva(double moveForward, double moveRight, double frameDt) {
    final body = _walkBody;
    if (body == null) return;
    final dt = frameDt.clamp(0.0, 0.1);
    if (dt <= 0) return;
    final r = _freecamRelLocal.length;
    if (r <= 0) return;

    final cam = _camera;
    final qc = _refBodyQuat().conjugate;
    final up = (_keysDown.contains(LogicalKeyboardKey.space) ? 1.0 : 0.0) -
        (_keysDown.contains(LogicalKeyboardKey.keyC) ? 1.0 : 0.0);

    final step = stepEvaPack(
      posLocal: _freecamRelLocal,
      velLocal: _evaVel,
      forwardLocal: qc.rotate(cam.forward),
      rightLocal: qc.rotate(cam.right),
      throttleForward: moveForward,
      throttleRight: moveRight,
      throttleUp: up,
      dt: dt,
      gravity: body.mu / (r * r),
      propellantKg: _evaFuelKg,
      groundRadiusAt: (p) => _walkGroundRadius(body, p),
    );
    _freecamRelLocal = step.posLocal;
    _evaVel = step.velLocal;
    _evaFuelKg = step.propellantKg;
    _walkGrounded = step.grounded;
    // Hand the walker a consistent vertical speed for the moment the pack is
    // stowed mid-air: the walk integrator owns one scalar, not a vector.
    _walkVertVel = step.grounded
        ? 0
        : step.velLocal.dot(_freecamRelLocal.normalized);
  }

  /// Publish the walker's pose to the renderer's avatar.
  ///
  /// The scene is focus-relative and the focus IS the walker while on foot, so
  /// the body sits at the origin; only its orientation has to be sent. Static
  /// fields rather than the snapshot because the walker never crosses the
  /// wire — no other client has one.
  void _syncWalkerBody() {
    WalkerNodes.visible = _walkMode && _thirdPerson;
    if (!WalkerNodes.visible) return;
    final q = _refBodyQuat();
    WalkerNodes.eyeRel = Vector3.zero;
    WalkerNodes.up = _freecamRelLocal.length > 0
        ? q.rotate(_freecamRelLocal.normalized)
        : Vector3.unitZ;
    WalkerNodes.forward = _camera.forward;
    WalkerNodes.eyeHeightM = walkEyeHeight;
  }

  // ---- Hand drill ----
  // Held E excavates the ground the operator is pointing at. The bore state
  // rides across frames so a held trigger keeps deepening ONE hole; the drill
  // itself decides when that has earned a terrain brush (rarely — a brush per
  // frame would flood the edit list the snapshot ships every tick).
  static const HandDrill _drill = HandDrill();
  DrillBore? _bore;
  double _drilledM3 = 0; // session total, for the HUD

  /// Trigger held by tooling rather than by a finger on E — the dev
  /// extension's way to drill, since a held key cannot be synthesized over
  /// the VM service.
  bool _drillLatched = false;

  /// One frame of drilling. Clearing [_bore] whenever the trigger is up (or
  /// the aim leaves the ground) is what makes a new press start a new hole
  /// instead of resuming the last one from across the valley.
  void _stepDrill(double frameDt) {
    final body = _walkBody;
    final held = _drillLatched || _keysDown.contains(LogicalKeyboardKey.keyE);
    if (body == null || !held) {
      _bore = null;
      return;
    }
    final dt = frameDt.clamp(0.0, 0.1);
    if (dt <= 0) return;

    // The contact march samples the LIVE field, edits included, so the bite
    // point follows the hole down as it deepens instead of hovering at the
    // pristine surface.
    final qc = _refBodyQuat().conjugate;
    final aim = _drill.contact(
      eyeBF: _freecamRelLocal,
      aimDirBF: qc.rotate(_camera.forward),
      groundRadiusAt: (p) => _walkGroundRadius(body, p),
    );
    if (aim == null) {
      _bore = null; // pointing at the sky, or across a gap
      return;
    }
    final t = _drill.drill(
        bore: _bore, aimBF: aim, dt: dt, tick: _sceneTick);
    _bore = t.bore;
    _drilledM3 += t.excavatedM3;
    for (final brush in t.brushes) {
      _terrainEdits.record(body.id, brush);
    }
  }

  BodySnapshot? _refBody() {
    final ref = _freecamRef?.value;
    if (ref == null) return null;
    return _sceneWorld?.bodies[ref];
  }

  Quaternion _refBodyQuat() {
    final b = _refBody();
    return b == null
        ? Quaternion.identity
        : Quaternion(b.qw, b.qx, b.qy, b.qz);
  }

  Vector3 get _freecamWorld {
    final b = _refBody();
    if (b != null) {
      return Vector3(b.px, b.py, b.pz) + _refBodyQuat().rotate(_freecamRelLocal);
    }
    return _freecamRelLocal; // absolute fallback (ref not in the snapshot)
  }

  Vector3 _refBodyWorld() {
    final b = _refBody();
    return b == null ? Vector3.zero : Vector3(b.px, b.py, b.pz);
  }

  void _toggleFreecam() => setState(_toggleFreecamInner);

  /// The freecam toggle itself, outside `setState` so walk mode — which turns
  /// the freecam on as part of its own transition — can reuse it.
  void _toggleFreecamInner() {
    _freecam = !_freecam;
    // Walk is a freecam sub-mode: leaving the freecam leaves the ground too.
    if (!_freecam && _walkMode) {
      _walkMode = false;
      _range = _rangeBeforeWalk;
    }
    if (_freecam) {
      _freecamRef = _focusBody ?? _lastFocusBody;
      _freecamRelLocal = _refBodyQuat()
          .conjugate
          .rotate(_currentFocusWorld() - _refBodyWorld());
      _manualControl = false;
      _craftCam = false;
      // Fly cam wants the eye AT the anchor: a stale multi-thousand-km
      // orbit range keeps the camera far away AND (near = range/20)
      // clips everything within kilometres — the entire ring asteroid
      // field vanished behind the near plane. The wheel is the speed
      // knob in freecam, so it can't zoom back in; [ ] still can.
      _range = math.min(_range, 100.0);
    }
  }

  /// Absolute world position (metres) of the current camera focus, from the
  /// latest snapshot — the freecam anchor starts here so toggling is
  /// seamless.
  Vector3 _currentFocusWorld() {
    final snap = _sceneWorld;
    if (snap == null) return _freecamWorld;
    final vid = _focusVessel?.value;
    if (vid != null) {
      final v = snap.vessels[vid];
      if (v != null) {
        final b = snap.bodies[v.body];
        final bodyPos =
            b == null ? Vector3.zero : Vector3(b.px, b.py, b.pz);
        return bodyPos + Vector3(v.px, v.py, v.pz);
      }
    }
    final bid = _focusBody?.value;
    if (bid != null) {
      final b = snap.bodies[bid];
      if (b != null) return Vector3(b.px, b.py, b.pz);
    }
    return _freecamWorld;
  }

  /// Shortest rotation taking [from] onto [to] (both need not be unit).
  static Quaternion _shortestArc(Vector3 from, Vector3 to) {
    final f = from.normalized, t = to.normalized;
    final d = f.dot(t).clamp(-1.0, 1.0);
    if (d > 1 - 1e-9) return Quaternion.identity;
    if (d < -1 + 1e-9) {
      // Antiparallel: 180° about any axis perpendicular to [from].
      final axis = f.cross(Vector3.unitX).lengthSquared < 1e-12
          ? f.cross(Vector3.unitY)
          : f.cross(Vector3.unitX);
      return Quaternion.axisAngle(axis, math.pi);
    }
    return Quaternion.axisAngle(f.cross(t), math.acos(d));
  }
  late final TextureCache _textures;

  // Destruction notice: set when a vessel is lost (impact / overstress / burn-up)
  // so the UI can pop a menu. Cleared when the user dismisses it.
  ({String title, String detail})? _crashNotice;
  // Events raised since the last frame's snapshot captures, flattened for the
  // renderers (drained every frame in _onFrame).
  final List<EventSnapshot> _frameEvents = [];
  // Vessel id -> display name, so a destruction event (which only carries the id,
  // and fires as the vessel is removed) can still be reported by name.
  final Map<String, String> _vesselNames = {};

  final GameStateCodec _codec = const GameStateCodec();
  String? _savedGame; // in-memory save slot (file IO is a separate concern)

  // ---- Manual 3D piloting + camera ----
  static const PilotController _pilot = PilotController();
  final FocusNode _keyFocus = FocusNode();
  final Set<LogicalKeyboardKey> _keysDown = {};
  // ignore: prefer_final_fields
  bool _manualControl = false; // when true, autopilot for the focus vessel is off

  // ---- Touchscreen flight inputs (on-screen controls) ----
  double _touchPitch = 0; // -1..1 from the virtual joystick
  double _touchYaw = 0;
  double _touchRoll = 0;
  double _touchThrottle = 0; // 0..1 from the throttle slider
  double _touchThrottleFine = 0; // 0..1 -> absolute 0..10% throttle (fine landing)

  /// Build a PilotInput from keyboard + on-screen touch controls (whichever is
  /// active; they sum so either input device works).
  PilotInput _readPilotInput() {
    double axis(LogicalKeyboardKey neg, LogicalKeyboardKey pos) =>
        (_keysDown.contains(pos) ? 1.0 : 0.0) - (_keysDown.contains(neg) ? 1.0 : 0.0);
    final keyThrottle = _keysDown.contains(LogicalKeyboardKey.shiftLeft) ? 1.0 : 0.0;
    return PilotInput(
      pitch: (axis(LogicalKeyboardKey.keyS, LogicalKeyboardKey.keyW) + _touchPitch).clamp(-1.0, 1.0),
      yaw: (axis(LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyD) + _touchYaw).clamp(-1.0, 1.0),
      // Negated: roll was inverted (Q/E + the touch slider rolled the wrong way).
      roll: (-(axis(LogicalKeyboardKey.keyQ, LogicalKeyboardKey.keyE) + _touchRoll)).clamp(-1.0, 1.0),
      throttle: keyThrottle > 0 ? keyThrottle : _touchThrottle,
    );
  }

  /// Every key the sim consumes — flight (W/S A/D Q/E, Shift), mode (M),
  /// zoom ([ ]), time warp (, .) and camera orbit (arrows).
  ///
  /// [_onKey] must report exactly these to the focus system as `handled`.
  /// macOS rings the system alert sound for any key an app leaves unhandled:
  /// the event walks the AppKit responder chain, matches no menu equivalent,
  /// and ends in NSBeep. Holding a key repeats the beep once per key-repeat.
  /// Windows has no such fallback, so the old always-unhandled path was only
  /// ever audible on macOS. Anything outside this set stays `ignored` so menu
  /// and system shortcuts still reach the platform.
  ///
  /// Both Shift keys are listed although only [LogicalKeyboardKey.shiftLeft]
  /// drives throttle — right-Shift stays silent rather than beeping.
  /// Per-keypress zoom factor for the [ ] and - = keys (>1 = out).
  static const double _keyZoomStep = 1.25;

  // Not `const`: LogicalKeyboardKey overrides `==`, which const sets forbid.
  static final Set<LogicalKeyboardKey> _simKeys = {
    LogicalKeyboardKey.keyW,
    LogicalKeyboardKey.keyS,
    LogicalKeyboardKey.keyA,
    LogicalKeyboardKey.keyD,
    LogicalKeyboardKey.keyQ,
    LogicalKeyboardKey.keyE,
    LogicalKeyboardKey.keyM,
    LogicalKeyboardKey.keyG,
    LogicalKeyboardKey.keyF,
    LogicalKeyboardKey.keyT,
    LogicalKeyboardKey.keyJ,
    LogicalKeyboardKey.keyC,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.bracketLeft,
    LogicalKeyboardKey.bracketRight,
    LogicalKeyboardKey.minus,
    LogicalKeyboardKey.equal,
    LogicalKeyboardKey.comma,
    LogicalKeyboardKey.period,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
  };

  KeyEventResult _keyResult(KeyEvent e) => _simKeys.contains(e.logicalKey)
      ? KeyEventResult.handled
      : KeyEventResult.ignored;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    // Key-up clears unconditionally — even under a modifier chord — so a key
    // can't stay latched in [_keysDown] if a shortcut is pressed mid-hold.
    if (e is KeyUpEvent) {
      _keysDown.remove(e.logicalKey);
      return _keyResult(e);
    }
    // A modifier chord is a shortcut, not a flight input: Cmd+Q must quit
    // rather than roll the craft, so let those bubble to the platform.
    if (HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    if (e is KeyDownEvent) {
      // Toggle manual control with M.
      if (e.logicalKey == LogicalKeyboardKey.keyM) {
        setState(() => _manualControl = !_manualControl);
        return KeyEventResult.handled;
      }
      // G gets out and walks (and back in again).
      if (e.logicalKey == LogicalKeyboardKey.keyG) {
        _toggleWalk();
        return KeyEventResult.handled;
      }
      // T swaps between first and third person while on foot.
      if (e.logicalKey == LogicalKeyboardKey.keyT) {
        if (_walkMode) setState(() => _thirdPerson = !_thirdPerson);
        return KeyEventResult.handled;
      }

      // J stows/deploys the thruster pack. Only means anything on foot.
      if (e.logicalKey == LogicalKeyboardKey.keyJ) {
        if (_walkMode) {
          setState(() {
            _evaPack = !_evaPack;
            // Deploying inherits the walker's current vertical motion so a
            // burn at the top of a jump continues the arc.
            _evaVel = _evaPack
                ? _freecamRelLocal.normalized * _walkVertVel
                : Vector3.zero;
          });
        }
        return KeyEventResult.handled;
      }

      // F is the head lamp. Lives on the terrain material, not the scene:
      // the engine has one directional light and it belongs to the sun.
      if (e.logicalKey == LogicalKeyboardKey.keyF) {
        setState(() => TerrainNodes.lampOn = !TerrainNodes.lampOn);
        return KeyEventResult.handled;
      }
      _keysDown.add(e.logicalKey);
      // Camera zoom: [ / ] and - / = are equivalent pairs (out / in). Both go
      // through _zoom so they track perspective range as well as ortho
      // metres-per-pixel, exactly like the scroll wheel — the old path wrote
      // _metresPerPixel directly and so did nothing in perspective mode.
      if (e.logicalKey == LogicalKeyboardKey.bracketLeft ||
          e.logicalKey == LogicalKeyboardKey.minus) {
        setState(() => _zoom(_keyZoomStep));
      } else if (e.logicalKey == LogicalKeyboardKey.bracketRight ||
          e.logicalKey == LogicalKeyboardKey.equal) {
        setState(() => _zoom(1 / _keyZoomStep));
      } else if (e.logicalKey == LogicalKeyboardKey.comma) {
        _stepWarp(-1); // , slows time
      } else if (e.logicalKey == LogicalKeyboardKey.period) {
        _stepWarp(1); // . speeds time
      } else if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
        _orbitCamera(-_orbitStep, 0); // arrows orbit the focus
      } else if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
        _orbitCamera(_orbitStep, 0);
      } else if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
        _orbitCamera(0, _orbitStep);
      } else if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
        _orbitCamera(0, -_orbitStep);
      }
    }
    // KeyRepeatEvent lands here and deliberately re-triggers nothing: held
    // keys act through [_keysDown], polled per frame. It still has to report
    // as handled, or every repeat tick rings the macOS alert sound.
    return _keyResult(e);
  }

  TopDownSnapshot? _snapshot;
  SceneCamera? _activeCamera; // camera that built _snapshot (painter reuses it)
  double _metresPerPixel = 25000; // Earth (~6371 km) fits a phone screen
  double _pinchBaseMpp = 25000; // mpp captured at the start of a pinch gesture
  double _pinchBaseRange = 2.0e7; // perspective range captured at pinch start

  /// Debug zoom readout: the raw camera scale so a render issue can be pinned
  /// to an exact zoom. ORTHO = metres-per-pixel (+ km across 100 px); PERSP =
  /// eye range. Compact engineering form for the huge dynamic range.
  String _zoomLabel() {
    String eng(double v) {
      if (v >= 1e9) return '${(v / 1e9).toStringAsFixed(2)}G';
      if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';
      if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(2)}k';
      if (v >= 1) return v.toStringAsFixed(2);
      return v.toStringAsExponential(2);
    }

    if (_perspectiveMode) {
      if (_walkMode) {
        final body = _walkBody;
        final r = _freecamRelLocal.length;
        final alt = body == null || r <= 0
            ? 0.0
            : r - _walkGroundRadius(body, _freecamRelLocal);
        final g = body == null || r <= 0 ? 0.0 : body.mu / (r * r);
        final bore = _bore;
        if (_evaPack) {
          return 'EVA  ${_walkGrounded ? 'contact' : 'float'}  '
              'v ${_evaVel.length.toStringAsFixed(1)} m/s  '
              'prop ${_evaFuelKg.toStringAsFixed(1)} kg  '
              'g ${g.toStringAsFixed(2)} m/s²'
              '${TerrainNodes.lampOn ? '  LAMP' : ''}';
        }
        return 'WALK  ${_walkGrounded ? 'ground' : 'air'}  '
            'eye ${alt.toStringAsFixed(1)} m  '
            'g ${g.toStringAsFixed(2)} m/s²  '
            'pace x${_freecamSpeedMul.toStringAsFixed(2)}'
            '${TerrainNodes.lampOn ? '  LAMP' : ''}'
            '${bore == null ? '' : '  DRILL r${bore.radiusM.toStringAsFixed(2)} m'}'
            '${_drilledM3 <= 0 ? '' : '  dug ${_drilledM3.toStringAsFixed(1)} m³'}';
      }
      if (_freecam) {
        // Scroll wheel drives the flight-speed multiplier while flying.
        final mul = _freecamSpeedMul >= 10
            ? _freecamSpeedMul.toStringAsFixed(0)
            : _freecamSpeedMul.toStringAsFixed(2);
        return 'FREECAM  range ${eng(_range)} m  spd x$mul  '
            'fov ${_fovDeg.toStringAsFixed(0)}°';
      }
      // _range is the eye's altitude above the focused body's surface.
      final label = _focusBody != null ? 'alt' : 'range';
      return 'PERSP  $label ${eng(_range)} m  fov ${_fovDeg.toStringAsFixed(0)}°';
    }
    // 100 px spans this many km on screen — an intuitive "how zoomed" number.
    final kmPer100px = _metresPerPixel * 100 / 1000;
    return 'ORTHO  ${eng(_metresPerPixel)} m/px  (100px=${eng(kmPer100px)} km)';
  }

  /// Depth-plane + ring-field diagnostics for the 3D backend HUD: mirrors
  /// the near/far formula in scene_camera_adapter (keep in sync) and
  /// appends [RingNodes.debugLine] when a ringed body is near.
  String _depthDebugLabel() {
    // Read the eye off the LIVE camera rather than _range: on foot the eye is
    // at the anchor (range 0) while _range still holds the orbit range the
    // walker will get back, and the label has to mirror what the adapter sees.
    final cam = _camera;
    final eyeM = cam.eyeOffset.length;
    final nearOv = SceneCameraDebug.nearOverrideM;
    final farOv = SceneCameraDebug.farOverrideM;
    final nearM = nearOv ??
        math.max(cam is PerspectiveCamera ? cam.near : 0.0,
            math.max(0.05, eyeM / 20.0));
    final farM = farOv ?? math.max(5e12, eyeM * 40);
    String eng(double v) => v >= 1e9
        ? '${(v / 1e9).toStringAsFixed(1)}Gm'
        : v >= 1e6
            ? '${(v / 1e6).toStringAsFixed(1)}Mm'
            : v >= 1e3
                ? '${(v / 1e3).toStringAsFixed(1)}km'
                : '${v.toStringAsFixed(1)}m';
    final rings = RingNodes.debugLine;
    // The city line is the only window into why a colony is not on screen —
    // culled by range, zero buildings in the frame, or drawn but somewhere
    // else. Without it every "nothing shows" report is a guessing game.
    final city = CityNodes.debugLine;
    // The terrain line carries the streaming state — how many chunks are in
    // flight, and how many were RETIRED after failing their own band check.
    // A retired chunk is a tile that has gone and will not come back, which
    // is exactly what mining produces and exactly what you cannot diagnose
    // from a hole in the ground.
    final terrain = TerrainNodes.debugLine;
    return 'near ${eng(nearM)}${nearOv != null ? '*' : ''}  '
        'far ${eng(farM)}${farOv != null ? '*' : ''}  '
        'exp ${SceneSync.lastExposure.toStringAsFixed(2)}  '
        'aa=${SceneSync.effectiveAa}'
        '${rings == null ? '' : '  |  $rings'}'
        '${city.isEmpty ? '  |  city: none in frame' : '  |  $city'}'
        '${terrain.isEmpty ? '' : '  |  $terrain'}';
  }

  /// Zoom by [factor] (>1 = out): adjusts ortho mpp or perspective range.
  void _zoom(double factor) {
    // On foot the eye IS the head: zooming would pull it out of the body.
    if (_walkMode) return;
    if (_perspectiveMode) {
      _range = (_range * factor).clamp(1.0, 1e13);
    } else {
      _metresPerPixel = (_metresPerPixel * factor).clamp(0.5, 2e10);
    }
  }

  // Time-warp ladder (sim seconds per real second). ',' / '.' step through
  // it. Level 0 = PAUSE (the tick loop skips entirely — subsystems never
  // see a dt of zero).
  static const List<double> _warpLevels = [0, 1, 5, 10, 50, 100, 1000, 10000, 100000, 1000000];
  // Ladder index of 1x — the level forced by atmosphere entry and
  // warp-to-apsis arrival (index 0 is now the pause).
  static const int _warp1x = 1;
  int _warpIndex = 3; // starts at 50x (matches the initial clock warp)

  void _stepWarp(int delta) {
    final next = (_warpIndex + delta).clamp(0, _warpLevels.length - 1);
    if (next == _warpIndex && _warpTarget == null) return;
    setState(() {
      _warpTarget = null; // manual warp input cancels an auto warp-to-apsis
      _warpTargetLabel = null;
      _warpIndex = next;
      _clock.warpFactor = _warpLevels[_warpIndex];
    });
  }

  /// Warp-to-AP/PE: sim epoch to auto-warp to, or null when inactive. Each
  /// frame the warp factor is re-fit to the remaining time (arrive in ~1.5
  /// real seconds), so the approach decelerates smoothly and lands within a
  /// tick of the apsis before dropping back to 1x.
  Epoch? _warpTarget;
  String? _warpTargetLabel; // 'AP' / 'PE' chip text while active

  /// Compact sim-time countdown for the warp chip: 42s / 12m34s / 3h07m.
  static String _fmtCountdown(double s) {
    if (s < 60) return '${s.toStringAsFixed(0)}s';
    if (s < 3600) {
      return '${s ~/ 60}m${(s % 60).toStringAsFixed(0).padLeft(2, '0')}s';
    }
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    return '${h}h${m.toString().padLeft(2, '0')}m';
  }

  void _warpToApsis({required bool periapsis}) {
    final id = _focusVessel;
    final v = id == null ? null : _vessels.byId(id);
    if (v == null || v.landed) return;
    final body = _universe.current().body(v.dominantBody);
    if (body == null) return;
    final label = periapsis ? 'PE' : 'AP';
    // Pressing the active button again cancels.
    if (_warpTarget != null && _warpTargetLabel == label) {
      setState(() {
        _warpTarget = null;
        _warpTargetLabel = null;
        _clock.warpFactor = _warpLevels[_warpIndex];
      });
      return;
    }
    final orbit = const StateVectorOrbitConverter().toOrbit(
      position: v.state.position,
      velocity: v.state.velocity,
      body: body,
      epoch: _clock.epoch,
    );
    final el = orbit.elements;
    // Escape / radial-degenerate: no closed orbit, no apses to warp to.
    if (el.eccentricity >= 1 ||
        !el.semiMajorAxis.isFinite ||
        el.semiMajorAxis <= 0) {
      return;
    }
    final n = el.meanMotion(orbit.mu);
    if (!n.isFinite || n <= 0) return;
    final twoPi = 2 * math.pi;
    final m = ((orbit.meanAnomalyAt(_clock.epoch) % twoPi) + twoPi) % twoPi;
    // Mean anomaly of the target apsis: PE at 0 (2pi ahead), AP at pi.
    var ahead = ((periapsis ? twoPi : math.pi) - m + twoPi) % twoPi;
    // Already sitting on the apsis: wrap a full orbit instead of a 0s warp.
    if (ahead / n < 2.0) ahead += twoPi;
    setState(() {
      _warpTarget = _clock.epoch + ahead / n;
      _warpTargetLabel = label;
    });
  }

  Duration _last = Duration.zero;
  double _accum = 0; // carried-over real time not yet consumed by a fixed step

  // ---- Perf overlay --------------------------------------------------------
  // Same instrumentation the terrain studio's perf panel already has (see
  // TerrainStudioScreen._perfPanel) — ported here so a real-flight slowdown
  // (as opposed to a studio-only one) is diagnosable the same way, without
  // reaching for DevTools.
  final List<double> _frameMs = [];
  final List<double> _uiMs = [];
  final List<double> _rasterMs = [];
  TimingsCallback? _timingsCb;

  /// Last frame's [TopDownSnapshotPresenter.present] cost (ms). Runs inside
  /// _onFrame's setState EVERY tick — on the flutterScene backend its output
  /// feeds only the HUD overlay, yet unflagged it still resamples every
  /// body's orbit rail and ring outline the 3D scene never reads.
  double _presentMs = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBackendPref());
    _registerControl();
    // The road ghost lives in renderer statics, and the toolbar commits and
    // cancels the spline without going anywhere near them — so a finished road
    // left its preview hanging over the world forever. Re-sync whenever the
    // editor's state changes, which is the one event both paths share.
    _cityEdit.addListener(_onCityEditChanged);

    // The REAL Solar System: Sun + planets + dwarf planets + moons.
    final system = SampleWorld.realSystem();
    // Built-in demo orbiter: a generic craft in low lunar orbit (~100 km).
    // Suppressed when the caller injects its own full fleet.
    final demo = widget.spawnDemoOrbiter
        ? SampleWorld.buildEarthOrbiter(
            bodyId: SampleWorld.moon, altitude: 100000)
        : null;
    // An ascent/descent craft injected by the caller (sits on a body surface).
    final injected = widget.injectedVessel;
    final fleet = [?demo, ?injected, ...widget.trafficVessels];

    // A halo ring mid-construction in high Earth orbit. Built here (not
    // inline in the session ctor) because the target list below needs the
    // same instances BEFORE `_session` is assigned — reading the late field
    // that early is a LateInitializationError.
    final megastructures = [SampleWorld.buildHaloRing()];

    // Camera-target cycle: every vessel first, then the major bodies, then any
    // sited megastructures. The switch-camera button steps through this list.
    _targets = [
      for (final v in fleet) (label: v.name, v: v.id, b: null, m: null),
      for (final body in system.all)
        (label: body.name, v: null, b: body.id, m: null),
      for (final mega in megastructures)
        if (mega.site != null && mega.ringSpec != null)
          (label: mega.id, v: null, b: null, m: mega.id),
    ];
    // START LOCKED ON the injected craft if any (fly it immediately); else the
    // demo orbiter so the player can fly it directly from the start (manual
    // mode, see the flags below).
    final focusId = injected?.id ?? demo?.id;
    _targetIndex =
        focusId == null ? 0 : _targets.indexWhere((t) => t.v == focusId);
    if (_targetIndex < 0) _targetIndex = 0;
    // A studio city is the subject: point the camera at its world rather than
    // at whatever craft happens to exist.
    final studioCity = widget.injectedCity;
    if (studioCity != null && injected == null) {
      final i = _targets.indexWhere((t) => t.b == studioCity.body.id);
      if (i >= 0) _targetIndex = i;
    }
    _focusVessel = _targets[_targetIndex].v;
    _focusBody = _targets[_targetIndex].b;
    _focusMega = _targets[_targetIndex].m;

    // Start ready to fly: manual control of the orbiter, infinite fuel, 1x warp.
    _manualControl = true;
    _layers = _layers.copyWith(infiniteFuel: true);
    _warpIndex = _warp1x;

    _session = FlightSession(
      system: system,
      fleet: fleet,
      // Minable asteroid lodes — mining them excavates the voxel terrain.
      deposits: SampleWorld.buildAsteroidDeposits(),
      megastructures: megastructures,
      // Pop a destruction menu when a vessel is lost.
      onEvent: _onDomainEvent,
    );
    // A colony handed over by the caller (the city studio), registered with
    // the WORLD so the authoritative tick advances it and the scene draws it
    // exactly as it would a colony founded in flight.
    //
    // AFTER the session exists: `_session` is `late final`, and reaching for
    // its city repository before this line threw a LateInitializationError
    // that took the whole app down on open.
    final city = widget.injectedCity;
    if (city != null) _session.cities.add(city);

    for (final v in _vessels.all()) {
      _vesselNames[v.id.value] = v.name;
    }
    _presenter = TopDownSnapshotPresenter(
        vessels: _vessels, universe: _universe, colonies: _colonies);

    // Body surface maps; repaint once each finishes decoding.
    _textures = TextureCache(
      onReady: () {
        if (mounted) setState(() {});
      },
    );

    // Open the engine bridge: serve this sim to a connected Unreal renderer and
    // apply the commands it sends back to the SAME repos the Flutter views use.
    // No-op on web (the stub). Fire-and-forget — a bind failure (port in use)
    // shouldn't stop the game from running in-process.
    _bridge = createSimBridge();
    // A failed bind (port 5800 already held by a second instance or the
    // standalone sim_server) must not surface as an unhandled async error —
    // `unawaited` only silences the lint, not the throw. The game runs fine
    // in-process; only the external-renderer bridge is unavailable.
    unawaited(_bridge.start().catchError((Object _) {}));
    _bridgeCommands = _bridge.commandFrames.listen(_applyBridgeCommands);

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

  /// Apply a CommandFrame from a connected renderer (Unreal) to the live repos.
  /// This is the local serve path: the single connected renderer is trusted, so
  /// — unlike the networked [ApplyCommands] use case — there's no ownership gate.
  /// Mirrors that use case's per-command handling so behaviour stays in step.
  void _applyBridgeCommands(Uint8List frame) {
    final CommandBatch batch;
    try {
      batch = _wire.decodeCommands(frame);
    } catch (_) {
      return; // ignore a malformed/foreign frame rather than crash the loop
    }
    for (final cmd in batch.commands) {
      switch (cmd) {
        case SetThrottleCommand(:final vesselId, :final throttle):
          final v = _vessels.byId(VesselId(vesselId));
          if (v != null) {
            v.setThrottle(throttle);
            _vessels.save(v);
          }
        case SeparateStageCommand(:final vesselId):
          final v = _vessels.byId(VesselId(vesselId));
          if (v != null && v.separateStage()) _vessels.save(v);
        case SetAttitudeCommand(:final vesselId, :final headingX, :final headingY, :final headingZ):
          final v = _vessels.byId(VesselId(vesselId));
          if (v != null) {
            v.targetFacing = Vector3(headingX, headingY, headingZ);
            _vessels.save(v);
          }
        case PlaceBuildingCommand():
        case ReportTerrainHeightCommand():
          break; // colony/terrain intent not served on this path
      }
    }
  }

  /// (Re)build the tick with the current debug-cheat flags.
  ///
  /// The cheat setters already rebuild the tick through the session, so
  /// this only exists for the call sites that toggle several at once.
  void _buildAdvance() => _session.rebuildTick();

  /// React to simulation events. Right now: surface a destruction menu when a
  /// vessel is lost (hard impact, structural overstress, or part burn-up).
  void _onDomainEvent(DomainEvent e) {
    // Every event also rides the next frame's WorldSnapshot so renderers can
    // key FX off it (e.g. terrain-impact dust). Capped: a runaway warp frame
    // must not balloon a cosmetic list.
    if (_frameEvents.length < 64) _frameEvents.add(EventSnapshot.of(e));
    String nameOf(VesselId id) => _vesselNames[id.value] ?? id.value;
    ({String title, String detail})? notice;
    // Cheat-gated: the thermal/structural SUBSYSTEMS still raise their
    // events when a limit is exceeded — only the tick's DESTRUCTION check
    // honours the cheats. With a cheat on, the craft survives, so popping
    // the death menu for the event alone is a lie ("burned up" while the
    // ship flies on).
    // Test impactors are SUPPOSED to die — their loss is the experiment's
    // result, not an emergency worth a death dialog over the readouts.
    if (e is Impact && e.vessel.value.startsWith('impactor-')) return;
    if (e is Impact && !_disableCraftDestruction) {
      notice = (
        title: '${nameOf(e.vessel)} destroyed',
        detail:
            'Hard impact with ${e.body.value} at '
            '${e.speed.toStringAsFixed(0)} m/s. The craft was lost.',
      );
    } else if (e is StructuralFailure && !_disableAeroStress) {
      notice = (
        title: '${nameOf(e.vessel)} broke up',
        detail:
            'Structural failure under aerodynamic load '
            '(${(e.dynamicPressure / 1000).toStringAsFixed(1)} kPa).',
      );
    } else if (e is PartOverheated && !_disableOverheat) {
      notice = (
        title: '${nameOf(e.vessel)} burned up',
        detail:
            'A part exceeded its temperature limit '
            '(${e.temperature.toStringAsFixed(0)} K) on reentry.',
      );
    }
    if (notice != null && mounted) {
      // Only the FIRST loss this frame pops; later ones don't stomp the message.
      setState(() => _crashNotice ??= notice);
    }
  }

  void _onFrame(Duration elapsed) {
    final frameDt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    // Guard as the terrain studio's does: reject the first tick (no prior
    // _last) and any outlier from a debugger pause or dropped-frame spike,
    // which would otherwise dominate the rolling average.
    final frameMsSample = frameDt * 1000;
    if (frameMsSample > 0 && frameMsSample < 500) {
      _frameMs.add(frameMsSample);
      if (_frameMs.length > 90) _frameMs.removeAt(0);
    }

    // Track the focused vessel's dominant body so that if the vessel is removed
    // (a hard impact destroys it â€” common when landing fast on an airless body
    // like the Moon), we can retarget the camera to that body instead of letting
    // the focus dangle: a dangling vessel focus makes camWorld fall to the system
    // root, snapping the camera to the Sun and culling the (now-gone) craft.
    if (_focusVessel != null) {
      final fv = _vessels.byId(_focusVessel!);
      if (fv != null) {
        _lastFocusBody = fv.dominantBody;
      } else {
        // Vessel gone â€” lock onto its last body so the view stays put.
        _focusBody = _lastFocusBody;
        _focusVessel = null;
        _craftCam = false; // no craft to chase
        _manualControl = false;
        final idx = _targets.indexWhere((t) => t.b == _focusBody);
        if (idx >= 0) _targetIndex = idx;
      }
    }

    // Manual flight: apply pilot input to the focus vessel each frame. Only a
    // vessel can be piloted; if a body is the camera target, manual is a no-op.
    if (_manualControl && _focusVessel != null) {
      final vessel = _vessels.byId(_focusVessel!);
      if (vessel != null) {
        vessel.flightPlan = null; // manual overrides autopilot (exclusive)
        _pilot.apply(vessel, _readPilotInput(), dt: frameDt.clamp(0.0, 0.1));
        // Hand-flying inside the atmosphere MUST run near real time — at high
        // warp a launch builds km/s of speed in dense air in a single frame and
        // tears apart at max-Q. Force 1x while piloting in atmosphere.
        final body = _universe.current().body(vessel.dominantBody);
        final alt = vessel.state.position.length - (body?.radius ?? 0);
        final atmoH = body?.atmosphere?.atmosphereHeight ?? 0;
        if (atmoH > 0 && alt < atmoH && _clock.warpFactor > 1) {
          _warpIndex = _warp1x;
          _clock.warpFactor = _warpLevels[_warp1x];
          _warpTarget = null; // atmosphere overrides an auto warp-to-apsis
          _warpTargetLabel = null;
        }
      }
    }

    // Freecam flight: WASD in the camera frame, Q/E down/up, Shift boosts.
    // Speed scales with zoom range so it feels right from surface to map.
    if (_freecam) {
      double axis(LogicalKeyboardKey neg, LogicalKeyboardKey pos) =>
          (_keysDown.contains(pos) ? 1.0 : 0.0) -
          (_keysDown.contains(neg) ? 1.0 : 0.0);
      final fwd = axis(LogicalKeyboardKey.keyS, LogicalKeyboardKey.keyW);
      final strafe = axis(LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyD);
      final lift = axis(LogicalKeyboardKey.keyQ, LogicalKeyboardKey.keyE);
      if (_walkMode) {
        if (_evaPack) {
          _stepEva(fwd, strafe, frameDt);
        } else {
          _stepWalk(fwd, strafe, frameDt);
        }
        _stepDrill(frameDt);
        _syncWalkerBody();
      } else if (fwd != 0 || strafe != 0 || lift != 0) {
        final cam = _camera;
        final boost =
            _keysDown.contains(LogicalKeyboardKey.shiftLeft) ? 8.0 : 1.0;
        final speed =
            math.max(_range, 5.0) * 1.5 * boost * _freecamSpeedMul; // m/s
        final dt = frameDt.clamp(0.0, 0.1);
        // World-frame flight delta, banked into the rotating frame.
        _freecamRelLocal = _freecamRelLocal +
            _refBodyQuat().conjugate.rotate(
                (cam.forward * fwd + cam.right * strafe + cam.up * lift) *
                    (speed * dt));
      }
    }

    // Infinite-fuel cheat: top every tank back to full each frame.
    if (_layers.infiniteFuel) {
      for (final v in _vessels.all()) {
        for (final p in v.allParts) {
          for (final r in p.resources) {
            r.amount = r.capacity;
          }
        }
      }
    }

    // Auto warp-to-apsis: refit the warp factor to the remaining time every
    // frame (smooth deceleration), drop to 1x on arrival.
    if (_warpTarget != null) {
      final remaining = _warpTarget!.seconds - _clock.epoch.seconds;
      if (remaining <= 0.5) {
        _warpTarget = null;
        _warpTargetLabel = null;
        _warpIndex = _warp1x;
        _clock.warpFactor = _warpLevels[_warp1x];
      } else {
        _clock.warpFactor = (remaining / 1.5).clamp(1.0, 1e6);
      }
    }

    // Run as many fixed steps as real time accrued. Carry the leftover across
    // frames â€” a 16ms frame is < the 20ms fixed step, so without accumulation
    // most frames ran ZERO steps and the sim only advanced on the occasional
    // slow frame (the jumpy "random update" motion).
    _accum += frameDt;
    var steps = 0;
    final swSteps = Stopwatch()..start();
    // PAUSE (warp 0): skip the tick entirely — running subsystems with a
    // zero dt is untested ground, and draining the backlog keeps unpausing
    // from replaying accumulated time.
    if (_clock.warpFactor <= 0) _accum = 0;
    while (_accum >= _clock.fixedStep && steps < 25) {
      _advance.execute(_clock);
      _accum -= _clock.fixedStep;
      steps++;
    }
    // If we hit the step cap (e.g. a long first frame or a stall), drop the
    // backlog instead of spiralling â€” better to skip time than freeze. 25
    // steps absorbs a half-second hiccup; a longer stall (asset loads, GC)
    // skips time rather than replaying it at ~10-30ms a step.
    if (steps >= 25) _accum = 0;
    if (swSteps.elapsedMilliseconds > 500) {
      debugPrint('simSteps: $steps steps in ${swSteps.elapsedMilliseconds}ms');
    }

    // Events raised by the steps above, flattened for the renderers. Drained
    // per frame whether or not anyone captures — the software backend must not
    // let the list grow without bound.
    final frameEvents = _frameEvents.isEmpty
        ? const <EventSnapshot>[]
        : List<EventSnapshot>.unmodifiable(_frameEvents);
    _frameEvents.clear();

    // Serve the freshly-advanced world to any connected renderer (Unreal). Gated
    // on hasClients so capture+encode cost is zero when nothing's attached. The
    // static body descriptors (kind/atmosphere/composition) are sticky on the
    // engine side, so ship them only ~1 Hz instead of every frame.
    if (_bridge.hasClients) {
      final sendDescriptors = (elapsed - _lastDescriptorAt) >= const Duration(seconds: 1);
      if (sendDescriptors) _lastDescriptorAt = elapsed;
      final world = WorldSnapshot.capture(
        _bridgeTick++,
        _vessels,
        system: _universe.current(),
        epoch: _clock.epoch,
        colonies: _colonies,
        cities: _cities,
        terrainEdits: _terrainEdits,
        megastructures: _session.megastructures,
        includeDescriptors: sendDescriptors,
        events: frameEvents,
      );
      _bridge.publish(_wire.encodeWorld(world));
    }

    // The flutter_scene backend consumes the SAME world feed in-process (no
    // serialization). Descriptors ride along every frame — the join is by
    // reference, not over a wire.
    if (_renderBackend == RenderBackend.flutterScene) {
      _sceneWorld = WorldSnapshot.capture(
        _sceneTick++,
        _vessels,
        system: _universe.current(),
        epoch: _clock.epoch,
        colonies: _colonies,
        cities: _cities,
        terrainEdits: _terrainEdits,
        megastructures: _session.megastructures,
        events: frameEvents,
      );
    } else {
      _sceneWorld = null;
    }

    // Encounter planner: refresh the trial plan + its render overlay
    // (throttled inside; cheap no-op when the planner is closed).
    _updatePlannerPlan();

    // Equator-aligned camera: gimbal the whole orbit in the focused body's
    // TILTED frame — azimuth then circles the body's equator, elevation
    // climbs toward its pole, and the pole reads upright on screen. (A
    // roll-only alignment was tried first: it levelled the horizon but the
    // orbit axes still followed the ecliptic, which felt wrong on every
    // drag.)
    if (_upMode != CameraUpMode.free && !_craftCam) {
      final bodyId = _focusBody ?? _lastFocusBody;
      final body = bodyId == null ? null : _universe.current().body(bodyId);
      final vessel =
          _focusVessel == null ? null : _vessels.byId(_focusVessel!);
      Quaternion frame;
      // ON FOOT the walker IS the local vertical. Without this the gimbal fell
      // back to the body's equator (there is no focused vessel while walking),
      // so "elevation" tilted toward the pole instead of toward the ground:
      // looking down was impossible, the horizon sat askew, and anything that
      // aims by looking — the drill, the lamp — pointed at the sky.
      final walkRadial = _walkMode && _freecamRelLocal.length > 1e-3
          ? _refBodyQuat().rotate(_freecamRelLocal).normalized
          : null;
      if (walkRadial != null) {
        final prevFrame = _gravFrame;
        final prevRadial = _gravRadial;
        frame = prevFrame == null || prevRadial == null
            ? _shortestArc(Vector3.unitZ, walkRadial)
            : (_shortestArc(prevRadial, walkRadial) * prevFrame).normalized;
        _gravFrame = frame;
        _gravRadial = walkRadial;
      } else if (_upMode == CameraUpMode.gravity &&
          vessel != null &&
          vessel.state.position.length > 1e-3) {
        // Local vertical: the radial through the vessel (its position is
        // dominant-body-centred with root-parallel axes, so the direction
        // needs no reframing). Gimbal +Z onto it — azimuth then circles
        // the horizon and elevation climbs from horizon to zenith.
        //
        // Updated INCREMENTALLY (small arc from the previous radial
        // composed onto the previous frame): a fresh shortest-arc from
        // +Z each frame is discontinuous when the radial passes near -Z
        // (the arc axis flips 180 degrees) — the camera snapped to a
        // "random" orientation when the vessel crossed under the body.
        final radial = vessel.state.position.normalized;
        final prevFrame = _gravFrame;
        final prevRadial = _gravRadial;
        if (prevFrame == null || prevRadial == null) {
          frame = _shortestArc(Vector3.unitZ, radial);
        } else {
          frame = (_shortestArc(prevRadial, radial) * prevFrame).normalized;
        }
        _gravFrame = frame;
        _gravRadial = radial;
      } else {
        _gravFrame = null;
        _gravRadial = null;
        final t = body?.axialTilt ?? 0;
        frame = t == 0
            ? Quaternion.identity
            : Quaternion.axisAngle(Vector3.unitX, t);
      }
      _view = _view.copyWith(frame: frame, roll: 0);
    } else if (_view.frame.x != 0 ||
        _view.frame.y != 0 ||
        _view.frame.z != 0) {
      _view = _view.copyWith(frame: Quaternion.identity);
    }

    // Craft chase cam: align the camera EXACTLY with the craft's attitude so the
    // view tracks yaw, pitch AND roll. The camera builds its basis from
    // (azimuth, elevation, roll) as:
    //   forward = (cosE*sinA, cosE*cosA, -sinE)
    //   rightBase = (cosA, -sinA, 0),  upBase = rightBase x forward
    //   up = upBase*cosR - rightBase*sinR,  right = rightBase*cosR + upBase*sinR
    // We invert that for the craft's nose/up so the camera looks down the nose
    // with the craft's up as screen-up. Previously the angles were reconstructed
    // with ad-hoc decoupled formulas that didn't form a consistent rotation, so
    // the view drifted off the craft's true orientation.
    if (_craftCam && _focusVessel != null) {
      final v = _vessels.byId(_focusVessel!);
      if (v != null) {
        final nose = v.state.attitude.rotate(Vector3.unitZ); // forward
        final craftUp = v.state.attitude.rotate(Vector3.unitY);

        // elevation = asin(-forward.z); azimuth = atan2(forward.x, forward.y).
        final elevation = math.asin((-nose.z).clamp(-1.0, 1.0));
        final azimuth = math.atan2(nose.x, nose.y);

        // Reconstruct the camera's UNROLLED up (upBase) for this az/el, then the
        // roll is the signed angle from upBase to the craft's up about the nose.
        final ca = math.cos(azimuth), sa = math.sin(azimuth);
        final rightBase = Vector3(ca, -sa, 0);
        final upBase = rightBase.cross(nose).normalized;
        // camera up = upBase*cosR - rightBase*sinR  =>  sinR = -craftUp.rightBase,
        // cosR = craftUp.upBase  =>  roll = atan2(-craftUp.rightBase, craftUp.upBase).
        final roll = math.atan2(-craftUp.dot(rightBase), craftUp.dot(upBase));

        _view = _view.copyWith(azimuth: azimuth, elevation: elevation, roll: roll);
      }
    }

    _recordTrail();

    final cam = _camera;
    setState(() {
      _activeCamera = cam;
      final sw = Stopwatch()..start();
      _snapshot = _presenter.present(
        focus: _focusVessel,
        focusBodyId: _focusBody,
        camera: cam,
        epoch: _clock.epoch,
        science: _research.science,
        cullDistant: _layers.cullDistant,
        flownTrail: _trail,
        flownTrailBody: _trailBody,
        // The 3D backend draws its own rails/rings/trail in-scene
        // (LineNodes/RingNodes); this snapshot then feeds ONLY the HUD
        // overlay (labels, markers, patch legs, telemetry text), so skip
        // projecting the polylines nobody reads — measured, they were the
        // bulk of a 20ms+ per-frame present() on a full system.
        hudOnly: _renderBackend == RenderBackend.flutterScene,
      );
      _presentMs = sw.elapsedMicroseconds / 1000;
    });
  }

  // ---- Flown trajectory trail (breadcrumb for the focused vessel) ----
  // Body-relative positions of the focused vessel, sampled by distance. Reset
  // when the focus or its dominant body changes so the line doesn't streak
  // across an SOI switch.
  final List<Vector3> _trail = [];
  BodyId? _trailBody; // dominant body the trail points are relative to
  VesselId? _trailVessel; // which vessel the trail belongs to
  static const int _trailMax = 600; // cap; oldest points drop off
  static const double _trailMinStep = 500; // metres between samples

  /// Append the focused vessel's current position to the trail (sampled by
  /// distance). Clears + restarts when the focus vessel or its dominant body
  /// changes.
  void _recordTrail() {
    final id = _focusVessel;
    final v = id == null ? null : _vessels.byId(id);
    if (v == null) {
      _trail.clear();
      _trailVessel = null;
      _trailBody = null;
      return;
    }
    if (id != _trailVessel || v.dominantBody != _trailBody) {
      _trail.clear();
      _trailVessel = id;
      _trailBody = v.dominantBody;
    }
    final p = v.state.position;
    if (_trail.isEmpty || (p - _trail.last).length > _trailMinStep) {
      _trail.add(p);
      if (_trail.length > _trailMax) _trail.removeAt(0);
    }
  }

  @override
  void dispose() {
    _cityEdit.removeListener(_onCityEditChanged);
    SimViewControl.instance.clear();
    final timingsCb = _timingsCb;
    if (timingsCb != null) {
      SchedulerBinding.instance.removeTimingsCallback(timingsCb);
    }
    _ticker.dispose();
    unawaited(_bridgeCommands?.cancel());
    unawaited(_bridge.stop());
    _keyFocus.dispose();
    _textures.dispose();
    _spawnAltCtrl.dispose();
    _impactMassCtrl.dispose();
    _impactSpeedCtrl.dispose();
    super.dispose();
  }

  /// Lock the camera onto target [i] in the list (vessel or body).
  void _selectTarget(int i) {
    setState(() {
      _targetIndex = i;
      final t = _targets[i];
      _focusVessel = t.v;
      _focusBody = t.b;
      _focusMega = t.m;
      // A body can't be piloted, so drop manual mode when locking onto one.
      if (t.v == null) _manualControl = false;
    });
    // The dropdown stole keyboard focus â€” hand it back so arrow keys (camera
    // orbit) and the other shortcuts keep working after a target switch.
    _keyFocus.requestFocus();
  }

  /// Cycle the projection through the named presets (snaps the orbit angles).
  void _cycleView() => setState(() => _view = CameraOrbit.preset(_view.nearestPreset.next));

  /// Toggle MAP <-> CRAFT chase cam. Entering craft cam locks onto a vessel and
  /// zooms in close; leaving it restores the saved map zoom + view.
  void _toggleCraftCam() {
    setState(() {
      _craftCam = !_craftCam;
      if (!_craftCam) {
        // The chase cam drives roll from the craft attitude every frame;
        // leaving it with that roll makes every subsequent MMB drag
        // rotate through the STALE angle (drags feel diagonal/reversed —
        // "the camera jumps around").
        _view = _view.copyWith(roll: 0);
      }
      if (_craftCam) {
        // Ensure a vessel is the target (fall back to the first vessel).
        if (_focusVessel == null) {
          final v = _vessels.all().isEmpty ? null : _vessels.all().first;
          if (v == null) {
            _craftCam = false;
            return;
          }
          _focusVessel = v.id;
          _focusBody = null;
          _focusMega = null;
        }
        _mapMpp = _metresPerPixel; // remember map zoom
        _metresPerPixel = 60.0; // close chase zoom (ortho fallback)
        // Chase cam reads best with perspective: the eye sits behind the craft
        // (eye = target - nose*range) looking down the nose. A short range frames
        // the craft ahead with the world beyond it.
        _perspectiveMode = true;
        _range = 150.0; // ~5 craft lengths behind
      } else {
        _metresPerPixel = _mapMpp; // restore map zoom
        _view = CameraOrbit.top;
      }
    });
    _keyFocus.requestFocus();
  }

  /// Rotate the focus craft so its nose (+Z) points at its dominant body's
  /// centre. In the body frame the planet is at the origin, so the look
  /// direction is just -position.
  /// True when the locked craft has more than one stage to drop.
  bool _canStageFocus() {
    final id = _focusVessel;
    if (id == null) return false;
    final v = _vessels.byId(id);
    return v != null && v.stages.length > 1;
  }

  /// Decouple the active (lowest) stage off the focused craft. The dropped
  /// stage's mass leaves the vessel; the remaining stack keeps flying.
  void _separateFocusStage() {
    final id = _focusVessel;
    if (id == null) return;
    final v = _vessels.byId(id);
    if (v == null) return;
    if (v.separateStage()) setState(() {});
  }

  void _lookAtPlanet() {
    final id = _focusVessel;
    if (id == null) return;
    final v = _vessels.byId(id);
    if (v == null) return;
    final pos = v.state.position;
    if (pos.length < 1) return;
    final dir = (pos * -1).normalized; // toward the planet centre
    // fromTo(+Z, dir): axis = Z x dir, angle = acos(Z . dir).
    final dot = Vector3.unitZ.dot(dir).clamp(-1.0, 1.0);
    Quaternion q;
    if (dot > 0.9999) {
      q = Quaternion.identity; // already aligned
    } else if (dot < -0.9999) {
      q = Quaternion.axisAngle(Vector3.unitX, math.pi); // opposite -> flip
    } else {
      q = Quaternion.axisAngle(Vector3.unitZ.cross(dir), math.acos(dot));
    }
    v.flightPlan = null; // manual override
    v.updateState(v.state.copyWith(attitude: q.normalized));
    setState(() {});
    _keyFocus.requestFocus();
  }

  /// Orbit the camera around the focus by arrow-key deltas (radians).
  void _orbitCamera(double dAz, double dEl) {
    // Screen-drag deltas are in VIEW space: when the camera is rolled
    // (align-up mode tracks a tilted spin axis), a horizontal drag must
    // still pan horizontally ON SCREEN — rotate the deltas through the
    // roll, or drags feel 90-degrees-wrong under a rolled camera.
    final r = _view.roll;
    final ca = math.cos(r), sa = math.sin(r);
    final az = dAz * ca - dEl * sa;
    final el = dAz * sa + dEl * ca;
    setState(() {
      if (_freecam) {
        // FPS-style look: the EYE stays put and the view direction pans —
        // the anchor swings around the eye instead of the eye orbiting
        // the anchor (which read as "panning around a point massively far
        // away"). Keep the eye world-invariant across the rotation.
        final eyeBefore = _camera.eyeOffset;
        _view = _view.copyWith(
            azimuth: _view.azimuth + az, elevation: _view.elevation + el);
        _freecamRelLocal = _freecamRelLocal +
            _refBodyQuat().conjugate.rotate(eyeBefore - _camera.eyeOffset);
      } else {
        _view = _view.copyWith(
            azimuth: _view.azimuth + az, elevation: _view.elevation + el);
      }
    });
  }

  /// Teleport the focused craft to a debug spawn preset — the quick way to get
  /// eyes on a scene (ground, water, low orbit, another world, the rings)
  /// without flying there.
  void _spawnAt(SpawnPreset preset) {
    final placement = const SpawnPresets()
        .resolve(preset, system: _universe.current(), epoch: _clock.epoch);
    if (placement == null) return; // body not in this system
    _applyPlacement(placement, viewRange: _spawnViewRange(preset));
  }

  /// Teleport the focused craft to the CUSTOM spawn the panel describes: the
  /// picked body, either landed (scored land-site hunt) or on a circular
  /// equatorial orbit at the typed altitude. A non-numeric altitude no-ops
  /// rather than guessing.
  void _spawnCustom({required bool landed}) {
    final system = _universe.current();
    final bodyId = _spawnCustomBodyId();
    if (bodyId == null) return;
    SpawnPlacement? placement;
    if (landed) {
      placement = const SpawnPresets()
          .customLanded(bodyId, system: system, epoch: _clock.epoch);
    } else {
      final altKm = double.tryParse(_spawnAltCtrl.text.trim());
      if (altKm == null || !altKm.isFinite || altKm < 0) return;
      placement = const SpawnPresets()
          .customOrbit(bodyId, system: system, altitude: altKm * 1000);
    }
    if (placement == null) return;
    // Surface framing wants to read the ground; orbit wants the planet behind
    // the craft — the same distances the fixed presets use.
    _applyPlacement(placement, viewRange: landed ? 150 : 600);
  }

  /// Drop a throwaway test mass beside the focused craft, falling straight
  /// down at the panel's typed mass and speed — the quick way to compare
  /// impact outcomes (bounce/land/destroy, crater size vs energy) without
  /// re-flying a crash profile each time.
  ///
  /// Spawns 60 m to the side so the crater (and the destruction) land next to
  /// the observer, not under it, and 30 m up so the fall adds little speed of
  /// its own. Respects both cheats as the panel has them: cratering is
  /// orthogonal to craft destruction, so a drop digs its hole even while
  /// "No craft destruction" is on (the surviving lump settles into it).
  void _dropImpactor() {
    final id = _focusVessel;
    final v = id == null ? null : _vessels.byId(id);
    if (v == null) return;
    final body = _universe.current().body(v.dominantBody);
    if (body == null) return;
    final mass = double.tryParse(_impactMassCtrl.text.trim());
    final speed = double.tryParse(_impactSpeedCtrl.text.trim());
    if (mass == null || mass <= 0 || !mass.isFinite) return;
    if (speed == null || speed <= 0 || !speed.isFinite) return;

    final dir = v.state.position.lengthSquared > 0
        ? v.state.position.normalized
        : Vector3.unitX;
    final ref = dir.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
    final side = ref.cross(dir).normalized;
    final beside = v.state.position + side * 60.0;
    final besideDir = beside.normalized;
    final ground = body.terrainGroundRadius(beside, _clock.epoch,
        edits: _terrainEdits.forBody(body.id));

    _impactorCount++;
    _vessels.save(Vessel(
      id: VesselId('impactor-$_impactorCount'),
      name: 'Impactor $_impactorCount',
      ownerId: v.ownerId,
      state: StateVector(
        position: besideDir * (ground + 30.0),
        velocity: besideDir * -speed,
      ),
      dominantBody: v.dominantBody,
      stages: [
        Stage(index: 0, parts: [
          Part(
            id: PartId('impactor-$_impactorCount-hull'),
            name: 'Test mass',
            dryMass: mass,
            crossSectionArea: 4,
          ),
        ]),
      ],
    ));
  }

  /// The custom-spawn target: the panel's pick when set, else the body the
  /// camera last cared about, else the first body in the system.
  BodyId? _spawnCustomBodyId() {
    final system = _universe.current();
    final picked = _spawnBody;
    if (picked != null && system.body(picked) != null) return picked;
    final last = _focusBody ?? _lastFocusBody;
    if (last != null && system.body(last) != null) return last;
    final all = system.all;
    return all.isEmpty ? null : all.first.id;
  }

  /// Write [placement] onto the focused craft and re-frame the camera [viewRange]
  /// metres off it. Warp drops to 1x and the camera locks on so what was asked
  /// for is on screen the moment it lands. Shared by the preset buttons and the
  /// custom body/altitude spawn.
  void _applyPlacement(SpawnPlacement placement, {required double viewRange}) {
    final all = _vessels.all();
    final id = _focusVessel ?? (all.isEmpty ? null : all.first.id);
    if (id == null) return;
    final vessel = _vessels.byId(id);
    if (vessel == null) return;

    // Nothing from the old flight carries across a teleport.
    vessel.flightPlan = null;
    vessel.docking = null;
    vessel.targetFacing = null;
    vessel.setThrottle(0);
    vessel.dominantBody = placement.body;
    vessel.landed = placement.landed;
    vessel.mode =
        placement.landed ? PropagationMode.physics : PropagationMode.onRails;
    vessel.updateState(placement.state);
    _vessels.save(vessel);

    setState(() {
      // Lock onto the craft we just moved (a body lock would look at the wrong
      // world entirely).
      _focusVessel = id;
      _focusBody = null;
      _lastFocusBody = placement.body;
      final idx = _targets.indexWhere((t) => t.v == id);
      if (idx >= 0) _targetIndex = idx;
      _freecam = false; // its anchor is a whole planet away now
      // The breadcrumb would streak across the jump (it only self-clears on an
      // SOI change, and a same-body teleport isn't one).
      _trail.clear();
      _trailVessel = null;
      _trailBody = null;
      // A warp-to-apsis was aimed at the OLD orbit; high warp on a fresh
      // surface spawn just throws the craft around.
      _warpTarget = null;
      _warpTargetLabel = null;
      _warpIndex = _warp1x;
      _clock.warpFactor = _warpLevels[_warp1x];
      // Local-vertical gimbal, re-seeded: the frame is integrated from the
      // previous radial each frame, so a teleport would compose a huge bogus
      // arc onto it.
      _upMode = CameraUpMode.gravity;
      _gravFrame = null;
      _gravRadial = null;
      _view = CameraOrbit.preset(CameraView.threeQuarter);
      _perspectiveMode = true;
      _range = viewRange;
      _metresPerPixel = (_range / 100).clamp(0.5, 2e10); // ortho fallback
    });
    _keyFocus.requestFocus();
  }

  /// Nav-ball state for the currently-locked vessel, or null when a body is the
  /// camera target (no craft attitude to show).
  NavState? _navState() {
    final id = _focusVessel;
    if (id == null) return null;
    final v = _vessels.byId(id);
    return v == null ? null : NavState.fromVessel(v);
  }

  /// Dropdown to pick the camera lock target. Vessels are listed first, then
  /// the celestial bodies, matching the [_targets] order.
  /// PERSP on/off; long-press cycles FOV (40/55/70/90).
  Widget _perspToggleFab() {
    return GestureDetector(
      onLongPress: () {
        const opts = [40.0, 55.0, 70.0, 90.0];
        final i = opts.indexWhere((o) => o >= _fovDeg);
        setState(() => _fovDeg = opts[(i + 1) % opts.length]);
      },
      child: FloatingActionButton.extended(
        heroTag: 'persp',
        backgroundColor: _perspectiveMode ? const Color(0xFF7FB0E0) : const Color(0xFF2A3A4A),
        onPressed: () {
          setState(() => _perspectiveMode = !_perspectiveMode);
          _keyFocus.requestFocus();
        },
        icon: const Icon(Icons.vrpano),
        label: Text(_perspectiveMode ? 'PERSP ${_fovDeg.toStringAsFixed(0)}°' : 'ORTHO'),
      ),
    );
  }

  Widget _targetDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: const Color(0xFF2A3A4A), borderRadius: BorderRadius.circular(28)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.center_focus_strong, size: 18, color: Colors.white),
          const SizedBox(width: 8),
          DropdownButton<int>(
            value: _targetIndex,
            dropdownColor: const Color(0xFF1A2530),
            iconEnabledColor: Colors.white,
            underline: const SizedBox.shrink(),
            style: const TextStyle(color: Colors.white, fontSize: 13),
            onChanged: (i) {
              if (i != null) _selectTarget(i);
            },
            items: [
              for (var i = 0; i < _targets.length; i++) DropdownMenuItem(value: i, child: Text(_targets[i].label)),
            ],
          ),
        ],
      ),
    );
  }

  /// The body the camera is currently centred on (the "nearest" planet for the
  /// atmosphere debug tools), or null when locked onto a vessel.
  CelestialBody? get _targetBody {
    final id = _focusBody;
    if (id == null) return null;
    return _universe.current().body(id);
  }

  /// Re-skin the focused body's atmosphere with a new gas mix and repaint. The
  /// render's haze colour is derived from composition (scatterColorArgb), so the
  /// limb visibly shifts hue the moment this lands.
  void _reskinAtmosphere(AtmosphericComposition comp, String note) {
    final b = _targetBody;
    if (b == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Lock the camera on a planet first (switch target).'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    _universe.replaceBody(b.copyWith(composition: comp));
    setState(() {}); // next _tick rebuilds the snapshot from the repo
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${b.name}: $note'), duration: const Duration(seconds: 3)));
  }

  /// Nuke the focused planet: choke its air with CO2 + soot-methane haze — the
  /// limb warms to a tan/teal smog (a "nuclear winter" chemistry).
  void _nukePlanet() => _reskinAtmosphere(
    AtmosphericComposition(const {
      AtmosphereGas.carbonDioxide: 0.55,
      AtmosphereGas.methane: 0.20,
      AtmosphereGas.nitrogen: 0.20,
      AtmosphereGas.water: 0.05,
    }),
    'atmosphere choked with CO₂ + soot — haze warms to smog.',
  );

  /// Terraform the focused planet to an Earthlike N2/O2 mix — the limb shifts to
  /// a clean Rayleigh blue.
  void _terraformPlanet() =>
      _reskinAtmosphere(AtmosphericComposition.earth(), 'terraformed to N₂/O₂ — clean blue sky.');

  /// Serialize the whole world into the in-memory save slot.
  void _save() {
    _savedGame = jsonEncode(_codec.encode(
        vessels: _vessels,
        colonies: _colonies,
        deposits: _deposits,
        clock: _clock,
        cities: _cities));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Saved at tick ${_clock.tick}'), duration: const Duration(seconds: 1)));
  }

  /// Restore the world from the in-memory save slot.
  void _load() {
    final save = _savedGame;
    if (save == null) return;
    // Wipe live vessels so the restore replaces them.
    for (final v in _vessels.all().toList()) {
      _vessels.remove(v.id);
    }
    // The load replaces the city list, so a view open on a pre-load colony
    // would be editing a ghost. Closing the editor is the honest move.
    _editingCity = null;
    _codec.decode(
      jsonDecode(save) as Map<String, dynamic>,
      vessels: _vessels,
      colonies: _colonies,
      deposits: _deposits,
      clock: _clock,
      cities: _cities,
      bodies:
          _universe.current().all.where((b) => !b.isStar).toList(),
    );
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Loaded tick ${_clock.tick}'), duration: const Duration(seconds: 1)));
  }

  @override
  Widget build(BuildContext context) {
    final snap = _snapshot;
    // _screenH (perspective focal length) is set from the real render-canvas
    // height by the LayoutBuilder around the painter below.
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      // Keep the FAB stack clear of the notch/home indicator.
      floatingActionButton: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Collapse/expand the control stack to free up the viewport.
            FloatingActionButton.small(
              heroTag: 'collapse',
              backgroundColor: const Color(0xFF2A3A4A),
              onPressed: () => setState(() => _controlsExpanded = !_controlsExpanded),
              child: Icon(_controlsExpanded ? Icons.expand_more : Icons.expand_less),
            ),
            const SizedBox(height: 8),
            // Return to the main menu (the flight view is pushed from it).
            if (Navigator.of(context).canPop())
              FloatingActionButton.small(
                heroTag: 'menu',
                backgroundColor: const Color(0xFF2A3A4A),
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Icon(Icons.home),
              ),
            if (Navigator.of(context).canPop()) const SizedBox(height: 8),
            // Collapsed: only PERSP for quick access.
            // Manual-flight toggle (so touch users can fly without a keyboard).
            if (_controlsExpanded)
              FloatingActionButton.extended(
                heroTag: 'manual',
                backgroundColor: _manualControl ? const Color(0xFFFF8C66) : const Color(0xFF2A3A4A),
                onPressed: () => setState(() => _manualControl = !_manualControl),
                icon: Icon(_manualControl ? Icons.flight : Icons.smart_toy),
                label: Text(_manualControl ? 'MANUAL' : 'AUTO'),
              ),
            // STAGE / decouple: drop the active (lowest) stage off the focused
            // craft. Shown when a stageable vessel is locked. The outline of the
            // remaining stack is the craft itself in the 3D view.
            if (_canStageFocus()) ...[
              const SizedBox(height: 8),
              FloatingActionButton.extended(
                heroTag: 'stage',
                backgroundColor: const Color(0xFFE0A040),
                foregroundColor: Colors.black,
                onPressed: _separateFocusStage,
                icon: const Icon(Icons.layers_clear),
                label: const Text('STAGE'),
              ),
            ],
            if (_controlsExpanded) const SizedBox(height: 8),
            // Perspective toggle + FOV.
            if (_controlsExpanded) _perspToggleFab(),
            if (_controlsExpanded) const SizedBox(height: 8),
            if (_controlsExpanded) ...[
              // Camera lock: pick the target (vessel or body) from a dropdown.
              _targetDropdown(),
              const SizedBox(height: 8),
              // Encounter planner: trial burn + transfer/rendezvous preview.
              if (_focusVessel != null) ...[
                FloatingActionButton.extended(
                  heroTag: 'planner',
                  backgroundColor: _plannerActive
                      ? const Color(0xFFE0A040)
                      : const Color(0xFF2A3A4A),
                  foregroundColor: _plannerActive ? Colors.black : null,
                  onPressed: _togglePlanner,
                  icon: const Icon(Icons.route),
                  label: const Text('PLAN'),
                ),
                const SizedBox(height: 8),
              ],
              // Point the focus craft's nose at its planet.
              if (_focusVessel != null)
                FloatingActionButton.extended(
                  heroTag: 'lookplanet',
                  backgroundColor: const Color(0xFF2A3A4A),
                  onPressed: _lookAtPlanet,
                  icon: const Icon(Icons.my_location),
                  label: const Text('LOOK AT'),
                ),
              if (_focusVessel != null) const SizedBox(height: 8),
              // MAP / CRAFT chase-cam toggle.
              FloatingActionButton.extended(
                heroTag: 'cammode',
                backgroundColor: _craftCam ? const Color(0xFF7FE0A0) : const Color(0xFF2A3A4A),
                onPressed: _toggleCraftCam,
                icon: Icon(_craftCam ? Icons.rocket_launch : Icons.public),
                label: Text(_craftCam ? 'CRAFT' : 'MAP'),
              ),
              const SizedBox(height: 8),
              // View-angle gizmo: top / front / side / 3-quarter projection.
              FloatingActionButton.extended(
                heroTag: 'view',
                backgroundColor: const Color(0xFF2A3A4A),
                onPressed: _cycleView,
                icon: const Icon(Icons.threed_rotation),
                label: Text(_view.nearestPreset.label),
              ),
              const SizedBox(height: 8),
              // Time-warp control: minus / readout / plus (also ',' and '.' keys).
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton.small(
                    heroTag: 'warpdown',
                    onPressed: () => _stepWarp(-1),
                    child: const Icon(Icons.fast_rewind),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(color: const Color(0xFF2A3A4A), borderRadius: BorderRadius.circular(20)),
                    child: Text(
                      _warpTarget != null
                          ? '→$_warpTargetLabel ${_fmtCountdown(_warpTarget!.seconds - _clock.epoch.seconds)}'
                          : _warpLevels[_warpIndex] == 0
                              ? '⏸'
                              : '${_warpLevels[_warpIndex].toStringAsFixed(0)}x',
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FloatingActionButton.small(
                    heroTag: 'warpup',
                    onPressed: () => _stepWarp(1),
                    child: const Icon(Icons.fast_forward),
                  ),
                ],
              ),
              // Warp straight to the focused vessel's next apsis. Active
              // button re-press cancels; manual warp steps also cancel.
              if (_focusVessel != null) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FloatingActionButton.small(
                      heroTag: 'warpap',
                      backgroundColor: _warpTargetLabel == 'AP'
                          ? const Color(0xFF7FE0A0)
                          : const Color(0xFF2A3A4A),
                      onPressed: () => _warpToApsis(periapsis: false),
                      child: const Text('AP',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 8),
                    FloatingActionButton.small(
                      heroTag: 'warppe',
                      backgroundColor: _warpTargetLabel == 'PE'
                          ? const Color(0xFF7FE0A0)
                          : const Color(0xFF2A3A4A),
                      onPressed: () => _warpToApsis(periapsis: true),
                      child: const Text('PE',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton.small(
                    heroTag: 'zoomout',
                    onPressed: () => setState(() => _metresPerPixel = (_metresPerPixel * 1.4).clamp(0.5, 2e10)),
                    child: const Icon(Icons.zoom_out),
                  ),
                  const SizedBox(width: 8),
                  FloatingActionButton.small(
                    heroTag: 'zoomin',
                    onPressed: () => setState(() => _metresPerPixel = (_metresPerPixel / 1.4).clamp(0.5, 2e10)),
                    child: const Icon(Icons.zoom_in),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton.small(heroTag: 'save', onPressed: _save, child: const Icon(Icons.save)),
                  const SizedBox(width: 8),
                  FloatingActionButton.small(
                    heroTag: 'load',
                    onPressed: _savedGame == null ? null : _load,
                    backgroundColor: _savedGame == null ? Colors.grey : null,
                    child: const Icon(Icons.folder_open),
                  ),
                  const SizedBox(width: 8),
                  FloatingActionButton.small(
                    heroTag: 'debug',
                    backgroundColor: _showDebugPanel ? const Color(0xFF7FB0E0) : const Color(0xFF2A3A4A),
                    onPressed: () => setState(() => _showDebugPanel = !_showDebugPanel),
                    child: const Icon(Icons.bug_report),
                  ),
                  const SizedBox(width: 8),
                  FloatingActionButton.small(
                    heroTag: 'inertialTrails',
                    tooltip: 'Trail frame: body-relative vs sun-inertial',
                    backgroundColor: LineNodes.inertialTrails
                        ? const Color(0xFF7FB0E0)
                        : const Color(0xFF2A3A4A),
                    onPressed: () => setState(() {
                      LineNodes.inertialTrails = !LineNodes.inertialTrails;
                    }),
                    child: const Icon(Icons.gesture),
                  ),
                  const SizedBox(width: 8),
                  FloatingActionButton.small(
                    heroTag: 'alignUp',
                    tooltip: switch (_upMode) {
                      CameraUpMode.free =>
                        'Camera up: free (tap: body spin axis)',
                      CameraUpMode.axis =>
                        'Camera up: body spin axis (tap: gravity)',
                      CameraUpMode.gravity =>
                        'Camera up: gravity / local vertical (tap: free)',
                    },
                    backgroundColor: switch (_upMode) {
                      CameraUpMode.free => const Color(0xFF2A3A4A),
                      CameraUpMode.axis => const Color(0xFF7FB0E0),
                      CameraUpMode.gravity => const Color(0xFF7FE0A0),
                    },
                    onPressed: () => setState(() {
                      _upMode = CameraUpMode
                          .values[(_upMode.index + 1) % CameraUpMode.values.length];
                      if (_upMode == CameraUpMode.free) {
                        _view = _view.copyWith(roll: 0);
                      }
                    }),
                    child: Icon(_upMode == CameraUpMode.gravity
                        ? Icons.explore
                        : Icons.align_vertical_center),
                  ),
                  const SizedBox(width: 8),
                  FloatingActionButton.small(
                    heroTag: 'freecam',
                    tooltip: _freecam
                        ? 'Freecam ON — WASD/QE fly, Shift boosts'
                        : 'Freecam: detach and fly the camera anchor',
                    backgroundColor: _freecam
                        ? const Color(0xFF7FE0A0)
                        : const Color(0xFF2A3A4A),
                    onPressed: _toggleFreecam,
                    child: const Icon(Icons.videocam),
                  ),
                  const SizedBox(width: 8),
                  FloatingActionButton.small(
                    heroTag: 'lamp',
                    tooltip: TerrainNodes.lampOn
                        ? 'Head lamp ON (F)'
                        : 'Head lamp: light the ground ahead (F)',
                    backgroundColor: TerrainNodes.lampOn
                        ? const Color(0xFFF0E080)
                        : const Color(0xFF2A3A4A),
                    onPressed: () =>
                        setState(() => TerrainNodes.lampOn = !TerrainNodes.lampOn),
                    child: const Icon(Icons.flashlight_on),
                  ),
                  const SizedBox(width: 8),
                  FloatingActionButton.small(
                    heroTag: 'walk',
                    tooltip: _walkMode
                        ? 'Walking — WASD, Space jumps, Shift runs (G)'
                        : 'Walk: stand on the surface, first person (G)',
                    backgroundColor: _walkMode
                        ? const Color(0xFFE0C77F)
                        : const Color(0xFF2A3A4A),
                    onPressed: _toggleWalk,
                    child: const Icon(Icons.directions_walk),
                  ),
                  const SizedBox(width: 8),
                  FloatingActionButton.small(
                    heroTag: 'renderBackend',
                    tooltip: _renderBackend.label,
                    backgroundColor: _renderBackend == RenderBackend.flutterScene
                        ? const Color(0xFF7FB0E0)
                        : const Color(0xFF2A3A4A),
                    onPressed: () => _setBackend(_renderBackend.next),
                    child: const Icon(Icons.view_in_ar),
                  ),
                ],
              ),
            ], // end if (_controlsExpanded)
          ],
        ),
      ), // end SafeArea(floatingActionButton)
      // Focus, not KeyboardListener: the latter reports every key as
      // `ignored`, which on macOS falls through to AppKit and rings the
      // system alert sound. See [_simKeys].
      body: Focus(
        focusNode: _keyFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Listener(
          // Any tap on the world reclaims keyboard focus (FABs/dropdown may have
          // stolen it), so camera-orbit arrow keys keep working.
          onPointerDown: (e) {
            _keyFocus.requestFocus();
            if (e.buttons & kMiddleMouseButton != 0) {
              _mmbDragging = true;
              _lastMmb = e.position;
            }
          },
          onPointerMove: (e) {
            if (!_mmbDragging) return;
            // A missed pointer-up (MMB released off-window, focus stolen)
            // leaves the drag armed; the next unrelated drag then applies
            // the delta from the STALE anchor and the camera leaps to a
            // "random" orientation. Consume deltas only while the middle
            // button is actually still held.
            if (e.buttons & kMiddleMouseButton == 0) {
              _mmbDragging = false;
              return;
            }
            final d = e.position - _lastMmb;
            _lastMmb = e.position;
            // Middle-mouse drag free-orbits the camera (azimuth/elevation).
            // Pitch inverted: dragging down tilts the view up.
            _orbitCamera(d.dx * 0.005, d.dy * 0.005);
          },
          onPointerUp: (e) {
            if (e.buttons & kMiddleMouseButton == 0) _mmbDragging = false;
          },
          onPointerCancel: (_) => _mmbDragging = false,
          // Mouse wheel: scroll up = zoom in. Drives mpp (ortho) or range
          // (perspective). In FREECAM the wheel sets the flight-speed
          // multiplier instead — speed control matters more than zoom
          // while flying, and the range still zooms via [ ] keys.
          onPointerSignal: (signal) {
            if (signal is PointerScrollEvent) {
              if (_freecam) {
                final factor = signal.scrollDelta.dy > 0 ? 1 / 1.3 : 1.3;
                setState(() => _freecamSpeedMul =
                    (_freecamSpeedMul * factor).clamp(0.01, 100000.0));
              } else {
                final factor = signal.scrollDelta.dy > 0 ? 1.15 : 1 / 1.15;
                setState(() => _zoom(factor));
              }
            }
          },
          // RawGestureDetector, NOT GestureDetector: the stock scale gesture
          // accepts EVERY mouse button, so a middle-drag orbited twice (once
          // here, once in the Listener above) and a right-press orbited on the
          // few pixels of jitter every physical click carries — the "camera
          // jumps on a bare MMB/RMB press" bug. The scale gesture is for touch
          // (pinch + one-finger orbit) and the primary button only; MMB stays
          // the Listener's, RMB stays nobody's. Guarded by
          // camera_mouse_button_test.dart.
          child: RawGestureDetector(
            gestures: {
              ScaleGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<ScaleGestureRecognizer>(
                () => ScaleGestureRecognizer(
                    allowedButtonsFilter: (int buttons) =>
                        buttons == kPrimaryButton),
                (r) => r
                  // Pinch zoom + single-finger drag orbit. d.scale is
                  // cumulative from the gesture START, so anchor it to the
                  // value captured at start.
                  ..onStart = (_) {
                    _pinchBaseMpp = _metresPerPixel;
                    _pinchBaseRange = _range;
                  }
                  ..onUpdate = (d) {
                    if (d.pointerCount >= 2 && d.scale != 1.0) {
                      // Two-finger pinch -> zoom.
                      setState(() {
                        if (_perspectiveMode) {
                          _range =
                              (_pinchBaseRange / d.scale).clamp(1.0, 1e13);
                        } else {
                          _metresPerPixel =
                              (_pinchBaseMpp / d.scale).clamp(0.5, 2e10);
                        }
                      });
                    } else {
                      // Single-finger drag -> orbit (pitch inverted).
                      final dd = d.focalPointDelta;
                      _orbitCamera(dd.dx * 0.005, dd.dy * 0.005);
                    }
                  },
              ),
            },
            child: Stack(
              children: [
                // Renderer fills edge-to-edge (into the notch / safe area).
                // The backend toggle swaps ONLY this subtree — camera state,
                // input handling, and the HUD overlays above are shared.
                if (_renderBackend == RenderBackend.flutterScene) ...[
                  Positioned.fill(
                    child: LayoutBuilder(builder: (context, constraints) {
                      // Keep the shared focal length in sync with the REAL
                      // canvas height in scene mode too. Only the software
                      // branch updated it before, so in scene mode the HUD
                      // overlay's projection used a stale height: labels
                      // scaled differently from the rendered bodies and
                      // drifted apart, worse with distance from centre.
                      if (constraints.maxHeight.isFinite &&
                          constraints.maxHeight > 0) {
                        _screenH = constraints.maxHeight;
                        _screenW = constraints.maxWidth;
                      }
                      return SceneRenderView(
                        camera: _camera,
                        textures: _textures,
                        snapshot: _sceneWorld,
                        focusVesselId: _focusVessel?.value,
                        focusBodyId: _focusBody?.value,
                        // Freecam wins; else a locked megastructure anchors
                        // the floating origin (it is neither vessel nor body,
                        // so the id channels can't carry it).
                        focusWorldOverride:
                            _freecam ? _freecamWorld : _megaFocusWorld,
                        planner: _plannerOverlay,
                      );
                    }),
                  ),
                  // Painter-parity text HUD (telemetry block + name labels)
                  // from the SAME presenter snapshot the software path uses.
                  // Hidden in freecam: the presenter still projects around
                  // the locked target, so its labels would sit off the
                  // freecam-rendered world.
                  // Also hidden on a megastructure lock: the presenter has no
                  // mega focus channel, so its labels would project around the
                  // wrong origin.
                  if (snap != null && !_freecam && _focusMega == null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: SceneHudOverlayPainter(snap, _camera,
                              layers: _layers),
                        ),
                      ),
                    ),
                  // Reflection-capture debug overlay (bottom-left, above the
                  // build stamp) — the equirect the craft's IBL reflects.
                  if (PlanetEnvironmentBaker.showDebug)
                    const Positioned(
                      left: 8,
                      bottom: 40,
                      child: IgnorePointer(child: _EnvBakeDebugView()),
                    ),
                ] else
                  Positioned.fill(
                    child: snap == null
                        ? const Center(child: CircularProgressIndicator())
                        : LayoutBuilder(
                            builder: (context, constraints) {
                              // The perspective focal length must use the ACTUAL
                              // render-canvas height, not the full MediaQuery window
                              // (which over-states it and makes the lens read long /
                              // the planet a touch small). Update it from the real
                              // layout height each build.
                              if (constraints.maxHeight.isFinite && constraints.maxHeight > 0) {
                                _screenH = constraints.maxHeight;
                                _screenW = constraints.maxWidth;
                        _screenW = constraints.maxWidth;
                              }
                              return CustomPaint(
                                size: Size.infinite,
                                painter: TopDownPainter(
                                  snap,
                                  textures: _textures,
                                  view: _activeCamera ?? OrthoCamera(_view, _metresPerPixel),
                                  layers: _layers,
                                ),
                              );
                            },
                          ),
                  ),
                // All UI overlays stay INSIDE the safe area.
                Positioned.fill(
                  child: SafeArea(
                    child: Stack(
                      children: [
                        // Nav-ball: attitude/prograde of the locked vessel.
                        if (_layers.navBall && _navState() != null)
                          Positioned(
                            bottom: 16,
                            left: 0,
                            right: 0,
                            child: Center(child: NavBall(state: _navState()!, size: 120)),
                          ),
                        // Perf panel (top-left) + debug draw-layer toggle
                        // panel (top-right) — same toggle, opposite corners
                        // so neither crowds the other.
                        if (_showDebugPanel) Positioned(top: 8, left: 8, child: _perfPanel()),
                        if (_showDebugPanel) Positioned(top: 8, right: 8, child: _debugPanel()),
                        // Encounter-planner panel (top-right; slides left of
                        // the debug panel when both are open).
                        if (_plannerActive)
                          Positioned(
                            top: 8,
                            right: _showDebugPanel ? 348 : 8,
                            child: _plannerPanel(),
                          ),
                        Positioned(
                          left: 8,
                          bottom: 8,
                          child: Text(
                            _manualControl
                                ? 'MANUAL  keys: W/S A/D Q/E Shift  |  touch: joystick + throttle  |  M auto  |  pinch/wheel/[ ]/-= zoom'
                                : 'AUTO  (M or tap for manual flight)  |  pinch/scroll/[ ]/-= zoom',
                            style: TextStyle(
                              color: _manualControl ? const Color(0xFFFF8C66) : const Color(0xFF6E8299),
                              fontSize: 11,
                            ),
                          ),
                        ),
                        // Build stamp (bottom-left, bright) to confirm a fresh deploy.
                        Positioned(
                          left: 8,
                          bottom: 28,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            color: const Color(0xCC00FF7F),
                            child: Text(
                              kBuildStamp,
                              style: const TextStyle(
                                color: Color(0xFF001A0D),
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        // Zoom-factor readout (debug): the camera scale so issues can be
                        // pinned to an exact zoom. ORTHO shows metres-per-pixel; PERSP
                        // shows the eye range (m). Sits just above the build stamp.
                        Positioned(
                          left: 8,
                          bottom: 46,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            color: const Color(0xAA001A0D),
                            child: Text(
                              _zoomLabel(),
                              style: const TextStyle(
                                color: Color(0xFF7FE0A0),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        // Depth-plane + ring-field diagnostics (3D backend):
                        // the near/far the adapter will derive this frame,
                        // and the nearest ring's field state — for pinning
                        // "where did the rocks go" style reports.
                        if (_renderBackend == RenderBackend.flutterScene)
                          Positioned(
                            left: 8,
                            bottom: 68,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              color: const Color(0xAA0D0D1A),
                              child: Text(
                                _depthDebugLabel(),
                                style: const TextStyle(
                                  color: Color(0xFFB0C4E8),
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        // On-screen flight controls (touch), only in manual mode.
                        if (_manualControl) ..._touchControls(),
                        // Vessel-lost menu (modal over everything).
                        if (_crashNotice != null) _crashMenu(_crashNotice!),
                      ],
                    ),
                  ),
                ), // end overlay SafeArea Positioned.fill
                // Ground picking. LAST but one, so it wins the gesture arena
                // against the camera's own drag handler wrapping this stack —
                // as a lower sibling it lost every pan, which is why painting
                // did nothing. Opaque only while a tool is held; on Inspect it
                // still tracks hover but lets the flight controls have the
                // gesture.
                if (_editingCity != null)
                  Positioned.fill(
                    child: MouseRegion(
                      opaque: false,
                      onHover: (e) => _hoverCityAt(e.localPosition),
                      onExit: (_) => CityNodes.cursorBF = null,
                      child: _PickGate(
                        // A held tool paints anywhere, so the gate stands
                        // open. On Look it opens only over a BUILDING —
                        // every other tap belongs to the HUD underneath, and
                        // a gesture arena cannot tell the two apart on its
                        // own.
                        pick: (p) =>
                            _cityEdit.active || _siteUnder(p) != null,
                        child: GestureDetector(
                          behavior: _cityEdit.active
                              ? HitTestBehavior.opaque
                              : HitTestBehavior.translucent,
                          onTapUp: (d) => _cityEdit.active
                              ? _editCityAt(d.localPosition)
                              : _inspectCityAt(d.localPosition),
                          onPanStart: _cityEdit.active ? (_) {} : null,
                          // Panning PAINTS for the lot tools but does not draw
                          // roads: the road tool is click-to-place, Skylines
                          // style — each tap a control point, the toolbar's
                          // check to build. A freehand scribble is not how
                          // anyone lays an avenue.
                          onPanUpdate:
                              _cityEdit.active &&
                                  _cityEdit.tool != CityEditTool.roadSpline
                              ? (d) => _editCityAt(d.localPosition)
                              : null,
                        ),
                      ),
                    ),
                  ),
                // City editor toolbar. LAST in the stack so it sits over the
                // HUD rather than under it — a toolbar you cannot click is
                // worse than no toolbar.
                if (_editingCity != null)
                  Positioned.fill(
                    child: CityEditOverlay(
                      controller: _cityEdit,
                      city: _editingCity!,
                      onClose: () => setState(() => _editingCity = null),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// On-screen flight controls, DOCKED to the bottom of the screen — the old
  /// Ascent-style panel: a throttle slider + pitch / yaw / roll axis sliders
  /// (self-centring), so launching is intuitive without a hidden joystick.
  List<Widget> _touchControls() {
    return [
      Positioned(
        right: 12,
        bottom: 12,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            decoration: BoxDecoration(
              color: const Color(0xDD0E1622),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0x33FF8C66)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _flightStatusRow(),
                  // FINE throttle — an absolute 0..10% throttle for delicate landing
                  // burns (full slider span = 10% thrust). Sits ABOVE the coarse one.
                  Row(
                    children: [
                      const SizedBox(
                        width: 56,
                        child: Text('FINE', style: TextStyle(color: Color(0xFFFFC58A), fontSize: 11)),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: const SliderThemeData(
                            activeTrackColor: Color(0xFFFFC58A),
                            inactiveTrackColor: Color(0x33FFC58A),
                            thumbColor: Color(0xFFFFC58A),
                            trackHeight: 2,
                          ),
                          child: Slider(
                            // 0..1 maps to an ABSOLUTE 0..10% throttle for fine landing
                            // burns. Sets the throttle directly (held, not a trim).
                            value: _touchThrottleFine,
                            onChanged: (v) => setState(() {
                              _touchThrottleFine = v;
                              _touchThrottle = v * 0.10; // 0..10%
                            }),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(
                          '${(_touchThrottleFine * 10).toStringAsFixed(1)}%',
                          textAlign: TextAlign.right,
                          style: const TextStyle(color: Color(0xFFFFC58A), fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                  // Throttle — held (does NOT self-centre).
                  Row(
                    children: [
                      const SizedBox(
                        width: 56,
                        child: Text('THR', style: TextStyle(color: Color(0xFFFF8C66), fontSize: 12)),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: const SliderThemeData(
                            activeTrackColor: Color(0xFFFF8C66),
                            thumbColor: Color(0xFFFF8C66),
                            trackHeight: 3,
                          ),
                          child: Slider(value: _touchThrottle, onChanged: (v) => setState(() => _touchThrottle = v)),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(
                          '${(_touchThrottle * 100).round()}%',
                          textAlign: TextAlign.right,
                          style: const TextStyle(color: Color(0xFFFF8C66), fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  _axisRow('PITCH', _touchPitch, (v) => _touchPitch = v),
                  _axisRow('YAW', _touchYaw, (v) => _touchYaw = v),
                  _axisRow('ROLL', _touchRoll, (v) => _touchRoll = v),
                ],
              ),
            ),
          ),
        ),
      ),
    ];
  }

  /// Flight status header for the control panel: altitude, speed, STAGING info
  /// (active stage / total), a landed badge, and a FOUND COLONY action when
  /// landed on a body's surface.
  Widget _flightStatusRow() {
    final id = _focusVessel;
    final v = id == null ? null : _vessels.byId(id);
    if (v == null) return const SizedBox.shrink();
    final body = _universe.current().body(v.dominantBody);
    final alt = v.state.position.length - (body?.radius ?? 0);
    final spd = v.state.velocity.length;
    final total = v.stages.length;
    // Active stage is the LAST in the list; stages already dropped reduce length.
    final stageNo = total; // current bottom-most remaining stage
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'ALT ${(alt / 1000).toStringAsFixed(1)}km · ${spd.toStringAsFixed(0)} m/s · STAGE $stageNo/$total',
              style: const TextStyle(color: Color(0xFF9FB4CC), fontSize: 11),
            ),
          ),
          if (v.landed)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  backgroundColor: const Color(0xFF7FE0A0),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                ),
                icon: const Icon(Icons.location_city, size: 16),
                label: const Text('FOUND', style: TextStyle(fontSize: 11)),
                onPressed: () => _foundColony(v),
              ),
            ),
        ],
      ),
    );
  }


  /// A self-centring attitude axis slider (-1..1), snapping back to 0 on release.
  Widget _axisRow(String label, double value, void Function(double) set) => Row(
    children: [
      SizedBox(
        width: 56,
        child: Text(label, style: const TextStyle(color: Color(0xFF9FB4CC), fontSize: 12)),
      ),
      Expanded(
        child: SliderTheme(
          data: const SliderThemeData(
            activeTrackColor: Color(0xFF7FE0A0),
            thumbColor: Color(0xFF7FE0A0),
            trackHeight: 2,
          ),
          child: Slider(
            value: value,
            min: -1,
            max: 1,
            onChanged: (v) => setState(() => set(v)),
            onChangeEnd: (_) => setState(() => set(0)), // self-centre
          ),
        ),
      ),
      const SizedBox(width: 40),
    ],
  );
}

/// On-screen view of the reflection-capture equirect the craft's IBL
/// reflects (toggle: debug panel 'Env reflection', or
/// `ext.acro.camera?envDebug=true`). Rebuilds itself as each rebake
/// publishes a new image — independent of the sim frame so it updates even
/// when the camera is parked.
class _EnvBakeDebugView extends StatelessWidget {
  const _EnvBakeDebugView();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ui.Image?>(
      valueListenable: PlanetEnvironmentBaker.latestBake,
      builder: (context, img, _) {
        if (img == null) return const SizedBox.shrink();
        return Container(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFF33CCCC)),
            color: const Color(0xFF000000),
          ),
          child: CustomPaint(
            size: const Size(320, 160),
            painter: _EnvBakePainter(img),
          ),
        );
      },
    );
  }
}

class _EnvBakePainter extends CustomPainter {
  _EnvBakePainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..filterQuality = FilterQuality.none,
    );
    // Reference axes: the equator (v=0.5) and the u=0.5 meridian, so a
    // mispositioned sun/body disc is easy to read off the projection.
    final axis = Paint()
      ..color = const Color(0x3333CCCC)
      ..strokeWidth = 1;
    canvas.drawLine(
        Offset(0, size.height / 2), Offset(size.width, size.height / 2), axis);
    canvas.drawLine(
        Offset(size.width / 2, 0), Offset(size.width / 2, size.height), axis);
    final tp = TextPainter(
      text: const TextSpan(
        text: 'ENV BAKE  (u: atan2 z,x — v: asin y)',
        style: TextStyle(color: Color(0xCC33CCCC), fontSize: 9),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(3, 2));
  }

  @override
  bool shouldRepaint(_EnvBakePainter old) => !identical(old.image, image);
}
