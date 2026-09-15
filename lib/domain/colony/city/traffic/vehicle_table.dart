// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The vehicles on the road: a row of typed columns per vehicle, and the
/// order they stand in on every lane and connector
/// (docs/plans/agent-traffic.md §2.3).
///
/// A vehicle is a SLOT, never an object (§2.1): thousands of Dart objects
/// would be thousands of live objects for the collector to mark on every
/// old-generation pause. Everything that remembers a vehicle holds its
/// handle ([SlotPool]), which goes stale when the vehicle despawns.
///
/// Where a vehicle is: an ELEMENT — a lane id below `LaneGraph.laneCount`,
/// or `laneCount + c` on connector c — and `s`, the metres its FRONT has
/// come along that element. Its body runs `len` metres back from there, so
/// a car that has just crossed into a lane still has its tail on the
/// connector behind it; the mover and the arbiter both allow for that. A
/// vehicle inside a site is on no element: its element is −1 and it is on
/// no list (D49, docs/plans/t4a-implementation.md §1.2), so everything that
/// walks the lists never meets it, and everything that reads an element by
/// slot checks for −1 first.
///
/// Its route is the locked connector list the planner returned,
/// `[firstLane, c₁, …, c_n]`, copied into the [RouteArena]. [routeCur] is
/// the index of the route EDGE the vehicle is on — edge 0 is `firstLane`'s,
/// edge i the one connector i leads onto — or, while it is on connector i,
/// the edge that connector is taking it to. That is the remapper's `at`
/// (graph_lineage.dart), so a remap reads a vehicle's place straight from
/// its columns.
///
/// Every element keeps its vehicles as an intrusive list, head (the one
/// furthest along) to tail, through [prev] (the leader) and [next] (the
/// follower). The mover walks those lists in element order every sub-step;
/// the arbiter reads their tails to see whether a connector is clear; the
/// lane planner reads their counts to spread through traffic across lanes.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'agent_kind.dart';
import 'lane_graph.dart';
import 'lane_planner.dart';
import 'route_arena.dart';
import 'slot_pool.dart';
import 'traffic_rng.dart';

/// What a vehicle is doing (§2.3). Append-only: the column holds the index.
enum VehicleState {
  /// On its route, under the car-following and the junction rules.
  driving,

  /// Its route was made impossible by a network edit and a re-plan is
  /// queued: it drives on, and stops at the end of the edge it is on
  /// (§3.9). Its stuck timer is frozen meanwhile.
  holdAtEdgeEnd,

  /// Standing on purpose: a service stop, a bus at a stop, a fire engine on
  /// scene. It does not move and its stuck timer is frozen; whoever set it
  /// sets it driving again.
  dwelling,

  /// Looking for a place to park (slice 4).
  parkingSearch,

  /// Despawned at the end of this sub-step.
  leaving,

  /// Inside a site (docs/plans/t4a-implementation.md §1.2, D49): off the
  /// road, its [VehicleTable.elem] −1 and on no element's list. Where it is
  /// lives in the site columns (`SiteVehicles.row`/`lane`) and its
  /// [VehicleTable.s]; the site mover moves it, and the road mover never
  /// sees it.
  onSite,

  /// On the road but not driving it: a car whose pose the site mover owns
  /// for a scripted manoeuvre (a home back-out's reverse and tail swing,
  /// site-access.md §7.4). The road mover treats it as it treats a dwell —
  /// a stationary obstacle in its lane, its stuck timer frozen.
  manoeuvre,
}

/// Bits of [VehicleTable.flags].
///
/// [kHalted]: it has come to rest at the stop line it is waiting at, as a
/// stop sign demands. [kInFifo]: it holds a place in an all-way stop's
/// arrival queue. [kHandedOver]: it moved onto a new element this sub-step.
/// [kRefused]: the junction ahead refused it this sub-step. [kReversing]: a
/// home back-out in its target lane, logged EXIT as its rear crossed the
/// kerb line (site-access.md §7.4): followers see its footprint as a
/// stopped obstacle.
const int kHalted = 1;
const int kInFifo = 2;
const int kHandedOver = 4;
const int kRefused = 8;
const int kReversing = 16;

