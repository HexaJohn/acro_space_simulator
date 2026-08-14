// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../domain/shared/vector3.dart';
import '../../flutter_scene/cloud_nodes.dart';
import '../../flutter_scene/coord_convert.dart';
import '../../flutter_scene/sphere_geometry_util.dart';
import 'app_theme.dart';

/// A planet-scale tuning view for the volumetric cloud decks — the cloud
/// sibling of the scatter lab.
///
/// Every [CloudStyle] knob is a judgement call that cannot be made from the
/// shader source: whether Venus reads as a featureless sulfur sea, whether
/// Earth's cyclone arms survive the coverage threshold, whether the wind
/// morph looks like weather or like soup. Answering those by flying the sim
/// to each planet per tweak would make tuning impossibly slow.
///
/// The view draws through the real shell rig ([CloudPreviewNodes] drives the
/// same materials and uniform packing the sim uses) over a bare grey sphere,
/// with a draggable sun. The knobs edit [CloudNodes.styles] IN PLACE, so a
/// flight scene opened afterwards shows exactly what was tuned here; COPY
/// exports the current numbers as a `CloudStyle(...)` literal ready to paste
/// into the styles table as the new default.
class CloudscapeScreen extends StatefulWidget {
  const CloudscapeScreen({super.key});

  @override
  State<CloudscapeScreen> createState() => _CloudscapeScreenState();
}

