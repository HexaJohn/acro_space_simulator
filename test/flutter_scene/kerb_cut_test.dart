// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The kerbside of a road with site access (docs/plans/site-access.md §5.5,
/// §8.3 R4 `kerb_cut_test`): the dropped kerb the sidewalk lays, the grass
/// the verge leaves out, the props and lamps a cut moves, the kerb cars its
/// mask stands down — and, on a sealed world, the pedestrian tube it carries
/// over the drive on legs (§3.8, §10.2 Q8 option (a)).
library;

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/kerb_cuts.dart';
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/scatter/prop_mesh.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/pedestrian_tube.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/street_furniture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const r = 1.7374e6;
  const anchor = Vector3(0, 0, r);
  const halfWidth = 4.0; // a street
  const lengthM = 200.0;

  /// A straight street through the anchor, anchor-relative, a station every
  /// two metres: travel runs toward larger x, so the kerb right of it —
  /// side 1 — is at −y.
  final pts = <Vector3>[
    for (var i = 0; i <= lengthM ~/ 2; i++) Vector3(i * 2.0, 0, 0),
  ];

  /// A canonical entry in the drawn frame: a two-way road drives on the
  /// right, so σ is +1 on side 1 and −1 on side 0.
  Float64List cuts(List<(int side, double c, double h, int kind)> of) {
    final out = Float64List(of.length * KerbCuts.stride);
    for (var i = 0; i < of.length; i++) {
      final (side, c, h, kind) = of[i];
      out[i * 5] = side.toDouble();
      out[i * 5 + 1] = c;
      out[i * 5 + 2] = h;
      out[i * 5 + 3] = side == 1 ? 1 : -1;
      out[i * 5 + 4] = kind.toDouble();
    }
    return out;
  }

  List<double> positionsOf(PropMesh m) => m.positions.toList();

  double arcOf(PropMesh m, int i) => m.positions[i * 3] * 1000.0;
  double acrossOf(PropMesh m, int i) => m.positions[i * 3 + 1] * 1000.0;

  /// Metres of a vertex (in scene units) over the DRAPE below it: the road
  /// is a chord of the body, so the plane it lies in is a few millimetres
  /// under the sphere by the end of it.
  double heightOf(PropMesh m, int i) {
    final p = Vector3(m.positions[i * 3], m.positions[i * 3 + 1],
            m.positions[i * 3 + 2]) *
        1000.0;
    final a = arcOf(m, i), across = acrossOf(m, i);
    final ground = Vector3(a, across, 0) + anchor;
    return (p + anchor).length - ground.length;
  }

  PropMesh walk({Float64List? with_, double pullStart = 0}) {
    final m = MeshBuilder();
    RoadMesher.sidewalks(m, pts, halfWidth, 3.0, anchor,
        pullStart: pullStart, cuts: with_);
    return m.build();
  }

  group('sidewalks', () {
    test('no cuts, an empty table and a cut off the road are all the road '
        'as it was, to the byte', () {
      final plain = positionsOf(walk());
      expect(positionsOf(walk(with_: Float64List(0))), plain);
      expect(positionsOf(walk(with_: cuts([(1, 900.0, 4.0, 0)]))), plain);
      // A far-kerb swing mask breaks no kerb (§5.5).
      expect(
          positionsOf(walk(
              with_: cuts([(1, 100.0, 4.0, KerbCuts.kindHomeFarSwing)]))),
          plain);
    });

    test('the kerb edge drops to the dropped-kerb lift at the cut centre and '
        'is the walk top a flare away', () {
      final m = walk(with_: cuts([(1, 100.0, 4.0, KerbCuts.kindDropped)]));
      // The inner (kerb) edge of the side-1 strip: at −y, at the half
      // width. The walk's own top stays where it was on the far side.
      // The TOP of the walk at that edge: the kerb face's foot shares the
      // inner edge's across, a kerb lower down.
      double atArc(double arc, {required bool inner, required double side}) {
        var best = double.negativeInfinity;
        var found = false;
        for (var i = 0; i < m.vertexCount; i++) {
          final across = acrossOf(m, i);
          final want = inner ? halfWidth : halfWidth + 3.0;
          if ((across - want * -side).abs() > 0.05) continue;
          if ((arcOf(m, i) - arc).abs() > 0.2) continue;
          found = true;
          final h = heightOf(m, i);
          if (h > best) best = h;
        }
        expect(found, isTrue, reason: 'a station near $arc');
        return best;
      }

      expect(atArc(100, inner: true, side: 1.0),
          closeTo(RoadMesher.cutTopLiftM, 1e-3));
      expect(atArc(100, inner: false, side: 1.0),
          closeTo(RoadMesher.walkTopLiftM, 1e-3));
      // Clear of the cut and its flare the kerb is the kerb again.
      expect(atArc(110, inner: true, side: 1.0),
          closeTo(RoadMesher.walkTopLiftM, 1e-3));
      // The other kerb never moves.
      expect(atArc(100, inner: true, side: -1.0),
          closeTo(RoadMesher.walkTopLiftM, 1e-3));
      // The stations the flare wants: its foot holds the drop, its head is
      // the walk again.
      expect(atArc(104, inner: true, side: 1.0),
          closeTo(RoadMesher.cutTopLiftM, 1e-3));
      expect(atArc(105, inner: true, side: 1.0),
          closeTo(RoadMesher.walkTopLiftM, 1e-3));
      // And the ease between them, half way up, half way down.
      final table = cuts([(1, 100.0, 4.0, KerbCuts.kindDropped)]);
      expect(
          RoadMesher.kerbTopLiftAt(table, 1, 104.5),
          closeTo(
              RoadMesher.cutTopLiftM +
                  (RoadMesher.walkTopLiftM - RoadMesher.cutTopLiftM) * 0.5,
              1e-9));
      expect(RoadMesher.kerbTopLiftAt(table, 0, 100),
          RoadMesher.walkTopLiftM);
    });

    test('the kerb face is 2.5 cm tall across the cut', () {
      final m = walk(with_: cuts([(1, 100.0, 4.0, KerbCuts.kindHomeLot)]));
      var top = double.nan, bottom = double.nan;
      for (var i = 0; i < m.vertexCount; i++) {
        if ((acrossOf(m, i) + halfWidth).abs() > 0.05) continue;
        if ((arcOf(m, i) - 100).abs() > 0.5) continue;
        final h = heightOf(m, i);
        if (h.isNaN) continue;
        if (top.isNaN || h > top) top = h;
        if (bottom.isNaN || h < bottom) bottom = h;
      }
      expect(top - bottom, closeTo(0.025, 2e-3));
    });

    test('a span later in the road reads its cuts through arcOffset', () {
      // The same cut, measured from a span that starts 60 m in.
      final whole = walk(with_: cuts([(1, 100.0, 4.0, 0)]));
      final tail = MeshBuilder();
      RoadMesher.sidewalks(tail, pts.sublist(30), halfWidth, 3.0, anchor,
          cuts: cuts([(1, 100.0, 4.0, 0)]), arcOffset: 60);
      final m = tail.build();
      var found = false;
      for (var i = 0; i < m.vertexCount; i++) {
        if ((acrossOf(m, i) + halfWidth).abs() > 0.05) continue;
        if ((arcOf(m, i) - 100).abs() > 0.2) continue;
        if ((heightOf(m, i) - RoadMesher.cutTopLiftM).abs() < 1e-3) {
          found = true;
        }
      }
      expect(found, isTrue, reason: 'the cut is at 100 m of the whole road');
      expect(whole.vertexCount, greaterThan(0));
    });
  });

  group('verges', () {
    PropMesh verge({Float64List? with_, List<(Vector3, double)>? trees}) {
      final m = MeshBuilder();
      RoadMesher.verges(m, pts, halfWidth, anchor,
          widthM: 1.3,
          u: 0.5,
          seed: 12345,
          treesOut: trees,
          cuts: with_);
      return m.build();
    }

    test('the grass stops at the cut and the tree pits near it are left out',
        () {
      final plainTrees = <(Vector3, double)>[];
      final plain = verge(trees: plainTrees);
      final cutTrees = <(Vector3, double)>[];
      final cut = verge(
          with_: cuts([(1, 100.0, 4.0, KerbCuts.kindDropped)]),
          trees: cutTrees);
      expect(cut.triangleCount, lessThan(plain.triangleCount));
      expect(cutTrees.length, lessThan(plainTrees.length));
      // The yaw counter still advances: every pit that survives is exactly
      // the pit it was.
      for (final t in cutTrees) {
        expect(plainTrees.contains(t), isTrue);
      }
      // Nothing planted within four metres of the cut on its own side.
      for (final (at, _) in cutTrees) {
        if (at.y > 0) continue; // side 1 is at −y
        expect((at.x * 1.0 - 100).abs(), greaterThanOrEqualTo(4.0 - 1e-9));
      }
    });

    test('no cuts is the verge it was, to the byte', () {
      expect(positionsOf(verge(with_: Float64List(0))),
          positionsOf(verge()));
    });
  });

  group('street furniture', () {
    (PropMesh, PropMesh, List<(Vector3, double)>) props({Float64List? with_}) {
      final solid = MeshBuilder(), glow = MeshBuilder();
      final trees = <(Vector3, double)>[];
      StreetFurniture.emit(solid, glow,
          pts: pts,
          anchorBF: anchor,
          cls: RoadClass.street,
          halfWidthM: halfWidth,
          pavementM: 3.0,
          seed: 4242,
          treesOut: trees,
          cuts: with_);
      return (solid.build(), glow.build(), trees);
    }

    test('a slot inside a cut draws its randomness and stands nothing there',
        () {
      final (plainSolid, _, plainTrees) = props();
      final (cutSolid, _, cutTrees) = props(
          with_: cuts([
            (1, 60.0, 4.0, KerbCuts.kindDropped),
            (0, 140.0, 4.0, KerbCuts.kindHomeLot),
          ]));
      expect(cutSolid.vertexCount, lessThan(plainSolid.vertexCount));
      // Every prop that survives is byte-for-byte the prop it was, in
      // order: the run of random draws is the same run.
      final plain = positionsOf(plainSolid), kept = positionsOf(cutSolid);
      var at = 0;
      for (final v in kept) {
        while (at < plain.length && plain[at] != v) {
          at++;
        }
        expect(at, lessThan(plain.length),
            reason: 'a prop the cut moved rather than dropped');
        at++;
      }
      for (final t in cutTrees) {
        expect(plainTrees.contains(t), isTrue);
      }
    });

    test('a far-kerb swing mask moves no prop', () {
      final plain = positionsOf(props().$1);
      final swing = positionsOf(props(
          with_: cuts([(1, 60.0, 4.0, KerbCuts.kindHomeFarSwing)])).$1);
      expect(swing, plain);
    });
  });

  group('lamps', () {
    (PropMesh, PropMesh) lamps({Float64List? with_}) {
      final solid = MeshBuilder(), glow = MeshBuilder();
      RoadMesher.lamps(
          solid, glow, pts, anchor, halfWidth, RoadClass.street,
          liftM: RoadMesher.walkTopLiftM, cuts: with_);
      return (solid.build(), glow.build());
    }

    /// The arc of each lamp head: one head per lamp, all the same size.
    List<double> headArcs(PropMesh glow, int count) {
      final per = glow.vertexCount ~/ count;
      return [
        for (var k = 0; k < count; k++)
          () {
            var sum = 0.0;
            for (var i = k * per; i < (k + 1) * per; i++) {
              sum += arcOf(glow, i);
            }
            return sum / per;
          }(),
      ];
    }

    test('a column standing in a cut moves to the cut end plus a metre', () {
      // A street is lit from alternating kerbs: 17 m on side 1, 51 m on
      // side 0, 85 m on side 1, and so on.
      // Spacing 34 from 17 m in, at the first station past each: the
      // stations are every 2 m, so 18, 52, 86, 120, 154, 188.
      const lamps0 = 6;
      final (_, plainGlow) = lamps();
      final plain = headArcs(plainGlow, lamps0);
      expect(plain[1], closeTo(52, 0.5));
      final (_, movedGlow) =
          lamps(with_: cuts([(0, 51.0, 4.0, KerbCuts.kindDropped)]));
      final moved = headArcs(movedGlow, lamps0);
      expect(moved[1], closeTo(51 + 4 + 1, 1.0));
      // Every other column is where it was.
      for (final i in [0, 2, 3, 4, 5]) {
        expect(moved[i], closeTo(plain[i], 1e-6));
      }
    });

    test('a column shifted past the end of its span stops at the end', () {
      // A road cut into graded spans by its decks dresses each span on its
      // own, so a cut near a span's edge shifts a column off the end of it.
      // It belongs at the end, not left standing in the dropped kerb.
      final span = pts.sublist(0, 30); // 58 m of the road
      final solid = MeshBuilder(), glow = MeshBuilder();
      RoadMesher.lamps(solid, glow, span, anchor, halfWidth, RoadClass.street,
          liftM: RoadMesher.walkTopLiftM,
          cuts: cuts([(0, 51.0, 6.5, KerbCuts.kindDropped)]));
      final m = glow.build();
      // Two columns on this span: 18 m on side 1, 52 m on side 0. The
      // second stands in the cut, whose far end (57.5 m) plus a metre is
      // past the span's last point.
      final arcs = () {
        final per = m.vertexCount ~/ 2;
        return [
          for (var k = 0; k < 2; k++)
            () {
              var sum = 0.0;
              for (var i = k * per; i < (k + 1) * per; i++) {
                sum += arcOf(m, i);
              }
              return sum / per;
            }(),
        ];
      }();
      expect(arcs[0], closeTo(18, 0.5));
      expect(arcs[1], closeTo(58, 0.5), reason: 'clamped to the span end');
      // And it really moved: standing put it would be at 52 m, inside the
      // cut that runs from 44.5 m to 57.5 m.
      expect(KerbCuts.blocked(cuts([(0, 51.0, 6.5, KerbCuts.kindDropped)]), 0,
              52, upstreamM: 0, downstreamM: 0),
          isTrue);
    });

    test('a cut on the other kerb, and a far-swing mask, move nothing', () {
      final plain = positionsOf(lamps().$2);
      expect(
          positionsOf(
              lamps(with_: cuts([(1, 51.0, 4.0, KerbCuts.kindDropped)])).$2),
          plain);
      expect(
          positionsOf(lamps(
                  with_: cuts([(0, 51.0, 4.0, KerbCuts.kindHomeFarSwing)]))
              .$2),
          plain);
    });
  });

  group('the pedestrian tube over a drive', () {
    // Where the barrel's axis runs: outside the kerb, clear of the lane. The
    // tube is on ONE verge, the side-1 kerb, so `side` (= −y here) times this
    // is where every measurement below is taken from.
    const across = halfWidth +
        PedestrianTube.radiusM +
        PedestrianTube.clearOfLaneM;
    const cutHalf = 4.0;

    (PropMesh, PropMesh) tube(
        {Float64List? with_, double arcOffset = 0, List<Vector3>? on}) {
      final solid = MeshBuilder(), glass = MeshBuilder();
      PedestrianTube.emit(solid, glass,
          pts: on ?? pts,
          halfWidthM: halfWidth,
          anchorBF: anchor,
          cuts: with_,
          arcOffset: arcOffset);
      return (solid.build(), glass.build());
    }

    /// A straight street [lengthM] long drawn with a vertex every [stationM]:
    /// how COARSELY a road is drawn is the road tool's business, not the
    /// tube's, and the zoo's own sealed street is drawn at 100 m stations
    /// (`road_tool_mesh_test`).
    List<Vector3> drawn(double lengthM, double stationM) => [
          for (var i = 0; i <= (lengthM / stationM).round(); i++)
            Vector3(i * stationM, 0, 0),
        ];

    /// Metres from the centreline on the tube's own side (side 1 is at −y).
    double outOf(PropMesh m, int i) => -acrossOf(m, i);

    /// The barrel's floor at [arc]: its lowest vertex is the one on the axis
    /// line, which is exactly the curb line the whole tube rides.
    double floorAt(PropMesh glass, double arc) {
      var best = double.infinity;
      var found = false;
      for (var i = 0; i < glass.vertexCount; i++) {
        if ((outOf(glass, i) - across).abs() > 0.01) continue;
        // Stations are two metres apart, so the nearest ring to any arc is
        // within one; every arc asked for below is on a flat stretch of the
        // profile, where which of the two it finds cannot matter.
        if ((arcOf(glass, i) - arc).abs() > 1.1) continue;
        final h = heightOf(glass, i);
        found = true;
        if (h < best) best = h;
      }
      expect(found, isTrue, reason: 'a ring near $arc');
      return best;
    }

    /// Whether [i] is a leg post rather than the beam: the posts stand a
    /// fixed offset either side of the axis, the beam's edges a radius.
    bool isLeg(PropMesh m, int i) {
      final d = outOf(m, i);
      for (final o in const [-1.0, 1.0]) {
        if ((d - (across + PedestrianTube.legOffsetM * o)).abs() <=
            PedestrianTube.legHalfM + 1e-6) {
          return true;
        }
      }
      return false;
    }

    /// The arc of every pair of posts in [m], ascending: a post is
    /// `legHalfM` thick along the road too, so its four corners bracket the
    /// arc its pair stands at.
    List<double> legPairs(PropMesh m) {
      final arcs = <double>[];
      for (var i = 0; i < m.vertexCount; i++) {
        if (isLeg(m, i)) arcs.add(arcOf(m, i));
      }
      arcs.sort();
      const span = 2 * PedestrianTube.legHalfM + 1e-3;
      final at = <double>[];
      var i = 0;
      while (i < arcs.length) {
        final lo = arcs[i];
        var hi = lo;
        while (i < arcs.length && arcs[i] - lo <= span) {
          hi = arcs[i];
          i++;
        }
        at.add((lo + hi) / 2);
      }
      return at;
    }

    test('no cut on its own kerb moves the tube, to the byte', () {
      final glass = positionsOf(tube().$2);
      final solid = positionsOf(tube().$1);
      for (final table in <Float64List?>[
        Float64List(0),
        // The far kerb: the tube runs down the other verge and crosses
        // nothing there.
        cuts([(0, 100.0, cutHalf, KerbCuts.kindDropped)]),
        // A swing mask breaks no kerb, so it bridges nothing either.
        cuts([(1, 100.0, cutHalf, KerbCuts.kindHomeFarSwing)]),
        // And a drive whose whole approach falls off the far end.
        cuts([(1, 900.0, cutHalf, KerbCuts.kindDropped)]),
      ]) {
        expect(positionsOf(tube(with_: table).$2), glass, reason: '$table');
        expect(positionsOf(tube(with_: table).$1), solid, reason: '$table');
      }
    });

    test('the tube rises over the drive at one in twelve, and comes back '
        'down', () {
      final (_, glass) =
          tube(with_: cuts([(1, 100.0, cutHalf, KerbCuts.kindHomeLot)]));
      // The hold runs a margin past the cut either side; the approaches run a
      // ramp out from that.
      const hold = cutHalf + PedestrianTube.crossMarginM; // 5 m
      expect(floorAt(glass, 100),
          closeTo(PedestrianTube.curbLiftM + PedestrianTube.crossLiftM, 2e-3),
          reason: 'level over the drive');
      expect(floorAt(glass, 100 - hold + 0.3),
          closeTo(PedestrianTube.curbLiftM + PedestrianTube.crossLiftM, 2e-3));
      // Clear of the approach it is the curb it always was.
      expect(floorAt(glass, 100 - hold - PedestrianTube.rampM - 6),
          closeTo(PedestrianTube.curbLiftM, 2e-3));
      expect(floorAt(glass, 100 + hold + PedestrianTube.rampM + 6),
          closeTo(PedestrianTube.curbLiftM, 2e-3));
      // And the grade between: measured over ten metres of the approach.
      final rise = floorAt(glass, 90) - floorAt(glass, 80);
      expect(rise / 10.0, closeTo(PedestrianTube.rampGrade, 1e-3));
      expect(PedestrianTube.rampGrade, closeTo(1 / 12, 1e-12));
    });

    test('a rover fits under the soffit, and the drive is clear of it', () {
      final (solid, _) =
          tube(with_: cuts([(1, 100.0, cutHalf, KerbCuts.kindDropped)]));
      // The lowest thing over the drive is the beam's underside.
      var soffit = double.infinity;
      for (var i = 0; i < solid.vertexCount; i++) {
        if ((arcOf(solid, i) - 100).abs() > 0.5) continue;
        final h = heightOf(solid, i);
        if (h < soffit) soffit = h;
      }
      expect(soffit, closeTo(PedestrianTube.crossClearM, 2e-3));
      expect(PedestrianTube.crossClearM, greaterThan(1.95),
          reason: 'a rover is 1.95 m tall');
    });

    test('the legs stand on the ground, and never in the drive', () {
      final (solid, _) =
          tube(with_: cuts([(1, 100.0, cutHalf, KerbCuts.kindDropped)]));
      final feet = <double, (double, double)>{};
      for (var i = 0; i < solid.vertexCount; i++) {
        if (!isLeg(solid, i)) continue;
        final s = (arcOf(solid, i) * 1000).round() / 1000.0;
        final h = heightOf(solid, i);
        final was = feet[s];
        feet[s] = was == null
            ? (h, h)
            : (h < was.$1 ? h : was.$1, h > was.$2 ? h : was.$2);
      }
      expect(feet, isNotEmpty, reason: 'nothing holds the deck up');
      final over = PedestrianTube.crossingsOf(
          cuts([(1, 100.0, cutHalf, KerbCuts.kindDropped)]));
      for (final MapEntry(key: s, value: (lo, hi)) in feet.entries) {
        // A foot in the ground, not in the air, and not hanging in it.
        expect(lo, closeTo(-PedestrianTube.legFootM, 2e-3),
            reason: 'the leg at $s does not reach the ground');
        // And its head under the deck it carries.
        expect(
            hi,
            closeTo(
                PedestrianTube.curbLiftM +
                    PedestrianTube.liftAt(over, s) -
                    PedestrianTube.deckThickM,
                0.1),
            reason: 'the leg at $s does not reach the soffit');
        // Never standing in the drive itself. A post's CENTRE is held
        // `legClearM` clear of the cut and the post is `legHalfM` thick along
        // the road too, so its nearest corner stands 1.84 m off the drive's
        // edge — which is the number this measures, since every vertex here
        // is a corner.
        expect(
            (s - 100).abs(),
            greaterThanOrEqualTo(cutHalf +
                PedestrianTube.legClearM -
                PedestrianTube.legHalfM -
                2e-3),
            reason: 'a leg planted in the drive at $s');
      }
      expect(
          PedestrianTube.legClearM - PedestrianTube.legHalfM, closeTo(1.84, 1e-9),
          reason: 'the clear the doc quotes at the post corner');
    });

    test('the legs are the structure\'s, not the polyline\'s', () {
      // The defect this pins: legs used to land only on a vertex the ROAD
      // TOOL happened to draw, and a post is barred from standing within
      // `legClearM` of a cut, so a fused terrace drawn at ten metre stations
      // stood on four posts with 38 m of level deck on nothing, and a lone
      // crossing on a road drawn at 25 m stations got no post at all.
      const drives = [120.0, 135.0, 150.0]; // a terrace, fused into one deck
      final terrace = cuts([
        for (final c in drives) (1, c, cutHalf, KerbCuts.kindHomeLot),
      ]);
      const shut = cutHalf + PedestrianTube.legClearM; // 6 m either side
      // The same posts at every density the road may be drawn at, including
      // one coarser than the zoo's own sealed street.
      List<double>? was;
      for (final station in const [1.0, 2.0, 10.0, 25.0, 100.0]) {
        final at = legPairs(tube(with_: terrace, on: drawn(400, station)).$1);
        if (was == null) {
          was = at;
        } else {
          expect(at.length, was.length, reason: '${station}m stations');
          for (var i = 0; i < at.length; i++) {
            expect(at[i], closeTo(was[i], 1e-3), reason: '${station}m stations');
          }
        }
      }
      final at = was!;
      // The whole raised run is held: from a leg-run into the first approach
      // to a leg-run out of the last.
      expect(at.first, closeTo(drives.first - cutHalf - 1 - PedestrianTube.legRunM,
          1e-3));
      expect(at.last,
          closeTo(drives.last + cutHalf + 1 + PedestrianTube.legRunM, 1e-3));
      for (var i = 1; i < at.length; i++) {
        final gap = at[i] - at[i - 1];
        // Either a step of the regular spacing, or a drive being spanned —
        // and nothing else. A drive's opening plus its clearance is the ONLY
        // stretch of deck that stands on nothing.
        final drive = drives.any((c) =>
            (at[i - 1] - (c - shut)).abs() < 1e-3 &&
            (at[i] - (c + shut)).abs() < 1e-3);
        expect(gap, lessThanOrEqualTo(drive ? 2 * shut + 1e-3 : PedestrianTube.legSpacingM + 1e-3),
            reason: 'a $gap m gap at ${at[i - 1]}');
      }
      // And a post stands at each edge of every drive, so the span over one
      // is the opening and nothing more.
      for (final c in drives) {
        for (final edge in [c - shut, c + shut]) {
          expect(at.any((s) => (s - edge).abs() < 1e-3), isTrue,
              reason: 'no post at the drive edge $edge');
        }
      }
      // A lone crossing on a coarsely drawn road is held too — it used to
      // get nothing at all.
      final lone = cuts([(1, 200.0, cutHalf, KerbCuts.kindDropped)]);
      for (final station in const [2.0, 25.0, 100.0]) {
        final posts = legPairs(tube(with_: lone, on: drawn(400, station)).$1);
        expect(posts.length, 8, reason: '${station}m stations');
        expect(posts.first,
            closeTo(200 - cutHalf - 1 - PedestrianTube.legRunM, 1e-3));
      }
    });

    test('drives a house apart fuse into one raised walkway', () {
      // A cut's spacing IS its lot's frontage, and a house lot is 17–24 m
      // (§3 C-1; the layout default is 24 m) — so two holds are 7–14 m of
      // clear apart against 58.8 m of two ramps, and the tube cannot come
      // down and go back up in that. So it stays up: one continuous walkway
      // on legs, which is the shape this feature takes rather than a surprise
      // (§10.2 Q8). The fifteen metres here are the tightest terrace the
      // layout makes (`minFrontageFraction` 0.6 of the 24 m default is
      // 14.4 m), so the case is the hardest one and not the typical one.
      final table = cuts([
        (1, 100.0, cutHalf, KerbCuts.kindHomeLot),
        (1, 115.0, cutHalf, KerbCuts.kindHomeLot),
        (1, 130.0, cutHalf, KerbCuts.kindHomeLot),
      ]);
      final over = PedestrianTube.crossingsOf(table);
      expect(over.length, 1, reason: 'three drives, one structure');
      expect(over.single.$1, closeTo(100 - cutHalf - 1, 1e-9));
      expect(over.single.$2, closeTo(130 + cutHalf + 1, 1e-9));
      final (_, glass) = tube(with_: table);
      // Level the whole way across, with no sag between the drives.
      for (final s in const [100.0, 108.0, 115.0, 122.0, 130.0]) {
        expect(floorAt(glass, s),
            closeTo(PedestrianTube.curbLiftM + PedestrianTube.crossLiftM, 2e-3),
            reason: 'a sag at $s');
      }
    });

    test('drives far apart each get their own bridge', () {
      final table = cuts([
        (1, 40.0, cutHalf, KerbCuts.kindDropped),
        (1, 160.0, cutHalf, KerbCuts.kindDropped),
      ]);
      final over = PedestrianTube.crossingsOf(table);
      expect(over.length, 2);
      final (_, glass) = tube(with_: table);
      // Down on its curb between them: 100 m is more than a ramp from either.
      expect(floorAt(glass, 100), closeTo(PedestrianTube.curbLiftM, 2e-3));
      // A lone crossing is still not SHORT: two approaches and the hold, as
      // §10.2 Q8 quotes it — 2·29.4 + 2·(4.0 + 1.0).
      expect(
          2 * PedestrianTube.rampM +
              2 * (cutHalf + PedestrianTube.crossMarginM),
          closeTo(68.8, 1e-9));
    });

    test('what a crossing costs, so §8.4 can be re-derived', () {
      // The figure §5.5 as built quotes, measured where anyone can re-run it:
      // `PedestrianTube.emit` alone over 400 m of street drawn at ten metre
      // stations, against the same call with no cut in the table. The tile
      // this rides in carries roads, kerbside and parked rovers too, so an
      // absolute tile total says nothing about the tube; this is the tube.
      const drives = <(int, double, double, int)>[
        (1, 120.0, cutHalf, KerbCuts.kindHomeLot),
        (1, 135.0, cutHalf, KerbCuts.kindHomeLot),
        (1, 150.0, cutHalf, KerbCuts.kindHomeLot),
        (1, 350.0, cutHalf, KerbCuts.kindDropped),
      ];
      (int, int) cost({Float64List? with_}) {
        final (solid, glass) = tube(with_: with_, on: drawn(400, 10));
        return (
          solid.vertexCount + glass.vertexCount,
          solid.triangleCount + glass.triangleCount,
        );
      }

      expect(cost(), (328, 560), reason: 'the plain tube');
      expect(cost(with_: cuts(drives)), (1606, 1680),
          reason: 'four drives: two crossings, one of them a fused terrace');
    });

    test('a span later in the road reads its crossings through arcOffset', () {
      // The same drive, drawn by a span that starts 60 m in: the tube is up
      // over 100 m of the WHOLE road either way.
      final table = cuts([(1, 100.0, cutHalf, KerbCuts.kindDropped)]);
      final solid = MeshBuilder(), glass = MeshBuilder();
      PedestrianTube.emit(solid, glass,
          pts: pts.sublist(30),
          halfWidthM: halfWidth,
          anchorBF: anchor,
          cuts: table,
          arcOffset: 60);
      final m = glass.build();
      var best = double.infinity;
      for (var i = 0; i < m.vertexCount; i++) {
        if ((outOf(m, i) - across).abs() > 0.01) continue;
        // The span's own points start at 60 m of the road, so the drive is
        // 40 m along it — and the mesh is still in road coordinates.
        if ((arcOf(m, i) - 100).abs() > 0.3) continue;
        final h = heightOf(m, i);
        if (h < best) best = h;
      }
      expect(best,
          closeTo(PedestrianTube.curbLiftM + PedestrianTube.crossLiftM, 2e-3));
    });
  });
}
