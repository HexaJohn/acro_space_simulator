// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Every building the agents drive to and from, as rows of typed columns
/// (docs/plans/agent-traffic.md §2.6, §3.10).
///
/// A building is a SITE: a lot id — an auto lot's `lot-<road>-<r|l><n>`, a
/// hand-drawn lot's `lot-m<n>` — or `cell-<k>` for a building the colony's
/// grid placed, the name `CitySim` already gives every building whichever
/// model placed it. Trips hold a building's HANDLE (a [SlotPool] handle), so
/// a building that is torn down leaves every trip that named it holding a
/// stale handle: a vehicle already on its way drives on, and finds it gone
/// when it arrives (§4.7).
///
/// The table follows the colony by a sync — every `buildingSyncS` of agent
/// time, and at once whenever the plat, the placed or grown buildings or
/// the road graph change — which reads capacities with exactly the tick's
/// rounding (`(x·uf).round()`, city_sim.dart's aggregation) and resolves
/// each building's access on the lane graph. Between syncs the colony's own
/// rename seams keep handles on their buildings: a road that re-cuts the
/// plat renames the lots along it ([rename]), and a cleared lot is gone at
/// once ([clear]). Without them a renamed lot would read as one building
/// torn down and another put up, and every trip to it would arrive at
/// nothing.
///
/// **Access is per JOIN** (site-access.md §7.3, C1). A site with a current
/// plan is reached and left at that plan's joins, each with its own role
/// (in, out or both); every other building — one with no plan, and one whose
/// plan is not current for the graph the vehicles drive (§0 Q5) — is reached
/// kerbside at the road graph's join slot 0, which is today's access exactly.
/// The rows below hold one row per join PER SERVING DIRECTION, because the
/// lane a car uses, the side it is on and the arc it stops at are all
/// direction's own; [kAccRows] of them per building covers the four slots a
/// lot may offer, both ways.
///
/// The sync may allocate: it runs on edits and once every two seconds,
/// never inside a sub-step's inner loops (§15.2). It walks the plat's own
/// lot views and the grid's buildings, never `layout.parcels` (a copy) nor
/// `parcelBuiltLots()` (a generator over that copy). The access rows
/// themselves are sized by capacity and reused: a sync rewrites them in
/// place and allocates nothing unless the building count grew.
library;

import 'dart:typed_data';

import '../city_building_spec.dart';
import '../city_sim.dart';
import '../parcel.dart';
import '../parcel_network.dart';
import '../site_access/site_access_constants.dart';
import 'access_points.dart';
import 'lane_graph.dart';
import 'route_cost.dart';
import 'site_plan_source.dart';
import 'slot_pool.dart';
import 'traffic_rng.dart';

/// Bits of [BuildingTable.accessFlags]: no trip can both reach the building
/// and leave it again, because it has no in-capable join on a serving edge
/// in the network's largest strongly connected part, or no out-capable one
/// (§3.10 "reachability is per role"). A building with no access at all
/// ([BuildingTable.accCount] 0) carries it too.
const int kAccessIsolated = 1;

/// Access rows per building: four join slots (own road, far end, side
/// street, alley) each served from at most two directions (site-access.md
/// §2.2). Building in slot `sl` owns rows `sl * kAccRows ..
/// sl * kAccRows + accCount[sl] - 1`.
const int kAccRows = 8;

/// Bits of [BuildingTable.accBits], per access row: a car may turn IN here
/// ([kAccIn]) and may pull OUT here ([kAccOut]) — the join's role; the
/// building lies on the LEFT of travel along this row's edge ([kAccLeft]),
/// which is a driveway across the road or a one-way road's left kerb; and
/// the join is a kerb CUT into the site rather than a stop at the kerb
/// ([kAccCut]).
const int kAccIn = 1;
const int kAccOut = 2;
const int kAccLeft = 4;
const int kAccCut = 8;

