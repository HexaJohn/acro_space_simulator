// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/road_tool_scene.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/traffic_lane_speed_overlay.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_overlay_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_overlay_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic_fixture.dart';
import 'bench_support.dart';

/// What the Lane speed view's ribbons cost on the UI thread (docs/plans/
/// agent-traffic.md §13.9, slice 2 "As built": "one overlay line per lane (a
/// big sprawl's rebuild on a band change is unmeasured)"; acea523), on the
/// sprawls the readout bench weighs, with the agents on and their lanes
/// measured.
///
/// Two costs, the frame a lane changes band (at most every 2 s,
/// [LaneSpeedGate]):
///
/// - [TrafficLaneSpeedOverlay.lines]: a first build — every lane's line laid
///   and draped through `RoadToolScene.drape` onto the body's sphere (a flat
///   datum: no terrain raster is sampled, so an in-app drape over a field
///   costs more) — and a rebuild after 10%, 50% and 100% of the lanes changed
///   band, which reuses the drapes and lays a new [OverlayLine] per lane;
/// - [RoadOverlayMesher.build]: the renderer's step that turns
///   [RoadOverlayState]'s lines into the one translucent vertex-coloured mesh
///   `CityNodes._syncRoadOverlay` hands `MeshGeometry.fromArrays` — the
///   whole overlay, on every revision. The upload itself needs a GPU and is
///   not timed here; its size is reported.
///
/// And, to say what a mesher-side path would buy: the builder's floor (the
/// same vertices and quads written with nothing computed), and the mesh's
/// colour stream alone rewritten in place from a table of the bands'
/// colours — what a retained-geometry, recolour-only path would pay.
///
/// The speeds are the agents' own lane graph and lines behind a stand-in
/// [AgentLaneSpeeds] whose percentages and revision the bench sets, so a
/// rebuild changes exactly the lanes it says. Reported only, against a
/// 16.7 ms UI frame, an 8 ms hitch and the city renderer's budgets
/// (`FrameBudget.stallMs` 6 ms, `CityNodes.uploadBudgetMs` 2 ms and
/// `uploadBytesPerFrame` 768 KB); a debug JIT test VM's numbers.
void main() {
  final o = RoadOverlayState.instance;
  setUp(o.clear);
  tearDown(() {
    o.clear();
    AgentTuning.reset();
  });

  for (final miles in const [2, 12]) {
    test('bench: Lane speed ribbons and their mesh, the $miles-mile sprawl '
        '(§13.9)', () {
      _bench(miles, o);
    }, skip: benchSkip, timeout: benchTimeout);
  }
}

