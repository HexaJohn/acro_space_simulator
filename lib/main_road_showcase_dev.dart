// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Dev entrypoint: a SHOWCASE of the road tool's roads, laid round the
/// colony origin — where the city camera's pivot sits, so every close-up is
/// a zoom and an orbit: a street raised 12 m over a cross street on piers,
/// one sunk 12 m under it into a tunnel, a one-way pair (one dressed in
/// trees), a gravel track, a four-lane road with trees meeting a six-lane
/// road with grass at a junction the player has switched the lights off at,
/// and a highway pair crossing them all at grade. Every road built through
/// `CitySim.buildRoad`, the player's path, against the real ground. No
/// starter kit: nothing but roads to look at.
///
///   fvm flutter run -d windows --profile -t lib/main_road_showcase_dev.dart \
///       --enable-impeller --enable-flutter-gpu
///
/// Extensions (driven by `tool/drive_road_showcase.dart`):
///
///   ext.acro.screenshot?path=PNG       capture the RepaintBoundary
///   ext.acro.camera?elevationDeg=&azimuthDeg=&rangeM=
///   ext.acro.showcase                  what was built (and refused), the
///                                      roads, the funds and the upkeep
///   ext.acro.showcase?reverse=E,N      reverse the one-way road nearest
///   ext.acro.showcase?upgrade=E,N&type=ID   upgrade the road nearest
///   ext.acro.showcase?lights=E,N&on=1|0|auto  override a junction
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'domain/colony/city/city_config.dart';
import 'domain/colony/city/city_sim.dart';
import 'domain/colony/city/parcel.dart';
import 'domain/colony/city/road_build.dart';
import 'domain/colony/city/road_catalog.dart';
import 'domain/colony/city/road_junction.dart';
import 'domain/planetary/planet_surface.dart';
import 'domain/universe/real_solar_system.dart';
import 'infrastructure/baked_terrain_data.dart';
import 'infrastructure/flutter/sim_view_control.dart';
import 'infrastructure/flutter/simulation_view.dart';
import 'infrastructure/flutter/windows_key_event_workaround.dart';
import 'infrastructure/flutter_scene/render_backend.dart';

final GlobalKey _shotKey = GlobalKey();

