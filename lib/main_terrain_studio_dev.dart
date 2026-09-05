// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Dev entrypoint: boots STRAIGHT into the terrain studio, with the same
/// VM-service harness surface `main_city_studio_dev.dart` gives the city
/// studio — so a script can open a site, walk or drive it, pick the ground
/// and screenshot the result headlessly (see tool/drive_terrain_rover_shot.dart):
///
///   fvm flutter run -d windows [--profile] -t lib/main_terrain_studio_dev.dart \
///       --enable-impeller --enable-flutter-gpu
///
/// Extensions:
///   ext.acro.screenshot?path=PNG          capture the RepaintBoundary
///   ext.acro.terrainstudio                status (site, frame ms, terrain
///                                         counters, walker, rover)
///   ext.acro.terrainstudio?action=open    press OPEN SITE
///   ext.acro.terrainstudio?perf=false&controls=false   hide the panels
///   ext.acro.terrainstudio?walk=e,n,yaw,pitch    stand the walker
///   ext.acro.terrainstudio?drive=e,n,yaw[,throttle,steer,seconds]
///                                         put the buggy down, hold the pedals
///   ext.acro.terrainstudio?pick=fx,fy     the ground under a viewport
///                                         fraction, metres e/n/up of the anchor
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'infrastructure/baked_terrain_data.dart';
import 'infrastructure/flutter/screens/terrain_studio_screen.dart';

final GlobalKey _shotKey = GlobalKey();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadBakedTerrainData();

  developer.registerExtension('ext.acro.screenshot', (method, params) async {
    try {
      final path = params['path'] ?? 'terrain_studio_shot.png';
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

  developer.registerExtension('ext.acro.terrainstudio', (method, params) async {
    final status = TerrainStudioDevHooks.status;
    if (status == null) {
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'error': 'no live studio'}));
    }
    Map<String, dynamic> ok() => {'ok': true};
    if (params['action'] == 'open') {
      final open = TerrainStudioDevHooks.openSite;
      if (open == null) {
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'error': 'no open hook'}));
      }
      open();
      return developer.ServiceExtensionResponse.result(jsonEncode(ok()));
    }
    if (params['perf'] != null || params['controls'] != null) {
      final set = TerrainStudioDevHooks.setPanels;
      if (set == null) {
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'error': 'no panels hook'}));
      }
      bool? flag(String k) =>
          params[k] == null ? null : params[k] == 'true';
      set(perf: flag('perf'), controls: flag('controls'));
      return developer.ServiceExtensionResponse.result(jsonEncode(ok()));
    }
    if (params['walk'] != null) {
      final walk = TerrainStudioDevHooks.walkTo;
      final parts = params['walk']!.split(',');
      if (walk == null || parts.length < 4) {
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'error': 'no walk hook or bad walk=e,n,yaw,pitch'}));
      }
      walk(
        e: double.parse(parts[0]),
        n: double.parse(parts[1]),
        yaw: double.parse(parts[2]),
        pitch: double.parse(parts[3]),
      );
      return developer.ServiceExtensionResponse.result(jsonEncode(ok()));
    }
    if (params['drive'] != null) {
      final drive = TerrainStudioDevHooks.drive;
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
      return developer.ServiceExtensionResponse.result(jsonEncode(ok()));
    }
    if (params['pick'] != null) {
      final pick = TerrainStudioDevHooks.pick;
      final parts = params['pick']!.split(',');
      if (pick == null || parts.length != 2) {
        return developer.ServiceExtensionResponse.result(
            jsonEncode({'error': 'no pick hook or bad pick=fx,fy'}));
      }
      final hit = pick(double.parse(parts[0]), double.parse(parts[1]));
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'hit': hit}));
    }
    return developer.ServiceExtensionResponse.result(jsonEncode(status()));
  });

  runApp(
    MaterialApp(
      title: 'Acro — terrain studio dev',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: RepaintBoundary(
        key: _shotKey,
        child: const TerrainStudioScreen(),
      ),
    ),
  );
}
