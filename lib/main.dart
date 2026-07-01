import 'package:flutter/material.dart';

import 'infrastructure/app_version.dart';
import 'infrastructure/flutter/screens/main_menu_screen.dart';
import 'infrastructure/sim_engine.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadAppVersion(); // read the pubspec version for the UI badge
  // Bring the simulation up immediately — it runs (and serves Unreal over the
  // bridge) from launch, independent of whether the player has entered flight.
  // On web this is the in-process-only sim (the bridge is a no-op there).
  simEngine.start();
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
