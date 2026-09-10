// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Dev entrypoint: boots STRAIGHT into the CITY BUILDER mode — a starter
/// colony already founded, the editor open on it, the camera over its
/// crossroads. No menu, no setup screen.
///
///   fvm flutter run -d windows --profile -t lib/main_city_game_dev.dart \
///       --enable-impeller --enable-flutter-gpu
///
/// `--dart-define=BODY=moon` founds it elsewhere; `START=harsh` changes the
/// difficulty. Extensions:
///
///   ext.acro.screenshot?path=PNG   capture the RepaintBoundary
///   ext.acro.citygame              the colony's live numbers (pop, funds,
///                                  ore, tier, RCI, roads, lots)
///   ext.acro.citygame?zones=on|off      raise/drop the zoning view
///   ext.acro.citygame?zone=residential  zone every street lot at once
///   ext.acro.camera?elevationDeg=&azimuthDeg=&rangeM=
///                                  aim the camera, for framing the shot
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'domain/colony/city/city_config.dart';
import 'domain/colony/city/city_progression.dart';
import 'domain/colony/city/city_sim.dart';
import 'domain/colony/city/city_starter_kit.dart';
import 'domain/colony/city/parcel.dart';
import 'domain/planetary/planet_surface.dart';
import 'domain/universe/real_solar_system.dart';
import 'infrastructure/baked_terrain_data.dart';
import 'infrastructure/flutter/sim_view_control.dart';
import 'infrastructure/flutter/simulation_view.dart';
import 'infrastructure/flutter_scene/city/city_nodes.dart';
import 'infrastructure/flutter/windows_key_event_workaround.dart';
import 'infrastructure/flutter_scene/render_backend.dart';

final GlobalKey _shotKey = GlobalKey();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installWindowsAltKeyAssertFilter();
  await loadBakedTerrainData();

  const bodyId = String.fromEnvironment('BODY', defaultValue: 'earth');
  const startName = String.fromEnvironment('START', defaultValue: 'standard');
  final start = CityStart.values.firstWhere((s) => s.name == startName,
      orElse: () => CityStart.standard);

  final colony = CityStarterKit.found(
    bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
    config: const CityConfig(
        bodyId: bodyId, latitude: -45.03, longitude: 168.66, biome: Biome.forest),
    start: start,
    id: 'city-dev',
    name: 'Dev Colony',
  );

  developer.registerExtension('ext.acro.screenshot', (method, params) async {
    try {
      final path = params['path'] ?? 'city_game_shot.png';
      final boundary =
          _shotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
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

  developer.registerExtension('ext.acro.citygame', (method, params) async {
    // The zoning view, for captures. Flipping it re-meshes the tiles, so a
    // driver should settle before it shoots.
    if (params['zones'] != null) {
      CityNodes.zoneOverlay = params['zones'] == 'on';
    }
    // Zone every street lot at once. The only way to drive zoning without a
    // mouse, which is what a capture of the zoning view needs.
    if (params['zone'] != null) {
      final use = switch (params['zone']) {
        'residential' => ParcelUse.residential,
        'commercial' => ParcelUse.commercial,
        'industrial' => ParcelUse.industrial,
        _ => ParcelUse.unzoned,
      };
      for (final lot in colony.layout.autoParcels) {
        colony.layout.setUse(lot.id, use);
      }
    }
    final view = SimViewControl.instance.status?.call() ?? const {};
    return developer.ServiceExtensionResponse.result(jsonEncode({
      ..._status(colony),
      // The camera's own geometry, so a framing complaint can be answered with
      // a number instead of a screenshot.
      'camera': {
        for (final k in const [
          'cityPivotAltM',
          'cityPivotOffsetM',
          'cityRangeM',
          'cityElevationRad',
          'freecam',
          'upMode',
        ])
          k: view[k],
      },
    }));
  });

  // Framing knob. The opening camera pose is a judgement call about how much
  // of the colony should be in frame, and re-launching to try a number is a
  // three-minute round trip — this makes it a request.
  developer.registerExtension('ext.acro.camera', (method, params) async {
    final c = SimViewControl.instance;
    double? deg(String k) =>
        params[k] == null ? null : double.tryParse(params[k]!);
    final az = deg('azimuthDeg'), el = deg('elevationDeg');
    if (az != null || el != null) {
      c.orbit?.call(
        azimuth: az == null ? null : az * math.pi / 180,
        elevation: el == null ? null : el * math.pi / 180,
      );
    }
    final range = deg('rangeM');
    if (range != null) c.zoom?.call(rangeM: range);
    return developer.ServiceExtensionResponse.result(jsonEncode({'ok': true}));
  });

  runApp(
    ExcludeSemantics(
      child: MaterialApp(
        title: 'Acro — city builder dev',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: RepaintBoundary(
          key: _shotKey,
          child: SimulationView(
            injectedCity: colony,
            cityMode: true,
            spawnDemoOrbiter: false,
            initialBackend: RenderBackend.flutterScene,
          ),
        ),
      ),
    ),
  );
}

/// Everything a driver script needs to judge a run without a screenshot.
Map<String, dynamic> _status(CitySim c) => {
      'body': c.body.id.value,
      'population': c.population,
      'tier': CityProgression.reached(c.population).name,
      'milestones': c.milestonesReached.toList()..sort(),
      'funds': c.funds,
      'ore': c.stockOf('ore'),
      'housing': c.housing,
      'jobs': c.jobs,
      'happiness': c.happiness,
      'power': {'out': c.powerOut, 'draw': c.powerDraw},
      'rci': {'r': c.resTarget, 'c': c.comTarget, 'i': c.indTarget},
      'spaceport': c.hasSpaceport,
      'roads': c.layout.roads.length,
      'lots': c.layout.parcels.length,
      'zoned': c.layout.parcels.where((p) => p.use.name != 'unzoned').length,
      'grown': c.grownParcels.length,
      'trend': c.popTrend,
    };
