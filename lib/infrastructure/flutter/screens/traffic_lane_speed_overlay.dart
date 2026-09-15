// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The Traffic tool's Lane speed view (docs/plans/agent-traffic.md §13.9,
/// §18 slice 2 as agreed with the road side): a ribbon down every lane,
/// green where traffic runs near the limit, amber where it slows, red where
/// it crawls — and the legend row that says so.
///
/// The road tool owns the Traffic tool, its tabs and its overlay; this file
/// is what its fourth view calls. `RoadToolScene.showTraffic` hands the
/// lines built here to [RoadOverlayState] the way its Routes view hands its
/// route lines, and `TrafficToolPanel` shows [TrafficLaneSpeedLegend] under
/// the tab. The data is the agents' own ([AgentLaneSpeeds]), read straight
/// off the domain as the road tool reads `trafficReadout`: nothing new rides
/// the wire.
///
/// It costs almost nothing between rebuilds, and rebuilds rarely:
/// - the speeds are re-read only when [AgentLaneSpeeds.revision] or the
///   lane graph moves, and at most once every [LaneSpeedGate.intervalUs]
///   (0.5 Hz) — the agents publish once an epoch (2 s) anyway, and the
///   renderer re-meshes the whole overlay on every change;
/// - a re-read that leaves every lane in its band hands back the very list
///   drawn last time, so the overlay is not republished at all;
/// - the ribbons' draped points are laid once per lane graph and ground,
///   and a change of colour reuses them.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/colony/city/traffic/city_agents.dart';
import '../../../domain/shared/vector3.dart';
import '../../flutter_scene/city/road_overlay_state.dart';

/// When the Lane speed view may read the speeds again: when they, the lane
/// graph or the ground moved — and never sooner than [intervalUs] after the
/// last read, so a busy colony cannot make the overlay re-mesh faster than
/// 0.5 Hz. The first read is always due.
class LaneSpeedGate {
  /// Two seconds: one congestion epoch.
  static const int intervalUs = 2000000;

  int _revision = -1, _graphRev = -1;
  Object? _groundKey;
  int? _atUs;

  /// Reads granted so far.
  int reads = 0;

  /// Whether a view showing [revision] of lane graph [graphRev] on
  /// [groundKey] should read again at [nowUs]. Allocates nothing: the flight
  /// view asks every frame the view is open.
  bool due(int revision, int graphRev, int nowUs, [Object? groundKey]) {
    final at = _atUs;
    if (at == null) return true;
    if (revision == _revision &&
        graphRev == _graphRev &&
        groundKey == _groundKey) {
      return false;
    }
    return nowUs - at >= intervalUs;
  }

  /// A read taken at [nowUs] of what [due] was asked about.
  void took(int revision, int graphRev, int nowUs, [Object? groundKey]) {
    _revision = revision;
    _graphRev = graphRev;
    _groundKey = groundKey;
    _atUs = nowUs;
    reads++;
  }

  /// Forget the last read: the next is due at once.
  void reset() {
    _atUs = null;
    _revision = -1;
    _graphRev = -1;
    _groundKey = null;
  }
}

/// The Lane speed view's ribbons, kept between refreshes.
class TrafficLaneSpeedOverlay {
  TrafficLaneSpeedOverlay({int Function()? clockUs})
      : _clockUs = clockUs ?? _wallUs;

  /// The overlay of the road tool's scene [scene] — one per flight view, as
  /// the scene is, without a field on it.
  static TrafficLaneSpeedOverlay of(Object scene) =>
      _perScene[scene] ??= TrafficLaneSpeedOverlay();
  static final Expando<TrafficLaneSpeedOverlay> _perScene =
      Expando<TrafficLaneSpeedOverlay>('lane speed');

  static final Stopwatch _wall = Stopwatch()..start();
  static int _wallUs() => _wall.elapsedMicroseconds;
  final int Function() _clockUs;

  // ---- Look --------------------------------------------------------------------