void _bench(int miles, RoadOverlayState o) {
  final city = quiet(const CityGenerator().generate(
      CityGenSpec(blocksAcross: 4, seed: 5, sprawlMiles: miles.toDouble()),
      bodies: fixtureBodies));
  final a = agentsOn(city);
  // A minute and a half of agent time: the lanes measured, commuters out.
  runAgents(a, 90);
  final real = a.laneSpeeds;
  expect(real.pct, isNotNull, reason: 'the lanes were measured');
  final speeds = _Speeds(real);
  final n = speeds.laneCount;

  final bodyId = city.body.id.value;
  final radius = city.body.radius;
  final scene = RoadToolScene()
    ..bindCustom(
      bodyId: bodyId,
      toBodyFixed: (p, h) => city.localToBodyFixed(p, bodyRadiusM: radius + h),
      height: (_) => 0,
    );
  var nowUs = 0;
  final view = TrafficLaneSpeedOverlay(clockUs: () => nowUs);
  List<OverlayLine> read() {
    nowUs += LaneSpeedGate.intervalUs;
    speeds.revision++;
    return view.lines(speeds, drape: scene.drape, bodyId: bodyId);
  }

  // First builds: everything laid and draped again.
  final firstMs = <double>[];
  late List<OverlayLine> lines;
  for (var i = 0; i < 8; i++) {
    view.forget();
    final sw = Stopwatch()..start();
    lines = read();
    if (i > 0) firstMs.add(sw.elapsedMicroseconds / 1000);
  }
  var points = 0;
  for (final l in lines) {
    points += l.pointsBF.length;
  }
  final flat = [
    for (var lane = 0; lane < n; lane++) AgentLaneSpeeds.band(speeds.pct[lane]),
  ];
  final bandCounts = List<int>.filled(3, 0);
  for (final b in flat) {
    bandCounts[b]++;
  }
  report('lane ribbons, the $miles-mile sprawl: $n lanes, ${lines.length} '
      'lines, $points points (${f(points / lines.length, 1)} a line); bands '
      'red/amber/green ${bandCounts.join('/')}; ${a.liveVehicles} '
      'vehicles live (JIT test VM)');
  report('  lines(), first build (lay + drape + ribbons): '
      '${_pct(firstMs)}');

  // A read that changes nothing hands back the same list.
  final quietMs = <double>[];
  for (var i = 0; i < 9; i++) {
    final sw = Stopwatch()..start();
    final same = read();
    quietMs.add(sw.elapsedMicroseconds / 1000);
    expect(identical(same, lines), isTrue, reason: 'nothing changed band');
  }
  report('  lines(), a read with every lane in its band: ${_pct(quietMs)}');

  // Rebuilds: a share of the lanes moved to another band, and back.
  final anchor = city.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: radius);
  final rebuildMs = <int, List<double>>{};
  final meshMs = <int, List<double>>{};
  var vertices = 0, triangles = 0;
  RoadOverlayGeometry? built;
  for (final share in const [10, 50, 100]) {
    final changed = [
      for (var lane = 0; lane < n; lane++)
        if ((lane * 7919) % 100 < share) lane,
    ];
    final ms = rebuildMs[share] = <double>[];
    final mesh = meshMs[share] = <double>[];
    // The first of ten is the JIT's: dropped.
    for (var i = 0; i < 10; i++) {
      for (final lane in changed) {
        final p = speeds.pct[lane];
        speeds.pct[lane] = AgentLaneSpeeds.band(p) == 2 ? 30 : 90;
      }
      final before = lines;
      final sw = Stopwatch()..start();
      lines = read();
      final lineMs = sw.elapsedMicroseconds / 1000;
      expect(identical(lines, before), isFalse, reason: 'lanes changed band');

      // What the renderer does with it: the state's lines, meshed whole.
      o
        ..bodyId = bodyId
        ..lines = lines
        ..markers = const []
        ..changed();
      final mw = Stopwatch()..start();
      final g = RoadOverlayMesher.build(o, anchor);
      final meshedMs = mw.elapsedMicroseconds / 1000;
      vertices = g.translucent.vertexCount;
      triangles = g.translucent.triangleCount;
      built = g;
      if (i == 0) continue;
      ms.add(lineMs);
      mesh.add(meshedMs);
    }
    report('  lines(), a rebuild after $share% of lanes (${changed.length}) '
        'changed band: ${_pct(ms)}');
  }
  final allMesh = [for (final m in meshMs.values) ...m];
  final bytes = vertices * (3 + 3 + 2 + 4) * 4 + triangles * 3 * 4;
  report('  RoadOverlayMesher.build, the whole overlay: ${_pct(allMesh)}; '
      '$vertices vertices, $triangles triangles, '
      '${f(bytes / (1024 * 1024), 2)} MB of arrays for one '
      'MeshGeometry.fromArrays');
  final worst = [
    for (final share in const [10, 50, 100])
      for (var i = 0; i < rebuildMs[share]!.length; i++)
        rebuildMs[share]![i] + meshMs[share]![i],
  ];
  report('  a band change on the UI thread (lines + mesh, upload not '
      'included): ${_pct(worst)}; against a 16.7 ms frame, an 8 ms hitch, '
      'the renderer\'s 6 ms stall and 2 ms upload budget, and its 768 KB of '
      'upload a frame');

  // Where the mesher's time goes, and what a colour-only path would cost.
  // The builder's floor: the same vertices and quads written with nothing
  // computed (its `vertex` linearises each channel with `math.pow`).
  final floorMs = <double>[];
  final zero = Vector3(0, 0, 0), up = Vector3(0, 0, 1);
  const bands = [
    TrafficLaneSpeedOverlay.redArgb,
    TrafficLaneSpeedOverlay.amberArgb,
    TrafficLaneSpeedOverlay.greenArgb,
  ];
  for (var i = 0; i < 6; i++) {
    final sw = Stopwatch()..start();
    final m = OverlayMeshBuilder();
    for (var v = 0; v < vertices; v++) {
      m.vertex(zero, up, bands[(v >> 1) % 3]);
    }
    for (var q = 0; q + 1 < triangles; q += 2) {
      m.quad(0, 1, 2, 3);
    }
    if (i > 0) floorMs.add(sw.elapsedMicroseconds / 1000);
  }
  // A retained mesh recoloured in place: the colour stream alone rewritten,
  // a lane's two vertices a point, from a table of the three bands'
  // linear colours.
  final colours = built!.translucent.colors;
  final table = Float32List(12);
  for (var b = 0; b < 3; b++) {
    final argb = bands[b];
    for (var c = 0; c < 3; c++) {
      table[4 * b + c] =
          math.pow(((argb >> (16 - 8 * c)) & 0xFF) / 255.0, 2.2).toDouble();
    }
    table[4 * b + 3] = ((argb >> 24) & 0xFF) / 255.0;
  }
  final recolourMs = <double>[];
  for (var i = 0; i < 6; i++) {
    final sw = Stopwatch()..start();
    var v = 0;
    for (var k = 0; k < lines.length && v < vertices; k++) {
      final b = k < n ? flat[k] : 2;
      final count = 2 * lines[k].pointsBF.length;
      for (var j = 0; j < count && v < vertices; j++, v++) {
        colours[4 * v] = table[4 * b];
        colours[4 * v + 1] = table[4 * b + 1];
        colours[4 * v + 2] = table[4 * b + 2];
        colours[4 * v + 3] = table[4 * b + 3];
      }
    }
    if (i > 0) recolourMs.add(sw.elapsedMicroseconds / 1000);
  }
  report('  of the mesh: the builder\'s floor (vertex + quad, nothing '
      'computed) ${_pct(floorMs)}; the colour stream alone rewritten in '
      'place ${_pct(recolourMs)}, '
      '${f(vertices * 16 / (1024 * 1024), 2)} MB to upload');
}

String _pct(List<double> ms) => 'median ${f(percentile(ms, 0.5))} ms, '
    'worst ${f(percentile(ms, 1))} ms';

/// The agents' lane speeds with percentages and a revision the bench sets:
/// the lane graph and its lines are the agents' own.
class _Speeds implements AgentLaneSpeeds {
  _Speeds(this._real) : pct = Uint8List.fromList(_real.pct!);

  final AgentLaneSpeeds _real;

  @override
  final Uint8List pct;

  @override
  int revision = 0;

  @override
  LaneGraph? get laneGraph => _real.laneGraph;

  @override
  int get graphRev => _real.graphRev;

  @override
  int get laneCount => _real.laneCount;

  @override
  String? roadOfLane(int lane) => _real.roadOfLane(lane);

  @override
  List<Vec2> laneLine(int lane, {double stepM = 6}) =>
      _real.laneLine(lane, stepM: stepM);
}