/// 2^-32: a 32-bit hash scaled onto [0, 1).
const double _unit32 = 1.0 / 4294967296.0;

/// Every building, in typed columns. See the library comment.
class BuildingTable {
  BuildingTable({int capacity = 256}) : pool = SlotPool(capacity) {
    _alloc(capacity);
  }

  /// Slots and their generations: a building's handle is its slot's.
  final SlotPool pool;

  /// Site id → handle. For lookup only; the table is walked in slot order.
  final Map<String, int> _idOf = {};

  // ---- Columns, by slot ------------------------------------------------------

  /// The site id, '' for an empty slot.
  late List<String> siteId;

  /// The spec INSTANCE standing there: specs of different types share
  /// labels, so identity is the only safe compare.
  late List<CityBuildingSpec?> spec;

  /// `ParcelUse` index, and 1 where the plat's own network serves it.
  late Uint8List use, served;

  /// The [kAccessIsolated] bits.
  late Uint8List accessFlags;

  /// Homes and jobs, rounded exactly as the tick rounds them.
  late Int32List housing, jobs;

  /// Citizens living and working here, as COUNTS (§6.2's invariants). The
  /// people themselves hang off `CitizenTable`'s per-building lists, in
  /// arrival order; these are the sums [housingVacancy] and [jobVacancy]
  /// answer from, and `CitizenMatch` — the only thing that moves anyone in
  /// or out — keeps them in step with those lists.
  late Int32List residents, workers;

  /// Bodies waiting for a hearse (§6.2's death, §9.2). A float because the
  /// colony's own deathcare accrues a fraction of a death per tick, and the
  /// hearses of slice 5 take whole ones away.
  late Float32List corpses;

  /// Where it stands, colony-local metres.
  late Float64List centroidE, centroidN;

  /// How many access rows the building owns, and its rows: for row
  /// `r = sl * kAccRows + i` with `i < accCount[sl]`, the directed edge the
  /// join is served by ([accEdge], −1 for an unused row), the travel arc it
  /// is met at on that edge ([accT]), the lane a trip along it arrives in
  /// and leaves from ([accLane], 0 the kerb lane, D6), the [kAccIn] bits,
  /// and the join's handle ([accJoin], site-access.md §2.3 — the same value
  /// on both directions of one join).
  late Uint8List accCount;
  late Int32List accEdge;
  late Float32List accT;
  late Uint8List accLane, accBits;
  late Int32List accJoin;

  /// `CommuteSynth`'s trips owed and not yet sent (slices 1–2): a fraction
  /// of a trip carried from one second to the next. It starts at a phase
  /// hashed from the site id, so a street of identical houses does not
  /// send its first commuters all in the same second — and a phase that
  /// comes from the name, not from a draw, is the same whenever a sync
  /// first sees the building.
  ///
  /// **Retired with slice 3's activity loop** (§6.4): demand becomes the
  /// citizens' own, off the wheel, and a building owes nothing. The column,
  /// its seeding in [_upsert] and its fold in [digest] all go together the
  /// day `CitizenTrips._emit` stops reading it — until then the column is
  /// still what the interim demand runs on, and taking it out now would
  /// leave the tree uncompilable for every other package.
  late Float64List commuteOwed;

  late Int32List _seen;

  int _stamp = 0;
  LaneGraph? _accessGraph;

  /// The plan source access was last resolved against, and its `sitesRev`
  /// then: a plan that appeared, went or changed moves the revision, and
  /// every site re-resolves (§7.3 "re-resolve on … `sitesRev`").
  SitePlanSource? _accessPlans;
  int _accessSitesRev = 0;
  bool _fresh = false;

  /// Syncs run, buildings renamed, and buildings torn down, since the table
  /// was made.
  int syncs = 0, renames = 0, removals = 0;

  // The job draw: job buildings in slot order with their running total.
  Int32List _jobSlot = Int32List(0);
  Int32List _jobCum = Int32List(0);
  int _jobCount = 0, _jobTotal = 0;
  bool _jobsDirty = true;

