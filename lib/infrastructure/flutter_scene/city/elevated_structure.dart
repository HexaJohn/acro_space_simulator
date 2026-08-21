// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Roads and railways that are not on the ground.
///
/// The single most recognisable thing in a photograph of the Loop is not a
/// building — it is the steel trestle carrying the L over the middle of the
/// street, and the train on top of it. A city renderer that can only draw
/// ribbons on the ground cannot draw that at all, and the street it does draw
/// reads as a canyon with nothing in it.
///
/// Two structures, and they are genuinely different objects rather than one
/// with a parameter:
///
///   * VIADUCT — a concrete highway deck on hammerhead piers down the middle
///     of the alignment. Heavy, continuous, big spans.
///   * TRESTLE — a steel rail structure on column bents at the CURB LINES, so
///     the street runs under it and the columns stand in the road. Light,
///     open, short spans, and you can see daylight through it.
///
/// Everything is emitted in metres relative to the colony anchor; [OrientedBox]
/// applies the render scale.
library;

import 'dart:math' as math;

import '../../../domain/colony/city/parcel.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import 'oriented_box.dart';

class ElevatedStructure {
  const ElevatedStructure._();

  /// Longitudinal spacing of the supports, by class. A concrete viaduct spans
  /// far further than a steel bent, and the difference in rhythm is most of
  /// what makes the two read as different structures from a distance.
  static double spacingFor(RoadClass cls) =>
      cls == RoadClass.transit ? 13.0 : 30.0;

  /// Build the structure carrying [pts] (anchor-relative metres).
  ///
  /// [solid] takes concrete and steel, [deck] the running surface (the road
  /// material, so a viaduct's carriageway has lane markings like any other),
  /// and [glow] the lit furniture.
  static void emit(
    MeshBuilder solid,
    MeshBuilder deck,
    MeshBuilder glow, {
    required List<Vector3> pts,
    required Vector3 anchorBF,
    required RoadClass cls,
    required double halfWidthM,
  }) {
    if (pts.length < 2) return;
    final h = cls.deckHeightM;
    if (h <= 0) return;
    // The alignment's own points are already on the graded ground — the same
    // terrain-following polyline every other road gets — so a column simply
    // runs from the point it stands on up to the deck. That also means the
    // deck holds a constant clearance over whatever it crosses, which is what
    // a real viaduct does and why one can be laid over rolling ground at all.
    if (cls == RoadClass.transit) {
      _trestle(solid, deck, pts, anchorBF, halfWidthM, h);
    } else {
      _viaduct(solid, deck, glow, pts, anchorBF, halfWidthM, h);
    }
  }

  // ---- Concrete viaduct ---------------------------------------------------

  static void _viaduct(
    MeshBuilder solid,
    MeshBuilder deck,
    MeshBuilder glow,
    List<Vector3> pts,
    Vector3 anchorBF,
    double hw,
    double h,
  ) {
    // Running surface, as a ribbon so it takes the road strip's lane markings.
    _ribbon(deck, pts, anchorBF, hw, h);

    // Soffit and edge fascias: what you see from underneath, which for an
    // elevated road is most of what anyone ever sees of it.
    _edge(solid, pts, anchorBF, hw, h, 1.25, inset: 0.0);
    _edge(solid, pts, anchorBF, -hw, h, 1.25, inset: 0.0);
    _soffit(solid, pts, anchorBF, hw, h - 1.25);

    // Barriers.
    _edge(glow, pts, anchorBF, hw - 0.35, h + 0.55, 1.1, inset: 0.0);
    _edge(glow, pts, anchorBF, -hw + 0.35, h + 0.55, 1.1, inset: 0.0);

    // Hammerhead piers down the centreline.
    for (final s in _stations(pts, spacingFor(RoadClass.elevated))) {
      final up = (s.at + anchorBF).normalized;
      final base = s.at;
      final stem = h - 1.6;
      if (stem <= 1) continue;
      OrientedBox.upright(solid, base, s.along, up, 2.4, 2.0, stem);
      // Cap beam, spanning the deck width above the column.
      final side = s.along.cross(up).normalized;
      OrientedBox.span(
        solid,
        base + up * stem + side * -hw * 0.82,
        base + up * stem + side * hw * 0.82,
        up,
        1.5,
        1.5,
      );
    }
  }

