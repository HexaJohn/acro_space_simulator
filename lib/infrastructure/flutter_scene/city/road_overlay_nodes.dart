// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The road tool's overlay as geometry: the road being laid, the lines and
/// the markers the editor asks for (see [RoadOverlayState]).
///
/// Drawn by the renderer on the UI thread, the frame the state changes, as
/// one node beside the tiles — a view that answers the mouse cannot wait on
/// a worker-meshed tile. Rebuilt only when the state's revision moves (see
/// [RoadOverlayGate]); a frame with the mouse still costs an integer
/// compare.
///
/// The GHOST is the real road, not a coloured strip: the same carriageway
/// the tiles lay, with its lanes and its median, raised onto its deck by
/// the per-point lifts, piers under whatever of it stands clear of the
/// ground. A tunnel stretch cannot be seen through the ground — the engine
/// has no depth test to turn off — so it is a translucent band laid on the
/// surface over where the tunnel runs. A refused road is the same shape in
/// a translucent red, so the player sees what they asked for and that it
/// cannot be built. LINES and MARKERS are flat translucent geometry in
/// their own colours, on an unlit material, lifted clear of what they
/// describe.
///
/// Everything here is plain Dart; `CityNodes` turns it into a node.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../../domain/colony/city/parcel.dart';
import '../../../domain/colony/city/road_elevation.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/scatter/prop_mesh.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'city_tile_mesher.dart' show CityMaterialKind;
import 'instant_road_nodes.dart' show RoadLiftProfile, tunnelRuns;
import 'road_mesher.dart';
import 'road_overlay_state.dart';

/// A mesh with a colour per vertex: what the translucent overlay is built
/// into. [MeshBuilder] has no colour stream, and the engine's unlit
/// material takes its colour and its alpha from the vertices.
///
/// Positions are in SCENE units relative to the node's anchor, as the road
/// pipeline's are; triangles are given by the right-hand rule and flipped
/// for the engine here, as [MeshBuilder.triangle] does, so both kinds of
/// geometry face the same way.
class OverlayMeshBuilder {
  Float32List _p = Float32List(3 * 64);
  Float32List _n = Float32List(3 * 64);
  Float32List _uv = Float32List(2 * 64);
  Float32List _c = Float32List(4 * 64);
  Uint32List _i = Uint32List(3 * 64);
  int _vc = 0, _ic = 0;

  int get vertexCount => _vc;
  int get triangleCount => _ic ~/ 3;
  bool get isEmpty => _ic == 0;

  /// One vertex at [scenePos] with [normal], coloured [argb] (0xAARRGGBB,
  /// sRGB as a designer writes it — linearised here, since the shader
  /// multiplies the vertex colour into its linear output).
  int vertex(Vector3 scenePos, Vector3 normal, int argb) {
    final i = _vc;
    if (i + 1 > _c.length ~/ 4) _grow(i + 1);
    _p[3 * i] = scenePos.x;
    _p[3 * i + 1] = scenePos.y;
    _p[3 * i + 2] = scenePos.z;
    _n[3 * i] = normal.x;
    _n[3 * i + 1] = normal.y;
    _n[3 * i + 2] = normal.z;
    _uv[2 * i] = 0.5;
    _uv[2 * i + 1] = 0.5;
    _c[4 * i] = _linear((argb >> 16) & 0xFF);
    _c[4 * i + 1] = _linear((argb >> 8) & 0xFF);
    _c[4 * i + 2] = _linear(argb & 0xFF);
    _c[4 * i + 3] = ((argb >> 24) & 0xFF) / 255.0;
    _vc = i + 1;
    return i;
  }

  /// A triangle by the right-hand rule (see the class docs).
  void triangle(int a, int b, int c) {
    if (_ic + 3 > _i.length) {
      _i = Uint32List(_i.length * 2)..setRange(0, _ic, _i);
    }
    _i[_ic] = a;
    _i[_ic + 1] = c;
    _i[_ic + 2] = b;
    _ic += 3;
  }

  void quad(int a, int b, int c, int d) {
    triangle(a, b, c);
    triangle(a, c, d);
  }

