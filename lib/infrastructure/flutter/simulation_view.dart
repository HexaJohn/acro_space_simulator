import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/gestures.dart'
    show PointerScrollEvent, kMiddleMouseButton;
import 'package:flutter/services.dart'
    show LogicalKeyboardKey, KeyEvent, KeyDownEvent, KeyUpEvent;

import '../../domain/autonomy/pilot_input.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';

import '../../adapters/events/in_memory_event_bus.dart';
import '../../adapters/presenters/top_down_snapshot.dart';
import '../../adapters/repositories/in_memory_repositories.dart';
import '../../adapters/repositories/in_memory_world_repositories.dart';
import '../../application/persistence/game_state_codec.dart';
import '../../application/ports/compute_port.dart';
import '../../application/usecases/advance_simulation_tick.dart';
import '../../domain/orbits/soi_transition_service.dart';
import '../../domain/science/research_ledger.dart';
import '../../domain/science/tech_tree.dart';
import '../../domain/simulation/simulation_clock.dart';
import '../../domain/simulation/domain_event.dart';
import '../../domain/planetary/atmospheric_composition.dart';
import '../../domain/universe/celestial_body.dart' show BodyId, CelestialBody;
import '../../domain/vessel/vessel.dart';
import '../sample_world.dart';
import 'debug_layers.dart';
import 'nav_ball.dart';
import 'screens/city_builder_screen.dart';
import 'texture_cache.dart';
import 'top_down_painter.dart';

/// Build stamp shown bottom-left so a deploy can be confirmed live (cache
/// busting check). Bump this every rebuild.
const String kBuildStamp = 'build 2026-06-18.158';

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

  const SimulationView({
    super.key,
    this.injectedVessel,
    this.trafficVessels = const [],
  });

  @override
  State<SimulationView> createState() => _SimulationViewState();
}

