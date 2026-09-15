// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// [SiteAccessBook]: where a colony's site access plans live
/// (docs/plans/site-access.md §4, §3.7a plan-time rules, §7.6).
///
/// The book owns every derived plan of a [CitySim]: it walks the colony's
/// built sites, decides which need a (re)plan, generates them through the R2
/// dispatch (`planSite`), and publishes immutable [SiteAccessChunk]s of
/// [kSitesPerChunk] sites, copy-on-write. Nothing here is saved: a load
/// re-derives the same plans (§4.4).
///
/// - **Slots.** A planned site takes the lowest free slot on first appearance
///   and keeps it while it lives (renames included). Slot `s` lives in chunk
///   `s ~/ kSitesPerChunk`, whose rows are its live slots in ascending order.
/// - **Resumable sync, counted budgets (§4.2, §4.3).** Each [sync] spends at
///   most `maxChecks` site checks and `maxUnits` generation units (kerbOnly
///   1, homeDriveway 2, carPark / yard 16, installation 128; at least one
///   plan per call), then resumes where it stopped. The easement-priority
///   sites (slot 0 `kJoinEasement`, §3.7a rule 3) are checked first, outside
///   both budgets. A road edit queues only the built lots in its dirty box
///   (checked next, marked [isStale]); the rest of the colony is re-resolved
///   against the new graph by the resumable walk.
/// - **Checks.** A site whose lot, building and graph stamp are unchanged
///   costs two identity compares. Otherwise its input signature (§3.9: the
///   polygon at 1 cm, frontage, graded, spec, and every slot's road id, arc,
///   side, directions, room, flags, kerb point bits and crossed lots with
///   their built bits) is recomputed: unchanged, the plan is re-resolved in
///   place (join handles, pieces, `graphStamp`; `rev` kept); changed, the
///   site is re-planned.
/// - **The first sync** of a book drains in full whatever budgets it is
///   given (the load and generation drain of §4.1, see the deviation note in
///   §4.1).
///
/// Determinism (§3.9): no platform hash, draw, clock, map or set iteration,
/// no trigonometry. Maps here are lookups only; everything walked is a list.
library;

import 'dart:collection';
import 'dart:typed_data';

import '../city_building_spec.dart';
import '../city_sim.dart';
import '../hash32.dart';
import '../parcel.dart';
import '../road_graph.dart';
import '../spatial_index.dart';
import 'site_access_constants.dart';
import 'site_access_plan.dart';
import 'site_easement.dart' as site_easement show easementOf;
import 'site_easement.dart' show SiteEasement;
import 'site_plan_builder.dart';
import 'site_plan_generator.dart';
import 'site_plan_validator.dart';
import 'site_program.dart';

typedef _L = SiteChunkLayout;

/// The easement rule the book applies to each stored plan (§3.7a rule 2):
/// `easementOf` in production, a fake in tests.
typedef SiteEasementRule = SiteEasement Function(
    RoadGraph graph, SiteAccessPlan plan, bool Function(int lot) lotBuilt);

/// What one [SiteAccessBook.sync] did (tests, benches, the dev hook).
class SiteAccessSyncStats {
  /// Site checks spent inside the check budget, and outside it (the
  /// easement-priority sites).
  int checks = 0, priorityChecks = 0;

  /// Generation units charged, plans generated, plans re-resolved in place,
  /// plans dropped, chunks republished.
  int units = 0, generated = 0, resolved = 0, dropped = 0, chunks = 0;

  /// Whether the book was complete when the call returned.
  bool complete = false;

  Map<String, Object> toJson() => {
        'checks': checks,
        'priorityChecks': priorityChecks,
        'units': units,
        'generated': generated,
        'resolved': resolved,
        'dropped': dropped,
        'chunks': chunks,
        'complete': complete,
      };
}

/// One site the book knows: a built lot or grid cell it has checked.
class _Site {
  _Site(this.id);

  String id;

  /// Grid anchor for a cell site; −1 for a lot.
  int anchor = -1;

  /// The lot and building the signature was taken from (identity compares).
  Parcel? parcel;
  CityBuildingSpec? spec;

  bool hasSig = false;
  int polySig = 0, slotSig = 0;

  /// The graph stamp the site was last checked / resolved against.
  int stamp = 0;

  /// Whether any slot's corridor crosses a lot (its built bits must be
  /// re-read on every check).
  bool crosses = false;

  /// Planned slot, or −1 (a built site that stores no plan).
  int slot = -1;

  /// Its graph lot at [stamp] (−1 for a cell or a lot outside the graph).
  int graphLot = -1;

  /// Whether its plan uses the side-street slot (then that slot is hashed
  /// into [slotSig]).
  bool usesSide = false;

  /// Whether slot 0 carries a real access corridor (kJoinEasement or
  /// kJoinOffFrontage), so [SiteAccessBook.corridorHits] tests it.
  bool corridor = false;

  /// Lot ids this site's plan makes easements of.
  List<String> easement = const [];

  int seenPass = -1;
  bool dead = false;
}

/// A published row copied into a new chunk, optionally re-resolved or renamed.
class _Row {
  _Row(this.chunk, this.site, this.id, [this.resolve]);
  final SiteAccessChunk chunk;
  final int site;
  final String id;
  final _Resolve? resolve;
}

/// A plan's graph resolution at a new graph: `graphStamp`, `graphLot`, and per
/// join its handle, piece and road number.
class _Resolve {
  _Resolve(this.stamp, this.graphLot, this.refs, this.pieces, this.roadNos);
  final int stamp, graphLot;
  final Int32List refs, pieces, roadNos;
}

/// A pending change to one slot, applied at flush.
class _Change {
  _Change.write(this.builderChunk, this.builderRow)
      : resolve = null,
        drop = false,
        rename = null;
  _Change.resolve(this.resolve)
      : builderChunk = -1,
        builderRow = -1,
        drop = false,
        rename = null;
  _Change.drop()
      : builderChunk = -1,
        builderRow = -1,
        resolve = null,
        drop = true,
        rename = null;
  _Change.rename(this.rename)
      : builderChunk = -1,
        builderRow = -1,
        resolve = null,
        drop = false;

  final int builderChunk, builderRow;
  final _Resolve? resolve;
  final bool drop;
  final String? rename;
}

/// The colony's site access plans. See the library comment.
class SiteAccessBook {
  SiteAccessBook({
    this.generators = SiteGenerators.standard,
    SiteEasementRule easements = site_easement.easementOf,
    this.validate = false,
  }) : _easementRule = easements;

  /// The generation units one sync may spend by default (§4.3).
  static const int defaultUnitsPerTick = 128;

  /// The site checks one sync may spend by default (§4.2, §4.3).
  static const int defaultChecksPerTick = 4096;

  /// A budget that never runs out (drains).
  static const int unlimited = 0x3FFFFFFF;

  /// How many changes [changedSince] remembers.
  static const int changeLogSize = 4096;

  /// The generators plans are dispatched to (fakes in tests).
  final SiteGenerators generators;

  /// Validate every chunk built at sync against V1–V13 (debug builds only;
  /// tests turn it on). Off in the colony: A1 and the property tests gate
  /// the generators.
  final bool validate;

  final SiteEasementRule _easementRule;

  // ---- published state -------------------------------------------------------

  final List<SiteAccessChunk> _chunks = [];
  final List<int> _rowOfSlot = [];
  final List<_Site?> _bySlot = [];

