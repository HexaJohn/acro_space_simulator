// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What the agents measured, rolled up for everyone who reads them
/// (docs/plans/agent-traffic.md §4.2, §12.2 step 7, §12.3).
///
/// Two things leave here for the economy and the views.
///
/// COMMUTE EFFICIENCY, which staffing reads (E4): how much longer completed
/// commutes took than they would have on an empty network ([tripRatio]),
/// and what share of them never arrived ([failedShare]):
///
///     commuteEff = clamp(1 − 0.4·(0.5·(tripRatio − 1) + failedShare), 0.6, 1)
///
/// CONGESTION, measured from vehicle SPEEDS: the distance vehicles drove
/// against the distance the same vehicle-time covers at the limit. It needs
/// no delay table, so it ships in slice 1. Network-wide it is an EMA over a
/// minute ([congestionIndex]; the HUD's Flow is one minus it); per road it
/// is the worst piece over the last complete minute, and the volume the
/// vehicles through its busiest piece over the last ten. Those are taken as
/// a PICTURE at each congestion epoch (2 s of agent time) — the readout's
/// last complete picture (D47) — from the very first epoch, whether or not
/// anything has driven: an empty picture is no congestion and no routes, so
/// before the first car every answer still punishes nothing, and nothing
/// waits for one.
///
/// Everything here is rolled on agent time, in the sub-step, with no
/// allocation once a graph is bound.
library;

import 'dart:typed_data';

import '../road_graph.dart';
import 'lane_graph.dart';
import 'traffic_time.dart';
import 'traffic_tuning.dart';
import 'vehicle_mover.dart';

/// How many completed trips the trip-ratio average spans: the mean of the
/// trips so far until there are this many, an EMA over about this many
/// after. The design leaves the span open.
const double kTripRatioTrips = 40;

/// No one trip counts for more than this many times its free-flow time.
const double kTripRatioCap = 3;

/// The minute windows the failed share and the road volumes keep: ten, so
/// both look back over the last 600 s.
const int kWindowBuckets = 10;

/// commuteEff's floor and slope.
const double kCommuteEffFloor = 0.6;
const double kCommuteEffSlope = 0.4;

/// The least metres-at-the-limit a piece needs in its window before its
/// congestion is judged: a car that has only just turned in and stopped at
/// the line is not a jammed road.
const double kMinSampleM = 50;

/// The agents' measurements. See the library comment.
class TrafficStats {
  // ---- Counters ---------------------------------------------------------------

  /// Vehicles put on the road, and trips that reached their stop — of
  /// those, how many found the building gone (§4.7).
  int spawned = 0, arrived = 0, arrivedGone = 0;

  /// Vehicles taken off the road: stuck (§5.6), the longest waiter at a
  /// wedged node (§5.8), or a network edit that took their road (§3.9).
  int despawnStuck = 0, despawnWedge = 0, despawnEdit = 0;

  /// Routes a network edit made impossible, planned again from where the
  /// vehicle was (§4.7), and legs appended after an arrival (a re-target
  /// from a building gone, §4.6; or from a stop its building's access has
  /// moved away from, D36's `siteRetarget`).
  int replans = 0, appendedLegs = 0;

  /// Routes the remaps carried across an edit with some lanes chosen again.
  int lanesRepaired = 0;

  /// Vehicles a rebuild placed onto the one ahead of them and moved back to
  /// clear it (`CityAgents`' remap). The carry through a new junction's box
  /// should leave none: each is a place the remap could not keep.
  int remapNudges = 0;

  /// Trips deferred by a cap (D10), and trips dropped because nothing joins
  /// their ends.
  int deferred = 0, noRoute = 0;

  // ---- Commutes -------------------------------------------------------------------

  /// Actual over free-flow time of completed commutes, averaged; 1 before
  /// the first.
  double tripRatio = 1;

  /// Seconds a completed trip took, averaged the same way.
  double avgTripS = 0;

  /// Commute legs completed since the colony started.
  int tripsDone = 0;

  final Int32List _doneIn = Int32List(kWindowBuckets);
  final Int32List _failedIn = Int32List(kWindowBuckets);
  int _bucket = 0;

