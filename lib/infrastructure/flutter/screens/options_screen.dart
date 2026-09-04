// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../flutter_scene/graphics_quality.dart';
import 'app_theme.dart';

/// App options: graphics, simulation, controls.
///
/// The GRAPHICS QUALITY block is live and persisted — it writes
/// [GraphicsQuality], which the cloud, atmosphere and reflection passes read
/// every frame, so dragging a slider changes the next frame. The rest of this
/// screen is still pure UI state (the live sim reads its own debug layers).
class OptionsScreen extends StatefulWidget {
  const OptionsScreen({super.key});

  @override
  State<OptionsScreen> createState() => _OptionsScreenState();
}

class _OptionsScreenState extends State<OptionsScreen> {
  // Graphics
  bool _skybox = true;
  bool _atmosphere = true;
  bool _planetTextures = true;
  double _meshDetail = 40;
  // Simulation
  double _maxWarp = 50;
  bool _infiniteFuel = false;
  bool _perspectiveDefault = true;
  // Controls
  double _orbitSensitivity = 0.5;
  bool _invertPitch = false;

  /// Whether the per-feature sliders are unfolded. Opens on its own when the
  /// stored settings are already custom, so a returning user can see what
  /// their overrides are without hunting for the disclosure.
  late bool _showOverrides = GraphicsQuality.isCustom;

  /// Persist the whole quality block. Fire-and-forget: losing a preference is
  /// cosmetic, and blocking the slider on a disk write would make it stutter.
  void _saveQuality() {
    unawaited(SharedPreferences.getInstance().then((p) {
      for (final e in GraphicsQuality.toPrefs().entries) {
        if (e.value == null) {
          p.remove(e.key);
        } else {
          p.setString(e.key, e.value!);
        }
      }
    }));
  }

  void _mutateQuality(VoidCallback change) {
    setState(change);
    _saveQuality();
  }

  @override
  Widget build(BuildContext context) {
    return AppTheme.scaffold(
      context: context,
      title: 'OPTIONS',
      accentColor: AppTheme.textDim,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('GRAPHICS QUALITY', [
            ..._qualityRows(),
            _toggle(
                'Terrain view culling (coarser ground behind the camera)',
                GraphicsQuality.terrainFrustumCull,
                (v) => _mutateQuality(
                    () => GraphicsQuality.terrainFrustumCull = v)),
          ]),
          _section('GRAPHICS', [
            _toggle('Skybox (Milky Way)', _skybox, (v) => setState(() => _skybox = v)),
            _toggle('Atmosphere scattering', _atmosphere,
                (v) => setState(() => _atmosphere = v)),
            _toggle('Planet surface textures', _planetTextures,
                (v) => setState(() => _planetTextures = v)),
            _slider('Sphere mesh detail', _meshDetail, 16, 64,
                (v) => setState(() => _meshDetail = v), suffix: 'cells'),
          ]),
          _section('SIMULATION', [
            _slider('Max time warp', _maxWarp, 1, 1000,
                (v) => setState(() => _maxWarp = v), suffix: '×'),
            _toggle('Perspective camera by default', _perspectiveDefault,
                (v) => setState(() => _perspectiveDefault = v)),
            _toggle('Infinite fuel (cheat)', _infiniteFuel,
                (v) => setState(() => _infiniteFuel = v)),
          ]),
          _section('CONTROLS', [
            _slider('Camera orbit sensitivity', _orbitSensitivity, 0.1, 2.0,
                (v) => setState(() => _orbitSensitivity = v)),
            _toggle('Invert pitch', _invertPitch,
                (v) => setState(() => _invertPitch = v)),
          ]),
          const SizedBox(height: 20),
          Center(
            child: Text('Graphics quality applies immediately. '
                'Other settings apply to new flight sessions.',
                style: AppTheme.dim, textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }

  // --- Graphics quality ----------------------------------------------------

  List<Widget> _qualityRows() {
    final custom = GraphicsQuality.isCustom;
    return [
      _qualitySlider(
        'Quality preset',
        GraphicsQuality.master,
        (v) => _mutateQuality(() => GraphicsQuality.setMaster(v)),
        valueLabel: custom ? 'CUSTOM' : GraphicsQuality.master.label,
        // The master is the one control someone on a weak GPU should have to
        // find, so it says what it is for rather than naming the passes.
        help: 'Lower settings march fewer, cheaper samples through clouds, '
            'sky and reflections — and Low swaps clouds to a flat textured '
            'shell with no raymarch at all. The biggest win on a low-end GPU.',
      ),
      const SizedBox(height: 4),
      InkWell(
        onTap: () => setState(() => _showOverrides = !_showOverrides),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(_showOverrides ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: AppTheme.textDim),
              const SizedBox(width: 6),
              Text('Per-feature overrides', style: AppTheme.body),
              const Spacer(),
              if (custom)
                TextButton(
                  onPressed: () =>
                      _mutateQuality(GraphicsQuality.resetOverrides),
                  child: Text('Follow preset',
                      style: AppTheme.body.copyWith(color: AppTheme.accent)),
                ),
            ],
          ),
        ),
      ),
      if (_showOverrides) ...[
        _qualitySlider(
          'Cloud quality',
          GraphicsQuality.cloudLevel,
          (v) => _mutateQuality(() => GraphicsQuality.cloudOverride = v),
          valueLabel: GraphicsQuality.cloudLevel.label,
          help: _cloudCostLine(),
          overridden: GraphicsQuality.cloudOverride != null &&
              GraphicsQuality.cloudOverride != GraphicsQuality.master,
        ),
        _qualitySlider(
          'Lighting quality',
          GraphicsQuality.lightingLevel,
          (v) => _mutateQuality(() => GraphicsQuality.lightingOverride = v),
          valueLabel: GraphicsQuality.lightingLevel.label,
          help: _lightingCostLine(),
          overridden: GraphicsQuality.lightingOverride != null &&
              GraphicsQuality.lightingOverride != GraphicsQuality.master,
        ),
      ],
    ];
  }

