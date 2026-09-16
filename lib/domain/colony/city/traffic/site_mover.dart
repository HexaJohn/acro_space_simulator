// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// How vehicles move inside sites, and across the kerb
/// (docs/plans/t4a-implementation.md §1.6; site-access.md §7.4, §7.8 items
/// 3–7, D49).
///
/// - **Inside a site** a vehicle has element −1 and state
///   `VehicleState.onSite`; its place is `(SiteVehicles.row, .lane,
///   VehicleTable.s)`. [SiteMover.step] runs IDM on site lanes (speed caps
///   from the plan, the throat at `AgentTuning.gateMaxMps`), follows
///   `SiteTable.nextLane` hops through §2.5 movements and turnarounds, and
///   ends in a scripted stall manoeuvre that lands exactly on the stall pose
///   ([SiteManoeuvre]). `sharedSingle` units are claimed whole, one
///   direction at a time, which is why no two cars can ever meet nose to
///   nose on a home drive.
/// - **The arrival gate** ([SiteMover.holdAtGate]): a car at `destS` with a
///   reserved stall is granted on G1–G3 (G2 by `JunctionArbiter.opposingClear`
///   through [AccessGaps]), forced after `AgentTuning.gateForcedS`, given up
///   after `gateGiveUpS` refused on the throat's room alone
///   ([SiteSink.gateGaveUp]). A grant logs ENTER, detaches the car and puts
///   it on the throat in-lane at s = 0. Every clock here counts MILLISECONDS
///   and saturates ([addClock]): a wait may run for hours, and an `Int32` of
///   microseconds wraps negative after 35.8 minutes, which would disarm the
///   very grant it was measuring for (traffic_time.dart).
/// - **Departures** ([SiteMover.spawnFromStall]): a car park, yard or
///   installation spawns a vehicle row detached at the stall, reverses out
///   along the very curve it came in by, drives to the throat and waits with
///   its front `throatStopM` inside the kerb line for `canJoin`; a grant logs
///   EXIT and attaches it. A home `inline` stall waits IN the stall for a
///   back-out gap ([AccessGaps.backOutClear]), then reverses down the drive
///   and swings its tail upstream into its target lane, logged
///   `backOutExit` as its rear crosses the kerb line, from which instant it
///   is a REVERSING vehicle in that lane (`VehicleState.manoeuvre`,
///   `kReversing`) until the 0.5 s shift is done. A gap that never comes is
///   given up after `AgentTuning.backOutGiveUpS`: the car goes back on its
///   stall and its owner is asked for the leg again (§7.5), because the
///   forced grant waives the ETA terms and NEVER a body in the footprint,
///   and a blocked driveway must not hold a car for ever.
/// - **Lane obstacles.** A granted back-out CLAIMS its footprint (and, for a
///   far-direction departure, the near lane it swings across) before its
///   body is in the lane, and the road mover reads those claims through
///   [LaneObstacles] as virtual stopped leaders. Two neighbouring
///   driveways can therefore never back out into each other: the second
///   claim overlaps the first and is refused.
/// - **Rebuilds and site changes.** [SiteMover.relink] rebuilds the site
///   lists after a site sync renumbered the site elements; [SiteMover.snap]
///   and [SiteMover.evacuate] are the §7.6 row 1 and row 3 moves;
///   [SiteMover.remapHeld] carries the road routes of cars waiting inside
///   sites across a lane-graph rebuild.
///
/// Nothing in a step allocates (§15.2): every column is a typed list grown
/// only with the vehicle table, and every pose is written into scratch.
///
/// **Order, and why it is what it is.** Decisions come first, in SLOT order,
/// because slot order is state and not history: two runs that reached the
/// same world decide in the same order. Movement comes second, element by
/// element and head to tail, so a follower always reads a leader that has
/// already moved. Structural changes — a hand-over onto another lane, a car
/// parked and gone — are deferred out of the walk, because the walk holds a
/// cursor into the very lists they edit.
library;

import 'dart:typed_data';

import '../site_access/site_access_constants.dart';
import '../site_access/site_access_plan.dart';
import '../site_access/site_lane_graph.dart';
import 'access_events.dart';
import 'access_gaps.dart';
import 'agent_kind.dart';
import 'graph_lineage.dart';
import 'junction_arbiter.dart';
import 'lane_graph.dart';
import 'lane_obstacles.dart';
import 'site_geometry.dart';
import 'site_manoeuvre.dart';
import 'site_stats.dart';
import 'site_table.dart';
import 'site_vehicles.dart';
import 'slot_pool.dart';
import 'traffic_rng.dart';
import 'traffic_time.dart';
import 'traffic_tuning.dart';
import 'trip_planner.dart';
import 'vehicle_mover.dart';
import 'vehicle_table.dart';

/// Told what the site mover did to vehicles, before their slots change, so
/// the owner can still read their columns. Implemented by the facade
/// (package E).
abstract interface class SiteSink {
  /// [handle] finished its stall manoeuvre on [stall] of site [row]: free
  /// its vehicle row and park its car there.
  ///
  /// [stall] is −1 when the mover had to give the car up where it stood — a
  /// re-plan left it with no route and no stall to go back to — and the car
  /// is garaged (§7.6 row 1's last resort).
  void parkedInStall(int handle, int row, int stall);

  /// [handle] gave its reserved stall up at the gate — the lot full, or 30 s
  /// refused on the throat's room: go on to D17 step 2 (a kerb slot).
  void gateGaveUp(int handle);

  /// [handle] crossed the kerb line out of its site onto the road (EXIT
  /// logged, attached).
  void exited(int handle);

  /// §7.5's tandem shuffle: [handle], waiting in a deep stall of [row], has
  /// been blocked by the parked car in stall [blocker] for
  /// `AgentTuning.tandemShuffleS`. Move that car to a free kerb slot — a
  /// counted relocation, never a teleport onto the carriageway — and answer
  /// true. False leaves it where it is and the clock starts again.
  bool shuffleBlocker(int handle, int row, int blocker);
}

/// A `sharedSingle` claim unit is held one way at a time:
/// [kUnitIn] toward the lot, [kUnitOut] toward the kerb.
const int kUnitIn = 1;
const int kUnitOut = 2;

/// How fast a scripted stall manoeuvre runs, m/s: a car crawls into its
/// space. Not an `AgentTuning` knob, because it changes only how long the
/// curve takes and never who may go.
const double kStallManoeuvreMps = 1.5;

/// A car whose front is this close to its stop on a site lane, and slower
/// than [kSiteRestMps], has arrived: the manoeuvre or the wait starts and
/// its `s` is snapped onto the stop exactly.
///
/// It must exceed `kStopShortM`, because the IDM's virtual leader brings a
/// car to rest that far SHORT of its stop and never any closer; the road
/// mover's own `kArriveM` is 1 m for the same reason. The snap is therefore
/// at most half a metre, and the manoeuvre that follows lands on the stall
/// exactly whatever it was.
const double kSiteArriveM = 1.0;
const double kSiteRestMps = 0.6;

/// Moves the vehicles inside sites. See the library comment.
class SiteMover implements LaneObstacles {
  SiteMover(this.table, this.site, this.sites, this.arbiter, this.events,
      this.stats);

  /// The vehicles, their site columns, and the synced site networks.
  final VehicleTable table;
  final SiteVehicles site;
  final SiteTable sites;

  /// The road's junction arbiter: `canJoin` and `opposingClear` at the kerb.
  final JunctionArbiter arbiter;

  /// Where ENTER and EXIT are logged, and what is counted.
  final AccessEventLog events;
  final SiteStats stats;

