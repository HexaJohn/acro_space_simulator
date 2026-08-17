// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../../domain/shared/vector3.dart';
import '../flutter_scene/render_backend.dart';

/// Programmatic control surface for the live [SimulationView] — lets dev
/// tooling (VM-service extensions in main_scene_dev.dart, integration
/// harnesses) drive the camera and renderer without synthesizing input
/// events. The active view state registers itself here on init and clears
/// on dispose; callers no-op harmlessly when no view is live.
///
/// Function refs rather than an interface: the view assigns closures that
/// wrap setState, so every mutation repaints exactly like user input.
class SimViewControl {
  SimViewControl._();

  static final SimViewControl instance = SimViewControl._();

  /// Orbit the camera. Radians; any subset. Absolute, not deltas.
  void Function({double? azimuth, double? elevation, double? roll})? orbit;

  /// Zoom: perspective eye range (metres above the focus surface) and/or
  /// ortho metres-per-pixel.
  void Function({double? rangeM, double? metresPerPixel})? zoom;

  /// Toggle perspective (true) vs ortho map (false) projection.
  void Function(bool perspective)? setPerspective;

  /// Switch the world-viewport backend.
  void Function(RenderBackend backend)? setBackend;

  /// Lock the camera focus onto a body by id (e.g. 'saturn'), clearing any
  /// vessel lock.
  void Function(String bodyId)? focusBody;

  /// Auto-warp the focused vessel to its next apsis ('ap' | 'pe'), exactly
  /// like the AP/PE buttons.
  void Function(bool periapsis)? warpToApsis;

  /// Camera up alignment by name: 'free' | 'axis' | 'gravity'.
  void Function(String mode)? setUpMode;

  /// Freecam on/off, optionally teleporting the anchor (world metres).
  void Function(bool on, Vector3? pos)? setFreecam;

  /// First-person walk on/off. Turning it on implies the freecam and drops
  /// the anchor onto the terrain under the current view — the one-call way to
  /// put a surface capture at eye height.
  void Function(bool on)? setWalk;

  /// Freecam teleport INTO a body's ring plane: radial in body radii,
  /// height above the plane in metres. Exact — computed through the body's
  /// live orientation quaternion (guessing the plane from axial tilt
  /// conventions goes thousands of km wrong).
  void Function(String bodyId, double radialMult, double zM)? freecamToRing;

  /// Drop a test impactor beside the focused craft (the debug panel's
  /// "Drop impactor" button), with explicit mass/speed. For driving the
  /// impact-FX path from dev tooling. [destroy] true forces the
  /// craft-destruction cheat OFF first so the hit raises its Impact event
  /// (the FX trigger) instead of settling a cheated-alive lump.
  void Function({double massKg, double speedMs, bool destroy})? dropImpactor;

  /// Teleport the focused craft to a scored landing site on [bodyId] (the
  /// debug panel's custom spawn, landed mode) — puts the camera at ground
  /// level for surface/FX captures.
  void Function(String bodyId)? spawnLanded;

  /// Current camera/backend state for assertions and closed-loop control.
  Map<String, Object?> Function()? status;

  void clear() {
    orbit = null;
    zoom = null;
    setPerspective = null;
    setBackend = null;
    focusBody = null;
    warpToApsis = null;
    setUpMode = null;
    setFreecam = null;
    setWalk = null;
    freecamToRing = null;
    dropImpactor = null;
    spawnLanded = null;
    status = null;
  }
}
