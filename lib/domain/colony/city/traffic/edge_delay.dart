// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What congestion a new trip is priced by: the measured delay of every
/// directed edge, published every congestion epoch, and the lane speeds the
/// traffic view colours by (docs/plans/agent-traffic.md §4.2, D11, §13.9).
///
/// The user's decision 1 (§0.2): congestion is read AT SPAWN, the way CS2
/// reads it. A new trip's search prices every edge at its free-flow time
/// plus the delay this table last published (§4.1's `D`), and the route and
/// its lanes are then locked (§4.6): nothing here ever re-plans a trip
/// already on the road. So "measured at plan time" means measured at most
/// one epoch (2 s) before the search began.
///
/// THE OBSERVATION. A vehicle that drove an edge from the start of its lane
/// reports, as it leaves the connector at the edge's end, how much longer
/// the edge and the connector took it than they would have on an empty
/// network — by ITS OWN desired speed, so a slow driver is not congestion —
/// less the control delay the route already pays at that node (§4.1's `J`):
///
///     obs = (t_lane + t_con) − free − Jexp
///     free = laneLen / (limit · f) + conLen / min(limit · f, conVmax)
///
/// A vehicle ending its trip on the edge reports its lane time up to its
/// stop, with no connector and no `J`. The observation is SIGNED: through
/// on green is quicker than the expected light, and reads below zero; a red
/// reads above. Their mean is the delay beyond the expected control delay,
/// so an empty network publishes `D ≈ 0`, signals included (D11), and no
/// light is charged twice. The mover books the observations as they happen
/// (`VehicleMover.observationCount`); [absorb] takes them in every sub-step
/// (§5.2 step 6).
///
/// THE EMA. `ema += α·(obs − ema)`, one observation at a time, with
/// `α = 1 − e^(−1/nEff)` read from a table and `nEff` the edge's departures
/// in the last complete 60 s window, clamped to 8–40: a busy edge averages
/// over more observations, a quiet one over fewer, and either forgets in
/// about a minute. An edge nobody left in a whole window has its EMA halved,
/// so a jam that has cleared stops deterring trips.
///
/// THE LIVE QUEUE. A jam nobody leaves reports nothing, so the EMA alone
/// would never see it. At every publish the vehicles standing (below
/// 1 m/s) on each edge's lanes are counted, and the queue beyond the first
/// in each lane — that one is the red wait `J` already prices — is charged
/// 2 s a vehicle, shared across the lanes. The published delay is the worse
/// of the two, clamped to [0, 600] s.
///
/// THE POOL. Every publish writes a buffer from a pool of three and never
/// the one it published last, nor one a suspended search still prices by
/// ([DelayHolders]): a search that spans sub-steps prices every edge from one
/// consistent picture, and a published picture is never written while
/// anyone reads it. When all three are held, the publish is skipped and the
/// last picture stands.
///
/// LANE SPEEDS. Per lane, a 60 s EMA of the mean `v / limit` of the vehicles
/// on it, sampled every sub-step by the mover and folded in every epoch,
/// quantised to 0–100 into a buffer of its own rotating pool of three: what
/// the Lane speed view colours its ribbons by (§13.9). An epoch with no
/// vehicle on a lane samples it free, so a cleared lane turns green again.
///
/// Bound like `TrafficStats`: a graph sharing the bound graph's structure (a
/// junction override, a light switched on) keeps every measurement — edge
/// ids stand — and re-reads only the control delay; any other starts afresh,
/// with nothing published until its first epoch.
///
/// Nothing here allocates once a graph is bound (§15.2): the books are
/// typed columns sized by the graph, the pools are rotated, not replaced.
library;

import 'dart:typed_data';

import 'lane_graph.dart';
import 'node_control.dart';
import 'route_cost.dart';
import 'traffic_rng.dart';
import 'traffic_time.dart';
import 'traffic_tuning.dart';
import 'vehicle_mover.dart';
import 'vehicle_table.dart';

/// No edge's published delay is more than this (§4.2): a wedge that will
/// never clear is ten minutes dear, not infinitely so.
const double kMaxDelayS = 600;

/// What each vehicle standing in a queue beyond the first of its lane
/// charges the edge (§4.2's live queue).
const double kQueueVehicleS = 2.0;

/// Below this speed a vehicle on a lane is standing in its queue.
const double kQueueStoppedMps = 1.0;

/// The departures a minute the EMA's weight is clamped between (§4.2).
const int kMinEffectiveFlow = 8;
const int kMaxEffectiveFlow = 40;

/// Buffers in each published pool: the one published, one a suspended
/// search may still hold, and one to write.
const int kDelayPoolSize = 3;

