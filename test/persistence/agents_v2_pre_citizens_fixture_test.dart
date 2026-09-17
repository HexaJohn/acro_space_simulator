// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A REAL SAVE, taken from the build of the day before slice 3 ports the
/// parked cars' owners, and the load that must keep working after it
/// (docs/plans/agent-traffic.md §14.1, §14.4; site-access.md §7.5).
///
/// **What the file is.** `test/persistence/fixtures/agents_v2_t4a_pre_citizens.json`
/// is `CitySim.toJson()` of the dev colony the City Builder founds, grown,
/// parked and re-platted by the generator at the end of this file, captured
/// on 2026-09-17 from `feat/agent-traffic` at T4a (`64d6604`). Its `agents`
/// block is `v: 2` and carries the T4a rows
/// `[ownerKind, ownerIdx, where, siteIdx, stallKey | e, n, headingMilli,
/// kind, variant]` (§4 Q2, site-access §7.5), keyed by `(siteId, stallKey)`.
///
/// **What is in it.** 67 parked cars over 58 sites, in 16 KB: 56 on lot
/// stalls, 5 at the kerb, 6 garaged. By owner, `commuter` and `homePool`
/// both; by kind, 63 `car` and 4 `truck`. By site PROGRAM — because stall
/// identity is the program's, not the car's, and a home pad's inline stalls
/// are the likeliest to renumber under a later change — 37 cars on home
/// driveways, 17 in car parks, 2 in installation yards, and 3 garaged at
/// `kerbOnly` sites that have no lot at all. Eleven of the lot cars stand on
/// lots the re-cut RENAMED before the save ([kRenamedSites]).
///
/// **Why it must never be regenerated.** Slice 3 replaces the OWNER of a lot
/// car: citizens become a new `CarOwnerKind`, and a commuter car's
/// `ownerIdx` stops meaning a building handle and starts meaning a citizen.
/// The row's SHAPE does not change, so a save a player took today must still
/// load then — every car on its own stall, with the `where`, `kind` and
/// `variant` it was saved with. A round-trip test inside one build cannot
/// say anything about that: it writes and reads the NEW meaning and passes
/// while the player's older save quietly re-owns its cars. Only bytes
/// written by the older build can. Regenerating this file under slice 3
/// would therefore delete the only evidence there is, which is why the
/// generator below is skipped unless it is asked for by name, and why the
/// test never writes the file.
///
/// **What slice 3 must not break.** Every assertion here is about the
/// columns the owner port does NOT own:
///
/// - every saved lot car comes back on the stall its `(siteId, stallKey)`
///   names, and the site row agrees that the car is on it;
/// - `where`, `kind` and `variant` come back per car;
/// - the counts by `where` come back as saved — no car invented, none lost;
/// - a car whose site is still standing but has NO lot row is garaged at its
///   building, not dropped (the 17b9e50 rule: a kerbside plan and a plan not
///   yet made both answer −1 to `rowOfSite`, and only a building the colony
///   no longer has takes its cars with it);
/// - the block is still `v: 2`, and a build that can only read v1 is
///   entitled to drop it whole rather than half-read it (§14.4).
///
/// The owner columns are deliberately NOT asserted per car. They are what
/// slice 3 is allowed to reinterpret, and a test that pinned them would fail
/// for the one change everybody expects while saying nothing about the ones
/// nobody does. What is checked of them is only that the FILE carries more
/// than one `CarOwnerKind`, so the port has both kinds in front of it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/parked_cars.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/planetary/planet_surface.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// The committed save. Read, never written, by everything above the
/// generator.
const String kFixturePath =
    'test/persistence/fixtures/agents_v2_t4a_pre_citizens.json';

/// Site ids the re-cut RENAMED before the save (`_carryRenamedLots`, E12):
/// the road commit split the roads these lots hang off, and the plat re-hung
/// and re-named them with their buildings, their plans and their stall keys
/// carried across (A10). They are the most valuable rows in the file —
/// `siteId` and `stallKey` there are exactly what a naive rebuild from the
/// layout would NOT agree with — so they are named rather than left to be
/// found among the rest.
const List<String> kRenamedSites = <String>[
  'lot-r0x1x0-l2',
  'lot-r0x1x0-l4',
  'lot-r0x1x0-r3',
  'lot-r0x1x0-r4',
  'lot-r0x1x1-l0',
  'lot-r0x1x1-l2',
  'lot-r0x1x1-l3',
  'lot-r0x1x1-r1',
  'lot-r0x1x1-r2',
  'lot-r0x1x1-r3',
  'lot-r1x1-r0',
];

