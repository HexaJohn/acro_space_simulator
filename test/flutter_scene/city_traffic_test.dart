// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_traffic.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/elevated_structure.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/rail_vehicles.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/railway.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/coord_convert.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/vehicle_meshes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// The traffic pass builds its tables once and places from them; the
/// per-frame pass it replaced derived everything from the snapshot every
/// frame. Both must agree to the byte, or two clients on different code
/// would see different cars — so the OLD pass is kept here, verbatim, as
/// the reference the tables are held to.
void main() {
  const r = 1.7374e6;
  const body = 'moon';
  // The body root's anchor: a building position, like the real one.
  const anchor = Vector3(0, 0, r);
  const focus = Vector3(300, 300, r + 1000);
  const rangeM = 3500.0;
  const maxVehicles = 600;

  RoadSnapshot road(
    RoadClass cls,
    List<(double, double)> xy, {
    double? halfWidthM,
    bool sealed = false,
    List<double> bridges = const [],
    double? startHalf,
    double? endHalf,
  }) =>
      RoadSnapshot(
        colonyId: 'c',
        body: body,
        points: [for (final (x, y) in xy) ...[x, y, r]],
        halfWidthM: halfWidthM ?? cls.width / 2,
        roadClassIndex: cls.index,
        sealed: sealed,
        bridges: bridges,
        startHalfWidthM: startHalf,
        endHalfWidthM: endHalf,
      );

  List<(double, double)> line(double y, double x0, double x1, int n) =>
      [for (var i = 0; i < n; i++) (x0 + (x1 - x0) * i / (n - 1), y)];

  BuildingSnapshot stop(String id, String type, double x, double y) =>
      BuildingSnapshot(
        id: id,
        type: type,
        colonyId: 'c',
        body: body,
        px: x,
        py: y,
        pz: r,
        qw: 1,
        qx: 0,
        qy: 0,
        qz: 0,
        lat: 0,
        lon: 0,
        siteWidthM: 60,
        siteDepthM: 30,
        siteKindIndex: 0,
        colorArgb: 0xFF808080,
      );

  // One of everything the pass has a rule for.
  final roads = <RoadSnapshot>[
    road(RoadClass.street, line(0, 0, 600, 6)),
    road(RoadClass.avenue, line(100, 0, 800, 5), bridges: [200, 500]),
    road(RoadClass.highway, line(300, 0, 1000, 4)),
    // Tapers: the outer lane is dropped along it.
    road(RoadClass.trunk, line(400, 0, 900, 4), startHalf: 12, endHalf: 9),
    road(RoadClass.ramp, line(500, 0, 400, 3)),
    road(RoadClass.alley, line(600, 0, 450, 3)),
    // A duplicated point: a degenerate segment the walk must step over.
    road(RoadClass.street, const [(0, 700), (200, 700), (200, 700), (400, 700)]),
    // Out of range: gated on its nearer end.
    road(RoadClass.street, line(20000, 0, 600, 4)),
    // Too short to carry anything, and too few points to be a road.
    road(RoadClass.street, line(800, 0, 20, 2)),
    RoadSnapshot(
        colonyId: 'c', body: body, points: const [0, 0, r], halfWidthM: 4,
        roadClassIndex: RoadClass.street.index),
    // The L.
    road(RoadClass.transit, line(900, 0, 900, 7)),
    // The railway, split at two crossings, one piece reversed.
    road(RoadClass.rail, line(1200, 0, 1000, 5)),
    road(RoadClass.rail, line(1200, 2000, 1000, 5)),
    road(RoadClass.rail, line(1200, 2000, 3000, 5)),
    // An airless road runs rovers.
    road(RoadClass.street, line(1400, 0, 500, 4), sealed: true),
  ];
  final buildings = <String, BuildingSnapshot>{
    'st': stop('st', 'station', 500, 1200),
    'fy': stop('fy', 'freightyard', 2500, 1250),
    // A stop on another body, and one too far from the line, are not stops.
    'far': stop('far', 'station', 500, 3000),
    'other': BuildingSnapshot(
      id: 'other',
      type: 'station',
      colonyId: 'c',
      body: 'mars',
      px: 500,
      py: 1200,
      pz: r,
      qw: 1,
      qx: 0,
      qy: 0,
      qz: 0,
      lat: 0,
      lon: 0,
      siteWidthM: 60,
      siteDepthM: 30,
      siteKindIndex: 0,
      colorArgb: 0xFF808080,
    ),
  };

  void expectSame(vm.Matrix4 got, vm.Matrix4 want, String what) {
    for (var i = 0; i < 16; i++) {
      expect(got.storage[i], want.storage[i], reason: '$what [$i]');
    }
  }

  void expectBuffer(
      TrafficBuffer got, List<vm.Matrix4> want, String what) {
    expect(got.count, want.length, reason: '$what count');
    for (var i = 0; i < want.length; i++) {
      expectSame(got.matrices[i], want[i], '$what #$i');
    }
  }

  _Reference run(CityTraffic traffic, double epoch,
      {List<RoadSnapshot>? on, String sig = 'sig'}) {
    traffic.begin(sig);
    traffic.visitTile('$body/0/0/0', 'k', body, on ?? roads, anchor);
    final sink = traffic.place(body, epoch, focus, buildings);
    traffic.end();
    final want = referencePoses(
      roads: on ?? roads,
      bodyId: body,
      anchorBF: anchor,
      focusBF: focus,
      epoch: epoch,
      rangeM: rangeM,
      maxVehicles: maxVehicles,
      density: traffic.density,
      buildings: buildings,
    );
    return _Reference(sink, want);
  }

  test('tables place what the per-frame pass placed, at two epochs', () {
    final traffic = CityTraffic();
    for (final epoch in const [0.0, 1234.5]) {
      final (sink, want) = run(traffic, epoch).pair;
      // Everything the fixture put on the road is on it.
      expect(want.byKind.keys, containsAll(VehicleKind.road));
      expect(want.byKind.keys, contains(VehicleKind.rover));
      expect(want.railCars, isNotEmpty);
      expect(want.trainCars, isNotEmpty);
      expect(sink.byKind.keys.toSet(), want.byKind.keys.toSet());
      for (final kind in want.byKind.keys) {
        expectBuffer(sink.byKind[kind]!, want.byKind[kind]!, '$kind @$epoch');
      }
      expect(sink.railCars.keys.toSet(), want.railCars.keys.toSet());
      for (final kind in want.railCars.keys) {
        expectBuffer(
            sink.railCars[kind]!, want.railCars[kind]!, '$kind @$epoch');
      }
      expectBuffer(sink.trainCars, want.trainCars, 'train @$epoch');
      expect(sink.placed, want.placed);
    }
    // One tile table, built once: the second epoch reused it.
    expect(traffic.tileCount, 1);
  });

  test('the epoch moves the cars', () {
    final traffic = CityTraffic();
    final a = run(traffic, 0.0).sink.byKind[VehicleKind.sedan]!;
    final first = vm.Matrix4.copy(a.matrices[0]);
    final b = run(traffic, 10.0).sink.byKind[VehicleKind.sedan]!;
    expect(b.matrices[0].storage, isNot(orderedEquals(first.storage)));
  });

  test('same input, same output, on a fresh pass or a warm one', () {
    final warm = CityTraffic();
    run(warm, 77.0);
    run(warm, 78.0);
    final a = run(warm, 77.0).sink;
    final b = run(CityTraffic(), 77.0).sink;
    for (final kind in a.byKind.keys) {
      final x = a.byKind[kind]!, y = b.byKind[kind]!;
      expect(x.count, y.count);
      for (var i = 0; i < x.count; i++) {
        expectSame(x.matrices[i], y.matrices[i], '$kind #$i');
      }
    }
  });

  test('the road-vehicle cap never drops a train', () {
    // Enough streets to spend the cap several times over, THEN the rail
    // and the L, in tile order — which the per-frame pass broke out of
    // once the cap was spent, so whether a colony had a train depended on
    // which tile its track happened to be bucketed into.
    final many = <RoadSnapshot>[
      for (var i = 0; i < 60; i++)
        road(RoadClass.street, line(20.0 * i, 0, 1100, 4)),
      road(RoadClass.transit, line(2000, 0, 900, 7)),
      road(RoadClass.rail, line(2200, 0, 3000, 9)),
    ];
    final (sink, want) = run(CityTraffic(), 5.0, on: many).pair;
    expect(sink.placed, maxVehicles);
    expect(want.placed, maxVehicles);
    var cars = 0;
    for (final b in sink.byKind.values) {
      cars += b.count;
    }
    expect(cars, maxVehicles);
    expect(sink.railCars, isNotEmpty);
    expect(sink.trainCars.count, greaterThan(0));
    // The old pass lost both behind the cap.
    expect(want.railCars, isEmpty);
    expect(want.trainCars, isEmpty);
    // The cars it did place are the same cars.
    for (final kind in want.byKind.keys) {
      expectBuffer(sink.byKind[kind]!, want.byKind[kind]!, '$kind');
    }
  });

  test('density rebuilds the tables', () {
    final traffic = CityTraffic();
    // The sink is resident and rewritten in place, so the count is copied.
    final fullCount = run(traffic, 3.0).sink.placed;
    traffic.density = 0.5;
    final (sink, want) = run(traffic, 3.0).pair;
    expect(sink.placed, lessThan(fullCount));
    expect(sink.placed, want.placed);
    for (final kind in want.byKind.keys) {
      expectBuffer(sink.byKind[kind]!, want.byKind[kind]!, '$kind');
    }
  });

  test('the trains equal RailConsist.posesAt over the chained line', () {
    // Independent of the reference: the consist's own timetable, on the
    // one line the three pieces chain into.
    final (sink, _) = run(CityTraffic(), 400.0).pair;
    final pieces = [
      for (final rd in roads)
        if (rd.roadClassIndex == RoadClass.rail.index)
          [
            for (var i = 0; i + 2 < rd.points.length; i += 3)
              Vector3(rd.points[i], rd.points[i + 1], rd.points[i + 2]) - anchor
          ],
    ];
    final chains = Railway.chains(pieces);
    expect(chains, hasLength(1));
    final chain = chains.single;
    final cum = RailConsist.cumulative(chain);
    final station = RailConsist.nearestOn(chain, cum, const Vector3(500, 1200, 0));
    final yard = RailConsist.nearestOn(chain, cum, const Vector3(2500, 1250, 0));
    expect(station.offM, lessThan(160));
    expect(yard.offM, lessThan(160));
    final phase = ((0 * 977 + body.hashCode) % 1000).toDouble();
    final passenger = RailConsist.passenger.posesAt(
      pts: chain,
      anchorBF: anchor,
      epochS: 400.0,
      stopsM: [station.alongM],
      phaseS: phase,
    );
    final freight = RailConsist.freight.posesAt(
      pts: chain,
      anchorBF: anchor,
      epochS: 400.0,
      stopsM: [yard.alongM],
      phaseS: phase + cum.last / RailConsist.freight.speedMs,
    );
    final want = <RailCarKind, List<vm.Matrix4>>{};
    for (final car in [...passenger, ...freight]) {
      (want[car.kind] ??= []).add(vm.Matrix4.compose(
        vm.Vector3(lengthToScene(car.centre.x), lengthToScene(car.centre.y),
            lengthToScene(car.centre.z)),
        quatToScene(Quaternion.fromBasis(car.side, car.along, car.up)),
        vm.Vector3.all(1.0),
      ));
    }
    expect(want, isNotEmpty);
    expect(sink.railCars.keys.toSet(), want.keys.toSet());
    for (final kind in want.keys) {
      expectBuffer(sink.railCars[kind]!, want[kind]!, '$kind');
    }
  });
}

