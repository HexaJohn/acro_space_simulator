import 'package:flutter/material.dart';

import 'app_theme.dart';

/// App options: graphics, simulation, controls. Pure UI state for now (the live
/// sim reads its own debug layers) — a place to surface every tunable.
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

  @override
  Widget build(BuildContext context) {
    return AppTheme.scaffold(
      context: context,
      title: 'OPTIONS',
      accentColor: AppTheme.textDim,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
            child: Text('Settings apply to new flight sessions.',
                style: AppTheme.dim),
          ),
        ],
      ),
    );
  }

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