/// The site whose building still stands with no LOT to park in: a hand-drawn
/// lot with no frontage, which the book has no frame to plan from and demotes
/// to `kerbOnly` (site-access §3.3). Its car was saved garaged and must come
/// back garaged AT IT.
const String kLotlessSite = 'lot-m4';

void main() {
  // The load's own advance must be the quiet one the fixture was taken with:
  // a colony that spawned a commute in the same tick would park a car this
  // file never held.
  setUp(() => AgentTuning.commuteRatePerResident = 0);
  tearDown(AgentTuning.reset);

  test('the file is a v2 T4a agents block with cars of every where', () {
    final saved = _saved;
    expect(saved.version, 2,
        reason: 'the version a block carrying the T4a columns says (§14.4): '
            'a build that reads only the flag drops it whole');
    expect(saved.enabled, isTrue, reason: 'the colony runs agents');
    expect(saved.rows, isNotEmpty);
    expect(saved.sites, isNotEmpty);
    expect(saved.sites, orderedEquals([...saved.sites]..sort()),
        reason: 'the string table is sorted, so a save is deterministic '
            '(§14.1)');

    // Every row is one of the two shapes §4 Q2 defines, and nothing else.
    for (final r in saved.rows) {
      expect(r.length, CarWhere.values[r[2].toInt()] == CarWhere.kerb ? 8 : 7,
          reason: 'a kerb row carries (e, n, headingMilli); a lot or garaged '
              'row carries (siteIdx, stallKey): $r');
    }

    expect(saved.lot, isNotEmpty, reason: 'cars on stalls');
    expect(saved.kerb, isNotEmpty, reason: 'cars at the kerb');
    expect(saved.garaged, isNotEmpty, reason: 'cars taken out of the world');
    expect(saved.ownerKinds.length, greaterThan(1),
        reason: 'more than one CarOwnerKind, so the slice 3 port has both in '
            'front of it: ${saved.ownerKinds}');
    expect(saved.kinds.length, greaterThan(1),
        reason: 'more than one AgentKind, so a build that defaulted the kind '
            'column to `car` would be caught: ${saved.kinds}');
  });

  test('every saved lot car comes back on the stall its (siteId, stallKey) '
      'names, with its where, kind and variant', () {
    final saved = _saved;
    final city = _load();
    final a = city.agents;
    final cars = a.parkedCars!;
    final sites = a.sites!;
    final buildings = a.buildings!;

    final gotLot = <String>[], gotKerb = <String>[], gotGaraged = <String>[];
    for (var i = 0; i < cars.pool.highWater; i++) {
      if (!cars.pool.isSlotLive(i)) continue;
      final b = cars.building[i];
      final site = b >= 0 ? buildings.siteId[b] : '';
      switch (CarWhere.values[cars.where[i]]) {
        case CarWhere.lot:
          // Not just the columns: the SITE agrees. The stall the car stands
          // on is the one its key names, and the site's own stall table
          // points back at this car — which is what makes the restore a
          // parking and not a bookkeeping entry.
          final row = cars.row[i];
          expect(sites.isRowLive(row), isTrue);
          expect(sites.plan[row]!.stallKey(cars.stall[i]), cars.stallKey[i],
              reason: 'the key, never the stall index (C-19)');
          expect(sites.stallCar[sites.stallBase[row] + cars.stall[i]],
              cars.pool.handleOf(i),
              reason: 'and the stall knows which car is on it');
          gotLot.add('$site|${cars.stallKey[i]}|${cars.kind[i]}|'
              '${cars.variant[i]}');
        case CarWhere.kerb:
          gotKerb.add('${cars.kind[i]}|${cars.variant[i]}');
        case CarWhere.garaged:
          gotGaraged.add('$site|${cars.kind[i]}|${cars.variant[i]}');
      }
    }

    // Multisets, because two cars may agree in every column asserted here
    // and the file says how many of them there are. Sorted rather than
    // counted so a failure prints what differs.
    expect(gotLot..sort(), orderedEquals(saved.lotKeys..sort()));
    expect(gotKerb..sort(), orderedEquals(saved.kerbKeys..sort()));
    expect(gotGaraged..sort(), orderedEquals(saved.garagedKeys..sort()));
  });

  test('the counts by where come back as saved: no car invented, none lost',
      () {
    final saved = _saved;
    final cars = _load().agents.parkedCars!;
    expect(cars.lotCars, saved.lot.length);
    expect(cars.kerbCars, saved.kerb.length);
    expect(cars.garagedCars, saved.garaged.length);
    expect(cars.count, saved.rows.length,
        reason: 'every row of the file is a car in the colony again');
  });

  test('a car at a site that still stands but has no LOT is garaged there, '
      'not dropped', () {
    // The 17b9e50 rule. `rowOfSite` answers −1 for a kerbside plan and for a
    // plan that has not been made, exactly as it does for a site that is
    // gone; reading it alone dropped the car, silently and for good. What
    // tells them apart is `buildingOfSite`, and a car garaged at a building
    // still standing is that building's — its home pool hands it back when
    // its owner drives again (§7.5).
    final saved = _saved;
    final city = _load();
    final a = city.agents;
    final cars = a.parkedCars!;
    final buildings = a.buildings!;
    final sites = a.sites!;

    expect(saved.sites, contains(kLotlessSite),
        reason: 'the file names the lotless site');
    final handle = buildings.handleOfSite(kLotlessSite);
    expect(handle, isNotNull, reason: 'its building is still standing');
    final slot = SlotPool.slotOf(handle!);
    expect(sites.rowOfBuilding(slot), -1,
        reason: 'and it still has no lot row to park on');

    var found = 0;
    for (var i = 0; i < cars.pool.highWater; i++) {
      if (!cars.pool.isSlotLive(i)) continue;
      if (cars.building[i] != slot) continue;
      expect(CarWhere.values[cars.where[i]], CarWhere.garaged);
      found++;
    }
    expect(found, greaterThan(0),
        reason: 'the car saved at $kLotlessSite came back garaged at it');
  });

  test('the lots the re-cut renamed still hold the cars they held', () {
    // A10's case, but across a SAVE written before the rename was a rename:
    // the plat re-hung these lots onto split roads and re-keyed their names,
    // and the plans kept their `rev` and their stall keys. A restore that
    // rebuilt the site ids from the layout instead of reading them from the
    // block would put every one of these cars somewhere else.
    final saved = _saved;
    final city = _load();
    final a = city.agents;
    final cars = a.parkedCars!;
    final buildings = a.buildings!;

    for (final site in kRenamedSites) {
      expect(saved.sites, contains(site), reason: 'the file names $site');
      final wanted = saved.stallKeysOf(site);
      expect(wanted, isNotEmpty, reason: '$site held a lot car');
      final got = <int>[];
      for (var i = 0; i < cars.pool.highWater; i++) {
        if (!cars.pool.isSlotLive(i)) continue;
        final b = cars.building[i];
        if (b < 0 || buildings.siteId[b] != site) continue;
        expect(CarWhere.values[cars.where[i]], CarWhere.lot,
            reason: '$site kept its stalls across the rename');
        got.add(cars.stallKey[i]);
      }
      expect(got..sort(), orderedEquals(wanted..sort()),
          reason: '$site holds the very stalls it was saved holding');
    }
  });

  // ---- The generator (never run by the suite) --------------------------------

  test('regenerates the fixture from the build running now', () {
    final (:city, :renamed) = _capture();
    final json = city.toJson();
    File(kFixturePath).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(json)}\n');
    // ignore: avoid_print
    print('${_describe(city, json)}; renamed under a car $renamed');
  }, skip: _regenerate ? null : _regenerateSkip, timeout: _slow);
}

