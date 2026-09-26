// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The `'agents'` block of a colony's save (docs/plans/agent-traffic.md
/// §14.1, §14.4; t4a-implementation.md §4 Q2).
///
/// Slice 1 saved one thing: that the colony runs agents, so a save and a
/// load keep them on. T4a adds the parked cars, and with them the `sites`
/// string table every column is indexed by. Vehicles in flight are still
/// never saved (§14.3) — the route arena is tied to one graph object, and
/// transient machinery re-derives — so a restored colony starts its spawn
/// ramp afresh, with its cars where they were parked. Citizens, the RNG,
/// accumulators and stops join the block in later slices, each column in
/// sorted site order so a save is deterministic; that is why this is the one
/// traffic file allowed to iterate a map.
///
/// **A car is saved by its key, never by its stall index** (C-19): the lot's
/// `siteId` current at save, and the `stallKey` its plan gives that stall,
/// which survives a re-plan that keeps the stall. On load the block places
/// what it can and says so in order (§14.1):
///
/// 1. an unknown site — renamed by a changed plat rule, demolished — drops
///    its cars, as a citizen's unknown home is dropped. A site that is still
///    there but has no LOT (a kerbside plan, or a building whose plan has
///    not been made) is not unknown: its cars are garaged at it;
/// 2. a key that is gone takes the nearest free stall of that lot;
/// 3. a lot with no free stall garages the car, and so does a kerb the car
///    can no longer be snapped to.
///
/// **A lot that has not arrived yet is not a lot that is gone.** Step 1 above
/// reads a site the plan source has not planned YET exactly as it reads one
/// that is kerbside for good, and a load is one pass over the rows: whatever
/// the colony had not synced by that instant was garaged, silently, with no
/// second chance. The book plans on a budget (site-access §4.1, §7.6), so a
/// colony that loads with a re-plan backlog in flight lost lot cars. So the
/// restore ASKS, through [CarRestoreSink.holdForSite], whether the world will
/// hold the car and try again when its site arrives; only a world that says
/// no resolves it by step 1. The retries come back through [restoreCars] with
/// [restoreCars.rows], the rows still waiting, so the order and the answers
/// are the same ones a single pass would have given.
///
/// **The version.** The block carries its own `v`, and it says the LOWEST
/// version that can read it back: 1 while it is the flag alone, 2 once it
/// carries the site and car tables (§14.4 additive). So a colony that has
/// parked nothing writes the bytes it wrote before T4a, and a colony that
/// has parked something says 2 — which a build that reads only 1 drops
/// whole, rather than half-reading. `GameStateCodec.schemaVersion` stays 1.
///
/// **The citizens (slice 3).** Three more keys ride inside v2, because they
/// are additive to a shape no build ever read differently: `cit` — the
/// citizens as dense columns in slot order — `ledger`, the population
/// budgets, and `pop`, the realisation's own stream and counters. The CAR
/// rows do not change at all: their shapes, their order and their bytes are
/// the ones T4a wrote, which is what `agents_v2_pre_citizens_fixture_test`
/// holds this file to. What changed is only what one owner KIND means, and
/// that was always a union tag: `commuter` and `homePool` keep their T4a
/// meaning for ever (`ownerIdx` is a BUILDING slot) and the new `citizen`
/// means `ownerIdx` is the dense index of the same block's `cit` table
/// (slice3 §0).
///
/// **One direction only** (§0 Q4). `cit` carries no `car` column: cars have
/// no stable save id, and two columns pointing at each other is two things to
/// keep in step. The CAR row says whose it is, the load rebuilds
/// `CitizenTable.car` from it, and a car whose citizen is gone is simply a
/// car nobody owns. At save time the owner column holds a citizen HANDLE, so
/// [encode] re-points the live rows at the dense index the `cit` table is
/// about to be written in — and only those rows, only for the one kind that
/// did not exist before slice 3.
library;

import 'dart:typed_data';

import 'citizen_population.dart';
import 'citizen_table.dart';
import 'parked_cars.dart';
import 'slot_pool.dart';

/// What a save needs to know about a parked car that the table does not
/// hold. Implemented by the facade over the site table and the lane graph.
abstract interface class CarSaveSource {
  /// The lot or site id string of [car]'s site at save time, renames
  /// followed (`_carryRenamedLots`); null when it has none, which writes the
  /// car garaged with no site.
  String? siteIdOf(int car);

  /// The colony-local `(east, north, heading)` of kerb car [car] into [out],
  /// heading in radians; false when it has no pose, which writes it garaged.
  bool kerbPoseOf(int car, Float64List out);
}

