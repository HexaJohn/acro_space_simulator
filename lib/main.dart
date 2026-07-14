// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

import 'package:flutter/material.dart';

import 'infrastructure/flutter/screens/main_menu_screen.dart';

void main() {
  runApp(const AcroSpaceSimulatorApp());
}

/// Composition root. Wires nothing itself beyond the app shell — the
/// [SimulationView] builds the use cases from adapters/ports. All architecture
/// layers (domain -> application -> adapters -> infrastructure) converge here.
class AcroSpaceSimulatorApp extends StatelessWidget {
  const AcroSpaceSimulatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Acro Space Simulator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const MainMenuScreen(),
    );
  }
}
