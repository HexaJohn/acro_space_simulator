// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A colony's desire paths as the 3D scene draws them
/// (docs/plans/desire-paths.md §5 phase 3): the worn runs of the routes its
/// people have taken lately, as ribbons draped on the ground, and the rovers
/// on their way along them.
///
/// Body-fixed metres, worked out here where the ground is known, so the
/// renderer asks nothing of the terrain. Each ground height is asked once
/// per trail cell, through the colony's own ground cache, which the capture
/// clears where a terrain edit reaches.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../domain/colony/city/city_sim.dart';
import '../../domain/colony/city/parcel.dart';
import '../../domain/colony/city/trails/trail_field.dart';
import '../../domain/colony/city/trails/trail_router.dart';
import '../../domain/shared/vector3.dart';

/// One colony's trails and rovers, for one frame.
class CityTrailFrame {
  const CityTrailFrame({
    required this.colonyId,
    required this.bodyId,
    required this.ribbons,
    required this.rovers,
    this.tubes = const [],
  });

  final String colonyId;
  final String bodyId;

  /// The trails, the SAME object until they change: the renderer rebuilds
  /// its mesh only when this does.
  final TrailRibbons ribbons;

  /// Per rover `[px, py, pz, fx, fy, fz]`: its centre on the ground and its
  /// heading, body-fixed.
  final Float64List rovers;

  /// The pedestrian tubes (desire-paths.md §9): per tube its axis `[x, y,
  /// z, …]`, body-fixed, [kTubeHeightM] over the ground, a point every ten
  /// metres or so. The SAME list until a tube is built.
  final List<Float64List> tubes;
}

/// Worn runs as polylines: per ribbon, its points `[x, y, z, …]` body-fixed
/// on the ground, and its wear (0…1), which sets its width.
class TrailRibbons {
  const TrailRibbons(this.points, this.wear);
  static const empty = TrailRibbons([], []);

  final List<Float64List> points;
  final List<double> wear;
}

/// Wear under which a cell is not drawn: a rover or two's tracks.
const double kTrailDrawnWear = 0.15;

/// Metres a tube's axis stands over the ground: a rover passes under.
const double kTubeHeightM = 5;

class TrailCapture {
  static final Expando<_Cache> _cache = Expando('trailCapture');

  /// Wall-clock milliseconds the ribbons are held before being cut again,
  /// however often wear moves: a trail changes over hours of colony time.
  static int holdMs = 2000;

  /// [city]'s trails, or null when it has none. [groundFor] is the
  /// capture's ground radius under a local point, cached by key; [dirOf]
  /// the body-fixed direction under one; [nowUs] the agents' clock.
  static CityTrailFrame? frameFor(
    CitySim city,
    String bodyId, {
    required double Function(String key, Vec2 local) groundFor,
    required Vector3 Function(Vec2 local) dirOf,
  }) {
    final net = city.trails;
    final f = net?.field;
    if (net == null || f == null) return null;
    final c = _cache[city] ??= _Cache();

    Vector3 onGround(int cell, {double liftM = 0}) {
      final local = f.centreOf(cell);
      final r = groundFor(
          'trail/${local.e.round()},${local.n.round()}', local);
      return dirOf(local) * (r + liftM);
    }

    if (!identical(c.field, f) ||
        (c.wearRev != f.wearRev && c.age.elapsedMilliseconds >= holdMs)) {
      c.field = f;
      c.wearRev = f.wearRev;
      c.age.reset();
      c.ribbons = _ribbons(f, net.takenRoutes, onGround);
    }

    if (c.tubeRev != net.tubeRev || !identical(c.tubeField, f)) {
      c.tubeRev = net.tubeRev;
      c.tubeField = f;
      c.tubes = [
        for (final t in net.tubes)
          _tubeAxis(t, (local) {
            final cell = f.cellAt(local.e, local.n);
            final key = cell < 0
                ? 'tube/${local.e.round()},${local.n.round()}'
                : 'trail/${f.centreE(cell).round()},${f.centreN(cell).round()}';
            return dirOf(local) *
                (groundFor(key, cell < 0 ? local : f.centreOf(cell)) +
                    kTubeHeightM);
          }),
      ];
    }

    final poses = net.roversAt(city.agents.timeUs);
    final rovers = Float64List(poses.length ~/ 4 * 6);
    for (var k = 0, o = 0; k + 3 < poses.length; k += 4, o += 6) {
      final e = poses[k], n = poses[k + 1];
      final cell = f.cellAt(e, n);
      if (cell < 0) continue;
      final p = dirOf(Vec2(e, n)) * groundFor(
          'trail/${f.centreE(cell).round()},${f.centreN(cell).round()}',
          f.centreOf(cell));
      final ahead = dirOf(Vec2(e + poses[k + 2], n + poses[k + 3])) * p.length;
      final fwd = ahead - p;
      rovers
        ..[o] = p.x
        ..[o + 1] = p.y
        ..[o + 2] = p.z
        ..[o + 3] = fwd.x
        ..[o + 4] = fwd.y
        ..[o + 5] = fwd.z;
    }
    return CityTrailFrame(
      colonyId: city.id,
      bodyId: bodyId,
      ribbons: c.ribbons,
      rovers: rovers,
      tubes: c.tubes,
    );
  }

