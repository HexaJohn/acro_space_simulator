// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/road_noise.dart';
import 'package:acro_space_simulator/domain/colony/city/spatial_index.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// `RoadNoiseSampler.noiseAtEN`, the allocation-free sample the agents'
/// sub-step reads, is bit-identical to the closure-walking sample it
/// replaced (kept below as the reference), at every lot and on a grid.
void main() {
  /// The sample as it stood before `noiseAtEN`: a closure per call, a Box2,
  /// a growable touched list and `clamp`.
  double reference(RoadGraph g, Vec2 p, Float64List pieceEmission) {
    final n = g.slotToRoad.length;
    final seen = <int, (double, int, double)>{};
    final order = <int>[];
    final reach = RoadNoise.reachM + RoadGraph.maxHalfWidth;
    g.index.visit(Box2.around(p, reach), 0, (slot, rec, seg) {
      if (seg == 0 || slot >= n) return;
      final r = g.slotToRoad[slot];
      if (r < 0 || !identical(rec.e, g.roadRecs[r].e)) return;
      final ae = rec.e[seg - 1], an = rec.n[seg - 1];
      final ex = rec.e[seg] - ae, en = rec.n[seg] - an;
      final len2 = ex * ex + en * en;
      final u = len2 <= 1e-12
          ? 0.0
          : (((p.e - ae) * ex + (p.n - an) * en) / len2).clamp(0.0, 1.0);
      final dx = p.e - (ae + ex * u), dn = p.n - (an + en * u);
      final d = math.sqrt(dx * dx + dn * dn);
      final best = seen[slot];
      if (best == null) {
        order.add(slot);
        seen[slot] = (d, seg, u);
      } else if (d < best.$1) {
        seen[slot] = (d, seg, u);
      }
    });
    var total = 0.0;
    for (final slot in order) {
      final (d, seg, u) = seen[slot]!;
      final r = g.slotToRoad[slot];
      final road = g.roads[r];
      final f = RoadNoise.falloff(d - road.halfWidth);
      if (f <= 0) continue;
      final s = g.roadRecs[r].arcAt(seg, u);
      if (road.deck?.inTunnelAt(s) ?? false) continue;
      total += pieceEmission[g.pieceAt(r, s)] * f;
    }
    return total.clamp(0.0, 1.0);
  }

  void expectSame(RoadGraph g, String name) {
    final emission = Float64List(g.pieceCount);
    for (var p = 0; p < g.pieceCount; p++) {
      emission[p] = ((p * 37) % 11) / 10;
    }
    final sampler = RoadNoiseSampler(g);
    var checked = 0, loud = 0;
    void at(double e, double n) {
      final want = reference(g, Vec2(e, n), emission);
      final got = sampler.noiseAtEN(e, n, emission);
      expect(got, want, reason: '$name at ($e, $n)');
      expect(sampler.noiseAt(Vec2(e, n), emission), want);
      checked++;
      if (want > 0) loud++;
    }

    for (var i = 0; i < g.lotCount; i++) {
      at(g.lotE[i], g.lotN[i]);
    }
    var minE = double.infinity, minN = double.infinity;
    var maxE = double.negativeInfinity, maxN = double.negativeInfinity;
    for (final r in g.roadRecs) {
      minE = math.min(minE, r.box.minE);
      minN = math.min(minN, r.box.minN);
      maxE = math.max(maxE, r.box.maxE);
      maxN = math.max(maxN, r.box.maxN);
    }
    const steps = 40;
    for (var ix = 0; ix <= steps; ix++) {
      for (var iy = 0; iy <= steps; iy++) {
        at(minE + (maxE - minE) * ix / steps, minN + (maxN - minN) * iy / steps);
      }
    }
    expect(checked, greaterThan(1000), reason: name);
    expect(loud, greaterThan(100), reason: name);
  }

  test('bit-identical on the built town', () {
    expectSame(town().roadGraph, 'town');
  });

  test('bit-identical on a small generated town', () {
    final city = const CityGenerator().generate(
        const CityGenSpec(blocksAcross: 4, seed: 5),
        bodies: fixtureBodies);
    expectSame(city.roadGraph, 'generated');
  });
}
