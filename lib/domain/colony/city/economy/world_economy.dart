// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// ONE world market for a whole game: Earth's market and the world's
/// learning state, with a single owner (docs/plans/dynamic-markets.md
/// phase 5).
///
/// Before this, every colony carried its own copy of Earth's market and of
/// the world clock (phase 1 said so: "each colony carries its own copy
/// until phase 5"). Two colonies each stepped "the world" once per close,
/// so the world aged twice as fast with two colonies, and a colony's
/// exports depressed only its own Earth: the other colony still sold into
/// a world that had never seen them.
///
/// **Ownership.** The host that holds every colony owns the world: the
/// `CityRepository` (`application/ports/world_repositories.dart`), which
/// [join]s each colony as it is added and lets it [leave] as it is removed.
/// A colony that stands alone (the city-builder screen, a test) holds a
/// private [WorldEconomy] of its own and behaves exactly as before: its
/// world steps on each of its closes.
///
/// **The world's day.** Colonies close their economy days on their own
/// clocks (founded at different times, they close at different moments of
/// a tick). The world steps once per round of closes ([closeColonyDay]):
/// when every member has closed since the last step, or when a member
/// closes a SECOND day before the rest have closed one (a colony the host
/// is holding back must not stop the world). With one member that is every
/// close, the pre-phase-5 cadence exactly. The step sums every colony's
/// trade with Earth in colony-id order (not the order they closed in), so
/// the same closes give the same world whatever order the host ran them.
///
/// **Migration (old saves).** A save from before phase 5 has no world
/// state of its own, only each colony's copy. As each colony joins, the
/// world keeps the MOST ADVANCED copy: the one with the highest world day
/// (ties keep what the world already has, so the first colony in the save
/// wins a tie). Rationale: world time only moves forward and world output
/// only grows, so the most advanced copy is the one that has seen the most
/// of the world; the others' extra knowledge (their own exports' effect on
/// their own Earth) is a few days' worth and is dropped rather than summed
/// twice. A save from phase 5 on carries the world once ([toJson]) and its
/// colonies carry none.
///
/// Pure and deterministic: every map a [SplayTreeMap] walked in key order.
library;

import 'dart:collection';

import 'inter_colony_trade.dart';
import 'learning.dart';
import 'markets.dart';

/// One colony's trade with Earth over its closed day: what the world's
/// step adds to Earth's demand and supply and to world output.
class WorldDayShare {
  const WorldDayShare({
    this.importsPerS = const {},
    this.exportsPerS = const {},
    this.daySec = 0,
  });

  /// Per good, what the colony bought from Earth (Earth's demand) and sold
  /// it (Earth's supply), units/s over its day.
  final Map<String, double> importsPerS;
  final Map<String, double> exportsPerS;

  /// The length of that day, colony seconds (exports × this = units the
  /// world's learning counts).
  final double daySec;

  Map<String, Object?> toJson() => {
    if (importsPerS.isNotEmpty) 'imp': {...importsPerS},
    if (exportsPerS.isNotEmpty) 'exp': {...exportsPerS},
    'sec': daySec,
  };

  static WorldDayShare fromJson(Map<String, Object?> j) {
    Map<String, double> m(Object? o) => {
      for (final e in ((o as Map?) ?? const {}).entries)
        e.key as String: (e.value as num).toDouble(),
    };
    return WorldDayShare(
      importsPerS: m(j['imp']),
      exportsPerS: m(j['exp']),
      daySec: (j['sec'] as num?)?.toDouble() ?? 0,
    );
  }
}

class WorldEconomy {
  /// [shared] true for the host-owned world every colony of a game joins;
  /// false for a lone colony's private one. A shared world is saved once
  /// by its owner, so its colonies leave it out of their own saves.
  WorldEconomy({this.shared = false});

  final bool shared;

  /// Earth's market: every good's world price, moved by world supply and
  /// demand plus every colony's trade with it.
  Market earth = Market();

  /// The world clock and world output. Every member's `TechState.world` is
  /// this very object; it is mutated in place, never replaced, while a
  /// colony holds it (a lone colony's test may swap its whole `TechState`,
  /// and its private world follows: `ColonyEconomy.tech`).
  WorldTech tech = WorldTech();

  /// The colonies trading in this world, by id (runtime: the host re-joins
  /// them on load).
  final SplayTreeMap<String, TradePartner> members = SplayTreeMap();

  /// Each colony's trade with Earth over the day it closed since the
  /// world's last step, by colony id. Saved: a save between closes must
  /// step the world on the same totals as an unsaved game.
  final SplayTreeMap<String, WorldDayShare> pending = SplayTreeMap();