  /// A mesh the road pipeline built, in one colour: the refused ghost is
  /// the real road's shape, tinted. Its indices are already in the
  /// engine's order.
  void addTinted(PropMesh mesh, int argb) {
    if (mesh.isEmpty) return;
    final base = _vc;
    final pos = mesh.positions, nor = mesh.normals;
    for (var v = 0; v < mesh.vertexCount; v++) {
      vertex(Vector3(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2]),
          Vector3(nor[3 * v], nor[3 * v + 1], nor[3 * v + 2]), argb);
    }
    final idx = mesh.indices;
    if (_ic + idx.length > _i.length) {
      var cap = _i.length;
      while (cap < _ic + idx.length) {
        cap *= 2;
      }
      _i = Uint32List(cap)..setRange(0, _ic, _i);
    }
    for (var k = 0; k < idx.length; k++) {
      _i[_ic + k] = base + idx[k];
    }
    _ic += idx.length;
  }

  Float32List get positions => Float32List.sublistView(_p, 0, 3 * _vc);
  Float32List get normals => Float32List.sublistView(_n, 0, 3 * _vc);
  Float32List get texCoords => Float32List.sublistView(_uv, 0, 2 * _vc);
  Float32List get colors => Float32List.sublistView(_c, 0, 4 * _vc);
  Uint32List get indices => Uint32List.sublistView(_i, 0, _ic);

  /// The colour of vertex [i], linear RGBA — what a test reads back.
  List<double> colorAt(int i) => _c.sublist(4 * i, 4 * i + 4);

  void _grow(int need) {
    var cap = _c.length ~/ 4;
    while (cap < need) {
      cap *= 2;
    }
    _p = Float32List(3 * cap)..setRange(0, 3 * _vc, _p);
    _n = Float32List(3 * cap)..setRange(0, 3 * _vc, _n);
    _uv = Float32List(2 * cap)..setRange(0, 2 * _vc, _uv);
    _c = Float32List(4 * cap)..setRange(0, 4 * _vc, _c);
  }

  static double _linear(int c) => math.pow(c / 255.0, 2.2).toDouble();
}

/// The overlay's geometry: opaque parts by the city material they draw on,
/// and the translucent part.
class RoadOverlayGeometry {
  final Map<CityMaterialKind, MeshBuilder> opaque = {};
  final OverlayMeshBuilder translucent = OverlayMeshBuilder();

  MeshBuilder opaqueFor(CityMaterialKind kind) =>
      opaque.putIfAbsent(kind, MeshBuilder.new);

  /// Triangles on [kind]'s material, 0 with none.
  int trianglesOn(CityMaterialKind kind) => opaque[kind]?.triangleCount ?? 0;

  bool get isEmpty =>
      translucent.isEmpty && opaque.values.every((m) => m.triangleCount == 0);
}

/// When the overlay has to be built again: on a new
/// [RoadOverlayState.revision], another body, or another anchor — never on
/// a frame that changed none of them, which is every frame the mouse rests.
class RoadOverlayGate {
  int? _revision;
  String? _bodyId;
  Vector3? _anchorBF;

  /// Rebuilds granted so far.
  int builds = 0;

  /// Whether the overlay must be rebuilt for [revision] on [bodyId] at
  /// [anchorBF]; when it must, the gate takes these as what it was built
  /// from.
  bool wants(int revision, String bodyId, Vector3 anchorBF) {
    if (revision == _revision &&
        bodyId == _bodyId &&
        anchorBF == _anchorBF) {
      return false;
    }
    _revision = revision;
    _bodyId = bodyId;
    _anchorBF = anchorBF;
    builds++;
    return true;
  }

  /// Forget what was built — the node was dropped — so the next call wants.
  void reset() {
    _revision = null;
    _bodyId = null;
    _anchorBF = null;
  }
}

/// [RoadOverlayState] into [RoadOverlayGeometry].
class RoadOverlayMesher {
  const RoadOverlayMesher._();

  /// The ghost rides this far over the ribbon it previews — above a road
  /// already there, a junction plate (0.16) and a pavement (0.27).
  static const double ghostLiftM = 0.3;

  /// A tunnel stretch's band stands this far over the drape.
  static const double tunnelLiftM = 0.4;

  /// Spacing of the direction-of-travel arrows on a one-way ghost.
  static const double arrowSpacingM = 24;

  /// A dashed line's dash and gap.
  static const double dashOnM = 6, dashOffM = 4;

  static const int refusedArgb = 0xA6E53935;
  static const int tunnelArgb = 0x8C5AA9E6;
  static const int selectedArgb = 0x6633D1FF;
  static const int arrowArgb = 0xE6FFFFFF;
  static const int _red = 0xFFE53935, _amber = 0xFFFFB300, _green = 0xFF43A047;
  static const int _white = 0xFFFFFFFF;