  /// The gap rules, over the same table and arbiter.
  late final AccessGaps gaps = AccessGaps(table, arbiter);

  LaneGraph? _lg;

  // ---- Columns of our own, by vehicle slot ---------------------------------

  /// The `sharedSingle` claim unit it holds (a GLOBAL unit index), or −1.
  /// `SiteVehicles.claim` holds the STALL, which a car keeps for the whole
  /// of its business, so the unit needs a column of its own.
  Int32List _unit = Int32List(0);

  /// Milliseconds refused at the gate on the throat's ROOM alone: what the
  /// 30 s give-up counts, as against `SiteVehicles.waitMs`, which counts
  /// every refusal and drives the 25 s forced grant (§7.4 step 4).
  Int32List _g1Ms = Int32List(0);

  /// Milliseconds a deep tandem car has been blocked by a parked outer car.
  Int32List _shuffleMs = Int32List(0);

  /// The travel arc on its route's first edge a departing car pulls out at.
  Float32List _originT = Float32List(0);

  /// The metres of the scripted curve it is on, so `manU` advances at a
  /// speed rather than at a rate.
  Float32List _curveM = Float32List(0);

  /// Deferred structural work from the movement walk: the slot, and which
  /// of [_doHandOver] / [_doParked] it needs.
  Int32List _hand = Int32List(0);
  Uint8List _handWhat = Uint8List(0);
  int _nHand = 0;
  static const int _doHandOver = 0;
  static const int _doParked = 1;

  /// Per site row, the cars held at its gate this sub-step: an outbound car
  /// that has not committed yields the drive to them (§7.4 deadlock).
  Int32List _heldRow = Int32List(0);

  // ---- The back-outs' claims on road lanes ---------------------------------

  /// Per claim: the road lane, its span in lane metres, and the vehicle slot
  /// that holds it. A far-direction back-out holds two.
  Int32List _clLane = Int32List(0), _clOwner = Int32List(0);
  Float32List _clFrom = Float32List(0), _clTo = Float32List(0);
  int _clCount = 0;

  /// Poses, written into by [SiteGeometry] and [SiteManoeuvre]: two of the
  /// former's five-double rows and room to spare.
  final Float64List _pose = Float64List(16);

  final IdmStep _idm = IdmStep();

  @override
  int get count => _clCount;

  /// Puts the mover on the road lane graph [lg].
  void bind(LaneGraph lg) => _lg = lg;

  // ---- The arrival gate (§7.4 steps 2–5) -----------------------------------

  /// Holds [handle], at its `destS`, at the gate of in-join [join] of site
  /// [row], with [stall] reserved for it (§7.4 steps 2–4).
  void holdAtGate(int handle, int row, int join, int stall) {
    if (!table.isLive(handle)) return;
    _ensure();
    final sl = SlotPool.slotOf(handle);
    site.clear(sl);
    site.row[sl] = row;
    site.join[sl] = join;
    site.claim[sl] = stall;
    site.phase[sl] = SitePhase.gateHeld.index;
    _unit[sl] = -1;
    _g1Ms[sl] = 0;
    _shuffleMs[sl] = 0;
  }

  /// Spawns a departing car detached on [stall] of site [row], leaving by
  /// out-join [join] on the road route [route] of [n] elements
  /// (`[firstLane, c₁, …]`) from [originT] to [destT]; its car is of [kind]
  /// and [variant], owned by [owner] of `CarOwnerKind` index [ownerKind].
  /// Returns its handle, or [SlotPool.none] when the table is full.
  ///
  /// A home `inline` stall waits in the stall for a gap (§7.4 Home
  /// back-out); every other stall starts its pull-out at once.
  int spawnFromStall(
      {required int row,
      required int stall,
      required int join,
      required AgentKind kind,
      required int variant,
      required int ownerKind,
      required int owner,
      required Int32List route,
      required int n,
      required double originT,
      required double destT,
      required int nowUs,
      required double speedFactor,
      required double freeFlowS}) {
    final lg = _lg;
    if (lg == null || !sites.isRowLive(row)) return SlotPool.none;
    final p = sites.plan[row];
    if (p == null || stall < 0 || stall >= sites.stallCount[row]) {
      return SlotPool.none;
    }
    final back = p.program == SiteProgram.homeDriveway &&
        p.stallAngle(stall) == StallAngle.inline;
    final lane = back
        ? -1
        : sites.laneOfTarget(row, sites.stallTarget(row, stall));
    if (!back && lane < 0) return SlotPool.none;
    final h = table.spawnDetached(
      kind: kind,
      route: route,
      routeLength: n,
      originT: originT,
      destT: destT,
      nowUs: nowUs,
      variant: variant,
      owner: owner,
      speedFactor: speedFactor,
      freeFlowS: freeFlowS,
    );
    if (h == SlotPool.none) return h;
    _ensure();
    final sl = SlotPool.slotOf(h);
    table.state[sl] = VehicleState.onSite.index;
    site.clear(sl);
    site.row[sl] = row;
    site.join[sl] = join;
    site.claim[sl] = stall;
    site.owner[sl] = owner;
    site.ownerKind[sl] = ownerKind & 0xFF;
    _unit[sl] = -1;
    _g1Ms[sl] = 0;
    _shuffleMs[sl] = 0;
    _originT[sl] = originT;
    sites.inside[row]++;
    if (back) {
      site.phase[sl] = SitePhase.backOutWait.index;
      return h;
    }
    final dir = SiteLaneGraph.isForward(lane) ? kSiteDirFwd : kSiteDirBwd;
    site.phase[sl] = SitePhase.stallOut.index;
    site.lane[sl] = lane;
    site.target[sl] = sites.joinTarget(row, join);
    site.manU[sl] = 1;
    _curveM[sl] = SiteManoeuvre.stallCurveM(p, stall, dir);
    table.s[sl] = SiteManoeuvre.mouthS(p, stall, dir);
    table.v[sl] = 0;
    _link(sl, row, lane);
    return h;
  }

  // ---- The sub-step --------------------------------------------------------

  /// One sub-step at agent time [nowUs], after the road mover's: the gate,
  /// the site lanes, the manoeuvres, the throats and the back-outs, telling
  /// [s] and [v] what became of each vehicle, and [spawns] whose leg has to
  /// be planned again — a home departure no gap ever came for (§7.5), which
  /// leaves its owner with a car back on a stall and nowhere to be.
  void step(int nowUs, SiteSink s, VehicleSink v, SpawnSink spawns) {
    final lg = _lg;
    if (lg == null) return;
    _ensure();
    final hw = table.highWater;

    // Who is waiting to come in, per site: an uncommitted outbound car
    // yields to them (§7.4 deadlock, inbound vs outbound).
    _heldRow.fillRange(0, _heldRow.length, 0);
    for (var sl = 0; sl < hw; sl++) {
      if (!table.isSlotLive(sl)) continue;
      if (site.phase[sl] != SitePhase.gateHeld.index) continue;
      final row = site.row[sl];
      if (row >= 0 && row < _heldRow.length) _heldRow[row]++;
    }

    // 1. Decisions, in slot order.
    for (var sl = 0; sl < hw; sl++) {
      if (!table.isSlotLive(sl)) continue;
      final ph = site.phase[sl];
      if (ph == SitePhase.gateHeld.index) {
        _gate(sl, nowUs, s);
      } else if (ph == SitePhase.throatWait.index) {
        _throat(sl, nowUs, s);
      } else if (ph == SitePhase.backOutWait.index) {
        _backOutGap(sl, s, spawns);
      } else if (ph == SitePhase.shift.index) {
        _shift(sl);
      }
    }

    // 2. The site lanes, element by element, head to tail.
    _nHand = 0;
    final nEl = sites.elemHead.length;
    for (var el = 0; el < nEl; el++) {
      var sl = sites.elemHead[el];
      while (sl >= 0) {
        final next = site.sNext[sl];
        _drive(sl, el);
        sl = next;
      }
    }
    for (var i = 0; i < _nHand; i++) {
      if (_handWhat[i] == _doHandOver) {
        _handOver(_hand[i]);
      } else {
        _parked(_hand[i], s);
      }
    }

    // 3. The back-outs, whose pose is on no site list at all.
    for (var sl = 0; sl < hw; sl++) {
      if (!table.isSlotLive(sl)) continue;
      if (site.phase[sl] == SitePhase.backOut.index) {
        _backOutStep(sl, nowUs, s);
      }
    }
  }

