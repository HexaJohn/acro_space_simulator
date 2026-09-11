// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The colonies every traffic test drives (docs/plans/agent-traffic.md §17).
///
/// Founded headless, with every road COMMITTED — never `layout.addRoad` — so
/// a crossing splits both roads and the junction exists in the graph exactly
/// as a player-drawn pair would make it (road_graph_test.dart:70-75). And
/// quiet: every colony here has hostility 0 and its disaster timer pushed out
/// of reach, because `CitySim` still draws on an unseeded `math.Random()` in
/// some twenty places, and the disasters among them (grid fires, lot-fire
/// sparks) would otherwise make two runs of one scenario disagree for reasons
/// that have nothing to do with traffic.
///
/// The agents' own helpers — [agentsOn], [forceTrip], [routeOf], [laneOn],
/// [stall] — sit at the end. `freezeDelays` and `setDelay` arrive with the
/// delay table (slice 2). [starterKit] and [town] found a colony that runs
/// its OWN agents when asked (`agentTraffic`, E17), ticked by its advance.
library;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';

/// The solar system's bodies, built once per test file: every colony here is
/// founded on one of them, and building the system is not free.
final List<CelestialBody> fixtureBodies =
    RealSolarSystem.build().all.where((b) => !b.isStar).toList();

/// One road to commit: its control points, its class and, for a one-way road,
/// which way it runs.
class FixtureRoad {
  const FixtureRoad(this.points,
      {this.roadClass = RoadClass.street, this.reversed = false});

  final List<Vec2> points;
  final RoadClass roadClass;

  /// A one-way road's traffic runs last point to first.
  final bool reversed;
}

/// [city], made quiet: no hostility, and no disaster for a billion seconds.
CitySim quiet(CitySim city) => city
  ..hostility = 0
  ..autoDisasterTimer = 1e9;

/// A bare, quiet colony on Earth with [roads] committed in order.
///
/// Flat in the sense that matters: no ground probe goes to the commits, so no
/// road is refused for its grade and every road is draped, which is what the
/// road graph treats as ground level.
CitySim foundFlat({List<FixtureRoad> roads = const [], String id = 'traffic'}) {
  final city = quiet(CitySim.found(
    const CityConfig(bodyId: 'earth', gridSize: 20),
    bodies: fixtureBodies,
    id: id,
  ));
  for (final road in roads) {
    commit(city, road);
  }
  return city;
}

/// Commits [road] to [city] through the editor's own path — splits, lot
/// re-cut, renamed lots carried — and returns the new road's id.
String commit(CitySim city, FixtureRoad road) {
  final id =
      city.commitRoad(road.points, road.roadClass, reversed: road.reversed);
  if (id == null) {
    throw StateError('the colony refused the road through ${road.points}');
  }
  return id;
}

/// An [n] × [n] grid of [cls] roads centred on the origin, [spacingM] apart,
/// each overrunning the outermost cross roads by half a block. Every crossing
/// is then a four-leg junction, and the rim ends in short dead ends, which is
/// where the U-turns are.
///
/// Laid with the lot re-cut deferred and run once at the end: re-cutting
/// every lot on every commit is quadratic in roads (city_layout.dart), and
/// nothing is built yet, so no rename is lost.
CitySim grid(int n,
    [double spacingM = 200, RoadClass cls = RoadClass.street]) {
  final city = foundFlat(id: 'grid');
  final half = (n - 1) * spacingM / 2;
  final lo = -half - spacingM / 2;
  final hi = half + spacingM / 2;
  for (var i = 0; i < n; i++) {
    final at = -half + i * spacingM;
    city.commitRoad([Vec2(at, lo), Vec2(at, hi)], cls, regenerateLots: false);
    city.commitRoad([Vec2(lo, at), Vec2(hi, at)], cls, regenerateLots: false);
  }
  city.layout.regenerate();
  return city;
}

/// An avenue east–west across a street north–south, crossing at the origin.
///
/// The crossing splits the avenue into two arterial legs, and two arterial
/// legs are what the class-only warrant lights (road_junction.dart): the one
/// signalised junction two commits can build.
CitySim signalised({double halfLengthM = 300}) => foundFlat(
      id: 'signalised',
      roads: [
        FixtureRoad([Vec2(-halfLengthM, 0), Vec2(halfLengthM, 0)],
            roadClass: RoadClass.avenue),
        FixtureRoad([Vec2(0, -halfLengthM), Vec2(0, halfLengthM)]),
      ],
    );

/// The City Builder founding (`CityStarterKit.found`), quiet: the crossroads,
/// the spaceport, the utilities and the warehouse, on the [start] treasury;
/// with [agentTraffic], the colony's own agents on, as the play surface
/// founds it.
CitySim starterKit(
        {CityStart start = CityStart.relaxed,
        String body = 'earth',
        bool agentTraffic = false}) =>
    quiet(CityStarterKit.found(
      bodies: fixtureBodies,
      config: CityConfig(bodyId: body, gridSize: 20),
      start: start,
      agentTraffic: agentTraffic,
    ));

/// The mix [zoneAll] deals round the free lots: two homes to each shop and
/// each works, the mix the routed model's economy test grows from.
const List<ParcelUse> townMix = [
  ParcelUse.residential,
  ParcelUse.residential,
  ParcelUse.commercial,
  ParcelUse.industrial,
];

/// The street lots of [city] with nothing placed on them, in layout order.
List<Parcel> freeLots(CitySim city) => [
      for (final lot in city.layout.autoParcels)
        if (!city.parcelBuildings.containsKey(lot.id)) lot,
    ];

