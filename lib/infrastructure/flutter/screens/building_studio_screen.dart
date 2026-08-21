// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../domain/architecture/architecture_style.dart';
import '../../../domain/architecture/building_generator.dart';
import '../../../domain/colony/city/city_building_spec.dart';
import '../../flutter_scene/city/building_preview_nodes.dart';
import '../../flutter_scene/city/city_materials.dart';
import '../../flutter_scene/city/city_textures.dart';
import '../../flutter_scene/coord_convert.dart';
import 'app_theme.dart';

/// A block face you can look at, in the time it takes to move a slider.
///
/// The city studio proved a colony can be generated and afforded. It is the
/// wrong tool for the question that came next — whether the buildings in it
/// look like buildings — because a whole city takes ten seconds to regenerate,
/// puts the thing you want to inspect four hundred metres away behind other
/// buildings, and answers "is this facade right?" with a view of a roof.
///
/// This is the tight loop for that question: one street, a handful of lots, a
/// building on each, rebuilt in single-digit milliseconds. The controls are
/// deliberately the inputs the generator actually takes — the lot, the spec,
/// the style — so nothing you tune here has to be translated to reach the
/// colony.
class BuildingStudioScreen extends StatefulWidget {
  const BuildingStudioScreen({super.key});

  @override
  State<BuildingStudioScreen> createState() => _BuildingStudioScreenState();
}

class _BuildingStudioScreenState extends State<BuildingStudioScreen> {
  /// Shared flutter_scene resources; geometry CONSTRUCTION throws without it.
  static final Future<void> _staticInit = fs.Scene.initializeStaticResources();

  fs.Scene? _scene;
  BuildingPreviewNodes? _nodes;
  bool _texturesPending = false;

  // ---- Controls ----------------------------------------------------------
  ArchitectureStyle _style = ArchitectureStyle.masonryStreet;
  String _zone = 'commercial';
  Density _density = Density.medium;
  double _lotWidthM = 22;
  double _lotDepthM = 34;
  double _lots = 5;
  int _seed = 1;
  BuildingDetail _detail = BuildingDetail.full;
  bool _varySeeds = true;
  bool _showRig = true;
  bool _showLots = true;
  bool _corners = true;

  // ---- Camera ------------------------------------------------------------
  double _azimuth = 1.35;
  double _elevation = 0.22;
  double _distanceM = 120;
  double _pivotZM = 8;
  double _sunAzimuth = 0.9;
  (double, double) _dragBase = (0, 0);

  static const double _fovY = 50 * math.pi / 180;

  CityBuildingSpec get _spec => kZoneSpecs[_zone]![_density]!;

  BuildingPreviewRequest get _request => BuildingPreviewRequest(
        style: _style,
        spec: _spec,
        lotWidthM: _lotWidthM,
        lotDepthM: _lotDepthM,
        lots: _lots.round(),
        seed: _seed,
        detail: _detail,
        varySeeds: _varySeeds,
        showRig: _showRig,
        showLots: _showLots,
        corners: _corners,
      );

  @override
  void dispose() {
    _nodes?.dispose();
    super.dispose();
  }

  /// Pull back far enough to hold the whole block, and lift the pivot to the
  /// middle of the buildings rather than to the tarmac.
  void _frame() {
    final n = _nodes;
    final radius = n?.layoutRadiusM ?? 60;
    _pivotZM = math.max(6.0, n?.stats.heightM ?? 12) * 0.45;
    _distanceM = radius / math.tan(_fovY * 0.5) * 0.95;
  }

  /// Down the street at eye height — the view a person standing on the
  /// pavement gets, and the only one that settles whether the scale is right.
  void _eyeLevel() => setState(() {
        _elevation = 0.02;
        _pivotZM = 1.7;
        _distanceM = math.max(30, _lotWidthM * _lots * 0.5);
        _azimuth = 1.62;
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.panel,
        foregroundColor: AppTheme.text,
        title: const Text('BUILDING STUDIO', style: AppTheme.heading),
        actions: [
          IconButton(
            tooltip: 'Street level',
            icon: const Icon(Icons.directions_walk),
            onPressed: _eyeLevel,
          ),
          IconButton(
            tooltip: 'Frame the block',
            icon: const Icon(Icons.center_focus_strong),
            onPressed: () => setState(_frame),
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(child: _viewport()),
          SizedBox(width: 320, child: _controls()),
        ],
      ),
    );
  }

