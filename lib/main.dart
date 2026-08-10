// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter/material.dart';

import 'infrastructure/flutter/screens/main_menu_screen.dart';
import 'infrastructure/flutter/windows_key_event_workaround.dart';

void main() {
  installWindowsAltKeyAssertFilter();
  runApp(const AcroSpaceSimulatorApp());
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