  void _gate(int sl, int nowUs, SiteSink sink) {
    final t = table, lg = _lg!;
    final row = site.row[sl], join = site.join[sl], stall = site.claim[sl];
    final el = t.elem[sl];
    final g = sites.isRowLive(row) ? sites.lanes[row] : null;
    final p = sites.isRowLive(row) ? sites.plan[row] : null;
    if (g == null || p == null || el < 0 || el >= lg.laneCount) {
      _giveUpGate(sl, sink);
      return;
    }
    final inLane = g.inLane(join);
    if (inLane < 0) {
      _giveUpGate(sl, sink);
      return;
    }
    final len = t.len[sl].toDouble();
    // G3: at a walking pace or less.
    final speedOk = t.v[sl] <= AgentTuning.gateMaxMps;
    // G1: room on the throat in-lane for the car's length. This is the
    // in-lane's OWN list, as §7.4 words it: a car that has already turned
    // off the throat onto the pad, its tail still over it, does not shut
    // the gate — the site IDM's one-element look-ahead is what stops the
    // next car behind it, inside the site rather than across the kerb.
    final e = sites.elemBase[row] + inLane;
    final tail = sites.elemTail[e];
    final room =
        tail < 0 ? sites.elemLen[e].toDouble() : t.s[tail] - t.len[tail];
    final roomOk = room >= len;
    // G1b: no outbound car holds the drive.
    final unit = sites.elemUnit[e];
    final unitOk = unit < 0 || _canClaim(unit, kUnitIn);
    // G2: a far-side left-in takes the opposing gap (ask 14). The ETA half
    // of it — and nothing else — is waived after 25 s.
    final edge = lg.laneEdge[el];
    final left = _leftOfTravel(p, join, lg, edge);
    final at = t.s[sl].toDouble();
    final forced = site.waitMs[sl] >= msOf(AgentTuning.gateForcedS);
    final crossOk =
        !left || gaps.turnInClear(el, at, len, forced: forced);
    if (speedOk && roomOk && unitOk && crossOk) {
      if (left && forced && !arbiter.opposingClear(el, at, len)) {
        stats.gateForced++;
      }
      _enter(sl, row, join, stall, inLane, el, edge);
      return;
    }
    site.waitMs[sl] = addClock(site.waitMs[sl], kStepMs);
    // The give-up clock runs only while the throat's room, or the claim on
    // it, is the reason: everything else clears by itself (§7.4 step 4).
    if (!roomOk || !unitOk) {
      _g1Ms[sl] = addClock(_g1Ms[sl], kStepMs);
      if (_g1Ms[sl] >= msOf(AgentTuning.gateGiveUpS)) _giveUpGate(sl, sink);
    }
  }

  /// The grant: ENTER logged at the join, the car off the road and on the
  /// throat in-lane at s = 0 (§7.4 step 5).
  void _enter(
      int sl, int row, int join, int stall, int inLane, int el, int edge) {
    final t = table, lg = _lg!;
    final arc = lg.edgeLaneS0[edge] + t.s[sl];
    events.log(AccessEventKind.enter, t.handleOf(sl), edge, arc, el, row, join);
    stats.enters++;
    arbiter.release(sl);
    t.detach(sl);
    t.state[sl] = VehicleState.onSite.index;
    t.s[sl] = 0;
    var v = t.v[sl].toDouble();
    if (v > AgentTuning.gateMaxMps) v = AgentTuning.gateMaxMps;
    t.v[sl] = v;
    t.a[sl] = 0;
    site.phase[sl] = SitePhase.inbound.index;
    site.lane[sl] = inLane;
    site.target[sl] = sites.stallTarget(row, stall);
    site.waitMs[sl] = 0;
    _g1Ms[sl] = 0;
    final unit = sites.elemUnit[sites.elemBase[row] + inLane];
    if (unit >= 0) _claim(unit, kUnitIn, sl);
    sites.inside[row]++;
    _link(sl, row, inLane);
  }

  void _giveUpGate(int sl, SiteSink sink) {
    final row = site.row[sl], stall = site.claim[sl];
    if (sites.isRowLive(row) && stall >= 0) sites.unreserve(row, stall);
    stats.gateGiveUps++;
    sink.gateGaveUp(table.handleOf(sl));
    // The columns go whether the owner freed the slot or kept it: a slot
    // handed out again must never inherit a dead car's site business.
    site.clear(sl);
    _unit[sl] = -1;
    _g1Ms[sl] = 0;
  }

  // ---- Driving the site lanes ----------------------------------------------

  void _drive(int sl, int el) {
    final ph = site.phase[sl];
    if (ph == SitePhase.stallIn.index || ph == SitePhase.stallOut.index) {
      _manoeuvre(sl);
      return;
    }
    if (ph == SitePhase.throatWait.index) {
      table.v[sl] = 0;
      table.a[sl] = 0;
      return;
    }
    if (ph != SitePhase.inbound.index && ph != SitePhase.toThroat.index) {
      return;
    }
    final t = table;
    final row = site.row[sl], lane = site.lane[sl], target = site.target[sl];
    final len = sites.elemLen[el].toDouble();
    final stop = _stopOn(sl, row, lane, target, len);
    final s = t.s[sl].toDouble(), v = t.v[sl].toDouble();
    final k = t.kind[sl];
    final s0 = VehicleKinds.jamM[k];
    _gap = double.infinity;
    _lv = 0;
    _room = double.infinity;
    _roomV = 0;
    final prev = site.sPrev[sl];
    if (prev >= 0) {
      final g = t.s[prev] - t.len[prev] - s;
      _lead(g, t.v[prev].toDouble(), g - kLeaderClearM);
    }
    _lead(stop - s + s0 - kStopShortM, 0, stop - s);
    // One element of look-ahead where the car hands over: a site lane is
    // metres long, so without it a car would roll onto a full aisle.
    if (stop >= len && prev < 0) {
      final nx = sites.nextLane(row, lane, target);
      if (nx >= 0 && nx != lane) {
        final ne = sites.elemBase[row] + nx;
        final tl = sites.elemTail[ne];
        if (tl >= 0) {
          final g = (len - s) + (t.s[tl] - t.len[tl]);
          _lead(g, t.v[tl].toDouble(), g - kLeaderClearM);
        }
      }
    }
    var v0 = sites.elemVmax[el] * t.f[sl];
    final cap = _speedCap(row, lane, site.join[sl]);
    if (v0 > cap) v0 = cap;
    if (v0 < 0.1) v0 = 0.1;
    final acc = Idm.accel(v, v0, _gap, v - _lv, VehicleKinds.accel[k],
        VehicleKinds.headwayS[k], s0, VehicleKinds.sqrtAb[k]);
    _idm.run(v, acc, kStepS);
    var ds = _idm.ds, vn = _idm.v;
    if (ds > _room) {
      ds = _room > 0 ? _room : 0.0;
      if (vn > _roomV) vn = _roomV;
    }
    final sn = s + ds;
    t.s[sl] = sn;
    t.v[sl] = vn;
    t.a[sl] = (vn - v) / kStepS;
    t.odo[sl] += ds;
    t.movedM[sl] += ds;
    if (sn >= len) {
      _push(sl, _doHandOver);
      return;
    }
    if (stop <= len && sn >= stop - kSiteArriveM && vn < kSiteRestMps) {
      t.s[sl] = stop;
      t.v[sl] = 0;
      t.a[sl] = 0;
      _atStop(sl, row, lane, target);
    }
  }