  int get capacity => pool.capacity;
  int get liveCount => pool.liveCount;

  /// Walk `0 <= slot < highWater` for every building, in slot order.
  int get highWater => pool.highWater;

  bool isLive(int handle) => pool.isLive(handle);
  bool isSlotLive(int slot) => pool.isSlotLive(slot);
  int handleOf(int slot) => pool.handleOf(slot);

  /// The first access row of the building in slot [slot]. Its rows run to
  /// `accRow0(slot) + accCount[slot]`.
  static int accRow0(int slot) => slot * kAccRows;

  /// The handle of the building on [site], or null.
  int? handleOfSite(String site) {
    final h = _idOf[site];
    return h != null && pool.isLive(h) ? h : null;
  }

  /// The site id of live [handle], or null for a building gone.
  String? siteOf(int handle) =>
      pool.isLive(handle) ? siteId[SlotPool.slotOf(handle)] : null;

  void _alloc(int n) {
    siteId = List<String>.filled(n, '');
    spec = List<CityBuildingSpec?>.filled(n, null);
    use = Uint8List(n);
    served = Uint8List(n);
    accessFlags = Uint8List(n);
    housing = Int32List(n);
    jobs = Int32List(n);
    residents = Int32List(n);
    workers = Int32List(n);
    corpses = Float32List(n);
    centroidE = Float64List(n);
    centroidN = Float64List(n);
    accCount = Uint8List(n);
    final rows = n * kAccRows;
    accEdge = Int32List(rows)..fillRange(0, rows, -1);
    accT = Float32List(rows);
    accLane = Uint8List(rows);
    accBits = Uint8List(rows);
    accJoin = Int32List(rows)..fillRange(0, rows, kJoinRefNone);
    commuteOwed = Float64List(n);
    _seen = Int32List(n);
  }

  /// Doubles the table, keeping every building and handle. The access rows
  /// carry over unmoved: their stride is fixed, so slot `sl`'s rows are at
  /// `sl * kAccRows` in the new arrays as they were in the old.
  void _grow() {
    final old = capacity, n = old * 2;
    pool.grow(n);
    final sid = siteId, sp = spec;
    final u = use, sv = served, af = accessFlags, ho = housing, jo = jobs;
    final re = residents, wo = workers, co = corpses;
    final ce = centroidE, cn = centroidN;
    final an = accCount, ae = accEdge, at = accT;
    final al = accLane, ab = accBits, aj = accJoin;
    final ow = commuteOwed, se = _seen;
    _alloc(n);
    siteId.setRange(0, old, sid);
    spec.setRange(0, old, sp);
    use.setRange(0, old, u);
    served.setRange(0, old, sv);
    accessFlags.setRange(0, old, af);
    housing.setRange(0, old, ho);
    jobs.setRange(0, old, jo);
    residents.setRange(0, old, re);
    workers.setRange(0, old, wo);
    corpses.setRange(0, old, co);
    centroidE.setRange(0, old, ce);
    centroidN.setRange(0, old, cn);
    accCount.setRange(0, old, an);
    final rows = old * kAccRows;
    accEdge.setRange(0, rows, ae);
    accT.setRange(0, rows, at);
    accLane.setRange(0, rows, al);
    accBits.setRange(0, rows, ab);
    accJoin.setRange(0, rows, aj);
    commuteOwed.setRange(0, old, ow);
    _seen.setRange(0, old, se);
  }

  // ---- The sync --------------------------------------------------------------

