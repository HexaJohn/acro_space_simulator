import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'infrastructure/flutter/sim_view_control.dart';
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
///
/// `--dart-define=BACKEND=software` boots the software renderer instead —
/// used for side-by-side parity captures of the SAME scene.
final GlobalKey _shotKey = GlobalKey();

void main() {
  const backend =
      String.fromEnvironment('BACKEND', defaultValue: 'flutterScene');

  // Headless-friendly screenshot: `ext.acro.screenshot` captures the app's
  // RepaintBoundary and writes a PNG — reliable even when the OS window is
  // occluded or the desktop is locked (window-level capture goes white).
  // Invoke over the VM service:
  //   callServiceExtension?...&method=ext.acro.screenshot&path=<out.png>
  developer.registerExtension('ext.acro.screenshot', (method, params) async {
    try {
      final path = params['path'] ?? 'scene_shot.png';
      final boundary = _shotKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.extensionError,
            'no RepaintBoundary yet');
      }
      final ui.Image image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File(path).writeAsBytes(data!.buffer.asUint8List());
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'saved': path}));
    } catch (e) {
      return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError, '$e');
    }
  });

  // Programmatic camera/renderer control over the VM service, e.g.
  //   ext.acro.camera?azimuthDeg=90&elevationDeg=20&rangeM=2e7
  //   ext.acro.camera?backend=software        (or flutterScene)
  //   ext.acro.status                          -> current camera/backend
  // Drives the live view through SimViewControl exactly like user input.
  developer.registerExtension('ext.acro.camera', (method, params) async {
    final c = SimViewControl.instance;
    double? deg(String k) =>
        params[k] == null ? null : double.tryParse(params[k]!);
    final az = deg('azimuthDeg'), el = deg('elevationDeg'), ro = deg('rollDeg');
    if (az != null || el != null || ro != null) {
      c.orbit?.call(
        azimuth: az == null ? null : az * math.pi / 180,
        elevation: el == null ? null : el * math.pi / 180,
        roll: ro == null ? null : ro * math.pi / 180,
      );
    }
    final range = deg('rangeM'), mpp = deg('metresPerPixel');
    if (range != null || mpp != null) {
      c.zoom?.call(rangeM: range, metresPerPixel: mpp);
    }
    if (params['perspective'] != null) {
      c.setPerspective?.call(params['perspective'] == 'true');
    }
    if (params['backend'] != null) {
      c.setBackend?.call(params['backend'] == 'software'
          ? RenderBackend.software
          : RenderBackend.flutterScene);
    }
    return developer.ServiceExtensionResponse.result(
        jsonEncode(c.status?.call() ?? {'error': 'no live view'}));
  });
  developer.registerExtension('ext.acro.status', (method, params) async {
    return developer.ServiceExtensionResponse.result(jsonEncode(
        SimViewControl.instance.status?.call() ?? {'error': 'no live view'}));
  });

  runApp(
    MaterialApp(
      title: 'Acro — flutter_scene dev',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: RepaintBoundary(
        key: _shotKey,
        child: SimulationView(
          initialBackend: backend == 'software'
              ? RenderBackend.software
              : RenderBackend.flutterScene,
        ),
      ),
    ),
  );
}