  /// Every member but [colonyId], in id order: its possible trade partners.
  List<TradePartner> partnersOf(String colonyId) => [
    for (final e in members.entries)
      if (e.key != colonyId) e.value,
  ];

  /// Takes [p] into this world. A colony coming from another (its private
  /// one, or an old save's copy) brings its world state if that is MORE
  /// advanced than this one's (the migration rule, library doc).
  void join(TradePartner p) {
    final e = p.economy;
    if (!identical(e.world, this)) {
      final old = e.world;
      if (old.tech.day > tech.day) {
        tech.copyFrom(old.tech);
        earth = Market.fromJson(old.earth.toJson());
      }
      e.attachWorld(this);
    }
    members[p.colonyId] = p;
  }

  /// Lets colony [colonyId] go: it keeps a private copy of the world as it
  /// stands, so it can run on alone.
  void leave(String colonyId) {
    final p = members.remove(colonyId);
    if (p == null) return;
    if (identical(p.economy.world, this)) p.economy.detachWorld();
  }

  /// A copy of this world's state with no members and no pending day: a
  /// colony leaving takes one.
  WorldEconomy privateCopy() => WorldEconomy()
    ..earth = Market.fromJson(earth.toJson())
    ..tech.copyFrom(tech);

  /// Records colony [colonyId]'s closed day ([share]) and steps the world
  /// when the round is complete (library doc): a second close by a colony
  /// already counted ends the round first; a world with every member
  /// counted (or none at all: a lone colony) steps now. [tech] is the
  /// closing colony's learning state, whose world is this one's: its
  /// catalog names what the world makes. Returns the number of world days
  /// stepped (0 or 1; 2 when a second close ends one round and completes
  /// the next).
  int closeColonyDay(String colonyId, WorldDayShare share, TechState tech) {
    var steps = 0;
    if (pending.containsKey(colonyId)) {
      _step(tech);
      steps++;
    }
    pending[colonyId] = share;
    if (members.keys.every(pending.containsKey)) {
      _step(tech);
      steps++;
    }
    return steps;
  }

  /// One world day: world output (plus every colony's exports) advances the
  /// learning curves, Earth's anchors follow them, and Earth's market steps
  /// on its depth plus every colony's trade, summed in colony-id order.
  void _step(TechState t) {
    final imports = SplayTreeMap<String, double>();
    final exports = SplayTreeMap<String, double>();
    final exportUnits = SplayTreeMap<String, double>();
    for (final s in pending.values) {
      final sec = s.daySec;
      for (final c in (s.importsPerS.keys.toList()..sort())) {
        imports[c] = (imports[c] ?? 0) + s.importsPerS[c]!;
      }
      for (final c in (s.exportsPerS.keys.toList()..sort())) {
        final x = s.exportsPerS[c]!;
        exports[c] = (exports[c] ?? 0) + x;
        exportUnits[c] = (exportUnits[c] ?? 0) + x * sec;
      }
    }
    pending.clear();
    if (earth.isEmpty) earth = seedEarthMarketFor(t);
    t.world.advanceDay(t.catalog, exportsUnits: exportUnits);
    applyWorldTech(earth, t);
    closeEarthDay(earth, importsPerS: imports, exportsPerS: exports);
  }

  /// Back to the world's first day, members and all gone: a game being
  /// loaded over this one. In place, so nothing holding [tech] is left on a
  /// stale copy.
  void reset() {
    for (final id in members.keys.toList()) {
      leave(id);
    }
    earth = Market();
    tech
      ..day = 0
      ..q.clear();
    pending.clear();
  }

  Map<String, Object?> toJson() => {
    ...tech.toJson(),
    if (!earth.isEmpty) 'earthMkt': earth.toJson(),
    if (pending.isNotEmpty)
      'pending': {for (final e in pending.entries) e.key: e.value.toJson()},
  };

  /// Restores a saved world in place (members keep their hold on [tech]).
  void restore(Map<String, Object?> j) {
    tech.restore(j);
    final e = j['earthMkt'];
    earth = Market.fromJson(e is Map ? e.cast<String, Object?>() : null);
    pending.clear();
    ((j['pending'] as Map?) ?? const {}).forEach((k, v) {
      pending[k as String] = WorldDayShare.fromJson(
        (v as Map).cast<String, Object?>(),
      );
    });
    // A member's cached solve read the world as it was.
    for (final p in members.values) {
      p.economy.market = null;
    }
  }
}