  /// Brings the table up to [city] as it stands, with access on [lg] (null:
  /// no lane graph yet, and no access) read from [plans] (null: no site
  /// plans, so every building is kerbside). Every built site is in
  /// afterwards, its capacities read again; every site no longer built is
  /// torn down.
  ///
  /// Access is resolved for a building new to the table, one whose spec
  /// changed, for all of them when [lg] is a new network — a graph that only
  /// re-planned junctions shares every edge, so its access stands — and for
  /// all of them when the plans moved (§7.3). Hold ONE [SitePlanSource] and
  /// hand it back every sync: a new source object reads as new plans, and
  /// every building resolves again.
  void sync(CitySim city, LaneGraph? lg, [SitePlanSource? plans]) {
    final was = _accessGraph;
    final regraph = !identical(lg, was) &&
        !(lg != null && was != null && lg.sharesStructureWith(was));
    final rev = plans == null ? 0 : plans.sitesRev;
    final replan = !identical(plans, _accessPlans) || rev != _accessSitesRev;
    final again = regraph || replan;
    _stamp++;
    syncs++;
    final net = city.parcelNetwork();
    final layout = city.layout;
    for (final p in layout.manualParcels) {
      _lot(city, net, p, lg, plans, again);
    }
    for (final p in layout.autoParcels) {
      _lot(city, net, p, lg, plans, again);
    }
    for (final cell in city.occupiedCells()) {
      if (city.abandoned.contains(cell.key)) continue;
      _cell(city, cell.key, cell.value, lg, plans, again);
    }
    for (var sl = 0; sl < pool.highWater; sl++) {
      if (pool.isSlotLive(sl) && _seen[sl] != _stamp) _remove(sl);
    }
    _accessGraph = lg;
    _accessPlans = plans;
    _accessSitesRev = rev;
    _jobsDirty = true;
  }

  void _lot(CitySim city, ParcelNetwork net, Parcel p, LaneGraph? lg,
      SitePlanSource? plans, bool again) {
    final id = p.id;
    var s = city.parcelBuildings[id];
    var uf = 1.0;
    if (s == null) {
      s = city.parcelGrownSpec(id, p.use);
      if (s == null) return;
      uf = city.parcelUtil(id);
    }
    final sl = _upsert(id, s, uf, net.lotServed(id));
    use[sl] = p.use.index;
    if (_fresh) {
      final c = p.centroid;
      centroidE[sl] = c.e;
      centroidN[sl] = c.n;
    }
    if (!_fresh && !again) return;
    if (lg == null) {
      _clearAccess(sl);
    } else if (!_planAccess(sl, lg, plans)) {
      // Kerbside at slot 0 (§0 Q5): today's access, and the only access a
      // site without a plan has ever had.
      _joinAccess(sl, lg, AccessPoints.ofLot(lg, id));
    }
  }

  void _cell(CitySim city, int anchor, CityBuildingSpec s, LaneGraph? lg,
      SitePlanSource? plans, bool again) {
    final id = CitySim.siteIdOfCell(anchor);
    final sl = _upsert(id, s, city.utilFactor(anchor), city.isConnected(anchor));
    if (!_fresh && !again) return;
    // The footprint the grid gives it, hung on the nearest road by the
    // hand-drawn lot's rule: the same call the routed model makes for it.
    final fp = city.parcelForCell(anchor, s);
    final c = fp.centroid;
    use[sl] = fp.use.index;
    centroidE[sl] = c.e;
    centroidN[sl] = c.n;
    if (lg == null) {
      _clearAccess(sl);
    } else if (!_planAccess(sl, lg, plans)) {
      _joinAccess(
          sl, lg, AccessPoints.ofFootprint(lg, fp.polygon, centroid: c));
    }
  }

  /// The slot of [id], made if new, with its spec and capacities set. Sets
  /// [_fresh] when its access must be resolved: new, or a different spec.
  int _upsert(String id, CityBuildingSpec s, double uf, bool isServed) {
    var h = _idOf[id];
    int sl;
    if (h == null || !pool.isLive(h)) {
      h = pool.alloc();
      if (h == SlotPool.none) {
        _grow();
        h = pool.alloc();
      }
      _idOf[id] = h;
      sl = SlotPool.slotOf(h);
      siteId[sl] = id;
      commuteOwed[sl] = fnv1a32(id) * _unit32;
      _fresh = true;
    } else {
      sl = SlotPool.slotOf(h);
      _fresh = !identical(spec[sl], s);
    }
    spec[sl] = s;
    housing[sl] = (s.housing * uf).round();
    jobs[sl] = (s.jobs * uf).round();
    served[sl] = isServed ? 1 : 0;
    _seen[sl] = _stamp;
    return sl;
  }