  /// The arc, measured along [lane], the front may not pass: the mouth of
  /// the stall or the stop inside the kerb line where this lane holds the
  /// target, and the end of the lane where it does not.
  ///
  /// A stop one hand-over ahead is answered as `len + that` — a stop BEYOND
  /// this lane — so a car slows for the end of its drive rather than running
  /// the throat at full site speed and stopping dead on the pad.
  double _stopOn(int sl, int row, int lane, int target, double len) {
    final nx = sites.nextLane(row, lane, target);
    if (nx == lane) return _stopEnd(sl, row, lane, target, len);
    if (nx < 0) return len;
    if (sites.nextLane(row, nx, target) != nx) return len;
    final nlen = sites.elemLen[sites.elemBase[row] + nx].toDouble();
    return len + _stopEnd(sl, row, nx, target, nlen);
  }

  /// The stop on the lane that HOLDS the target.
  double _stopEnd(int sl, int row, int lane, int target, double len) {
    final p = sites.plan[row];
    if (p == null) return len;
    if (target < sites.stallCount[row]) {
      final stall = site.claim[sl];
      if (stall < 0) return len;
      final dir = SiteLaneGraph.isForward(lane) ? kSiteDirFwd : kSiteDirBwd;
      return SiteManoeuvre.mouthS(p, stall, dir);
    }
    final st = len - AgentTuning.throatStopM;
    return st < 0 ? 0 : st;
  }

  /// Arrived where this leg ends: into the stall manoeuvre, or into the
  /// throat's wait for a gap.
  void _atStop(int sl, int row, int lane, int target) {
    final p = sites.plan[row];
    if (p == null) return;
    if (target < sites.stallCount[row]) {
      final stall = site.claim[sl];
      final dir = SiteLaneGraph.isForward(lane) ? kSiteDirFwd : kSiteDirBwd;
      site.phase[sl] = SitePhase.stallIn.index;
      site.manU[sl] = 0;
      _curveM[sl] = SiteManoeuvre.stallCurveM(p, stall, dir);
      return;
    }
    site.phase[sl] = SitePhase.throatWait.index;
    site.waitMs[sl] = 0;
  }

  /// One sub-step of a scripted stall manoeuvre, in or out. The car holds
  /// its place on the aisle while it runs, so whoever is behind waits.
  void _manoeuvre(int sl) {
    final t = table;
    final row = site.row[sl];
    final p = sites.plan[row];
    t.v[sl] = 0;
    t.a[sl] = 0;
    if (p == null) return;
    final curve = _curveM[sl] > 0.01 ? _curveM[sl].toDouble() : 0.01;
    final du = kStallManoeuvreMps * kStepS / curve;
    if (site.phase[sl] == SitePhase.stallIn.index) {
      final u = site.manU[sl] + du;
      if (u >= 1) {
        site.manU[sl] = 1;
        _push(sl, _doParked);
        return;
      }
      site.manU[sl] = u;
      return;
    }
    var u = site.manU[sl] - du;
    if (u < 0) u = 0;
    site.manU[sl] = u;
    // §7.4 departure step 3: the stall is another car's once no part of this
    // one is left inside it — on a reverse-out the nose is the last to go.
    final stall = site.claim[sl];
    if (stall >= 0 && _clearOfStall(p, stall, sl, u)) {
      sites.unreserve(row, stall);
      sites.vacate(row, stall);
      site.claim[sl] = -1;
    }
    if (u <= 0) {
      site.phase[sl] = SitePhase.toThroat.index;
      site.target[sl] = sites.joinTarget(row, site.join[sl]);
    }
  }

  /// Whether the car's whole body is out of [stall] at manoeuvre parameter
  /// [u]: its deepest point — the NOSE, since a car nose-in leaves rear
  /// first — across the stall's mouth line.
  ///
  /// The nose's reach into the stall shrinks as the car turns onto its
  /// aisle, which is why the heading is read from the pose rather than
  /// assumed to be the stall's: a car square across the aisle is out of its
  /// space even though its centre has barely moved half a length.
  bool _clearOfStall(SiteAccessPlan p, int stall, int sl, double u) {
    final lane = site.lane[sl];
    final dir = SiteLaneGraph.isForward(lane) ? kSiteDirFwd : kSiteDirBwd;
    SiteManoeuvre.stallPose(p, stall, dir, u, _pose, 0);
    final de = p.stallDirE(stall), dn = p.stallDirN(stall);
    final along =
        (_pose[0] - p.stallE(stall)) * de + (_pose[1] - p.stallN(stall)) * dn;
    final nose = (_pose[2] * de + _pose[3] * dn) * table.len[sl] / 2;
    return along + nose <= -p.stallLenM(stall) / 2;
  }

  /// A car has landed on its stall: off the site lists and into the owner's
  /// hands, which free its vehicle row and park its car.
  void _parked(int sl, SiteSink sink) {
    final row = site.row[sl], stall = site.claim[sl];
    _unlink(sl);
    _releaseUnit(sl);
    if (sites.isRowLive(row) && sites.inside[row] > 0) sites.inside[row]--;
    sink.parkedInStall(table.handleOf(sl), row, stall);
    site.clear(sl);
    _unit[sl] = -1;
  }

  /// A hand-over onto the next site lane toward the target, with the claim
  /// unit taken or held as the chain changes (§7.4 `sharedSingle`).
  void _handOver(int sl) {
    final t = table;
    final row = site.row[sl], lane = site.lane[sl], target = site.target[sl];
    if (!sites.isRowLive(row) || lane < 0) return;
    final el = sites.elemBase[row] + lane;
    final len = sites.elemLen[el].toDouble();
    final nx = sites.nextLane(row, lane, target);
    if (nx < 0 || nx == lane) {
      t.s[sl] = len;
      t.v[sl] = 0;
      return;
    }
    final want = sites.elemUnit[sites.elemBase[row] + nx];
    final have = _unit[sl];
    final dir = _dirOf(sl);
    if (want != have && want >= 0 && !_canClaim(want, dir)) {
      t.s[sl] = len;
      t.v[sl] = 0;
      return;
    }
    _unlink(sl);
    if (want != have) {
      _releaseUnit(sl);
      if (want >= 0) _claim(want, dir, sl);
    }
    site.lane[sl] = nx;
    var over = t.s[sl] - len;
    if (over < 0) over = 0;
    final nlen = sites.elemLen[sites.elemBase[row] + nx];
    if (over > nlen) over = nlen;
    t.s[sl] = over;
    _link(sl, row, nx);
  }

  // ---- Forward-out departures (§7.4 departure steps 4–5) -------------------