  // ---- Steel rail trestle -------------------------------------------------

  static void _trestle(
    MeshBuilder solid,
    MeshBuilder deck,
    List<Vector3> pts,
    Vector3 anchorBF,
    double hw,
    double h,
  ) {
    const girderDepth = 1.5;
    // Two deep plate girders, one each side, carrying the track between them.
    _edge(solid, pts, anchorBF, hw, h, girderDepth, inset: 0.0);
    _edge(solid, pts, anchorBF, -hw, h, girderDepth, inset: 0.0);

    // Track deck between the girders, and the two rails on it. The rails are
    // the thing that says "railway" at any distance the structure is legible
    // at — without them a trestle is a footbridge.
    _ribbon(deck, pts, anchorBF, hw * 0.72, h + 0.05);
    for (final off in [-0.72, 0.72]) {
      _edge(solid, pts, anchorBF, off, h + 0.2, 0.16, inset: 0.0, widthM: 0.14);
    }

    // Column bents. The columns stand at the CURB LINES of the street below,
    // not under the track — that is why an L structure straddles the road with
    // traffic running between its legs, and it is the detail that places the
    // whole thing over a street rather than beside one.
    for (final s in _stations(pts, spacingFor(RoadClass.transit))) {
      final up = (s.at + anchorBF).normalized;
      final side = s.along.cross(up).normalized;
      final stem = h - girderDepth;
      if (stem <= 1) continue;
      for (final sign in [-1.0, 1.0]) {
        final foot = s.at + side * (hw * sign);
        OrientedBox.upright(solid, foot, s.along, up, 0.55, 0.55, stem);
      }
      // Cross girder over the street, under the track.
      final top = s.at + up * (h - girderDepth) - up * 0.0;
      OrientedBox.span(solid, top + side * -hw, top + side * hw, up, 0.5, 0.7);
      // Knee braces, which is what gives an L bent its silhouette.
      for (final sign in [-1.0, 1.0]) {
        final foot =
            s.at + side * (hw * sign) + up * (h - girderDepth - 1.9);
        final knee = s.at + side * (hw * sign * 0.45) + up * (h - girderDepth);
        OrientedBox.span(solid, foot, knee, up, 0.3, 0.3);
      }
    }
  }

  // ---- Shared ribbon helpers ---------------------------------------------