  // ---- Viewport ----------------------------------------------------------

  Widget _viewport() => FutureBuilder<void>(
        future: _staticInit,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Scene resources failed to load:\n'
                    '${snapshot.error}',
                    style: AppTheme.dim, textAlign: TextAlign.center),
              ),
            );
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const ColoredBox(
              color: Color(0xFF0B0E12),
              child: Center(
                  child: CircularProgressIndicator(color: AppTheme.accent2)),
            );
          }
          final scene = _scene ??= fs.Scene();
          final nodes = _nodes ??= BuildingPreviewNodes(scene);
          return _sceneStack(scene, nodes);
        },
      );

  Widget _sceneStack(fs.Scene scene, BuildingPreviewNodes nodes) {
    // The facade and glazing tiles bake off the main isolate. Kick the load
    // and let the first frames draw against the engine's white placeholder;
    // when it lands, drop the materials so they rebind — the materials cache
    // their handle at first use, so without the reset the whole studio would
    // stay untextured for the session.
    if (!CityTextures.ready) {
      unawaited(CityTextures.load().then((_) {
        if (mounted) setState(() {});
      }));
      _texturesPending = true;
    } else if (_texturesPending) {
      _texturesPending = false;
      CityMaterials.reset();
      nodes.invalidate();
    }

    _syncSun(scene);
    nodes.update(_request);

    return Stack(children: [
      Positioned.fill(
        child: GestureDetector(
          onScaleStart: (_) => _dragBase = (_azimuth, _elevation),
          onScaleUpdate: (d) => setState(() {
            if (d.pointerCount > 1) {
              _distanceM =
                  (_distanceM / d.scale.clamp(0.2, 5.0)).clamp(3.0, 3000.0);
            } else {
              _azimuth = _dragBase.$1 - d.focalPointDelta.dx * 0.008;
              _elevation = (_dragBase.$2 + d.focalPointDelta.dy * 0.006)
                  .clamp(-0.2, 1.45);
              _dragBase = (_azimuth, _elevation);
            }
          }),
          child: Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) {
                setState(() => _distanceM =
                    (_distanceM * (1 + e.scrollDelta.dy * 0.0016))
                        .clamp(3.0, 3000.0));
              }
            },
            // CHIRALITY: the world-to-scene mapping is a mirror that
            // SceneRenderView corrects by flipping the finished image. The
            // studio flips too, so what you tune here is what the sim shows.
            child: Transform.flip(
              flipX: true,
              child: fs.SceneView(scene, camera: _camera()),
            ),
          ),
        ),
      ),
      Positioned(left: 12, top: 12, child: _statsPanel(nodes.stats)),
    ]);
  }

  fs.PerspectiveCamera _camera() {
    final ce = math.cos(_elevation), se = math.sin(_elevation);
    final dir =
        vm.Vector3(math.cos(_azimuth) * ce, math.sin(_azimuth) * ce, se);
    final target = vm.Vector3(0, 0, lengthToScene(_pivotZM));
    return fs.PerspectiveCamera(
      fovRadiansY: _fovY,
      position: target + dir * lengthToScene(_distanceM),
      target: target,
      up: vm.Vector3(0, 0, 1),
      // A building is tens of metres and the scene unit is a kilometre, so the
      // stock 0.1 near plane would sit 100 m in front of the camera and clip
      // the entire subject away.
      fovNear: lengthToScene(math.max(_distanceM * 0.01, 0.05)),
      fovFar: lengthToScene(_distanceM * 12 + 400),
    );
  }

  void _syncSun(fs.Scene scene) {
    scene.environmentIntensity = 0.22;
    // Light TRAVELS along this vector, so a sun in the north-west shines
    // toward the south-east. Low, because the whole point of modelling piers
    // and cornices is the shadows they throw, and an overhead sun throws none.
    final dir = vm.Vector3(
      -math.cos(_sunAzimuth),
      -math.sin(_sunAzimuth),
      -0.42,
    )..normalize();
    final light = scene.directionalLight;
    if (light == null) {
      scene.directionalLight =
          fs.DirectionalLight(direction: dir, intensity: 2.4);
    } else {
      light.direction = dir;
    }
  }

  // ---- HUD ---------------------------------------------------------------

  Widget _statsPanel(BuildingPreviewStats s) {
    final mono = AppTheme.mono.copyWith(fontSize: 11, color: AppTheme.text);
    String row(String k, String v) => '${k.padRight(11)}$v';
    // The two numbers that decide whether this is a street or a business park.
    final wall = s.frontGapM.abs() < 1.0 && s.sideGapM < 0.5;
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
          Text(_style.label,
              style:
                  AppTheme.mono.copyWith(fontSize: 12, color: AppTheme.accent2)),
          const SizedBox(height: 4),
          Text(row('building', '${_spec.label} · ${s.floors} fl · '
              '${s.heightM.toStringAsFixed(1)} m'), style: mono),
          Text(
              row(
                  'footprint',
                  '${s.footprintW.toStringAsFixed(1)} x '
                      '${s.footprintD.toStringAsFixed(1)} m  '
                      '${s.floorAreaM2.round()} m2'),
              style: mono),
          Text(row('parking', '${s.parkingSpaces} spaces'), style: mono),
          Text(
            row(
                'frontage',
                '${s.frontGapM.toStringAsFixed(1)} m to curb · '
                    '${s.sideGapM.toStringAsFixed(1)} m between'),
            style: mono.copyWith(
                color: wall ? AppTheme.accent2 : AppTheme.warn),
          ),
          Text(
              row('cost', '${s.triangles} tris  ${s.drawCalls} draws  '
                  '${s.buildMs.toStringAsFixed(1)} ms'),
              style: mono.copyWith(color: AppTheme.textDim)),
          Text(row('camera', '${_distanceM.toStringAsFixed(0)} m'),
              style: mono.copyWith(color: AppTheme.textDim)),
        ],
      ),
    );
  }

  // ---- Controls ----------------------------------------------------------

  // Material, NOT a coloured Container: a ListTile paints its background and
  // ink on the nearest Material ancestor, and a plain ColoredBox in between
  // hides both — which Flutter reports as a layout assertion rather than as a
  // wrong colour. Third time this has bitten a panel in this app.
  Widget _controls() => Material(
        color: AppTheme.panel,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
          children: [
            const Text('KIT', style: AppTheme.heading),
            Text(_style.note, style: AppTheme.dim.copyWith(fontSize: 11)),
            const SizedBox(height: 6),
            _dropdown<String>(
              'Style',
              _style.id,
              [for (final s in ArchitectureStyle.kits) s.id],
              (id) => ArchitectureStyle.byId(id).label,
              (v) => setState(() => _style = ArchitectureStyle.byId(v)),
            ),
            const SizedBox(height: 12),
            const Text('ZONE', style: AppTheme.heading),
            Text('The spec is what sizes the building: how many it houses or '
                'employs, and how much plant it holds.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            const SizedBox(height: 6),
            _dropdown<String>(
              'Use',
              _zone,
              const ['residential', 'commercial', 'industrial'],
              (v) => v,
              (v) => setState(() => _zone = v),
            ),
            const SizedBox(height: 8),
            _dropdown<Density>(
              'Density',
              _density,
              Density.values,
              (d) => d.name,
              (v) => setState(() => _density = v),
            ),
            const SizedBox(height: 12),
            const Text('LOT', style: AppTheme.heading),
            Text('The parcel the colony would hand the generator. Frontage is '
                'the dimension that decides everything else.',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            _slider('Frontage', _lotWidthM, 8, 70,
                'Lot width along the street.',
                (v) => setState(() => _lotWidthM = v), unit: 'm'),
            _slider('Depth', _lotDepthM, 12, 90,
                'How far the lot runs back from the curb.',
                (v) => setState(() => _lotDepthM = v), unit: 'm'),
            _slider('Lots', _lots, 1, 9,
                'A row, not a hero shot: whether the frontages line up is the '
                'whole question.',
                (v) => setState(() => _lots = v), divisions: 8),
            const SizedBox(height: 12),
            const Text('DETAIL', style: AppTheme.heading),
            _dropdown<BuildingDetail>(
              'Tier',
              _detail,
              BuildingDetail.values,
              (d) => d.name,
              (v) => setState(() => _detail = v),
            ),
            const SizedBox(height: 4),
            _slider('Seed', _seed.toDouble(), 1, 40,
                'Same inputs, different building.',
                (v) => setState(() => _seed = v.round()), divisions: 39),
            _slider('Sun', _sunAzimuth, 0, math.pi * 2,
                'Low sun. The piers and the cornice only exist as shadows.',
                (v) => setState(() => _sunAzimuth = v)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _varySeeds,
              activeThumbColor: AppTheme.accent2,
              title: const Text('Vary along the row', style: AppTheme.body),
              subtitle: Text('Off repeats one design, which is how you inspect '
                  'a single building from every side.',
                  style: AppTheme.dim.copyWith(fontSize: 11)),
              onChanged: (v) => setState(() => _varySeeds = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _corners,
              activeThumbColor: AppTheme.accent2,
              title: const Text('Corner lots at the ends', style: AppTheme.body),
              subtitle: Text('Two public faces, no blank flank, and a storey '
                  'more than its neighbours — the building on a block worth '
                  'looking at.',
                  style: AppTheme.dim.copyWith(fontSize: 11)),
              onChanged: (v) => setState(() => _corners = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _showLots,
              activeThumbColor: AppTheme.accent2,
              title: const Text('Property lines', style: AppTheme.body),
              subtitle: Text('Where the lot ends. Without it you cannot see '
                  'what the building is doing with its plot.',
                  style: AppTheme.dim.copyWith(fontSize: 11)),
              onChanged: (v) => setState(() => _showLots = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _showRig,
              activeThumbColor: AppTheme.accent2,
              title: const Text('Scale reference', style: AppTheme.body),
              subtitle: Text('Mast, person, car, 3 m storey, 3.5 m lane.',
                  style: AppTheme.dim.copyWith(fontSize: 11)),
              onChanged: (v) => setState(() => _showRig = v),
            ),
          ],
        ),
      );

  Widget _dropdown<T>(String label, T value, List<T> options,
      String Function(T) name, void Function(T) onChanged) {
    return Row(
      children: [
        SizedBox(width: 78, child: Text(label, style: AppTheme.body)),
        Expanded(
          child: DropdownButton<T>(
            value: value,
            isExpanded: true,
            dropdownColor: AppTheme.panel,
            style: AppTheme.body,
            underline: Container(height: 1, color: AppTheme.textDim),
            items: [
              for (final o in options)
                DropdownMenuItem(value: o, child: Text(name(o))),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ],
    );
  }

  Widget _slider(String label, double value, double min, double max,
      String hint, void Function(double) onChanged,
      {String unit = '', int? divisions}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: AppTheme.body),
            Text(
                '${value.toStringAsFixed(unit == 'm' ? 0 : 2)}'
                '${unit.isEmpty ? '' : ' $unit'}',
                style: AppTheme.mono
                    .copyWith(fontSize: 11, color: AppTheme.accent2)),
          ],
        ),
        Text(hint, style: AppTheme.dim.copyWith(fontSize: 11)),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2,
            activeTrackColor: AppTheme.accent2,
            thumbColor: AppTheme.accent2,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