  // ---- Access (§3.10, site-access.md §7.3) --------------------------------------

  /// Rows for the joins of the building's own plan, or false when it has
  /// none to offer: no plan source, no plan, a plan queued for a check or
  /// resolved against another graph (§0 Q5), or one whose joins this graph
  /// no longer holds. Each of those reads kerbside at slot 0 instead.
  bool _planAccess(int sl, LaneGraph lg, SitePlanSource? plans) {
    if (plans == null) return false;
    final id = siteId[sl];
    if (!plans.isCurrentFor(id, lg.graph)) return false;
    final plan = plans.planOf(id);
    if (plan == null) return false;
    _clearAccess(sl);
    final base = accRow0(sl);
    var n = 0;
    for (var j = 0; j < plan.joinCount && n < kAccRows; j++) {
      n = _addJoin(base, n, lg, AccessPoints.ofPlanJoin(lg, plan, j));
    }
    if (n == 0) return false;
    _finishAccess(sl, lg, n);
    return true;
  }

  /// Rows for one join [ap] — the kerbside fallback — as a site with no plan
  /// is reached and left.
  void _joinAccess(int sl, LaneGraph lg, AccessPoint? ap) {
    _clearAccess(sl);
    _finishAccess(sl, lg, _addJoin(accRow0(sl), 0, lg, ap));
  }

  /// Rows for [ap]'s serving directions, appended after row [n] of [base].
  int _addJoin(int base, int n, LaneGraph lg, AccessPoint? ap) {
    if (ap == null) return n;
    final f = ap.fwdEdge, b = ap.bwdEdge;
    var k = n;
    if (f >= 0 && k < kAccRows) k = _addRow(base, k, lg, ap, f);
    if (b >= 0 && k < kAccRows) k = _addRow(base, k, lg, ap, b);
    return k;
  }

  int _addRow(int base, int n, LaneGraph lg, AccessPoint ap, int edge) {
    final r = base + n;
    accEdge[r] = edge;
    accT[r] = ap.sOn(lg, edge);
    accLane[r] = ap.destLane(lg, edge);
    accJoin[r] = ap.joinRef;
    var bits = 0;
    if (ap.canIn) bits |= kAccIn;
    if (ap.canOut) bits |= kAccOut;
    if (!ap.rightOfTravel(lg, edge)) bits |= kAccLeft;
    if (ap.isCut) bits |= kAccCut;
    accBits[r] = bits;
    return n + 1;
  }

  void _clearAccess(int sl) {
    final base = accRow0(sl);
    for (var i = 0; i < kAccRows; i++) {
      final r = base + i;
      accEdge[r] = -1;
      accT[r] = 0;
      accLane[r] = 0;
      accBits[r] = 0;
      accJoin[r] = kJoinRefNone;
    }
    accCount[sl] = 0;
    accessFlags[sl] = 0;
  }

  /// Counts the rows written and judges the site: a trip can reach it and
  /// leave it again only if some IN-capable row and some OUT-capable row
  /// stand on edges in the network's largest strongly connected part
  /// (§3.10). A kerbside plan, whose one join is both, reduces to the old
  /// rule — neither serving edge in the main part.
  void _finishAccess(int sl, LaneGraph lg, int n) {
    accCount[sl] = n;
    final base = accRow0(sl);
    var canIn = false, canOut = false;
    for (var i = 0; i < n; i++) {
      final r = base + i;
      if (lg.edgeInMainScc[accEdge[r]] != 1) continue;
      if (accBits[r] & kAccIn != 0) canIn = true;
      if (accBits[r] & kAccOut != 0) canOut = true;
    }
    accessFlags[sl] = canIn && canOut ? 0 : kAccessIsolated;
  }