  /// Band colours, 0xAARRGGBB: the palette the road ghost already reads
  /// good, careful and refused in.
  static const int greenArgb = 0xD943A047;
  static const int amberArgb = 0xD9FFB300;
  static const int redArgb = 0xD9E53935;

  /// A ribbon a little narrower than a lane, so two lanes side by side read
  /// as two; over the route lines (0.9 m) and the road surface.
  static const double ribbonWidthM = 2.2;
  static const double ribbonLiftM = 0.95;

  /// A point along a lane at least this often: enough for a ribbon to lie
  /// on rolling ground, few enough that a sprawl's lanes mesh quickly.
  static const double stepM = 10;

  /// How far a draped point may sit off the straight line between the
  /// points kept either side of it before it must be kept: well under the
  /// ribbon's lift, so a ribbon dropped to its corners still clears the road.
  static const double simplifyTolM = 0.15;

  /// The most samples one straight run of a ribbon may span.
  static const int maxRun = 16;

  /// [pts] with the points a straight ribbon would pass within
  /// [simplifyTolM] of dropped. The mesher's cost goes with the points it
  /// is handed, and most of a sprawl's lanes are straight on even ground, so
  /// the ten-metre samples the drape needs are mostly nothing to draw
  /// (lane_ribbon_bench_test). The ends are always kept.
  static List<Vector3> simplify(List<Vector3> pts) {
    if (pts.length < 3) return pts;
    final out = <Vector3>[pts.first];
    final tol2 = simplifyTolM * simplifyTolM;
    var anchor = 0;
    for (var i = 1; i < pts.length - 1; i++) {
      // Point i may go only if the chord from the last kept point to the
      // point after i passes within the tolerance of every point between.
      final a = pts[anchor];
      final d = pts[i + 1] - a;
      final len2 = d.lengthSquared;
      // A run is re-checked whole at every step, so a long straight one
      // would cost its length squared: one point every [maxRun] samples
      // keeps the first build linear for a line kept to its ends.
      var keep = i - anchor >= maxRun;
      for (var j = anchor + 1; !keep && j <= i; j++) {
        final v = pts[j] - a;
        final t = len2 > 0 ? (v.dot(d) / len2).clamp(0.0, 1.0) : 0.0;
        if ((v - d * t).lengthSquared > tol2) {
          keep = true;
          break;
        }
      }
      if (keep) {
        out.add(pts[i]);
        anchor = i;
      }
    }
    out.add(pts.last);
    return out;
  }

  /// [AgentLaneSpeeds.band]'s colour.
  static int argbOfBand(int band) => switch (band) {
        2 => greenArgb,
        1 => amberArgb,
        _ => redArgb,
      };

  // ---- State ---------------------------------------------------------------------

  final LaneSpeedGate gate = LaneSpeedGate();

  /// Lists of ribbons handed out: a new one only when a lane changed band,
  /// the graph was rebuilt or the ground moved.
  int builds = 0;

  List<OverlayLine> _lines = const <OverlayLine>[];

  /// Per lane of the graph drawn: its band last drawn (255: not drawn), and
  /// its draped centreline.
  Uint8List _bands = Uint8List(0);
  List<List<Vector3>> _drapes = const [];
  Object? _drapeKey;
  Object? _drapeGraph;
  String _bodyId = '';

  /// Whether a refresh now would read the speeds again — the flight view's
  /// per-frame question while the view is open, so it can redraw a view
  /// nobody is moving the mouse over.
  bool due(AgentLaneSpeeds speeds) =>
      gate.due(speeds.revision, speeds.graphRev, _clockUs(), _groundKeyLast);
  Object? _groundKeyLast;