/// The world a saved car is put back into (§14.1). The facade implements it
/// over the site table, the kerb slots and the parked cars; the codec owns
/// the ORDER the three are tried in.
///
/// Every `car` below is a row of the [SavedAgents.cars] being restored, not
/// a handle: the columns there say whose car it is, what kind and what
/// variant, and the sink reads them as it places it.
abstract interface class CarRestoreSink {
  /// The site row of [siteId], or −1 when it has none — which is NOT the
  /// same as having no such site: a kerbside plan, and a building whose plan
  /// has not been made yet, are both real places with no lot to park in.
  /// [buildingOfSite] tells the two apart.
  int rowOfSite(String siteId);

  /// The building slot [siteId] names, or −1 when the colony has no such
  /// building at all.
  ///
  /// This is what keeps a garaged car whose site has no lot: it belongs to a
  /// building that is still standing, and it comes back out of that
  /// building's pool when its owner drives again. Reading only [rowOfSite]
  /// would have dropped it as though the whole lot were gone.
  int buildingOfSite(String siteId);

  /// The stall of [row] keyed [stallKey] (`SiteTable.stallIndexOfKey`), or
  /// −1 when the re-plan dropped it.
  int stallOfKey(int row, int stallKey);

  /// The free stall of [row] nearest where [stallKey] stood, or −1 when the
  /// lot has none.
  int nearestFreeStall(int row, int stallKey);

  /// Parks saved car [car] on [stall] of site [row].
  void parkLot(int car, int row, int stall);

  /// Puts saved car [car] back at the kerb slot nearest its saved pose;
  /// false when there is none to snap to, and the codec garages it.
  bool parkKerb(int car);

  /// Takes saved car [car] out of the world, at site row [row] (−1 when it
  /// has none) of [building] (−1 when even that is unknown): a car garaged
  /// at a building is still that building's, and is handed back when its
  /// owner drives.
  void garage(int car, int row, int building);

  /// Offers saved lot car [car] — whose [building] is standing and whose lot
  /// has no row — to the world to HOLD until its site arrives: true when the
  /// world took it, and the codec leaves it alone.
  ///
  /// Only the world can answer this. The codec sees a site with no row and
  /// cannot tell a lot the plans have not reached yet from one that is
  /// kerbside for good; the world knows whether its plan source still has
  /// work to do, and how long it is willing to wait. False puts the car back
  /// on §14.1's order, which garages it at [building].
  bool holdForSite(int car, int building);
}

/// What a save needs to know about a citizen that the table does not hold:
/// the SITE their home and their job answer to, and the clock their wake is
/// measured against. Implemented by the facade over the building table.
abstract interface class CitizenSaveSource {
  /// The site id string of building slot [buildingSlot], or null when the
  /// colony has no such building: the column is written −1 and the citizen
  /// comes back homeless or unemployed (§14.4's load order).
  String? siteIdOfBuilding(int buildingSlot);

  /// Agent µs now. Wakes are written RELATIVE to it (`wakeInUs`), because a
  /// colony resumed from a save starts its clock wherever the save left it
  /// and an absolute wake would come due all at once, or never (§14.3).
  int get nowUs;
}

/// The world a saved citizen is put back into (§14.1): one question, the
/// same one a car asks, because a home and a job are sites too.
abstract interface class CitizenRestoreSink {
  /// The building slot of [siteId], or −1 when the colony no longer has that
  /// building — a lot a changed plat rule renamed, a tower that vanished on
  /// load. The citizen is restored homeless or unemployed and re-matched at
  /// the next sync (§14.4, §6.3).
  int buildingOfSite(String siteId);
}

/// The citizens of a save, decoded: the `cit` columns, DENSE and in the slot
/// order they were written in, with `home` and `work` indices into
/// [SavedAgents.sites].
///
/// The dense position is the citizen's identity in the block: it is what a
/// `citizen`-owned car row's `ownerIdx` names, and what [AgentsCodec.restoreCitizens]
/// hands back a live handle for.
class SavedCitizens {
  SavedCitizens(int capacity)
      : home = Int32List(capacity),
        work = Int32List(capacity),
        state = Uint8List(capacity),
        flags = Uint8List(capacity),
        wakeInUs = Float64List(capacity);

  /// Citizens in the table.
  int count = 0;

  /// Per citizen: the site their home and their job are on (−1 for none).
  final Int32List home, work;

  /// Per citizen: the [CitizenState] index and the `CitizenFlags` bits.
  final Uint8List state, flags;