// ---- The file ---------------------------------------------------------------

/// The committed block, read once per test process and never written.
_SavedBlock? _cached;

/// The file's `agents` block. Read on first use rather than while the tests
/// are being collected, so a run that is REGENERATING the fixture is not
/// stopped by the fixture it is about to write.
_SavedBlock get _saved => _cached ??= _SavedBlock.read();

/// The `agents` block of the committed save, read once and never written.
class _SavedBlock {
  _SavedBlock._(this.json, this.block, this.sites, this.rows);

  factory _SavedBlock.read() {
    final file = File(kFixturePath);
    if (!file.existsSync()) {
      throw StateError('$kFixturePath is missing. It is committed test DATA, '
          'not build output: restore it from git rather than regenerating '
          'it, which would capture this build and not the one before slice '
          '3.');
    }
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final block = json['agents']! as Map<String, dynamic>;
    return _SavedBlock._(
      json,
      block,
      [for (final s in block['sites']! as List) s as String],
      [for (final r in block['cars']! as List) (r as List).cast<num>()],
    );
  }

  final Map<String, dynamic> json;
  final Map<String, dynamic> block;
  final List<String> sites;
  final List<List<num>> rows;

  int get version => block['v']! as int;
  bool get enabled => block['enabled']! as bool;

  List<List<num>> get lot => _where(CarWhere.lot);
  List<List<num>> get kerb => _where(CarWhere.kerb);
  List<List<num>> get garaged => _where(CarWhere.garaged);

