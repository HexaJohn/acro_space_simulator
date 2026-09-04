// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The ground railway: the track, and the trains that run it.
///
/// Track geometry is emitted by the road pass exactly as a ribbon is; the
/// trains ride the traffic pass as instanced rolling stock. Everything here
/// that is not a mesh emitter is pure — chains, schedules, poses — so the
/// timetable can be tested without a scene.
library;

import 'dart:math' as math;

import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'rail_vehicles.dart';

/// The pose of one car of a train on the line.
typedef RailCarPose = ({
  RailCarKind kind,
  Vector3 centre,
  Vector3 side,
  Vector3 along,
  Vector3 up,
});

/// A train as a list of vehicles, with how it runs.
class RailConsist {
  const RailConsist(this.cars, {required this.speedMs, required this.dwellS});

  /// A locomotive and four coaches, calling at every station.
  static const passenger = RailConsist(
    [
      RailCarKind.loco,
      RailCarKind.coach,
      RailCarKind.coach,
      RailCarKind.coach,
      RailCarKind.coach,
    ],
    speedMs: 30,
    dwellS: 24,
  );

  /// A locomotive and a mixed rake of wagons, calling at the yard.
  static const freight = RailConsist(
    [
      RailCarKind.loco,
      RailCarKind.boxcar,
      RailCarKind.boxcar,
      RailCarKind.tanker,
      RailCarKind.tanker,
      RailCarKind.flatcar,
      RailCarKind.flatcar,
      RailCarKind.hopper,
      RailCarKind.hopper,
      RailCarKind.boxcar,
    ],
    speedMs: 19,
    dwellS: 45,
  );

  final List<RailCarKind> cars;
  final double speedMs;

  /// How long the train stands at each stop.
  final double dwellS;

  /// Gap between coupled cars.
  static const double couplingM = 1.1;

  double get lengthM {
    var l = 0.0;
    for (final c in cars) {
      l += c.lengthM;
    }
    return l + couplingM * (cars.length - 1);
  }

  /// Where the head of the train is, [lengthM] along a line with stops at
  /// [stopsM] (arc lengths, any order), at [epochS] — and which way it is
  /// going. A shuttle: it runs the line end to end, standing [dwellS] at each
  /// stop, then comes back the same way, so there is never a jump.
  ///
  /// Pure: derived from the epoch, so every client sees the same train in
  /// the same place, and a paused clock is a stopped train.
  ({double headM, double direction}) headAt({
    required double lineM,
    required List<double> stopsM,
    required double epochS,
    double phaseS = 0,
  }) {
    if (lineM <= 0 || speedMs <= 0) return (headM: 0, direction: 1);
    final stops = [for (final s in stopsM) s.clamp(0.0, lineM)]..sort();
    final oneWayS = lineM / speedMs + dwellS * stops.length;
    final cycleS = oneWayS * 2;
    var tau = (epochS + phaseS) % cycleS;
    if (tau < 0) tau += cycleS;
    final forward = tau < oneWayS;
    if (!forward) tau = cycleS - tau;
    // Walk the timetable: travel to each stop, stand, travel on.
    var acc = 0.0;
    var from = 0.0;
    for (final s in stops) {
      final travel = (s - from) / speedMs;
      if (tau < acc + travel) {
        return (headM: from + (tau - acc) * speedMs, direction: forward ? 1 : -1);
      }
      acc += travel;
      if (tau < acc + dwellS) return (headM: s, direction: forward ? 1 : -1);
      acc += dwellS;
      from = s;
    }
    final head = (from + (tau - acc) * speedMs).clamp(0.0, lineM);
    return (headM: head, direction: forward ? 1 : -1);
  }

  /// Every car's pose on [pts] (anchor-relative metres) at [epochS].
  ///
  /// The head leads in the direction of travel; the rest trail behind it,
  /// each centred on its own slot. Cars that would hang off the start of the
  /// line before the train has fully entered are simply not drawn.
  List<RailCarPose> posesAt({
    required List<Vector3> pts,
    required Vector3 anchorBF,
    required double epochS,
    List<double> stopsM = const [],
    double phaseS = 0,
    bool moving = true,
    double parkedAtM = 0,
  }) {
    if (pts.length < 2) return const [];
    final cum = cumulative(pts);
    final lineM = cum.last;
    if (lineM < lengthM + 10) return const [];
    final double head;
    final double dir;
    if (moving) {
      final h = headAt(lineM: lineM, stopsM: stopsM, epochS: epochS, phaseS: phaseS);
      head = h.headM;
      dir = h.direction;
    } else {
      head = parkedAtM.clamp(lengthM, lineM);
      dir = 1;
    }
    final out = <RailCarPose>[];
    var offset = 0.0;
    for (final kind in cars) {
      final s = head - dir * (offset + kind.lengthM / 2);
      offset += kind.lengthM + couplingM;
      if (s < 0 || s > lineM) continue;
      final at = pointAt(pts, cum, s);
      final ahead = pointAt(pts, cum, (s + 2.0).clamp(0.0, lineM));
      final behind = pointAt(pts, cum, (s - 2.0).clamp(0.0, lineM));
      final d = ahead - behind;
      if (d.length < 1e-6) continue;
      final along = d.normalized * dir;
      final up = (at + anchorBF).normalized;
      final side = along.cross(up).normalized;
      out.add((
        kind: kind,
        centre: at + up * RailVehicleMeshes.railHeadM,
        side: side,
        along: along,
        up: up,
      ));
    }
    return out;
  }

