// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_texture_bakes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_mesher.dart';
import 'package:flutter_test/flutter_test.dart';

/// One road pipeline: a road's class decides its geometry, and a junction's
/// control decides what stands on it, wherever either is drawn.
void main() {
  // On the equator of a 6371 km world: local up is +x, the road runs +z.
  final anchor = Vector3(6371000, 0, 0);
  List<Vector3> line(double lengthM, {int samples = 2}) => [
        for (var i = 0; i < samples; i++)
          Vector3(0, 0, lengthM * i / (samples - 1)),
      ];
  int tris(MeshBuilder m) => m.build().indices.length ~/ 3;

  group('carriageways', () {
    test('a street is a ribbon and one painted line', () {
      final m = MeshBuilder();
      RoadMesher.carriageway(m, line(100), anchor, RoadClass.street);
      // Two strips of one quad each.
      expect(tris(m), 4);
    });

    test('paint off, the road is the ribbon alone', () {
      final m = MeshBuilder();
      RoadMesher.carriageway(m, line(100), anchor, RoadClass.expressway8,
          paint: false);
      expect(tris(m), 2);
    });

    test('an eight-lane expressway paints every line, both shoulders and '
        'the median, and stands a barrier on the solid', () {
      final m = MeshBuilder();
      final solid = MeshBuilder();
      RoadMesher.carriageway(m, line(100), anchor, RoadClass.expressway8,
          solid: solid);
      // Ribbon + 10 lines + 2 shoulders + median = 14 strips of one quad.
      expect(tris(m), 28);
      // One barrier box per segment.
      expect(tris(solid), 12);
    });

    test('a ramp is one way: a ribbon, two edge lines, two shoulders, no '
        'centre', () {
      final m = MeshBuilder();
      RoadMesher.carriageway(m, line(100), anchor, RoadClass.ramp);
      expect(tris(m), 10);
    });

    test('a road drawn narrower than its class keeps its lanes inside it',
        () {
      final m = MeshBuilder();
      RoadMesher.carriageway(m, line(100), anchor, RoadClass.avenue,
          halfWidthM: 6.0);
      final mesh = m.build();
      // Every vertex lies within the drawn half width of the centreline
      // (the road runs along z at y = 0, so |y| is the lateral offset).
      for (var i = 0; i < mesh.positions.length; i += 3) {
        expect(mesh.positions[i + 1].abs() / 1e-3, lessThanOrEqualTo(6.0 + 1e-6));
      }
    });

    test('a taper narrows the edge and folds the outer lines onto it', () {
      final m = MeshBuilder();
      RoadMesher.carriageway(m, line(300, samples: 31), anchor,
          RoadClass.expressway6,
          endHalfWidthM: RoadClass.expressway4.halfWidth);
      final mesh = m.build();
      // The ribbon is the first strip: its first two vertices are the full
      // width, its last two the narrower one.
      double lateral(int v) => mesh.positions[v * 3 + 1].abs() / 1e-3;
      expect(lateral(0), closeTo(RoadClass.expressway6.halfWidth, 1e-6));
      expect(lateral(61), closeTo(RoadClass.expressway4.halfWidth, 1e-6));
      // Nothing anywhere lies outside the local edge.
      final total = 300.0;
      for (var v = 0; v < mesh.vertexCount; v++) {
        final s = mesh.positions[v * 3 + 2] / 1e-3;
        final hwAt = s < total - RoadMesher.taperM
            ? RoadClass.expressway6.halfWidth
            : RoadClass.expressway6.halfWidth +
                (RoadClass.expressway4.halfWidth - RoadClass.expressway6.halfWidth) *
                    ((s - (total - RoadMesher.taperM)) / RoadMesher.taperM);
        expect(lateral(v), lessThanOrEqualTo(hwAt + 1e-6));
      }
      // A start taper widens from the given width.
      final w = MeshBuilder();
      RoadMesher.carriageway(w, line(300, samples: 31), anchor,
          RoadClass.expressway6,
          startHalfWidthM: RoadClass.elevated.halfWidth, paint: false);
      final wm = w.build();
      expect(wm.positions[1].abs() / 1e-3, closeTo(RoadClass.elevated.halfWidth, 1e-6));
      expect(wm.positions[61 * 3 + 1].abs() / 1e-3,
          closeTo(RoadClass.expressway6.halfWidth, 1e-6));
    });

    test('sound barriers: a panel per segment each side, gaps at the ends, '
        'posts when detailed, none on a bridge', () {
      final solid = MeshBuilder();
      // 300 m in ten segments: the end gaps swallow the first and last.
      RoadMesher.soundWalls(solid, line(300, samples: 11), anchor, 15.8);
      // 35 m gaps at both ends swallow the first and last segments whole
      // and clip the second and ninth: eight panels a side, twelve
      // triangles each.
      expect(tris(solid), 2 * 8 * 12);
      final posted = MeshBuilder();
      RoadMesher.soundWalls(posted, line(300, samples: 11), anchor, 15.8,
          posts: true);
      expect(tris(posted), greaterThan(tris(solid)));
      // The panels stand outside the carriageway's edge.
      final mesh = solid.build();
      for (var v = 0; v < mesh.vertexCount; v++) {
        expect(mesh.positions[v * 3 + 1].abs() / 1e-3,
            greaterThan(15.8 + RoadMesher.soundWallOffsetM - 0.2));
      }
      // Nothing where the road is on a bridge.
      final bridged = MeshBuilder();
      RoadMesher.soundWalls(bridged, line(300, samples: 11), anchor, 15.8,
          liftAt: (_) => RoadMesher.bridgeHeightM);
      expect(tris(bridged), 0);
      // Too short for its gaps: nothing.
      final short = MeshBuilder();
      RoadMesher.soundWalls(short, line(60, samples: 3), anchor, 15.8);
      expect(tris(short), 0);
    });

    test('the atlas bands are inset from their edges', () {
      final u0 = RoadMesher.bandU(CityTextureBakes.roadWhite, 0);
      final u1 = RoadMesher.bandU(CityTextureBakes.roadWhite, 1);
      final band = 1 / CityTextureBakes.roadBands;
      expect(u0, greaterThan(CityTextureBakes.roadWhite * band));
      expect(u1, lessThan((CityTextureBakes.roadWhite + 1) * band));
    });

    test('a bridge lifts the deck smoothly and stands piers under it', () {
      final ranges = [(100.0, 500.0)];
      expect(RoadMesher.bridgeLiftAt(50, ranges), 0);
      expect(RoadMesher.bridgeLiftAt(300, ranges), RoadMesher.bridgeHeightM);
      final half = RoadMesher.bridgeLiftAt(100 + RoadMesher.bridgeRampM / 2, ranges);
      expect(half, greaterThan(0));
      expect(half, lessThan(RoadMesher.bridgeHeightM));
      final solid = MeshBuilder();
      RoadMesher.piers(solid, line(600, samples: 31), anchor, 12,
          (s) => RoadMesher.bridgeLiftAt(s, ranges));
      expect(tris(solid), greaterThan(0));
    });
  });

  group('junctions', () {
    RoadEnd end(Vector3 at, Vector3 towards, RoadClass cls) =>
        RoadEnd(at, at + towards, cls.halfWidth, cls);
    final o = Vector3.zero;
    final n = Vector3(0, 0, 1), e = Vector3(0, 1, 0);

    test('ends meeting on one point are one junction; two ends are none', () {
      final js = RoadMesher.junctionsFromEnds([
        end(o, n, RoadClass.street),
        end(o, n * -1, RoadClass.street),
        end(o, e, RoadClass.street),
        end(o, e * -1, RoadClass.street),
        // A corner elsewhere: two ends, no junction.
        end(Vector3(0, 0, 500), n, RoadClass.street),
        end(Vector3(0, 0, 503), e, RoadClass.street),
      ]);
      expect(js, hasLength(1));
      expect(js.single.legs, hasLength(4));
      expect(js.single.control, JunctionControl.stop);
    });

    test('a crossing of avenues is signalised and gets masts and heads', () {
      final js = RoadMesher.junctionsFromEnds([
        end(o, n, RoadClass.avenue),
        end(o, n * -1, RoadClass.avenue),
        end(o, e, RoadClass.street),
        end(o, e * -1, RoadClass.street),
      ]);
      expect(js.single.control, JunctionControl.signals);
      final road = MeshBuilder(), poles = MeshBuilder(), lights = MeshBuilder();
      RoadMesher.junctions(road, poles, lights, js, anchor, 0);
      expect(tris(road), greaterThan(8), reason: 'plate, bars and zebras');
      expect(tris(poles), greaterThan(0), reason: 'masts');
      expect(tris(lights), 8, reason: 'one head (a quad) per leg');
    });

    test('a stop crossing gets signs and no heads; plates only without '
        'furniture', () {
      final js = RoadMesher.junctionsFromEnds([
        end(o, n, RoadClass.street),
        end(o, n * -1, RoadClass.street),
        end(o, e, RoadClass.street),
      ]);
      final road = MeshBuilder(), poles = MeshBuilder(), lights = MeshBuilder();
      RoadMesher.junctions(road, poles, lights, js, anchor, 0);
      expect(tris(lights), 0);
      expect(tris(poles), greaterThan(0), reason: 'signs on posts');
      final bare = MeshBuilder(), noPoles = MeshBuilder();
      RoadMesher.junctions(bare, noPoles, MeshBuilder(), js, anchor, 0,
          furniture: false);
      expect(tris(bare), 8, reason: 'the octagonal plate alone');
      expect(tris(noPoles), 0);
    });

    test('a roundabout is a round plate with an island; a merge is nothing',
        () {
      final legs = [
        RoadLeg(n, 3.5, RoadClass.street),
        RoadLeg(n * -1, 3.5, RoadClass.street),
        RoadLeg(e, 3.5, RoadClass.street),
        RoadLeg(e * -1, 3.5, RoadClass.street),
      ];
      final road = MeshBuilder(), poles = MeshBuilder();
      RoadMesher.junctions(road, poles, MeshBuilder(),
          [RoadJunction(o, legs, JunctionControl.roundabout)], anchor, 0);
      // Plate (16) + island top (16) + island face (32) + four yield bars.
      expect(tris(road), 16 + 16 + 32 + 8);
      expect(tris(poles), greaterThan(0), reason: 'keep-right posts');
      final none = MeshBuilder();
      RoadMesher.junctions(none, MeshBuilder(), MeshBuilder(),
          [RoadJunction(o, legs, JunctionControl.merge)], anchor, 0);
      expect(tris(none), 0);
    });

    test('a turning circle is a plate', () {
      final m = MeshBuilder();
      RoadMesher.culDeSac(m, o, anchor, 11);
      expect(tris(m), 12);
    });
  });

  test('sidewalks pull back from their crossings and keep a real run', () {
    final m = MeshBuilder();
    RoadMesher.sidewalks(m, line(100, samples: 5), 4, 3, anchor,
        pullStart: 10, pullEnd: 10);
    expect(tris(m), greaterThan(0));
    final short = MeshBuilder();
    RoadMesher.sidewalks(short, line(12, samples: 3), 4, 3, anchor,
        pullStart: 10, pullEnd: 10);
    expect(tris(short), 0, reason: 'nothing left mid-block');
  });

  group('junctionsFromEnds against the pair scan it replaced', () {
    // Every ends layout below is fed to both the reference scan and the
    // bucketed mesher; the outputs must match junction for junction, leg
    // for leg. The comparison checks identity of the seed point (the node
    // sits ON the seed end, not near it) and value equality of everything
    // else.
    void expectSame(List<RoadJunction> got, List<RoadJunction> want,
        {String? reason}) {
      expect(got, hasLength(want.length), reason: reason);
      for (var k = 0; k < want.length; k++) {
        final g = got[k], w = want[k];
        expect(identical(g.at, w.at), isTrue,
            reason: '${reason ?? ''} junction $k sits on a different end');
        expect(g.control, w.control, reason: reason);
        expect(g.liftM, w.liftM, reason: reason);
        expect(g.legs, hasLength(w.legs.length),
            reason: '${reason ?? ''} junction $k has other legs');
        for (var l = 0; l < w.legs.length; l++) {
          expect(g.legs[l].dir, w.legs[l].dir, reason: reason);
          expect(g.legs[l].halfWidthM, w.legs[l].halfWidthM, reason: reason);
          expect(g.legs[l].roadClass, w.legs[l].roadClass, reason: reason);
          expect(g.legs[l].paved, w.legs[l].paved, reason: reason);
        }
      }
    }

    // A random end: any class, sometimes a collector, sometimes unpaved,
    // and now and then a degenerate direction (next on the end itself) so
    // the leg-skipping path is exercised too.
    RoadEnd randomEnd(math.Random rng, Vector3 at) {
      final cls = RoadClass.values[rng.nextInt(RoadClass.values.length)];
      final len = rng.nextInt(12) == 0 ? 0.0 : 5 + rng.nextDouble() * 40;
      final dir = Vector3(rng.nextDouble() - 0.5, rng.nextDouble() - 0.5,
              (rng.nextDouble() - 0.5) * 0.1)
          .normalized;
      return RoadEnd(at, at + dir * len,
          rng.nextBool() ? cls.halfWidth : 2 + rng.nextDouble() * 20, cls,
          paved: rng.nextInt(5) != 0, collector: rng.nextInt(3) == 0);
    }

    // Ends in clusters sized around the tolerance — tight knots that all
    // group, loose knots whose outliers just miss, chains of ends each a
    // shade under the tolerance apart (so the star-shaped grouping, not a
    // transitive one, is what is being matched), and some singletons —
    // then shuffled, so the greedy seeding order runs across clusters.
    List<RoadEnd> layout(int n, math.Random rng,
        {double tol = 8.0, double spanM = 3000}) {
      final ends = <RoadEnd>[];
      while (ends.length < n) {
        final c = Vector3(rng.nextDouble() * spanM, rng.nextDouble() * spanM,
            (rng.nextDouble() - 0.5) * 40);
        switch (rng.nextInt(4)) {
          case 0:
            // A knot: three to six ends within the tolerance of each other.
            final k = 3 + rng.nextInt(4);
            for (var i = 0; i < k; i++) {
              final r = rng.nextDouble() * tol * 0.45;
              final a = rng.nextDouble() * 2 * math.pi;
              ends.add(randomEnd(rng,
                  c + Vector3(math.cos(a) * r, math.sin(a) * r, 0)));
            }
          case 1:
            // A loose knot: radii straddle the tolerance, so some ends fall
            // inside the seed's reach and some just outside.
            final k = 2 + rng.nextInt(5);
            for (var i = 0; i < k; i++) {
              final r = rng.nextDouble() * tol * 1.6;
              final a = rng.nextDouble() * 2 * math.pi;
              final dz = (rng.nextDouble() - 0.5) * tol * 0.5;
              ends.add(randomEnd(rng,
                  c + Vector3(math.cos(a) * r, math.sin(a) * r, dz)));
            }
          case 2:
            // A chain: each link under the tolerance from the last, the
            // ends two links apart beyond it.
            final k = 3 + rng.nextInt(4);
            final a = rng.nextDouble() * 2 * math.pi;
            final step = Vector3(math.cos(a), math.sin(a), 0) * (tol * 0.8);
            for (var i = 0; i < k; i++) {
              ends.add(randomEnd(rng, c + step * i.toDouble()));
            }
          default:
            ends.add(randomEnd(rng, c));
        }
      }
      ends.shuffle(rng);
      return ends;
    }

    test('several thousand clustered ends group identically', () {
      for (final seed in [1, 2, 3, 7, 42]) {
        final rng = math.Random(seed);
        final ends = layout(4000, rng);
        expectSame(RoadMesher.junctionsFromEnds(ends),
            referenceJunctionsFromEnds(ends),
            reason: 'seed $seed');
        // A wider and a narrower tolerance re-bucket everything.
        for (final tol in [3.0, 12.5]) {
          expectSame(RoadMesher.junctionsFromEnds(ends, toleranceM: tol),
              referenceJunctionsFromEnds(ends, toleranceM: tol),
              reason: 'seed $seed tol $tol');
        }
      }
    });

    test('ends on a planet-sized offset group identically', () {
      // Body-fixed coordinates: the tile sits thousands of kilometres from
      // the origin, where the cell division has the least precision.
      final rng = math.Random(11);
      final local = layout(3000, rng);
      final far = Vector3(6371000, -2400000, 1800000);
      final ends = [
        for (final e in local)
          RoadEnd(e.at + far, e.next + far, e.halfWidthM, e.roadClass,
              paved: e.paved, collector: e.collector),
      ];
      expectSame(RoadMesher.junctionsFromEnds(ends),
          referenceJunctionsFromEnds(ends));
    });

    test('edge cases: exact tolerance, coincident, lone, none, negative', () {
      final n = Vector3(0, 0, 1), e = Vector3(0, 1, 0);
      RoadEnd end(Vector3 at, Vector3 towards, [RoadClass cls = RoadClass.street]) =>
          RoadEnd(at, at + towards, cls.halfWidth, cls);
      // Exactly the tolerance apart is IN (the test is "farther than"),
      // one ulp past it is out; both sit right on a cell boundary.
      final exact = [
        end(Vector3.zero, n),
        end(Vector3(8, 0, 0), e),
        end(Vector3(0, 8, 0), n * -1),
        end(Vector3(0, 0, 8), e * -1),
        end(Vector3(8.000000000001, 0, 0), n),
        end(Vector3(-8, 0, 0), e),
      ];
      final exactGot = RoadMesher.junctionsFromEnds(exact);
      expectSame(exactGot, referenceJunctionsFromEnds(exact));
      expect(exactGot.single.legs, hasLength(5));
      // Ends that lie on one point, plus lone ends far from anything.
      final coincident = [
        for (var i = 0; i < 6; i++) end(Vector3(100, 100, 5), i.isEven ? n : e),
        end(Vector3(500, 500, 0), n),
        end(Vector3(-500, 500, 0), e),
      ];
      expectSame(RoadMesher.junctionsFromEnds(coincident),
          referenceJunctionsFromEnds(coincident));
      // One end, and none.
      expectSame(RoadMesher.junctionsFromEnds([end(Vector3.zero, n)]),
          referenceJunctionsFromEnds([end(Vector3.zero, n)]));
      expectSame(RoadMesher.junctionsFromEnds([]), referenceJunctionsFromEnds([]));
      // A zero tolerance still groups the coincident; a negative one
      // groups nothing at all.
      for (final tol in [0.0, -1.0]) {
        expectSame(RoadMesher.junctionsFromEnds(coincident, toleranceM: tol),
            referenceJunctionsFromEnds(coincident, toleranceM: tol),
            reason: 'tol $tol');
      }
      // A ramp meeting an expressway end-on: two legs, still a merge.
      final merge = [
        end(Vector3.zero, n, RoadClass.ramp),
        end(Vector3(3, 3, 0), e, RoadClass.expressway4),
      ];
      expectSame(RoadMesher.junctionsFromEnds(merge),
          referenceJunctionsFromEnds(merge));
      expect(RoadMesher.junctionsFromEnds(merge).single.control,
          JunctionControl.merge);
    });

    test('COARSE TIMING SANITY: 20k ends stay well under a budget the pair '
        'scan could never meet', () {
      // Not a benchmark — a tripwire. The pair scan is O(N²) and takes
      // seconds here; the bucketed grouping is O(N) in the ends and should
      // be a few tens of milliseconds. The bound is loose enough for a
      // loaded CI box, tight enough that a return to quadratic fails.
      final rng = math.Random(99);
      final ends = layout(20000, rng, spanM: 6000);
      // A warm-up so JIT compilation is not what gets timed.
      RoadMesher.junctionsFromEnds(layout(500, math.Random(5)));
      final sw = Stopwatch()..start();
      final js = RoadMesher.junctionsFromEnds(ends);
      sw.stop();
      expect(js, isNotEmpty);
      expect(sw.elapsedMilliseconds, lessThan(200),
          reason: '20k ends took ${sw.elapsedMilliseconds} ms');
    });
  });
}