/// How each kind of vehicle drives and how long it is (§5.3).
///
/// The IDM parameters are the design's table: a car pulls away at 1.4 m/s²
/// and brakes comfortably at 2.0, keeps 1.2 s of headway and 2 m at a
/// standstill; lorries, vans and service vehicles are slower to move and
/// keep further back, a semi more so, a bus in between. Lengths are the
/// renderer's longest mesh of each kind (vehicle_meshes.dart), so two cars
/// the simulation keeps apart never overlap on screen.
class VehicleKinds {
  VehicleKinds._();

  static final int _n = AgentKind.values.length;

  /// Metres, bumper to bumper.
  static final Float64List lengthM = _table((k) => switch (k) {
        AgentKind.car || AgentKind.policeCar => 4.9,
        AgentKind.truck => 7.0,
        AgentKind.semi => 15.5,
        AgentKind.bus => 12.0,
        AgentKind.garbageTruck => 9.0,
        AgentKind.hearse || AgentKind.mailVan => 5.5,
        AgentKind.ambulance || AgentKind.deliveryVan => 6.0,
        AgentKind.fireEngine => 10.0,
        AgentKind.train => 60.0,
        AgentKind.lTrain => 40.0,
        AgentKind.freightTrain => 120.0,
      });

  /// IDM `a`: the most it accelerates, m/s².
  static final Float64List accel = _table((k) => switch (_class(k)) {
        _Class.car => 1.4,
        _Class.heavy => 0.9,
        _Class.semi => 0.7,
        _Class.bus => 1.0,
      });

  /// IDM `b`: the deceleration it brakes at by choice, m/s². Harder is
  /// possible — the model brakes as hard as a collision demands — but
  /// every choice the junction rules offer is judged against this.
  static final Float64List brake = _table((k) => switch (_class(k)) {
        _Class.car => 2.0,
        _Class.heavy || _Class.bus => 1.8,
        _Class.semi => 1.6,
      });

  /// IDM `T`: the time headway it keeps, s.
  static final Float64List headwayS = _table((k) => switch (_class(k)) {
        _Class.car => 1.2,
        _Class.heavy => 1.5,
        _Class.semi => 1.8,
        _Class.bus => 1.4,
      });

  /// IDM `s₀`: the gap it keeps at a standstill, m.
  static final Float64List jamM = _table((k) => switch (_class(k)) {
        _Class.car => 2.0,
        _Class.heavy || _Class.bus => 2.5,
        _Class.semi => 3.0,
      });

  /// √(a·b), worked out once (§5.3).
  static final Float64List sqrtAb = Float64List.fromList([
    for (var k = 0; k < _n; k++) math.sqrt(accel[k] * brake[k]),
  ]);

  /// The desired-speed factor of every kind but the car, which draws its
  /// own per trip ([drawFactor]).
  static final Float64List speedFactor = _table((k) => switch (_class(k)) {
        _Class.car => 1.0,
        _Class.heavy || _Class.bus => 0.95,
        _Class.semi => 0.90,
      });

  /// The desired-speed factor of one trip by [kind] (§5.3): a car's is
  /// U(0.92, 1.05), drawn once per trip, so a street holds some quicker
  /// drivers and some slower; every other kind drives at its fixed factor.
  static double drawFactor(AgentKind kind, TrafficRng rng) =>
      kind == AgentKind.car
          ? rng.nextBetween(0.92, 1.05)
          : speedFactor[kind.index];

  static _Class _class(AgentKind k) => switch (k) {
        AgentKind.car => _Class.car,
        AgentKind.semi || AgentKind.freightTrain => _Class.semi,
        AgentKind.bus || AgentKind.train || AgentKind.lTrain => _Class.bus,
        AgentKind.truck ||
        AgentKind.garbageTruck ||
        AgentKind.hearse ||
        AgentKind.policeCar ||
        AgentKind.ambulance ||
        AgentKind.fireEngine ||
        AgentKind.mailVan ||
        AgentKind.deliveryVan =>
          _Class.heavy,
      };

  static Float64List _table(double Function(AgentKind) f) =>
      Float64List.fromList([for (final k in AgentKind.values) f(k)]);
}

/// The four rows of the design's IDM table.
enum _Class { car, heavy, semi, bus }