  /// Tears down the building in [sl]: its handle goes stale.
  void _remove(int sl) {
    final h = pool.handleOf(sl);
    final id = siteId[sl];
    if (_idOf[id] == h) _idOf.remove(id);
    pool.free(h);
    siteId[sl] = '';
    spec[sl] = null;
    housing[sl] = 0;
    jobs[sl] = 0;
    // The counts go with the building; the PEOPLE are turned out by
    // `CitizenMatch`, which watches for a slot whose handle moved on and
    // makes its residents homeless and its workers unemployed (§2.6's
    // removal). A new building taking this slot must not inherit either
    // them or the bodies waiting on the old one.
    residents[sl] = 0;
    workers[sl] = 0;
    corpses[sl] = 0;
    served[sl] = 0;
    _clearAccess(sl);
    commuteOwed[sl] = 0;
    removals++;
    _jobsDirty = true;
  }

  // ---- The colony's seams (E12–E14) --------------------------------------------

  /// Carries buildings onto the lots a re-plat renamed them to: [renamed]
  /// is old lot id → new, as the colony reports it. Handles stay, so every
  /// trip to or from a renamed lot keeps its building.
  ///
  /// Looked up building by building, in slot order, rather than by walking
  /// the map; and in two passes, so a renaming that hands one building's old
  /// id to another never loses either.
  void rename(Map<String, String> renamed) {
    if (renamed.isEmpty) return;
    final slots = <int>[];
    final to = <String>[];
    for (var sl = 0; sl < pool.highWater; sl++) {
      if (!pool.isSlotLive(sl)) continue;
      final next = renamed[siteId[sl]];
      if (next == null || next == siteId[sl]) continue;
      slots.add(sl);
      to.add(next);
    }
    for (var i = 0; i < slots.length; i++) {
      final sl = slots[i];
      if (_idOf[siteId[sl]] == pool.handleOf(sl)) _idOf.remove(siteId[sl]);
    }
    for (var i = 0; i < slots.length; i++) {
      final sl = slots[i];
      final prior = _idOf[to[i]];
      if (prior != null && pool.isLive(prior)) _remove(SlotPool.slotOf(prior));
      siteId[sl] = to[i];
      _idOf[to[i]] = pool.handleOf(sl);
    }
    renames += slots.length;
  }

  /// Tears down the building on [site] at once — the colony cleared the
  /// lot — rather than at the next sync. False when there was none.
  bool clear(String site) {
    final h = _idOf[site];
    if (h == null || !pool.isLive(h)) return false;
    _remove(SlotPool.slotOf(h));
    return true;
  }

  // ---- What trips ask -----------------------------------------------------------

  /// Whether the building in [sl] can be driven to and away from: served,
  /// with access, and not cut off from the rest of the network — which is
  /// per role ([_finishAccess]).
  bool reachable(int sl) =>
      served[sl] != 0 &&
      accCount[sl] != 0 &&
      accessFlags[sl] & kAccessIsolated == 0;

  /// Whether live building [handle] has a serving edge at all.
  bool hasAccess(int handle) =>
      pool.isLive(handle) && accCount[SlotPool.slotOf(handle)] != 0;

  /// Whether live building [handle] is met on [edge] within [tolM] of travel
  /// arc [t]: whether a trip that stopped there stopped at its access as
  /// the table resolves it now, on the graph of the last sync.
  bool meetsAt(int handle, int edge, double t, double tolM) =>
      _rowAt(handle, edge, t, tolM) >= 0;

