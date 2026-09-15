// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';

import 'package:acro_space_simulator/application/snapshot/traffic_capture.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_join.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart'
    show NodeControlKind;
import 'package:acro_space_simulator/domain/colony/city/traffic/node_control.dart'
    as nc;
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';

/// Kerb windows (docs/plans/site-access.md §3.2, slice R1): where on a piece
/// a kerb cut may go, whatever the player overrides.
void main() {
  const eps = 1e-9;

  /// The windows of the piece of [g] whose road is [roadId], as pairs.
  List<(double, double)> windowsOf(RoadGraph g, String roadId) {
    final r = g.roadNoOf(roadId)!;
    final w = g.kerbWindows;
    return [
      for (var p = g.roadFirstPiece[r]; p < g.roadFirstPiece[r + 1]; p++)
        for (var k = w.start[p]; k < w.start[p + 1]; k++) (w.lo[k], w.hi[k]),
    ];
  }

  void expectWindows(List<(double, double)> actual,
      List<(double, double)> expected) {
    expect(actual.length, expected.length, reason: '$actual vs $expected');
    for (var i = 0; i < actual.length; i++) {
      expect(actual[i].$1, closeTo(expected[i].$1, 1e-6), reason: '$actual');
      expect(actual[i].$2, closeTo(expected[i].$2, 1e-6), reason: '$actual');
    }
  }

  group('pins against the sources they copy', () {
    test('the reserve constants are node_control\'s', () {
      expect(kReservePlatePerHalfWidth, nc.kPlateRadiusPerHalfWidth);
      expect(kReserveStopBarAt, nc.kStopBarAt);
      expect(kReserveRoundaboutMinRadiusM, nc.kRoundaboutMinRadiusM);
      expect(kReserveYieldLineAt, nc.kYieldLineAt);
      // The roundabout radius formula, max(14, 2·hw + 6), at a few widths.
      for (final hw in [2.0, 4.0, 8.0, 11.5]) {
        expect(
          nc.stopBackOf(NodeControlKind.roundabout, hw),
          closeTo(
              (hw * kReserveRoundaboutPerHalfWidth + kReserveRoundaboutExtraM <
                          kReserveRoundaboutMinRadiusM
                      ? kReserveRoundaboutMinRadiusM
                      : hw * kReserveRoundaboutPerHalfWidth +
                          kReserveRoundaboutExtraM) *
                  kReserveYieldLineAt,
              eps),
        );
      }
      expect(kJoinTaperM, TrafficCapture.taperM);
    });

    test('the cul-de-sac radius and the pavement pull-back are the tiles\'',
        () {
      final src = File(
              'lib/infrastructure/flutter_scene/city/city_tile_mesher.dart')
          .readAsStringSync();
      final radii = RegExp(r'RoadMesher\.culDeSac\([^;]*?,\s*([0-9.]+)\s*[,)]')
          .allMatches(src)
          .map((m) => double.parse(m.group(1)!))
          .toList();
      expect(radii, hasLength(2), reason: 'both cul-de-sac calls found');
      expect(radii, everyElement(kCulDeSacRadiusM));
      final pull = RegExp(r'e\.\$1 \* ([0-9.]+) \+ ([0-9.]+)').firstMatch(src)!;
      expect(double.parse(pull.group(1)!), kReservePlatePerHalfWidth);
      expect(double.parse(pull.group(2)!), kReservePavementPullBackM);
    });
  });

  group('node reserve', () {
    test('a street crossing reserves 11.3 m, a street dead end 12 m', () {
      final g = starterKit().roadGraph;
      final crossing = g.nodeNear(const Vec2(0, 0))!;
      expect(nodeReserveM(crossing), closeTo(4 * 1.45 + 5.5, eps));
      expect(nodeReserveM(crossing), closeTo(11.3, eps));
      final end = g.nodeNear(const Vec2(0, 300))!;
      expect(end.legs, hasLength(1));
      expect(nodeReserveM(end), kCulDeSacRadiusM + kCutFlareM);
      expect(nodeReserveM(end), 12.0);
    });

    test('a dead end of anything but a street reserves nothing', () {
      final layout = CityLayout()
        ..addRoad(const RoadSpline(
            id: 'r0',
            controls: [Vec2(0, 0), Vec2(0, 400)],
            roadClass: RoadClass.avenue));
      final g = RoadGraph.of(layout);
      for (final n in g.nodes) {
        expect(nodeReserveM(n), 0);
      }
      expectWindows(windowsOf(g, 'r0'), [(6.0, 394.0)]);
    });

    test('the reserve covers every control an override can give, and a '
        'roundabout\'s yield line', () {
      for (final c in RoadClass.values) {
        final hw = c.halfWidth;
        for (final kind in NodeControlKind.values) {
          if (kind == NodeControlKind.roundabout) continue;
          expect(hw * kReservePlatePerHalfWidth + kReservePavementPullBackM,
              greaterThanOrEqualTo(nc.stopBackOf(kind, hw)),
              reason: '$c $kind');
        }
      }
      final core = const CityGenerator()
          .generate(const CityGenSpec(blocksAcross: 4, seed: 5, sprawlMiles: 2),
              bodies: fixtureBodies)
          .roadGraph;
      var roundabouts = 0;
      for (final n in core.nodes) {
        if (n.legs.length < 2) continue;
        final r = nodeReserveM(n);
        final kind = nc.controlKindOf(n);
        expect(r, greaterThanOrEqualTo(nc.stopBackOf(kind, nc.junctionHalfWidthOf(n))),
            reason: 'node ${n.id} $kind');
        if (n.control == JunctionControl.roundabout) {
          roundabouts++;
          expect(r, greaterThanOrEqualTo(
              nc.stopBackOf(NodeControlKind.roundabout, nc.junctionHalfWidthOf(n))));
        }
      }
      expect(roundabouts, greaterThan(0), reason: 'the sprawl has roundabouts');
    });
  });

  group('windows', () {
    test('the starter kit\'s north and south pieces', () {
      final g = starterKit().roadGraph;
      // North: from the crossing (11.3) to the street end (12).
      expectWindows(windowsOf(g, 'r0x1'), [(17.3, 282.0)]);
      // South, drawn from its dead end at n = −300 to the crossing.
      expectWindows(windowsOf(g, 'r0x0'), [(18.0, 282.7)]);
    });

    test('no cut within the drawn cul-de-sac: a street end\'s window starts '
        '12 + 6 m in', () {
      final g = starterKit().roadGraph;
      final ends = [for (final n in g.nodes) if (n.legs.length == 1) n];
      expect(ends, isNotEmpty);
      for (var p = 0; p < g.pieceCount; p++) {
        final w = g.kerbWindows;
        for (var k = w.start[p]; k < w.start[p + 1]; k++) {
          if (g.nodes[g.pieceFrom[p]].legs.length == 1) {
            expect(w.lo[k] - g.pieceS0[p], greaterThanOrEqualTo(18 - eps));
          }
          if (g.nodes[g.pieceTo[p]].legs.length == 1) {
            expect(g.pieceS1[p] - w.hi[k], greaterThanOrEqualTo(18 - eps));
          }
        }
      }
    });

    test('a lot beside a sprawl cul-de-sac gets no cut inside the bulb', () {
      final city = const CityGenerator().generate(
          const CityGenSpec(blocksAcross: 4, seed: 5, sprawlMiles: 2),
          bodies: fixtureBodies);
      final g = city.roadGraph;
      var checked = 0;
      for (var j = 0; j < g.joinCount; j++) {
        if (g.joinFlags[j] & kJoinCut == 0) continue;
        final p = g.joinPiece[j];
        final road = g.roads[g.pieceRoad[p]];
        if (road.roadClass != RoadClass.street) continue;
        for (final (node, arc) in [
          (g.nodes[g.pieceFrom[p]], g.pieceS0[p]),
          (g.nodes[g.pieceTo[p]], g.pieceS1[p]),
        ]) {
          if (node.legs.length != 1) continue;
          checked++;
          final gap = (g.joinS[j] - arc).abs() - g.joinRoomM[j];
          expect(gap, greaterThanOrEqualTo(kCulDeSacRadiusM + kCutFlareM + 6 - 1e-4),
              reason: 'slot $j on ${road.id}');
        }
      }
      expect(checked, greaterThan(100), reason: 'the sprawl has cul-de-sacs');
    });

    test('bridges, deck stretches off the ground or off grade, tunnels and '
        'tapers take no cut', () {
      final layout = CityLayout()
        ..addRoad(const RoadSpline(
            id: 'bridged',
            controls: [Vec2(0, 0), Vec2(600, 0)],
            bridges: [(200, 240)]))
        ..addRoad(const RoadSpline(
            id: 'decked',
            controls: [Vec2(0, 1000), Vec2(600, 1000)],
            deck: RoadDeck(
                startM: 0,
                endM: 0,
                structures: [(100, 150)],
                tunnels: [(300, 320)])))
        ..addRoad(const RoadSpline(
            id: 'graded',
            controls: [Vec2(0, 2000), Vec2(400, 2000)],
            deck: RoadDeck(startM: 0, endM: 4, endOffsetM: 4)))
        ..addRoad(const RoadSpline(
            id: 'tapered',
            controls: [Vec2(0, 3000), Vec2(600, 3000)],
            startHalfWidthM: 6));
      final g = RoadGraph.of(layout);
      // Each a street between two dead ends: [18, L − 18] before exclusions.
      expectWindows(windowsOf(g, 'bridged'), [(18, 197), (243, 582)]);
      expectWindows(windowsOf(g, 'decked'), [(18, 100), (150, 300), (320, 582)]);
      // The elevation above the ground reaches 0.5 m at 50 m of 400.
      expectWindows(windowsOf(g, 'graded'), [(18, 50)]);
      expectWindows(windowsOf(g, 'tapered'), [(90, 582)]);
      // Every slot on them keeps its whole cut inside a window.
      for (var j = 0; j < g.joinCount; j++) {
        if (g.joinFlags[j] & kJoinCut == 0) continue;
        expect(g.kerbWindows.roomAt(g.joinPiece[j], g.joinS[j]),
            greaterThanOrEqualTo(kJoinMinRoomM));
      }
    });

    test('a piece shorter than its reserves and clears has no window', () {
      final layout = CityLayout();
      for (final x in [0.0, 30.0]) {
        layout.commitRoad(controls: [Vec2(x, -200), Vec2(x, 200)]);
      }
      layout.commitRoad(controls: const [Vec2(-200, 0), Vec2(230, 0)]);
      final g = RoadGraph.of(layout);
      // The 30 m piece between the two crossings.
      final between = [
        for (var p = 0; p < g.pieceCount; p++)
          if (g.nodes[g.pieceFrom[p]].legs.length == 4 &&
              g.nodes[g.pieceTo[p]].legs.length == 4)
            p
      ];
      expect(between, hasLength(1));
      expect(g.kerbWindows.countOf(between.single), 0);
    });

    test('windows and slots are shared by a graph under new overrides', () {
      final city = starterKit();
      final g = city.roadGraph;
      final o = g.withOverrides(
          const [JunctionOverride(at: Vec2(0, 0), lights: true)]);
      expect(identical(o, g), isFalse);
      expect(o.nodeNear(const Vec2(0, 0))!.control, JunctionControl.signals);
      expect(identical(o.kerbWindows, g.kerbWindows), isTrue);
      expect(identical(o.joinS, g.joinS), isTrue);
      expect(identical(o.lotJoinStart, g.lotJoinStart), isTrue);
      expect(o.sharesStructureWith(g), isTrue);
      // A fresh build under the override places every slot alike.
      final fresh = RoadGraph.of(city.layout,
          overrides: const [JunctionOverride(at: Vec2(0, 0), lights: true)]);
      expect(fresh.joinS, g.joinS);
      expect(fresh.joinPiece, g.joinPiece);
      expect(fresh.kerbWindows.lo, g.kerbWindows.lo);
      expect(fresh.kerbWindows.hi, g.kerbWindows.hi);
    });
  });
}
