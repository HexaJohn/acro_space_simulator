// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// CITY BUILDER: found a colony and grow it, in the live 3D world.
///
/// The setup half of the mode. It picks a world, a site and the odds, hands
/// [CityStarterKit] the decision, and opens the running world on the colony it
/// gets back — so the thing being played is a real [CitySim] on real terrain,
/// ticked by the authoritative simulation, not a second model that looks like
/// one.
///
/// Distinct from the flat [NewCityScreen] / [CityBuilderScreen] pair, which is
/// the original 2D cell-grid game and stays as it is.
library;

import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_config.dart';
import '../../../domain/colony/city/city_starter_kit.dart';
import '../../../domain/planetary/planet_surface.dart';
import '../../../domain/universe/celestial_body.dart';
import '../../../domain/universe/real_solar_system.dart';
import '../../flutter_scene/render_backend.dart';
import '../simulation_view.dart';
import 'app_theme.dart';

/// New-colony setup for the 3D city-builder mode.
class CityGameSetupScreen extends StatefulWidget {
  const CityGameSetupScreen({super.key});

  @override
  State<CityGameSetupScreen> createState() => _CityGameSetupScreenState();
}

class _CityGameSetupScreenState extends State<CityGameSetupScreen> {
  late final List<CelestialBody> _bodies;
  late CelestialBody _body;
  Biome _biome = Biome.forest;
  CityStart _start = CityStart.standard;
  // A lakeside basin in the Southern Alps (Queenstown, NZ), chosen off the
  // baked DEM rather than off a map — and chosen for what RENDERS, which is
  // not the same as what is dramatic. Peaks 25 km out flatten into the far
  // field at every camera height worth playing at, so the site that gives a
  // sense of scale is the one whose ground rises CLOSE: +350 m by 4 km and
  // +708 m by 8 km, in every direction and with no cliff to fall off, over a
  // core two kilometres flat to within 93 m — enough to lay a town on.
  double _lat = -45.03;
  double _lon = 168.66;
  final _name = TextEditingController(text: 'New Colony');

