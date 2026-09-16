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
/// **The version.** The block carries its own `v`, and it says the LOWEST
/// version that can read it back: 1 while it is the flag alone, 2 once it
/// carries the site and car tables (§14.4 additive). So a colony that has
/// parked nothing writes the bytes it wrote before T4a, and a colony that
/// has parked something says 2 — which a build that reads only 1 drops
/// whole, rather than half-reading. `GameStateCodec.schemaVersion` stays 1.
library;

import 'dart:typed_data';

import 'parked_cars.dart';

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
      required this.cars});

  /// The `v` the block carried: 1 (the flag alone) or 2.
  final int version;

  /// Whether the colony runs agents.
  final bool enabled;

  /// The site id strings, sorted: every column indexes these (§14.1).
  final List<String> sites;

  /// The parked cars.
  final SavedCars cars;
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
  /// [cars] of [world].
  ///
  /// [cars] and [world] go together: without a world the codec cannot name a
  /// car's site or a kerb car's pose, so it writes the flag alone — which is
  /// also what a colony that has parked nothing writes.
  ///
  /// Rows are written in a total order of their own numbers, not in slot
  /// order: a colony resumed from a save re-creates its cars in another slot
  /// order, and saving it again must write the same bytes (the fidelity
  /// graft, §14.1).
  static Map<String, Object?> encode(
      {required bool enabled, ParkedCarTable? cars, CarSaveSource? world}) {
    final rows = <List<num>>[];
    final ids = <String>[];
    if (cars != null && world != null) {
      _writeCars(cars, world, rows, ids);
    }
    if (rows.isEmpty) return {'v': oldestVersion, 'enabled': enabled};
    return {
      'v': version,
      'enabled': enabled,
      'sites': ids,
      'cars': rows,
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
        version: v, enabled: enabled, sites: sites, cars: cars);
  }

  /// Puts every car of [saved] back into [sink], in §14.1's order: the key,
  /// then the nearest free stall, then the garage; and an unknown site drops
  /// its cars.
  static RestoreTally restoreCars(SavedAgents saved, CarRestoreSink sink) {
    final cars = saved.cars;
    var lot = 0, kerb = 0, garaged = 0, dropped = 0;
    for (var i = 0; i < cars.count; i++) {
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
  /// name collected into [ids], sorted (§14.1).
  ///
  /// A lot row is `[ownerKind, ownerIdx, where, siteIdx, stallKey, kind,
  /// variant]` and a kerb row `[ownerKind, ownerIdx, where, e, n,
  /// headingMilli, kind, variant]` (§4 Q2, site-access §7.5). A garaged car
  /// takes the lot row with no stall key, so it keeps the site it belongs
  /// to and comes back there when its owner drives again.
  static void _writeCars(ParkedCarTable cars, CarSaveSource world,
      List<List<num>> rows, List<String> ids) {
    final byId = <String, int>{};
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
      var site = -1;
      if (id != null) {
        site = byId[id] ?? -1;
        if (site < 0) {
          site = ids.length;
          ids.add(id);
          byId[id] = site;
        }
      }
      // A kerb car with no pose left cannot be put back at a kerb: it is
      // saved garaged at the site it belongs to.
      final lot = w == CarWhere.lot;
      rows.add([
        ownerKind,
        owner,
        lot ? CarWhere.lot.index : CarWhere.garaged.index,
        site,
        lot ? cars.stallKey[i] : -1,
        kind,
        variant,
      ]);
    }
    _sortIds(rows, ids);
    rows.sort(_compareRows);
  }

  /// [ids] sorted, with every row's site index moved with them: the string
  /// table is sorted by site id, so a save is deterministic (§14.1).
  static void _sortIds(List<List<num>> rows, List<String> ids) {
    final n = ids.length;
    if (n == 0) return;
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
