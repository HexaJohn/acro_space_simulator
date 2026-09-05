// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Dev entrypoint: boots STRAIGHT into the city studio, with the same
/// VM-service harness surface `main_scene_dev.dart` gives the flight view —
/// so a script can generate a colony, read the perf panel's numbers, and
/// screenshot the result headlessly (see tool/drive_city_studio.dart):
///
///   fvm flutter run -d macos [--profile] -t lib/main_city_studio_dev.dart \
///       --enable-impeller --enable-flutter-gpu
///
/// Extensions:
///   ext.acro.screenshot?path=PNG       capture the RepaintBoundary
///   ext.acro.citystudio                status (busy, frame/ui/raster ms,
///                                      terrain/city phase ms, census, stats)
///   ext.acro.citystudio?perf=false&controls=false   hide the panels
///   ext.acro.citystudio?distance=9000&elevation=1.2  aim the orbit camera
///   ext.acro.citystudio?pick=0.5,0.5      click at a viewport fraction
///   ext.acro.citystudio?walk=e,n,yaw,pitch[,eyeM]   hover the walker's eye
///   ext.acro.citystudio?drive=e,n,yaw[,throttle,steer,seconds]
///                                      put the buggy down, hold the pedals
///   ext.acro.citystudio?action=generate[&blocks=N][&voxelM=V]
///                                      press GENERATE remotely
library;

import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'infrastructure/baked_terrain_data.dart';
import 'infrastructure/flutter/screens/city_studio_screen.dart';
import 'infrastructure/flutter_scene/terrain/terrain_nodes.dart';

final GlobalKey _shotKey = GlobalKey();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadBakedTerrainData();

  developer.registerExtension('ext.acro.screenshot', (method, params) async {
    try {
      final path = params['path'] ?? 'city_studio_shot.png';
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

  developer.registerExtension('ext.acro.citystudio', (method, params) async {
    final status = CityStudioDevHooks.status;
    if (status == null) {
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'error': 'no live studio'}));
    }
    if (params['shadows'] != null || params['atmosphere'] != null) {
      final set = CityStudioDevHooks.setIsolate;
      if (set == null) {
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'error': 'no isolate hook'}));
      }
      bool? flag(String k) =>
          params[k] == null ? null : params[k] == 'true';
      set(shadows: flag('shadows'), atmosphere: flag('atmosphere'));
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'ok': true}));
    }
    if (params['distance'] != null ||
        params['azimuth'] != null ||
        params['elevation'] != null) {
      final set = CityStudioDevHooks.setCamera;
      if (set == null) {
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'error': 'no camera hook'}));
      }
      set(
        distanceM: double.tryParse(params['distance'] ?? ''),
        azimuth: double.tryParse(params['azimuth'] ?? ''),
        elevation: double.tryParse(params['elevation'] ?? ''),
      );
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'ok': true}));
    }
    if (params['walk'] != null) {
      final walk = CityStudioDevHooks.walkTo;
      final parts = params['walk']!.split(',');
      if (walk == null || parts.length < 4) {
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'error': 'no walk hook or bad walk=e,n,yaw,pitch[,eyeM]'}));
      }
      walk(
        e: double.parse(parts[0]),
        n: double.parse(parts[1]),
        yaw: double.parse(parts[2]),
        pitch: double.parse(parts[3]),
        eyeM: parts.length > 4 ? double.tryParse(parts[4]) : null,
      );
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'ok': true}));
    }
    if (params['drive'] != null) {
      final drive = CityStudioDevHooks.drive;
      final parts = params['drive']!.split(',');
      if (drive == null || parts.length < 3) {
        return developer.ServiceExtensionResponse.result(jsonEncode({
          'error': 'no drive hook or bad drive=e,n,yaw[,throttle,steer,seconds]'
        }));
      }
      drive(
        e: double.parse(parts[0]),
        n: double.parse(parts[1]),
        yaw: double.parse(parts[2]),
        throttle: parts.length > 3 ? double.tryParse(parts[3]) ?? 0 : 0,
        steer: parts.length > 4 ? double.tryParse(parts[4]) ?? 0 : 0,
        seconds: parts.length > 5 ? double.tryParse(parts[5]) ?? 0 : 0,
      );
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'ok': true}));
    }
    if (params['pick'] != null) {
      final pick = CityStudioDevHooks.pick;
      final parts = params['pick']!.split(',');
      if (pick == null || parts.length != 2) {
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'error': 'no pick hook or bad pick=fx,fy'}));
      }
      final label = pick(double.parse(parts[0]), double.parse(parts[1]));
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'picked': label}));
    }
    if (params['perf'] != null || params['controls'] != null) {
      final set = CityStudioDevHooks.setPanels;
      if (set == null) {
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'error': 'no panels hook'}));
      }
      bool? flag(String k) =>
          params[k] == null ? null : params[k] == 'true';
      set(perf: flag('perf'), controls: flag('controls'));
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'ok': true}));
    }
    if (params['action'] == 'generate') {
      final gen = CityStudioDevHooks.generate;
      if (gen == null) {
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'error': 'no generate hook'}));
      }
      // Fire-and-forget: a build takes seconds and the caller polls `busy`.
      // `blocks=N` sizes the colony (the "Blocks across" slider); `voxelM=V`
      // sets the ground's voxel floor under it (the "City voxel floor" one).
      unawaited(gen(
        blocks: int.tryParse(params['blocks'] ?? ''),
        voxelM: double.tryParse(params['voxelM'] ?? ''),
        sprawlMiles: double.tryParse(params['sprawl'] ?? ''),
      ));
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'ok': true}));
    }
    return developer.ServiceExtensionResponse.result(jsonEncode({
      ...status(),
      'terrainDebug': TerrainNodes.debugLine,
      'terrainProfile': TerrainNodes.profileLine,
      // The panel's terrain rows (chunks, brushes, refineTargets, ...).
      'terrainCounters': TerrainNodes.counters,
    }));
  });

  runApp(
    // ExcludeSemantics above MaterialApp, as main_scene_dev does: the
    // Windows accessibility bridge corrupts on semantics mutation, and the
    // perf panel's fifty rows re-generate the tree on every panel tick —
    // a 15 ms SEMANTICS span in the frame timeline for a readout nobody
    // reads through a screen reader.
    ExcludeSemantics(child: MaterialApp(
      title: 'Acro — city studio dev',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: RepaintBoundary(
        key: _shotKey,
        child: const CityStudioScreen(),
      ),
    )),
  );
}
