// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Dev entrypoint: boots STRAIGHT into the building studio, with the same
/// VM-service harness surface `main_city_studio_dev.dart` gives the city —
/// so a script can put every catalogue entry on the stand in turn, frame
/// it, and screenshot it headlessly:
///
///   fvm flutter run -d macos [--profile] -t lib/main_building_studio_dev.dart \
///       --enable-impeller --enable-flutter-gpu
///
/// Extensions:
///   ext.acro.screenshot?path=PNG          capture the RepaintBoundary
///   ext.acro.buildingstudio               status (label, type, the
///                                         catalogue's labels, lot, camera)
///   ext.acro.buildingstudio?label=Refinery   put a catalogue entry on the
///                                         stand (empty label: the zone)
///   ext.acro.buildingstudio?distance=&azimuth=&elevation=&pivot=&pivotY=
///                                         aim the orbit camera
///   ext.acro.buildingstudio?lot=W,D[,lots]   the lot sliders
///   ext.acro.buildingstudio?shape=tapered    the parcel shape, by name
///   ext.acro.buildingstudio?controls=false&hud=false&rig=false&lots=false
///   ext.acro.buildingstudio?action=frame|eye   the two toolbar buttons
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'infrastructure/flutter/screens/building_studio_screen.dart';

final GlobalKey _shotKey = GlobalKey();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  developer.registerExtension('ext.acro.screenshot', (method, params) async {
    try {
      final path = params['path'] ?? 'building_studio_shot.png';
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

  developer.registerExtension('ext.acro.buildingstudio', (method, params) async {
    final status = BuildingStudioDevHooks.status;
    if (status == null) {
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'error': 'no live studio'}));
    }
    bool? flag(String k) => params[k] == null ? null : params[k] == 'true';
    if (params['label'] != null) {
      BuildingStudioDevHooks.pick?.call(params['label']!);
    }
    if (params['distance'] != null ||
        params['azimuth'] != null ||
        params['elevation'] != null ||
        params['pivot'] != null ||
        params['pivotY'] != null ||
        params['pivotX'] != null) {
      BuildingStudioDevHooks.setCamera?.call(
        distanceM: double.tryParse(params['distance'] ?? ''),
        azimuth: double.tryParse(params['azimuth'] ?? ''),
        elevation: double.tryParse(params['elevation'] ?? ''),
        pivotZM: double.tryParse(params['pivot'] ?? ''),
        pivotYM: double.tryParse(params['pivotY'] ?? ''),
        pivotXM: double.tryParse(params['pivotX'] ?? ''),
      );
    }
    if (params['controls'] != null ||
        params['hud'] != null ||
        params['rig'] != null ||
        params['lots'] != null) {
      BuildingStudioDevHooks.setPanels?.call(
        controls: flag('controls'),
        hud: flag('hud'),
        rig: flag('rig'),
        lots: flag('lots'),
      );
    }
    if (params['lot'] != null) {
      final parts = params['lot']!.split(',');
      BuildingStudioDevHooks.setLot?.call(
        widthM: double.tryParse(parts[0]),
        depthM: parts.length > 1 ? double.tryParse(parts[1]) : null,
        lots: parts.length > 2 ? int.tryParse(parts[2]) : null,
      );
    }
    if (params['shape'] != null) {
      BuildingStudioDevHooks.setShape?.call(params['shape']!);
    }
    if (params['action'] == 'frame') BuildingStudioDevHooks.frame?.call();
    if (params['action'] == 'eye') BuildingStudioDevHooks.eyeLevel?.call();
    return developer.ServiceExtensionResponse.result(jsonEncode(status()));
  });

  runApp(
    MaterialApp(
      title: 'Acro — building studio dev',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: RepaintBoundary(
        key: _shotKey,
        child: const BuildingStudioScreen(),
      ),
    ),
  );
}