/// Every vehicle, in typed columns (§2.3). See the library comment.
///
/// It never grows by itself: [spawn] answers [SlotPool.none] when the table
/// is full, and the owner decides whether this is a moment it may [grow]
/// (warm-up, a rebuild) or a trip that waits (D10).
class VehicleTable implements LaneLoad {
  VehicleTable({int capacity = 4096, RouteArena? arena})
      : pool = SlotPool(capacity),
        arena = arena ?? RouteArena() {
    _allocColumns(capacity);
  }

  /// Slots and their generations.
  final SlotPool pool;

  /// Where the routes live.
  final RouteArena arena;

  LaneGraph? _lg;

  /// The lane graph the elements, lanes and connectors are ids of.
  LaneGraph get graph {
    final lg = _lg;
    if (lg == null) throw StateError('the vehicle table has no lane graph');
    return lg;
  }

  // ---- Columns ---------------------------------------------------------------

  /// [AgentKind], the renderer's opaque variant byte (D42), [VehicleState],
  /// [TripPurpose], and the [kHalted]… flag bits — all as indices.
  late Uint8List kind, variant, state, purpose, flags;

  /// The [GrantReason] index of the last clearance the arbiter gave it.
  late Uint8List grant;

  /// Its element (−1 inside a site), and the route edge it is on or heading
  /// onto.
  late Int32List elem, routeCur;

  /// Its route block in [arena]: offset and length.
  late Int32List routeOff, routeLen;

  /// Leader and follower on its element: slots, or −1.
  late Int32List prev, next;

  /// The connector the arbiter has cleared it into and it is committed to,
  /// or −1 (junction_arbiter.dart).
  late Int32List pass;

  /// Whoever the trip belongs to: a citizen, a building, a request.
  late Int32List owner;

  /// Microseconds stationary while it should be moving (§5.6), and at the
  /// stop line it is waiting at. Integer microseconds, so 120 s is exactly
  /// 600 sub-steps and a despawn lands on the sub-step it should.
  late Int32List stuckUs, waitUs;

  /// Front position along its element (m), speed (m/s), last acceleration
  /// (m/s²), the desired speed of its element (m/s, cached on entry), its
  /// trip's desired-speed factor, its length (m).
  late Float32List s, v, a, v0, f, len;

  /// Where it stops: travel metres along the route's last edge.
  late Float32List destS;

  /// Metres moved since its stuck timer was last reset (§5.6).
  late Float32List movedM;

  /// The free-flow seconds of its route, for trip statistics.
  late Float32List freeFlowS;

  /// [s] and [v] as they stood when the sub-step began: what a follower on
  /// another element reads, so the order vehicles are stepped in never
  /// changes what they see (§5.2).
  late Float32List sPre, vPre;

  /// Metres driven this trip: the arbiter measures from it how far a car
  /// that has left a connector still has its tail on it.
  late Float64List odo;

  /// Agent time it entered its current edge, and began its trip (µs, whole
  /// numbers held in doubles).
  late Float64List edgeEnterUs, tripT0Us;

  // ---- Occupancy, per element -------------------------------------------------

  /// Per element: the vehicle furthest along, the last, and how many.
  Int32List elemHead = Int32List(0);
  Int32List elemTail = Int32List(0);
  Int32List elemCount = Int32List(0);

  int get capacity => pool.capacity;
  int get liveCount => pool.liveCount;

  /// Iteration in slot order runs `0 <= slot < highWater`.
  int get highWater => pool.highWater;

  bool isLive(int handle) => pool.isLive(handle);
  bool isSlotLive(int slot) => pool.isSlotLive(slot);
  int handleOf(int slot) => pool.handleOf(slot);
  static int slotOf(int handle) => SlotPool.slotOf(handle);

  /// Vehicles on [lane] now: the lane planner's tie-break (§4.5).
  @override
  int vehiclesOn(int lane) =>
      lane >= 0 && lane < elemCount.length ? elemCount[lane] : 0;

  void _allocColumns(int n) {
    kind = Uint8List(n);
    variant = Uint8List(n);
    state = Uint8List(n);
    purpose = Uint8List(n);
    flags = Uint8List(n);
    grant = Uint8List(n);
    elem = Int32List(n);
    routeCur = Int32List(n);
    routeOff = Int32List(n);
    routeLen = Int32List(n);
    prev = Int32List(n);
    next = Int32List(n);
    pass = Int32List(n);
    owner = Int32List(n);
    stuckUs = Int32List(n);
    waitUs = Int32List(n);
    s = Float32List(n);
    v = Float32List(n);
    a = Float32List(n);
    v0 = Float32List(n);
    f = Float32List(n);
    len = Float32List(n);
    destS = Float32List(n);
    movedM = Float32List(n);
    freeFlowS = Float32List(n);
    sPre = Float32List(n);
    vPre = Float32List(n);
    odo = Float64List(n);
    edgeEnterUs = Float64List(n);
    tripT0Us = Float64List(n);
  }