  /// The `CarOwnerKind` and `AgentKind` indices the file carries.
  Set<int> get ownerKinds => {for (final r in rows) r[0].toInt()};
  Set<int> get kinds => {
        for (final r in rows)
          (CarWhere.values[r[2].toInt()] == CarWhere.kerb ? r[6] : r[5]).toInt()
      };

  /// What a restored car must look like, in the words the assertions compare:
  /// its site, the stall key it stood on, its kind and its variant.
  List<String> get lotKeys => [
        for (final r in lot)
          '${_siteOf(r)}|${r[4].toInt()}|${r[5].toInt()}|${r[6].toInt()}',
      ];

  /// A kerb car belongs to no site row, so it is matched on what it IS. Where
  /// it stands is the codec's own business (the nearest free slot within 12 m
  /// and 45°), and re-asserting it here would pin the snap, not the save.
  List<String> get kerbKeys =>
      [for (final r in kerb) '${r[6].toInt()}|${r[7].toInt()}'];

  List<String> get garagedKeys => [
        for (final r in garaged)
          '${_siteOf(r)}|${r[5].toInt()}|${r[6].toInt()}',
      ];

  /// The stall keys the file says stood on [site].
  List<int> stallKeysOf(String site) => [
        for (final r in lot)
          if (_siteOf(r) == site) r[4].toInt(),
      ];

  List<List<num>> _where(CarWhere w) =>
      [for (final r in rows) if (r[2].toInt() == w.index) r];

  String _siteOf(List<num> r) {
    final i = r[3].toInt();
    return i < 0 || i >= sites.length ? '' : sites[i];
  }
}

/// The bodies every colony here is founded on, built once.
final List<CelestialBody> _bodies =
    RealSolarSystem.build().all.where((b) => !b.isStar).toList();

/// The fixture loaded and given the ONE advance that puts its cars down.
///
/// The cars go back at the first prime that has a lane graph to place them
/// on (§14.4's load order), so a single tick is the whole of the restore —
/// and it is the only state worth asserting: the tick after it, a commuter
/// the load woke at work may already be driving home in the car it was saved
/// beside (§14.3, `restoreAtWork`).
CitySim _load() {
  final city = CitySim.fromJson(
      jsonDecode(File(kFixturePath).readAsStringSync())
          as Map<String, dynamic>,
      bodies: _bodies);
  expect(city.agents.enabled, isTrue, reason: 'the block switched them on');
  city.advance(0.5);
  return city;
}

// ---- The generator ----------------------------------------------------------

/// Whether the generator runs. Its OWN define, not the bench gate: a bench
/// run must never overwrite committed test data.
const bool _regenerate =
    bool.fromEnvironment('ACRO_WRITE_AGENTS_FIXTURE');

const String _regenerateSkip =
    'writes committed test data: run it only to capture a NEW fixture, with '
    '--dart-define=ACRO_WRITE_AGENTS_FIXTURE=true, and never to refresh '
    'agents_v2_t4a_pre_citizens.json, whose whole value is that it was '
    'written before slice 3';

const Timeout _slow = Timeout(Duration(minutes: 5));