  void _throat(int sl, int nowUs, SiteSink sink) {
    final t = table, lg = _lg!;
    final row = site.row[sl], join = site.join[sl];
    final p = sites.isRowLive(row) ? sites.plan[row] : null;
    if (p == null || t.routeLen[sl] <= 0) return;
    final lane = t.arena.data[t.routeOff[sl]];
    final edge = lg.laneEdge[lane];
    final at = _originT[sl] - lg.edgeLaneS0[edge];
    final left = _leftOfTravel(p, join, lg, edge);
    final kind = AgentKind.values[t.kind[sl]];
    if (!arbiter.canJoin(lane, at, t.len[sl].toDouble(), kind,
        fromLeft: left)) {
      site.waitMs[sl] = addClock(site.waitMs[sl], kStepMs);
      // §7.4 step 6: a car queueing for its gap is not stuck until it has
      // been there a minute. Its stuck clock saturates too: the road mover
      // never sees a car inside a site, so nothing else bounds this one, and
      // in microseconds it would wrap after 35.8 minutes at the throat.
      if (site.waitMs[sl] > msOf(AgentTuning.throatStuckAfterS)) {
        t.stuckUs[sl] = addClock(t.stuckUs[sl], kStepUs);
      }
      return;
    }
    events.log(AccessEventKind.exit, t.handleOf(sl), edge,
        lg.edgeLaneS0[edge] + at, lane, row, join);
    stats.exits++;
    _unlink(sl);
    _releaseUnit(sl);
    if (sites.isRowLive(row) && sites.inside[row] > 0) sites.inside[row]--;
    t.attach(sl, lane, at, nowUs: nowUs);
    t.routeCur[sl] = 0;
    t.state[sl] = VehicleState.driving.index;
    sink.exited(t.handleOf(sl));
    site.clear(sl);
    _unit[sl] = -1;
  }

  // ---- The home back-out (§7.4 Home back-out) ------------------------------

  /// A car waiting in its stall: the clock, the give-up, the blockers, the
  /// claims and the gap.
  ///
  /// The clock is first and the give-up second, before anything that can
  /// answer "not yet", so that NO path through this method leaves a car
  /// waiting for ever — not a blocker nowhere will take, not a plan that
  /// went, not a footprint something stands in all day (§7.5).
  void _backOutGap(int sl, SiteSink sink, SpawnSink spawns) {
    final t = table, lg = _lg!;
    final row = site.row[sl], join = site.join[sl], stall = site.claim[sl];
    final p = sites.isRowLive(row) ? sites.plan[row] : null;
    site.waitMs[sl] = addClock(site.waitMs[sl], kStepMs);
    if (site.waitMs[sl] >= msOf(AgentTuning.backOutGiveUpS)) {
      _giveUpBackOut(sl, sink, spawns);
      return;
    }
    if (p == null || t.routeLen[sl] <= 0 || stall < 0) return;
    // Physically blocked by the car in front of it on a tandem pad: it goes
    // nowhere until that car is shuffled away (§7.5).
    final blocker = _blockerOf(row, p, stall);
    if (blocker >= 0) {
      _shuffleMs[sl] = addClock(_shuffleMs[sl], kStepMs);
      if (_shuffleMs[sl] >= msOf(AgentTuning.tandemShuffleS)) {
        _shuffleMs[sl] = 0;
        if (sink.shuffleBlocker(t.handleOf(sl), row, blocker)) stats.shuffles++;
      }
      return;
    }
    _shuffleMs[sl] = 0;
    // An inbound car held at the gate has the right of way while we are
    // uncommitted: we wait in the stall (§7.4 deadlock).
    if (row < _heldRow.length && _heldRow[row] > 0) return;
    final unit = _stallUnit(row, p, stall);
    if (unit >= 0 && !_canClaim(unit, kUnitOut)) return;
    final lane = t.arena.data[t.routeOff[sl]];
    final edge = lg.laneEdge[lane];
    final arc = lg.travelArc(edge, p.joinRoadS(join));
    final far = _leftOfTravel(p, join, lg, edge);
    final forced = site.waitMs[sl] >= msOf(AgentTuning.backOutForcedS);
    // Two neighbours never reverse into each other: an overlapping claim is
    // refused, the earlier slot of this sub-step keeping it.
    if (_claimOverlaps(lane, edge, arc)) return;
    if (!gaps.backOutClear(lane, arc, far: far, forced: forced)) return;
    if (forced) stats.backOutForced++;
    if (unit >= 0) _claim(unit, kUnitOut, sl);
    _takeFootprint(sl, lane, edge, arc, far);
    site.phase[sl] = SitePhase.backOut.index;
    site.lane[sl] = -1;
    site.manU[sl] = 0;
    site.waitMs[sl] = 0;
    _curveM[sl] = SiteManoeuvre.backOutLengthM(
        p, join, stall, lane, lg, t.len[sl].toDouble());
  }

  /// §7.5: the departure no gap ever came for. The forced grant waives the
  /// ETA terms and nothing else — a body in the footprint is a collision
  /// however long the car has waited, and so is a queue it would reverse
  /// into — so a drive held by something that does not move (a van standing
  /// at the kerb, a jam that never clears, a tandem blocker nowhere would
  /// take) would hold the car, its stall and its owner's leg for as long as
  /// the obstruction stood. After `backOutGiveUpS` it gives the departure
  /// up: the car goes back on the stall it never left, counted, and its
  /// owner is asked for the leg again, which plans a fresh route from the
  /// site's out-joins and may come back by another join or another
  /// direction (the same way out `remapHeld` takes for a route it cannot
  /// carry, §7.6).
  ///
  /// No gap is accepted and no kerb is crossed, so the one safety rule the
  /// back-out has — never an EXIT with a body in the footprint — is not
  /// touched by any of this.
  void _giveUpBackOut(int sl, SiteSink sink, SpawnSink spawns) {
    stats.backOutGiveUps++;
    // The owner is told BEFORE the car is parked, because parking it frees
    // the vehicle row and with it the owner column this reads (§7.4's
    // gateGaveUp takes what it needs in the same order, and for the same
    // reason).
    spawns.replanWaiting(table.owner[sl]);
    _backToStall(sl, sink);
  }

  /// The reverse and the swing, one sub-step at `backOutMaxMps`.
  void _backOutStep(int sl, int nowUs, SiteSink sink) {
    final t = table, lg = _lg!;
    final row = site.row[sl], join = site.join[sl], stall = site.claim[sl];
    final p = sites.isRowLive(row) ? sites.plan[row] : null;
    if (p == null || t.routeLen[sl] <= 0) return;
    final lane = t.arena.data[t.routeOff[sl]];
    final lenM = t.len[sl].toDouble();
    final curve = _curveM[sl] > 0.01 ? _curveM[sl].toDouble() : 0.01;
    final uk = SiteManoeuvre.backOutCommitU(p, join, stall, lane, lg, lenM);
    final was = site.manU[sl].toDouble();
    var u = was + AgentTuning.backOutMaxMps * kStepS / curve;
    if (u > 1) u = 1;
    site.manU[sl] = u;
    if (was < uk && u >= uk) {
      _backOutExit(sl, nowUs, row, join, stall, lane, sink);
    }
    if (u >= 1) {
      site.phase[sl] = SitePhase.shift.index;
      site.waitMs[sl] = 0;
    }
  }

