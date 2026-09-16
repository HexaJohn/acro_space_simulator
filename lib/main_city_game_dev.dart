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
///   ext.acro.citygame?knob=NAME&value=V a perf trade-off by name, live
///                                  (`PerfKnobs`, as the city studio drives
///                                  them): `agentsDrawn=0` takes the
///                                  vehicle draws out without a rebuild,
///                                  which is how the renderer is bisected
///   ext.acro.camera?elevationDeg=&azimuthDeg=&rangeM=
///                                  aim the camera, for framing the shot
///   ext.acro.roadtool              the road tool, driven by name through
///                                  the paths a player's input takes:
///       tool=road|traffic|look  mode=straight|curved|freeform|upgrade
///       type=(a RoadType.id)  elev=(metres)|up|down  step=3|6|12
///       snap=roads,angles,grid,guides (the set ON)  view=routes|junctions|adjust
///       hover=fx,fy  click=fx,fy  rclick=fx,fy  drag=fx0,fy0,fx1,fy1
///       key=pageUp|pageDown|escape            (fx,fy: screen fractions)
///     returns mode, type, elevation, anchor, the last quote, blocked,
///     roads, funds and road upkeep.
///
/// The colony runs agent traffic unless `--dart-define=AGENTS=false`, and
/// `ext.acro.citygame` drives it (docs/plans/agent-traffic.md §16.4), each
/// parameter reporting what it did under `did`:
///
///   agents=on|off                  switch the colony's agents
///   road=add&pts=e,n;e,n&class=I   commit a road (RoadClass index I)
///   traffic=spawn&n=K[&from=&to=]  force K car trips, homes to jobs
///   step=S                         run the colony S seconds headless
///   vehicle=H                      one vehicle, its route lane by lane
///   traffic=stats | graph=audit    the agents' numbers; their lane graph
///   site=plan&id=SITE              a site's access plan as JSON
///                                  (docs/plans/site-access.md §4)
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
import 'domain/colony/city/site_access/site_access_book.dart';
import 'domain/colony/city/traffic/agent_kind.dart';
import 'domain/colony/city/traffic/building_table.dart';
import 'domain/colony/city/traffic/city_agents.dart';
import 'domain/colony/city/traffic/slot_pool.dart';
import 'domain/planetary/planet_surface.dart';
import 'domain/universe/real_solar_system.dart';
import 'infrastructure/baked_terrain_data.dart';
import 'infrastructure/flutter/sim_view_control.dart';
import 'infrastructure/flutter/simulation_view.dart';
import 'infrastructure/flutter/windows_key_event_workaround.dart';
import 'infrastructure/flutter_scene/city/city_nodes.dart';
import 'infrastructure/flutter_scene/perf_knobs.dart';
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
    agentTraffic: const bool.fromEnvironment('AGENTS', defaultValue: true),
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
    // Step out onto the streets (G), or back. Through the view's own toggle,
    // so a driver gets the mouse capture a player would.
    if (params['walk'] != null) {
      SimViewControl.instance.setWalk?.call(params['walk'] == 'on');
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
    // knob=<name>&value=<v>: any perf trade-off by name, live, exactly as
    // `main_city_studio_dev` drives them (docs/plans/agent-traffic.md
    // §15.5). Here because the City Builder is where the renderer is bisected
    // and a Windows profile rebuild is a three-minute round trip: turning
    // `agentsDrawn` off, or `agentRenderCap` down, says whether a fault is in
    // the vehicle draws without touching a line of code.
    final knob = params['knob'];
    final knobOk = knob == null || PerfKnobs.set(knob, params['value'] ?? '');
    final did = _agentHooks(colony, params);
    final view = SimViewControl.instance.status?.call() ?? const {};
    return developer.ServiceExtensionResponse.result(jsonEncode({
      ..._status(colony),
      if (knob != null) 'knobs': PerfKnobs.snapshot(),
      if (!knobOk) 'error': 'unknown knob or bad value: $knob',
      if (did.isNotEmpty) 'did': did,
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
          'walk',
          'azimuth',
          'pointerLockSupported',
          'pointerLockCaptured',
        ])
          k: view[k],
      },
    }));
  });

  // The road tool, driven through the view (SimViewControl.roadTool) so a
  // scripted click is picked, snapped, priced and drawn exactly as a real
  // one — the only way to see the tool's ghost and its bill without a hand
  // on the mouse.
  developer.registerExtension('ext.acro.roadtool', (method, params) async {
    final drive = SimViewControl.instance.roadTool;
    if (drive == null) {
      return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError, 'no view yet');
    }
    try {
      return developer.ServiceExtensionResponse.result(
          jsonEncode(drive(params)));
    } catch (e) {
      return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError, '$e');
    }
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
      'agents': _agentsStatus(c.agents),
    };

