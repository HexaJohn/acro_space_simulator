// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// An AOT smoke run of the City Builder's FRAME: the dev colony grown to a
/// town, ticked the way the view ticks it (a frame-budgeted hold, replayed
/// by `endFrame`), its terrain shaped as the host shapes it, and captured
/// into a [WorldSnapshot] every frame — none of which
/// tool/aot_traffic_smoke.dart does.
///
/// Why it exists: T4a put the site poses and the parked-car columns on the
/// wire (lib/application/snapshot/traffic_capture.dart), and the City
/// Builder died with a native access violation about forty minutes of
/// colony time in, with every test green in the JIT and the traffic-only
/// smoke exiting 0. The readout's crash before it (e456be6) was found by
/// making the headless run do what the app does, so this run does what the
/// app's FRAME does:
///
/// - a `WorldSnapshot.capture` after every tick, with the terrain-edit
///   store the host keeps, so the drapes, the traffic geometry and the site
///   heights are re-derived as ground moves under a growing town;
/// - the tick held and replayed against the frame budget (§5.7), at a
///   display frame and now and then at the half second a warp feeds;
/// - a town: a grid of streets, every lot zoned, growth filling it, trips
///   forced BOTH ways so cars park AND leave;
/// - the agents switched off and on, a road laid under a driving town, and
///   a save reloaded through `AgentsCodec`;
/// - the published columns read the way a renderer reads them.
///
/// It prints what it covered — the site phases seen above all, because a
/// green run that placed no car in a lot proves nothing, and the first
/// version of this harness reached none of the departure phases at all.
/// With every branch of `TrafficCapture`'s `_poseOf` reached — lane, stall
/// and back-out — and the parked columns rebuilt under a moving site
/// revision, the run still exits 0: the crash the City Builder takes is NOT
/// in the capture's Dart.
///
/// The run is deterministic, so repeating it tells you nothing; the SEED
/// argument is what puts a different town under the capture.
///
///     dart compile exe tool/aot_capture_smoke.dart -o build/aot_capture.exe
///     build/aot_capture.exe [captures] [assets/terrain] [seed]
///
/// A native crash exits this process non-zero;
/// test/traffic/bench/aot_capture_smoke_test.dart compiles and runs it (a
/// bench: `--dart-define=ACRO_BENCH=true`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_vehicles.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/planetary/planet_surface.dart';
import 'package:acro_space_simulator/domain/terrain/dem_pyramid.dart';
import 'package:acro_space_simulator/domain/terrain/dem_registry.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';

/// A stand-in for a player picking a home and a workplace, by the domain's
/// own rule (no `math.Random` anywhere the sim can see it).
///
/// Seeded, because the whole run is deterministic — two runs of one build
/// print the same phase histogram to the vehicle — so the only way to put a
/// DIFFERENT town under the capture is to ask for one. The harness's third
/// argument is this seed; it moves the trips, the street grid and the
/// zoning mix together.
class _Rng {
  _Rng(this._s);

  int _s;

  int next(int n) {
    _s = (_s * 1103515245 + 12345) & 0x3fffffff;
    return n <= 0 ? 0 : _s % n;
  }
}

/// The baked pyramids under [dir], registered as the boot loader does: the
/// capture asks the ground for every road drape and every pad, and a body
/// whose catalogue declares a DEM throws without them (`DemRegistry`). The
/// live colony stands on real relief, so this one must too.
void _registerDems(String dir) {
  final d = Directory(dir);
  if (!d.existsSync()) {
    throw StateError('$dir missing — run this from the repo root, or pass '
        'the terrain directory as the second argument');
  }
  for (final f in d.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (!name.endsWith('.acrodem')) continue;
    final id = name.substring(0, name.length - '.acrodem'.length);
    if (DemRegistry.contains(id)) continue;
    DemRegistry.register(id, DemPyramid.decode(f.readAsBytesSync()));
  }
}