  /// The join (its handle, site-access.md §2.3) building [handle] is met by
  /// on [edge] within [tolM] of travel arc [t], or [kJoinRefNone]: which
  /// driveway a car that stopped there stopped at. Cuts on one edge are
  /// ≥ 6 m apart (V4), so `(edge, T)` names one join.
  int joinAt(int handle, int edge, double t, double tolM) {
    final r = _rowAt(handle, edge, t, tolM);
    return r < 0 ? kJoinRefNone : accJoin[r];
  }

  /// Whether building [handle] lies on the left of travel along [edge] at
  /// travel arc [t] — the join a car stopped at, not merely the first on
  /// that edge. A left join is a turn across the road, or a one-way road's
  /// left kerb (D6).
  bool leftOfAt(int handle, int edge, double t) {
    final r = _rowAt(handle, edge, t, double.infinity);
    return r >= 0 && accBits[r] & kAccLeft != 0;
  }

  /// Whether building [handle] lies on the left of travel along [edge], at
  /// whichever of its joins that edge serves: for a departure, which has an
  /// edge but no arc of its own yet.
  bool leftOf(int handle, int edge) => leftOfAt(handle, edge, double.nan);

  /// The access row of [handle] on [edge] nearest travel arc [t], within
  /// [tolM], or −1. A NaN [t] takes the first row on the edge, so a caller
  /// with no arc still gets the join.
  int _rowAt(int handle, int edge, double t, double tolM) {
    if (!pool.isLive(handle) || edge < 0) return -1;
    final sl = SlotPool.slotOf(handle);
    final base = accRow0(sl);
    final n = accCount[sl];
    var best = -1;
    var bestM = double.infinity;
    for (var i = 0; i < n; i++) {
      final r = base + i;
      if (accEdge[r] != edge) continue;
      final d = (accT[r] - t).abs();
      if (d.isNaN) return r;
      if (d > tolM || d >= bestM) continue;
      best = r;
      bestM = d;
    }
    return best;
  }

  /// Adds building [handle]'s out-capable access to [ends] as origins, from
  /// any lane: a trip pulling out of an access point chooses its lane there
  /// (§5.5). With [nearEdge] set, only rows on that edge are offered — a car
  /// backing out onto a road it may not cross leaves in the near direction
  /// only. False for a building gone, without access, or with none that
  /// answers.
  bool addOrigins(int handle, PathEnds ends, {int nearEdge = -1}) {
    if (!pool.isLive(handle)) return false;
    final sl = SlotPool.slotOf(handle);
    final base = accRow0(sl);
    final n = accCount[sl];
    var any = false;
    for (var i = 0; i < n; i++) {
      final r = base + i;
      if (accBits[r] & kAccOut == 0) continue;
      if (nearEdge >= 0 && accEdge[r] != nearEdge) continue;
      ends.addOrigin(accEdge[r], accT[r]);
      any = true;
    }
    return any;
  }

  /// Adds building [handle]'s in-capable access to [ends] as goals, each
  /// reached in the one lane a car pulls in from on that side (D6).
  bool addGoals(int handle, PathEnds ends) {
    if (!pool.isLive(handle)) return false;
    final sl = SlotPool.slotOf(handle);
    final base = accRow0(sl);
    final n = accCount[sl];
    var any = false;
    for (var i = 0; i < n; i++) {
      final r = base + i;
      if (accBits[r] & kAccIn == 0) continue;
      ends.addGoal(accEdge[r], accT[r], laneMask: 1 << accLane[r]);
      any = true;
    }
    return any;
  }

  /// Homes standing empty at [sl] — never negative. A building whose
  /// utilisation has just fallen reads over-full until the sync's eviction
  /// catches up (§6.2), and an over-full building offers nothing.
  int housingVacancy(int sl) {
    final free = housing[sl] - residents[sl];
    return free > 0 ? free : 0;
  }

  /// Jobs going at [sl], by the same rule (§6.3's job loss).
  int jobVacancy(int sl) {
    final free = jobs[sl] - workers[sl];
    return free > 0 ? free : 0;
  }