  /// A flat surface [lift] metres above the alignment, [hw] to each side.
  static void _ribbon(MeshBuilder m, List<Vector3> pts, Vector3 anchorBF,
      double hw, double lift) {
    var v = 0.0;
    int? pl, pr;
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      final up = (p + anchorBF).normalized;
      final ahead = i + 1 < pts.length ? pts[i + 1] - p : p - pts[i - 1];
      final along = ahead.length > 1e-6 ? ahead.normalized : Vector3.unitX;
      final side = along.cross(up).normalized;
      if (i > 0) v += (p - pts[i - 1]).length / (hw * 2);
      final c = p + up * lift;
      final l = m.vertex(_s(c + side * -hw), up, 0, v);
      final r = m.vertex(_s(c + side * hw), up, 1, v);
      // Same winding as the ground ribbons, which render face up.
      if (pl != null && pr != null) m.quad(pl, pr, r, l);
      pl = l;
      pr = r;
    }
  }

  /// A continuous beam running the alignment at lateral offset [off], its TOP
  /// at [top], hanging [depth] below it.
  static void _edge(
    MeshBuilder m,
    List<Vector3> pts,
    Vector3 anchorBF,
    double off,
    double top,
    double depth, {
    required double inset,
    double widthM = 0.42,
  }) {
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1], b = pts[i];
      final up = ((a + b) * 0.5 + anchorBF).normalized;
      final along = (b - a);
      if (along.length < 1e-6) continue;
      final side = along.normalized.cross(up).normalized;
      OrientedBox.span(
        m,
        a + side * off + up * (top - depth / 2),
        b + side * off + up * (top - depth / 2),
        up,
        widthM,
        depth,
      );
    }
  }

  /// The underside of a deck — one flat surface facing DOWN, because that is
  /// the face a street sees.
  static void _soffit(MeshBuilder m, List<Vector3> pts, Vector3 anchorBF,
      double hw, double at) {
    int? pl, pr;
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      final up = (p + anchorBF).normalized;
      final ahead = i + 1 < pts.length ? pts[i + 1] - p : p - pts[i - 1];
      final along = ahead.length > 1e-6 ? ahead.normalized : Vector3.unitX;
      final side = along.cross(up).normalized;
      final c = p + up * at;
      final down = up * -1;
      final l = m.vertex(_s(c + side * -hw), down, 0, 0.5);
      final r = m.vertex(_s(c + side * hw), down, 1, 0.5);
      // Reversed against the deck above it, so it faces the street.
      if (pl != null && pr != null) m.quad(l, r, pr, pl);
      pl = l;
      pr = r;
    }
  }

  /// Evenly spaced points along a polyline, with the local direction.
  static List<({Vector3 at, Vector3 along})> _stations(
      List<Vector3> pts, double spacingM) {
    final out = <({Vector3 at, Vector3 along})>[];
    var carry = spacingM * 0.5;
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1], b = pts[i];
      final seg = b - a;
      final len = seg.length;
      if (len < 1e-6) continue;
      final dir = seg.normalized;
      var s = carry;
      while (s < len) {
        out.add((at: a + dir * s, along: dir));
        s += spacingM;
      }
      carry = s - len;
    }
    return out;
  }

  static Vector3 _s(Vector3 metres) => metres * _scale;
  static const double _scale = 1e-3;

  /// Cars per train, and how long one is. A four-car set at 18 m a car is
  /// roughly what runs on the Loop.
  static const int trainCars = 4;
  static const double carLengthM = 18;
  static const double carWidthM = 2.9;
  static const double carHeightM = 3.6;

  /// The train itself, drawn by the TRAFFIC pass rather than with the
  /// structure: it moves, and the structure is rebuilt only when the colony's
  /// shape changes.
  ///
  /// Position is derived from [epochS] exactly as road traffic is — no state,
  /// nothing on the wire, and every client watching the same tick sees the
  /// train in the same place.
  static void emitTrain(
    MeshBuilder body,
    MeshBuilder glass, {
    required List<Vector3> pts,
    required Vector3 anchorBF,
    required double lengthM,
    required double epochS,
    required int seed,
  }) {
    if (pts.length < 2 || lengthM < carLengthM * trainCars) return;
    const speedMs = 14.0;
    final period = lengthM / speedMs;
    final phase = ((epochS + seed * 37.0) % period) / period;
    final head = phase * lengthM;

    for (var c = 0; c < trainCars; c++) {
      final s = head - c * (carLengthM + 1.2);
      if (s < 0 || s > lengthM - carLengthM) continue;
      final at = _along(pts, s + carLengthM / 2);
      final ahead = _along(pts, math.min(lengthM, s + carLengthM));
      final dir = (ahead - at);
      if (dir.length < 1e-6) continue;
      final along = dir.normalized;
      final up = (at + anchorBF).normalized;
      final side = along.cross(up).normalized;
      final centre =
          at + up * (RoadClass.transit.deckHeightM + 0.35 + carHeightM / 2);
      OrientedBox.emit(body, centre, side, along, up, carWidthM / 2,
          carLengthM / 2, carHeightM / 2);
      // Window band, on the glazing material so it lights at night.
      OrientedBox.emit(
          glass,
          centre + up * 0.55,
          side,
          along,
          up,
          carWidthM / 2 + 0.03,
          carLengthM / 2 - 0.9,
          0.62);
    }
  }

  /// Point at arc length [s] along a polyline.
  static Vector3 _along(List<Vector3> pts, double s) {
    var acc = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final seg = pts[i] - pts[i - 1];
      final len = seg.length;
      if (acc + len >= s) {
        final t = len < 1e-9 ? 0.0 : (s - acc) / len;
        return pts[i - 1] + seg * t;
      }
      acc += len;
    }
    return pts.last;
  }

  /// Total length of a polyline.
  static double lengthOf(List<Vector3> pts) {
    var t = 0.0;
    for (var i = 1; i < pts.length; i++) {
      t += (pts[i] - pts[i - 1]).length;
    }
    return t;
  }
}