/// The colony the fixture is taken from: the dev colony the City Builder
/// founds, grown into a town, parked on, and then re-platted by a road
/// commit that renames the lots it re-hangs.
///
/// Its buildings are the plat's OWN (`grownParcels`) and its installations
/// are catalogue specs, because those are the two kinds a save carries
/// whole: `CitySim.toJson` writes a placed building as its LABEL and reads
/// it back out of `kUtilCatalog` only, so a zone spec put on a lot by hand
/// is dropped by the load and would take its cars with it.
({CitySim city, List<String> renamed}) _capture() {
  final city = CityStarterKit.found(
    bodies: _bodies,
    config: const CityConfig(
        bodyId: 'earth',
        gridSize: 20,
        latitude: -45.03,
        longitude: 168.66,
        biome: Biome.forest),
    start: CityStart.standard,
    id: 'city-dev',
    name: 'Dev Colony',
    agentTraffic: true,
  )
    // Quiet, as every scenario colony is: `CitySim` still draws on an
    // unseeded `math.Random()` for its disasters, and a grid fire mid-capture
    // would put a hole in the town the fixture is meant to be.
    ..hostility = 0
    ..autoDisasterTimer = 1e9
    ..funds = 1e12
    ..ignoreUnlocks = true;

  const deal = [
    ParcelUse.residential,
    ParcelUse.residential,
    ParcelUse.commercial,
    ParcelUse.industrial,
  ];
  var k = 0;
  for (final lot in city.layout.autoParcels.toList()) {
    if (city.parcelBuildings.containsKey(lot.id)) continue;
    city.layout.setUse(lot.id, deal[k++ % deal.length]);
    city.grownParcels[lot.id] = 1.0;
  }
  // One hand-drawn lot with NO frontage and a catalogue building on it: with
  // no frame the book has nothing to plan from and demotes it to `kerbOnly`
  // (§3.3), which is a site the colony still has and the traffic side has no
  // row for — the case the garaged-not-dropped rule exists for.
  final lotless = city.layout.addManualParcel(const [
    Vec2(-60, -60),
    Vec2(-44, -60),
    Vec2(-44, -44),
    Vec2(-60, -44),
  ], use: ParcelUse.utility);
  if (lotless == null) throw StateError('the lotless lot was refused');
  city.placeOnParcel(
      lotless.id, kUtilCatalog.firstWhere((s) => s.label == 'Chemist'));

  // Long enough for the book to plan every site and for the town to settle
  // at the size its demand supports: a shorter run leaves a re-plan backlog
  // that the save would catch half done.
  _run(city, 60);
  final a = city.agents;
  a.forceTrip('nowhere', 'nowhere'); // primes the tables
  _park(a, city);

  // The re-cut: a street across the north arm splits the roads it crosses,
  // and every lot those roads hung has to be re-hung and re-named (E12).
  final before = _sitesHoldingACar(a);
  if (city.commitRoad(const [Vec2(-250, 150), Vec2(250, 150)],
          RoadClass.street) ==
      null) {
    throw StateError('the colony refused the re-cut');
  }
  _run(city, 60);
  final renamed = <String>[
    for (final e in _sitesHoldingACar(a).entries)
      if (before[e.key] != null && before[e.key] != e.value) e.value,
  ]..sort();
  return (city: city, renamed: renamed);
}

/// Per building slot holding a parked car: the site id it answers to now.
/// Taken before and after the re-cut, the two say which of them were RENAMED
/// under their cars.
Map<int, String> _sitesHoldingACar(CityAgents a) {
  final cars = a.parkedCars!;
  final buildings = a.buildings!;
  final out = <int, String>{};
  for (var i = 0; i < cars.pool.highWater; i++) {
    if (!cars.pool.isSlotLive(i)) continue;
    final b = cars.building[i];
    if (b < 0 || !buildings.isSlotLive(b)) continue;
    out[b] = buildings.siteId[b];
  }
  return out;
}

void _run(CitySim city, double seconds) {
  for (var i = 0; i < (seconds / 0.5).round(); i++) {
    city.advance(0.5);
  }
}