  /// The ribbons for [speeds], laid through [drape] (a colony-local point
  /// and a lift to body-fixed metres on the ground) on [bodyId], whose
  /// ground is [groundKey]. The same list as last time until [gate] lets a
  /// read through and it finds something to draw differently.
  List<OverlayLine> lines(
    AgentLaneSpeeds speeds, {
    required Vector3 Function(Vec2 p, [double liftM]) drape,
    required String bodyId,
    Object? groundKey,
  }) {
    if (bodyId != _bodyId) {
      _bodyId = bodyId;
      gate.reset();
      _drapeKey = null;
    }
    _groundKeyLast = groundKey;
    final now = _clockUs();
    if (!gate.due(speeds.revision, speeds.graphRev, now, groundKey)) {
      return _lines;
    }
    gate.took(speeds.revision, speeds.graphRev, now, groundKey);
    final pct = speeds.pct;
    final n = speeds.laneCount;
    if (pct == null || n == 0) {
      // Nothing measured on the graph running now: agents off, no roads, or
      // a rebuild less than an epoch old. The old ribbons would be drawn on
      // lanes that may be gone.
      if (_lines.isNotEmpty) builds++;
      _bands = Uint8List(0);
      return _lines = const <OverlayLine>[];
    }
    final drapeKey = (speeds.graphRev, bodyId, groundKey);
    final redrape = drapeKey != _drapeKey ||
        !identical(speeds.laneGraph, _drapeGraph) ||
        _drapes.length != n;
    if (redrape) {
      _drapeKey = drapeKey;
      _drapeGraph = speeds.laneGraph;
      _drapes = [
        for (var lane = 0; lane < n; lane++)
          simplify([
            for (final p in speeds.laneLine(lane, stepM: stepM)) drape(p)
          ]),
      ];
    }
    final m = pct.length < n ? pct.length : n;
    var changed = redrape || _bands.length != n;
    if (_bands.length != n) _bands = Uint8List(n)..fillRange(0, n, 255);
    for (var lane = 0; lane < m; lane++) {
      final b = AgentLaneSpeeds.band(pct[lane]);
      if (b != _bands[lane]) {
        _bands[lane] = b;
        changed = true;
      }
    }
    if (!changed) return _lines;
    final out = <OverlayLine>[];
    for (var lane = 0; lane < m; lane++) {
      final pts = _drapes[lane];
      if (pts.length < 2) continue;
      out.add(OverlayLine(
        pointsBF: pts,
        argb: argbOfBand(_bands[lane]),
        widthM: ribbonWidthM,
        liftM: ribbonLiftM,
      ));
    }
    builds++;
    return _lines = out.isEmpty ? const <OverlayLine>[] : out;
  }

  /// Drop what was drawn: the next call reads and lays everything again.
  void forget() {
    gate.reset();
    _lines = const <OverlayLine>[];
    _bands = Uint8List(0);
    _drapes = const [];
    _drapeKey = null;
    _drapeGraph = null;
  }
}

const Color _dim = Color(0xFF9FB4CC);
const Color _faint = Color(0xFF6D8095);

/// The Lane speed view's row on the Traffic tool's strip: what the three
/// colours mean, and — before there is anything to colour — why not.
class TrafficLaneSpeedLegend extends StatelessWidget {
  const TrafficLaneSpeedLegend({super.key, required this.city});

  final CitySim city;

  @override
  Widget build(BuildContext context) {
    final agents = city.agents;
    final String hint;
    if (!agents.enabled) {
      hint = 'Lane speeds are measured by agent traffic, which is off here';
    } else if (agents.laneSpeeds.pct == null) {
      hint = 'Measuring lane speeds — let the colony run a moment';
    } else {
      hint = 'Speed against the limit, over the last minute · click a car '
          'to follow it';
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _swatch(TrafficLaneSpeedOverlay.greenArgb, '70% and up'),
        _swatch(TrafficLaneSpeedOverlay.amberArgb, '40–69%'),
        _swatch(TrafficLaneSpeedOverlay.redArgb, 'under 40%'),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(hint, style: const TextStyle(fontSize: 10, color: _faint)),
        ),
      ]),
    );
  }

  static Widget _swatch(int argb, String label) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 16,
            height: 6,
            decoration: BoxDecoration(
              color: Color(argb | 0xFF000000),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(fontSize: 11, color: _dim)),
        ]),
      );
}