  /// Per citizen: µs from the save's clock to their next wake. Negative for
  /// a wake that was already due.
  final Float64List wakeInUs;
}

/// The parked cars of a save, decoded: the columns of the `cars` table, with
/// `site` an index into [SavedAgents.sites].
class SavedCars {
  SavedCars(int capacity)
      : where = Uint8List(capacity),
        ownerKind = Uint8List(capacity),
        kind = Uint8List(capacity),
        variant = Uint8List(capacity),
        owner = Int32List(capacity),
        site = Int32List(capacity),
        stallKey = Int32List(capacity),
        e = Float64List(capacity),
        n = Float64List(capacity),
        heading = Float64List(capacity);

  /// Cars in the table.
  int count = 0;

  /// Per car: [CarWhere], [CarOwnerKind], the `AgentKind` index and the
  /// renderer's variant byte.
  final Uint8List where, ownerKind, kind, variant;

  /// Per car: its opaque owner index, its site (an index into
  /// [SavedAgents.sites], −1 for none) and its `stallKey` (−1 when it stood
  /// on no stall).
  final Int32List owner, site, stallKey;

  /// Per kerb car: where it stood, and which way it faced (radians).
  final Float64List e, n, heading;
}

/// The `'agents'` block, decoded.
class SavedAgents {
  SavedAgents(
      {required this.version,
      required this.enabled,
      required this.sites,
      required this.cars,
      required this.citizens,
      required this.ledgerJson,
      required this.popJson});

  /// The `v` the block carried: 1 (the flag alone) or 2.
  final int version;

  /// Whether the colony runs agents.
  final bool enabled;

  /// The site id strings, sorted: every column indexes these (§14.1).
  final List<String> sites;

  /// The parked cars.
  final SavedCars cars;

  /// The citizens, dense and in slot order; empty for a block written before
  /// slice 3.
  final SavedCitizens citizens;

  /// The `ledger` and `pop` blocks as they were written, for
  /// `PopulationLedger.restore` and `CitizenPopulation.restore` to read —
  /// and for [AgentsCodec.encode] to write straight back out while a load has
  /// not put its people down yet. Null when the block carried neither.
  final Object? ledgerJson, popJson;
}

/// How a load went, per §14.1's order.
typedef RestoreTally = ({int lot, int kerb, int garaged, int dropped});

/// Reads and writes the `'agents'` save block.
class AgentsCodec {
  AgentsCodec._();

  /// The block's schema version: what a block carrying every T4a column
  /// says. Bumped on any change to its shape.
  static const int version = 2;

  /// The oldest block this build still reads (§14.4: `restore` migrates the
  /// previous version or drops the block).
  static const int oldestVersion = 1;

  /// Milliradians of heading, the unit the kerb rows are written in: a
  /// heading rounds to a fifth of a degree, which is far inside the 45° the
  /// re-snap allows (§14.1).
  static const double headingScale = 1000;