/// The status's `agents` block (docs/plans/agent-traffic.md §16.4): slice
/// 1's share of it, with no citizens, pedestrians, parking, services or
/// stubs yet.
Map<String, Object?> _agentsStatus(CityAgents a) {
  final s = a.stats;
  return {
    'enabled': a.enabled,
    'vehicles': a.liveVehicles,
    'pathQueue': a.pathQueue?.length ?? 0,
    'deferred': s.deferred,
    'flow': 1 - s.congestionIndex,
    'avgTripS': s.avgTripS,
    'despawn': {
      'stuck': s.despawnStuck,
      'wedge': s.despawnWedge,
      'edit': s.despawnEdit,
    },
    'held': {'ticks': a.heldTicks, 'cityS': a.heldCityS},
    'graph': _graphCounts(a),
    'tickMs': a.metrics.avgTickMs,
  };
}

/// The agent traffic's dev hooks (§16.4, E25), in the order they run:
/// `agents=on|off`; `road=add&pts=e,n;e,n&class=<index>`, a road committed
/// the generator's way, to exercise a remap live (`ext.acro.roadtool` lays
/// one the player's way); `traffic=spawn&n=<k>[&from=<site>&to=<site>]`,
/// car trips between random homes and workplaces unless told;
/// `step=<cityS>`; `vehicle=<handle>`; `traffic=stats`; `graph=audit`.
/// What each did, by name.
Map<String, Object?> _agentHooks(CitySim c, Map<String, String> p) {
  final a = c.agents;
  final did = <String, Object?>{};
  final on = p['agents'];
  if (on != null) {
    a.enabled = on == 'on';
    did['agents'] = a.enabled;
  }
  if (p['road'] == 'add') {
    final pts = _points(p['pts']);
    final i = int.tryParse(p['class'] ?? '') ?? RoadClass.street.index;
    final cls = RoadClass.values[i.clamp(0, RoadClass.values.length - 1)];
    did['road'] = pts.length < 2 ? null : c.commitRoad(pts, cls);
  }
  if (p['traffic'] == 'spawn') {
    final n = (int.tryParse(p['n'] ?? '') ?? 1).clamp(0, 4096);
    did['spawn'] = _spawn(c, n, p['from'], p['to']);
  }
  final step = double.tryParse(p['step'] ?? '');
  if (step != null && step > 0) did['step'] = _step(c, step);
  final h = int.tryParse(p['vehicle'] ?? '');
  if (h != null) did['vehicle'] = a.describe(h);
  if (p['traffic'] == 'stats') did['traffic'] = _trafficStats(c);
  if (p['graph'] == 'audit') did['graph'] = _graphAudit(a);
  if (p['site'] == 'plan') did['site'] = _sitePlan(c, p['id']);
  return did;
}

/// `site=plan&id=<siteId>` (docs/plans/site-access.md §9 R2): the site's
/// access plan as JSON, whether it is current for the colony's road graph,
/// stale, or an easement, and what the book's last sync did.
Map<String, Object?> _sitePlan(CitySim c, String? id) {
  final book = c.siteAccess;
  final plan = id == null ? null : book.planOf(id);
  return {
    'id': id,
    'slot': id == null ? -1 : book.slotOf(id),
    'current': id != null && book.isCurrentFor(id, c.roadGraph),
    'stale': id != null && book.isStale(id),
    'easementFor': id == null ? null : book.easementOf(id),
    'sitesRev': book.sitesRev,
    'chunks': book.chunks.length,
    'lastSync': book.lastSync.toJson(),
    'plan': plan == null ? null : sitePlanJson(plan),
  };
}

/// `e,n;e,n;…` as colony-local points; a malformed pair is skipped.
List<Vec2> _points(String? s) {
  final out = <Vec2>[];
  for (final pair in (s ?? '').split(';')) {
    final xy = pair.split(',');
    if (xy.length != 2) continue;
    final e = double.tryParse(xy[0]), n = double.tryParse(xy[1]);
    if (e != null && n != null) out.add(Vec2(e, n));
  }
  return out;
}

/// [n] car trips from [from] to [to], or between random built homes and
/// workplaces: the trips' handles, and how many were refused (agents off,
/// no building there, or a cap).
Map<String, Object?> _spawn(CitySim c, int n, String? from, String? to) {
  final homes = <String>[], works = <String>[];
  for (final (lot, s) in c.parcelBuiltLots()) {
    if (s.housing > 0) homes.add(lot.id);
    if (s.jobs > 0) works.add(lot.id);
  }
  final rnd = math.Random();
  String? pick(List<String> of) =>
      of.isEmpty ? null : of[rnd.nextInt(of.length)];
  final trips = <int>[];
  var refused = 0;
  for (var i = 0; i < n; i++) {
    final f = from ?? pick(homes), t = to ?? pick(works);
    final trip =
        f == null || t == null ? SlotPool.none : c.agents.forceTrip(f, t);
    if (trip == SlotPool.none) {
      refused++;
    } else {
      trips.add(trip);
    }
  }
  return {'trips': trips, 'refused': refused};
}