/// Who may still be reading a published delay buffer: the path queue's
/// suspended searches (`PathQueue`).
abstract interface class DelayHolders {
  /// Whether a search not yet finished prices by [delays].
  bool holdsDelays(Float32List delays);
}

/// The measured delay of every directed edge. See the library comment.
class EdgeDelayTable {
  EdgeDelayTable({this.holders});

  /// Asked before a buffer is written: a buffer one of them holds is not.
  DelayHolders? holders;

  LaneGraph? _lg;

  /// Per edge: the signed EMA of the observations, seconds.
  Float64List _ema = Float64List(0);

  /// Per edge: departures in the window running now, and in the last
  /// complete one (`flowPerMin`).
  Uint16List _flowNow = Uint16List(0), _flowLast = Uint16List(0);

  /// Per edge: the control delay its node is expected to cost — §4.1's `J`,
  /// read off the bound graph's controls.
  Float32List _jExp = Float32List(0);

  /// Per edge, a publish's scratch: vehicles standing on its lanes.
  Int32List _stopped = Int32List(0);

  /// The published delay buffers, and which was published last (−1: none).
  final List<Float32List> _pool =
      List<Float32List>.filled(kDelayPoolSize, Float32List(0));
  int _current = -1;

  /// Pinned delays (§17's `freezeDelays` and `setDelay`): while [frozen],
  /// what every publish carries instead of what was measured.
  Float32List _pinned = Float32List(0);
  bool _frozen = false;

  /// Per lane: the EMA of `v / limit`, and the published percentages.
  Float64List _laneEma = Float64List(0);
  final List<Uint8List> _speedPool =
      List<Uint8List>.filled(kDelayPoolSize, Uint8List(0));
  int _speedCurrent = -1;

  /// Delay buffers published, and publishes skipped because every buffer
  /// was held.
  int publishes = 0;
  int skippedPublishes = 0;

  /// Moves with every lane-speed publish, and when a rebuild drops the
  /// last one: a view keyed on it redraws whenever [laneSpeedPct] may have
  /// changed.
  int laneSpeedRev = 0;

  /// α of the EMA by effective departures a minute (§4.2), from the e^-x
  /// table (D27): index n holds `1 − e^(−1/n)` for n in 8–40.
  static final Float64List _alphaByFlow = _buildAlpha();

  static Float64List _buildAlpha() {
    final t = Float64List(kMaxEffectiveFlow + 1);
    for (var n = 0; n <= kMaxEffectiveFlow; n++) {
      final k = n < kMinEffectiveFlow ? kMinEffectiveFlow : n;
      t[n] = 1 - Lut.expNeg(1 / k);
    }
    return t;
  }

  /// The EMA weight of one observation on an edge that saw [flowPerMin]
  /// departures in its last complete window.
  static double alphaFor(int flowPerMin) =>
      _alphaByFlow[flowPerMin > kMaxEffectiveFlow
          ? kMaxEffectiveFlow
          : (flowPerMin < 0 ? 0 : flowPerMin)];

  // ---- What the planners and the views read -----------------------------------

  /// The last published delay buffer, seconds per edge id; null before the
  /// first publish on the bound graph. Never written while it is the last
  /// published, nor while a search holds it.
  Float32List? get published => _current < 0 ? null : _pool[_current];

  /// The last published lane speeds, 0–100 per lane id; null before the
  /// first epoch on the bound graph. The pool rotates, so a buffer is
  /// rewritten three publishes (6 s) after it was published: read one when
  /// [laneSpeedRev] moves, and do not keep it longer than that.
  Uint8List? get laneSpeedPct =>
      _speedCurrent < 0 ? null : _speedPool[_speedCurrent];

  /// The graph the tables are bound to.
  LaneGraph? get graph => _lg;

  /// Whether publishes carry pinned delays rather than measured ones.
  bool get frozen => _frozen;

  /// [edge]'s EMA of its observations, signed seconds.
  double emaOf(int edge) => _ema[edge];

  /// [edge]'s departures in the last complete window: `flowPerMin`.
  int flowPerMin(int edge) => _flowLast[edge];

  /// [edge]'s departures so far in the window running now.
  int flowThisWindow(int edge) => _flowNow[edge];

  /// The control delay an observation on [edge] is measured against: §4.1's
  /// `J` at the node it ends at, and none where the road ends (a turning
  /// place's `J` prices the U-turn, and turning round keeps nobody waiting).
  double expectedControlDelayOf(int edge) => _jExp[edge];