  /// Grows the table to [newCapacity] slots. Every column is copied; live
  /// handles stay live. Only during warm-up or a rebuild (§2.1).
  void grow(int newCapacity) {
    final old = capacity;
    pool.grow(newCapacity);
    Uint8List u8(Uint8List a) => Uint8List(newCapacity)..setRange(0, old, a);
    Int32List i32(Int32List a) => Int32List(newCapacity)..setRange(0, old, a);
    Float32List f32(Float32List a) =>
        Float32List(newCapacity)..setRange(0, old, a);
    Float64List f64(Float64List a) =>
        Float64List(newCapacity)..setRange(0, old, a);
    kind = u8(kind);
    variant = u8(variant);
    state = u8(state);
    purpose = u8(purpose);
    flags = u8(flags);
    grant = u8(grant);
    elem = i32(elem);
    routeCur = i32(routeCur);
    routeOff = i32(routeOff);
    routeLen = i32(routeLen);
    prev = i32(prev);
    next = i32(next);
    pass = i32(pass);
    owner = i32(owner);
    stuckUs = i32(stuckUs);
    waitUs = i32(waitUs);
    s = f32(s);
    v = f32(v);
    a = f32(a);
    v0 = f32(v0);
    f = f32(f);
    len = f32(len);
    destS = f32(destS);
    movedM = f32(movedM);
    freeFlowS = f32(freeFlowS);
    sPre = f32(sPre);
    vPre = f32(vPre);
    odo = f64(odo);
    edgeEnterUs = f64(edgeEnterUs);
    tripT0Us = f64(tripT0Us);
  }

  /// Puts the table on [lg].
  ///
  /// A graph that shares [lg]'s structure — a refresh of its controls, a
  /// light switched on — keeps every element id, so everything stands. Any
  /// other graph numbers everything afresh: the occupancy is cleared, and
  /// the owner must give every live vehicle its place on the new graph
  /// ([setRoute], [place]) and then [relinkAll] (§3.8 steps 2–3).
  void bind(LaneGraph lg) {
    final old = _lg;
    _lg = lg;
    if (old != null && lg.sharesStructureWith(old)) return;
    final nEl = lg.elementCount;
    if (elemHead.length < nEl) {
      elemHead = Int32List(nEl);
      elemTail = Int32List(nEl);
      elemCount = Int32List(nEl);
    }
    elemHead.fillRange(0, elemHead.length, -1);
    elemTail.fillRange(0, elemTail.length, -1);
    elemCount.fillRange(0, elemCount.length, 0);
    for (var sl = 0; sl < highWater; sl++) {
      prev[sl] = -1;
      next[sl] = -1;
    }
  }

  // ---- Routes -----------------------------------------------------------------

  /// The lane of route edge [i] of [slot]'s route.
  int laneOfRouteEdge(int slot, int i) {
    final data = arena.data;
    final off = routeOff[slot];
    return i == 0 ? data[off] : graph.conToLane[data[off + i]];
  }

  /// The connector taking [slot] from route edge [i] − 1 onto edge [i]
  /// (1 ≤ [i] < `routeLen`).
  int connectorOfRouteEdge(int slot, int i) => arena.data[routeOff[slot] + i];

  /// The element [slot] moves onto after its current one, or −1 on its last
  /// edge — and −1 off the road (a vehicle inside a site, [detach]), whose
  /// next place is no element at all until it is attached.
  int nextElemOf(int slot) {
    final lg = graph;
    final el = elem[slot];
    if (el < 0) return -1;
    if (el >= lg.laneCount) return lg.conToLane[el - lg.laneCount];
    final i = routeCur[slot] + 1;
    if (i >= routeLen[slot]) return -1;
    return lg.laneCount + arena.data[routeOff[slot] + i];
  }