  /// The block for a colony whose agents are [enabled], with the parked
  /// [cars] of [world] and whatever rows of an earlier load it is still
  /// [held]ing.
  ///
  /// [cars] and [world] go together: without a world the codec cannot name a
  /// car's site or a kerb car's pose, so it writes the flag alone — which is
  /// also what a colony that has parked nothing writes.
  ///
  /// [held] is a block a load has not finished putting down: one waiting for
  /// its first advance, or the rows still waiting for their sites (see the
  /// library comment). [heldRows] names which of its rows are still waiting,
  /// [heldCount] of them; null means every row of it. They are written back
  /// out exactly as they came in, so a save taken while a load is still
  /// settling loses nothing — a save, a load and a save again is the same
  /// bytes, whatever the colony had managed to place in between.
  ///
  /// Rows are written in a total order of their own numbers, not in slot
  /// order: a colony resumed from a save re-creates its cars in another slot
  /// order, and saving it again must write the same bytes (the fidelity
  /// graft, §14.1).
  ///
  /// [citizens] and [census] go together the way [cars] and [world] do, and
  /// [population] brings the budgets ([CitizenPopulation.ledger]) and the
  /// realisation's stream with it. Pass all three whenever the colony has
  /// citizens: without them a `citizen`-owned car row would be written
  /// carrying a HANDLE where the load expects a dense index, and its owner
  /// would come back owning nothing.
  ///
  /// A colony with neither cars nor citizens nor budgets writes the flag
  /// alone, exactly as it did before T4a and before slice 3.
  static Map<String, Object?> encode(
      {required bool enabled,
      ParkedCarTable? cars,
      CarSaveSource? world,
      CitizenTable? citizens,
      CitizenSaveSource? census,
      CitizenPopulation? population,
      SavedAgents? held,
      Int32List? heldRows,
      int heldCount = 0}) {
    final rows = <List<num>>[];
    final ids = <String>[];
    final byId = <String, int>{};
    if (cars != null && world != null) {
      _writeCars(cars, world, rows, ids, byId);
    }
    // Before the held rows, because those are already written in the dense
    // numbering of the block they came from and must go back out untouched.
    if (citizens != null) _pointAtCitizens(rows, citizens);
    if (held != null) {
      _writeHeld(held, heldRows, heldCount, rows, ids, byId);
    }
    // Whose citizens the block carries. The live tables win whenever the
    // colony has anybody; a load that has not put its people down yet
    // carries the block it is holding through untouched, so a save, a load
    // and a save again are the same bytes (§14.1 as built).
    final budgets = population?.ledger;
    final owed = budgets != null && !budgets.isEmpty;
    final live = citizens != null && census != null && citizens.liveCount > 0;
    final mine = live || owed;
    final folk = live
        ? _writeCitizens(citizens, census, ids, byId)
        : (!mine && held != null && held.citizens.count > 0
            ? _writeHeldCitizens(held, ids, byId)
            : null);
    final ledger = mine ? (owed ? budgets.toJson() : null) : held?.ledgerJson;
    final pop = mine ? population?.toJson() : held?.popJson;
    if (rows.isEmpty && folk == null && ledger == null && pop == null) {
      return {'v': oldestVersion, 'enabled': enabled};
    }
    final moved = _sortIds(rows, ids);
    if (folk != null && moved != null) folk.moveSites(moved);
    rows.sort(_compareRows);
    return {
      'v': version,
      'enabled': enabled,
      'sites': ids,
      'cars': rows,
      if (folk != null) 'cit': folk.toJson(),
      'ledger': ?ledger,
      'pop': ?pop,
    };
  }

  /// The enabled flag [json] carries, or null when there is no block, a
  /// block of a version this build does not read, or one that is not a
  /// block at all: the colony then runs without agents, as it did before it
  /// had any.
  static bool? enabledOf(Object? json) => decode(json)?.enabled;

  /// [json] decoded, or null when this build cannot read it. A v1 block
  /// decodes with no sites and no cars, which is what it held.
  static SavedAgents? decode(Object? json) {
    if (json is! Map) return null;
    final v = json['v'];
    if (v is! int || v < oldestVersion || v > version) return null;
    final enabled = json['enabled'];
    if (enabled is! bool) return null;
    final rawSites = json['sites'];
    final sites = <String>[];
    if (rawSites is List) {
      for (final id in rawSites) {
        if (id is String) sites.add(id);
      }
    }
    final rawCars = json['cars'];
    final cars = SavedCars(rawCars is List ? rawCars.length : 0);
    if (rawCars is List) {
      for (final raw in rawCars) {
        _readCar(raw, sites.length, cars);
      }
    }
    return SavedAgents(
        version: v,
        enabled: enabled,
        sites: sites,
        cars: cars,
        citizens: _readCitizens(json['cit'], sites.length),
        ledgerJson: json['ledger'],
        popJson: json['pop']);
  }

  /// Puts the citizens of [saved] back into [citizens], in the dense order
  /// the block wrote them, at agent time [nowUs]; [sink] answers what a site
  /// id is a building of now. Returns their new handles BY DENSE INDEX, with
  /// [SlotPool.none] for one the table could not hold.
  ///
  /// That list is the load's other half: a restored car whose `ownerKind` is
  /// `citizen` carries a dense index, and its owner is `handles[ownerIdx]`.
  /// Nothing here touches a car — the cars go down on their own order and
  /// their own schedule (§14.1), possibly several advances later — so the
  /// column that says which car a citizen owns is written by whoever places
  /// the car, from the row it places (§0 Q4).
  ///
  /// The budgets and the realisation's stream are restored beside this, from
  /// [SavedAgents.ledgerJson] and [SavedAgents.popJson].
  static Int32List restoreCitizens(SavedAgents saved, CitizenTable citizens,
      CitizenRestoreSink sink, {required int nowUs}) {
    final folk = saved.citizens;
    final out = Int32List(folk.count)
      ..fillRange(0, folk.count, SlotPool.none);
    if (folk.count == 0) return out;
    // The table never grows by itself (§2.1); a load is a moment its owner
    // may, and it grows once here rather than doubling person by person.
    var want = citizens.capacity;
    final need = citizens.liveCount + folk.count;
    while (want < need && want < SlotPool.maxSlots) {
      want *= 2;
    }
    if (want > citizens.capacity) {
      citizens.grow(want < SlotPool.maxSlots ? want : SlotPool.maxSlots);
    }
    for (var k = 0; k < folk.count; k++) {
      final made = citizens.spawn(
          home: _buildingOf(saved, sink, folk.home[k]),
          work: _buildingOf(saved, sink, folk.work[k]),
          car: CitizenTable.carNone,
          state: CitizenState.values[folk.state[k]],
          wakeUs: nowUs + folk.wakeInUs[k],
          flags: folk.flags[k]);
      if (made == SlotPool.none) return out;
      out[k] = made;
    }
    return out;
  }