  /// A commute leg arrived after [actualS] seconds, against [freeFlowS] on
  /// an empty network.
  void tripDone(double actualS, double freeFlowS) {
    var r = freeFlowS > 0 ? actualS / freeFlowS : 1.0;
    if (r > kTripRatioCap) r = kTripRatioCap;
    final n = tripsDone + 1.0;
    final alpha = n < kTripRatioTrips ? 1.0 / n : 1.0 / kTripRatioTrips;
    tripRatio += alpha * (r - tripRatio);
    avgTripS += alpha * (actualS - avgTripS);
    tripsDone++;
    _doneIn[_bucket]++;
  }

  /// A commute leg never arrived: its vehicle was taken off the road.
  void tripFailed() => _failedIn[_bucket]++;

  /// The despawned share of commute legs over the last 600 s; 0 with none.
  double get failedShare {
    var done = 0, failed = 0;
    for (var i = 0; i < kWindowBuckets; i++) {
      done += _doneIn[i];
      failed += _failedIn[i];
    }
    final all = done + failed;
    return all == 0 ? 0.0 : failed / all;
  }

  /// What staffing reads (E4): 1 on an empty network, down to 0.6.
  double get commuteEff {
    final e = 1 -
        kCommuteEffSlope * (0.5 * (tripRatio - 1) + failedShare);
    return e < kCommuteEffFloor ? kCommuteEffFloor : (e > 1 ? 1.0 : e);
  }

  // ---- Congestion ---------------------------------------------------------------

  /// Whether a picture has been taken: the first congestion epoch has
  /// passed, cars or no cars.
  bool hasRun = false;

  /// Pictures taken. Moves with every one, never goes back.
  int pictures = 0;

  /// 1 − driven/at-the-limit, an EMA over `congestionWindowS`: live, moved
  /// at every epoch.
  double congestionIndex = 0;
  double _emaDriven = 0, _emaLimit = 0;

  LaneGraph? _lg;

  /// Per edge: metres driven and metres at the limit this window and in the
  /// last complete one; vehicles through, per minute bucket.
  Float32List _winD = Float32List(0), _winL = Float32List(0);
  Float32List _lastD = Float32List(0), _lastL = Float32List(0);
  Int32List _exits = Int32List(0);

  // ---- The picture ----------------------------------------------------------------

  RoadGraph? _picGraph;
  Float32List _roadCong = Float32List(0), _roadVol = Float32List(0);

  /// The worst road's congestion in the last picture, and the network's.
  double peakCongestion = 0, averageCongestion = 0;

  /// Every buffer the statistics keep from one sub-step to the next, by
  /// name into [into], for the allocation test (§15.2): the per-edge books
  /// are sized by the graph they are bound to, the picture's by its road
  /// graph, and none is replaced while those run. The window's books and
  /// the last window's change places at every window's end, so the two
  /// names swap buffers: the same pair, never a new one.
  void collectBuffers(Map<String, Object> into, String name) {
    into['$name.doneIn'] = _doneIn;
    into['$name.failedIn'] = _failedIn;
    into['$name.winD'] = _winD;
    into['$name.winL'] = _winL;
    into['$name.lastD'] = _lastD;
    into['$name.lastL'] = _lastL;
    into['$name.exits'] = _exits;
    into['$name.roadCong'] = _roadCong;
    into['$name.roadVol'] = _roadVol;
  }

  /// Puts the per-edge books on [lg]. A graph sharing [lg]'s structure keeps
  /// them; any other starts them afresh — edge ids mean nothing across two
  /// builds — and the network index carries on.
  void bind(LaneGraph lg) {
    final old = _lg;
    _lg = lg;
    if (old != null && lg.sharesStructureWith(old)) return;
    final nE = lg.edgeCount;
    _winD = Float32List(nE);
    _winL = Float32List(nE);
    _lastD = Float32List(nE);
    _lastL = Float32List(nE);
    _exits = Int32List(nE * kWindowBuckets);
  }