  /// The actual budget behind the preset. Worth showing: "Low" means
  /// nothing on its own, and the ratio against High is the number someone
  /// deciding whether to turn it down actually wants. The ratio comes from
  /// [CloudQuality.approxNoiseCost], not the sample counts — the technique
  /// and field-detail axes are where the big multipliers live.
  String _cloudCostLine() {
    final q = GraphicsQuality.clouds;
    final ratio = CloudQuality.high.approxNoiseCost / q.approxNoiseCost;
    final technique = switch (q.mode) {
      CloudRenderMode.flat => 'Textured shell — no raymarch',
      CloudRenderMode.reduced =>
        '${q.viewSampleCap} view x ${q.lightSamples} light samples · '
            'reduced noise field',
      CloudRenderMode.full =>
        '${q.viewSampleCap} view x ${q.lightSamples} light samples',
    };
    return '$technique${_ratioSuffix(ratio)}';
  }

  String _lightingCostLine() {
    final q = GraphicsQuality.lighting;
    final ratio = LightingQuality.high.worstCaseSamples / q.worstCaseSamples;
    return 'Sky ${q.atmoViewSamples} x ${q.atmoLightSamples} samples · '
        'reflection ${q.envBakeWidth}x${q.envBakeHeight}'
        '${_ratioSuffix(ratio)}';
  }

  static String _ratioSuffix(double ratio) {
    if (ratio > 1.05) return ' · ${ratio.toStringAsFixed(1)}x cheaper than High';
    if (ratio < 0.95) {
      return ' · ${(1 / ratio).toStringAsFixed(1)}x costlier than High';
    }
    return '';
  }

  /// A slider that snaps to the four rungs, labelled by name rather than by
  /// number — the positions are an enum, not a continuum.
  Widget _qualitySlider(
    String label,
    QualityLevel value,
    ValueChanged<QualityLevel> onChanged, {
    required String valueLabel,
    String? help,
    bool overridden = false,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(label, style: AppTheme.body)),
                if (overridden)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text('OVERRIDE',
                        style: AppTheme.mono
                            .copyWith(color: AppTheme.textDim, fontSize: 10)),
                  ),
                Text(valueLabel,
                    style: AppTheme.mono.copyWith(color: AppTheme.accent)),
              ],
            ),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: AppTheme.accent,
                thumbColor: AppTheme.accent,
                inactiveTrackColor: AppTheme.panelLight,
                trackHeight: 3,
              ),
              child: Slider(
                value: value.position,
                min: 0,
                max: (QualityLevel.values.length - 1).toDouble(),
                divisions: QualityLevel.values.length - 1,
                onChanged: (v) => onChanged(QualityLevel.fromPosition(v)),
              ),
            ),
            if (help != null)
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 2),
                child: Text(help, style: AppTheme.dim),
              ),
          ],
        ),
      );

  // --- Shared chrome -------------------------------------------------------

  Widget _section(String title, List<Widget> rows) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(14),
        decoration: AppTheme.panelBox(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AppTheme.heading),
            const SizedBox(height: 10),
            ...rows,
          ],
        ),
      );

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(child: Text(label, style: AppTheme.body)),
            Switch(
              value: value,
              activeThumbColor: AppTheme.accent,
              onChanged: onChanged,
            ),
          ],
        ),
      );

  Widget _slider(String label, double value, double min, double max,
          ValueChanged<double> onChanged,
          {String suffix = ''}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(label, style: AppTheme.body)),
                Text('${value.toStringAsFixed(value < 10 ? 1 : 0)} $suffix',
                    style: AppTheme.mono.copyWith(color: AppTheme.accent)),
              ],
            ),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: AppTheme.accent,
                thumbColor: AppTheme.accent,
                inactiveTrackColor: AppTheme.panelLight,
                trackHeight: 3,
              ),
              child: Slider(
                  value: value, min: min, max: max, onChanged: onChanged),
            ),
          ],
        ),
      );
}