  /// The lane [slot] stops in, and where along it (lane metres).
  double destLaneS(int slot) {
    final lg = graph;
    final e = lg.laneEdge[laneOfRouteEdge(slot, routeLen[slot] - 1)];
    return destS[slot] - lg.edgeLaneS0[e];
  }

  /// Replaces [slot]'s route with the [n] elements of [src] — a remap, or a
  /// re-plan from where it is — stopping [destS] travel metres along the new
  /// last edge, with the vehicle on route edge [routeCur]. The old block goes
  /// back to the arena. False (the old route kept) when [n] is no route the
  /// arena can hold.
  bool setRoute(int slot, Int32List src, int n,
      {required double destS, int routeCur = 0}) {
    if (n < 1 || n > RouteArena.maxBlock) return false;
    if (routeLen[slot] > 0) arena.free(routeOff[slot], routeLen[slot]);
    final off = arena.alloc(n);
    arena.data.setRange(off, off + n, src);
    routeOff[slot] = off;
    routeLen[slot] = n;
    this.routeCur[slot] = routeCur;
    this.destS[slot] = destS;
    return true;
  }

  /// Gives [slot] a place without touching the lists — after a rebuild,
  /// before [relinkAll].
  void place(int slot, int element, double sM) {
    elem[slot] = element;
    s[slot] = sM;
  }

  // ---- Spawn and free -------------------------------------------------------

  /// A new vehicle of [kind] at travel arc [originT] of its route's first
  /// edge, on the route of the [routeLength] elements in [route]
  /// (`[firstLane, c₁, …]`), stopping [destT] travel metres along its last
  /// edge. Returns its handle, or [SlotPool.none] when the table is full or
  /// the route is longer than the arena's largest block (the planner splits
  /// those into legs before they get here, §2.10).
  ///
  /// The vehicle is put in its lane's list at its place, so a spawn mid-lane
  /// keeps the order. Whether there is room to pull out there is the
  /// arbiter's question (`JunctionArbiter.canJoin`), asked first.
  int spawn({
    required AgentKind kind,
    required Int32List route,
    required int routeLength,
    required double originT,
    required double destT,
    required int nowUs,
    TripPurpose purpose = TripPurpose.commute,
    int variant = 0,
    int owner = -1,
    double speedFactor = 1.0,
    double speed = 0,
    double freeFlowS = 0,
  }) {
    if (routeLength < 1 || routeLength > RouteArena.maxBlock) {
      return SlotPool.none;
    }
    final h = pool.alloc();
    if (h == SlotPool.none) return h;
    final sl = h & SlotPool.slotMask;
    final lg = graph;
    final off = arena.alloc(routeLength);
    arena.data.setRange(off, off + routeLength, route);
    final lane = route[0];
    final e = lg.laneEdge[lane];
    var at = originT - lg.edgeLaneS0[e];
    final laneLen = lg.laneLength(lane);
    if (at < 0) at = 0;
    if (at > laneLen) at = laneLen;
    _init(sl, kind, lane, off, routeLength, at, speed, lg.edgeLimit[e],
        destT, nowUs, purpose, variant, owner, speedFactor, freeFlowS);
    link(sl);
    return h;
  }

  /// A new vehicle OFF the road (docs/plans/t4a-implementation.md §1.4): a
  /// car that starts its trip in a site stall. Everything [spawn] sets is
  /// set, the route included, but its [elem] is −1, its [s] 0 and its speed
  /// 0, and it is on no element's list; the caller marks it
  /// `VehicleState.onSite` (it starts [VehicleState.driving], as [spawn]
  /// does) and the site mover drives it to its throat, where [attach] puts
  /// it on the road.
  ///
  /// [originT] is where on the route's first edge the road leg will start:
  /// the table keeps no column for it (the facade's planner does), but it is
  /// asked for so both spawns read alike at their call sites. [SlotPool.none]
  /// when the table is full or the route too long, as for [spawn].
  int spawnDetached({
    required AgentKind kind,
    required Int32List route,
    required int routeLength,
    required double originT,
    required double destT,
    required int nowUs,
    TripPurpose purpose = TripPurpose.commute,
    int variant = 0,
    int owner = -1,
    double speedFactor = 1.0,
    double freeFlowS = 0,
  }) {
    if (routeLength < 1 || routeLength > RouteArena.maxBlock) {
      return SlotPool.none;
    }
    final h = pool.alloc();
    if (h == SlotPool.none) return h;
    final sl = h & SlotPool.slotMask;
    final lg = graph;
    final off = arena.alloc(routeLength);
    arena.data.setRange(off, off + routeLength, route);
    // The desired speed of the road it will pull out onto; the site mover
    // caps its own speeds, and [attach] sets this again.
    final limit = lg.edgeLimit[lg.laneEdge[route[0]]];
    _init(sl, kind, -1, off, routeLength, 0, 0, limit, destT, nowUs, purpose,
        variant, owner, speedFactor, freeFlowS);
    prev[sl] = -1;
    next[sl] = -1;
    return h;
  }

