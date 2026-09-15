// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_frame.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';

/// 500 seeded random sites × road classes (docs/plans/site-access.md §7.9
/// A1, §8.3 `site_plan_property_test`): every eligible join road class, each
/// straight and curved (an avenue also planted), and on each road auto lots of
/// the plat and hand-drawn footprints (rectangles, triangles, L shapes and
/// trapezoids, skewed up to 15°, 5–90 m wide and 5–180 m deep) with a spec
/// drawn from homes, flats, shops, industry, megatowers and installations.
///
/// Test-only: the draws use `dart:math` `Random`, which plan code never may.
class RandomSite {
  RandomSite._(this.index, this.graph, this.parcel, this.spec, this.isLot);

  /// The site's place in the seeded list.
  final int index;
  final RoadGraph graph;
  final Parcel parcel;
  final CityBuildingSpec spec;

  /// A graph lot (`SiteContext.ofLot`) or a footprint (`ofFootprint`).
  final bool isLot;

  /// A fresh context (its lazy frame and seed not yet derived).
  SiteContext context() => isLot
      ? SiteContext.ofLot(graph, parcel, spec)
      : SiteContext.ofFootprint(graph, parcel, spec);
}

abstract final class RandomSites {
  static const int count = 500;

  /// Houses (40%), the other zone specs (35%), megatowers (5%) and
  /// installation-kind utilities (20%).
  static CityBuildingSpec _spec(math.Random rnd) {
    final r = rnd.nextDouble();
    if (r < 0.40) return kZoneSpecs['residential']![Density.low]!;
    if (r < 0.75) return _zone[rnd.nextInt(_zone.length)];
    if (r < 0.80) return kMegatowerSpec;
    return _sites[rnd.nextInt(_sites.length)];
  }

  static final List<CityBuildingSpec> _zone = [
    for (final byDensity in kZoneSpecs.values) ...byDensity.values,
  ];
  static final List<CityBuildingSpec> _sites = [
    for (final s in kUtilCatalog)
      if (s.siteKind != SiteKind.building) s,
  ];

  /// The [count] sites of [seed], in their seeded order.
  static List<RandomSite> build({int seed = 2026}) {
    final rnd = math.Random(seed);
    final roads = <(RoadClass, RoadDecoration, bool)>[
      for (final c in RoadClass.values.where(isEligibleJoinRoad)) ...[
        (c, RoadDecoration.none, false),
        (c, RoadDecoration.none, true),
      ],
      (RoadClass.avenue, RoadDecoration.grass, false),
    ];
    final graphs = <(RoadGraph, CityLayout, double)>[];
    for (var i = 0; i < roads.length; i++) {
      final (cls, deco, curved) = roads[i];
      final layout = CityLayout()
        ..addRoad(RoadSpline(
          id: 'rr$i',
          controls: curved
              ? const [Vec2(0, 0), Vec2(200, 40), Vec2(400, 0)]
              : const [Vec2(0, 0), Vec2(400, 0)],
          roadClass: cls,
          decoration: deco,
        ));
      graphs.add((RoadGraph.of(layout), layout, cls.halfWidth));
    }
    final usedLots = <String>{};
    final out = <RandomSite>[];
    for (var i = 0; i < count; i++) {
      final gi = i % graphs.length;
      final (g, layout, hw) = graphs[gi];
      final (_, _, curved) = roads[gi];
      final spec = _spec(rnd);
      final lots = layout.autoParcels;
      if (rnd.nextBool() && lots.isNotEmpty) {
        final p = lots[rnd.nextInt(lots.length)];
        if (usedLots.add(p.id)) {
          out.add(RandomSite._(i, g, p, spec, true));
          continue;
        }
      }
      out.add(RandomSite._(i, g, _footprint(rnd, i, hw, curved), spec, false));
    }
    return out;
  }

  static Parcel _footprint(math.Random rnd, int i, double hw, bool curved) {
    final cx = 40 + rnd.nextDouble() * 320;
    // Curved roads bulge to +y: their footprints stand on the −y side.
    final side = curved || rnd.nextBool() ? -1.0 : 1.0;
    final gap = hw + 2 + rnd.nextDouble() * 8;
    final w = 5 + rnd.nextDouble() * 85;
    final d = 5 + rnd.nextDouble() * 175;
    final skew = (rnd.nextDouble() * 2 - 1) * 15 * math.pi / 180;
    final shape = rnd.nextInt(4);
    // Local (x along the road, y away from it), skewed about the front
    // centre, then placed.
    final ux = math.cos(skew), uy = math.sin(skew);
    Vec2 at(double x, double y) {
      final rx = x * ux - y * uy, ry = x * uy + y * ux;
      return Vec2(cx + rx, side * (gap + ry));
    }

    final List<Vec2> poly = switch (shape) {
      0 => [at(-w / 2, 0), at(w / 2, 0), at(w / 2, d), at(-w / 2, d)],
      1 => [at(-w / 2, 0), at(w / 2, 0), at((rnd.nextDouble() - 0.5) * w, d)],
      2 => [
          at(-w / 2, 0), at(w / 2, 0), at(w / 2, d * 0.4), at(0, d * 0.4),
          at(0, d), at(-w / 2, d), //
        ],
      _ => [at(-w / 2, 0), at(w / 2, 0), at(w / 4, d), at(-w / 4, d)],
    };
    return Parcel(id: 'cell-rand-$i', polygon: poly);
  }

  /// A plan's rows as one comparable list: every count, every family's
  /// columns that are not chunk-global offsets, and `rev`.
  static List<Object> signatureOf(SiteAccessPlan p) => [
        p.siteId, p.rev, p.program, p.flags, p.graphStamp, p.graphLot,
        p.frameE, p.frameN, p.frameUE, p.frameUN,
        p.envX0, p.envY0, p.envX1, p.envY1, p.envFrontInset, p.gateX, p.gateW,
        p.truckTurnRadiusM, p.entrancePt, p.pavementPt, p.entranceNode,
        p.pointCount, p.joinCount, p.nodeCount, p.segCount, p.stallCount,
        p.bayCount, p.paveCount, p.lampCount, p.pathCount,
        for (var k = 0; k < p.pointCount; k++) ...[
          p.ptE(k), p.ptN(k), p.ptHRef(k), p.ptHJoin(k), p.ptHT(k),
        ],
        for (var j = 0; j < p.joinCount; j++) ...[
          p.joinSlot(j), p.joinRef(j), p.joinPiece(j), p.joinRoadS(j),
          p.joinKind(j), p.joinRole(j), p.joinDirs(j), p.joinCutHalfM(j),
          p.joinKerbNode(j), p.joinThroatSeg(j),
        ],
        for (var n = 0; n < p.nodeCount; n++) ...[
          p.nodePt(n), p.nodeFlags(n), p.nodeTurnKind(n),
        ],
        for (var k = 0; k < p.segCount; k++) ...[
          p.segFrom(k), p.segTo(k), p.segLenM(k), p.segWidthM(k),
          p.segKind(k), p.segFlags(k), p.segViaCount(k),
        ],
        for (var s = 0; s < p.stallCount; s++) ...[
          p.stallKey(s), p.stallSeg(s), p.stallS(s), p.stallE(s), p.stallN(s),
          p.stallAngle(s), p.stallInDirs(s), p.stallOutDirs(s),
        ],
      ];
}
