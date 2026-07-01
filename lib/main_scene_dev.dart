import 'package:flutter/material.dart';

import 'infrastructure/flutter/simulation_view.dart';
import 'infrastructure/flutter_scene/render_backend.dart';

/// Dev entrypoint: boots STRAIGHT into [SimulationView] with the
/// flutter_scene backend active — no menu, no clicking. For iterating on the
/// 3D backend:
///
///   .fvm\flutter_sdk\bin\flutter.bat run -d windows --enable-impeller \
///       --enable-flutter-gpu -t lib/main_scene_dev.dart
///
/// Not wired into any release build; the shipping entrypoint stays main.dart.
void main() {
  runApp(
    MaterialApp(
      title: 'Acro — flutter_scene dev',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const SimulationView(initialBackend: RenderBackend.flutterScene),
    ),
  );
}