  @override
  void initState() {
    super.initState();
    // Surfaces only. A gas giant has no ground to lay a road on, and the
    // floating/orbital colony styles the 2D builder offers have no plat model
    // behind them yet — offering them here would open a mode that cannot be
    // played.
    _bodies = RealSolarSystem.build()
        .all
        .where((b) => !b.isStar && !b.isGasGiant)
        .toList()
      ..sort((a, b) => b.solarFlux.compareTo(a.solarFlux));
    _body = _bodies.firstWhere((b) => b.id.value == 'earth',
        orElse: () => _bodies.first);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _found() {
    final colony = CityStarterKit.found(
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      config: CityConfig(
        bodyId: _body.id.value,
        biome: _biome,
        latitude: _lat,
        longitude: _lon,
      ),
      start: _start,
      id: 'city-${DateTime.now().millisecondsSinceEpoch}',
      name: _name.text.trim().isEmpty ? 'New Colony' : _name.text.trim(),
      agentTraffic: true,
    );
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => SimulationView(
        // The colony IS the scene: no demo orbiter, no injected craft. A ship
        // can still be flown in later; the mode does not start with one in the
        // way of the camera.
        injectedCity: colony,
        cityMode: true,
        spawnDemoOrbiter: false,
        initialBackend: RenderBackend.flutterScene,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AppTheme.scaffold(
      context: context,
      title: 'CITY BUILDER',
      accentColor: AppTheme.accent2,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: AppTheme.panelBox(border: AppTheme.accent2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('THE OPENING POSITION', style: AppTheme.heading),
                    const SizedBox(height: 6),
                    Text(
                        'You start with a spaceport, a crossroads and a budget. '
                        'Zone the lots along the streets, keep the power and the '
                        'mood up, and the population climbs — every milestone '
                        'pays a grant and opens more of the build palette.',
                        style: AppTheme.dim),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text('COLONY', style: AppTheme.heading),
              const SizedBox(height: 6),
              TextField(
                controller: _name,
                style: AppTheme.body,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: AppTheme.panelLight,
                  hintText: 'Colony name',
                  hintStyle: AppTheme.dim,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 14),
              const Text('WORLD', style: AppTheme.heading),
              const SizedBox(height: 6),
              _bodyPicker(),
              const SizedBox(height: 10),
              _biomePicker(),
              const SizedBox(height: 14),
              const Text('SITE', style: AppTheme.heading),
              const SizedBox(height: 2),
              Text('Where on the world the town stands. Latitude drives the '
                  'sun, and the sun drives solar power and crops.',
                  style: AppTheme.dim),
              _siteSlider('Latitude', _lat, -80, 80,
                  (v) => setState(() => _lat = v)),
              _siteSlider('Longitude', _lon, -180, 180,
                  (v) => setState(() => _lon = v)),
              const SizedBox(height: 14),
              const Text('DIFFICULTY', style: AppTheme.heading),
              const SizedBox(height: 6),
              for (final d in CityStart.values) _startCard(d),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _found,
                style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.accent2,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                icon: const Icon(Icons.location_city),
                label: const Text('FOUND THE COLONY'),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bodyPicker() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: AppTheme.panelBox(),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<CelestialBody>(
            isExpanded: true,
            dropdownColor: AppTheme.panel,
            value: _body,
            items: [
              for (final b in _bodies)
                DropdownMenuItem(
                  value: b,
                  child: Text(
                      '${b.name}   ·   ${b.solarFlux.toStringAsFixed(0)} W/m²'
                      '   ·   g ${(b.mu / (b.radius * b.radius)).toStringAsFixed(1)} m/s²',
                      style: AppTheme.body),
                ),
            ],
            onChanged: (b) => setState(() => _body = b ?? _body),
          ),
        ),
      );

  Widget _biomePicker() => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final b in Biome.values)
            InkWell(
              onTap: () => setState(() => _biome = b),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: _biome == b
                      ? AppTheme.accent.withValues(alpha: 0.18)
                      : AppTheme.panelLight,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: _biome == b
                          ? AppTheme.accent
                          : const Color(0xFF223247)),
                ),
                child: Text(b.name,
                    style: AppTheme.body.copyWith(
                        color:
                            _biome == b ? AppTheme.accent : AppTheme.textDim)),
              ),
            ),
        ],
      );

  Widget _siteSlider(String label, double value, double lo, double hi,
          ValueChanged<double> onCh) =>
      Row(children: [
        SizedBox(
            width: 82, child: Text(label, style: AppTheme.body)),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
                activeTrackColor: AppTheme.accent2,
                thumbColor: AppTheme.accent2,
                inactiveTrackColor: AppTheme.panelLight,
                trackHeight: 3),
            child: Slider(value: value, min: lo, max: hi, onChanged: onCh),
          ),
        ),
        SizedBox(
          width: 56,
          child: Text('${value.toStringAsFixed(0)}°',
              textAlign: TextAlign.right,
              style: AppTheme.mono.copyWith(color: AppTheme.accent)),
        ),
      ]);

  Widget _startCard(CityStart d) {
    final on = _start == d;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: () => setState(() => _start = d),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: on ? AppTheme.panelLight : AppTheme.panel,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: on ? AppTheme.accent2 : const Color(0xFF223247)),
          ),
          child: Row(children: [
            Icon(on ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 16, color: on ? AppTheme.accent2 : AppTheme.textDim),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.label,
                      style: AppTheme.body.copyWith(
                          fontWeight: FontWeight.bold,
                          color: on ? AppTheme.accent2 : AppTheme.text)),
                  Text(d.blurb, style: AppTheme.dim),
                ],
              ),
            ),
            Text(
                '§${d.funds.toStringAsFixed(0)}\n'
                '${d.ore.toStringAsFixed(0)} ore',
                textAlign: TextAlign.right,
                style: AppTheme.mono.copyWith(fontSize: 11)),
          ]),
        ),
      ),
    );
  }
}