  /// Free slots, DESCENDING, so the lowest is `removeLast`.
  final List<int> _freeSlots = [];

  final Map<String, _Site> _byId = {};
  final List<_Site> _sites = [];
  final Map<String, String> _easementByLot = {};

  int _sitesRev = 0;
  final List<String> _log = List.filled(changeLogSize, '');
  int _logged = 0;

  // ---- sync state ---------------------------------------------------------------

  RoadGraph? _graph;
  int _stamp = 0;
  bool _everSynced = false;
  int _layoutVersion = -1, _useRevision = -1, _placed = -1, _grownLots = -1;
  int _tierRevision = -1, _utils = -1, _gridGrown = -1, _zones = -1;
  int _abandoned = -1;

  List<Parcel> _walkLots = const [];
  List<(int, CityBuildingSpec)> _walkCells = const [];
  int _cursor = 0, _passNo = 0;
  bool _passActive = false, _rewalk = false;

  final List<String> _queue = [];
  int _queueHead = 0;
  final Set<String> _queued = {};

  List<String> _priorityIds = const [];

  // Per-sync scratch.
  CitySim? _city;
  RoadGraph? _g;
  bool Function(int lot)? _builtFn;

  /// `fnv1a32` of each road id of the graph last stamped.
  Int32List _roadHash = Int32List(0);
  int _maxUnits = 0;
  PlanBuilder? _builder;
  final List<SiteAccessChunk> _builtChunks = [];
  final Map<int, _Change> _changes = {};
  final List<int> _changedSlots = [];

  /// What the last [sync] did.
  SiteAccessSyncStats lastSync = SiteAccessSyncStats();

  /// Tests only: the corridor source [corridorHits] answers from instead of
  /// the plans (a placement refusal test without a filled-in installation
  /// generator).
  List<String> Function(List<Vec2> polygon)? debugCorridorHits;

  // ---- reads -----------------------------------------------------------------------

  /// Moves when any plan appears, goes or changes `rev`.
  int get sitesRev => _sitesRev;

  /// The published chunks. A chunk's identity changes only when one of its
  /// sites changed (appeared, went, changed, was re-resolved or renamed).
  List<SiteAccessChunk> get chunks => UnmodifiableListView(_chunks);

  /// [siteId]'s slot, or −1 when it has no plan. Stable while the site
  /// lives; a rename keeps it.
  int slotOf(String siteId) => _byId[siteId]?.slot ?? -1;

  /// [siteId]'s plan, or null. Allocates a view: sync, tests and diagnostics.
  SiteAccessPlan? planOf(String siteId) {
    final rec = _byId[siteId];
    if (rec == null || rec.slot < 0) return null;
    final row = _rowOfSlot[rec.slot];
    if (row < 0) return null;
    return _chunks[rec.slot ~/ kSitesPerChunk].plan(row);
  }

  /// The ids whose plans appeared, went or changed `rev` after [sitesRev],
  /// oldest first, each once; null when that is older than the log.
  List<String>? changedSince(int sitesRev) {
    if (sitesRev >= _sitesRev) return const [];
    final n = _sitesRev - sitesRev;
    if (n > _logged || n > changeLogSize) return null;
    final out = <String>[];
    final seen = <String>{};
    for (var r = sitesRev; r < _sitesRev; r++) {
      final id = _log[r % changeLogSize];
      if (seen.add(id)) out.add(id);
    }
    return out;
  }

  /// Whether [siteId] is queued for a check since the last graph or layout
  /// change (§4.2): its plan may be out of date.
  bool isStale(String siteId) => _queued.contains(siteId);

  /// Whether [siteId]'s plan was resolved against [g]'s structure and is not
  /// queued for a check. Traffic reads a site that is not current as
  /// kerbside at [g]'s slot 0 (§4.2 step 3). Decided by stamps alone, so a
  /// headless and a rendered run agree.
  bool isCurrentFor(String siteId, RoadGraph g) {
    final p = planOf(siteId);
    return p != null && p.graphStamp == g.structureStamp && !isStale(siteId);
  }

  /// The site the unbuilt auto lot [lotId] is an access easement for (§3.7a
  /// rule 2), or null.
  String? easementOf(String lotId) => _easementByLot[lotId];

  /// The sites whose live access corridor (§3.7a: slot 0 `kJoinEasement` or
  /// `kJoinOffFrontage`, the throat stretch outside the site's own lot, half
  /// width `kAccessCorridorHalfM`) [polygon] overlaps, sorted.
  List<String> corridorHits(List<Vec2> polygon) {
    final fake = debugCorridorHits;
    if (fake != null) return fake(polygon);
    if (polygon.length < 3) return const [];
    final box = Box2.of(polygon);
    final out = <String>[];
    for (final rec in _sites) {
      if (rec.dead || !rec.corridor || rec.slot < 0) continue;
      final p = planOf(rec.id);
      final own = rec.parcel;
      if (p == null || own == null) continue;
      if (_corridorHit(p, own, polygon, box)) out.add(rec.id);
    }
    out.sort();
    return out;
  }

  // ---- hooks ---------------------------------------------------------------------------

  /// Re-keys every site [renamed] names (old id → new id); `rev`, slots and
  /// rows are kept. Order-independent: every new id is taken from the ids as
  /// they stood before the call.
  void onLotsRenamed(Map<String, String> renamed) {
    if (renamed.isEmpty) return;
    final moved = <(_Site, String)>[];
    for (final rec in _sites) {
      if (rec.dead) continue;
      final to = renamed[rec.id];
      if (to != null && to != rec.id) moved.add((rec, to));
    }
    for (final (rec, _) in moved) {
      if (identical(_byId[rec.id], rec)) _byId.remove(rec.id);
    }
    for (final (rec, to) in moved) {
      final from = rec.id;
      rec.id = to;
      _byId[to] = rec;
      for (final lot in rec.easement) {
        if (_easementByLot[lot] == from) _easementByLot[lot] = to;
      }
      if (rec.slot >= 0 && _rowOfSlot[rec.slot] >= 0) {
        _record(rec.slot, _Change.rename(to));
      }
    }
    for (var i = _queueHead; i < _queue.length; i++) {
      final to = renamed[_queue[i]];
      if (to != null) {
        _queued.remove(_queue[i]);
        _queue[i] = to;
      }
    }
    for (var i = _queueHead; i < _queue.length; i++) {
      _queued.add(_queue[i]);
    }
    _priorityIds = [for (final id in _priorityIds) renamed[id] ?? id];
    _flush();
  }

  /// Drops [siteId]'s plan now (demolished, cleared): its easements lift and
  /// [sitesRev] moves.
  void onLotCleared(String siteId) {
    final rec = _byId[siteId];
    if (rec == null) return;
    _forget(rec);
    _flush();
  }

  // ---- sync ----------------------------------------------------------------------------