  /// The building slot site index [site] of [saved] names now, or −1 for a
  /// site the colony no longer has (§14.4's load order).
  static int _buildingOf(
      SavedAgents saved, CitizenRestoreSink sink, int site) {
    if (site < 0 || site >= saved.sites.length) return -1;
    return sink.buildingOfSite(saved.sites[site]);
  }

  /// Puts the cars of [saved] back into [sink], in §14.1's order: the key,
  /// then the nearest free stall, then the garage; and an unknown site drops
  /// its cars. A lot car whose site has no row yet is offered to
  /// [CarRestoreSink.holdForSite] first, and counted in none of the four
  /// while the sink holds it.
  ///
  /// [rows] names which rows to put back, [count] of them — the rows a
  /// previous pass held, retried now that their sites may have arrived.
  /// Null is every row, which is what a load's first pass asks for.
  static RestoreTally restoreCars(SavedAgents saved, CarRestoreSink sink,
      {Int32List? rows, int count = 0}) {
    final cars = saved.cars;
    final n = rows == null ? cars.count : count;
    var lot = 0, kerb = 0, garaged = 0, dropped = 0;
    for (var k = 0; k < n; k++) {
      final i = rows == null ? k : rows[k];
      final s = cars.site[i];
      final id = s < 0 ? null : saved.sites[s];
      final row = id == null ? -1 : sink.rowOfSite(id);
      var building = -1;
      if (id != null && row < 0) {
        // No lot row is not the same as no site. A kerbside plan and a
        // building whose plan has not been made both answer −1 here and are
        // still standing, and a car garaged at one of them belongs to it: it
        // is garaged again, not dropped. Only a building the colony no
        // longer has takes its cars with it.
        building = sink.buildingOfSite(id);
        if (building < 0) {
          dropped++;
          continue;
        }
      }
      switch (CarWhere.values[cars.where[i]]) {
        case CarWhere.lot:
          // A lot with no row is the one case worth waiting on: the site may
          // be one the plans have not reached yet, and garaging the car here
          // would be for ever. Only a car that stood on a STALL waits — a
          // kerb car hangs on no site row, and a garaged car is garaged
          // whenever it is asked, so neither gains anything by waiting.
          if (row < 0 && sink.holdForSite(i, building)) continue;
          var stall = row < 0 ? -1 : sink.stallOfKey(row, cars.stallKey[i]);
          if (stall < 0 && row >= 0) {
            stall = sink.nearestFreeStall(row, cars.stallKey[i]);
          }
          if (stall < 0) {
            sink.garage(i, row, building);
            garaged++;
          } else {
            sink.parkLot(i, row, stall);
            lot++;
          }
        case CarWhere.kerb:
          if (sink.parkKerb(i)) {
            kerb++;
          } else {
            sink.garage(i, row, building);
            garaged++;
          }
        case CarWhere.garaged:
          sink.garage(i, row, building);
          garaged++;
      }
    }
    return (lot: lot, kerb: kerb, garaged: garaged, dropped: dropped);
  }