class _Reference {
  const _Reference(this.sink, this.want);
  final TrafficSink sink;
  final ReferencePoses want;
  (TrafficSink, ReferencePoses) get pair => (sink, want);
}

class ReferencePoses {
  final Map<VehicleKind, List<vm.Matrix4>> byKind = {};
  final Map<RailCarKind, List<vm.Matrix4>> railCars = {};
  final List<vm.Matrix4> trainCars = [];
  int placed = 0;
}

/// A road as the old traffic pass saw it.
class _TrafficRoad {
  const _TrafficRoad(this.points, this.roadClassIndex, this.halfWidthM,
      this.sealed, this.overpasses,
      {double? narrowHalfWidthM})
      : narrowHalfWidthM = narrowHalfWidthM ?? halfWidthM;
  final List<double> points;
  final int roadClassIndex;
  final double halfWidthM;
  final bool sealed;
  final double narrowHalfWidthM;
  final List<double> overpasses;
}

/// The per-frame traffic pass as it stood before the tables (one body of
/// `CityNodes._syncTraffic` at f50fd0d), verbatim but for the anchor,
/// which is passed in rather than taken off the first road.
ReferencePoses referencePoses({
  required List<RoadSnapshot> roads,
  required String bodyId,
  required Vector3 anchorBF,
  required Vector3 focusBF,
  required double epoch,
  required double rangeM,
  required int maxVehicles,
  required double density,
  required Map<String, BuildingSnapshot> buildings,
}) {
  final out = ReferencePoses();
  final list = <_TrafficRoad>[];
  for (final r in roads) {
    var narrow = r.halfWidthM;
    for (final w in [r.startHalfWidthM, r.endHalfWidthM]) {
      if (w != null && w < narrow) narrow = w;
    }
    list.add(_TrafficRoad(
        r.points, r.roadClassIndex, r.halfWidthM, r.sealed, r.bridges,
        narrowHalfWidthM: narrow));
  }
  final railSegments = <List<Vector3>>[];
  var placed = 0;
  for (final road in list) {
    if (placed >= maxVehicles) break;
    if (road.points.length < 6) continue;
    final cls = RoadClass
        .values[road.roadClassIndex.clamp(0, RoadClass.values.length - 1)];
    if (cls != RoadClass.rail) {
      final n = road.points.length;
      final a = Vector3(road.points[0], road.points[1], road.points[2]);
      final b =
          Vector3(road.points[n - 3], road.points[n - 2], road.points[n - 1]);
      final near = math.min((a - focusBF).length, (b - focusBF).length);
      if (near > rangeM) continue;
    }
    final pts = <Vector3>[];
    for (var i = 0; i + 2 < road.points.length; i += 3) {
      pts.add(Vector3(road.points[i] - anchorBF.x,
          road.points[i + 1] - anchorBF.y, road.points[i + 2] - anchorBF.z));
    }
    if (pts.length < 2) continue;
    final cum = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum[i - 1] + (pts[i] - pts[i - 1]).length);
    }
    final total = cum.last;
    if (total < 30) continue;
    if (cls == RoadClass.rail) {
      railSegments.add(pts);
      continue;
    }
    if (!cls.carriesCars) {
      for (final car in ElevatedStructure.trainCarPoses(
        pts: pts,
        anchorBF: anchorBF,
        lengthM: total,
        epochS: epoch,
        seed: road.points.length,
      )) {
        out.trainCars.add(vm.Matrix4.compose(
          vm.Vector3(lengthToScene(car.centre.x), lengthToScene(car.centre.y),
              lengthToScene(car.centre.z)),
          quatToScene(Quaternion.fromBasis(car.side, car.along, car.up)),
          vm.Vector3.all(1.0),
        ));
      }
      continue;
    }
    final (spacingM, speed) = switch (cls) {
      RoadClass.street => (110.0, 8.0),
      RoadClass.avenue => (120.0, 13.0),
      RoadClass.highway => (110.0, 22.0),
      RoadClass.elevated => (95.0, 24.0),
      RoadClass.alley => (200.0, 4.0),
      RoadClass.path => (150.0, 6.0),
      RoadClass.trunk => (140.0, 30.0),
      RoadClass.expressway4 => (90.0, 31.0),
      RoadClass.expressway6 => (95.0, 31.0),
      RoadClass.expressway8 => (100.0, 31.0),
      RoadClass.ramp => (160.0, 14.0),
      RoadClass.transit || RoadClass.rail => (0.0, 0.0),
    };
    if (spacingM <= 0) continue;
    final perLane = (total / spacingM * density).floor();
    if (perLane <= 0) continue;
    final family = road.sealed ? VehicleKind.airless : VehicleKind.road;
    final seed = road.points.length * 2654435761 + bodyId.hashCode;
    final layout = cls.lanes;
    final laneScale =
        layout == null ? 1.0 : road.halfWidthM / layout.halfWidthM;
    final drivable =
        road.narrowHalfWidthM - (layout?.shoulderM ?? 0) * laneScale;
    final laneOffsets = [
      for (final o in layout?.laneOffsets ?? [road.halfWidthM * 0.5])
        if (o.abs() * laneScale + 1.0 <= drivable) o
    ];
    final ranges = <(double, double)>[
      for (var i = 0; i + 1 < road.overpasses.length; i += 2)
        (road.overpasses[i], road.overpasses[i + 1]),
    ];
    final oneWay = layout?.oneWay ?? false;
    var stream = 0;
    for (var dirIndex = 0; dirIndex < (oneWay ? 1 : 2); dirIndex++) {
      final dirSign = dirIndex == 0 ? 1.0 : -1.0;
      for (final laneOffset in laneOffsets) {
        final lane = stream++;
        for (var i = 0; i < perLane && placed < maxVehicles; i++) {
          final h = _hash(seed + lane * 7919 + i * 104729);
          final kind = family[h % family.length];
          final phase = (h >> 8 & 0xFFFF) / 65536.0;
          var d = (cum.last * (i + phase) / perLane + dirSign * epoch * speed) %
              total;
          if (d < 0) d += total;
          final at = _alongPolyline(pts, cum, d);
          if (at == null) continue;
          final fwd = at.$2 * dirSign;
          final up = (at.$1 + anchorBF).normalized;
          final side = fwd.cross(up).normalized;
          final lift = cls.deckHeightM + RoadMesher.bridgeLiftAt(d, ranges);
          final offset = side * (laneOffset * laneScale) + up * lift;
          final rot = Quaternion.fromBasis(side, fwd, up);
          (out.byKind[kind] ??= []).add(vm.Matrix4.compose(
            vm.Vector3(
                lengthToScene((at.$1 + offset).x),
                lengthToScene((at.$1 + offset).y),
                lengthToScene((at.$1 + offset).z)),
            quatToScene(rot),
            vm.Vector3.all(1.0),
          ));
          placed++;
        }
      }
    }
  }
  out.placed = placed;
  if (railSegments.isNotEmpty) {
    final stops = <(String, Vector3)>[
      for (final b in buildings.values)
        if (b.body == bodyId &&
            (b.type == 'station' || b.type == 'freightyard'))
          (b.type, Vector3(b.px, b.py, b.pz) - anchorBF),
    ];
    var line = 0;
    for (final chain in Railway.chains(railSegments)) {
      final cum = RailConsist.cumulative(chain);
      if (cum.last < 200) continue;
      final stationsM = <double>[];
      final yardsM = <double>[];
      for (final (type, at) in stops) {
        final n = RailConsist.nearestOn(chain, cum, at);
        if (n.offM > 160) continue;
        (type == 'station' ? stationsM : yardsM).add(n.alongM);
      }
      final phase = ((line++ * 977 + bodyId.hashCode) % 1000).toDouble();
      final siding = cum.last < 900 && stationsM.isEmpty && yardsM.isEmpty;
      final runs = siding
          ? [(RailConsist.freight, const <double>[], 0.0, false)]
          : [
              (RailConsist.passenger, stationsM, phase, true),
              (
                RailConsist.freight,
                yardsM,
                phase + cum.last / RailConsist.freight.speedMs,
                true
              ),
            ];
      for (final (consist, stopsM, phaseS, moving) in runs) {
        for (final car in consist.posesAt(
          pts: chain,
          anchorBF: anchorBF,
          epochS: epoch,
          stopsM: stopsM,
          phaseS: phaseS,
          moving: moving,
          parkedAtM: cum.last / 2 + consist.lengthM / 2,
        )) {
          (out.railCars[car.kind] ??= []).add(vm.Matrix4.compose(
            vm.Vector3(lengthToScene(car.centre.x),
                lengthToScene(car.centre.y), lengthToScene(car.centre.z)),
            quatToScene(Quaternion.fromBasis(car.side, car.along, car.up)),
            vm.Vector3.all(1.0),
          ));
        }
      }
    }
  }
  return out;
}

(Vector3, Vector3)? _alongPolyline(
    List<Vector3> pts, List<double> cum, double d) {
  for (var i = 1; i < pts.length; i++) {
    if (d > cum[i]) continue;
    final seg = pts[i] - pts[i - 1];
    final len = seg.length;
    if (len < 1e-6) continue;
    final t = ((d - cum[i - 1]) / len).clamp(0.0, 1.0);
    return (pts[i - 1] + seg * t, seg.normalized);
  }
  return null;
}

int _hash(int x) {
  var h = x & 0x7FFFFFFF;
  h = (h ^ (h >> 15)) * 0x2C1B3C6D & 0x7FFFFFFF;
  h = (h ^ (h >> 12)) * 0x297A2D39 & 0x7FFFFFFF;
  return h ^ (h >> 15);
}