  /// [line]'s axis, a point at least every ten metres along it, each put
  /// in the air by [atLocal].
  static Float64List _tubeAxis(
      List<Vec2> line, Vector3 Function(Vec2 local) atLocal) {
    final pts = <Vector3>[];
    for (var k = 0; k < line.length; k++) {
      if (k == 0) {
        pts.add(atLocal(line[0]));
        continue;
      }
      final a = line[k - 1], b = line[k];
      final n = math.max(1, (a.distanceTo(b) / 10).ceil());
      for (var s = 1; s <= n; s++) {
        pts.add(atLocal(Vec2(
            a.e + (b.e - a.e) * s / n, a.n + (b.n - a.n) * s / n)));
      }
    }
    final out = Float64List(pts.length * 3);
    for (var k = 0; k < pts.length; k++) {
      out
        ..[k * 3] = pts[k].x
        ..[k * 3 + 1] = pts[k].y
        ..[k * 3 + 2] = pts[k].z;
    }
    return out;
  }

  /// The worn runs of [routes] that are not road, each cell drawn once: a
  /// run that reaches cells another already drew is cut there, so two
  /// routes along one trail draw one ribbon, not two fighting for depth.
  /// Points are the cells' centres smoothed over three, so the grid's
  /// staircase reads as a line.
  static TrailRibbons _ribbons(TrailField f, Iterable<TrailRoute> routes,
      Vector3 Function(int cell) onGround) {
    final drawn = <int>{};
    final points = <Float64List>[];
    final wear = <double>[];
    void emit(List<int> run) {
      if (run.length < 3) return;
      final pts = Float64List(run.length * 3);
      var w = 0.0;
      for (var k = 0; k < run.length; k++) {
        final a = run[k > 0 ? k - 1 : k], b = run[k];
        final d = run[k + 1 < run.length ? k + 1 : k];
        final p = (onGround(a) + onGround(b) * 2 + onGround(d)) / 4;
        pts
          ..[k * 3] = p.x
          ..[k * 3 + 1] = p.y
          ..[k * 3 + 2] = p.z;
        w += f.wear[b];
      }
      points.add(pts);
      wear.add(w / run.length);
    }

    for (final r in routes) {
      var run = <int>[];
      for (final i in r.cells) {
        final worn = f.wear[i] >= kTrailDrawnWear && !f.road(i);
        if (worn && !drawn.contains(i)) {
          run.add(i);
          drawn.add(i);
        } else {
          // A drawn neighbour ends this run ON it, so the two meet.
          if (worn && run.isNotEmpty) run.add(i);
          emit(run);
          run = worn ? [i] : <int>[];
        }
      }
      emit(run);
    }
    return TrailRibbons(points, wear);
  }
}

class _Cache {
  TrailField? field;
  int wearRev = -1;
  final Stopwatch age = Stopwatch()..start();
  TrailRibbons ribbons = TrailRibbons.empty;
  int tubeRev = -1;
  TrailField? tubeField;
  List<Float64List> tubes = const [];
}