  /// One congestion epoch: [mover]'s books since the last one go into the
  /// index and the windows, and are cleared; at [windowEnd] the minute
  /// closes; and the picture is taken.
  void epoch(VehicleMover mover, {required bool windowEnd}) {
    final lg = _lg;
    if (lg == null) return;
    final alpha = 1 -
        Lut.expNeg(AgentTuning.congestionEpochS / AgentTuning.congestionWindowS);
    _emaDriven += alpha * (mover.drivenM - _emaDriven);
    _emaLimit += alpha * (mover.limitM - _emaLimit);
    congestionIndex =
        _emaLimit > 1e-9 ? _clamp01(1 - _emaDriven / _emaLimit) : 0.0;
    final d = mover.edgeDrivenM, l = mover.edgeLimitM, x = mover.edgeExits;
    var nE = lg.edgeCount;
    if (d.length < nE) nE = d.length;
    if (_winD.length < nE) nE = _winD.length;
    final b = _bucket;
    for (var e = 0; e < nE; e++) {
      _winD[e] += d[e];
      _winL[e] += l[e];
      _exits[e * kWindowBuckets + b] += x[e];
    }
    mover.clearBooks();
    if (windowEnd) _closeWindow();
    // A picture at every epoch from the first, whether or not anything has
    // driven: a network nothing drives on is a picture too, of no
    // congestion and no routes. Waiting for the first car left a colony with
    // no commuters — the starter kit before anything is zoned — "still being
    // counted" for good in the Routes view.
    hasRun = true;
    _picture(lg);
  }

  /// The minute closes: its books become the last complete window's, and
  /// the oldest minute of the ten falls out.
  void _closeWindow() {
    final d = _lastD, l = _lastL;
    _lastD = _winD;
    _lastL = _winL;
    _winD = d..fillRange(0, d.length, 0);
    _winL = l..fillRange(0, l.length, 0);
    _bucket = (_bucket + 1) % kWindowBuckets;
    final b = _bucket;
    for (var i = b; i < _exits.length; i += kWindowBuckets) {
      _exits[i] = 0;
    }
    _doneIn[b] = 0;
    _failedIn[b] = 0;
  }

  int _through(int e) {
    var n = 0;
    final base = e * kWindowBuckets;
    for (var i = 0; i < kWindowBuckets; i++) {
      n += _exits[base + i];
    }
    return n;
  }

  void _picture(LaneGraph lg) {
    final g = lg.graph;
    final nR = g.roadCount;
    if (_roadCong.length != nR) {
      _roadCong = Float32List(nR);
      _roadVol = Float32List(nR);
    }
    final nE = _lastD.length;
    var peak = 0.0;
    for (var r = 0; r < nR; r++) {
      var worst = 0.0;
      var busiest = 0;
      for (var p = g.roadFirstPiece[r]; p < g.roadFirstPiece[r + 1]; p++) {
        var dd = 0.0, ll = 0.0;
        var n = 0;
        final f = g.pieceFwdEdge[p], bk = g.pieceBwdEdge[p];
        if (f >= 0 && f < nE) {
          dd += _lastD[f];
          ll += _lastL[f];
          n += _through(f);
        }
        if (bk >= 0 && bk < nE) {
          dd += _lastD[bk];
          ll += _lastL[bk];
          n += _through(bk);
        }
        final c = ll > kMinSampleM ? _clamp01(1 - dd / ll) : 0.0;
        if (c > worst) worst = c;
        if (n > busiest) busiest = n;
      }
      _roadCong[r] = worst;
      _roadVol[r] = busiest.toDouble();
      // Read back as stored, so the peak IS the worst road's answer.
      final stored = _roadCong[r];
      if (stored > peak) peak = stored;
    }
    _picGraph = g;
    peakCongestion = peak;
    averageCongestion = congestionIndex;
    pictures++;
  }

  /// The last picture's congestion of [roadId]'s worst piece; 0 for a road
  /// it does not know.
  double congestionOf(String roadId) {
    final r = _picGraph?.roadNoOf(roadId);
    return r == null || r >= _roadCong.length ? 0.0 : _roadCong[r];
  }

  /// The last picture's vehicles through [roadId]'s busiest piece over the
  /// last 600 s; 0 for a road it does not know.
  double volumeOf(String roadId) {
    final r = _picGraph?.roadNoOf(roadId);
    return r == null || r >= _roadVol.length ? 0.0 : _roadVol[r];
  }

  static double _clamp01(double x) => x < 0 ? 0.0 : (x > 1 ? 1.0 : x);
}