  /// A building with a home to spare, drawn by [rng] weighted by its
  /// vacancy in stable slot order; −1 when the colony is full (§6.2's
  /// arrival).
  ///
  /// Answers a SLOT where [drawJob] answers a handle: a home is what
  /// `CitizenTable.home` records, and that column holds slots.
  ///
  /// The gate is [served], not [reachable]: a citizen without a car walks
  /// home, so a house the lane graph cannot drive to is still a house,
  /// while one the colony's own network does not serve is not a working
  /// building at all.
  ///
  /// Two passes and exactly one draw, with no cumulative index: a vacancy
  /// changes with every citizen housed, so an index like [drawJob]'s would
  /// have to be rebuilt between one draw and the next anyway.
  int drawVacantHome(TrafficRng rng) {
    var total = 0;
    for (var sl = 0; sl < pool.highWater; sl++) {
      if (!pool.isSlotLive(sl) || served[sl] == 0) continue;
      total += housingVacancy(sl);
    }
    if (total <= 0) return -1;
    var r = rng.nextInt(total);
    for (var sl = 0; sl < pool.highWater; sl++) {
      if (!pool.isSlotLive(sl) || served[sl] == 0) continue;
      r -= housingVacancy(sl);
      if (r < 0) return sl;
    }
    return -1;
  }

  /// A job building drawn by [rng], weighted by its jobs, among those a
  /// trip can reach — never the one in slot [except] while there is another.
  /// Returns its handle, or −1 when the colony has no reachable jobs.
  int drawJob(TrafficRng rng, {int except = -1}) {
    if (_jobsDirty) _indexJobs();
    if (_jobTotal <= 0) return -1;
    final r = rng.nextInt(_jobTotal);
    var lo = 0, hi = _jobCount - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_jobCum[mid] > r) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    var sl = _jobSlot[lo];
    if (sl == except) {
      if (_jobCount == 1) return -1;
      sl = _jobSlot[(lo + 1) % _jobCount];
    }
    return pool.handleOf(sl);
  }

  void _indexJobs() {
    if (_jobSlot.length < pool.highWater) {
      _jobSlot = Int32List(pool.capacity);
      _jobCum = Int32List(pool.capacity);
    }
    var n = 0, total = 0;
    for (var sl = 0; sl < pool.highWater; sl++) {
      if (!pool.isSlotLive(sl) || jobs[sl] <= 0 || !reachable(sl)) continue;
      total += jobs[sl];
      _jobSlot[n] = sl;
      _jobCum[n] = total;
      n++;
    }
    _jobCount = n;
    _jobTotal = total;
    _jobsDirty = false;
  }

  /// [hash] with every live building's handle, capacities, access rows and
  /// owed trips folded in, in slot order: for `CityAgents.digest`.
  ///
  /// [residents], [workers] and [corpses] are deliberately NOT here. They
  /// ride `CitizenMatch.digest`, which `CityAgents` folds in only once the
  /// citizens are wired, so that every digest a colony without citizens
  /// takes — the determinism test's among them — is the value it was
  /// before slice 3.
  int digest(int hash) {
    var h = fnv1aU32(hash, pool.highWater);
    for (var sl = 0; sl < pool.highWater; sl++) {
      if (!pool.isSlotLive(sl)) continue;
      h = fnv1aU32(h, pool.handleOf(sl));
      h = fnv1aU32(h, housing[sl]);
      h = fnv1aU32(h, jobs[sl]);
      final base = accRow0(sl);
      final n = accCount[sl];
      h = fnv1aU32(h, n);
      for (var i = 0; i < n; i++) {
        final r = base + i;
        h = fnv1aU32(h, accEdge[r]);
        h = fnv1aU32(h, accJoin[r]);
        h = fnv1aByte(h, accBits[r] | (accLane[r] << 4));
      }
      h = fnv1aU32(h, (commuteOwed[sl] * 1e6).round());
    }
    return h;
  }
}
