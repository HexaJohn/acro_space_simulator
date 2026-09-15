// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Traffic noise at the lots, and what the land beside a road is worth.
///
/// A road's menu entry says how loud it is ([RoadType.noise], after its
/// decoration and sound barriers: [RoadType.noiseEmission]); how busy it is
/// says how much of that it actually makes. Noise carries a block's depth
/// past the kerb and fades to nothing by [RoadNoise.reachM], and a stretch
/// in a tunnel throws none at all — which is half of what a tunnel is FOR.
/// Land value is what is left of a quiet, dressed street after the noise
/// and the colony's air are taken off it: the thing that makes trees along
/// a road worth their price.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'parcel.dart';
import 'road_catalog.dart';
import 'road_graph.dart';
import 'spatial_index.dart';

/// The rules. Pure arithmetic.
class RoadNoise {
  const RoadNoise._();

  /// How far past the kerb traffic noise carries: about a block's depth.
  static const double reachM = 60;

  /// Land value of a lot on a quiet, plain street in clean air, 0..1.
  static const double baseLandValue = 0.5;

  /// How much a lot's noise (0..1) takes off its land value.
  static const double noiseWeight = 0.5;

  /// The most the colony's air can take off land value, and the pollution
  /// at which it does — the level the sim starts raising air alarms at.
  static const double pollutionWeight = 0.25;
  static const double pollutionFullAt = 60;

  /// How much of its rated noise a road makes at [congestion]: an empty
  /// road still hums, a jammed one is louder than its rating.
  static double volumeFactor(double congestion) =>
      0.4 + 0.8 * congestion.clamp(0.0, 1.0);

  /// Noise a road of [type] throws at its kerb at [congestion].
  static double emission(RoadType type, {double congestion = 0}) =>
      type.noiseEmission * volumeFactor(congestion);

  /// The share of a road's noise that reaches a point [kerbM] past its
  /// kerb: all of it at the kerb, none from [reachM] on.
  static double falloff(double kerbM) {
    if (kerbM >= reachM) return 0;
    final f = 1 - math.max(0.0, kerbM) / reachM;
    return f * f;
  }

  /// What the road a lot fronts adds to it: grass or trees along the kerb,
  /// or the parking an undecorated street keeps.
  static double frontageBonus(RoadSpline road) =>
      frontageBonusOf(RoadType.of(road), road.decoration);

  /// [frontageBonus] for a road of menu entry [type] dressed with
  /// [decoration] — for a caller that has already looked the type up
  /// (`RoadType.of` is a scan of the menu, and the road graph looks every
  /// road up once for its speed anyway).
  static double frontageBonusOf(RoadType type, RoadDecoration decoration) {
    final deco = switch (decoration) {
      RoadDecoration.none => 0.0,
      RoadDecoration.grass => 0.05,
      RoadDecoration.trees => 0.1,
    };
    return deco + (type.hasParking ? 0.03 : 0.0);
  }

  /// What the colony's air takes off every lot's value.
  static double pollutionPenalty(double pollution) =>
      pollutionWeight * (pollution / pollutionFullAt).clamp(0.0, 1.0);

  /// Land value, 0..1: the base, plus the frontage [bonus], less the
  /// lot's [noise] and the colony's [pollution].
  static double landValue({
    required double noise,
    double bonus = 0,
    double pollution = 0,
  }) =>
      (baseLandValue +
              bonus -
              noiseWeight * noise -
              pollutionPenalty(pollution))
          .clamp(0.0, 1.0);

  /// The multiplier a colony's average land value puts on its tax take:
  /// 1 at [baseLandValue], clamped to 0.85..1.15 so the land can sweeten
  /// or sour the budget but never make or break it.
  static double taxFactor(double averageLandValue) =>
      (0.7 + 0.6 * averageLandValue).clamp(0.85, 1.15);
}

/// The noise a graph's roads throw at a point.
///
/// One per noise pass: it holds per-road scratch sized to the road index,
/// so sampling a lot allocates nothing. Walks the layout's road index the
/// graph was built from, so a lot costs the roads around it; a road the
/// index holds that the graph does not know (rail, or laid since the
/// build) is skipped.
class RoadNoiseSampler {
  RoadNoiseSampler(this.graph)
      : _stamp = Int32List(graph.slotToRoad.length),
        _bestD = Float64List(graph.slotToRoad.length),
        _bestSeg = Int32List(graph.slotToRoad.length),
        _bestU = Float64List(graph.slotToRoad.length),
        _touched = Int32List(graph.slotToRoad.length) {
    _visitor = _measure;
  }

