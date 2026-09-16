// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The kerbside of a road with site access (docs/plans/site-access.md §5.5,
/// §8.3 R4 `kerb_cut_test`): the dropped kerb the sidewalk lays, the grass
/// the verge leaves out, the props and lamps a cut moves, and the kerb cars
/// its mask stands down.
library;

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/kerb_cuts.dart';
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/scatter/prop_mesh.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
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
}