/// Zones every free street lot, dealing [uses] round them in layout order.
void zoneAll(CitySim city, [List<ParcelUse> uses = townMix]) {
  var k = 0;
  for (final lot in freeLots(city)) {
    city.layout.setUse(lot.id, uses[k++ % uses.length]);
  }
}

/// Puts the [density] building of its zone on every zoned free lot, as a
/// PLACED building: built at once, and stable, since growth never touches a
/// placed lot (`CitySim.advanceParcelGrowth`). The homes and jobs a test
/// starts with are then the ones it ends with.
void buildAll(CitySim city, {Density density = Density.low}) {
  for (final lot in freeLots(city)) {
    final zone = CitySim.zoneKindOf(lot.use);
    if (zone == null) continue;
    city.placeOnParcel(lot.id, kZoneSpecs[zone]![density]!);
  }
}

/// Grows every zoned free lot to [progress], as the player's demand would:
/// 1.0 is built and fully let at low density. Unlike [buildAll]'s, these lots
/// stay under demand — they densify while it lasts, and decay without it.
void growAll(CitySim city, {double progress = 1.0}) {
  for (final lot in freeLots(city)) {
    if (CitySim.zoneKindOf(lot.use) == null) continue;
    city.grownParcels[lot.id] = progress;
  }
}

/// Puts [spec] on [site]: false when the site is taken or unknown.
bool place(CitySim city, String site, CityBuildingSpec spec) =>
    city.placeOnParcel(site, spec);

/// A headless City Builder town: the starter kit, every free street lot
/// zoned in [townMix], and every one of them built — placed and stable, or
/// [grown] under demand the way a player's town is. [agentTraffic] as for
/// [starterKit].
CitySim town({bool grown = false, bool agentTraffic = false}) {
  final city = starterKit(agentTraffic: agentTraffic);
  zoneAll(city);
  if (grown) {
    growAll(city);
  } else {
    buildAll(city);
  }
  return city;
}

/// Advances [city] [seconds] of colony time in ticks of [dt], through
/// `CitySim.advance`, so everything a tick runs, runs. No frame hold unless a
/// test has set one.
void run(CitySim city, double seconds, {double dt = 0.5}) {
  final ticks = (seconds / dt).round();
  for (var i = 0; i < ticks; i++) {
    city.advance(dt);
  }
}

/// The street lot whose centroid is nearest [p].
Parcel lotNearest(CitySim city, Vec2 p) {
  Parcel? best;
  var bestM = double.infinity;
  for (final lot in city.layout.autoParcels) {
    final m = lot.centroid.distanceTo(p);
    if (m < bestM) {
      bestM = m;
      best = lot;
    }
  }
  if (best == null) throw StateError('the colony has no street lots');
  return best;
}

// ---- The agents -------------------------------------------------------------

/// Agents of the test's own on [city], switched on, beside the colony's
/// (which stay off): they read the colony and nothing in the colony reads
/// them, so the economy stands still while they run — exactly the scope
/// §17.4's partition test asks for.
CityAgents agentsOn(CitySim city) => CityAgents(city)..enabled = true;

/// Advances [agents] by [seconds] of agent time in ticks of [dt], calling
/// [each] after every tick.
void runAgents(CityAgents agents, double seconds,
    {double dt = 0.5, void Function()? each}) {
  final ticks = (seconds / dt).round();
  for (var i = 0; i < ticks; i++) {
    agents.advance(dt);
    each?.call();
  }
}

/// A trip between the buildings on two sites (§17's `forceTrip`): its trip
/// handle, or `SlotPool.none`.
int forceTrip(CityAgents agents, String fromSite, String toSite,
        {AgentKind kind = AgentKind.car}) =>
    agents.forceTrip(fromSite, toSite, kind: kind);

/// The vehicle [trip] is driving, or −1 while it is still planned or waiting
/// to pull out, or done.
int vehicleOfTrip(CityAgents agents, int trip) =>
    agents.commutes?.vehicleOf(trip) ?? -1;

/// [handle]'s remaining route as words that mean the same across two builds
/// of the network: each edge's road id, `+` along the road's line or `-`
/// against it, and the lane index.
List<String> routeOf(CityAgents agents, int handle) {
  final d = agents.describe(handle);
  if (d == null) return const [];
  return [
    for (final e in d['route'] as List<Map<String, Object?>>)
      '${e['road']}${e['forward'] == true ? '+' : '-'}${e['lane']}',
  ];
}

/// The road [handle] is on, or heading onto from a connector.
String roadOf(CityAgents agents, int handle) {
  final d = agents.describe(handle)!;
  return (d['route'] as List<Map<String, Object?>>).first['road']! as String;
}

/// The lane index [handle] drives road [roadId] in, or −1 when the rest of
/// its route does not use it.
int laneOn(CityAgents agents, int handle, String roadId) {
  final d = agents.describe(handle);
  if (d == null) return -1;
  for (final e in d['route'] as List<Map<String, Object?>>) {
    if (e['road'] == roadId) return e['lane']! as int;
  }
  return -1;
}

/// §17's `stall`: [handle] stops where it is, for good.
void stall(CityAgents agents, int handle) => agents.debugStall(handle);

/// A hash of [handle]'s locked route — its connectors, in order — wherever
/// in the arena its block now sits.
int routeHash(CityAgents agents, int handle) {
  final t = agents.vehicles!;
  final sl = SlotPool.slotOf(handle);
  var h = fnv1aU32(kFnvOffset32, t.routeLen[sl]);
  for (var i = 0; i < t.routeLen[sl]; i++) {
    h = fnv1aU32(h, t.arena.data[t.routeOff[sl] + i]);
  }
  return h;
}