/// The pair scan [RoadMesher.junctionsFromEnds] replaced, copied verbatim as
/// the reference the bucketed version must match exactly: for each lowest
/// unused end, every later unused end within the tolerance joins its group
/// in index order.
List<RoadJunction> referenceJunctionsFromEnds(List<RoadEnd> ends,
    {double toleranceM = 8.0}) {
  final out = <RoadJunction>[];
  final used = List<bool>.filled(ends.length, false);
  for (var i = 0; i < ends.length; i++) {
    if (used[i]) continue;
    final at = ends[i].at;
    final group = <RoadEnd>[ends[i]];
    used[i] = true;
    for (var j = i + 1; j < ends.length; j++) {
      if (used[j]) continue;
      if ((ends[j].at - at).length > toleranceM) continue;
      used[j] = true;
      group.add(ends[j]);
    }
    final legs = <RoadLeg>[];
    for (final e in group) {
      final inward = e.next - e.at;
      if (inward.length < 1e-6) continue;
      legs.add(RoadLeg(inward.normalized, e.halfWidthM, e.roadClass,
          paved: e.paved));
    }
    // Where two collectors cross — all four legs collectors, or three at
    // a T — a subdivision builds a roundabout, not a four-way stop.
    final collectors = group.where((e) => e.collector).length;
    final control = junctionControlFor(
        [for (final l in legs) l.roadClass],
        roundaboutPreferred: collectors >= 3);
    if (control == JunctionControl.none) continue;
    out.add(RoadJunction(at, legs, control));
  }
  return out;
}