  final RoadGraph graph;
  final Int32List _stamp;
  final Float64List _bestD;
  final Int32List _bestSeg;
  final Float64List _bestU;

  /// The slots measured this sample, `[0, _touchedCount)`: each at most once.
  final Int32List _touched;
  int _touchedCount = 0;
  int _epoch = 0;

  /// [_measure], torn off once, so a sample passes the index no new closure.
  late final void Function(int slot, IndexedRoad rec, int seg) _visitor;

  /// The point being sampled, read by [_measure].
  double _qe = 0, _qn = 0;

  /// Work so far, in the unit the traffic model budgets its noise pass in:
  /// an index cell looked in (a map probe whether or not a road is there),
  /// a road segment measured, a nearby road weighed. Counting the segments
  /// alone made a noise step several times slower than a routing step of
  /// the same budget: a lot's probe looks in thirty-odd cells to measure a
  /// couple of dozen segments.
  int work = 0;

  /// Noise at [p], 0..1: every road within [RoadNoise.reachM] of its kerb,
  /// each at its piece's [pieceEmission] (see [RoadNoise.emission]) faded
  /// by distance, nothing from a stretch in a tunnel, summed.
  double noiseAt(Vec2 p, Float64List pieceEmission) =>
      noiseAtEN(p.e, p.n, pieceEmission);

  /// [noiseAt] at `(e, n)`, allocating nothing: the index is walked by
  /// bounds with a visitor torn off once, the touched roads are typed
  /// scratch, and every loop is indexed. Bit-identical to [noiseAt].
  double noiseAtEN(double e, double n, Float64List pieceEmission) {
    final g = graph;
    _epoch++;
    if (_epoch == 0x3fffffff) {
      _stamp.fillRange(0, _stamp.length, 0);
      _epoch = 1;
    }
    _touchedCount = 0;
    _qe = e;
    _qn = n;
    final reach = RoadNoise.reachM + RoadGraph.maxHalfWidth;
    final minE = e - reach, maxE = e + reach;
    final minN = n - reach, maxN = n + reach;
    final cellM = g.index.cellM;
    work += ((maxE / cellM).floor() - (minE / cellM).floor() + 1) *
        ((maxN / cellM).floor() - (minN / cellM).floor() + 1);
    g.index.visitBounds(minE, minN, maxE, maxN, _visitor);
    var total = 0.0;
    work += 4 * _touchedCount;
    for (var k = 0; k < _touchedCount; k++) {
      final slot = _touched[k];
      final r = g.slotToRoad[slot];
      final road = g.roads[r];
      final kerb = _bestD[slot] - road.halfWidth;
      final f = RoadNoise.falloff(kerb);
      if (f <= 0) continue;
      final s = g.roadRecs[r].arcAt(_bestSeg[slot], _bestU[slot]);
      final deck = road.deck;
      if (deck != null && deck.inTunnelAt(s)) continue;
      total += pieceEmission[g.pieceAt(r, s)] * f;
    }
    return total <= 0 ? 0.0 : (total >= 1 ? 1.0 : total);
  }

  /// One (road, segment) near the point: keeps each road's nearest segment.
  void _measure(int slot, IndexedRoad rec, int seg) {
    work++;
    final g = graph;
    if (seg == 0 || slot >= g.slotToRoad.length) return;
    final r = g.slotToRoad[slot];
    // Same samples as at the build: an attribute swap keeps them, a
    // re-laid road does not.
    if (r < 0 || !identical(rec.e, g.roadRecs[r].e)) return;
    final pe = _qe, pn = _qn;
    final ae = rec.e[seg - 1], an = rec.n[seg - 1];
    final ex = rec.e[seg] - ae, en = rec.n[seg] - an;
    final len2 = ex * ex + en * en;
    var u = 0.0;
    if (len2 > 1e-12) {
      u = ((pe - ae) * ex + (pn - an) * en) / len2;
      // As num.clamp(0.0, 1.0): -0.0 compares below 0.0 and becomes 0.0.
      u = u <= 0 ? 0.0 : (u >= 1 ? 1.0 : u);
    }
    final dx = pe - (ae + ex * u), dn = pn - (an + en * u);
    final d = math.sqrt(dx * dx + dn * dn);
    if (_stamp[slot] != _epoch) {
      _stamp[slot] = _epoch;
      _touched[_touchedCount++] = slot;
      _bestD[slot] = d;
      _bestSeg[slot] = seg;
      _bestU[slot] = u;
    } else if (d < _bestD[slot]) {
      _bestD[slot] = d;
      _bestSeg[slot] = seg;
      _bestU[slot] = u;
    }
  }
}
