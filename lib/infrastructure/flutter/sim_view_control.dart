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

  /// Current camera/backend state for assertions and closed-loop control.
  Map<String, Object?> Function()? status;

  void clear() {
    orbit = null;
    zoom = null;
    setPerspective = null;
    setBackend = null;
    status = null;
  }
}