/// Runs [c] [cityS] seconds headless, now, in half-second ticks: the frame
/// hold first plays out what it had queued, and holds nothing meanwhile, so
/// the reply comes once the colony has advanced.
Map<String, Object?> _step(CitySim c, double cityS) {
  final a = c.agents;
  final held = a.frameBudgeted;
  a
    ..flushHeld()
    ..frameBudgeted = false;
  final t0 = a.timeUs;
  try {
    for (var i = 0; i < (cityS / 0.5).round(); i++) {
      c.advance(0.5);
    }
  } finally {
    a.frameBudgeted = held;
  }
  return {'cityS': cityS, 'agentS': (a.timeUs - t0) / 1e6};
}

/// The agents' numbers in full, for `traffic=stats`.
Map<String, Object?> _trafficStats(CitySim c) {
  final a = c.agents, s = a.stats, m = a.metrics, t = a.vehicles;
  // For `vehicle=`: the first few on the road, in slot order.
  final handles = <int>[];
  if (t != null) {
    for (var sl = 0; sl < t.highWater && handles.length < 16; sl++) {
      if (t.isSlotLive(sl)) handles.add(t.handleOf(sl));
    }
  }
  return {
    'spawned': s.spawned,
    'arrived': s.arrived,
    'arrivedGone': s.arrivedGone,
    'replans': s.replans,
    'appendedLegs': s.appendedLegs,
    'lanesRepaired': s.lanesRepaired,
    'remapNudges': s.remapNudges,
    'deferred': s.deferred,
    'noRoute': s.noRoute,
    'commutes': {
      'done': s.tripsDone,
      'tripRatio': s.tripRatio,
      'avgTripS': s.avgTripS,
      'failedShare': s.failedShare,
      'commuteEff': s.commuteEff,
      'staffing': c.staffing,
    },
    'congestion': {
      'index': s.congestionIndex,
      'peak': s.peakCongestion,
      'average': s.averageCongestion,
      'pictures': a.pictures,
      'parcel': c.parcelCongestion,
    },
    'pathQueue': {
      'queued': a.pathQueue?.length ?? 0,
      'fallbacks': a.pathQueue?.fallbacks ?? 0,
      'waitingToPullOut': a.planner?.waiting ?? 0,
    },
    'moves': {
      'handOvers': a.mover?.handOvers ?? 0,
      'lineStops': a.mover?.lineStops ?? 0,
    },
    'tickMs': {'last': m.lastTickMs, 'avg': m.avgTickMs, 'max': m.maxTickMs},
    'handles': handles,
  };
}

/// The lane graph's size and where cars turn round or run out of road: the
/// status's `agents.graph`.
Map<String, Object?> _graphCounts(CityAgents a) {
  final lg = a.laneGraph;
  var deadEnds = 0, decks = 0;
  if (lg != null) {
    for (var n = 0; n < lg.nodeCount; n++) {
      final k = lg.kindOf(n);
      if (k == NodeControlKind.deadEnd) deadEnds++;
      if (k == NodeControlKind.danglingDeck) decks++;
    }
  }
  return {
    'rev': a.graphRev,
    'nodes': lg?.nodeCount ?? 0,
    'edges': lg?.edgeCount ?? 0,
    'lanes': lg?.laneCount ?? 0,
    'connectors': lg?.connectorCount ?? 0,
    'deadEnds': deadEnds,
    'danglingDecks': decks,
  };
}

/// The lane graph audited, for `graph=audit` (C6): node kinds, edges
/// outside the network's main strongly connected part, lots with no road,
/// and buildings trips cannot reach (no serving edge) or cannot leave and
/// return to (isolated).
Map<String, Object?> _graphAudit(CityAgents a) {
  final lg = a.laneGraph;
  if (lg == null) return {'built': false};
  final kinds = <String, int>{};
  for (var n = 0; n < lg.nodeCount; n++) {
    final k = lg.kindOf(n).name;
    kinds[k] = (kinds[k] ?? 0) + 1;
  }
  var stranded = 0;
  for (var e = 0; e < lg.edgeCount; e++) {
    if (lg.edgeInMainScc[e] == 0) stranded++;
  }
  final g = lg.graph;
  var lotsWithout = 0;
  for (var i = 0; i < g.lotCount; i++) {
    if (g.lotPiece[i] < 0) lotsWithout++;
  }
  var noAccess = 0, isolated = 0;
  final b = a.buildings;
  if (b != null) {
    for (var sl = 0; sl < b.highWater; sl++) {
      if (!b.isSlotLive(sl)) continue;
      if (b.accCount[sl] == 0) {
        noAccess++;
      } else if ((b.accessFlags[sl] & kAccessIsolated) != 0) {
        isolated++;
      }
    }
  }
  return {
    ..._graphCounts(a),
    'kinds': kinds,
    'strandedEdges': stranded,
    'lotsWithoutRoad': lotsWithout,
    'buildings': b?.liveCount ?? 0,
    'buildingsWithoutAccess': noAccess,
    'buildingsIsolated': isolated,
  };
}