  /// The rear crosses the kerb line: EXIT logged, the car inserted into its
  /// target lane as a REVERSING vehicle at the place its swing ends — inside
  /// the footprint it cleared, and nowhere else (§7.4 EXIT logging).
  ///
  /// [SiteManoeuvre.restLaneS] answers where the FRONT rests, which is what
  /// [VehicleTable.attach] wants and what the road mover and the renderer
  /// both read `s` as (§2.3, §13.3): the same arc the swing ends on, so the
  /// pose does not step half a length when the road takes the car over.
  void _backOutExit(int sl, int nowUs, int row, int join, int stall, int lane,
      SiteSink sink) {
    final t = table, lg = _lg!;
    final p = sites.plan[row]!;
    final edge = lg.laneEdge[lane];
    final arc = lg.travelArc(edge, p.joinRoadS(join));
    final rest = SiteManoeuvre.restLaneS(p, join, lane, lg);
    events.log(
        AccessEventKind.backOutExit, t.handleOf(sl), edge, arc, lane, row, join);
    stats.exits++;
    if (stall >= 0) {
      sites.unreserve(row, stall);
      sites.vacate(row, stall);
    }
    t.attach(sl, lane, rest, nowUs: nowUs);
    t.state[sl] = VehicleState.manoeuvre.index;
    t.flags[sl] |= kReversing;
    t.routeCur[sl] = 0;
    sink.exited(t.handleOf(sl));
  }

  /// The 0.5 s stop to shift out of reverse, and then the car is the road
  /// mover's again.
  void _shift(int sl) {
    site.waitMs[sl] = addClock(site.waitMs[sl], kStepMs);
    if (site.waitMs[sl] < msOf(AgentTuning.shiftStopS)) return;
    final t = table;
    t.flags[sl] &= ~kReversing;
    t.state[sl] = VehicleState.driving.index;
    final row = site.row[sl];
    _releaseFootprint(sl);
    _releaseUnit(sl);
    if (sites.isRowLive(row) && sites.inside[row] > 0) sites.inside[row]--;
    site.clear(sl);
    _unit[sl] = -1;
  }

  /// The parked car in the way of a deep tandem stall, or −1: a stall of the
  /// same pad segment nearer the street (a smaller arc), holding a car.
  int _blockerOf(int row, SiteAccessPlan p, int stall) {
    if (p.program != SiteProgram.homeDriveway) return -1;
    final seg = p.stallSeg(stall), s = p.stallS(stall);
    final base = sites.stallBase[row];
    final n = sites.stallCount[row];
    for (var i = 0; i < n; i++) {
      if (i == stall || p.stallSeg(i) != seg) continue;
      if (p.stallS(i) >= s) continue;
      if (sites.stallCar[base + i] >= 0) return i;
    }
    return -1;
  }

  // ---- The claims a back-out holds on road lanes ---------------------------

  void _takeFootprint(int sl, int lane, int edge, double arc, bool far) {
    final lg = _lg!;
    final at = arc - lg.edgeLaneS0[edge];
    _addClaim(sl, lane, at - AgentTuning.backOutUpM,
        at + AgentTuning.backOutDownM);
    if (!far) return;
    // The near lane is only crossed, never occupied: a claim for the
    // manoeuvre's duration (§7.4 EXIT logging).
    final n = lg.edgeReverse[edge];
    if (n < 0) return;
    final an = (lg.edgeLen[edge] - arc) - lg.edgeLaneS0[n];
    _addClaim(sl, lg.laneOf(n, 0), an - AgentTuning.backOutDownM,
        an + AgentTuning.backOutUpM);
  }

  void _addClaim(int sl, int lane, double from, double to) {
    if (_clCount >= _clLane.length) return;
    _clLane[_clCount] = lane;
    _clFrom[_clCount] = from;
    _clTo[_clCount] = to;
    _clOwner[_clCount] = sl;
    _clCount++;
  }

  void _releaseFootprint(int sl) {
    var w = 0;
    for (var i = 0; i < _clCount; i++) {
      if (_clOwner[i] == sl) continue;
      if (w != i) {
        _clLane[w] = _clLane[i];
        _clFrom[w] = _clFrom[i];
        _clTo[w] = _clTo[i];
        _clOwner[w] = _clOwner[i];
      }
      w++;
    }
    _clCount = w;
  }

  /// Whether a footprint at [arc] on [lane] would overlap one already held.
  bool _claimOverlaps(int lane, int edge, double arc) {
    final lg = _lg!;
    final at = arc - lg.edgeLaneS0[edge];
    final from = at - AgentTuning.backOutUpM;
    final to = at + AgentTuning.backOutDownM;
    for (var i = 0; i < _clCount; i++) {
      if (_clLane[i] != lane) continue;
      if (_clFrom[i] <= to && _clTo[i] >= from) return true;
    }
    return false;
  }

  /// See [LaneObstacles.obstacleAhead].
  @override
  bool obstacleAhead(int lane, double laneS, Float64List out) {
    var best = double.infinity;
    for (var i = 0; i < _clCount; i++) {
      if (_clLane[i] != lane) continue;
      final f = _clFrom[i].toDouble();
      if (f <= laneS || f >= best) continue;
      best = f;
    }
    if (best == double.infinity) return false;
    out[0] = best;
    out[1] = 0;
    return true;
  }

  // ---- Site changes (§7.6) -------------------------------------------------

  /// Rebuilds the site lists from the site columns after a site sync has
  /// renumbered the site elements, and re-counts who is inside each row —
  /// which is what decides when a limbo row may be freed.
  void relink() {
    _ensure();
    final n = sites.elemHead.length;
    sites.elemHead.fillRange(0, n, -1);
    sites.elemTail.fillRange(0, n, -1);
    sites.elemCount.fillRange(0, n, 0);
    for (var r = 0; r < sites.highWater; r++) {
      if (sites.isRowLive(r)) sites.inside[r] = 0;
    }
    final hw = table.highWater;
    for (var sl = 0; sl < hw; sl++) {
      site.sPrev[sl] = -1;
      site.sNext[sl] = -1;
    }
    for (var sl = 0; sl < hw; sl++) {
      if (!table.isSlotLive(sl)) continue;
      final ph = site.phase[sl];
      if (!_inside(ph)) continue;
      final row = site.row[sl];
      if (row < 0 || !sites.isRowLive(row)) continue;
      sites.inside[row]++;
      final lane = site.lane[sl];
      if (lane >= 0 && _onLane(ph)) _link(sl, row, lane);
    }
  }

  /// §7.6 row 1: the movers in [oldRow] snap onto [newRow]'s lanes (within
  /// `siteSnapM` and the angle of `siteSnapCos`), or stay on the old plan,
  /// which is readable in limbo until its last car has left.
  void snap(int oldRow, int newRow) {
    _ensure();
    if (oldRow < 0 || oldRow >= sites.highWater) return;
    final og = sites.lanes[oldRow];
    final op = sites.plan[oldRow];
    final ng = newRow >= 0 && sites.isRowLive(newRow) ? sites.lanes[newRow] : null;
    final np = newRow >= 0 && sites.isRowLive(newRow) ? sites.plan[newRow] : null;
    if (og == null || op == null || ng == null || np == null) return;
    for (var sl = 0; sl < table.highWater; sl++) {
      if (!table.isSlotLive(sl) || site.row[sl] != oldRow) continue;
      final ph = site.phase[sl];
      if (ph == SitePhase.none.index) continue;
      // The stall follows its KEY, never its index (C-19).
      final stall = site.claim[sl];
      final key = stall >= 0 && stall < op.stallCount ? op.stallKey(stall) : -1;
      final now = key < 0 ? -1 : np.stallIndexOfKey(key);
      if (_onLane(ph)) {
        SiteGeometry.pointAt(
            og, site.lane[sl], table.s[sl].toDouble(), _pose, 0);
        final lane = SiteGeometry.snap(ng, _pose[0], _pose[1], _pose[2],
            _pose[3], AgentTuning.siteSnapM, AgentTuning.siteSnapCos, _pose, 5);
        if (lane < 0) continue;
        _unlink(sl);
        _releaseUnit(sl);
        if (sites.inside[oldRow] > 0) sites.inside[oldRow]--;
        site.row[sl] = newRow;
        site.lane[sl] = lane;
        table.s[sl] = _pose[9];
        sites.inside[newRow]++;
        _retarget(sl, newRow, np, op, now, ph);
        // A car half way through a manoeuvre on the OLD plan drives its leg
        // again on the new one rather than finishing a curve that no longer
        // leads anywhere (§7.6 row 1, "re-plan the site leg").
        final t = site.target[sl];
        site.phase[sl] = t >= 0 && t < sites.stallCount[newRow]
            ? SitePhase.inbound.index
            : SitePhase.toThroat.index;
        site.manU[sl] = 0;
        _link(sl, newRow, lane);
        stats.snaps++;
        continue;
      }
      // In a stall, or waiting in one: it moves with its key, or it stays.
      if (now < 0) continue;
      if (sites.inside[oldRow] > 0) sites.inside[oldRow]--;
      _releaseUnit(sl);
      site.row[sl] = newRow;
      site.claim[sl] = now;
      sites.inside[newRow]++;
      _retarget(sl, newRow, np, op, now, ph);
      stats.snaps++;
    }
  }