  /// Every column of a vehicle just handed slot [sl]: [spawn]'s and
  /// [spawnDetached]'s one initialisation, so the two can never disagree on
  /// a column one of them forgot.
  void _init(
      int sl,
      AgentKind kind,
      int element,
      int off,
      int routeLength,
      double at,
      double speed,
      double limit,
      double destT,
      int nowUs,
      TripPurpose purpose,
      int variant,
      int owner,
      double speedFactor,
      double freeFlowS) {
    this.kind[sl] = kind.index;
    this.variant[sl] = variant & 0xFF;
    state[sl] = VehicleState.driving.index;
    this.purpose[sl] = purpose.index;
    flags[sl] = 0;
    grant[sl] = 0;
    elem[sl] = element;
    routeCur[sl] = 0;
    routeOff[sl] = off;
    routeLen[sl] = routeLength;
    pass[sl] = -1;
    this.owner[sl] = owner;
    stuckUs[sl] = 0;
    waitUs[sl] = 0;
    s[sl] = at;
    v[sl] = speed;
    a[sl] = 0;
    f[sl] = speedFactor;
    v0[sl] = limit * speedFactor;
    len[sl] = VehicleKinds.lengthM[kind.index];
    destS[sl] = destT;
    movedM[sl] = 0;
    this.freeFlowS[sl] = freeFlowS;
    sPre[sl] = at;
    vPre[sl] = speed;
    odo[sl] = 0;
    edgeEnterUs[sl] = nowUs.toDouble();
    tripT0Us[sl] = nowUs.toDouble();
  }

  /// Takes [handle] off the road: out of its element's list, its route
  /// block back to the arena, its slot freed. False for a stale handle.
  /// Whatever else it held — a junction clearance, a place in a queue — is
  /// its holder's to release first (`VehicleMover.despawn` does both).
  bool free(int handle) {
    if (!pool.isLive(handle)) return false;
    final sl = handle & SlotPool.slotMask;
    unlink(sl);
    arena.free(routeOff[sl], routeLen[sl]);
    routeLen[sl] = 0;
    pass[sl] = -1;
    flags[sl] = 0;
    pool.free(handle);
    return true;
  }

  // ---- The lists ------------------------------------------------------------

  /// Puts [slot] into its element's list, in order of [s]: walked from the
  /// tail, so a vehicle arriving at the back — every hand-over — costs one
  /// step. Equal [s] goes behind. A vehicle off the road ([elem] −1, inside
  /// a site) has no list, and is left out.
  void link(int slot) {
    final el = elem[slot];
    if (el < 0) return;
    final at = s[slot];
    var ahead = elemTail[el];
    while (ahead >= 0 && s[ahead] < at) {
      ahead = prev[ahead];
    }
    prev[slot] = ahead;
    if (ahead >= 0) {
      final behind = next[ahead];
      next[slot] = behind;
      next[ahead] = slot;
      if (behind >= 0) {
        prev[behind] = slot;
      } else {
        elemTail[el] = slot;
      }
    } else {
      final head = elemHead[el];
      next[slot] = head;
      if (head >= 0) {
        prev[head] = slot;
      } else {
        elemTail[el] = slot;
      }
      elemHead[el] = slot;
    }
    elemCount[el]++;
  }

  /// Takes [slot] out of its element's list.
  void unlink(int slot) {
    final el = elem[slot];
    if (el < 0 || el >= elemHead.length) return;
    final p = prev[slot], n = next[slot];
    final linked = p >= 0 || n >= 0 || elemHead[el] == slot;
    if (!linked) return;
    if (p >= 0) {
      next[p] = n;
    } else {
      elemHead[el] = n;
    }
    if (n >= 0) {
      prev[n] = p;
    } else {
      elemTail[el] = p;
    }
    prev[slot] = -1;
    next[slot] = -1;
    elemCount[el]--;
  }

