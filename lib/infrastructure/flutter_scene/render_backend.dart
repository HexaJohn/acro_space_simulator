/// Which rendering backend [SimulationView] mounts for the world viewport.
///
/// Both backends share the SAME camera state ([CameraOrbit] + range/fov) and
/// the same domain repos; they differ in what they consume:
///  - [software]: the 2D pre-projected `TopDownSnapshot` via `TopDownPainter`
///    (CustomPainter). The default and fallback everywhere.
///  - [flutterScene]: the raw 3D `WorldSnapshot` (same feed the Unreal bridge
///    serializes) via an in-process flutter_scene / Impeller scene graph.
///    Windows desktop first (`--enable-impeller`).
enum RenderBackend {
  software,
  flutterScene;

  RenderBackend get next => switch (this) {
        software => flutterScene,
        flutterScene => software,
      };

  String get label => switch (this) {
        software => 'Software (2D)',
        flutterScene => 'flutter_scene (3D)',
      };
}
