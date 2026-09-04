// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter/material.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'infrastructure/baked_terrain_data.dart';
import 'infrastructure/flutter/screens/main_menu_screen.dart';
import 'infrastructure/flutter/windows_key_event_workaround.dart';
import 'infrastructure/flutter_scene/graphics_quality.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installWindowsAltKeyAssertFilter();
  // Awaited: collision reads the DEM registry synchronously from the tick, so
  // the pyramids must be resident before any screen can build a sim.
  await loadBakedTerrainData();
  await _loadGraphicsQuality();
  runApp(const AcroSpaceSimulatorApp());
}

/// Restore the scalability preset before the first frame.
///
/// Awaited rather than fire-and-forget: the render passes read
/// [GraphicsQuality] every frame, so loading it late would draw the first
/// seconds at High on the very machines the setting exists for. A failure here
/// is not worth blocking launch over — the defaults are the shipped look.
Future<void> _loadGraphicsQuality() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    GraphicsQuality.applyPrefs({
      for (final key in GraphicsQuality.prefKeys) key: prefs.getString(key),
    });
  } catch (_) {
    GraphicsQuality.reset();
  }
}

/// Composition root. Wires nothing itself beyond the app shell — the
/// [SimulationView] builds the use cases from adapters/ports. All architecture
/// layers (domain -> application -> adapters -> infrastructure) converge here.
class AcroSpaceSimulatorApp extends StatelessWidget {
  const AcroSpaceSimulatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    // ExcludeSemantics above MaterialApp: the Windows accessibility bridge
    // spams 'Failed to update ui::AXTree ... will not be in the tree' (and can
    // AV in flutter_windows.dll) whenever the semantics tree mutates on a
    // focus switch. An empty, static semantics tree gives the bridge nothing
    // to reconcile. Same workaround as main_scene_dev.dart — see the rationale
    // there. Costs screen-reader support; pointer/keyboard input unaffected.
    return ExcludeSemantics(
      child: MaterialApp(
        title: 'Acro Space Simulator',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const MainMenuScreen(),
      ),
    );
  }
}