  /// Cumulative arc length at each point of a polyline.
  static List<double> cumulative(List<Vector3> pts) {
    final cum = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum[i - 1] + (pts[i] - pts[i - 1]).length);
    }
    return cum;
  }

  /// The point [s] metres along [pts].
  static Vector3 pointAt(List<Vector3> pts, List<double> cum, double s) {
    if (s <= 0) return pts.first;
    for (var i = 1; i < pts.length; i++) {
      if (cum[i] >= s) {
        final seg = cum[i] - cum[i - 1];
        final t = seg < 1e-9 ? 0.0 : (s - cum[i - 1]) / seg;
        return pts[i - 1] + (pts[i] - pts[i - 1]) * t;
      }
    }
    return pts.last;
  }

  /// Arc length of the point on [pts] nearest [p], and how far off it is.
  static ({double alongM, double offM}) nearestOn(
      List<Vector3> pts, List<double> cum, Vector3 p) {
    var bestS = 0.0;
    var bestD = double.infinity;
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1], b = pts[i];
      final ab = b - a;
      final len2 = ab.lengthSquared;
      final t = len2 < 1e-12 ? 0.0 : ((p - a).dot(ab) / len2).clamp(0.0, 1.0);
      final q = a + ab * t;
      final d = (p - q).length;
      if (d < bestD) {
        bestD = d;
        bestS = cum[i - 1] + (cum[i] - cum[i - 1]) * t;
      }
    }
    return (alongM: bestS, offM: bestD);
  }
}

/// The track, and the joining-up of a line the network split at crossings.
class Railway {
  const Railway._();

  /// Standard gauge, half.
  static const double halfGaugeM = 0.7175;

  /// Stitch rail segments that share an end into whole lines.
  ///
  /// The network splits every road at its crossings, so a mainline that a
  /// trunk road and two streets cross arrives as five pieces. A train has to
  /// run the whole line, so pieces whose ends coincide are chained, either
  /// way round, greedily — a few segments, so nothing cleverer is needed.
  static List<List<Vector3>> chains(List<List<Vector3>> segments,
      {double joinM = 3.0}) {
    final pool = [
      for (final s in segments)
        if (s.length >= 2) List<Vector3>.of(s)
    ];
    final out = <List<Vector3>>[];
    while (pool.isNotEmpty) {
      final chain = pool.removeLast();
      var grew = true;
      while (grew) {
        grew = false;
        for (var i = 0; i < pool.length; i++) {
          final seg = pool[i];
          if ((seg.first - chain.last).length <= joinM) {
            chain.addAll(seg.skip(1));
          } else if ((seg.last - chain.last).length <= joinM) {
            chain.addAll(seg.reversed.skip(1));
          } else if ((seg.last - chain.first).length <= joinM) {
            chain.insertAll(0, seg.take(seg.length - 1));
          } else if ((seg.first - chain.first).length <= joinM) {
            chain.insertAll(0, seg.reversed.take(seg.length - 1));
          } else {
            continue;
          }
          pool.removeAt(i);
          grew = true;
          break;
        }
      }
      out.add(chain);
    }
    return out;
  }

