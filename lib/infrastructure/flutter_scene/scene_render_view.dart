import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../adapters/presenters/camera_view.dart';
import 'scene_camera_adapter.dart';

/// The flutter_scene (Impeller) world viewport.
///
/// Consumes the app's shared camera state and (from WS1 on) the per-frame
/// `WorldSnapshot` — the same 3D world feed the Unreal bridge serializes,
/// NOT the 2D `TopDownSnapshot`. The scene graph is focus-relative
/// (floating origin at the camera target) and keeps the domain's
/// right-handed Z-up frame; all conversions live in coord_convert.dart.
///
/// WS0 state: a fixed Earth-radius test sphere at the focus plus a sun
/// light — enough to prove Impeller compositing, the camera adapter, and
/// float precision end-to-end. WS1 replaces the sphere with real bodies
/// synced from WorldSnapshot.
class SceneRenderView extends StatefulWidget {
  const SceneRenderView({super.key, required this.camera});

  /// The app camera for this frame (shared with the software renderer).
  /// Focus-relative: the camera always looks at the scene origin.
  final SceneCamera camera;

  @override
  State<SceneRenderView> createState() => _SceneRenderViewState();
}

class _SceneRenderViewState extends State<SceneRenderView> {
  final fs.Scene _scene = fs.Scene();

  /// Base shader bundle load. Static: kicked off once per app, shared by
  /// every view. Rendering before it completes throws — gate on it.
  static final Future<void> _staticInit = fs.Scene.initializeStaticResources();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    // Geometry and material construction ALSO touch the base shader
    // library, so even scene population must wait for the bundle load —
    // not just the first render.
    _staticInit.then((_) {
      if (!mounted) return;
      _populate();
      setState(() => _ready = true);
    });
  }

  void _populate() {
    // WS0 test sphere: Earth radius in scene units (km), at the focus.
    final sphere = fs.Node(
      mesh: fs.Mesh(
        fs.SphereGeometry(radius: 6371.0, segments: 96, rings: 48),
        fs.PhysicallyBasedMaterial()
          ..baseColorFactor = vm.Vector4(0.22, 0.42, 0.65, 1.0)
          ..roughnessFactor = 0.9
          ..metallicFactor = 0.0,
      ),
    );
    _scene.add(sphere);

    // Sun along -X (light travels toward the scene). Domain frame, Z up.
    _scene.directionalLight = fs.DirectionalLight(
      direction: vm.Vector3(-1.0, -0.2, -0.1),
      intensity: 5.0,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const ColoredBox(
        color: Color(0xFF000000),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return fs.SceneView(_scene, camera: toSceneCamera(widget.camera));
  }
}