  /// Puts the tables on [lg]. A graph sharing the bound graph's structure
  /// keeps every measurement and every published buffer — edge and lane ids
  /// stand — and re-reads only the controls; any other starts afresh, with
  /// nothing published.
  void bind(LaneGraph lg) {
    final old = _lg;
    _lg = lg;
    if (old == null || !lg.sharesStructureWith(old)) {
      final nE = lg.edgeCount, nL = lg.laneCount;
      _ema = Float64List(nE);
      _flowNow = Uint16List(nE);
      _flowLast = Uint16List(nE);
      _jExp = Float32List(nE);
      _stopped = Int32List(nE);
      _pinned = Float32List(nE);
      for (var k = 0; k < kDelayPoolSize; k++) {
        _pool[k] = Float32List(nE);
        _speedPool[k] = Uint8List(nL);
      }
      _laneEma = Float64List(nL)..fillRange(0, nL, 1.0);
      _current = -1;
      if (_speedCurrent >= 0) laneSpeedRev++;
      _speedCurrent = -1;
    }
    final ctl = lg.controls;
    for (var e = 0; e < lg.edgeCount; e++) {
      final kind = lg.kindOf(lg.edgeTo[e]);
      final road = e < ctl.edgeStops.length;
      _jExp[e] = isTurningPlace(kind)
          ? 0.0
          : junctionPenaltyS(kind,
              stops: road && ctl.edgeStops[e] == 1,
              yields: road && ctl.edgeYields[e] == 1);
    }
  }

  // ---- The sub-step (§5.2 step 6) ---------------------------------------------

  /// Takes in, in the order they happened, the observations [mover] booked
  /// this sub-step, and clears its log.
  void absorb(VehicleMover mover) {
    final n = mover.observationCount;
    mover.observationCount = 0;
    if (_lg == null) return;
    final edges = mover.obsEdge, secs = mover.obsS, atNode = mover.obsAtNode;
    final nE = _ema.length;
    for (var i = 0; i < n; i++) {
      final e = edges[i];
      if (e < 0 || e >= nE) continue;
      final obs = atNode[i] == 1 ? secs[i] - _jExp[e] : secs[i];
      _ema[e] += alphaFor(_flowLast[e]) * (obs - _ema[e]);
    }
  }

  /// One congestion epoch: [mover]'s departures since the last join the
  /// window — closed at [windowEnd] — its lane-speed samples join the lane
  /// EMAs, and a fresh delay buffer is published from the EMAs and the
  /// queues standing on [table]'s lanes now. True when a buffer was
  /// published; false when every buffer was held, and the last stands.
  bool epoch(VehicleMover mover, VehicleTable table,
      {required bool windowEnd}) {
    final lg = _lg;
    if (lg == null) return false;
    final dep = mover.edgeDeparts;
    var nE = _flowNow.length;
    if (dep.length < nE) nE = dep.length;
    for (var e = 0; e < nE; e++) {
      final v = _flowNow[e] + dep[e];
      _flowNow[e] = v > 0xFFFF ? 0xFFFF : v;
    }
    mover.clearDepartures();
    if (windowEnd) _closeWindow();
    _foldLaneSpeeds(mover);
    return _publish(table);
  }

  /// Publishes now, outside the epoch: what a test that pins a delay reads
  /// at once. False when every buffer was held.
  bool publishNow(VehicleTable table) => _publish(table);

  // ---- Pinning (§17's `freezeDelays`, `setDelay`) --------------------------------

  /// From the next publish, every edge's delay is pinned: 0, unless
  /// [setDelay] says otherwise. Measuring goes on underneath.
  void freeze() {
    _frozen = true;
    _pinned.fillRange(0, _pinned.length, 0);
  }

  /// Pins [edge]'s delay at [seconds] (clamped to [0, 600]), freezing the
  /// table if it was not.
  void setDelay(int edge, double seconds) {
    if (!_frozen) freeze();
    _pinned[edge] =
        seconds < 0 ? 0.0 : (seconds > kMaxDelayS ? kMaxDelayS : seconds);
  }

  /// Back to publishing what was measured.
  void thaw() => _frozen = false;

  // ---- Inside ----------------------------------------------------------------------

  /// The minute closes: its departures become `flowPerMin`, and an edge
  /// nobody left in it has its EMA halved.
  void _closeWindow() {
    for (var e = 0; e < _flowNow.length; e++) {
      final n = _flowNow[e];
      if (n == 0) _ema[e] *= 0.5;
      _flowLast[e] = n;
      _flowNow[e] = 0;
    }
  }

