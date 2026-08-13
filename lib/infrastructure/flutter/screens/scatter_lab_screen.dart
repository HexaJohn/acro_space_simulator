// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../domain/scatter/prop_catalog.dart';
import '../../../domain/scatter/prop_model.dart';
import '../../flutter_scene/coord_convert.dart';
import '../../flutter_scene/scatter/prop_preview_nodes.dart';
import '../../flutter_scene/scatter/scatter_prop_library.dart';
import '../scatter_lab_control.dart';
import 'app_theme.dart';

/// A viewer for the procedural prop generators: pick a species, a seed and a
/// detail level, and see exactly what the scatter system will draw.
///
/// This exists because every knob in the generators is a judgement call that
/// cannot be made from a triangle count. Whether a conifer's whorls sit too
/// high, whether LOD2 still reads as the same tree, whether the imposter pops
/// on switch — all of it is a look-at-it question, and answering it by flying
/// to a planet surface each time would make tuning impossibly slow.
///
/// It draws through the real instanced path (see [PropPreviewNodes]), so the
/// cost readout is the cost you will actually pay.
class ScatterLabScreen extends StatefulWidget {
  const ScatterLabScreen({super.key});

  @override
  State<ScatterLabScreen> createState() => _ScatterLabScreenState();
}

class _ScatterLabScreenState extends State<ScatterLabScreen> {
  /// Base flutter_scene resources. Static: shared with every other view in the
  /// app, and geometry CONSTRUCTION (not just drawing) throws before it lands.
  static final Future<void> _staticInit = fs.Scene.initializeStaticResources();

  fs.Scene? _scene;
  PropPreviewNodes? _nodes;
  String? _error;

  // Camera (turntable): azimuth/elevation about the layout centre.
  double _azimuth = 0.9;
  double _elevation = 0.28;
  double _distanceM = 30.0;
  double _pivotZM = 4.0;

  // Controls.
  PropKind _kind = PropKind.broadleafTree;
  int _seed = 1;
  int _gridSide = 1;
  PropLod _lod = PropLod.lod0;
  bool _autoLod = false;
  bool _varySeeds = true;
  double _sunAzimuth = 0.8;

  static const double _fovY = 50 * math.pi / 180;