/// One line per road the showcase asked for: what it cost, or why not.
final List<String> _built = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installWindowsAltKeyAssertFilter();
  await loadBakedTerrainData();

  final colony = CitySim.found(
    const CityConfig(
        bodyId: 'earth', latitude: -45.03, longitude: 168.66, biome: Biome.forest),
    bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
    id: 'roads-dev',
    name: 'Road Showcase',
  );
  // Every road on the menu, and the money to lay them all.
  colony.funds = 5e6;
  colony.ignoreUnlocks = true;
  final ground = _groundOf(colony);
  _layShowcase(colony, ground);

  developer.registerExtension('ext.acro.screenshot', (method, params) async {
    try {
      final path = params['path'] ?? 'road_showcase_shot.png';
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

  developer.registerExtension('ext.acro.showcase', (method, params) async {
    String? act;
    try {
      Vec2? at(String k) {
        final v = params[k];
        if (v == null) return null;
        final parts = v.split(',').map(double.parse).toList();
        return Vec2(parts[0], parts[1]);
      }

      String? nearest(Vec2 p) =>
          colony.layout.nearestRoadPoint(p, withinM: 40)?.roadId;

      final rev = at('reverse');
      if (rev != null) {
        final id = nearest(rev);
        act = 'reverse $id: ${id != null && colony.reverseRoad(id)}';
      }
      final up = at('upgrade');
      if (up != null) {
        final id = nearest(up);
        final type = RoadType.byId(params['type'] ?? '');
        if (id != null && type != null) {
          final q = colony.upgradeRoad(id, type, groundAt: ground);
          act = 'upgrade $id to ${type.id}: '
              '${q.ok ? 'ok ${formatMoney(q.cost)}' : q.reason}';
        } else {
          act = 'upgrade: no road or no type';
        }
      }
      // build=E,N;E,N[;...]&type=ID&e0=&e1= : lay a road the player's way.
      final build = params['build'];
      if (build != null) {
        final pts = [
          for (final pair in build.split(';'))
            Vec2(double.parse(pair.split(',')[0]),
                double.parse(pair.split(',')[1])),
        ];
        final type = RoadType.byId(params['type'] ?? 'two-lane')!;
        final r = colony.buildRoad(
            RoadBuildRequest(
              controls: pts,
              type: type,
              startElevationM: double.tryParse(params['e0'] ?? '') ?? 0,
              endElevationM: double.tryParse(params['e1'] ?? '') ?? 0,
            ),
            groundAt: ground);
        act = 'build ${r.roadId ?? r.quote.reason} ${formatMoney(r.quote.cost)}';
      }
      final lights = at('lights');
      if (lights != null) {
        final on = params['on'];
        colony.setJunctionOverride(JunctionOverride(
            at: lights, lights: on == '1' ? true : (on == '0' ? false : null)));
        act = 'lights at $lights: $on';
      }
    } catch (e) {
      act = 'error: $e';
    }
    return developer.ServiceExtensionResponse.result(jsonEncode({
      if (act != null) 'action': act,
      'built': _built,
      'funds': colony.funds.round(),
      'roadUpkeepPerWeek': colony.roadUpkeepPerWeek.toStringAsFixed(1),
      'roadsRevision': colony.roadsRevision,
      'roads': [
        for (final r in colony.layout.roads)
          '${r.id} ${r.roadClass.name}'
              '${r.decoration.index != 0 ? ' ${r.decoration.name}' : ''}'
              '${r.reversed ? ' reversed' : ''}'
              '${r.deck == null ? '' : ' deck ${r.deck!.startM.toStringAsFixed(1)}..${r.deck!.endM.toStringAsFixed(1)} piers ${r.deck!.structureM.round()} tunnel ${r.deck!.tunnelM.round()}'}',
      ],
    }));
  });

  runApp(
    ExcludeSemantics(
      child: MaterialApp(
        title: 'Acro — road showcase dev',
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

/// The natural ground's height above the body datum under a colony point:
/// the pristine field (nothing is graded yet when the showcase is laid).
double Function(Vec2) _groundOf(CitySim c) {
  final body = c.body;
  final field = body.terrainFieldWith(null);
  return (p) {
    if (field == null) return 0;
    final d = c.localToBodyFixed(p, bodyRadiusM: body.radius);
    return field.surfaceRadiusAt(d.x, d.y, d.z) - body.radius;
  };
}

void _build(
  CitySim c,
  String label,
  String typeId,
  List<Vec2> controls,
  double Function(Vec2) ground, {
  double e0 = 0,
  double e1 = 0,
}) {
  final type = RoadType.byId(typeId)!;
  final r = c.buildRoad(
      RoadBuildRequest(
          controls: controls,
          type: type,
          startElevationM: e0,
          endElevationM: e1),
      groundAt: ground);
  final q = r.quote;
  _built.add('$label (${type.id}): '
      '${r.roadId ?? 'REFUSED — ${q.reason}'} '
      '${formatMoney(q.cost)}, ${q.lengthM.round()} m, '
      'piers ${q.structureM.round()} m (bridge ${q.bridgeM.round()}), '
      'tunnel ${q.tunnelM.round()} m, grade ${q.gradePct.toStringAsFixed(1)}%');
}

/// The showcase, laid in order round the origin: later roads cross earlier
/// ones, which is what exercises the crossing rules — at grade (a
/// junction), over or under (no junction).
void _layShowcase(CitySim c, double Function(Vec2) g) {
  // The cross street, east-west through the origin.
  _build(c, 'cross street', 'two-lane', const [Vec2(-400, 0), Vec2(400, 0)], g);
  // An overpass: north-south through the origin, raised 12 m over the
  // cross street on piers, down again either side.
  _build(c, 'ramp up', 'two-lane', const [Vec2(0, -300), Vec2(0, -120)], g,
      e1: 12);
  _build(c, 'viaduct', 'two-lane', const [Vec2(0, -120), Vec2(0, 120)], g,
      e0: 12, e1: 12);
  _build(c, 'ramp down', 'two-lane', const [Vec2(0, 120), Vec2(0, 300)], g,
      e0: 12);
  // A tunnel beside it: down 12 m, under the cross street, and up.
  _build(c, 'tunnel in', 'two-lane', const [Vec2(-200, -300), Vec2(-200, -140)],
      g,
      e1: -12);
  _build(c, 'tunnel', 'two-lane', const [Vec2(-200, -140), Vec2(-200, 140)], g,
      e0: -12, e1: -12);
  _build(c, 'tunnel out', 'two-lane', const [Vec2(-200, 140), Vec2(-200, 300)],
      g,
      e0: -12);
  // A one-way pair to the north, drawn opposite ways, one dressed in trees.
  _build(c, 'one-way west', 'one-way', const [Vec2(400, 200), Vec2(-400, 200)], g);
  _build(c, 'one-way east', 'one-way-trees',
      const [Vec2(-400, 240), Vec2(400, 240)], g);
  _build(c, 'gravel', 'gravel', const [Vec2(-400, 340), Vec2(300, 340)], g);
  // A four-lane road with trees, north-south, meeting a six-lane road with
  // grass to the south — a junction the rules give lights, switched off.
  _build(c, 'four-lane trees', 'four-lane-trees',
      const [Vec2(200, -300), Vec2(200, 300)], g);
  _build(c, 'six-lane grass', 'six-lane-grass',
      const [Vec2(-400, -200), Vec2(400, -200)], g);
  c.setJunctionOverride(
      const JunctionOverride(at: Vec2(200, -200), lights: false));
  // A highway pair to the east, one each way, the southbound walled.
  _build(c, 'highway north', 'highway',
      const [Vec2(350, -400), Vec2(350, 400)], g);
  _build(c, 'highway south', 'highway-walls',
      const [Vec2(390, 400), Vec2(390, -400)], g);
}
