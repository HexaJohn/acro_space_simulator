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
/// The sync may allocate: it runs on edits and once every two seconds,
/// never inside a sub-step's inner loops (§15.2). It walks the plat's own
/// lot views and the grid's buildings, never `layout.parcels` (a copy) nor
/// `parcelBuiltLots()` (a generator over that copy).
library;

import 'dart:typed_data';

import '../city_building_spec.dart';
import '../city_sim.dart';
import '../parcel.dart';
import '../parcel_network.dart';
import 'access_points.dart';
import 'lane_graph.dart';
import 'route_cost.dart';
import 'slot_pool.dart';
import 'traffic_rng.dart';

/// Bits of [BuildingTable.accessFlags]: the building's serving edges are
/// all outside the network's largest strongly connected part, so a trip
/// could reach it and not leave, or leave and not come back
/// ([kAccessIsolated]); it lies on the LEFT of travel along its forward or
/// backward serving edge ([kAccessFwdLeft], [kAccessBwdLeft]) — a driveway
/// across the road, or a one-way road's left kerb.
const int kAccessIsolated = 1;
const int kAccessFwdLeft = 2;
const int kAccessBwdLeft = 4;

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

  /// The [kAccessIsolated]… bits.
  late Uint8List accessFlags;

  /// Homes and jobs, rounded exactly as the tick rounds them.
  late Int32List housing, jobs;

  /// Where it stands, colony-local metres.
  late Float64List centroidE, centroidN;

  /// The directed edges that serve it — along its road's polyline and
  /// against it — or −1; the travel arc it is met at on each; the lane a
  /// trip along each arrives in and leaves from (0 the kerb lane).
  late Int32List accFwd, accBwd;
  late Float32List accFwdT, accBwdT;
  late Uint8List accFwdLane, accBwdLane;

  /// `CommuteSynth`'s trips owed and not yet sent (slices 1–2): a fraction
  /// of a trip carried from one second to the next. It starts at a phase
  /// hashed from the site id, so a street of identical houses does not
  /// send its first commuters all in the same second — and a phase that
  /// comes from the name, not from a draw, is the same whenever a sync
  /// first sees the building.
  late Float64List commuteOwed;

  late Int32List _seen;

  int _stamp = 0;
  LaneGraph? _accessGraph;
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
    centroidE = Float64List(n);
    centroidN = Float64List(n);
    accFwd = Int32List(n)..fillRange(0, n, -1);
    accBwd = Int32List(n)..fillRange(0, n, -1);
    accFwdT = Float32List(n);
    accBwdT = Float32List(n);
    accFwdLane = Uint8List(n);
    accBwdLane = Uint8List(n);
    commuteOwed = Float64List(n);
    _seen = Int32List(n);
  }

  /// Doubles the table, keeping every building and handle.
  void _grow() {
    final old = capacity, n = old * 2;
    pool.grow(n);
    final sid = siteId, sp = spec;
    final u = use, sv = served, af = accessFlags, ho = housing, jo = jobs;
    final ce = centroidE, cn = centroidN, fa = accFwd, ba = accBwd;
    final ft = accFwdT, bt = accBwdT, fl = accFwdLane, bl = accBwdLane;
    final ow = commuteOwed, se = _seen;
    _alloc(n);
    siteId.setRange(0, old, sid);
    spec.setRange(0, old, sp);
    use.setRange(0, old, u);
    served.setRange(0, old, sv);
    accessFlags.setRange(0, old, af);
    housing.setRange(0, old, ho);
    jobs.setRange(0, old, jo);
    centroidE.setRange(0, old, ce);
    centroidN.setRange(0, old, cn);
    accFwd.setRange(0, old, fa);
    accBwd.setRange(0, old, ba);
    accFwdT.setRange(0, old, ft);
    accBwdT.setRange(0, old, bt);
    accFwdLane.setRange(0, old, fl);
    accBwdLane.setRange(0, old, bl);
    commuteOwed.setRange(0, old, ow);
    _seen.setRange(0, old, se);
  }

  // ---- The sync --------------------------------------------------------------

  /// Brings the table up to [city] as it stands, with access on [lg] (null:
  /// no lane graph yet, and no access). Every built site is in afterwards,
  /// its capacities read again; every site no longer built is torn down.
  ///
  /// Access is resolved for a building new to the table, one whose spec
  /// changed, and for all of them when [lg] is a new network — a graph that
  /// only re-planned junctions shares every edge, so its access stands.
  void sync(CitySim city, LaneGraph? lg) {
    final was = _accessGraph;
    final regraph = !identical(lg, was) &&
        !(lg != null && was != null && lg.sharesStructureWith(was));
    _stamp++;
    syncs++;
    final net = city.parcelNetwork();
    final layout = city.layout;
    for (final p in layout.manualParcels) {
      _lot(city, net, p, lg, regraph);
    }
    for (final p in layout.autoParcels) {
      _lot(city, net, p, lg, regraph);
    }
    for (final cell in city.occupiedCells()) {
      if (city.abandoned.contains(cell.key)) continue;
      _cell(city, cell.key, cell.value, lg, regraph);
    }
    for (var sl = 0; sl < pool.highWater; sl++) {
      if (pool.isSlotLive(sl) && _seen[sl] != _stamp) _remove(sl);
    }
    _accessGraph = lg;
    _jobsDirty = true;
  }

  void _lot(CitySim city, ParcelNetwork net, Parcel p, LaneGraph? lg,
      bool regraph) {
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
    if (_fresh || regraph) {
      _setAccess(sl, lg == null ? null : AccessPoints.ofLot(lg, id), lg);
    }
  }

  void _cell(CitySim city, int anchor, CityBuildingSpec s, LaneGraph? lg,
      bool regraph) {
    final id = CitySim.siteIdOfCell(anchor);
    final sl = _upsert(id, s, city.utilFactor(anchor), city.isConnected(anchor));
    if (!_fresh && !regraph) return;
    // The footprint the grid gives it, hung on the nearest road by the
    // hand-drawn lot's rule: the same call the routed model makes for it.
    final fp = city.parcelForCell(anchor, s);
    final c = fp.centroid;
    use[sl] = fp.use.index;
    centroidE[sl] = c.e;
    centroidN[sl] = c.n;
    _setAccess(sl,
        lg == null ? null : AccessPoints.ofFootprint(lg, fp.polygon, centroid: c),
        lg);
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

  void _setAccess(int sl, AccessPoint? ap, LaneGraph? lg) {
    accFwd[sl] = -1;
    accBwd[sl] = -1;
    accessFlags[sl] = 0;
    if (ap == null || lg == null) return;
    var bits = ap.isolated(lg) ? kAccessIsolated : 0;
    final f = ap.fwdEdge, b = ap.bwdEdge;
    if (f >= 0) {
      accFwd[sl] = f;
      accFwdT[sl] = ap.sOn(lg, f);
      accFwdLane[sl] = ap.destLane(lg, f);
      if (!ap.rightOfTravel(lg, f)) bits |= kAccessFwdLeft;
    }
    if (b >= 0) {
      accBwd[sl] = b;
      accBwdT[sl] = ap.sOn(lg, b);
      accBwdLane[sl] = ap.destLane(lg, b);
      if (!ap.rightOfTravel(lg, b)) bits |= kAccessBwdLeft;
    }
    accessFlags[sl] = bits;
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
    served[sl] = 0;
    accFwd[sl] = -1;
    accBwd[sl] = -1;
    accessFlags[sl] = 0;
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
  /// with a serving edge, and not cut off from the rest of the network.
  bool reachable(int sl) =>
      served[sl] != 0 &&
      (accFwd[sl] >= 0 || accBwd[sl] >= 0) &&
      accessFlags[sl] & kAccessIsolated == 0;

  /// Whether building [handle] lies on the left of travel along [edge].
  bool leftOf(int handle, int edge) {
    if (!pool.isLive(handle)) return false;
    final sl = SlotPool.slotOf(handle);
    if (edge == accFwd[sl]) return accessFlags[sl] & kAccessFwdLeft != 0;
    if (edge == accBwd[sl]) return accessFlags[sl] & kAccessBwdLeft != 0;
    return false;
  }

  /// Adds building [handle]'s serving edges to [ends] as origins, from any
  /// lane: a trip pulling out of an access point chooses its lane there
  /// (§5.5). False for a building gone or without access.
  bool addOrigins(int handle, PathEnds ends) {
    if (!pool.isLive(handle)) return false;
    final sl = SlotPool.slotOf(handle);
    var any = false;
    if (accFwd[sl] >= 0) {
      ends.addOrigin(accFwd[sl], accFwdT[sl]);
      any = true;
    }
    if (accBwd[sl] >= 0) {
      ends.addOrigin(accBwd[sl], accBwdT[sl]);
      any = true;
    }
    return any;
  }

  /// Adds building [handle]'s serving edges to [ends] as goals, each
  /// reached in the one lane a car pulls in from on that side (D6).
  bool addGoals(int handle, PathEnds ends) {
    if (!pool.isLive(handle)) return false;
    final sl = SlotPool.slotOf(handle);
    var any = false;
    if (accFwd[sl] >= 0) {
      ends.addGoal(accFwd[sl], accFwdT[sl], laneMask: 1 << accFwdLane[sl]);
      any = true;
    }
    if (accBwd[sl] >= 0) {
      ends.addGoal(accBwd[sl], accBwdT[sl], laneMask: 1 << accBwdLane[sl]);
      any = true;
    }
    return any;
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

  /// [hash] with every live building's handle, capacities and owed trips
  /// folded in, in slot order: for `CityAgents.digest`.
  int digest(int hash) {
    var h = fnv1aU32(hash, pool.highWater);
    for (var sl = 0; sl < pool.highWater; sl++) {
      if (!pool.isSlotLive(sl)) continue;
      h = fnv1aU32(h, pool.handleOf(sl));
      h = fnv1aU32(h, housing[sl]);
      h = fnv1aU32(h, jobs[sl]);
      h = fnv1aU32(h, accFwd[sl]);
      h = fnv1aU32(h, accBwd[sl]);
      h = fnv1aU32(h, (commuteOwed[sl] * 1e6).round());
    }
    return h;
  }
}
