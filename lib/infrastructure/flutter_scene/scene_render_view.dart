// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_scene/scene.dart' as fs;

import '../../adapters/presenters/camera_view.dart';
import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/vector3.dart';
import '../flutter/texture_cache.dart';
import 'atmosphere_nodes.dart';
import 'ring_nodes.dart';
import 'terrain/terrain_nodes.dart';
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
    this.focusWorldOverride,
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

  /// Freecam: when set, the floating origin follows this absolute world
  /// position (metres) instead of the focus target.
  final Vector3? focusWorldOverride;

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

  /// Frame-coalescing guard: pointer events can trigger several builds per
  /// vsync, and each GPU-touching sync pass rebuilds geometry through the
  /// engine's transient upload path — overlapping rebuilds inside one
  /// painted frame alias and tear (pale shards under mouse drag). Only the
  /// FIRST build in a given frame does GPU work; later builds this frame
  /// reuse it (the last one's camera wins next frame).
  Duration? _lastSyncFrame;

  @override
  void initState() {
    super.initState();
    // Custom shader bundle (raymarched atmosphere + ring sheet).
    // Independent of the base bundle; on failure those layers simply never
    // spawn — log, don't brick the whole viewport.
    AtmosphereNodes.loadShader().catchError((Object e) {
      debugPrint('atmosphere shader load failed: $e');
    });
    RingNodes.loadShader().catchError((Object e) {
      debugPrint('ring shader load failed: $e');
    });
    TerrainNodes.loadShader().catchError((Object e) {
      debugPrint('terrain shader load failed: $e');
    });
    TerrainNodes.loadTextures().catchError((Object e) {
      debugPrint('terrain textures load failed: $e');
    });
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
      final frame = SchedulerBinding.instance.currentSystemFrameTimeStamp;
      final firstBuildThisFrame = _lastSyncFrame != frame;
      _lastSyncFrame = frame;
      if (snap != null && firstBuildThisFrame) {
        sync.update(
          snap,
          camera: widget.camera,
          viewport: viewport,
          focusVesselId: widget.focusVesselId,
          focusBodyId: widget.focusBodyId,
          focusWorldOverride: widget.focusWorldOverride,
        );
      }
      // Strip expansion is copy-on-write inside updateForCamera and, like
      // sync.update, runs at most once per painted frame. Never inside
      // SceneView's own repaint ticker, and never twice per vsync.
      final camera = toSceneCamera(widget.camera, viewportH: viewport.height);
      if (firstBuildThisFrame) {
        sync.updateForCamera(camera, viewport);
      }
      // CHIRALITY: the domain camera basis and flutter_scene's lookAt have
      // opposite triple handedness, so the raw render is a mirror image
      // (reversed panning, backwards orbits). Reflecting the WORLD instead
      // flips triangle winding scene-wide (backface culling then shows
      // every mesh inside-out). Correcting the finished IMAGE is winding-
      // and lighting-neutral; equirect textures are pre-mirrored in
      // sphere_geometry_util.dart so they read correctly after this flip.
      return Transform.flip(
        flipX: true,
        child: fs.SceneView(sync.scene, camera: camera),
      );
    });
  }
}