  /// A snapped mover's join, target and reservation on its new row [row],
  /// whose plan is [np] where it was [op].
  void _retarget(int sl, int row, SiteAccessPlan np, SiteAccessPlan op,
      int stall, int ph) {
    final join = _joinBySlot(np, site.join[sl], op);
    if (join >= 0) site.join[sl] = join;
    if (ph == SitePhase.toThroat.index || ph == SitePhase.stallOut.index) {
      site.target[sl] = sites.joinTarget(row, site.join[sl]);
      stats.siteRetargets++;
      return;
    }
    if (stall >= 0) {
      site.claim[sl] = stall;
      sites.reserve(row, stall, table.handleOf(sl));
      site.target[sl] = sites.stallTarget(row, stall);
      return;
    }
    final free = sites.firstFreeStall(row, site.join[sl]);
    if (free < 0) return;
    site.claim[sl] = free;
    sites.reserve(row, free, table.handleOf(sl));
    site.target[sl] = sites.stallTarget(row, free);
    stats.siteRetargets++;
  }

  /// The index in [p] of the join whose SLOT the mover came in by — the
  /// identity a join keeps across a re-plan.
  int _joinBySlot(SiteAccessPlan p, int was, SiteAccessPlan? old) {
    if (old == null || was < 0 || was >= old.joinCount) return -1;
    final slot = old.joinSlot(was);
    for (var j = 0; j < p.joinCount; j++) {
      if (p.joinSlot(j) == slot) return j;
    }
    return -1;
  }

  /// §7.6 row 3: the movers in [oldRow], whose plan went, carry on in limbo:
  /// inbound drops its reservation and heads for an out-join, outbound
  /// carries on exactly as it was.
  void evacuate(int oldRow) {
    _ensure();
    if (!sites.isRowLive(oldRow)) return;
    final p = sites.plan[oldRow];
    if (p == null) return;
    for (var sl = 0; sl < table.highWater; sl++) {
      if (!table.isSlotLive(sl) || site.row[sl] != oldRow) continue;
      final ph = site.phase[sl];
      if (ph != SitePhase.inbound.index && ph != SitePhase.stallIn.index) {
        continue;
      }
      final out = _anyOutJoin(oldRow, p);
      if (out < 0) continue;
      final stall = site.claim[sl];
      if (stall >= 0) {
        sites.unreserve(oldRow, stall);
        site.claim[sl] = -1;
      }
      site.join[sl] = out;
      site.phase[sl] = SitePhase.toThroat.index;
      site.target[sl] = sites.joinTarget(oldRow, out);
      site.manU[sl] = 0;
      stats.siteRetargets++;
    }
  }

  /// The first join of [row] a car may leave by, or −1.
  int _anyOutJoin(int row, SiteAccessPlan p) {
    for (var j = 0; j < p.joinCount; j++) {
      if (sites.joinTarget(row, j) >= 0) return j;
    }
    return -1;
  }

  /// Carries the held road route of every car waiting inside a site across a
  /// lane graph rebuild by [rm], as `TripPlanner.remapWaiting` does. A route
  /// made impossible is reported to [spawns], and its car put back in a
  /// stall — or garaged, through [sink], when none is left. Returns the
  /// routes it could not carry.
  ///
  /// Cars held at a GATE are on the road with a live element, so the
  /// facade's own `_remapAll` carries them; nothing here touches them.
  int remapHeld(RouteRemapper rm, SpawnSink spawns, SiteSink sink) {
    _ensure();
    final from = rm.lineage.from;
    final data = table.arena.data;
    var lost = 0;
    for (var sl = 0; sl < table.highWater; sl++) {
      if (!table.isSlotLive(sl)) continue;
      final ph = site.phase[sl];
      if (ph != SitePhase.toThroat.index &&
          ph != SitePhase.throatWait.index &&
          ph != SitePhase.backOutWait.index &&
          ph != SitePhase.stallOut.index) {
        continue;
      }
      final off = table.routeOff[sl], len = table.routeLen[sl];
      if (len <= 0) continue;
      final lane0 = data[off];
      if (lane0 < 0 || lane0 >= from.laneCount) continue;
      final e0 = from.laneEdge[lane0];
      final st = rm.remap(data, off, len,
          s: _originT[sl] - from.edgeLaneS0[e0], destS: table.destS[sl]);
      if (st == RemapStatus.kept) {
        table.setRoute(sl, rm.route, rm.routeLength, destS: rm.stopS);
        _originT[sl] = rm.placeT;
        continue;
      }
      lost++;
      spawns.replanWaiting(table.owner[sl]);
      _backToStall(sl, sink);
    }
    return lost;
  }

  /// A departing car whose route died: back into its own stall if it still
  /// holds one, else the nearest free one, else garaged.
  void _backToStall(int sl, SiteSink sink) {
    final row = site.row[sl];
    var stall = site.claim[sl];
    if (stall < 0 && sites.isRowLive(row)) {
      stall = sites.firstFreeStall(row, site.join[sl]);
    }
    _unlink(sl);
    _releaseUnit(sl);
    _releaseFootprint(sl);
    if (sites.isRowLive(row) && sites.inside[row] > 0) sites.inside[row]--;
    sink.parkedInStall(table.handleOf(sl), row, stall);
    site.clear(sl);
    _unit[sl] = -1;
  }

  // ---- Claim units ---------------------------------------------------------

  bool _canClaim(int unit, int dir) =>
      sites.unitClaimH[unit] < 0 || sites.unitClaimDir[unit] == dir;

  void _claim(int unit, int dir, int sl) {
    if (sites.unitClaimH[unit] < 0) {
      sites.unitClaimH[unit] = table.handleOf(sl);
      sites.unitClaimDir[unit] = dir;
      sites.unitClaimers[unit] = 0;
    }
    sites.unitClaimers[unit]++;
    _unit[sl] = unit;
  }

  void _releaseUnit(int sl) {
    final unit = _unit[sl];
    if (unit < 0 || unit >= sites.unitClaimH.length) {
      _unit[sl] = -1;
      return;
    }
    if (sites.unitClaimers[unit] > 0) sites.unitClaimers[unit]--;
    if (sites.unitClaimers[unit] <= 0) {
      sites.unitClaimH[unit] = -1;
      sites.unitClaimDir[unit] = 0;
      sites.unitClaimers[unit] = 0;
    }
    _unit[sl] = -1;
  }

  /// The claim unit of the lane [stall] sits on, or −1.
  int _stallUnit(int row, SiteAccessPlan p, int stall) {
    final seg = p.stallSeg(stall);
    if (seg < 0) return -1;
    final el = sites.elemBase[row] + 2 * seg;
    if (el < 0 || el >= sites.elemUnit.length) return -1;
    return sites.elemUnit[el];
  }