class _CloudscapeScreenState extends State<CloudscapeScreen>
    with SingleTickerProviderStateMixin {
  /// Base flutter_scene resources. Static: shared with every other view in
  /// the app, and geometry CONSTRUCTION (not just drawing) throws before it
  /// lands.
  static final Future<void> _staticInit = fs.Scene.initializeStaticResources();

  /// Preview radii (metres) for the bodies carrying a cloud style. Any body
  /// id added to [CloudNodes.styles] without an entry here previews on the
  /// fallback radius — the deck still tunes fine, only the shell-to-planet
  /// proportion is approximate.
  static const Map<String, double> _radiusM = {
    'earth': 6371e3,
    'venus': 6052e3,
    'titan': 2575e3,
    'mars': 3390e3,
  };
  static const double _fallbackRadiusM = 6000e3;

  static const double _fovY = 50 * math.pi / 180;

  fs.Scene? _scene;
  CloudPreviewNodes? _clouds;
  fs.Node? _planet;
  String? _error;

  // Subject.
  String _body = 'earth';

  /// App-start snapshot of every style, for RESET — captured before any
  /// slider moves so a wrecked art pass can always get back to the shipped
  /// numbers (even though the knobs edit the live styles map in place).
  late final Map<String, Map<String, Object?>> _initial = {
    for (final e in CloudNodes.styles.entries) e.key: e.value.toJson(),
  };

  // Camera (turntable about the planet centre).
  double _azimuth = 0.9;
  double _elevation = 0.28;
  double _distanceM = 6371e3 * 3.2;
  (double, double) _dragBase = (0, 0);

  // Sun.
  double _sunAzimuth = 0.6;
  double _sunElevation = 0.15;

  // Cloud-time animation: the shader's time uniform advances at [_warp]
  // sim-seconds per wall-second, mirroring how the sim's time-warp drives
  // the morph. 0 freezes the deck for still judgement.
  late final Ticker _ticker;
  double _warp = 100;
  double _cloudTimeS = 0;
  Duration _lastTick = Duration.zero;

  double get _radiusOf => _radiusM[_body] ?? _fallbackRadiusM;
  CloudStyle get _style =>
      CloudNodes.styles.putIfAbsent(_body, CloudStyle.new);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _staticInit.then((_) async {
      await CloudNodes.loadShader();
      if (!mounted) return;
      final scene = fs.Scene();
      // The clouds light themselves from their own sun uniform; the low
      // image-based ambient here only keeps the grey ball's night side from
      // washing out to flat white.
      scene.environmentIntensity = 0.05;
      final planet = fs.Node(
        mesh: fs.Mesh(
          uvSphereZUp(segments: 96, rings: 48),
          fs.PhysicallyBasedMaterial()
            ..baseColorFactor = vm.Vector4(0.42, 0.44, 0.47, 1.0)
            ..metallicFactor = 0.0
            ..roughnessFactor = 1.0,
        ),
      );
      scene.add(planet);
      setState(() {
        _scene = scene;
        _planet = planet;
        _clouds = CloudPreviewNodes(scene);
        _frameSubject();
      });
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clouds?.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (_warp <= 0 || _scene == null) return;
    setState(() => _cloudTimeS += dt * _warp);
  }

  void _frameSubject() {
    _distanceM = _radiusOf * 3.2;
  }

  void _apply(VoidCallback change) => setState(change);

  /// The current style as a `CloudStyle(...)` literal, ready to paste into
  /// [CloudNodes.styles] as the body's new default.
  String _asDart() {
    final s = _style;
    String n(double v) {
      var t = v.toStringAsFixed(4);
      t = t.replaceFirst(RegExp(r'0+$'), '');
      if (t.endsWith('.')) t = '${t}0';
      return t;
    }

    return 'CloudStyle(\n'
        '  baseM: ${s.baseM.round()},\n'
        '  topM: ${s.topM.round()},\n'
        '  coverage: ${n(s.coverage)},\n'
        '  density: ${n(s.density)},\n'
        '  wind: ${n(s.wind)},\n'
        '  detail: ${n(s.detail)},\n'
        '  ambient: ${n(s.ambient)},\n'
        '  intensity: ${n(s.intensity)},\n'
        '  tintArgb: 0x${s.tintArgb.toRadixString(16).toUpperCase()},\n'
        '  freq: ${n(s.freq)},\n'
        ')';
  }

  void _copyAsDart() {
    Clipboard.setData(ClipboardData(text: _asDart()));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$_body CloudStyle copied as Dart',
          style: AppTheme.mono.copyWith(fontSize: 12)),
      duration: const Duration(seconds: 2),
    ));
  }

  void _resetBody() {
    final snap = _initial[_body];
    if (snap == null) return;
    _apply(() => _applyJson(_style, snap));
  }

  static void _applyJson(CloudStyle s, Map<String, Object?> j) {
    double d(String k) => (j[k]! as num).toDouble();
    s
      ..enabled = j['enabled']! as bool
      ..baseM = d('baseKm') * 1000
      ..topM = d('topKm') * 1000
      ..coverage = d('coverage')
      ..density = d('density')
      ..wind = d('wind')
      ..detail = d('detail')
      ..ambient = d('ambient')
      ..intensity = d('intensity')
      ..tintArgb = 0xFF000000 | int.parse(j['tint']! as String, radix: 16)
      ..freq = d('freq');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.panel,
        foregroundColor: AppTheme.text,
        title: const Text('CLOUDSCAPE', style: AppTheme.heading),
        actions: [
          IconButton(
            tooltip: 'Frame planet',
            icon: const Icon(Icons.center_focus_strong),
            onPressed: () => _apply(_frameSubject),
          ),
          IconButton(
            tooltip: 'Copy style as Dart',
            icon: const Icon(Icons.copy_all),
            onPressed: _copyAsDart,
          ),
          IconButton(
            tooltip: 'Reset this body to app-start values',
            icon: const Icon(Icons.restart_alt),
            onPressed: _resetBody,
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
          child: Text('Cloudscape unavailable\n\n$error',
              textAlign: TextAlign.center, style: AppTheme.dim),
        ),
      );
    }
    final scene = _scene;
    final clouds = _clouds;
    if (scene == null || clouds == null) {
      return const ColoredBox(
        color: Color(0xFF0B0E12),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final radiusM = _radiusOf;
    final toSun = _toSun();
    _syncSun(scene, toSun);
    _planet!.localTransform = vm.Matrix4.compose(
      vm.Vector3.zero(),
      vm.Quaternion.identity(),
      vm.Vector3.all(lengthToScene(radiusM)),
    );
    final camera = _camera();
    clouds.update(
      style: _style,
      planetRadiusM: radiusM,
      timeS: _cloudTimeS,
      toSun: Vector3(toSun.x, toSun.y, toSun.z),
      cameraEyeScene: camera.position,
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onScaleStart: (_) => _dragBase = (_azimuth, _elevation),
            onScaleUpdate: (d) => _apply(() {
              if (d.pointerCount > 1) {
                _distanceM = (_distanceM / d.scale.clamp(0.2, 5.0))
                    .clamp(_radiusOf * 1.02, _radiusOf * 80);
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
                          .clamp(_radiusOf * 1.02, _radiusOf * 80));
                }
              },
              // CHIRALITY: the app's world-to-scene mapping is a mirror that
              // SceneRenderView corrects by flipping the finished image. The
              // editor flips too, so the swirl handedness tuned here is the
              // handedness the sim shows.
              child: Transform.flip(
                flipX: true,
                child: fs.SceneView(scene, camera: camera),
              ),
            ),
          ),
        ),
        Positioned(left: 12, top: 12, child: _statsPanel()),
      ],
    );
  }

  vm.Vector3 _toSun() {
    final ce = math.cos(_sunElevation);
    return vm.Vector3(
      math.cos(_sunAzimuth) * ce,
      math.sin(_sunAzimuth) * ce,
      math.sin(_sunElevation),
    );
  }

  void _syncSun(fs.Scene scene, vm.Vector3 toSun) {
    // Light TRAVELS along this vector (see scene_sync's note): the grey ball
    // is lit from the same direction the cloud uniform calls "toward the
    // sun", so the terminators agree.
    final dir = -toSun;
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

  fs.PerspectiveCamera _camera() {
    final ce = math.cos(_elevation), se = math.sin(_elevation);
    final dir = vm.Vector3(
      math.cos(_azimuth) * ce,
      math.sin(_azimuth) * ce,
      se,
    );
    return fs.PerspectiveCamera(
      fovRadiansY: _fovY,
      position: dir * lengthToScene(_distanceM),
      target: vm.Vector3.zero(),
      // The scene keeps the domain's Z-up frame (see coord_convert).
      up: vm.Vector3(0, 0, 1),
      // Near tracks the gap down to the cloud tops so skimming the deck
      // doesn't clip it away, and depth precision follows the zoom.
      fovNear: lengthToScene(
          math.max((_distanceM - _radiusOf * 1.05) * 0.2, 5e3)),
      fovFar: lengthToScene(_distanceM * 4 + _radiusOf * 4),
    );
  }

  // ---- HUD ----------------------------------------------------------------

  Widget _statsPanel() {
    final mono = AppTheme.mono.copyWith(fontSize: 11, color: AppTheme.text);
    String row(String k, String v) => '${k.padRight(10)}$v';
    final s = _style;
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
          Text(_body.toUpperCase(),
              style:
                  AppTheme.mono.copyWith(fontSize: 12, color: AppTheme.accent2)),
          const SizedBox(height: 4),
          Text(row('radius', '${(_radiusOf / 1000).round()} km'), style: mono),
          Text(
              row(
                  'deck',
                  '${(s.baseM / 1000).toStringAsFixed(1)}-'
                      '${(s.topM / 1000).toStringAsFixed(1)} km'),
              style: mono),
          Text(row('time', '${(_cloudTimeS / 3600).toStringAsFixed(1)} h  '
              '(x${_warp.round()})'), style: mono),
          Text(row('camera', '${(_distanceM / 1000).round()} km'),
              style: mono.copyWith(color: AppTheme.textDim)),
        ],
      ),
    );
  }

  // ---- Controls -----------------------------------------------------------

  Widget _controls() {
    final s = _style;
    // Material, not a coloured Container: ListTile paints its ink splashes
    // onto the nearest Material ancestor, and a plain ColoredBox in between
    // hides them (Flutter asserts loudly about it every frame).
    return Material(
      color: AppTheme.panel,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _sectionLabel('BODY'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final id in CloudNodes.styles.keys)
                _chip(
                  id.toUpperCase(),
                  selected: _body == id,
                  onTap: () => _apply(() {
                    _body = id;
                    _frameSubject();
                  }),
                ),
            ],
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('Deck enabled',
                style: AppTheme.mono.copyWith(fontSize: 12)),
            value: s.enabled,
            activeThumbColor: AppTheme.accent2,
            onChanged: (v) => _apply(() => s.enabled = v),
          ),
          const SizedBox(height: 8),
          _sectionLabel('SHELL'),
          _knob('base', s.baseM / 1000, 0, 60, unit: 'km', decimals: 1,
              (v) {
            s.baseM = v * 1000;
            if (s.topM < s.baseM + 500) s.topM = s.baseM + 500;
          }),
          _knob('top', s.topM / 1000, 0.5, 90, unit: 'km', decimals: 1,
              (v) {
            s.topM = v * 1000;
            if (s.baseM > s.topM - 500) s.baseM = math.max(0, s.topM - 500);
          }),
          const SizedBox(height: 8),
          _sectionLabel('FIELD'),
          _knob('coverage', s.coverage, 0, 1, decimals: 2,
              (v) => s.coverage = v),
          _knob('density', s.density, 0, 40, decimals: 1,
              (v) => s.density = v),
          _knob('detail', s.detail, 0, 1, decimals: 2, (v) => s.detail = v),
          _knob('freq', s.freq, 2, 30, decimals: 1, (v) => s.freq = v),
          // Log scale: Titan crawls at 0.0015 while Earth churns at 0.015 —
          // a linear slider wastes its whole travel on the top decade.
          _knob('wind', _log10(s.wind.clamp(1e-4, 0.1)), -4, -1, decimals: 4,
              display: s.wind, (v) => s.wind = math.pow(10, v).toDouble()),
          const SizedBox(height: 8),
          _sectionLabel('LIGHT'),
          _knob('intensity', s.intensity, 0, 40, decimals: 1,
              (v) => s.intensity = v),
          _knob('ambient', s.ambient, 0, 0.5, decimals: 3,
              (v) => s.ambient = v),
          _sectionLabel('TINT'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (label, argb) in const [
                ('white', 0xFFF2F5FF),
                ('pure', 0xFFFFFFFF),
                ('sulfur', 0xFFE8D8B0),
                ('haze', 0xFFD8A860),
                ('dust', 0xFFE8D0C0),
                ('storm', 0xFFB8C0D0),
              ])
                _swatch(label, argb, s),
            ],
          ),
          const SizedBox(height: 12),
          _sectionLabel('SUN'),
          _knob('azimuth', _sunAzimuth, 0, 2 * math.pi, decimals: 2,
              (v) => _sunAzimuth = v),
          _knob('elevation', _sunElevation, -1.2, 1.2, decimals: 2,
              (v) => _sunElevation = v),
          const SizedBox(height: 8),
          _sectionLabel('TIME WARP'),
          Wrap(
            spacing: 6,
            children: [
              for (final w in const [0.0, 1.0, 10.0, 100.0, 1000.0, 10000.0])
                _chip(
                  w == 0 ? 'PAUSE' : 'x${w.round()}',
                  selected: _warp == w,
                  onTap: () => _apply(() => _warp = w),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Drag to orbit  ·  scroll or pinch to zoom\n'
            'Knobs edit the LIVE style table — the sim shows this deck.\n'
            'COPY exports the numbers for cloud_nodes.dart.',
            style: AppTheme.dim.copyWith(fontSize: 10),
          ),
        ],
      ),
    );
  }

  static double _log10(double v) => math.log(v) / math.ln10;

  /// One labelled slider row. [display] overrides the shown number when the
  /// slider position is a transform of the real value (the log wind knob).
  Widget _knob(
    String label,
    double value,
    double min,
    double max,
    void Function(double) set, {
    String unit = '',
    int decimals = 2,
    double? display,
  }) {
    final shown = display ?? value;
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(label, style: AppTheme.mono.copyWith(fontSize: 11)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            activeColor: AppTheme.accent2,
            onChanged: (v) => _apply(() => set(v)),
          ),
        ),
        SizedBox(
          width: 58,
          child: Text(
            '${shown.toStringAsFixed(decimals)}$unit',
            textAlign: TextAlign.right,
            style: AppTheme.mono
                .copyWith(fontSize: 10, color: AppTheme.textDim),
          ),
        ),
      ],
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Text(text,
            style:
                AppTheme.mono.copyWith(fontSize: 10, color: AppTheme.textDim)),
      );

  Widget _swatch(String label, int argb, CloudStyle s) {
    final selected = s.tintArgb == argb;
    return InkWell(
      borderRadius: BorderRadius.circular(5),
      onTap: () => _apply(() => s.tintArgb = argb),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
              color: selected ? AppTheme.accent2 : AppTheme.textDim,
              width: selected ? 1.6 : 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: Color(argb),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 6),
            Text(label,
                style: AppTheme.mono.copyWith(
                    fontSize: 11,
                    color: selected ? AppTheme.accent2 : AppTheme.textDim)),
          ],
        ),
      ),
    );
  }

  Widget _chip(
    String label, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colour = selected ? AppTheme.accent2 : AppTheme.textDim;
    return Material(
      color: selected
          ? AppTheme.accent2.withValues(alpha: 0.16)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(5),
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: onTap,
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
    );
  }
}