void main(List<String> args) {
  final ticks = args.isEmpty ? 12000 : int.parse(args.first);
  _registerDems(args.length > 1 ? args[1] : 'assets/terrain');
  final seed = args.length > 2 ? int.parse(args[2]) : 0;
  final system = RealSolarSystem.build();
  final bodies = system.all.where((b) => !b.isStar).toList();
  final vessels = InMemoryVesselRepository(const []);
  final edits = InMemoryTerrainEditsRepository();
  const shaper = CityTerrainShaper();
  final rng = _Rng(0x2545f49 + seed * 7919);
  late CitySim city;
  late InMemoryCityRepository cities;
  late CityAgents agents;

  /// The colony this run drives from here. Called again after a save and a
  /// load, which is a different object: the codec's restore (T4a's cars and
  /// their sites) is a path the traffic-only smoke never takes.
  void adopt(CitySim c) {
    city = c
      ..funds = 1e12
      ..ignoreUnlocks = true;
    cities = InMemoryCityRepository([c]);
    agents = c.agents..frameBudgeted = true;
  }

  adopt(CityStarterKit.found(
    bodies: bodies,
    config: const CityConfig(
        bodyId: 'earth',
        latitude: -45.03,
        longitude: 168.66,
        biome: Biome.forest),
    start: CityStart.standard,
    id: 'city-dev',
    name: 'Dev Colony',
    agentTraffic: true,
  ));

  var captures = 0, trips = 0, refused = 0;
  var tick = 0;
  var posesSeen = 0, maxPoses = 0, maxParked = 0, reloads = 0;
  var sink = 0.0;
  // Site phases seen, so a green run cannot hide a branch of the capture's
  // `_poseOf` that never ran: a stall turn-in, a pull-out and a home
  // back-out are three different curves, and the back-out is the one the
  // hand-over fix (5ec9ff2) moved.
  final phases = List<int>.filled(SitePhase.values.length, 0);

  /// The terrain a colony's new work implies, recorded as
  /// `AdvanceSimulationTick._shapeCityTerrain` does it: a levelled pad, a
  /// graded corridor. Every brush laid forgets the ground cached under it,
  /// which is what makes the capture re-drape a road, re-slice the traffic
  /// geometry and rebuild the site heights — the churn a growing town
  /// really puts the capture through, and which no fixed-ground run sees.
  void shape() {
    final body = system.body(city.body.id);
    if (body == null) return;
    final held = edits.forBody(body.id);
    for (final p in shaper.pending(city,
        bodyRadiusM: body.radius,
        tick: tick,
        groundRadiusAt: (dirBF) {
          final f = body.terrainFieldWith(held);
          return f == null
              ? body.radius
              : f.groundRadiusAt(dirBF.x, dirBF.y, dirBF.z);
        })) {
      edits.record(body.id, p.brush);
      CityTerrainShaper.markShaped(city, p.key, p.brush);
    }
  }

  /// One frame as `SimulationView` runs it: the colony advanced by a display
  /// frame (the tick held), the hold replayed against the frame budget, then
  /// the world captured — the capture LAST, on the state the frame will
  /// draw.
  ///
  /// A DISPLAY frame mostly — 1/60 s, not the half-second the traffic-only
  /// smoke ticks, because the live app captures thirty times a colony
  /// second and so samples every manoeuvre thirty times as finely — and
  /// every eighth frame the half-second a warp really feeds it, which steps
  /// straight over states the fine one lands on. Both cadences, so neither
  /// is the only one the capture has ever seen.
  void frame() {
    city.advance(captures % 8 == 7 ? 0.5 : 1 / 60);
    agents.endFrame();
    shape();
    final snap = WorldSnapshot.capture(tick++, vessels,
        system: system, cities: cities, terrainEdits: edits);
    captures++;
    final cols = agents.siteVehicles, table = agents.vehicles;
    if (cols != null && table != null) {
      for (var sl = 0; sl < table.highWater; sl++) {
        if (table.isSlotLive(sl)) phases[cols.phase[sl]]++;
      }
    }
    // What the frame actually carried, so a run that placed no car in a lot
    // cannot be mistaken for a run that proved the placing safe. Reading the
    // columns is also what a renderer does with them.
    for (final f in snap.cityTraffic) {
      final p = f.sitePoses;
      posesSeen += p.count;
      if (p.count > maxPoses) maxPoses = p.count;
      for (var i = 0; i < p.count; i++) {
        sink += p.e[i] + p.n[i] + p.up[i] + p.dirE[i] + p.dirN[i];
        if (p.row[i] >= 0 && p.row[i] < f.agents.count) {
          sink += f.agents.kind[p.row[i]] + f.agents.flags[p.row[i]];
        }
      }
      final k = f.parked;
      if (k.lotCount > maxParked) maxParked = k.lotCount;
      for (var i = 0; i < k.lotCount; i++) {
        sink += k.lotE[i] + k.lotN[i] + k.lotUp[i] + k.lotDirE[i] + k.lotDirN[i];
        sink += k.lotSite[i] + k.lotStall[i] + k.lotKind[i] + k.lotVariant[i];
      }
    }
  }

  /// [cityS] seconds run headless, as `ext.acro.citygame?step=` does: the
  /// hold flushed, the budget off, no capture in between.
  void step(double cityS) {
    final held = agents.frameBudgeted;
    agents
      ..flushHeld()
      ..frameBudgeted = false;
    try {
      for (var i = 0; i < (cityS / 0.5).round(); i++) {
        city.advance(0.5);
        shape();
      }
    } finally {
      agents.frameBudgeted = held;
    }
  }

  /// Every free street lot zoned, the mix the dev colony grows on.
  void zoneAll() {
    const uses = [
      ParcelUse.residential,
      ParcelUse.residential,
      ParcelUse.commercial,
      ParcelUse.industrial,
    ];
    var k = seed;
    for (final lot in city.layout.autoParcels.toList()) {
      if (city.parcelBuildings.containsKey(lot.id)) continue;
      if (lot.use != ParcelUse.unzoned) continue;
      city.layout.setUse(lot.id, uses[k++ % uses.length]);
    }
  }

  /// [n] forced trips between built homes and workplaces, the dev hook's
  /// own `traffic=spawn` — BOTH ways, alternately.
  ///
  /// The way home matters as much as the way out: a car that only ever
  /// arrives parks and stays, and the capture then never places one pulling
  /// out of a stall or reversing down a drive (`stallOut`, `backOut`,
  /// `shift`) — three of `_poseOf`'s branches, including the one the
  /// hand-over fix moved. The phase histogram this run prints is what
  /// proved it: home-to-work trips alone left them at zero.
  void spawn(int n) {
    final homes = <String>[], works = <String>[];
    for (final (lot, s) in city.parcelBuiltLots()) {
      if (s.housing > 0) homes.add(lot.id);
      if (s.jobs > 0) works.add(lot.id);
    }
    if (homes.isEmpty || works.isEmpty) {
      refused += n;
      return;
    }
    for (var i = 0; i < n; i++) {
      final h = homes[rng.next(homes.length)];
      final w = works[rng.next(works.length)];
      final out = rng.next(2) == 0;
      final t = agents.forceTrip(out ? h : w, out ? w : h);
      if (t == SlotPool.none) {
        refused++;
      } else {
        trips++;
      }
    }
  }

  /// The colony saved and loaded, as the City Builder's save does: the
  /// agents' block goes out through `AgentsCodec` and comes back, parked
  /// cars, sites and all (T4a's D, and 17b9e50's garaged car). The frame
  /// hold is flushed first, because a save is the colony as of its clock.
  void reload() {
    agents.flushHeld();
    final json =
        jsonDecode(jsonEncode(city.toJson())) as Map<String, dynamic>;
    adopt(CitySim.fromJson(json, bodies: bodies));
    reloads++;
  }

  // ---- The run the live session took, then well past it ---------------------
  // A founding colony idle at the frame rate (75 s of it killed nothing);
  // then zoned, with cars driving; then grown by long headless steps with
  // more trips forced over them; then left idle, capturing, which is where
  // the City Builder died about 100 s later.
  //
  // [ticks] buys the whole run: the growth rounds first — each is what
  // `step=600` plus a stretch of drawn frames did — and whatever is left
  // goes on the idle tail. Half and half, so a short bench still grows a
  // town and still idles over it.
  final rounds = (((ticks - 750) ~/ 2) ~/ 630).clamp(2, 40);
  for (var i = 0; i < 150; i++) {
    frame();
  }
  // A town, not a crossroads: a grid of streets off the starter kit's, so
  // the plat cuts hundreds of lots and the book plans hundreds of sites.
  // The crash wanted a town that growth had filled, and the starter
  // crossroads alone cuts 86 lots.
  const half = 900.0;
  for (var k = -2; k <= 2; k++) {
    if (k == 0) continue;
    final at = k * (220.0 + (seed % 5) * 9);
    city.commitRoad([Vec2(at, -half), Vec2(at, half)], RoadClass.street);
    city.commitRoad([Vec2(-half, at), Vec2(half, at)], RoadClass.street);
  }
  zoneAll();
  for (var i = 0; i < 600; i++) {
    if (i % 30 == 0) spawn(2);
    frame();
  }
  // Growth: each round a long headless step, more trips, more lots zoned as
  // the plat cuts them, and a stretch of captured frames over the result —
  // sites appear and are re-planned under the parked cars while the capture
  // is reading them, which is the state the crash needed.
  for (var round = 0; round < rounds; round++) {
    step(600);
    zoneAll();
    spawn(12);
    // The three things a live session does that a steady tick does not:
    // the agents switched off and on (their tables start afresh), a road
    // laid under a town that is already driving on it (a remap, with cars
    // in lots the whole time), and a save reloaded.
    if (round % 7 == 3 && round + 1 < rounds) {
      agents.enabled = false;
      for (var i = 0; i < 30; i++) {
        frame();
      }
      agents.enabled = true;
    }
    if (round % 5 == 2) {
      final at = 110.0 + round * 7;
      city.commitRoad([Vec2(-900, at), Vec2(900, at)], RoadClass.street);
    }
    if (round % 11 == 6) reload();
    for (var i = 0; i < 600; i++) {
      frame();
    }
    stdout.writeln('  round $round: rss '
        '${(ProcessInfo.currentRss / (1 << 20)).round()} MiB, '
        'pop ${city.population} '
        'grown ${city.grownParcels.length}/${city.layout.parcels.length} '
        'housing ${city.housing} jobs ${city.jobs} '
        'live ${agents.liveVehicles} done ${agents.stats.tripsDone} '
        'parked ${agents.parkedCars?.count ?? 0} '
        'poses $maxPoses/$maxParked');
  }
  // Idle, at the frame rate, for as long as it takes: the rest of the run,
  // with cars still driving into lots and parking — which is exactly where
  // the City Builder died, a hundred seconds after the last thing anyone
  // touched.
  spawn(10);
  while (captures < ticks) {
    if (captures % 300 == 0) spawn(3);
    frame();
  }

  final r = city.trafficReadout;
  final cars = agents.parkedCars;
  stdout.writeln('aot capture smoke: seed $seed, $captures captures, '
      'pop ${city.population}, lots ${city.layout.parcels.length}, '
      'grown ${city.grownParcels.length}, sites ${city.siteAccess.sitesRev}, '
      '$trips trips ($refused refused), ${agents.stats.spawned} spawned, '
      '${agents.stats.tripsDone} done, parked ${cars?.count ?? 0}, '
      '${r.passes} passes, site poses $posesSeen (peak $maxPoses), '
      'peak parked rows $maxParked, $reloads reloads, '
      'sink ${sink.isFinite}');
  // The waiting counters: a car that never gets its gap accumulates one
  // sub-step a sub-step, and the run is long enough in colony time to say
  // whether any of them has run away. Both saturate now rather than wrapping
  // past 2^31 (traffic_time.dart, "clocks that only count up"), so a
  // NEGATIVE worst here is a defect and not a long wait — which is how the
  // wrap was found in the first place.
  final st = agents.siteVehicles, vt = agents.vehicles;
  var worstWait = 0, worstRoad = 0, waiting = 0;
  if (st != null && vt != null) {
    for (var sl = 0; sl < vt.highWater; sl++) {
      if (!vt.isSlotLive(sl)) continue;
      if (st.phase[sl] != SitePhase.none.index) waiting++;
      if (st.waitMs[sl].abs() > worstWait.abs()) worstWait = st.waitMs[sl];
      if (vt.waitUs[sl].abs() > worstRoad.abs()) worstRoad = vt.waitUs[sl];
    }
  }
  stdout.writeln('  waits: $waiting on sites, worst site waitMs $worstWait, '
      'worst road waitUs $worstRoad, '
      '${agents.siteStats.backOutForced} back-outs forced, '
      '${agents.siteStats.backOutGiveUps} given up, '
      '${agents.siteStats.throatGiveUps} throats given up, '
      '${agents.siteStats.gateGiveUps} gates given up '
      '(${agents.siteStats.gateCrossGiveUps} on the crossing)');
  stdout.writeln('  site phases seen: ${[
    for (var i = 0; i < phases.length; i++)
      if (phases[i] > 0) '${SitePhase.values[i].name}=${phases[i]}'
  ].join(', ')}');
}
