import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' as fs;

import '../../adapters/presenters/camera_view.dart';
import '../../application/snapshot/world_snapshot.dart';
import '../flutter/texture_cache.dart';
import 'scene_camera_adapter.dart';
import 'scene_sync.dart';

/// The flutter_scene (Impeller) world viewport.
///
/// Consumes the app's shared camera state and the per-frame [WorldSnapshot]
/// — the same 3D world feed the Unreal bridge serializes, NOT the 2D
/// `TopDownSnapshot`. The scene graph is focus-relative (floating origin at
/// the camera target) and keeps the domain's right-handed Z-up frame; all
/// conversions live in coord_convert.dart.
class SceneRenderView extends StatefulWidget {
  const SceneRenderView({
    super.key,
    required this.camera,
    required this.textures,
    this.snapshot,
    this.focusVesselId,
    this.focusBodyId,
  });

  /// The app camera for this frame (shared with the software renderer).
  /// Focus-relative: the camera always looks at the scene origin.
  final SceneCamera camera;

  /// Shared decoded-image cache (same instance the software painter uses).
  final TextureCache textures;

  /// This frame's world state; null before the first sim tick.
  final WorldSnapshot? snapshot;

  /// Camera lock target — exactly one is non-null. The floating origin
  /// follows it.
  final String? focusVesselId;
  final String? focusBodyId;

  @override
  State<SceneRenderView> createState() => _SceneRenderViewState();
}

class _SceneRenderViewState extends State<SceneRenderView> {
  /// Base shader bundle load. Static: kicked off once per app, shared by
  /// every view. Geometry/material CONSTRUCTION (not just rendering) throws
  /// before it completes — everything is gated on it.
  static final Future<void> _staticInit = fs.Scene.initializeStaticResources();
  bool _ready = false;

  SceneSync? _sync;

  @override
  void initState() {
    super.initState();
    _staticInit.then((_) {
      if (!mounted) return;
      _sync = SceneSync(
        fs.Scene(),
        widget.textures,
        // Texture uploads land async; nudge a rebuild so materials swap in.
        onTexture: () {
          if (mounted) setState(() {});
        },
      );
      setState(() => _ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final sync = _sync;
    if (!_ready || sync == null) {
      return const ColoredBox(
        color: Color(0xFF000000),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final snap = widget.snapshot;
    return LayoutBuilder(builder: (context, constraints) {
      final viewport = Size(constraints.maxWidth, constraints.maxHeight);
      if (snap != null) {
        sync.update(
          snap,
          camera: widget.camera,
          viewport: viewport,
          focusVesselId: widget.focusVesselId,
          focusBodyId: widget.focusBodyId,
        );
      }
      // Strip expansion happens exactly ONCE per app frame, here, on
      // freshly created geometry (sync.update recreates every polyline's
      // buffers each frame). Never inside SceneView's own repaint ticker:
      // in-place writes to GPU buffers that an in-flight frame is reading
      // tear visibly (black shards). The camera only changes when
      // SimulationView rebuilds — the same build that runs this — so
      // SceneView's extra repaints between builds render a CONSTANT
      // camera against valid strips.
      final camera = toSceneCamera(widget.camera, viewportH: viewport.height);
      sync.updateForCamera(camera, viewport);
      return fs.SceneView(sync.scene, camera: camera);
    });
  }
}