  /// Brings the plans up to date with [city] over [g], spending at most
  /// [maxChecks] site checks and [maxUnits] generation units (the
  /// easement-priority sites outside both). True when nothing is left to do.
  bool sync(CitySim city, RoadGraph g,
      {int maxUnits = defaultUnitsPerTick,
      int maxChecks = defaultChecksPerTick}) {
    if (!_everSynced) {
      maxUnits = unlimited;
      maxChecks = unlimited;
    }
    final stats = lastSync = SiteAccessSyncStats();
    _city = city;
    _g = g;
    _builtFn = _built;
    _maxUnits = maxUnits;
    final layout = city.layout;
    final stamp = g.structureStamp;

    // Triggers (§4.2): integer compares unless something moved.
    final old = _graph;
    if (old == null || stamp != _stamp) {
      if (old != null) _queueDirtyBox(old, g, city);
      _priorityIds = _priorityOf(g);
      final hashes = Int32List(g.roadCount);
      for (var r = 0; r < g.roadCount; r++) {
        hashes[r] = old != null &&
                r < old.roadCount &&
                r < _roadHash.length &&
                identical(old.roads[r], g.roads[r])
            ? _roadHash[r]
            : fnv1a32(g.roads[r].id);
      }
      _roadHash = hashes;
      _stamp = stamp;
      _startPass(city);
    }
    _graph = g;
    if (layout.version != _layoutVersion) {
      _layoutVersion = layout.version;
      _startPass(city);
    }
    if (_builtKeyMoved(city)) {
      // A walk that has not begun sees the change anyway.
      if (_passActive && _cursor > 0) {
        _rewalk = true;
      } else {
        _startPass(city);
      }
    }

    var stopped = false;
    // 1. Easement-priority sites, outside both budgets (§3.7a rule 3).
    for (final id in _priorityIds) {
      final parcel = layout.parcelById(id);
      if (parcel == null) continue;
      _check(id, parcel, -1, _lotSpec(city, parcel), priority: true);
      stats.priorityChecks++;
    }
    // 2. The dirty box queue.
    while (_queueHead < _queue.length) {
      if (stats.checks >= maxChecks) {
        stopped = true;
        break;
      }
      final id = _queue[_queueHead];
      final parcel = layout.parcelById(id);
      if (parcel != null &&
          !_check(id, parcel, -1, _lotSpec(city, parcel), queued: true)) {
        stopped = true;
        break;
      }
      _queued.remove(id);
      _queueHead++;
      stats.checks++;
    }
    if (_queueHead >= _queue.length) {
      _queue.clear();
      _queueHead = 0;
    }
    // 3. The walk.
    if (!stopped && _passActive) {
      final nLots = _walkLots.length, total = nLots + _walkCells.length;
      while (_cursor < total) {
        if (stats.checks >= maxChecks) break;
        final bool ok;
        if (_cursor < nLots) {
          // Zoning replaces a lot's Parcel without a new walk: read it now.
          final walked = _walkLots[_cursor];
          final p = layout.parcelById(walked.id) ?? walked;
          ok = _check(p.id, p, -1, _lotSpec(city, p));
        } else {
          final (anchor, spec) = _walkCells[_cursor - nLots];
          ok = _check(CitySim.siteIdOfCell(anchor), null, anchor, spec);
        }
        if (!ok) break;
        _cursor++;
        stats.checks++;
      }
      if (_cursor >= total) _endPass(city);
    }
    _flush();
    _everSynced = true;
    _city = null;
    _g = null;
    _builtFn = null;
    stats.complete = _queue.isEmpty && !_passActive && !_rewalk;
    return stats.complete;
  }

  /// The cheap built-state trigger (§4.2): counts and revision counters.
  bool _builtKeyMoved(CitySim city) {
    final use = city.layout.useRevision,
        placed = city.parcelBuildings.length,
        grownLots = city.grownParcels.length,
        tier = city.parcelTierRevision,
        utils = city.utils.length,
        gridGrown = city.grown.length,
        zones = city.zones.length,
        abandoned = city.abandoned.length;
    final moved = use != _useRevision ||
        placed != _placed ||
        grownLots != _grownLots ||
        tier != _tierRevision ||
        utils != _utils ||
        gridGrown != _gridGrown ||
        zones != _zones ||
        abandoned != _abandoned;
    _useRevision = use;
    _placed = placed;
    _grownLots = grownLots;
    _tierRevision = tier;
    _utils = utils;
    _gridGrown = gridGrown;
    _zones = zones;
    _abandoned = abandoned;
    return moved;
  }

  /// Whether graph lot [lot] of the graph being synced has a building.
  bool _built(int lot) {
    final g = _g!, city = _city!;
    final lotId = g.lotIds[lot];
    if (city.parcelBuildings.containsKey(lotId)) return true;
    final p = city.layout.parcelById(lotId);
    return p != null && city.parcelGrownSpec(lotId, p.use) != null;
  }

  static CityBuildingSpec? _lotSpec(CitySim city, Parcel p) =>
      city.parcelBuildings[p.id] ?? city.parcelGrownSpec(p.id, p.use);