  /// Re-inserts every live vehicle on the road, in slot order, at its [elem]
  /// and [s]: after a rebuild has placed them on the new graph. A vehicle
  /// inside a site ([elem] −1) holds no road element to relink: the site
  /// mover relinks its own lists (docs/plans/t4a-implementation.md §1.2).
  void relinkAll() {
    elemHead.fillRange(0, elemHead.length, -1);
    elemTail.fillRange(0, elemTail.length, -1);
    elemCount.fillRange(0, elemCount.length, 0);
    for (var sl = 0; sl < highWater; sl++) {
      prev[sl] = -1;
      next[sl] = -1;
    }
    for (var sl = 0; sl < highWater; sl++) {
      if (pool.isSlotLive(sl) && elem[sl] >= 0) link(sl);
    }
  }

  // ---- Access events: off the road and back (site-access.md §7.4) ----------

  /// Takes [slot] off the road into a site: out of its element's list, its
  /// [elem] −1 (an ENTER, docs/plans/t4a-implementation.md §1.2). Its route
  /// block, its speed and its [s] are left as they are, for the site mover
  /// to set; so is [state], which the caller makes `VehicleState.onSite`.
  /// Whatever it held at a junction — a pass, a queue place — is the
  /// caller's to release first (`JunctionArbiter.release`), as for [free].
  /// Detaching a vehicle already off the road changes nothing.
  void detach(int slot) {
    unlink(slot);
    elem[slot] = -1;
    prev[slot] = -1;
    next[slot] = -1;
  }

  /// Puts [slot], off the road, into [lane] with its front at [laneS] lane
  /// metres (clamped onto the lane) moving at [speed]: an EXIT
  /// (docs/plans/t4a-implementation.md §1.4). The caller has set the route
  /// it drives from here ([setRoute], `routeCur` the edge [lane] is on) and
  /// its state; the flags are its too (a home back-out sets [kReversing]).
  ///
  /// The desired speed is the lane's, and the stuck clock starts afresh: a
  /// car just out of a site has not been stuck on this road. Its entry time
  /// is marked −1, as for a vehicle that pulled out part way along an edge:
  /// it observes nothing on this edge (§4.2, `VehicleMover`'s delay books),
  /// whose free time would be the whole lane's. [nowUs], the sub-step of the
  /// EXIT, is asked for as [spawn] asks for it; no column keeps it today.
  void attach(int slot, int lane, double laneS,
      {double speed = 0, required int nowUs}) {
    final lg = graph;
    if (elem[slot] >= 0) unlink(slot);
    final laneLen = lg.laneLength(lane);
    var at = laneS;
    if (at < 0) at = 0;
    if (at > laneLen) at = laneLen;
    elem[slot] = lane;
    s[slot] = at;
    v[slot] = speed;
    a[slot] = 0;
    v0[slot] = lg.edgeLimit[lg.laneEdge[lane]] * f[slot];
    sPre[slot] = at;
    vPre[slot] = speed;
    stuckUs[slot] = 0;
    movedM[slot] = 0;
    waitUs[slot] = 0;
    pass[slot] = -1;
    edgeEnterUs[slot] = -1;
    link(slot);
  }

  /// Packs the arena when fragmentation calls for it (§2.10): every live
  /// route relocated in slot order, its offset rewritten. Allocates nothing.
  bool compactRoutes() {
    if (!arena.needsCompaction) return false;
    arena.beginCompaction();
    for (var sl = 0; sl < highWater; sl++) {
      if (!pool.isSlotLive(sl)) continue;
      routeOff[sl] = arena.relocate(routeOff[sl], routeLen[sl]);
    }
    arena.endCompaction();
    return true;
  }

  /// Makes [handle] stand where it is, for good: a stalled vehicle, as the
  /// scenario tests and `CityAgents.debugStall` use one (§17). It dwells —
  /// motionless, its stuck timer frozen — until someone sets it driving.
  void stall(int handle) {
    if (!pool.isLive(handle)) return;
    final sl = handle & SlotPool.slotMask;
    state[sl] = VehicleState.dwelling.index;
    v[sl] = 0;
    a[sl] = 0;
  }
}
