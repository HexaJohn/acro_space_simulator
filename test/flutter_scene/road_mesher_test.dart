// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

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
}