  /// Starts a walk over the colony's sites in §4.1 order: manual lots, auto
  /// lots, then occupied cells in ascending anchor order (abandoned cells
  /// skipped; an anchor reported twice walks once, its first report).
  void _startPass(CitySim city) {
    _walkLots = city.layout.parcels;
    final cells = <(int, int, CityBuildingSpec)>[];
    for (final cell in city.occupiedCells()) {
      if (city.abandoned.contains(cell.key)) continue;
      cells.add((cell.key, cells.length, cell.value));
    }
    cells.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2 - b.$2);
    final walk = <(int, CityBuildingSpec)>[];
    for (final (anchor, _, spec) in cells) {
      if (walk.isNotEmpty && walk.last.$1 == anchor) continue;
      walk.add((anchor, spec));
    }
    _walkCells = walk;
    _cursor = 0;
    _passNo++;
    _passActive = true;
    _rewalk = false;
  }

  /// A finished walk: every site it did not see is gone.
  void _endPass(CitySim city) {
    for (final rec in _sites) {
      if (!rec.dead && rec.seenPass != _passNo) _forget(rec);
    }
    _sites.removeWhere((r) => r.dead);
    _passActive = false;
    if (_rewalk) _startPass(city);
  }

  /// The lots whose slot 0 carries `kJoinEasement`, in graph lot order.
  static List<String> _priorityOf(RoadGraph g) {
    final out = <String>[];
    for (var lot = 0; lot < g.lotCount; lot++) {
      final k = g.lotJoinStart[lot];
      if (k < g.lotJoinStart[lot + 1] && g.joinFlags[k] & kJoinEasement != 0) {
        out.add(g.lotIds[lot]);
      }
    }
    return out;
  }

  /// §4.2 step 1: the dirty box of a structure change — the boxes of the
  /// roads added, removed or changed, and of the lots new to the graph —
  /// inflated by the longest access corridor; the built lots it meets are
  /// queued for a check, sorted by id.
  void _queueDirtyBox(RoadGraph old, RoadGraph g, CitySim city) {
    double? e0, n0, e1, n1;
    void grow(Box2 b) {
      e0 = e0 == null || b.minE < e0! ? b.minE : e0;
      n0 = n0 == null || b.minN < n0! ? b.minN : n0;
      e1 = e1 == null || b.maxE > e1! ? b.maxE : e1;
      n1 = n1 == null || b.maxN > n1! ? b.maxN : n1;
    }

    // Roads: the same RoadSpline at the same index is unchanged without a
    // lookup (a road edit appends and splits; the rest keep their places).
    for (var r = 0; r < g.roadCount; r++) {
      if (r < old.roadCount && identical(old.roads[r], g.roads[r])) continue;
      final o = old.roadNoOf(g.roads[r].id);
      if (o == null || !_sameRoad(old, o, g, r)) {
        grow(g.roadRecs[r].box);
        if (o != null) grow(old.roadRecs[o].box);
      }
    }
    for (var r = 0; r < old.roadCount; r++) {
      if (r < g.roadCount && identical(old.roads[r], g.roads[r])) continue;
      if (g.roadNoOf(old.roads[r].id) == null) grow(old.roadRecs[r].box);
    }
    // A new manual lot (a claimed site) re-cuts the auto lots around it, so
    // its box covers theirs; auto lots re-cut by a road lie near that road.
    final layout = city.layout;
    for (final p in layout.manualParcels) {
      if (old.lotNoOf(p.id) == null) grow(Box2.of(p.polygon));
    }
    if (e0 == null) return;
    final reach = dirtyReachM;
    final box = Box2(e0! - reach, n0! - reach, e1! + reach, n1! + reach);
    // The index keeps the parcels it was built with; zoning replaces them.
    final ids = <String>[];
    for (final near in layout.parcelsNear(box)) {
      final p = layout.parcelById(near.id);
      if (p != null && _lotSpec(city, p) != null) ids.add(p.id);
    }
    ids.sort();
    for (final id in ids) {
      if (_queued.add(id)) _queue.add(id);
    }
  }

  /// How far past a changed road a lot can have a changed slot:
  /// `max(manualReachM + the widest half width, 120 m)` (§4.2).
  static final double dirtyReachM =
      RoadGraph.manualReachM + RoadGraph.maxHalfWidth > 120
          ? RoadGraph.manualReachM + RoadGraph.maxHalfWidth
          : 120;

  static bool _sameRoad(RoadGraph a, int ra, RoadGraph b, int rb) {
    final x = a.roads[ra], y = b.roads[rb];
    if (identical(x, y)) return true;
    if (x.roadClass != y.roadClass ||
        x.decoration != y.decoration ||
        x.reversed != y.reversed) {
      return false;
    }
    final xr = a.roadRecs[ra], yr = b.roadRecs[rb];
    if (xr.e.length != yr.e.length) return false;
    for (var i = 0; i < xr.e.length; i++) {
      if (xr.e[i] != yr.e[i] || xr.n[i] != yr.n[i]) return false;
    }
    return true;
  }

  // ---- one site --------------------------------------------------------------------------

  /// Checks one site; false when it needs a plan the unit budget cannot pay
  /// for (nothing changed, resume here next sync).
  bool _check(String id, Parcel? parcel, int anchor, CityBuildingSpec? spec,
      {bool priority = false, bool queued = false}) {
    var rec = _byId[id];
    if (rec != null && rec.dead) rec = null;
    if (spec == null) {
      if (rec != null) _forget(rec);
      return true;
    }
    final g = _g!, city = _city!;
    if (rec == null) {
      rec = _Site(id);
      _byId[id] = rec;
      _sites.add(rec);
    }
    rec.seenPass = _passNo;
    final sameInputs = rec.hasSig &&
        identical(rec.spec, spec) &&
        (anchor >= 0 ? rec.anchor == anchor : identical(rec.parcel, parcel));
    if (sameInputs && rec.stamp == _stamp && !rec.crosses) return true;
    // A re-cut plat hands every lot a new Parcel: equal values are the same
    // inputs, and cost no hashing.
    final sameValues = sameInputs ||
        (rec.hasSig &&
            _sameSpec(rec.spec!, spec) &&
            (anchor >= 0
                ? rec.anchor == anchor
                : _sameParcel(rec.parcel!, parcel!)));
    if (sameValues && rec.stamp == _stamp && !rec.crosses) {
      if (anchor < 0) rec.parcel = parcel;
      rec.spec = spec;
      return true;
    }

    final built = _builtFn!;
    // A lot's slots are hashed straight off the graph's columns (no context,
    // no allocation); a cell's through its footprint context.
    SiteContext? ctx;
    final int lot;
    final Parcel site;
    final int slotSig;
    final bool crosses;
    if (anchor >= 0) {
      lot = -1;
      ctx = SiteContext.ofFootprint(g, city.parcelForCell(anchor, spec), spec,
          graphStamp: _stamp, lotBuilt: built);
      site = ctx.parcel;
      (slotSig, crosses) = _footprintSlotSig(ctx, g, built);
    } else {
      lot = g.lotNoOf(id) ?? -1;
      site = parcel!;
      (slotSig, crosses) = _lotSlotSig(g, lot, built, withSide: rec.usesSide);
    }
    final polySig = sameValues ? rec.polySig : _polySpecSig(site, spec);
    // A corner car park, yard or installation in the dirty box may take its
    // side street now: re-planned rather than compared (the side-street slot
    // is hashed only into plans that use it).
    final replanCorner = queued &&
        site.isCorner &&
        rec.slot >= 0 &&
        _rowOfSlot[rec.slot] >= 0 &&
        switch (_chunks[rec.slot ~/ kSitesPerChunk]
            .program(_rowOfSlot[rec.slot])) {
          SiteProgram.carPark ||
          SiteProgram.yard ||
          SiteProgram.installation =>
            true,
          _ => false,
        };
    if (!replanCorner &&
        rec.hasSig &&
        polySig == rec.polySig &&
        slotSig == rec.slotSig) {
      // Inputs unchanged: re-resolve against this graph, rev kept.
      if (rec.stamp != _stamp &&
          rec.slot >= 0 &&
          _rowOfSlot[rec.slot] >= 0 &&
          !_changes.containsKey(rec.slot)) {
        _record(rec.slot, _Change.resolve(_resolveOf(rec, g, lot, ctx)));
        lastSync.resolved++;
      }
      rec
        ..stamp = _stamp
        ..graphLot = lot
        ..parcel = site
        ..spec = spec
        ..anchor = anchor
        ..crosses = crosses;
      return true;
    }
    ctx ??= SiteContext.ofLot(g, site, spec,
        graphStamp: _stamp, lotBuilt: built);
    // Re-plan: charge the units first (§4.3).
    final units = _unitsOf(ctx);
    if (!priority &&
        lastSync.units > 0 &&
        lastSync.units + units > _maxUnits) {
      return false;
    }
    lastSync.units += units;
    var b = _builder;
    if (b == null || b.siteCount == kSitesPerChunk) {
      if (b != null) _builtChunks.add(b.build(validate: validate));
      b = _builder = PlanBuilder(graph: g);
    }
    final program = planSite(b, ctx, generators: generators);
    rec
      ..hasSig = true
      ..polySig = polySig
      ..slotSig = rec.usesSide
          ? _lotSlotSig(g, lot, built, withSide: false).$1
          : slotSig
      ..usesSide = false // settled at flush, from the plan's joins
      ..graphLot = lot
      ..stamp = _stamp
      ..parcel = site
      ..spec = spec
      ..anchor = anchor
      ..crosses = crosses
      ..corridor = ctx.slotCount > 0 &&
          ctx.slot0.flags & (kJoinEasement | kJoinOffFrontage) != 0;
    if (program == null) {
      if (rec.slot >= 0) _dropSlot(rec);
      return true;
    }
    lastSync.generated++;
    if (rec.slot < 0) {
      rec.slot = _takeSlot();
      _bySlot[rec.slot] = rec;
    }
    _record(rec.slot, _Change.write(_builtChunks.length, b.siteCount - 1));
    return true;
  }

  static int _unitsOf(SiteContext ctx) {
    final spec = ctx.spec;
    if (spec == null || ctx.slotCount == 0 || ctx.noFrontageRoad) return 1;
    final offer = classifyProgram(
      spec: spec,
      slot0: ctx.slot0,
      widthM: ctx.widthM,
      depthM: ctx.depthM,
      hasFrame: ctx.frame != null,
      lotBuilt: ctx.lotBuilt,
    );
    return switch (offer.program) {
      SiteProgram.installation => 128,
      SiteProgram.carPark || SiteProgram.yard => 16,
      SiteProgram.homeDriveway => 2,
      _ => 1,
    };
  }

  /// One word into a signature hash: FNV-1a over the whole 32-bit word (the
  /// signatures are change detection only, never persisted or compared across
  /// platforms, so a word step is enough and a quarter the cost).
  static int _w(int h, int x) => mul32(h ^ (x & 0xFFFFFFFF), 0x01000193);

  static final Float64List _dblScratch = Float64List(1);
  static final Uint32List _dblWords = _dblScratch.buffer.asUint32List();

  /// A double into a signature hash, by its bits.
  static int _dbl(int h, double x) {
    _dblScratch[0] = x;
    return _w(_w(h, _dblWords[0]), _dblWords[1]);
  }

  static int _cm(double x) => x.isFinite ? (x * 100).round() : 0x7FFFFFFF;

  /// Whether two lots have the same signature inputs, value for value.
  static bool _sameParcel(Parcel a, Parcel b) {
    if (identical(a, b)) return true;
    if (a.graded != b.graded || a.polygon.length != b.polygon.length) {
      return false;
    }
    for (var i = 0; i < a.polygon.length; i++) {
      final p = a.polygon[i], q = b.polygon[i];
      if (p.e != q.e || p.n != q.n) return false;
    }
    bool edge((Vec2, Vec2)? x, (Vec2, Vec2)? y) =>
        identical(x, y) ||
        (x != null &&
            y != null &&
            x.$1.e == y.$1.e &&
            x.$1.n == y.$1.n &&
            x.$2.e == y.$2.e &&
            x.$2.n == y.$2.n);
    return edge(a.frontage, b.frontage) && edge(a.sideStreet, b.sideStreet);
  }

  /// Whether two buildings have the same signature inputs (§3.9).
  static bool _sameSpec(CityBuildingSpec a, CityBuildingSpec b) =>
      identical(a, b) ||
      (a.type == b.type &&
          a.housing == b.housing &&
          a.jobs == b.jobs &&
          a.siteWidthM == b.siteWidthM &&
          a.siteDepthM == b.siteDepthM &&
          a.siteKind == b.siteKind &&
          a.group == b.group);

  /// The lot and building half of the §3.9 input signature.
  static int _polySpecSig(Parcel p, CityBuildingSpec spec) {
    var h = _w(kFnvOffset32, kSiteProgramVersion);
    h = _w(h, p.polygon.length);
    for (final v in p.polygon) {
      h = _w(_w(h, _cm(v.e)), _cm(v.n));
    }
    final f = p.frontage;
    if (f == null) {
      h = _w(h, -1);
    } else {
      h = _w(_w(h, _cm(f.$1.e)), _cm(f.$1.n));
      h = _w(_w(h, _cm(f.$2.e)), _cm(f.$2.n));
    }
    final s = p.sideStreet;
    if (s == null) {
      h = _w(h, -1);
    } else {
      h = _w(_w(h, _cm(s.$1.e)), _cm(s.$1.n));
      h = _w(_w(h, _cm(s.$2.e)), _cm(s.$2.n));
    }
    h = _w(h, p.graded ? 1 : 0);
    h = _w(h, fnv1a32(spec.type));
    h = _w(h, spec.housing);
    h = _w(h, spec.jobs);
    h = _w(h, _cm(spec.siteWidthM));
    h = _w(h, _cm(spec.siteDepthM));
    h = _w(h, spec.siteKind.index);
    return _w(h, fnv1a32(spec.group));
  }

  /// One slot's part of the §3.9 input signature: its road's id, arc, side,
  /// directions, room, flags, the kerb point and normal by their bits, and
  /// the crossed lots with their built bits.
  int _slotHash(int h, RoadGraph g, int piece, double s, bool right, int dirs,
      double roomM, int flags, double kerbE, double kerbN, double normE,
      double normN) {
    h = _w(h, _roadHash[g.pieceRoad[piece]]);
    h = _w(h, (s * 4).round());
    h = _w(h, right ? 1 : 0);
    h = _w(h, dirs);
    h = _w(h, _cm(roomM));
    h = _w(h, flags);
    h = _dbl(_dbl(h, kerbE), kerbN);
    return _dbl(_dbl(h, normE), normN);
  }

  int _crossHash(int h, RoadGraph g, List<int> lots, int from, int to,
      bool Function(int lot) built) {
    h = _w(h, to - from);
    for (var i = from; i < to; i++) {
      h = _w(h, fnv1a32(g.lotIds[lots[i]]));
      h = _w(h, built(lots[i]) ? 1 : 0);
    }
    return h;
  }

  /// The slot half of a graph lot's signature, read off [g]'s join columns
  /// (the lot's packed slots 0 and 1; with [withSide], its side-street slot
  /// too), and whether any slot crosses a lot.
  (int, bool) _lotSlotSig(RoadGraph g, int lot, bool Function(int lot) built,
      {required bool withSide}) {
    if (lot < 0) return (_w(kFnvOffset32, -1), false);
    final k0 = g.lotJoinStart[lot];
    final n = g.lotJoinStart[lot + 1] - k0;
    final count = n < 2 ? n : 2;
    var h = _w(kFnvOffset32, count);
    var crosses = false;
    for (var k = k0; k < k0 + count; k++) {
      h = _slotHash(h, g, g.joinPiece[k], g.joinS[k], g.joinRight[k] == 1,
          g.joinDirs[k], g.joinRoomM[k], g.joinFlags[k], g.joinKerbE[k],
          g.joinKerbN[k], g.joinNormE[k], g.joinNormN[k]);
      final c0 = g.joinCrossStart[k], c1 = g.joinCrossStart[k + 1];
      if (c1 > c0) crosses = true;
      h = _crossHash(h, g, g.joinCrossLot, c0, c1, built);
    }
    if (withSide) h = _sideHash(h, g, lot, built);
    return (h, crosses);
  }

  /// [h] with graph lot [lot]'s side-street slot (placed on first ask).
  int _sideHash(int h, RoadGraph g, int lot, bool Function(int lot) built) {
    final s = g.sideStreetJoinOf(lot);
    if (s == null) return _w(h, -2);
    h = _slotHash(h, g, s.piece, s.s, s.right, s.dirs, s.roomM, s.flags,
        s.kerbE, s.kerbN, s.normE, s.normN);
    return _crossHash(h, g, s.crossLots, 0, s.crossLots.length, built);
  }

  /// The slot half of a footprint's signature, from its context.
  (int, bool) _footprintSlotSig(
      SiteContext ctx, RoadGraph g, bool Function(int lot) built) {
    var h = _w(kFnvOffset32, ctx.slotCount);
    var crosses = false;
    for (var k = 0; k < ctx.slotCount; k++) {
      final s = ctx.slot(k);
      h = _slotHash(h, g, s.piece, s.s, s.right, s.dirs, s.roomM, s.flags,
          s.kerbE, s.kerbN, s.normE, s.normN);
      if (s.crossLots.isNotEmpty) crosses = true;
      h = _crossHash(h, g, s.crossLots, 0, s.crossLots.length, built);
    }
    return (h, crosses);
  }

  /// [rec]'s published plan re-resolved at [g]: a graph lot's joins from the
  /// join columns ([lot]; its side-street join from the placed slot), a
  /// footprint's from its context.
  _Resolve _resolveOf(_Site rec, RoadGraph g, int lot, SiteContext? ctx) {
    final c = _chunks[rec.slot ~/ kSitesPerChunk];
    final row = _rowOfSlot[rec.slot];
    final j0 = c.joinStart(row), n = c.joinCountOf(row);
    final refs = Int32List(n), pieces = Int32List(n), roads = Int32List(n);
    for (var j = 0; j < n; j++) {
      final k = c.joinSlot(j0 + j);
      var ref = kJoinRefNone;
      var piece = c.joinPiece(j0 + j);
      if (ctx != null) {
        if (k < ctx.slotCount) piece = ctx.slot(k).piece;
      } else if (lot >= 0) {
        ref = g.joinRefOf(lot, k);
        if (k == kJoinSlotSideStreet) {
          final s = g.sideStreetJoinOf(lot);
          if (s != null) piece = s.piece;
        } else if (ref >= 0) {
          piece = g.joinPiece[ref];
        }
      }
      refs[j] = ref;
      pieces[j] = piece;
      roads[j] = piece >= 0 && piece < g.pieceCount
          ? g.pieceRoad[piece]
          : c.joinRoadNo(j0 + j);
    }
    return _Resolve(_stamp, lot, refs, pieces, roads);
  }

  // ---- slots and changes ------------------------------------------------------------------

  int _takeSlot() {
    if (_freeSlots.isNotEmpty) return _freeSlots.removeLast();
    _bySlot.add(null);
    _rowOfSlot.add(-1);
    return _bySlot.length - 1;
  }

  void _freeSlot(int slot) {
    var lo = 0, hi = _freeSlots.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_freeSlots[mid] > slot) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    _freeSlots.insert(lo, slot);
  }

  void _record(int slot, _Change change) {
    if (!_changes.containsKey(slot)) _changedSlots.add(slot);
    _changes[slot] = change;
  }

  /// Drops [rec]'s plan (if any) and forgets the site.
  void _forget(_Site rec) {
    if (rec.slot >= 0) _dropSlot(rec);
    rec.dead = true;
    if (identical(_byId[rec.id], rec)) _byId.remove(rec.id);
  }

  void _dropSlot(_Site rec) {
    final slot = rec.slot;
    _liftEasements(rec);
    if (_rowOfSlot[slot] >= 0 || _changes.containsKey(slot)) {
      _record(slot, _Change.drop());
    }
    if (_rowOfSlot[slot] >= 0) _logChange(rec.id);
    _bySlot[slot] = null;
    rec.slot = -1;
    _freeSlot(slot);
    lastSync.dropped++;
  }

  void _logChange(String id) {
    _log[_sitesRev % changeLogSize] = id;
    _sitesRev++;
    if (_logged < changeLogSize) _logged++;
  }

  void _liftEasements(_Site rec) {
    for (final lot in rec.easement) {
      if (_easementByLot[lot] == rec.id) _easementByLot.remove(lot);
    }
    rec.easement = const [];
  }

  /// Publishes every pending change, one new chunk per touched chunk.
  void _flush() {
    final b = _builder;
    if (b != null) {
      if (b.siteCount > 0) _builtChunks.add(b.build(validate: validate));
      _builder = null;
    }
    if (_changedSlots.isEmpty) {
      _builtChunks.clear();
      return;
    }
    _changedSlots.sort();
    final touched = <int>[];
    for (final s in _changedSlots) {
      final c = s ~/ kSitesPerChunk;
      if (touched.isEmpty || touched.last != c) touched.add(c);
    }
    while (_chunks.length <= touched.last) {
      _chunks.add(_pack(const []));
    }
    final written = <int>[];
    for (final c in touched) {
      final old = _chunks[c];
      final rows = <_Row>[];
      final slots = <int>[];
      final end = (c + 1) * kSitesPerChunk < _bySlot.length
          ? (c + 1) * kSitesPerChunk
          : _bySlot.length;
      for (var s = c * kSitesPerChunk; s < end; s++) {
        final ch = _changes[s];
        final oldRow = _rowOfSlot[s];
        if (ch == null) {
          if (oldRow >= 0) {
            rows.add(_Row(old, oldRow, old.siteId(oldRow)));
            slots.add(s);
          }
          continue;
        }
        if (ch.drop) continue;
        if (ch.builderChunk >= 0) {
          final src = _builtChunks[ch.builderChunk];
          rows.add(_Row(src, ch.builderRow, src.siteId(ch.builderRow)));
          written.add(s);
        } else if (oldRow >= 0) {
          rows.add(_Row(old, oldRow, ch.rename ?? old.siteId(oldRow),
              ch.resolve));
        } else {
          continue;
        }
        slots.add(s);
      }
      final chunk = _pack(rows);
      if (validate) {
        assert(() {
          final bad = SitePlanValidator.validateChunk(chunk, graph: _g);
          if (bad.isNotEmpty) {
            throw StateError('SiteAccessBook: invalid plans:\n${bad.join('\n')}');
          }
          return true;
        }());
      }
      // What the written slots held before the swap: a plan appears, or
      // changes rev, or another site took the slot.
      final mine = <int>[], wasRev = <int>[];
      final wasId = <String?>[];
      for (final s in written) {
        if (s ~/ kSitesPerChunk != c) continue;
        final r = _rowOfSlot[s];
        mine.add(s);
        wasRev.add(r >= 0 ? old.rev(r) : 0);
        wasId.add(r >= 0 ? old.siteId(r) : null);
      }
      for (var s = c * kSitesPerChunk; s < end; s++) {
        _rowOfSlot[s] = -1;
      }
      for (var i = 0; i < slots.length; i++) {
        _rowOfSlot[slots[i]] = i;
      }
      _chunks[c] = chunk;
      lastSync.chunks++;
      for (var i = 0; i < mine.length; i++) {
        final row = _rowOfSlot[mine[i]];
        final id = chunk.siteId(row);
        if (wasId[i] != id || wasRev[i] != chunk.rev(row)) _logChange(id);
      }
    }
    // Easements of the plans written or re-resolved (§3.7a rule 2).
    final g = _g;
    final built = _builtFn;
    if (g != null && built != null) {
      for (final s in _changedSlots) {
        final ch = _changes[s]!;
        if (ch.drop || ch.rename != null) continue;
        final rec = _bySlot[s];
        if (rec == null) continue;
        _liftEasements(rec);
        final row = _rowOfSlot[s];
        if (row < 0) continue;
        final chunk = _chunks[s ~/ kSitesPerChunk];
        // A new plan that uses its side-street slot hashes that slot into
        // its signature from now on.
        if (ch.builderChunk >= 0 && rec.graphLot >= 0) {
          final j0 = chunk.joinStart(row), n = chunk.joinCountOf(row);
          for (var j = j0; j < j0 + n; j++) {
            if (chunk.joinSlot(j) != kJoinSlotSideStreet) continue;
            rec
              ..usesSide = true
              ..slotSig = _sideHash(rec.slotSig, g, rec.graphLot, built);
            break;
          }
        }
        final plan = chunk.plan(row);
        if (plan.graphStamp != g.structureStamp) continue;
        final e = _easementRule(g, plan, built);
        if (e.isEmpty) continue;
        final lots = <String>[for (final lot in e.lots) g.lotIds[lot]];
        rec.easement = lots;
        for (final lot in lots) {
          _easementByLot[lot] = rec.id;
        }
      }
    }
    _changes.clear();
    _changedSlots.clear();
    _builtChunks.clear();
  }

  // ---- packing ----------------------------------------------------------------------------------

  /// Per column: 0 a site column, 1 a family start column, 2 a count family
  /// column, 3 a CSR column (count + 1 rows per site).
  static final List<int> _colKind = [
    for (var col = 0; col < SiteCol.count; col++)
      switch (_L.familyOf(col)) {
        _L.fSite => 0,
        _L.fStart => 1,
        _L.fSegVia || _L.fPaveRing || _L.fPathStart => 3,
        _ => 2,
      },
  ];

  /// Per column: the index in `countFamilies` of its family (count
  /// columns) or of the family it extends (CSR columns); −1 otherwise.
  static final List<int> _colFamily = [
    for (var col = 0; col < SiteCol.count; col++)
      switch (_colKind[col]) {
        2 => _L.countFamilies.indexOf(_L.familyOf(col)),
        3 => _L.countFamilies.indexOf(_L.csrBaseFamily(_L.familyOf(col))),
        _ => -1,
      },
  ];

  /// Chunk-global first row of every count family for [site] (13 entries,
  /// then the row past the site's last).
  static void _familyStarts(
      SiteAccessChunk c, int site, Int32List out, int at, int stride) {
    for (var k = 0; k < 2; k++) {
      final s = site + k, o = at + k * stride;
      out[o] = c.ptStart(s);
      out[o + 1] = c.joinStart(s);
      out[o + 2] = c.nodeStart(s);
      out[o + 3] = c.segStart(s);
      out[o + 4] = c.viaStart(s);
      out[o + 5] = c.stallStart(s);
      out[o + 6] = c.bayStart(s);
      out[o + 7] = c.paveCountStart(s);
      out[o + 8] = c.pavePtStart(s);
      out[o + 9] = c.lampStart(s);
      out[o + 10] = c.pathCountStart(s);
      out[o + 11] = c.pathPtStart(s);
      out[o + 12] = c.fenceGapStart(s);
    }
  }

  /// Packs [rows] (published rows, copied verbatim apart from the id and
  /// the graph resolution) into a new chunk, in `PlanBuilder.build`'s layout:
  /// the same rows give the same bytes.
  static SiteAccessChunk _pack(List<_Row> rows) {
    final nS = rows.length;
    final fams = _L.countFamilies.length;
    assert(fams == 13);
    // Each row's family starts and counts in its source chunk.
    final st = Int32List(nS * 2 * fams);
    final cnt = Int32List(nS * fams);
    for (var k = 0; k < nS; k++) {
      _familyStarts(rows[k].chunk, rows[k].site, st, 2 * k * fams, fams);
      for (var fi = 0; fi < fams; fi++) {
        cnt[k * fams + fi] = st[2 * k * fams + fams + fi] - st[2 * k * fams + fi];
      }
    }
    final totals = Int32List(fams);
    for (var k = 0; k < nS; k++) {
      for (var fi = 0; fi < fams; fi++) {
        totals[fi] += cnt[k * fams + fi];
      }
    }
    final offsets = Int32List(SiteCol.count);
    final used = [0, 0, 0, 0];
    for (var col = 0; col < SiteCol.count; col++) {
      final n = switch (_colKind[col]) {
        0 => nS,
        1 => nS + 1,
        2 => totals[_colFamily[col]],
        _ => totals[_colFamily[col]] + nS,
      };
      final t = _L.typeOf(col);
      offsets[col] = used[t];
      used[t] += n;
    }
    final f64 = Float64List(used[_L.tF64]);
    final f32 = Float32List(used[_L.tF32]);
    final i32 = Int32List(used[_L.tI32]);
    final u8 = Uint8List(used[_L.tU8]);
    // Starts.
    for (var fi = 0; fi < fams; fi++) {
      final o = offsets[SiteCol.startBase + fi];
      var acc = 0;
      for (var k = 0; k < nS; k++) {
        i32[o + k] = acc;
        acc += cnt[k * fams + fi];
      }
      i32[o + nS] = acc;
    }
    // Every other column.
    for (var col = 0; col < SiteCol.count; col++) {
      final kind = _colKind[col];
      if (kind == 1) continue;
      final o = offsets[col];
      final t = _L.typeOf(col);
      final fi = _colFamily[col];
      final patched = col == SiteCol.graphStamp ||
          col == SiteCol.graphLot ||
          col == SiteCol.joinRef ||
          col == SiteCol.joinPiece ||
          col == SiteCol.joinRoadNo;
      var w = 0;
      for (var k = 0; k < nS; k++) {
        final r = rows[k];
        final c = r.chunk;
        final int row0, n;
        switch (kind) {
          case 0:
            row0 = r.site;
            n = 1;
          case 2:
            row0 = st[2 * k * fams + fi];
            n = cnt[k * fams + fi];
          default:
            row0 = st[2 * k * fams + fi] + r.site;
            n = cnt[k * fams + fi] + 1;
        }
        switch (t) {
          case _L.tF64:
            for (var i = 0; i < n; i++) {
              f64[o + w + i] = c.f64(col, row0 + i);
            }
          case _L.tF32:
            for (var i = 0; i < n; i++) {
              f32[o + w + i] = c.f32(col, row0 + i);
            }
          case _L.tI32:
            final res = r.resolve;
            if (patched && res != null) {
              for (var i = 0; i < n; i++) {
                i32[o + w + i] = switch (col) {
                  SiteCol.graphStamp => res.stamp,
                  SiteCol.graphLot => res.graphLot,
                  SiteCol.joinRef => res.refs[i],
                  SiteCol.joinPiece => res.pieces[i],
                  _ => res.roadNos[i],
                };
              }
            } else {
              for (var i = 0; i < n; i++) {
                i32[o + w + i] = c.i32(col, row0 + i);
              }
            }
          default:
            for (var i = 0; i < n; i++) {
              u8[o + w + i] = c.u8(col, row0 + i);
            }
        }
        w += n;
      }
    }
    return SiteAccessChunk.packed(
      siteId: [for (final r in rows) r.id],
      f64: f64,
      f32: f32,
      i32: i32,
      u8: u8,
      offsets: offsets,
    );
  }

  /// Tests only: [rows] of published chunks packed as the book packs them.
  static SiteAccessChunk debugRepack(
          List<(SiteAccessChunk chunk, int site)> rows) =>
      _pack([for (final (c, s) in rows) _Row(c, s, c.siteId(s))]);

  // ---- corridors --------------------------------------------------------------------------------

  /// Whether a cut join's throat of [p], where it lies outside [own], comes
  /// within `kAccessCorridorHalfM` of [polygon].
  static bool _corridorHit(
      SiteAccessPlan p, Parcel own, List<Vec2> polygon, Box2 box) {
    for (var j = 0; j < p.joinCount; j++) {
      if (!p.joinIsCut(j)) continue;
      final seg = p.joinThroatSeg(j);
      if (seg < 0 || seg >= p.segCount) continue;
      final n = p.segPointCount(seg);
      for (var i = 1; i < n; i++) {
        final a = p.segPoint(seg, i - 1), b = p.segPoint(seg, i);
        final va = Vec2(p.ptE(a), p.ptN(a)), vb = Vec2(p.ptE(b), p.ptN(b));
        // Only the stretch outside the site's own lot is a corridor.
        if (own.contains(va) && own.contains(vb)) continue;
        final lo = Box2(
          (va.e < vb.e ? va.e : vb.e) - kAccessCorridorHalfM,
          (va.n < vb.n ? va.n : vb.n) - kAccessCorridorHalfM,
          (va.e > vb.e ? va.e : vb.e) + kAccessCorridorHalfM,
          (va.n > vb.n ? va.n : vb.n) + kAccessCorridorHalfM,
        );
        if (!lo.within(box, 0)) continue;
        if (_segmentNearPolygon(va, vb, polygon, kAccessCorridorHalfM)) {
          return true;
        }
      }
    }
    return false;
  }

  static bool _segmentNearPolygon(
      Vec2 a, Vec2 b, List<Vec2> poly, double r) {
    if (_inside(poly, a) || _inside(poly, b)) return true;
    for (var i = 0; i < poly.length; i++) {
      final c = poly[i], d = poly[(i + 1) % poly.length];
      if (_segSegDist(a, b, c, d) <= r) return true;
    }
    return false;
  }

  static bool _inside(List<Vec2> poly, Vec2 p) {
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final a = poly[i], b = poly[j];
      if ((a.n > p.n) != (b.n > p.n) &&
          p.e < (b.e - a.e) * (p.n - a.n) / (b.n - a.n) + a.e) {
        inside = !inside;
      }
    }
    return inside;
  }

  static double _pointSegDist(Vec2 p, Vec2 a, Vec2 b) {
    final ex = b.e - a.e, en = b.n - a.n;
    final len2 = ex * ex + en * en;
    var t = len2 <= 1e-12 ? 0.0 : ((p.e - a.e) * ex + (p.n - a.n) * en) / len2;
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    return p.distanceTo(Vec2(a.e + ex * t, a.n + en * t));
  }

  static double _segSegDist(Vec2 a, Vec2 b, Vec2 c, Vec2 d) {
    double cross(Vec2 o, Vec2 p, Vec2 q) =>
        (p.e - o.e) * (q.n - o.n) - (p.n - o.n) * (q.e - o.e);
    final d1 = cross(c, d, a), d2 = cross(c, d, b);
    final d3 = cross(a, b, c), d4 = cross(a, b, d);
    if (((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))) return 0;
    var m = _pointSegDist(a, c, d);
    final m2 = _pointSegDist(b, c, d);
    if (m2 < m) m = m2;
    final m3 = _pointSegDist(c, a, b);
    if (m3 < m) m = m3;
    final m4 = _pointSegDist(d, a, b);
    return m4 < m ? m4 : m;
  }
}

