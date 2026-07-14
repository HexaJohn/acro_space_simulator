// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

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