  /// Every live car of [cars] as a row of [rows], with the site ids they
  /// name collected into [ids] (interned through [byId]); [encode] sorts
  /// both afterwards (§14.1).
  ///
  /// A lot row is `[ownerKind, ownerIdx, where, siteIdx, stallKey, kind,
  /// variant]` and a kerb row `[ownerKind, ownerIdx, where, e, n,
  /// headingMilli, kind, variant]` (§4 Q2, site-access §7.5). A garaged car
  /// takes the lot row with no stall key, so it keeps the site it belongs
  /// to and comes back there when its owner drives again.
  static void _writeCars(ParkedCarTable cars, CarSaveSource world,
      List<List<num>> rows, List<String> ids, Map<String, int> byId) {
    final pose = Float64List(3);
    for (var i = 0; i < cars.pool.highWater; i++) {
      if (!cars.pool.isSlotLive(i)) continue;
      final car = cars.pool.handleOf(i);
      final w = CarWhere.values[cars.where[i]];
      final kind = cars.kind[i], variant = cars.variant[i];
      final ownerKind = cars.ownerKind[i], owner = cars.owner[i];
      if (w == CarWhere.kerb && world.kerbPoseOf(car, pose)) {
        rows.add([
          ownerKind,
          owner,
          CarWhere.kerb.index,
          pose[0],
          pose[1],
          (pose[2] * headingScale).round(),
          kind,
          variant,
        ]);
        continue;
      }
      final id = world.siteIdOf(car);
      // A kerb car with no pose left cannot be put back at a kerb: it is
      // saved garaged at the site it belongs to.
      final lot = w == CarWhere.lot;
      rows.add([
        ownerKind,
        owner,
        lot ? CarWhere.lot.index : CarWhere.garaged.index,
        id == null ? -1 : _intern(id, ids, byId),
        lot ? cars.stallKey[i] : -1,
        kind,
        variant,
      ]);
    }
  }

  /// The rows of [held] a load has not put down, written back out into
  /// [rows] with their site ids interned into [ids]: [rowsOf] names which of
  /// them, [count] of them, and null means all of them.
  ///
  /// The columns go out exactly as they came in — the same `where`, the same
  /// `stallKey`, the same pose — because they ARE what the earlier save
  /// wrote. Nothing is re-derived from the colony: the whole point of a held
  /// row is that the colony cannot say where it belongs yet (§14.1 as built).
  static void _writeHeld(SavedAgents held, Int32List? rowsOf, int count,
      List<List<num>> rows, List<String> ids, Map<String, int> byId) {
    final cars = held.cars;
    final n = rowsOf == null ? cars.count : count;
    for (var k = 0; k < n; k++) {
      final i = rowsOf == null ? k : rowsOf[k];
      if (i < 0 || i >= cars.count) continue;
      if (CarWhere.values[cars.where[i]] == CarWhere.kerb) {
        rows.add([
          cars.ownerKind[i],
          cars.owner[i],
          CarWhere.kerb.index,
          cars.e[i],
          cars.n[i],
          (cars.heading[i] * headingScale).round(),
          cars.kind[i],
          cars.variant[i],
        ]);
        continue;
      }
      final s = cars.site[i];
      rows.add([
        cars.ownerKind[i],
        cars.owner[i],
        cars.where[i],
        s < 0 || s >= held.sites.length
            ? -1
            : _intern(held.sites[s], ids, byId),
        cars.stallKey[i],
        cars.kind[i],
        cars.variant[i],
      ]);
    }
  }

  // ---- The citizens (slice 3, §14.1) --------------------------------------------

  /// The live citizens of [citizens] as the `cit` columns, dense and in slot
  /// order, with the sites their homes and jobs stand on interned into [ids].
  ///
  /// Dense, because the position IS the citizen's name in this block: a
  /// `citizen`-owned car row points at it, and the load spawns them back in
  /// the same order. Nothing of the wheel, the per-building lists or the slot
  /// generations is written — a colony resumed from a save has the same
  /// PEOPLE with a different history behind its lists, which is what
  /// `CitizenTable.digest` already says it means.
  static _CitRows _writeCitizens(CitizenTable citizens,
      CitizenSaveSource census, List<String> ids, Map<String, int> byId) {
    final out = _CitRows();
    final now = census.nowUs;
    for (var i = 0; i < citizens.highWater; i++) {
      if (!citizens.isSlotLive(i)) continue;
      out.home.add(_siteOfBuilding(citizens.home[i], census, ids, byId));
      out.work.add(_siteOfBuilding(citizens.work[i], census, ids, byId));
      out.state.add(citizens.state[i]);
      out.flags.add(citizens.flags[i]);
      out.wakeInUs.add(_wakeIn(citizens.wakeUs[i], now));
    }
    return out;
  }

  /// The citizens of [held] written back out as they came in, with their site
  /// ids re-interned into [ids]: the same people, named against the string
  /// table this save is building (see [_writeHeld], which does it for cars).
  static _CitRows _writeHeldCitizens(
      SavedAgents held, List<String> ids, Map<String, int> byId) {
    final folk = held.citizens;
    final out = _CitRows();
    for (var k = 0; k < folk.count; k++) {
      out.home.add(_carrySite(held, folk.home[k], ids, byId));
      out.work.add(_carrySite(held, folk.work[k], ids, byId));
      out.state.add(folk.state[k]);
      out.flags.add(folk.flags[k]);
      out.wakeInUs.add(folk.wakeInUs[k].round());
    }
    return out;
  }