  int _dirOf(int sl) {
    final ph = site.phase[sl];
    return ph == SitePhase.toThroat.index || ph == SitePhase.stallOut.index
        ? kUnitOut
        : kUnitIn;
  }

  // ---- Small things --------------------------------------------------------

  /// Whether the building lies LEFT of travel along [edge] at join [join]:
  /// read off `joinRight` and the edge's own direction, never a centroid.
  bool _leftOfTravel(SiteAccessPlan p, int join, LaneGraph lg, int edge) {
    if (join < 0 || join >= p.joinCount) return false;
    final right = p.joinRight(join);
    return !(lg.edgeForward[edge] == 1 ? right : !right);
  }

  /// The cap on a site lane: the throat of the join a car comes in or goes
  /// out by is taken at the gate's own speed (§7.8 item 3).
  double _speedCap(int row, int lane, int join) {
    final g = sites.lanes[row];
    if (g == null || join < 0 || join >= g.plan.joinCount) {
      return double.infinity;
    }
    return lane == g.inLane(join) || lane == g.outLane(join)
        ? AgentTuning.gateMaxMps
        : double.infinity;
  }

  static bool _onLane(int ph) =>
      ph == SitePhase.inbound.index ||
      ph == SitePhase.toThroat.index ||
      ph == SitePhase.stallIn.index ||
      ph == SitePhase.stallOut.index ||
      ph == SitePhase.throatWait.index;

  static bool _inside(int ph) =>
      _onLane(ph) ||
      ph == SitePhase.backOutWait.index ||
      ph == SitePhase.backOut.index ||
      ph == SitePhase.shift.index;

  // The leader search's answer, as the road mover keeps it.
  double _gap = double.infinity, _lv = 0, _room = double.infinity, _roomV = 0;

  void _lead(double g, double lv, double room) {
    if (g < _gap) {
      _gap = g;
      _lv = lv;
    }
    if (room < _room) {
      _room = room;
      _roomV = lv;
    }
  }

  void _push(int sl, int what) {
    if (_nHand >= _hand.length) return;
    _hand[_nHand] = sl;
    _handWhat[_nHand] = what;
    _nHand++;
  }

  // ---- The site element lists ----------------------------------------------

  void _link(int sl, int row, int lane) {
    final el = sites.elemBase[row] + lane;
    if (el < 0 || el >= sites.elemHead.length) return;
    final at = table.s[sl];
    var ahead = sites.elemTail[el];
    while (ahead >= 0 && table.s[ahead] < at) {
      ahead = site.sPrev[ahead];
    }
    site.sPrev[sl] = ahead;
    if (ahead >= 0) {
      final behind = site.sNext[ahead];
      site.sNext[sl] = behind;
      site.sNext[ahead] = sl;
      if (behind >= 0) {
        site.sPrev[behind] = sl;
      } else {
        sites.elemTail[el] = sl;
      }
    } else {
      final head = sites.elemHead[el];
      site.sNext[sl] = head;
      if (head >= 0) {
        site.sPrev[head] = sl;
      } else {
        sites.elemTail[el] = sl;
      }
      sites.elemHead[el] = sl;
    }
    sites.elemCount[el]++;
  }

  void _unlink(int sl) {
    final row = site.row[sl], lane = site.lane[sl];
    if (row < 0 || lane < 0 || !sites.isRowLive(row)) {
      site.sPrev[sl] = -1;
      site.sNext[sl] = -1;
      return;
    }
    final el = sites.elemBase[row] + lane;
    if (el < 0 || el >= sites.elemHead.length) {
      site.sPrev[sl] = -1;
      site.sNext[sl] = -1;
      return;
    }
    final p = site.sPrev[sl], n = site.sNext[sl];
    final linked = p >= 0 || n >= 0 || sites.elemHead[el] == sl;
    site.sPrev[sl] = -1;
    site.sNext[sl] = -1;
    if (!linked) return;
    if (p >= 0) {
      site.sNext[p] = n;
    } else {
      sites.elemHead[el] = n;
    }
    if (n >= 0) {
      site.sPrev[n] = p;
    } else {
      sites.elemTail[el] = p;
    }
    sites.elemCount[el]--;
  }

  // ---- Storage, buffers and the digest -------------------------------------

  void _ensure() {
    final n = table.capacity;
    site.ensure(n);
    events.ensure(n);
    if (_unit.length < n) {
      Int32List i32(Int32List a) => Int32List(n)
        ..fillRange(0, n, -1)
        ..setRange(0, a.length, a);
      _unit = i32(_unit);
      _g1Ms = Int32List(n)..setRange(0, _g1Ms.length, _g1Ms);
      _shuffleMs = Int32List(n)..setRange(0, _shuffleMs.length, _shuffleMs);
      _originT = Float32List(n)..setRange(0, _originT.length, _originT);
      _curveM = Float32List(n)..setRange(0, _curveM.length, _curveM);
      _hand = Int32List(n);
      _handWhat = Uint8List(n);
      // A far-direction back-out holds two claims, and a grow must not drop
      // one: a car mid-manoeuvre still owns its footprint.
      _clLane = Int32List(2 * n)..setRange(0, _clLane.length, _clLane);
      _clOwner = Int32List(2 * n)..setRange(0, _clOwner.length, _clOwner);
      _clFrom = Float32List(2 * n)..setRange(0, _clFrom.length, _clFrom);
      _clTo = Float32List(2 * n)..setRange(0, _clTo.length, _clTo);
    }
    final rows = sites.rows.capacity;
    if (_heldRow.length < rows) _heldRow = Int32List(rows);
  }

  /// Every buffer by name into [into], for the allocation test (A13).
  void collectBuffers(Map<String, Object> into, String name) {
    into['$name.unit'] = _unit;
    into['$name.g1Ms'] = _g1Ms;
    into['$name.shuffleMs'] = _shuffleMs;
    into['$name.originT'] = _originT;
    into['$name.curveM'] = _curveM;
    into['$name.hand'] = _hand;
    into['$name.handWhat'] = _handWhat;
    into['$name.heldRow'] = _heldRow;
    into['$name.clLane'] = _clLane;
    into['$name.clOwner'] = _clOwner;
    into['$name.clFrom'] = _clFrom;
    into['$name.clTo'] = _clTo;
  }

  /// [hash] with the mover's own state folded in — the gate and shuffle
  /// clocks, the claim unit each car holds, and where its road leg starts —
  /// in slot order, and only for cars that have site business, so a colony
  /// with no site traffic digests exactly as it did before T4a.
  int digest(int hash) {
    var h = hash;
    final hw = table.highWater;
    for (var sl = 0; sl < hw; sl++) {
      if (!table.isSlotLive(sl) || site.phase[sl] == 0) continue;
      h = fnv1aU32(h, table.handleOf(sl));
      h = fnv1aU32(h, _unit[sl]);
      h = fnv1aU32(h, _g1Ms[sl]);
      h = fnv1aU32(h, _shuffleMs[sl]);
      h = fnv1aU32(h, (_originT[sl] * 1000).round());
      h = fnv1aU32(h, (_curveM[sl] * 1000).round());
      // The claims this car holds, in the order it took them.
      for (var i = 0; i < _clCount; i++) {
        if (_clOwner[i] != sl) continue;
        h = fnv1aU32(h, _clLane[i]);
        h = fnv1aU32(h, (_clFrom[i] * 100).round());
        h = fnv1aU32(h, (_clTo[i] * 100).round());
      }
    }
    return h;
  }
}