  /// A point the overlay can be anchored at — the first thing it draws —
  /// or null when it draws nothing.
  static Vector3? anchorOf(RoadOverlayState s) {
    if (s.ghostBF.length >= 2) return s.ghostBF.first;
    for (final l in s.lines) {
      if (l.pointsBF.length >= 2) return l.pointsBF.first;
    }
    if (s.markers.isNotEmpty) return s.markers.first.atBF;
    return null;
  }

  /// Everything [s] draws, relative to [anchorBF].
  static RoadOverlayGeometry build(RoadOverlayState s, Vector3 anchorBF) {
    final g = RoadOverlayGeometry();
    _ghost(g, s, anchorBF);
    for (final line in s.lines) {
      _line(g.translucent, line, anchorBF);
    }
    for (final m in s.markers) {
      _marker(g.translucent, m, anchorBF);
    }
    return g;
  }

  static Vector3 _scene(Vector3 metres) => metres * kRenderScale;

  // ---- The ghost -------------------------------------------------------------

  static void _ghost(RoadOverlayGeometry g, RoadOverlayState s, Vector3 anchorBF) {
    final bf = s.ghostBF;
    final n = bf.length;
    if (n < 2) return;
    final lifts = s.ghostLiftsM.length == n ? s.ghostLiftsM : const <double>[];
    double liftOf(int i) => lifts.isEmpty ? 0.0 : lifts[i];
    final cls = RoadClass
        .values[s.ghostClassIndex.clamp(0, RoadClass.values.length - 1)];
    final hw = s.ghostHalfWidthM;
    final refused = s.ghostState == RoadGhostState.refused;
    final pts = [for (final p in bf) p - anchorBF];
    const liftM = RoadMesher.ribbonLiftM + ghostLiftM;
    for (final run in tunnelRuns(n, liftOf)) {
      final runPts = pts.sublist(run.from, run.to + 1);
      if (run.tunnel) {
        _band(g.translucent, runPts, anchorBF, hw, tunnelLiftM, null,
            refused ? refusedArgb : tunnelArgb);
        continue;
      }
      final profile = lifts.isEmpty
          ? null
          : RoadLiftProfile(runPts, lifts.sublist(run.from, run.to + 1));
      final liftAt = profile?.at;
      double pierAt(double s) {
        final l = profile?.at(s) ?? 0.0;
        return l > RoadElevation.structureClearM ? l : 0.0;
      }

      if (refused) {
        final surface = MeshBuilder(), solid = MeshBuilder();
        _surface(surface, solid, cls, runPts, anchorBF, hw, liftM, liftAt);
        if (profile != null) {
          RoadMesher.piers(solid, runPts, anchorBF, hw, pierAt);
        }
        g.translucent.addTinted(surface.build(), refusedArgb);
        g.translucent.addTinted(solid.build(), refusedArgb);
        continue;
      }
      final solid = g.opaqueFor(CityMaterialKind.facade);
      _surface(g.opaqueFor(_kindFor(cls)), solid, cls, runPts, anchorBF, hw,
          liftM, liftAt);
      if (profile != null) {
        RoadMesher.piers(solid, runPts, anchorBF, hw, pierAt);
      }
      if (s.ghostState == RoadGhostState.selected) {
        _band(g.translucent, runPts, anchorBF, hw + 0.6, liftM + 0.12, profile,
            selectedArgb);
      }
    }
    if (s.ghostOneWay) _arrows(g.translucent, pts, anchorBF, lifts, hw);
  }

  static CityMaterialKind _kindFor(RoadClass cls) => cls == RoadClass.alley
      ? CityMaterialKind.alley
      : (cls.paved ? CityMaterialKind.road : CityMaterialKind.dirt);

  /// The road's own surface: the carriageway for a paved class, its lanes
  /// and its median, or the plain ribbon of an alley or a gravel road.
  static void _surface(
    MeshBuilder m,
    MeshBuilder solid,
    RoadClass cls,
    List<Vector3> pts,
    Vector3 anchorBF,
    double hw,
    double liftM,
    double Function(double s)? liftAt,
  ) {
    if (cls == RoadClass.alley || !cls.paved) {
      RoadMesher.ribbon(m, pts, anchorBF, hw, liftM: liftM, liftAt: liftAt);
    } else {
      RoadMesher.carriageway(m, pts, anchorBF, cls,
          halfWidthM: hw, liftM: liftM, liftAt: liftAt, solid: solid);
    }
  }