  void _foldLaneSpeeds(VehicleMover mover) {
    final sum = mover.laneVSum, cnt = mover.laneSamples;
    var nL = _laneEma.length;
    if (sum.length < nL) nL = sum.length;
    final next = (_speedCurrent + 1) % kDelayPoolSize;
    final out = _speedPool[next];
    final alpha = 1 -
        Lut.expNeg(
            AgentTuning.congestionEpochS / AgentTuning.congestionWindowS);
    for (var l = 0; l < nL; l++) {
      final n = cnt[l];
      var x = n > 0 ? sum[l] / n : 1.0;
      if (x > 1) x = 1.0;
      if (x < 0) x = 0.0;
      final ema = _laneEma[l] + alpha * (x - _laneEma[l]);
      _laneEma[l] = ema;
      final pct = (ema * 100).round();
      out[l] = pct < 0 ? 0 : (pct > 100 ? 100 : pct);
    }
    mover.clearLaneBooks();
    _speedCurrent = next;
    laneSpeedRev++;
  }

  bool _publish(VehicleTable table) {
    final lg = _lg;
    if (lg == null) return false;
    var into = -1;
    for (var k = 0; k < kDelayPoolSize; k++) {
      if (k == _current) continue;
      final h = holders;
      if (h != null && h.holdsDelays(_pool[k])) continue;
      into = k;
      break;
    }
    if (into < 0) {
      skippedPublishes++;
      return false;
    }
    final out = _pool[into];
    final nE = out.length;
    if (_frozen) {
      out.setRange(0, nE, _pinned);
    } else {
      _countQueues(lg, table);
      for (var e = 0; e < nE; e++) {
        final lanes = lg.edgeLaneCount[e];
        final beyond = _stopped[e] - lanes;
        final q = beyond > 0 ? beyond * kQueueVehicleS / lanes : 0.0;
        var d = _ema[e] > q ? _ema[e] : q;
        if (d < 0) d = 0.0;
        if (d > kMaxDelayS) d = kMaxDelayS;
        out[e] = d;
      }
    }
    _current = into;
    publishes++;
    return true;
  }

  /// The vehicles standing on each edge's lanes, from [table]'s lists: once
  /// a publish, which is when the live queue is read (§4.2 recomputes it
  /// every sub-step; only the published value is ever priced).
  void _countQueues(LaneGraph lg, VehicleTable table) {
    _stopped.fillRange(0, _stopped.length, 0);
    var nL = lg.laneCount;
    if (table.elemHead.length < nL) nL = table.elemHead.length;
    final head = table.elemHead, next = table.next, v = table.v;
    for (var l = 0; l < nL; l++) {
      var n = 0;
      for (var sl = head[l]; sl >= 0; sl = next[sl]) {
        if (v[sl] < kQueueStoppedMps) n++;
      }
      if (n > 0) _stopped[lg.laneEdge[l]] += n;
    }
  }

  // ---- Tests and determinism ----------------------------------------------------------

  /// Every buffer the table keeps from one sub-step to the next, by name
  /// into [into], for the allocation test (§15.2): sized by the bound graph,
  /// and — the pools rotating among their own three — none replaced while
  /// it runs.
  void collectBuffers(Map<String, Object> into, String name) {
    into['$name.ema'] = _ema;
    into['$name.flowNow'] = _flowNow;
    into['$name.flowLast'] = _flowLast;
    into['$name.jExp'] = _jExp;
    into['$name.stopped'] = _stopped;
    into['$name.pinned'] = _pinned;
    into['$name.laneEma'] = _laneEma;
    for (var k = 0; k < kDelayPoolSize; k++) {
      into['$name.pool$k'] = _pool[k];
      into['$name.speedPool$k'] = _speedPool[k];
    }
  }

  /// [hash] with everything a later plan depends on folded in — each EMA to
  /// the millisecond, the flow windows, what was published and which buffer
  /// holds it, the lane EMAs to a ten-thousandth — for `CityAgents.digest`.
  int digest(int hash) {
    var h = fnv1aU32(hash, (_current + 1) | (_speedCurrent + 1) << 4);
    h = fnv1aU32(h, publishes);
    h = fnv1aU32(h, skippedPublishes);
    h = fnv1aU32(h, _frozen ? 1 : 0);
    for (var e = 0; e < _ema.length; e++) {
      h = fnv1aU32(h, (_ema[e] * 1000).round());
      h = fnv1aU32(h, _flowNow[e] | _flowLast[e] << 16);
    }
    final pub = published;
    if (pub != null) {
      for (var e = 0; e < pub.length; e++) {
        h = fnv1aU32(h, (pub[e] * 1000).round());
      }
    }
    for (var l = 0; l < _laneEma.length; l++) {
      h = fnv1aU32(h, (_laneEma[l] * 10000).round());
    }
    return h;
  }
}
