import 'package:flutter/material.dart';

import 'infrastructure/flutter/simulation_view.dart';

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
      home: const SimulationView(),
    );
  }
}