  /// A translucent band [hw] each side of [pts], [liftM] over them plus the
  /// [profile]'s lift.
  static void _band(OverlayMeshBuilder m, List<Vector3> pts, Vector3 anchorBF,
      double hw, double liftM, RoadLiftProfile? profile, int argb) {
    var s = 0.0;
    int? pl, pr;
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      if (i > 0) s += (p - pts[i - 1]).length;
      final up = (p + anchorBF).normalized;
      final ahead = i + 1 < pts.length ? pts[i + 1] - p : p - pts[i - 1];
      if (ahead.length <= 1e-9) continue;
      final side = ahead.normalized.cross(up).normalized;
      final c = p + up * (liftM + (profile?.at(s) ?? 0.0));
      final l = m.vertex(_scene(c - side * hw), up, argb);
      final r = m.vertex(_scene(c + side * hw), up, argb);
      if (pl != null && pr != null) m.quad(pl, pr, r, l);
      pl = l;
      pr = r;
    }
  }

  /// Arrowheads along [pts] pointing first to last — the direction of
  /// travel on a one-way road — every [arrowSpacingM], over the deck (or
  /// over the drape where the ghost is in a tunnel).
  static void _arrows(OverlayMeshBuilder m, List<Vector3> pts,
      Vector3 anchorBF, List<double> lifts, double hw) {
    final length = (hw * 1.1).clamp(3.0, 8.0);
    final half = length * 0.45;
    var s0 = 0.0;
    var next = arrowSpacingM / 2;
    for (var i = 0; i + 1 < pts.length; i++) {
      final a = pts[i], b = pts[i + 1];
      final seg = b - a;
      final len = seg.length;
      if (len < 1e-9) continue;
      final along = seg * (1 / len);
      while (next <= s0 + len) {
        final t = (next - s0) / len;
        final p = a + seg * t;
        final up = (p + anchorBF).normalized;
        final side = along.cross(up).normalized;
        final l0 = lifts.isEmpty ? 0.0 : lifts[i];
        final l1 = lifts.isEmpty ? 0.0 : lifts[i + 1];
        final lift = l0 + (l1 - l0) * t;
        final h = lift < -RoadElevation.tunnelCoverM
            ? tunnelLiftM + 0.1
            : RoadMesher.ribbonLiftM + ghostLiftM + 0.2 + lift;
        final c = p + up * h;
        final tip = m.vertex(_scene(c + along * (length * 0.6)), up, arrowArgb);
        final left = m.vertex(
            _scene(c - along * (length * 0.4) - side * half), up, arrowArgb);
        final right = m.vertex(
            _scene(c - along * (length * 0.4) + side * half), up, arrowArgb);
        m.triangle(tip, left, right);
        next += arrowSpacingM;
      }
      s0 += len;
    }
  }

  // ---- Lines -----------------------------------------------------------------

  static void _line(OverlayMeshBuilder m, OverlayLine line, Vector3 anchorBF) {
    final bf = line.pointsBF;
    final n = bf.length;
    if (n < 2) return;
    final extra = line.liftsM;
    final lifted = extra != null && extra.length == n;
    final hw = line.widthM / 2;
    final ups = [for (final p in bf) p.normalized];
    final pts = [
      for (var i = 0; i < n; i++)
        bf[i] - anchorBF + ups[i] * (line.liftM + (lifted ? extra[i] : 0.0)),
    ];
    if (!line.dashed) {
      int? pl, pr;
      for (var i = 0; i < n; i++) {
        final ahead = pts[i < n - 1 ? i + 1 : i] - pts[i > 0 ? i - 1 : i];
        if (ahead.length <= 1e-9) continue;
        final side = ahead.normalized.cross(ups[i]).normalized;
        final l = m.vertex(_scene(pts[i] - side * hw), ups[i], line.argb);
        final r = m.vertex(_scene(pts[i] + side * hw), ups[i], line.argb);
        if (pl != null && pr != null) m.quad(pl, pr, r, l);
        pl = l;
        pr = r;
      }
      return;
    }
    // Dashed: each segment cut against the dash pattern, which runs on
    // from one segment into the next so the dashes keep their spacing
    // round a bend.
    const period = dashOnM + dashOffM;
    var s0 = 0.0;
    for (var i = 0; i + 1 < n; i++) {
      final a = pts[i], b = pts[i + 1];
      final seg = b - a;
      final len = seg.length;
      if (len < 1e-9) continue;
      final along = seg * (1 / len);
      final up = (ups[i] + ups[i + 1]).normalized;
      final side = along.cross(up).normalized;
      final s1 = s0 + len;
      for (var k = (s0 / period).floor(); k * period < s1; k++) {
        final w0 = math.max(s0, k * period);
        final w1 = math.min(s1, k * period + dashOnM);
        if (w1 <= w0) continue;
        final p0 = a + along * (w0 - s0), p1 = a + along * (w1 - s0);
        m.quad(
          m.vertex(_scene(p0 - side * hw), up, line.argb),
          m.vertex(_scene(p0 + side * hw), up, line.argb),
          m.vertex(_scene(p1 + side * hw), up, line.argb),
          m.vertex(_scene(p1 - side * hw), up, line.argb),
        );
      }
      s0 = s1;
    }
  }

  // ---- Markers ---------------------------------------------------------------

  static void _marker(
      OverlayMeshBuilder m, OverlayMarker mk, Vector3 anchorBF) {
    final up = mk.atBF.normalized;
    // A stable tangent frame, as the cursor's: any vector off the up axis.
    final east = (up.cross(Vector3.unitZ).lengthSquared > 1e-9
            ? up.cross(Vector3.unitZ)
            : up.cross(Vector3.unitX))
        .normalized;
    final north = up.cross(east);
    final c = mk.atBF - anchorBF + up * mk.liftM;
    final r = mk.radiusM;
    // Each layer of an icon a couple of centimetres over the last.
    final top = up * 0.02;
    switch (mk.kind) {
      case OverlayMarkerKind.dot:
        _disc(m, c, up, east, north, r, mk.argb);
      case OverlayMarkerKind.ring:
        _ring(m, c, up, east, north, r * 0.7, r, mk.argb);
      case OverlayMarkerKind.lights:
        // A ring, and a signal head's three lamps in it.
        _ring(m, c, up, east, north, r * 0.8, r, mk.argb);
        for (final (dy, argb) in [(0.42, _red), (0.0, _amber), (-0.42, _green)]) {
          _disc(m, c + north * (r * dy) + top, up, east, north, r * 0.18, argb,
              segments: 12);
        }
      case OverlayMarkerKind.noLights:
        // A ring struck through.
        _ring(m, c, up, east, north, r * 0.8, r, mk.argb);
        final a = c + (east + north) * (r * -0.6) + top;
        final b = c + (east + north) * (r * 0.6) + top;
        final dir = (b - a).normalized;
        final side = dir.cross(up).normalized * (r * 0.09);
        m.quad(
          m.vertex(_scene(a - side), up, mk.argb),
          m.vertex(_scene(a + side), up, mk.argb),
          m.vertex(_scene(b + side), up, mk.argb),
          m.vertex(_scene(b - side), up, mk.argb),
        );
      case OverlayMarkerKind.stop:
        // An octagon with a white border inside its rim.
        const phase = math.pi / 8;
        _disc(m, c, up, east, north, r, mk.argb, segments: 8, phase: phase);
        _ring(m, c + top, up, east, north, r * 0.74, r * 0.86, _white,
            segments: 8, phase: phase);
    }
  }

  /// A filled disc (a regular polygon of [segments] sides) of radius [r]
  /// round [c] in the plane of [east] and [north].
  static void _disc(OverlayMeshBuilder m, Vector3 c, Vector3 up, Vector3 east,
      Vector3 north, double r, int argb,
      {int segments = 24, double phase = 0}) {
    final centre = m.vertex(_scene(c), up, argb);
    int? first, prev;
    for (var k = 0; k <= segments; k++) {
      final int v;
      if (k == segments) {
        v = first!;
      } else {
        final a = phase + 2 * math.pi * k / segments;
        v = m.vertex(
            _scene(c + east * (r * math.cos(a)) + north * (r * math.sin(a))),
            up,
            argb);
      }
      first ??= v;
      if (prev != null) m.triangle(centre, prev, v);
      prev = v;
    }
  }

  /// An annulus from radius [r0] to [r1] round [c].
  static void _ring(OverlayMeshBuilder m, Vector3 c, Vector3 up, Vector3 east,
      Vector3 north, double r0, double r1, int argb,
      {int segments = 24, double phase = 0}) {
    int? pi, po, fi, fo;
    for (var k = 0; k <= segments; k++) {
      final int vi, vo;
      if (k == segments) {
        vi = fi!;
        vo = fo!;
      } else {
        final a = phase + 2 * math.pi * k / segments;
        final dir = east * math.cos(a) + north * math.sin(a);
        vi = m.vertex(_scene(c + dir * r0), up, argb);
        vo = m.vertex(_scene(c + dir * r1), up, argb);
      }
      fi ??= vi;
      fo ??= vo;
      if (pi != null && po != null) m.quad(pi, po, vo, vi);
      pi = vi;
      po = vo;
    }
  }
}