/// [plan] as JSON (the dev hook `ext.acro.citygame site=plan&id=`): the site
/// row, joins, nodes, segments (with their polylines), stalls, bays, paves,
/// lamps, the door and pavement point, and the footpaths.
Map<String, Object?> sitePlanJson(SiteAccessPlan plan) {
  List<double> pt(int p) => [plan.ptE(p), plan.ptN(p)];
  return {
    'siteId': plan.siteId,
    'rev': plan.rev,
    'program': plan.program.name,
    'flags': plan.flags,
    'graphStamp': plan.graphStamp,
    'graphLot': plan.graphLot,
    'frame': {
      'e': plan.frameE,
      'n': plan.frameN,
      'uE': plan.frameUE,
      'uN': plan.frameUN,
    },
    'envelope': [plan.envX0, plan.envY0, plan.envX1, plan.envY1],
    'gate': {'x': plan.gateX, 'w': plan.gateW},
    'truckTurnRadiusM': plan.truckTurnRadiusM,
    'joins': [
      for (var j = 0; j < plan.joinCount; j++)
        {
          'slot': plan.joinSlot(j),
          'kind': plan.joinKind(j).name,
          'role': plan.joinRole(j).name,
          'ref': plan.joinRef(j),
          'piece': plan.joinPiece(j),
          'roadNo': plan.joinRoadNo(j),
          's': plan.joinRoadS(j),
          'right': plan.joinRight(j),
          'dirs': plan.joinDirs(j),
          'cutHalfM': plan.joinCutHalfM(j),
          'kerbNode': plan.joinKerbNode(j),
          'throatSeg': plan.joinThroatSeg(j),
        },
    ],
    'nodes': [
      for (var n = 0; n < plan.nodeCount; n++)
        {
          'at': pt(plan.nodePt(n)),
          'flags': plan.nodeFlags(n),
          'turn': plan.nodeTurnKind(n).name,
          'turnR': plan.nodeTurnR(n),
        },
    ],
    'segments': [
      for (var k = 0; k < plan.segCount; k++)
        {
          'from': plan.segFrom(k),
          'to': plan.segTo(k),
          'kind': plan.segKind(k).name,
          'mode': plan.segLaneMode(k).name,
          'widthM': plan.segWidthM(k),
          'lenM': plan.segLenM(k),
          'speedMps': plan.segSpeedMps(k),
          'flags': plan.segFlags(k),
          'points': [
            for (var i = 0; i < plan.segPointCount(k); i++)
              pt(plan.segPoint(k, i)),
          ],
        },
    ],
    'stalls': [
      for (var i = 0; i < plan.stallCount; i++)
        {
          'key': plan.stallKey(i),
          'seg': plan.stallSeg(i),
          's': plan.stallS(i),
          'side': plan.stallSide(i),
          'angle': plan.stallAngle(i).name,
          'in': plan.stallInDirs(i),
          'out': plan.stallOutDirs(i),
          'at': [plan.stallE(i), plan.stallN(i)],
          'dir': [plan.stallDirE(i), plan.stallDirN(i)],
        },
    ],
    'bays': [
      for (var i = 0; i < plan.bayCount; i++)
        {
          'seg': plan.baySeg(i),
          's': plan.bayS(i),
          'at': [plan.bayE(i), plan.bayN(i)],
          'kind': plan.bayKind(i).name,
        },
    ],
    'paves': [
      for (var q = 0; q < plan.paveCount; q++)
        {
          'surface': plan.paveSurface(q).name,
          'ring': [
            for (var i = plan.paveStart(q); i < plan.paveStart(q + 1); i++)
              pt(plan.pavePt(i)),
          ],
        },
    ],
    'lamps': [for (var l = 0; l < plan.lampCount; l++) pt(plan.lampPt(l))],
    'entrance': plan.entrancePt < 0 ? null : pt(plan.entrancePt),
    'entranceNode': plan.entranceNode,
    'pavement': plan.pavementPt < 0 ? null : pt(plan.pavementPt),
    'paths': [
      for (var q = 0; q < plan.pathCount; q++)
        [
          for (var i = plan.pathStart(q); i < plan.pathStart(q + 1); i++)
            pt(plan.pathPt(i)),
        ],
    ],
  };
}