  /// The track along [pts] (anchor-relative metres): a ballast bed, concrete
  /// sleepers, and two rails at standard gauge on top.
  ///
  /// Ballast into [ballast] (the dirt material), sleepers into [concrete],
  /// rails into [steel]. Sleepers are spaced coarser than real (2.4 m
  /// against 0.6) because from anywhere a colony is looked at they read as
  /// a rhythm, not as individual timbers, and a real spacing would put a
  /// hundred thousand triangles under one line.
  static void emit(
    MeshBuilder ballast,
    MeshBuilder concrete,
    MeshBuilder steel, {
    required List<Vector3> pts,
    required Vector3 anchorBF,
    required double halfWidthM,
  }) {
    if (pts.length < 2) return;
    const bedTop = 0.30;
    const sleeperTop = 0.46;
    const railTop = RailVehicleMeshes.railHeadM;
    const railHalf = 0.035;
    final shoulder = halfWidthM + 0.7;

    // Frames along the line, one per point.
    final frames = <({Vector3 p, Vector3 side, Vector3 up})>[];
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      final up = (p + anchorBF).normalized;
      final ahead = i + 1 < pts.length ? pts[i + 1] - p : p - pts[i - 1];
      final along = ahead.length > 1e-6 ? ahead.normalized : Vector3.unitX;
      final side = along.cross(up).normalized;
      frames.add((p: p, side: side, up: up));
    }

    Vector3 sp(Vector3 m) => m * kRenderScale;

    // A strip between two lateral offsets (metres off the centreline) at
    // two heights, the length of the line. [normalUp] is the strip's facing.
    void strip(MeshBuilder m, double offA, double hA, double offB, double hB,
        double uA, double uB) {
      int? prevA, prevB;
      var v = 0.0;
      for (var i = 0; i < frames.length; i++) {
        final f = frames[i];
        if (i > 0) v += (f.p - frames[i - 1].p).length / 8.0;
        final a = f.p + f.side * offA + f.up * hA;
        final b = f.p + f.side * offB + f.up * hB;
        // Facing: perpendicular to the strip, leaning up.
        final across = (b - a);
        final n = across.length < 1e-9
            ? f.up
            : f.up.cross(across.normalized.cross(f.up)).normalized;
        final ia = m.vertex(sp(a), n, uA, v);
        final ib = m.vertex(sp(b), n, uB, v);
        if (prevA != null && prevB != null) m.quad(prevA, prevB, ib, ia);
        prevA = ia;
        prevB = ib;
      }
    }

    // Ballast: top and two shoulders.
    strip(ballast, -halfWidthM, bedTop, halfWidthM, bedTop, 0, 1);
    strip(ballast, -shoulder, 0, -halfWidthM, bedTop, 0, 0.2);
    strip(ballast, halfWidthM, bedTop, shoulder, 0, 0.8, 1);

    // Rails: a head and two webs each.
    for (final g in const [-halfGaugeM, halfGaugeM]) {
      strip(steel, g - railHalf, railTop, g + railHalf, railTop, 0.5, 0.5);
      strip(steel, g - railHalf, sleeperTop, g - railHalf, railTop, 0.5, 0.5);
      strip(steel, g + railHalf, railTop, g + railHalf, sleeperTop, 0.5, 0.5);
    }

    // Sleepers: a box top and two long sides, every 2.4 m.
    const pitch = 2.4;
    const sleeperHalfL = 1.25;
    const sleeperHalfW = 0.13;
    final cum = RailConsist.cumulative(pts);
    for (var s = pitch / 2; s < cum.last; s += pitch) {
      final at = RailConsist.pointAt(pts, cum, s);
      final ahead = RailConsist.pointAt(pts, cum, math.min(cum.last, s + 1));
      final behind = RailConsist.pointAt(pts, cum, math.max(0, s - 1));
      final d = ahead - behind;
      if (d.length < 1e-6) continue;
      final along = d.normalized;
      final up = (at + anchorBF).normalized;
      final side = along.cross(up).normalized;
      final c = [
        at - side * sleeperHalfL - along * sleeperHalfW,
        at + side * sleeperHalfL - along * sleeperHalfW,
        at + side * sleeperHalfL + along * sleeperHalfW,
        at - side * sleeperHalfL + along * sleeperHalfW,
      ];
      final top = [
        for (final p in c)
          concrete.vertex(sp(p + up * sleeperTop), up, 0.5, 0.5)
      ];
      concrete.quad(top[0], top[1], top[2], top[3]);
      for (final (i0, i1, n) in [(0, 1, along * -1), (3, 2, along)]) {
        final lo0 = concrete.vertex(sp(c[i0] + up * bedTop), n, 0.5, 0);
        final lo1 = concrete.vertex(sp(c[i1] + up * bedTop), n, 0.5, 0);
        final hi1 = concrete.vertex(sp(c[i1] + up * sleeperTop), n, 0.5, 1);
        final hi0 = concrete.vertex(sp(c[i0] + up * sleeperTop), n, 0.5, 1);
        if (n.dot(along) > 0) {
          concrete.quad(lo0, lo1, hi1, hi0);
        } else {
          concrete.quad(lo1, lo0, hi0, hi1);
        }
      }
    }
  }
}