  /// Every `citizen`-owned row of [rows] re-pointed from the citizen HANDLE
  /// the table holds at the dense index the `cit` block is written in (§0 Q4).
  ///
  /// The only rows touched are the ones carrying a kind that did not exist
  /// before slice 3, so no save written by an older build — and no row of
  /// this one that a `commuter` or a `homePool` owns — can be moved by it. A
  /// handle that has gone stale writes −1: its owner died between the trip
  /// that parked the car and the save, and the car comes back owning nobody.
  static void _pointAtCitizens(List<List<num>> rows, CitizenTable citizens) {
    final dense = _denseIndex(citizens);
    for (final row in rows) {
      if (row[0] != CarOwnerKind.citizen.index) continue;
      final owner = row[1].toInt();
      final slot = SlotPool.slotOf(owner);
      row[1] = citizens.isLive(owner) && slot < dense.length
          ? dense[slot]
          : -1;
    }
  }

  /// Per citizen slot: its position in the dense `cit` columns, or −1 for a
  /// slot nobody is on.
  static Int32List _denseIndex(CitizenTable citizens) {
    final n = citizens.highWater;
    final out = Int32List(n)..fillRange(0, n, -1);
    var dense = 0;
    for (var i = 0; i < n; i++) {
      if (citizens.isSlotLive(i)) out[i] = dense++;
    }
    return out;
  }

  /// The `cit` block of [raw], or an empty table: a block written before
  /// slice 3, or one whose columns are not five lists of numbers.
  ///
  /// A row that does not read is DEFAULTED rather than skipped — homeless,
  /// unemployed, at home and due now — because the dense position is what a
  /// car row names, and dropping one would hand every car after it to the
  /// wrong person.
  static SavedCitizens _readCitizens(Object? raw, int siteCount) {
    if (raw is! Map) return SavedCitizens(0);
    final home = raw['home'], work = raw['work'], state = raw['state'];
    final flags = raw['flags'], wake = raw['wakeInUs'];
    if (home is! List ||
        work is! List ||
        state is! List ||
        flags is! List ||
        wake is! List) {
      return SavedCitizens(0);
    }
    var n = home.length;
    if (work.length < n) n = work.length;
    if (state.length < n) n = state.length;
    if (flags.length < n) n = flags.length;
    if (wake.length < n) n = wake.length;
    final out = SavedCitizens(n);
    for (var k = 0; k < n; k++) {
      out.home[k] = _siteOrNone(home[k], siteCount);
      out.work[k] = _siteOrNone(work[k], siteCount);
      out.state[k] = _byteOf(state[k], CitizenState.values.length);
      out.flags[k] = _byteOf(flags[k], 256);
      final w = wake[k];
      out.wakeInUs[k] = w is num && w.toDouble().isFinite ? w.toDouble() : 0;
    }
    out.count = n;
    return out;
  }

  /// [buildingSlot]'s site as an index into [ids], or −1.
  static int _siteOfBuilding(int buildingSlot, CitizenSaveSource census,
      List<String> ids, Map<String, int> byId) {
    if (buildingSlot < 0) return -1;
    final id = census.siteIdOfBuilding(buildingSlot);
    return id == null ? -1 : _intern(id, ids, byId);
  }

  /// Site index [site] of [held] as an index into [ids].
  static int _carrySite(
      SavedAgents held, int site, List<String> ids, Map<String, int> byId) =>
      site < 0 || site >= held.sites.length
          ? -1
          : _intern(held.sites[site], ids, byId);

  /// [wakeUs] as µs from [nowUs], saturating at [_maxWakeUs] so that a wake
  /// somebody scheduled at the end of agent time is written as a long wait
  /// rather than as a number no column holds.
  static int _wakeIn(double wakeUs, int nowUs) {
    final d = wakeUs - nowUs;
    if (!(d > -_maxWakeUs)) return -_maxWakeUs;
    if (!(d < _maxWakeUs)) return _maxWakeUs;
    return d.round();
  }

  /// The furthest a saved wake can be, µs: inside 2^31, the range every
  /// platform's int agrees on.
  static const int _maxWakeUs = 2000000000;

  /// [v] as a site index below [siteCount], or −1.
  static int _siteOrNone(Object? v, int siteCount) {
    if (v is! num) return -1;
    final i = v.toInt();
    return i >= 0 && i < siteCount ? i : -1;
  }