/// A car on the first free stall of every site row that has one, a car
/// garaged at every lotless site, and a few at the kerb.
///
/// Placed through the table the site mover parks through, so the rows are
/// the rows a driven car leaves behind; the colony's own demand has parked
/// some by itself by now, and those are kept.
void _park(CityAgents a, CitySim city) {
  final sites = a.sites!;
  final cars = a.parkedCars!;
  final buildings = a.buildings!;

  // Home building slots, to own the cars that are not at home. Their index
  // is what slice 3 re-points at a citizen; it is written here so the port
  // has commuter-owned rows to convert.
  final homes = <int>[];
  for (var sl = 0; sl < buildings.highWater && homes.length < 16; sl++) {
    if (!buildings.isSlotLive(sl)) continue;
    final row = sites.rowOfBuilding(sl);
    if (row < 0) continue;
    if (sites.plan[row]?.program == SiteProgram.homeDriveway) homes.add(sl);
  }
  var variant = 3, n = 0;
  for (var r = 0; r < sites.highWater; r++) {
    if (!sites.isRowLive(r)) continue;
    final plan = sites.plan[r];
    if (plan == null || sites.lotCap[r] <= 0) continue;
    final stall = sites.firstFreeStall(r, 0);
    if (stall < 0) continue;
    final home = plan.program == SiteProgram.homeDriveway;
    final car = cars.parkLot(
        building: sites.building[r],
        row: r,
        stall: stall,
        stallKey: plan.stallKey(stall),
        ownerKind: home ? CarOwnerKind.homePool : CarOwnerKind.commuter,
        owner: home
            ? sites.building[r]
            : (homes.isEmpty ? -1 : homes[n % homes.length]),
        // An installation's yard takes the lorry. T4a parks no truck of its
        // own (its scope is CommuteSynth cars), and that is the point: the
        // `kind` column has to come back per car, and a file in which every
        // car is a `car` could not tell a build that read it from one that
        // defaulted it.
        kind: plan.program == SiteProgram.installation
            ? AgentKind.truck.index
            : AgentKind.car.index,
        variant: (variant += 5) & 0xff);
    if (car == SlotPool.none) continue;
    sites.occupy(r, stall, car);
    n++;
  }
  // The lotless sites: still standing, no row, so their cars live in the
  // garage.
  for (var sl = 0; sl < buildings.highWater; sl++) {
    if (!buildings.isSlotLive(sl) || sites.rowOfBuilding(sl) >= 0) continue;
    final plan = city.siteAccess.planOf(buildings.siteId[sl]);
    if (plan == null || plan.program != SiteProgram.kerbOnly) continue;
    cars.garage(
        building: sl,
        ownerKind: CarOwnerKind.homePool,
        owner: sl,
        kind: AgentKind.car.index,
        variant: (variant += 5) & 0xff);
  }
  // And a handful at the kerb, spread along the streets so no two share an
  // edge.
  final kerbs = a.kerbs!;
  var kerbed = 0;
  for (var s = 0; s < kerbs.slotCount && kerbed < 6; s += 23) {
    if (!kerbs.isFree(s)) continue;
    final car = cars.parkKerb(
        building: -1,
        edge: kerbs.slotEdge(s),
        slot: s,
        side: kerbs.slotSide(s),
        ownerKind: CarOwnerKind.commuter,
        owner: homes.isEmpty ? -1 : homes[kerbed % homes.length],
        kind: AgentKind.car.index,
        variant: (variant += 5) & 0xff);
    if (car == SlotPool.none) continue;
    kerbs.occupy(s, car);
    kerbed++;
  }
}

/// What the capture ended up holding, for the commit message and the header
/// above: counts by `where`, by kind and by site program, and the lots the
/// re-cut renamed.
String _describe(CitySim city, Map<String, Object?> json) {
  final a = city.agents;
  final cars = a.parkedCars!;
  final sites = a.sites!;
  final block = json['agents']! as Map<String, Object?>;
  final byWhere = <String, int>{};
  final byKind = <String, int>{};
  final byProgram = <String, int>{};
  for (var i = 0; i < cars.pool.highWater; i++) {
    if (!cars.pool.isSlotLive(i)) continue;
    final w = CarWhere.values[cars.where[i]].name;
    byWhere[w] = (byWhere[w] ?? 0) + 1;
    final kind = AgentKind.values[cars.kind[i]].name;
    byKind[kind] = (byKind[kind] ?? 0) + 1;
    final row = cars.row[i];
    final p = row >= 0 && sites.isRowLive(row)
        ? sites.plan[row]?.program.name
        : (cars.building[i] >= 0
            ? city.siteAccess
                .planOf(a.buildings!.siteId[cars.building[i]])
                ?.program
                .name
            : null);
    final key = p ?? 'none';
    byProgram[key] = (byProgram[key] ?? 0) + 1;
  }
  return 'fixture: v ${block['v']}, '
      '${(block['cars']! as List).length} rows over '
      '${(block['sites']! as List).length} sites; '
      'by where $byWhere; by kind $byKind; by program $byProgram; '
      'sites ${(block['sites']! as List)}';
}