class _SimulationViewState extends State<SimulationView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final SimulationClock _clock;
  late AdvanceSimulationTick _advance;
  // Stashed tick deps so _advance can be rebuilt when a debug cheat toggles.
  late final InMemoryEventBus _events;
  late final InMemoryWeatherRepository _weather;
  // Debug cheats: skip overheat / aero-stress / impact destruction. ON by
  // default so flight testing isn't cut short; toggle off in the debug panel.
  bool _disableOverheat = true;
  bool _disableAeroStress = true;
  bool _disableImpact = true;
  late final TopDownSnapshotPresenter _presenter;
  late final StaticUniverseRepository _universe;
  late final InMemoryVesselRepository _vessels;
  late final InMemoryColonyRepository _colonies;
  late final InMemoryDepositRepository _deposits;
  late final ResearchLedger _research;

  // ---- Camera target + view ----
  // The locked target cycles through vessels and major bodies. Exactly one of
  // these is non-null at a time; the other is cleared when the cycle advances.
  VesselId? _focusVessel; // active vessel lock (null when a body is locked)
  BodyId? _focusBody; // active body lock (null when a vessel is locked)
  BodyId? _lastFocusBody; // dominant body of the focused vessel, last seen
  late final List<({String label, VesselId? v, BodyId? b})> _targets;
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
  bool _controlsExpanded = true; // collapsible FAB stack

  /// Radius (m) of the body the camera is locked on, or 0 (vessel / none). Lets
  /// the perspective eye measure its range from the SURFACE, not the centre.
  double get _focusBodyRadius {
    if (_focusBody == null) return 0;
    return _universe.current().body(_focusBody!)?.radius ?? 0;
  }

  /// The active camera for this frame: ortho or perspective, both driven by the
  /// shared `_view` orientation (azimuth/elevation/roll). In perspective the
  /// eye sits [_range] from the body's SURFACE (range + radius from centre), so
  /// _range is an altitude that can shrink to near-zero — you keep zooming all
  /// the way down to the surface instead of stalling at centre-distance==radius.
  SceneCamera get _camera => _perspectiveMode
      ? PerspectiveCamera(
          azimuth: _view.azimuth,
          elevation: _view.elevation,
          roll: _view.roll,
          range: _range + _focusBodyRadius,
          fovY: _fovDeg * math.pi / 180,
          viewportH: _screenH,
        )
      : OrthoCamera(_view, _metresPerPixel);
  // Tilted-view distance-cull kicks in above this zoom (m/px). 1e6 == 100 px /
  // 100,000 km. Configurable via the debug panel.
  double _tiltedCullMpp = 1e6;
  static const double _orbitStep = 0.1309; // ~7.5 deg per arrow press
  DebugLayers _layers = const DebugLayers();
  bool _showDebugPanel = false;
  late final TextureCache _textures;

  // Destruction notice: set when a vessel is lost (impact / overstress / burn-up)
  // so the UI can pop a menu. Cleared when the user dismisses it.
  ({String title, String detail})? _crashNotice;
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
  bool _manualControl =
      false; // when true, autopilot for the focus vessel is off

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
        (_keysDown.contains(pos) ? 1.0 : 0.0) -
        (_keysDown.contains(neg) ? 1.0 : 0.0);
    final keyThrottle = _keysDown.contains(LogicalKeyboardKey.shiftLeft)
        ? 1.0
        : 0.0;
    return PilotInput(
      pitch:
          (axis(LogicalKeyboardKey.keyS, LogicalKeyboardKey.keyW) + _touchPitch)
              .clamp(-1.0, 1.0),
      yaw: (axis(LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyD) + _touchYaw)
          .clamp(-1.0, 1.0),
      // Negated: roll was inverted (Q/E + the touch slider rolled the wrong way).
      roll: (-(axis(LogicalKeyboardKey.keyQ, LogicalKeyboardKey.keyE) +
                  _touchRoll))
          .clamp(-1.0, 1.0),
      throttle: keyThrottle > 0 ? keyThrottle : _touchThrottle,
    );
  }

  void _onKey(KeyEvent e) {
    if (e is KeyDownEvent) {
      // Toggle manual control with M.
      if (e.logicalKey == LogicalKeyboardKey.keyM) {
        setState(() => _manualControl = !_manualControl);
        return;
      }
      _keysDown.add(e.logicalKey);
      // Camera zoom with [ and ].
      if (e.logicalKey == LogicalKeyboardKey.bracketLeft) {
        setState(
          () => _metresPerPixel = (_metresPerPixel * 1.25).clamp(0.5, 2e10),
        );
      } else if (e.logicalKey == LogicalKeyboardKey.bracketRight) {
        setState(
          () => _metresPerPixel = (_metresPerPixel / 1.25).clamp(0.5, 2e10),
        );
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
    } else if (e is KeyUpEvent) {
      _keysDown.remove(e.logicalKey);
    }
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
      // _range is the eye's altitude above the focused body's surface.
      final label = _focusBody != null ? 'alt' : 'range';
      return 'PERSP  $label ${eng(_range)} m  fov ${_fovDeg.toStringAsFixed(0)}°';
    }
    // 100 px spans this many km on screen — an intuitive "how zoomed" number.
    final kmPer100px = _metresPerPixel * 100 / 1000;
    return 'ORTHO  ${eng(_metresPerPixel)} m/px  (100px=${eng(kmPer100px)} km)';
  }

  /// Zoom by [factor] (>1 = out): adjusts ortho mpp or perspective range.
  void _zoom(double factor) {
    if (_perspectiveMode) {
      _range = (_range * factor).clamp(100.0, 1e13);
    } else {
      _metresPerPixel = (_metresPerPixel * factor).clamp(0.5, 2e10);
    }
  }

  // Time-warp ladder (sim seconds per real second). ',' / '.' step through it.
  static const List<double> _warpLevels = [
    1, 5, 10, 50, 100, 1000, 10000, 100000, 1000000
  ];
  int _warpIndex = 3; // starts at 50x (matches the initial clock warp)

  void _stepWarp(int delta) {
    final next = (_warpIndex + delta).clamp(0, _warpLevels.length - 1);
    if (next == _warpIndex) return;
    setState(() {
      _warpIndex = next;
      _clock.warpFactor = _warpLevels[_warpIndex];
    });
  }
  Duration _last = Duration.zero;
  double _accum = 0; // carried-over real time not yet consumed by a fixed step

  @override
  void initState() {
    super.initState();

    // The REAL Solar System: Sun + planets + dwarf planets + moons.
    final system = SampleWorld.realSystem();
    // ~3000 km up so the craft is clearly off the surface at the default zoom
    // (a 400 km LEO sits only a few px above Earth's limb and looks landed).
    final vessel = SampleWorld.buildEarthOrbiter(altitude: 3000000);
    // An ascent/descent craft injected by the caller (sits on a body surface).
    final injected = widget.injectedVessel;
    final fleet = [vessel, ?injected, ...widget.trafficVessels];

    // Camera-target cycle: every vessel first, then the major bodies. The
    // switch-camera button steps through this list.
    _targets = [
      for (final v in fleet) (label: v.name, v: v.id, b: null),
      for (final body in system.all)
        (label: body.name, v: null, b: body.id),
    ];
    // If a craft was injected (ascent/descent), START LOCKED ON IT so the player
    // is flying it immediately; otherwise lock on the ORBITER so the player can
    // fly it directly from the start (manual mode, see the flags below).
    if (injected != null) {
      _targetIndex = _targets.indexWhere((t) => t.v == injected.id);
    } else {
      _targetIndex = _targets.indexWhere((t) => t.v == vessel.id);
    }
    if (_targetIndex < 0) _targetIndex = 0;
    _focusVessel = _targets[_targetIndex].v;
    _focusBody = _targets[_targetIndex].b;

    // Start ready to fly: manual control of the orbiter, infinite fuel, 1x warp.
    _manualControl = true;
    _layers = _layers.copyWith(infiniteFuel: true);
    _warpIndex = 0; // 1x

    _vessels = InMemoryVesselRepository(fleet);
    for (final v in _vessels.all()) {
      _vesselNames[v.id.value] = v.name;
    }
    final universe = StaticUniverseRepository(system);
    _universe = universe;
    _events = InMemoryEventBus();
    // Pop a destruction menu when a vessel is lost.
    _events.subscribe(_onDomainEvent);
    _colonies = InMemoryColonyRepository();
    _deposits = InMemoryDepositRepository();
    _weather = InMemoryWeatherRepository();
    _research = ResearchLedger(
      tree: TechTree(
        nodes: const [
          TechNode(id: 'start', cost: 0),
          TechNode(id: 'generalRocketry', cost: 20, requires: ['start']),
        ],
      ),
    );

    _clock = SimulationClock(warpFactor: 1, fixedStep: 0.02); // dev start: 1x
    _buildAdvance();
    _presenter = TopDownSnapshotPresenter(
      vessels: _vessels,
      universe: universe,
      colonies: _colonies,
    );

    // Body surface maps; repaint once each finishes decoding.
    _textures = TextureCache(
      onReady: () {
        if (mounted) setState(() {});
      },
    );

    _ticker = createTicker(_onFrame)..start();
  }

  /// (Re)build the tick with the current debug-cheat flags. Called on init and
  /// whenever a disable-overheat / aero / impact toggle changes.
  void _buildAdvance() {
    _advance = AdvanceSimulationTick(
      vessels: _vessels,
      universe: _universe,
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: _events,
      colonies: _colonies,
      deposits: _deposits,
      weather: _weather,
      research: _research,
      disableOverheat: _disableOverheat,
      disableAeroStress: _disableAeroStress,
      disableImpact: _disableImpact,
    );
  }

  /// React to simulation events. Right now: surface a destruction menu when a
  /// vessel is lost (hard impact, structural overstress, or part burn-up).
  void _onDomainEvent(DomainEvent e) {
    String nameOf(VesselId id) => _vesselNames[id.value] ?? id.value;
    ({String title, String detail})? notice;
    if (e is Impact) {
      notice = (
        title: '${nameOf(e.vessel)} destroyed',
        detail: 'Hard impact with ${e.body.value} at '
            '${e.speed.toStringAsFixed(0)} m/s. The craft was lost.',
      );
    } else if (e is StructuralFailure) {
      notice = (
        title: '${nameOf(e.vessel)} broke up',
        detail: 'Structural failure under aerodynamic load '
            '(${(e.dynamicPressure / 1000).toStringAsFixed(1)} kPa).',
      );
    } else if (e is PartOverheated) {
      notice = (
        title: '${nameOf(e.vessel)} burned up',
        detail: 'A part exceeded its temperature limit '
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
          _warpIndex = 0;
          _clock.warpFactor = _warpLevels[0];
        }
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

    // Run as many fixed steps as real time accrued. Carry the leftover across
    // frames â€” a 16ms frame is < the 20ms fixed step, so without accumulation
    // most frames ran ZERO steps and the sim only advanced on the occasional
    // slow frame (the jumpy "random update" motion).
    _accum += frameDt;
    var steps = 0;
    while (_accum >= _clock.fixedStep && steps < 200) {
      _advance.execute(_clock);
      _accum -= _clock.fixedStep;
      steps++;
    }
    // If we hit the step cap (e.g. a long first frame or a stall), drop the
    // backlog instead of spiralling â€” better to skip time than freeze.
    if (steps >= 200) _accum = 0;

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
        final roll =
            math.atan2(-craftUp.dot(rightBase), craftUp.dot(upBase));

        _view = _view.copyWith(
          azimuth: azimuth,
          elevation: elevation,
          roll: roll,
        );
      }
    }

    _recordTrail();

    final cam = _camera;
    setState(() {
      _activeCamera = cam;
      _snapshot = _presenter.present(
        focus: _focusVessel,
        focusBodyId: _focusBody,
        camera: cam,
        epoch: _clock.epoch,
        science: _research.science,
        cullDistant: _layers.cullDistant,
        flownTrail: _trail,
        flownTrailBody: _trailBody,
      );
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
    _ticker.dispose();
    _keyFocus.dispose();
    _textures.dispose();
    super.dispose();
  }

  /// Lock the camera onto target [i] in the list (vessel or body).
  void _selectTarget(int i) {
    setState(() {
      _targetIndex = i;
      final t = _targets[i];
      _focusVessel = t.v;
      _focusBody = t.b;
      // A body can't be piloted, so drop manual mode when locking onto one.
      if (t.v == null) _manualControl = false;
    });
    // The dropdown stole keyboard focus â€” hand it back so arrow keys (camera
    // orbit) and the other shortcuts keep working after a target switch.
    _keyFocus.requestFocus();
  }

  /// Cycle the projection through the named presets (snaps the orbit angles).
  void _cycleView() => setState(
      () => _view = CameraOrbit.preset(_view.nearestPreset.next));

  /// Toggle MAP <-> CRAFT chase cam. Entering craft cam locks onto a vessel and
  /// zooms in close; leaving it restores the saved map zoom + view.
  void _toggleCraftCam() {
    setState(() {
      _craftCam = !_craftCam;
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
    setState(() => _view = _view.copyWith(
          azimuth: _view.azimuth + dAz,
          elevation: _view.elevation + dEl,
        ));
  }

  /// Modal "vessel lost" menu shown when a craft is destroyed. Fills the screen
  /// with a scrim so the sim is clearly interrupted; a single button dismisses.
  Widget _crashMenu(({String title, String detail}) notice) {
    return Positioned.fill(
      child: Container(
        color: const Color(0xCC000000),
        alignment: Alignment.center,
        child: Container(
          width: 360,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1014),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFFF6B6B), width: 1.5),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.warning_amber_rounded,
                      color: Color(0xFFFF6B6B), size: 26),
                  SizedBox(width: 8),
                  Text('VESSEL LOST',
                      style: TextStyle(
                          color: Color(0xFFFF6B6B),
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2)),
                ],
              ),
              const SizedBox(height: 14),
              Text(notice.title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(notice.detail,
                  style: const TextStyle(
                      color: Color(0xFFC9B8BC), fontSize: 13, height: 1.35)),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF6B6B),
                    foregroundColor: const Color(0xFF1A0A0A),
                  ),
                  onPressed: () => setState(() => _crashNotice = null),
                  child: const Text('DISMISS'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Debug panel: a checkbox per draw layer so each pass can be isolated.
  /// A debug-cheat checkbox row: flips [value] via [set], then rebuilds the tick
  /// so the new flag takes effect immediately.
  Widget _cheatRow(String label, bool value, void Function(bool) set) => InkWell(
        onTap: () => setState(() {
          set(!value);
          _buildAdvance();
        }),
        child: Row(children: [
          Checkbox(
            value: value,
            onChanged: (v) => setState(() {
              set(v ?? false);
              _buildAdvance();
            }),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          Text(label,
              style: const TextStyle(color: Color(0xFFB9C9DC), fontSize: 12)),
        ]),
      );

  Widget _debugPanel() {
    final rows = <(String, bool, DebugLayers Function(bool))>[
      ('Skybox', _layers.skybox, (v) => _layers.copyWith(skybox: v)),
      ('Orbit rails', _layers.orbitRails, (v) => _layers.copyWith(orbitRails: v)),
      ('Planet texture', _layers.planetTexture,
          (v) => _layers.copyWith(planetTexture: v)),
      ('Sphere shadow', _layers.sphereShadow,
          (v) => _layers.copyWith(sphereShadow: v)),
      ('Atmo halo', _layers.atmoHalo, (v) => _layers.copyWith(atmoHalo: v)),
      ('Atmo overlay', _layers.atmoOverlay,
          (v) => _layers.copyWith(atmoOverlay: v)),
      ('Nav-ball', _layers.navBall, (v) => _layers.copyWith(navBall: v)),
      ('Exaggerate star', _layers.exaggerateStar,
          (v) => _layers.copyWith(exaggerateStar: v)),
      ('Exaggerate atmo', _layers.exaggerateAtmosphere,
          (v) => _layers.copyWith(exaggerateAtmosphere: v)),
      ('Show SOIs', _layers.showSoi, (v) => _layers.copyWith(showSoi: v)),
      ('Cull distant', _layers.cullDistant,
          (v) => _layers.copyWith(cullDistant: v)),
      ('Infinite fuel', _layers.infiniteFuel,
          (v) => _layers.copyWith(infiniteFuel: v)),
    ];
    return Container(
      width: 190,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xE6101820),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x447FB0E0)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4, top: 4, bottom: 2),
            child: Text('DRAW LAYERS',
                style: TextStyle(
                    color: Color(0xFF7FB0E0),
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ),
          for (final (label, value, set) in rows)
            InkWell(
              onTap: () => setState(() => _layers = set(!value)),
              child: Row(
                children: [
                  Checkbox(
                    value: value,
                    onChanged: (v) =>
                        setState(() => _layers = set(v ?? false)),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  Text(label,
                      style: const TextStyle(
                          color: Color(0xFFB9C9DC), fontSize: 12)),
                ],
              ),
            ),
          // Perspective camera toggle.
          InkWell(
            onTap: () =>
                setState(() => _perspectiveMode = !_perspectiveMode),
            child: Row(
              children: [
                Checkbox(
                  value: _perspectiveMode,
                  onChanged: (v) =>
                      setState(() => _perspectiveMode = v ?? false),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                const Text('Perspective',
                    style: TextStyle(color: Color(0xFFB9C9DC), fontSize: 12)),
              ],
            ),
          ),
          // FOV (tap to cycle), only meaningful in perspective.
          InkWell(
            onTap: () => setState(() {
              const opts = [50.0, 65.0, 75.0, 90.0, 105.0];
              final i = opts.indexWhere((o) => o >= _fovDeg);
              _fovDeg = opts[(i + 1) % opts.length];
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
              child: Text('FOV: ${_fovDeg.toStringAsFixed(0)}°',
                  style: const TextStyle(color: Color(0xFF7FB0E0), fontSize: 12)),
            ),
          ),
          // Tilted-view cull zoom threshold (tap to cycle).
          InkWell(
            onTap: () => setState(() {
              const opts = [3e5, 1e6, 3e6, 1e7, double.infinity];
              final i = opts.indexWhere((o) => o >= _tiltedCullMpp);
              _tiltedCullMpp = opts[(i + 1) % opts.length];
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
              child: Text(
                'Cull zoom: ${_tiltedCullMpp.isInfinite ? "never" : "${(_tiltedCullMpp / 1000).toStringAsFixed(0)}k m/px"}',
                style: const TextStyle(color: Color(0xFF7FB0E0), fontSize: 12),
              ),
            ),
          ),
          // Destruction cheats: skip overheat / aero-stress / impact so a craft
          // survives an otherwise-fatal profile. Rebuilds the tick on change.
          const Padding(
            padding: EdgeInsets.only(left: 4, top: 6, bottom: 2),
            child: Text('CHEATS',
                style: TextStyle(
                    color: Color(0xFF7FB0E0),
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ),
          _cheatRow('No overheating', _disableOverheat,
              (v) => _disableOverheat = v),
          _cheatRow('No aero load', _disableAeroStress,
              (v) => _disableAeroStress = v),
          _cheatRow('No impact damage', _disableImpact,
              (v) => _disableImpact = v),
          // Atmosphere chemistry demo: re-skin the focused planet's gas mix and
          // watch the limb's haze colour shift (driven by composition).
          const Padding(
            padding: EdgeInsets.only(left: 4, top: 6, bottom: 2),
            child: Text('ATMOSPHERE',
                style: TextStyle(
                    color: Color(0xFF7FB0E0),
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Row(children: [
              Expanded(
                child: _atmoButton('☢ Nuke', const Color(0xFFFF7043),
                    _targetBody == null ? null : _nukePlanet),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _atmoButton('Terraform', const Color(0xFF4FC3F7),
                    _targetBody == null ? null : _terraformPlanet),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Text(
              _targetBody == null
                  ? 'Lock a planet to enable.'
                  : 'Target: ${_targetBody!.name}',
              style: const TextStyle(color: Color(0xFF7E93A8), fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _atmoButton(String label, Color color, VoidCallback? onTap) =>
      InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: onTap == null
                ? const Color(0x22556677)
                : color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: onTap == null ? const Color(0x33889999) : color, width: 1),
          ),
          child: Text(label,
              style: TextStyle(
                  color: onTap == null ? const Color(0xFF66788A) : color,
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
        ),
      );

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
        backgroundColor: _perspectiveMode
            ? const Color(0xFF7FB0E0)
            : const Color(0xFF2A3A4A),
        onPressed: () {
          setState(() => _perspectiveMode = !_perspectiveMode);
          _keyFocus.requestFocus();
        },
        icon: const Icon(Icons.vrpano),
        label: Text(
            _perspectiveMode ? 'PERSP ${_fovDeg.toStringAsFixed(0)}°' : 'ORTHO'),
      ),
    );
  }

  Widget _targetDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A3A4A),
        borderRadius: BorderRadius.circular(28),
      ),
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
              for (var i = 0; i < _targets.length; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text(_targets[i].label),
                ),
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Lock the camera on a planet first (switch target).'),
          duration: Duration(seconds: 2)));
      return;
    }
    _universe.replaceBody(b.copyWith(composition: comp));
    setState(() {}); // next _tick rebuilds the snapshot from the repo
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${b.name}: $note'), duration: const Duration(seconds: 3)));
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
      'atmosphere choked with CO₂ + soot — haze warms to smog.');

  /// Terraform the focused planet to an Earthlike N2/O2 mix — the limb shifts to
  /// a clean Rayleigh blue.
  void _terraformPlanet() => _reskinAtmosphere(
      AtmosphericComposition.earth(), 'terraformed to N₂/O₂ — clean blue sky.');

  /// Serialize the whole world into the in-memory save slot.
  void _save() {
    _savedGame = jsonEncode(
      _codec.encode(
        vessels: _vessels,
        colonies: _colonies,
        deposits: _deposits,
        clock: _clock,
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved at tick ${_clock.tick}'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  /// Restore the world from the in-memory save slot.
  void _load() {
    final save = _savedGame;
    if (save == null) return;
    // Wipe live vessels so the restore replaces them.
    for (final v in _vessels.all().toList()) {
      _vessels.remove(v.id);
    }
    _codec.decode(
      jsonDecode(save) as Map<String, dynamic>,
      vessels: _vessels,
      colonies: _colonies,
      deposits: _deposits,
      clock: _clock,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Loaded tick ${_clock.tick}'),
        duration: const Duration(seconds: 1),
      ),
    );
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
            onPressed: () =>
                setState(() => _controlsExpanded = !_controlsExpanded),
            child: Icon(
                _controlsExpanded ? Icons.expand_more : Icons.expand_less),
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
            backgroundColor: _manualControl
                ? const Color(0xFFFF8C66)
                : const Color(0xFF2A3A4A),
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
            backgroundColor: _craftCam
                ? const Color(0xFF7FE0A0)
                : const Color(0xFF2A3A4A),
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
                decoration: BoxDecoration(
                  color: const Color(0xFF2A3A4A),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${_warpLevels[_warpIndex].toStringAsFixed(0)}x',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold),
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
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FloatingActionButton.small(
                heroTag: 'zoomout',
                onPressed: () => setState(() =>
                    _metresPerPixel = (_metresPerPixel * 1.4).clamp(0.5, 2e10)),
                child: const Icon(Icons.zoom_out),
              ),
              const SizedBox(width: 8),
              FloatingActionButton.small(
                heroTag: 'zoomin',
                onPressed: () => setState(() =>
                    _metresPerPixel = (_metresPerPixel / 1.4).clamp(0.5, 2e10)),
                child: const Icon(Icons.zoom_in),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FloatingActionButton.small(
                heroTag: 'save',
                onPressed: _save,
                child: const Icon(Icons.save),
              ),
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
                backgroundColor: _showDebugPanel
                    ? const Color(0xFF7FB0E0)
                    : const Color(0xFF2A3A4A),
                onPressed: () =>
                    setState(() => _showDebugPanel = !_showDebugPanel),
                child: const Icon(Icons.bug_report),
              ),
            ],
          ),
          ], // end if (_controlsExpanded)
        ],
      ),
      ), // end SafeArea(floatingActionButton)
      body: KeyboardListener(
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
          // (perspective).
          onPointerSignal: (signal) {
            if (signal is PointerScrollEvent) {
              final factor = signal.scrollDelta.dy > 0 ? 1.15 : 1 / 1.15;
              setState(() => _zoom(factor));
            }
          },
          child: GestureDetector(
            // Pinch zoom + single-finger drag orbit. d.scale is cumulative from
            // the gesture START, so anchor it to the value captured at start.
            onScaleStart: (_) {
              _pinchBaseMpp = _metresPerPixel;
              _pinchBaseRange = _range;
            },
            onScaleUpdate: (d) {
              if (d.pointerCount >= 2 && d.scale != 1.0) {
                // Two-finger pinch -> zoom.
                setState(() {
                  if (_perspectiveMode) {
                    _range = (_pinchBaseRange / d.scale).clamp(100.0, 1e13);
                  } else {
                    _metresPerPixel =
                        (_pinchBaseMpp / d.scale).clamp(0.5, 2e10);
                  }
                });
              } else {
                // Single-finger drag -> orbit the camera (pitch inverted).
                final dd = d.focalPointDelta;
                _orbitCamera(dd.dx * 0.005, dd.dy * 0.005);
              }
            },
            child: Stack(
              children: [
                // Renderer fills edge-to-edge (into the notch / safe area).
                Positioned.fill(
                  child: snap == null
                      ? const Center(child: CircularProgressIndicator())
                      : LayoutBuilder(builder: (context, constraints) {
                          // The perspective focal length must use the ACTUAL
                          // render-canvas height, not the full MediaQuery window
                          // (which over-states it and makes the lens read long /
                          // the planet a touch small). Update it from the real
                          // layout height each build.
                          if (constraints.maxHeight.isFinite &&
                              constraints.maxHeight > 0) {
                            _screenH = constraints.maxHeight;
                          }
                          return CustomPaint(
                            size: Size.infinite,
                            painter: TopDownPainter(
                              snap,
                              textures: _textures,
                              view: _activeCamera ??
                                  OrthoCamera(_view, _metresPerPixel),
                              layers: _layers,
                            ),
                          );
                        }),
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
                    child: Center(
                      child: NavBall(state: _navState()!, size: 120),
                    ),
                  ),
                // Debug draw-layer toggle panel (top-right).
                if (_showDebugPanel)
                  Positioned(top: 8, right: 8, child: _debugPanel()),
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: Text(
                    _manualControl
                        ? 'MANUAL  keys: W/S A/D Q/E Shift  |  touch: joystick + throttle  |  M auto  |  pinch/wheel/[ ] zoom'
                        : 'AUTO  (M or tap for manual flight)  |  pinch/scroll/[ ] zoom',
                    style: TextStyle(
                      color: _manualControl
                          ? const Color(0xFFFF8C66)
                          : const Color(0xFF6E8299),
                      fontSize: 11,
                    ),
                  ),
                ),
                // Build stamp (bottom-left, bright) to confirm a fresh deploy.
                Positioned(
                  left: 8,
                  bottom: 28,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                // On-screen flight controls (touch), only in manual mode.
                if (_manualControl) ..._touchControls(),
                // Vessel-lost menu (modal over everything).
                if (_crashNotice != null) _crashMenu(_crashNotice!),
                      ],
                    ),
                  ),
                ), // end overlay SafeArea Positioned.fill
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
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _flightStatusRow(),
              // FINE throttle — an absolute 0..10% throttle for delicate landing
              // burns (full slider span = 10% thrust). Sits ABOVE the coarse one.
              Row(children: [
                const SizedBox(
                    width: 56,
                    child: Text('FINE',
                        style: TextStyle(color: Color(0xFFFFC58A), fontSize: 11))),
                Expanded(
                  child: SliderTheme(
                    data: const SliderThemeData(
                        activeTrackColor: Color(0xFFFFC58A),
                        inactiveTrackColor: Color(0x33FFC58A),
                        thumbColor: Color(0xFFFFC58A),
                        trackHeight: 2),
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
                        style: const TextStyle(
                            color: Color(0xFFFFC58A), fontSize: 11))),
              ]),
              // Throttle — held (does NOT self-centre).
              Row(children: [
                const SizedBox(
                    width: 56,
                    child: Text('THR', style: TextStyle(color: Color(0xFFFF8C66), fontSize: 12))),
                Expanded(
                  child: SliderTheme(
                    data: const SliderThemeData(
                        activeTrackColor: Color(0xFFFF8C66),
                        thumbColor: Color(0xFFFF8C66),
                        trackHeight: 3),
                    child: Slider(
                      value: _touchThrottle,
                      onChanged: (v) => setState(() => _touchThrottle = v),
                    ),
                  ),
                ),
                SizedBox(
                    width: 40,
                    child: Text('${(_touchThrottle * 100).round()}%',
                        textAlign: TextAlign.right,
                        style: const TextStyle(color: Color(0xFFFF8C66), fontSize: 12))),
              ]),
              _axisRow('PITCH', _touchPitch, (v) => _touchPitch = v),
              _axisRow('YAW', _touchYaw, (v) => _touchYaw = v),
              _axisRow('ROLL', _touchRoll, (v) => _touchRoll = v),
            ]),
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
      child: Row(children: [
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
                  minimumSize: const Size(0, 30)),
              icon: const Icon(Icons.location_city, size: 16),
              label: const Text('FOUND', style: TextStyle(fontSize: 11)),
              onPressed: () => _foundColony(v),
            ),
          ),
      ]),
    );
  }

  /// Found a colony where the landed [v] sits: open the City Builder on that body
  /// at the craft's surface lat/long.
  void _foundColony(Vessel v) {
    final body = _universe.current().body(v.dominantBody);
    if (body == null) return;
    final dir = v.state.position.normalized;
    final latDeg = math.asin(dir.z.clamp(-1.0, 1.0)) * 180 / math.pi;
    final lonDeg = math.atan2(dir.y, dir.x) * 180 / math.pi;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CityBuilderScreen(
        config: CityConfig(
          bodyId: body.id.value,
          latitude: latDeg,
          longitude: lonDeg,
        ),
      ),
    ));
  }

  /// A self-centring attitude axis slider (-1..1), snapping back to 0 on release.
  Widget _axisRow(String label, double value, void Function(double) set) =>
      Row(children: [
        SizedBox(
            width: 56,
            child: Text(label,
                style: const TextStyle(color: Color(0xFF9FB4CC), fontSize: 12))),
        Expanded(
          child: SliderTheme(
            data: const SliderThemeData(
                activeTrackColor: Color(0xFF7FE0A0),
                thumbColor: Color(0xFF7FE0A0),
                trackHeight: 2),
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
      ]);
}