  /// [id]'s index in [ids], appended if it is new. [byId] is the lookup that
  /// keeps the append linear; [encode] sorts [ids] afterwards and moves every
  /// row's index with them.
  static int _intern(String id, List<String> ids, Map<String, int> byId) {
    final at = byId[id] ?? -1;
    if (at >= 0) return at;
    final made = ids.length;
    ids.add(id);
    byId[id] = made;
    return made;
  }

  /// [ids] sorted, with every row's site index moved with them: the string
  /// table is sorted by site id, so a save is deterministic (§14.1). Returns
  /// where each id went, so the citizen columns — interned into the same
  /// table — can be moved with it; null when there was nothing to sort.
  static Int32List? _sortIds(List<List<num>> rows, List<String> ids) {
    final n = ids.length;
    if (n == 0) return null;
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) => ids[a].compareTo(ids[b]));
    final was = List<String>.from(ids);
    final moved = Int32List(n);
    for (var i = 0; i < n; i++) {
      ids[i] = was[order[i]];
      moved[order[i]] = i;
    }
    for (final row in rows) {
      if (row.length != 7) continue;
      final site = row[3] as int;
      if (site >= 0) row[3] = moved[site];
    }
    return moved;
  }

  /// Two rows in a total order of their numbers: the same cars write the
  /// same bytes whatever order the table holds them in.
  static int _compareRows(List<num> a, List<num> b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final c = a[i].compareTo(b[i]);
      if (c != 0) return c;
    }
    return a.length.compareTo(b.length);
  }

  /// One row of the `cars` table into [cars]; a row that is not one is
  /// skipped, as a save is data and a half-read row is worse than a lost
  /// car.
  static void _readCar(Object? raw, int siteCount, SavedCars cars) {
    if (raw is! List || raw.length < 7) return;
    for (final v in raw) {
      if (v is! num) return;
    }
    final w = (raw[2] as num).toInt();
    if (w < 0 || w >= CarWhere.values.length) return;
    final kerb = CarWhere.values[w] == CarWhere.kerb;
    if (kerb && raw.length < 8) return;
    final i = cars.count;
    if (i >= cars.where.length) return;
    cars.ownerKind[i] = _byteOf(raw[0], CarOwnerKind.values.length);
    cars.owner[i] = (raw[1] as num).toInt();
    cars.where[i] = w;
    if (kerb) {
      cars.site[i] = -1;
      cars.stallKey[i] = -1;
      cars.e[i] = (raw[3] as num).toDouble();
      cars.n[i] = (raw[4] as num).toDouble();
      cars.heading[i] = (raw[5] as num).toDouble() / headingScale;
      cars.kind[i] = _byteOf(raw[6], 256);
      cars.variant[i] = _byteOf(raw[7], 256);
    } else {
      final site = (raw[3] as num).toInt();
      cars.site[i] = site >= 0 && site < siteCount ? site : -1;
      cars.stallKey[i] = (raw[4] as num).toInt();
      cars.e[i] = 0;
      cars.n[i] = 0;
      cars.heading[i] = 0;
      cars.kind[i] = _byteOf(raw[5], 256);
      cars.variant[i] = _byteOf(raw[6], 256);
    }
    cars.count = i + 1;
  }

  /// [v] as a byte below [limit]; 0 for anything else, so a column an older
  /// or newer build wrote out of range reads as the first member rather
  /// than throwing on an enum index.
  static int _byteOf(Object? v, int limit) {
    if (v is! num) return 0;
    final i = v.toInt();
    return i >= 0 && i < limit ? i : 0;
  }
}

/// The `cit` columns while they are being built, before the string table is
/// sorted. Plain lists, because this is JSON's own shape and it is written
/// once per save; [moveSites] carries the two site columns over the sort the
/// car rows also go through.
class _CitRows {
  final List<int> home = <int>[];
  final List<int> work = <int>[];
  final List<int> state = <int>[];
  final List<int> flags = <int>[];
  final List<int> wakeInUs = <int>[];

  /// Every site index moved to where [moved] put its id.
  void moveSites(Int32List moved) {
    for (var k = 0; k < home.length; k++) {
      final h = home[k];
      if (h >= 0 && h < moved.length) home[k] = moved[h];
      final w = work[k];
      if (w >= 0 && w < moved.length) work[k] = moved[w];
    }
  }

  Map<String, Object?> toJson() => {
        'home': home,
        'work': work,
        'state': state,
        'wakeInUs': wakeInUs,
        'flags': flags,
      };
}
