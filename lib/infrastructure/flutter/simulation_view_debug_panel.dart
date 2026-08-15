// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The debug/cheat panel and the crash notice, lifted out of the flight view.
//
// A `part` rather than a separate class: a class body cannot span files, but an
// extension in the same library can, and it keeps every private field of the
// state reachable without threading sixty of them through a constructor. The
// split is about making the file navigable now; promoting these into a real
// widget with an explicit interface is a later, riskier step that wants test
// coverage first.
part of 'simulation_view.dart';

extension SimulationViewDebugPanel on _SimulationViewState {
  /// Modal "vessel lost" menu shown when a craft is destroyed. Fills the screen
  /// with a scrim so the sim is clearly interrupted; a single button dismisses.
  Widget _crashMenu(({String title, String detail}) notice) {
    return Positioned.fill(
      child: Container(
        color: const Color(0xCC000000),
        alignment: Alignment.center,
        child: Container(
          width: 360,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1014),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFFF6B6B), width: 1.5),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.warning_amber_rounded, color: Color(0xFFFF6B6B), size: 26),
                  SizedBox(width: 8),
                  Text(
                    'VESSEL LOST',
                    style: TextStyle(
                      color: Color(0xFFFF6B6B),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                notice.title,
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(notice.detail, style: const TextStyle(color: Color(0xFFC9B8BC), fontSize: 13, height: 1.35)),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF6B6B),
                    foregroundColor: const Color(0xFF1A0A0A),
                  ),
                  onPressed: () => rebuild(() => _crashNotice = null),
                  child: const Text('DISMISS'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Debug panel: a checkbox per draw layer so each pass can be isolated.
  /// A debug-cheat checkbox row: flips [value] via [set], then rebuilds the tick
  /// so the new flag takes effect immediately.
  Widget _cheatRow(String label, bool value, void Function(bool) set) => InkWell(
    onTap: () => rebuild(() {
      set(!value);
      _buildAdvance();
    }),
    child: Row(
      children: [
        Checkbox(
          value: value,
          onChanged: (v) => rebuild(() {
            set(v ?? false);
            _buildAdvance();
          }),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        Expanded(
          child: Text(label,
              style: const TextStyle(color: Color(0xFFB9C9DC), fontSize: 12)),
        ),
      ],
    ),
  );

  /// Metres with an engineering suffix, for the depth-plane sliders.
  static String _engM(double v) => v >= 1e9
      ? '${(v / 1e9).toStringAsFixed(1)} Gm'
      : v >= 1e6
          ? '${(v / 1e6).toStringAsFixed(1)} Mm'
          : v >= 1e3
              ? '${(v / 1e3).toStringAsFixed(1)} km'
              : '${v.toStringAsFixed(1)} m';

  /// Compact log10-scale slider spanning 10^[minExp]..10^[maxExp] metres.
  Widget _logSlider({
    required double value,
    required double minExp,
    required double maxExp,
    required ValueChanged<double> onChanged,
  }) {
    final exp = (math.log(value) / math.ln10).clamp(minExp, maxExp).toDouble();
    return SizedBox(
      height: 26,
      child: SliderTheme(
        data: SliderThemeData(
          trackHeight: 2,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
          activeTrackColor: const Color(0xFF7FB0E0),
          inactiveTrackColor: const Color(0x337FB0E0),
          thumbColor: const Color(0xFF7FB0E0),
        ),
        child: Slider(
          value: exp,
          min: minExp,
          max: maxExp,
          onChanged: (e) => onChanged(math.pow(10.0, e).toDouble()),
        ),
      ),
    );
  }

  Widget _debugPanel() {
    final rows = <(String, bool, DebugLayers Function(bool))>[
      ('Skybox', _layers.skybox, (v) => _layers.copyWith(skybox: v)),
      ('Orbit rails', _layers.orbitRails, (v) => _layers.copyWith(orbitRails: v)),
      ('Planet texture', _layers.planetTexture, (v) => _layers.copyWith(planetTexture: v)),
      ('Sphere shadow', _layers.sphereShadow, (v) => _layers.copyWith(sphereShadow: v)),
      // Drives BOTH renderers: the software painter's halo layer and the
      // 3D backend's raymarched shells.
      ('Atmo halo', _layers.atmoHalo, (v) {
        AtmosphereNodes.hidden = !v;
        return _layers.copyWith(atmoHalo: v);
      }),
      // 3D backend only: raymarched volumetric cloud shells. Static flag
      // (no software-renderer analogue), so leave _layers untouched.
      ('Clouds', !CloudNodes.hidden, (v) {
        CloudNodes.hidden = !v;
        return _layers;
      }),
      ('Atmo overlay', _layers.atmoOverlay, (v) => _layers.copyWith(atmoOverlay: v)),
      ('Nav-ball', _layers.navBall, (v) => _layers.copyWith(navBall: v)),
      ('Exaggerate star', _layers.exaggerateStar, (v) => _layers.copyWith(exaggerateStar: v)),
      ('Exaggerate atmo', _layers.exaggerateAtmosphere, (v) => _layers.copyWith(exaggerateAtmosphere: v)),
      ('Show SOIs', _layers.showSoi, (v) => _layers.copyWith(showSoi: v)),
      ('Cull distant', _layers.cullDistant, (v) => _layers.copyWith(cullDistant: v)),
      ('Infinite fuel', _layers.infiniteFuel, (v) => _layers.copyWith(infiniteFuel: v)),
      // 3D backend only: overlay the reflection-capture equirect (what the
      // craft's IBL reflects). Static flag, so leave _layers untouched.
      ('Env reflection', PlanetEnvironmentBaker.showDebug, (v) {
        PlanetEnvironmentBaker.showDebug = v;
        return _layers;
      }),
      // 3D backend only: per-craft origin + 1-metre axis ruler (X red, Y
      // green, Z blue = nose). Static flag, so leave _layers untouched.
      ('Axis gizmo', VesselNodes.showAxes, (v) {
        VesselNodes.showAxes = v;
        return _layers;
      }),
    ];
    return Container(
      width: 190,
      // The panel grew past a short viewport (spawn presets + depth sliders +
      // cheats); cap it to the screen and scroll instead of overflowing.
      constraints: BoxConstraints(
          maxHeight: math.max(160.0, MediaQuery.sizeOf(context).height - 24)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xE6101820),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x447FB0E0)),
      ),
      child: SingleChildScrollView(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Spawn presets first: the fastest way to get a scene on screen.
          const Padding(
            padding: EdgeInsets.only(left: 4, top: 4, bottom: 2),
            child: Text(
              'SPAWN',
              style: TextStyle(color: Color(0xFF7FB0E0), fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          for (final preset in SpawnPreset.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              child: _atmoButton(
                preset.label,
                const Color(0xFF7FE0A0),
                _vessels.all().isEmpty ? null : () => _spawnAt(preset),
              ),
            ),
          // Custom spawn: any body, at a typed altitude or landed. The body
          // pick defaults to whatever the camera is looking at.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Row(children: [
              const Text('Body ',
                  style: TextStyle(color: Color(0xFFB9C9DC), fontSize: 12)),
              Expanded(
                child: DropdownButton<BodyId>(
                  value: _spawnCustomBodyId(),
                  isExpanded: true,
                  isDense: true,
                  dropdownColor: const Color(0xE6101820),
                  style:
                      const TextStyle(color: Color(0xFFB9C9DC), fontSize: 12),
                  items: [
                    for (final b in _universe.current().all)
                      DropdownMenuItem(value: b.id, child: Text(b.name)),
                  ],
                  onChanged: (id) => rebuild(() => _spawnBody = id),
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Row(children: [
              const Text('Alt ',
                  style: TextStyle(color: Color(0xFFB9C9DC), fontSize: 12)),
              Expanded(
                child: TextField(
                  controller: _spawnAltCtrl,
                  style:
                      const TextStyle(color: Color(0xFFB9C9DC), fontSize: 12),
                  decoration: const InputDecoration(
                    isDense: true,
                    suffixText: 'km',
                    suffixStyle:
                        TextStyle(color: Color(0xFF7E93A8), fontSize: 11),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                    enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0x447FB0E0))),
                    focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF7FB0E0))),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Row(children: [
              Expanded(
                child: _atmoButton(
                  'Orbit @ alt',
                  const Color(0xFF7FE0A0),
                  _vessels.all().isEmpty
                      ? null
                      : () => _spawnCustom(landed: false),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _atmoButton(
                  'Landed',
                  const Color(0xFF7FE0A0),
                  _vessels.all().isEmpty
                      ? null
                      : () => _spawnCustom(landed: true),
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
            child: Text(
              _vessels.all().isEmpty
                  ? 'No craft to move.'
                  : 'Moves the locked craft (warp → 1x).',
              style: const TextStyle(color: Color(0xFF7E93A8), fontSize: 11),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(left: 4, top: 6, bottom: 2),
            child: Text(
              'DRAW LAYERS',
              style: TextStyle(color: Color(0xFF7FB0E0), fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          for (final (label, value, set) in rows)
            InkWell(
              onTap: () => rebuild(() => _layers = set(!value)),
              child: Row(
                children: [
                  Checkbox(
                    value: value,
                    onChanged: (v) => rebuild(() => _layers = set(v ?? false)),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  // Flexible: the longest labels ('Exaggerate atmosphere')
                  // overflow the 190 px panel otherwise.
                  Expanded(
                    child: Text(label,
                        style: const TextStyle(
                            color: Color(0xFFB9C9DC), fontSize: 12)),
                  ),
                ],
              ),
            ),
          // Perspective camera toggle.
          InkWell(
            onTap: () => rebuild(() => _perspectiveMode = !_perspectiveMode),
            child: Row(
              children: [
                Checkbox(
                  value: _perspectiveMode,
                  onChanged: (v) => rebuild(() => _perspectiveMode = v ?? false),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                const Text('Perspective', style: TextStyle(color: Color(0xFFB9C9DC), fontSize: 12)),
              ],
            ),
          ),
          // FOV (tap to cycle), only meaningful in perspective.
          InkWell(
            onTap: () => rebuild(() {
              const opts = [50.0, 65.0, 75.0, 90.0, 105.0];
              final i = opts.indexWhere((o) => o >= _fovDeg);
              _fovDeg = opts[(i + 1) % opts.length];
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
              child: Text(
                'FOV: ${_fovDeg.toStringAsFixed(0)}°',
                style: const TextStyle(color: Color(0xFF7FB0E0), fontSize: 12),
              ),
            ),
          ),
          // Terrain shader debug view (tap to cycle). Only the 3D backend
          // runs terrain.frag — on the software painter the choice is stored
          // but has no visual effect, hence the suffix.
          // height = hypsometric bands of the meshed field, albedo = the raw
          // baked map through the shader's uv path, align = albedo grey +
          // altitude contours + graticule (contours hugging maria = aligned).
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: _atmoButton(
              'Terrain view: '
              '${TerrainNodes.debugViewNames[TerrainNodes.debugView]}'
              '${_renderBackend == RenderBackend.flutterScene ? '' : ' (3D only)'}',
              TerrainNodes.debugView == 0
                  ? const Color(0xFF7FB0E0)
                  : const Color(0xFFFFB347),
              () => rebuild(() {
                TerrainNodes.debugView =
                    (TerrainNodes.debugView + 1) % TerrainNodes.debugViewCount;
              }),
            ),
          ),
          // Tilted-view cull zoom threshold (tap to cycle).
          InkWell(
            onTap: () => rebuild(() {
              const opts = [3e5, 1e6, 3e6, 1e7, double.infinity];
              final i = opts.indexWhere((o) => o >= _tiltedCullMpp);
              _tiltedCullMpp = opts[(i + 1) % opts.length];
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
              child: Text(
                'Cull zoom: ${_tiltedCullMpp.isInfinite ? "never" : "${(_tiltedCullMpp / 1000).toStringAsFixed(0)}k m/px"}',
                style: const TextStyle(color: Color(0xFF7FB0E0), fontSize: 12),
              ),
            ),
          ),
          // Depth planes (3D backend): adaptive by default; unchecking pins
          // near/far to log-scale sliders (same overrides as the
          // ext.acro.camera?near=&far= dev extension — the HUD depth line
          // marks pinned values with '*').
          const Padding(
            padding: EdgeInsets.only(left: 4, top: 6, bottom: 2),
            child: Text(
              'DEPTH PLANES',
              style: TextStyle(color: Color(0xFF7FB0E0), fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          InkWell(
            onTap: () => rebuild(() {
              final adaptive = SceneCameraDebug.nearOverrideM == null &&
                  SceneCameraDebug.farOverrideM == null;
              if (adaptive) {
                // Seed the sliders from what the adaptive formula gives now.
                final eyeM = _range + _focusBodyRadius;
                SceneCameraDebug.nearOverrideM = math.max(1.0, eyeM / 20.0);
                SceneCameraDebug.farOverrideM = math.max(5e12, eyeM * 40);
              } else {
                SceneCameraDebug.nearOverrideM = null;
                SceneCameraDebug.farOverrideM = null;
              }
            }),
            child: Row(
              children: [
                Checkbox(
                  value: SceneCameraDebug.nearOverrideM == null &&
                      SceneCameraDebug.farOverrideM == null,
                  onChanged: (_) => rebuild(() {
                    final adaptive = SceneCameraDebug.nearOverrideM == null &&
                        SceneCameraDebug.farOverrideM == null;
                    if (adaptive) {
                      final eyeM = _range + _focusBodyRadius;
                      SceneCameraDebug.nearOverrideM =
                          math.max(1.0, eyeM / 20.0);
                      SceneCameraDebug.farOverrideM = math.max(5e12, eyeM * 40);
                    } else {
                      SceneCameraDebug.nearOverrideM = null;
                      SceneCameraDebug.farOverrideM = null;
                    }
                  }),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                const Text('Adaptive',
                    style: TextStyle(color: Color(0xFFB9C9DC), fontSize: 12)),
              ],
            ),
          ),
          if (SceneCameraDebug.nearOverrideM != null) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                'near ${_engM(SceneCameraDebug.nearOverrideM!)}',
                style: const TextStyle(color: Color(0xFF7FB0E0), fontSize: 11),
              ),
            ),
            _logSlider(
              value: SceneCameraDebug.nearOverrideM!,
              minExp: -1, // 0.1 m
              maxExp: 9, // 1,000,000 km
              onChanged: (v) =>
                  rebuild(() => SceneCameraDebug.nearOverrideM = v),
            ),
          ],
          if (SceneCameraDebug.farOverrideM != null) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                'far ${_engM(SceneCameraDebug.farOverrideM!)}',
                style: const TextStyle(color: Color(0xFF7FB0E0), fontSize: 11),
              ),
            ),
            _logSlider(
              value: SceneCameraDebug.farOverrideM!,
              minExp: 5, // 100 km
              maxExp: 14, // beyond the system
              onChanged: (v) =>
                  rebuild(() => SceneCameraDebug.farOverrideM = v),
            ),
          ],
          // Eye adaptation: auto heuristic vs a manual override, with the
          // auto clamp and the up/down ease times exposed. The readout shows
          // the eased exposure actually applied and the target it chases —
          // 3D backend only (the software painter has no exposure).
          const Padding(
            padding: EdgeInsets.only(left: 4, top: 6, bottom: 2),
            child: Text(
              'EXPOSURE',
              style: TextStyle(color: Color(0xFF7FB0E0), fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: _atmoButton(
              'Exposure: ${SceneSync.autoExposure ? 'auto' : 'manual'}'
              '${_renderBackend == RenderBackend.flutterScene ? '' : ' (3D only)'}',
              SceneSync.autoExposure
                  ? const Color(0xFF7FB0E0)
                  : const Color(0xFFFFB347),
              () => rebuild(
                  () => SceneSync.autoExposure = !SceneSync.autoExposure),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              'now ${SceneSync.lastExposure.toStringAsFixed(2)}'
              ' → target ${SceneSync.lastTarget.toStringAsFixed(2)}',
              style: const TextStyle(color: Color(0xFF7FB0E0), fontSize: 11),
            ),
          ),
          if (!SceneSync.autoExposure) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                'manual ${SceneSync.manualExposure.toStringAsFixed(2)}x',
                style: const TextStyle(color: Color(0xFFB9C9DC), fontSize: 11),
              ),
            ),
            _logSlider(
              value: SceneSync.manualExposure,
              minExp: -0.7, // 0.2x
              maxExp: 0.7, // 5x
              onChanged: (v) =>
                  rebuild(() => SceneSync.manualExposure = v),
            ),
          ] else ...[
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                'auto min ${SceneSync.minExposure.toStringAsFixed(2)}x',
                style: const TextStyle(color: Color(0xFFB9C9DC), fontSize: 11),
              ),
            ),
            _logSlider(
              value: SceneSync.minExposure,
              minExp: -0.7, // 0.2x
              maxExp: 0.3, // 2x
              onChanged: (v) => rebuild(() => SceneSync.minExposure =
                  math.min(v, SceneSync.maxExposure)),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                'auto max ${SceneSync.maxExposure.toStringAsFixed(2)}x',
                style: const TextStyle(color: Color(0xFFB9C9DC), fontSize: 11),
              ),
            ),
            _logSlider(
              value: SceneSync.maxExposure,
              minExp: 0.0, // 1x
              maxExp: 0.7, // 5x
              onChanged: (v) => rebuild(() => SceneSync.maxExposure =
                  math.max(v, SceneSync.minExposure)),
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              'up ${SceneSync.adaptUpS.toStringAsFixed(2)}s',
              style: const TextStyle(color: Color(0xFFB9C9DC), fontSize: 11),
            ),
          ),
          _logSlider(
            value: SceneSync.adaptUpS,
            minExp: -1.3, // 0.05 s
            maxExp: 0.7, // 5 s
            onChanged: (v) => rebuild(() => SceneSync.adaptUpS = v),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              'down ${SceneSync.adaptDownS.toStringAsFixed(2)}s',
              style: const TextStyle(color: Color(0xFFB9C9DC), fontSize: 11),
            ),
          ),
          _logSlider(
            value: SceneSync.adaptDownS,
            minExp: -1.3, // 0.05 s
            maxExp: 0.7, // 5 s
            onChanged: (v) => rebuild(() => SceneSync.adaptDownS = v),
          ),
          // Destruction cheats: skip overheat / aero-stress / impact so a craft
          // survives an otherwise-fatal profile. Rebuilds the tick on change.
          const Padding(
            padding: EdgeInsets.only(left: 4, top: 6, bottom: 2),
            child: Text(
              'CHEATS',
              style: TextStyle(color: Color(0xFF7FB0E0), fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          _cheatRow('No overheating', _disableOverheat, (v) => _disableOverheat = v),
          _cheatRow('No aero load', _disableAeroStress, (v) => _disableAeroStress = v),
          _cheatRow('No craft destruction', _disableCraftDestruction,
              (v) => _disableCraftDestruction = v),
          _cheatRow('No impact craters', _disableCrater, (v) => _disableCrater = v),
          // Impact tester: drop a test mass beside the focused craft and watch
          // what the tick does with it (destruction threshold, crater size).
          const Padding(
            padding: EdgeInsets.only(left: 4, top: 6, bottom: 2),
            child: Text(
              'IMPACT TEST',
              style: TextStyle(color: Color(0xFF7FB0E0), fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Row(children: [
              const Text('Mass ',
                  style: TextStyle(color: Color(0xFFB9C9DC), fontSize: 12)),
              Expanded(
                child: TextField(
                  controller: _impactMassCtrl,
                  style:
                      const TextStyle(color: Color(0xFFB9C9DC), fontSize: 12),
                  decoration: const InputDecoration(
                    isDense: true,
                    suffixText: 'kg',
                    suffixStyle:
                        TextStyle(color: Color(0xFF7E93A8), fontSize: 11),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                    enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0x447FB0E0))),
                    focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF7FB0E0))),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                ),
              ),
              const SizedBox(width: 4),
              const Text('Speed ',
                  style: TextStyle(color: Color(0xFFB9C9DC), fontSize: 12)),
              Expanded(
                child: TextField(
                  controller: _impactSpeedCtrl,
                  style:
                      const TextStyle(color: Color(0xFFB9C9DC), fontSize: 12),
                  decoration: const InputDecoration(
                    isDense: true,
                    suffixText: 'm/s',
                    suffixStyle:
                        TextStyle(color: Color(0xFF7E93A8), fontSize: 11),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                    enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0x447FB0E0))),
                    focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF7FB0E0))),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: _atmoButton(
              '☄ Drop impactor',
              const Color(0xFFFFB74D),
              _focusVessel == null ? null : _dropImpactor,
            ),
          ),
          // Atmosphere chemistry demo: re-skin the focused planet's gas mix and
          // watch the limb's haze colour shift (driven by composition).
          const Padding(
            padding: EdgeInsets.only(left: 4, top: 6, bottom: 2),
            child: Text(
              'ATMOSPHERE',
              style: TextStyle(color: Color(0xFF7FB0E0), fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Row(
              children: [
                Expanded(
                  child: _atmoButton('☢ Nuke', const Color(0xFFFF7043), _targetBody == null ? null : _nukePlanet),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _atmoButton(
                    'Terraform',
                    const Color(0xFF4FC3F7),
                    _targetBody == null ? null : _terraformPlanet,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Text(
              _targetBody == null ? 'Lock a planet to enable.' : 'Target: ${_targetBody!.name}',
              style: const TextStyle(color: Color(0xFF7E93A8), fontSize: 11),
            ),
          ),
        ],
        ),
      ),
    );
  }

  Widget _atmoButton(String label, Color color, VoidCallback? onTap) => InkWell(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: onTap == null ? const Color(0x22556677) : color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: onTap == null ? const Color(0x33889999) : color, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: onTap == null ? const Color(0xFF66788A) : color,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    ),
  );

}

/// How far the camera should sit off the craft after a spawn (m). Surface
/// sites want to read the ground, the ring orbit wants the particle field
/// (visible within ~1 km), and the orbits want the planet behind the craft.
///
/// Top level, not a static on the extension: a static there would have to be
/// called through the extension's name, which is noise for a pure helper.
double _spawnViewRange(SpawnPreset preset) => switch (preset) {
      SpawnPreset.earthSurface || SpawnPreset.earthOcean => 150,
      SpawnPreset.moonSurface => 150,
      SpawnPreset.saturnRings => 400,
      SpawnPreset.lowEarthOrbit || SpawnPreset.lowLunarOrbit => 600,
    };