  @override
  void initState() {
    super.initState();
    _staticInit.then((_) async {
      try {
        await ScatterPropLibrary.loadTextures();
      } catch (e) {
        if (mounted) setState(() => _error = 'texture bake failed: $e');
        return;
      }
      if (!mounted) return;
      final scene = fs.Scene();
      // The props are the subject, so keep the image-based ambient low and let
      // the directional light do the shading — the same balance scene_sync
      // strikes, and without it every prop washes out to flat white.
      scene.environmentIntensity = 0.18;
      ScatterPropLibrary.instance.addListener(_onLibraryChanged);
      _registerControl();
      setState(() {
        _scene = scene;
        _nodes = PropPreviewNodes(scene);
        _frameSubject();
      });
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  /// Expose the controls to the dev harness (see [ScatterLabControl]).
  void _registerControl() {
    final control = ScatterLabControl.instance;
    control.apply = ({
      PropKind? kind,
      int? seed,
      int? gridSide,
      PropLod? lod,
      bool? autoLod,
      bool? varySeeds,
      double? azimuth,
      double? elevation,
      double? distanceM,
      double? sunAzimuth,
      bool? frame,
    }) {
      if (!mounted) return;
      setState(() {
        if (kind != null) _kind = kind;
        if (seed != null) _seed = seed;
        if (gridSide != null) _gridSide = gridSide;
        if (lod != null) _lod = lod;
        if (autoLod != null) _autoLod = autoLod;
        if (varySeeds != null) _varySeeds = varySeeds;
        // Framing runs BEFORE any explicit camera value so a call can reframe
        // for a new species and then nudge the result in one go.
        if (frame ?? (kind != null || gridSide != null)) _frameSubject();
        if (azimuth != null) _azimuth = azimuth;
        if (elevation != null) _elevation = elevation;
        if (distanceM != null) _distanceM = distanceM;
        if (sunAzimuth != null) _sunAzimuth = sunAzimuth;
      });
    };
    control.status = () {
      final s = _nodes?.stats ?? PropPreviewStats.empty;
      return {
        'kind': _kind.name,
        'seed': _seed,
        'gridSide': _gridSide,
        'lod': _autoLod ? 'auto' : _lod.name,
        'instances': s.instances,
        'triangles': s.triangles,
        'drawCalls': s.drawCalls,
        'drawnLod': s.drawnLod.name,
        'heightM': s.heightM,
        'imposterReady': s.imposterReady,
        'distanceM': _distanceM,
        'azimuth': _azimuth,
        'elevation': _elevation,
      };
    };
  }

  /// An imposter finished baking: force the node layer to rebuild (so the fresh
  /// billboard is picked up) and repaint the HUD.
  void _onLibraryChanged() {
    if (!mounted) return;
    _nodes?.invalidate();
    setState(() {});
  }

  @override
  void dispose() {
    ScatterPropLibrary.instance.removeListener(_onLibraryChanged);
    final control = ScatterLabControl.instance;
    control.apply = null;
    control.status = null;
    _nodes?.dispose();
    super.dispose();
  }

  PropPreviewRequest get _request => PropPreviewRequest(
        kind: _kind,
        seed: _seed,
        gridSide: _gridSide,
        lod: _lod,
        autoLod: _autoLod,
        varySeeds: _varySeeds,
      );

  /// Pull the camera back far enough to hold the whole layout, and raise the
  /// pivot to the middle of the props rather than the ground.
  void _frameSubject() {
    final nodes = _nodes;
    if (nodes == null) return;
    // Ask the library directly: the layout radius is only known after a build,
    // and on a species change we need the framing BEFORE the first draw.
    final prop = ScatterPropLibrary.instance.get(_kind, seed: _seed);
    final spacing = math.max(_kind.previewSpacingM, prop.radiusM * 2.2);
    final extent = (_gridSide - 1) * spacing;
    final radius = math.max(extent * 0.71, prop.heightM * 0.6) + spacing * 0.6;
    _pivotZM = prop.heightM * 0.45;
    _distanceM = radius / math.tan(_fovY * 0.5) * 1.15;
  }

  void _apply(VoidCallback change) => setState(change);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.panel,
        foregroundColor: AppTheme.text,
        title: const Text('SCATTER LAB', style: AppTheme.heading),
        actions: [
          IconButton(
            tooltip: 'Frame subject',
            icon: const Icon(Icons.center_focus_strong),
            onPressed: () => _apply(_frameSubject),
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(child: _viewport()),
          SizedBox(width: 300, child: _controls()),
        ],
      ),
    );
  }

  // ---- Viewport -----------------------------------------------------------

  Widget _viewport() {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Scatter lab unavailable\n\n$error',
              textAlign: TextAlign.center, style: AppTheme.dim),
        ),
      );
    }
    final scene = _scene;
    final nodes = _nodes;
    if (scene == null || nodes == null) {
      return const ColoredBox(
        color: Color(0xFF0B0E12),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      final viewport = Size(constraints.maxWidth, constraints.maxHeight);
      _syncSun(scene);
      nodes.update(
        _request,
        cameraDistanceM: _distanceM,
        fovY: _fovY,
        viewportHeightPx: viewport.height,
      );
      final camera = _camera();

      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onScaleStart: (_) => _dragBase = (_azimuth, _elevation),
              onScaleUpdate: (d) => _apply(() {
                if (d.pointerCount > 1) {
                  _distanceM = (_distanceM / d.scale.clamp(0.2, 5.0))
                      .clamp(0.2, 4000.0);
                } else {
                  _azimuth = _dragBase.$1 - d.focalPointDelta.dx * 0.008;
                  _elevation = (_dragBase.$2 + d.focalPointDelta.dy * 0.006)
                      .clamp(-1.35, 1.45);
                  // Accumulate so a long drag keeps turning rather than
                  // snapping back to the gesture's start each frame.
                  _dragBase = (_azimuth, _elevation);
                }
              }),
              child: Listener(
                onPointerSignal: (e) {
                  if (e is PointerScrollEvent) {
                    _apply(() => _distanceM =
                        (_distanceM * (1 + e.scrollDelta.dy * 0.0016))
                            .clamp(0.2, 4000.0));
                  }
                },
                // CHIRALITY: the app's world-to-scene mapping is a mirror that
                // SceneRenderView corrects by flipping the finished image.
                // The lab flips too, so what you tune here is what the sim
                // shows.
                child: Transform.flip(
                  flipX: true,
                  child: fs.SceneView(scene, camera: camera),
                ),
              ),
            ),
          ),
          Positioned(left: 12, top: 12, child: _statsPanel(nodes.stats)),
        ],
      );
    });
  }

  (double, double) _dragBase = (0, 0);

  fs.PerspectiveCamera _camera() {
    final ce = math.cos(_elevation), se = math.sin(_elevation);
    final dir = vm.Vector3(
      math.cos(_azimuth) * ce,
      math.sin(_azimuth) * ce,
      se,
    );
    final target = vm.Vector3(0, 0, lengthToScene(_pivotZM));
    return fs.PerspectiveCamera(
      fovRadiansY: _fovY,
      position: target + dir * lengthToScene(_distanceM),
      target: target,
      // The scene keeps the domain's Z-up frame (see coord_convert).
      up: vm.Vector3(0, 0, 1),
      // Props span centimetres to tens of metres and the scene unit is a
      // kilometre, so the default 0.1 near plane would sit 100 m in front of
      // the camera and clip the entire subject away.
      fovNear: lengthToScene(math.max(_distanceM * 0.01, 0.02)),
      fovFar: lengthToScene(_distanceM * 12 + 200),
    );
  }

  void _syncSun(fs.Scene scene) {
    // Light TRAVELS along this vector (see scene_sync's note), so a sun in the
    // north-west shines toward the south-east.
    final dir = vm.Vector3(
      -math.cos(_sunAzimuth),
      -math.sin(_sunAzimuth),
      -0.55,
    )..normalize();
    final light = scene.directionalLight;
    if (light == null) {
      scene.directionalLight = fs.DirectionalLight(
        direction: dir,
        intensity: 2.2,
      );
    } else {
      light.direction = dir;
    }
  }

  // ---- HUD ----------------------------------------------------------------

  Widget _statsPanel(PropPreviewStats s) {
    final mono = AppTheme.mono.copyWith(fontSize: 11, color: AppTheme.text);
    String row(String k, String v) => '${k.padRight(11)}$v';
    final lodMix = s.byLod.entries
        .map((e) => '${_lodLabel(e.key)}x${e.value}')
        .join('  ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xCC0B0E12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.accent2.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_kind.label, style: AppTheme.mono.copyWith(
              fontSize: 12, color: AppTheme.accent2)),
          const SizedBox(height: 4),
          Text(row('size', '${s.heightM.toStringAsFixed(2)} m tall, '
              '${(s.radiusM * 2).toStringAsFixed(2)} m across'), style: mono),
          Text(row('instances', '${s.instances}'), style: mono),
          Text(row('drawing', '${_lodLabel(s.drawnLod)}  '
              '${s.triangles} tris  ${s.drawCalls} draws'), style: mono),
          if (s.lodTriangles.isNotEmpty)
            Text(
                row(
                    'per prop',
                    [PropLod.lod0, PropLod.lod1, PropLod.lod2]
                        .map((l) =>
                            '${_lodLabel(l)}:${s.lodTriangles[l] ?? 0}')
                        .join('  ')),
                style: mono),
          if (_autoLod && lodMix.isNotEmpty)
            Text(row('auto mix', lodMix), style: mono),
          Text(
            row('imposter', s.imposterReady ? 'baked' : 'baking...'),
            style: mono.copyWith(
                color: s.imposterReady ? AppTheme.text : AppTheme.warn),
          ),
          Text(row('camera', '${_distanceM.toStringAsFixed(1)} m'),
              style: mono.copyWith(color: AppTheme.textDim)),
        ],
      ),
    );
  }

  static String _lodLabel(PropLod lod) => switch (lod) {
        PropLod.lod0 => 'LOD0',
        PropLod.lod1 => 'LOD1',
        PropLod.lod2 => 'LOD2',
        PropLod.billboard => 'BILL',
      };

  // ---- Controls -----------------------------------------------------------

  Widget _controls() {
    // Material, not a coloured Container: ListTile paints its ink splashes onto
    // the nearest Material ancestor, and a plain ColoredBox in between hides
    // them (Flutter asserts loudly about it every frame).
    return Material(
      color: AppTheme.panel,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _sectionLabel('SPECIES'),
          for (final family in PropFamily.values) ...[
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: Text(_familyLabel(family),
                  style: AppTheme.dim.copyWith(fontSize: 10)),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final kind
                    in PropKind.values.where((k) => k.family == family))
                  _chip(
                    kind.label,
                    selected: _kind == kind,
                    onTap: () => _apply(() {
                      _kind = kind;
                      _frameSubject();
                    }),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          _sectionLabel('INDIVIDUAL'),
          Row(
            children: [
              Expanded(
                child: Text('seed $_seed',
                    style: AppTheme.mono.copyWith(fontSize: 12)),
              ),
              IconButton(
                iconSize: 18,
                icon: const Icon(Icons.chevron_left),
                onPressed: () =>
                    _apply(() => _seed = math.max(1, _seed - 1)),
              ),
              IconButton(
                iconSize: 18,
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _apply(() => _seed += 1),
              ),
              IconButton(
                iconSize: 18,
                tooltip: 'Random seed',
                icon: const Icon(Icons.casino),
                onPressed: () => _apply(
                    () => _seed = 1 + math.Random().nextInt(9999)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _sectionLabel('DETAIL LEVEL'),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('Auto (by screen size)',
                style: AppTheme.mono.copyWith(fontSize: 12)),
            subtitle: Text(
                'Picks the level the scatter system would, from how big the '
                'prop is on screen. Zoom out to watch it step down.',
                style: AppTheme.dim.copyWith(fontSize: 10)),
            value: _autoLod,
            activeThumbColor: AppTheme.accent2,
            onChanged: (v) => _apply(() => _autoLod = v),
          ),
          Wrap(
            spacing: 6,
            children: [
              for (final lod in PropLod.values)
                _chip(
                  _lodLabel(lod),
                  selected: !_autoLod && _lod == lod,
                  enabled: !_autoLod,
                  onTap: () => _apply(() => _lod = lod),
                ),
            ],
          ),
          const SizedBox(height: 14),
          _sectionLabel('INSTANCES'),
          Wrap(
            spacing: 6,
            children: [
              for (final n in const [1, 2, 4, 8, 16, 32])
                _chip(
                  n == 1 ? '1' : '${n * n}',
                  selected: _gridSide == n,
                  onTap: () => _apply(() {
                    _gridSide = n;
                    _frameSubject();
                  }),
                ),
            ],
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('Vary seed per instance',
                style: AppTheme.mono.copyWith(fontSize: 12)),
            subtitle: Text(
                'Off repeats one individual — the way to judge a single prop. '
                'On shows the variety the species produces.',
                style: AppTheme.dim.copyWith(fontSize: 10)),
            value: _varySeeds,
            activeThumbColor: AppTheme.accent2,
            onChanged: (v) => _apply(() => _varySeeds = v),
          ),
          const SizedBox(height: 8),
          _sectionLabel('SUN'),
          Slider(
            value: _sunAzimuth,
            min: 0,
            max: 2 * math.pi,
            activeColor: AppTheme.accent2,
            onChanged: (v) => _apply(() => _sunAzimuth = v),
          ),
          const SizedBox(height: 8),
          Text(
            'Drag to orbit  ·  scroll or pinch to zoom',
            style: AppTheme.dim.copyWith(fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text,
            style: AppTheme.mono
                .copyWith(fontSize: 10, color: AppTheme.textDim)),
      );

  static String _familyLabel(PropFamily f) => switch (f) {
        PropFamily.tree => 'Trees',
        PropFamily.plant => 'Ground cover',
        PropFamily.rock => 'Rock',
      };

  Widget _chip(
    String label, {
    required bool selected,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    final colour = selected ? AppTheme.accent2 : AppTheme.textDim;
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: Material(
        color: selected
            ? AppTheme.accent2.withValues(alpha: 0.16)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          borderRadius: BorderRadius.circular(5),
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: colour.withValues(alpha: 0.55)),
            ),
            child: Text(label,
                style: AppTheme.mono.copyWith(fontSize: 11, color: colour)),
          ),
        ),
      ),
    );
  }
}
