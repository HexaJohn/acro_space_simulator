// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Everything on a pavement that is not the pavement.
///
/// Count the objects in the reference photographs between the curb and the
/// shopfronts: signal masts, a hydrant, three bins, a bus shelter, planters,
/// bollards, parking meters, newspaper boxes, a sandwich board, street trees,
/// and a vendor's cart. A bare grey strip between a road and a building is
/// the most obviously CGI part of any generated city, and none of this is
/// expensive — it is small boxes on an instanced material that already exists.
///
/// Placement is deterministic from the road's own polyline and a hash, exactly
/// as the street lamps and junction furniture already are: no state, nothing
/// on the wire, and every client watching the same tick sees the same street.
///
/// Density is deliberately uneven. Furniture laid on an even pitch reads as
/// fence posts; real pavements have a cluster at every corner, a gap in the
/// middle of a block, and a bus shelter only where a bus stops.
library;

import 'dart:math' as math;

import '../../../domain/colony/city/parcel.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import 'oriented_box.dart';

/// What can stand on a pavement.
enum StreetProp {
  /// Squat, unmissable, and the one piece of street furniture everybody can
  /// name the size of — which makes it a scale reference as well as clutter.
  hydrant(0.34, 0.34, 0.78),
  litterBin(0.62, 0.62, 0.95),
  bench(0.62, 1.85, 0.46),
  bollard(0.22, 0.22, 0.95),
  planter(1.1, 1.1, 0.62),
  parkingMeter(0.16, 0.16, 1.35),
  newsBox(0.46, 0.42, 1.25),
  mailbox(0.58, 0.5, 1.35),
  utilityCabinet(0.75, 0.45, 1.25),
  busShelter(1.5, 4.2, 2.5),
  streetTree(0.34, 0.34, 5.5);

  const StreetProp(this.widthM, this.depthM, this.heightM);

  /// Across the pavement, along it, and up.
  final double widthM, depthM, heightM;

  /// Whether it glazes — a shelter is mostly glass and a tree is a canopy;
  /// both belong in the alpha-masked channel rather than the opaque one.
  bool get glazed => this == StreetProp.busShelter;

  /// How far off the curb it stands, as a fraction of the pavement width.
  /// Bins, meters and hydrants hug the curb; benches and shelters sit back.
  double get curbFraction => switch (this) {
        StreetProp.hydrant ||
        StreetProp.parkingMeter ||
        StreetProp.bollard =>
          0.22,
        StreetProp.streetTree || StreetProp.litterBin => 0.3,
        StreetProp.busShelter || StreetProp.bench => 0.55,
        _ => 0.42,
      };

  /// Relative frequency. There are a great many more meters and bollards on a
  /// street than there are bus shelters.
  int get weight => switch (this) {
        StreetProp.parkingMeter => 7,
        StreetProp.bollard => 6,
        StreetProp.litterBin => 5,
        StreetProp.streetTree => 5,
        StreetProp.hydrant => 4,
        StreetProp.newsBox => 3,
        StreetProp.planter => 3,
        StreetProp.bench => 3,
        StreetProp.utilityCabinet => 2,
        StreetProp.mailbox => 2,
        StreetProp.busShelter => 1,
      };
}

class StreetFurniture {
  const StreetFurniture._();

  /// Average spacing along a pavement, metres. Not the actual pitch — the
  /// placement jitters either side of it and skips outright — just the budget.
  static double pitchM = 11.0;

  /// Global on/off, for the studio's isolate panel.
  static bool enabled = true;

  static final List<StreetProp> _bag = [
    for (final p in StreetProp.values)
      for (var i = 0; i < p.weight; i++) p
  ];

  /// Furnish both pavements of one road.
  ///
  /// [pts] is the centreline in anchor-relative metres; [pavementM] the width
  /// of the footway outside the curb. Returns how many props it placed, so a
  /// caller can hold a budget across a whole colony.
  ///
  /// [treesOut] takes street-tree PLACEMENTS instead of geometry: a real tree
  /// is the scatter system's prop, drawn instanced by the caller, and baking
  /// one into this per-colony mesh would cost more than the buildings behind
  /// it. Null falls back to the box stand-in (headless callers and tests).
  /// Each entry is the pit position in anchor-relative metres plus a yaw.
  ///
  /// [shrubsOut] is the same deal for what grows in the planters: the box pot
  /// is still meshed here, and the mounded-box "planting" on its rim becomes
  /// a placement (at the soil line, inside the pot) for the caller to draw as
  /// the scatter shrub.
  static int emit(
    MeshBuilder solid,
    MeshBuilder glow, {
    required List<Vector3> pts,
    required Vector3 anchorBF,
    required RoadClass cls,
    required double halfWidthM,
    required double pavementM,
    required int seed,
    int budget = 1 << 30,
    List<(Vector3, double)>? treesOut,
    List<(Vector3, double)>? shrubsOut,
  }) {
    if (!enabled || !cls.hasPavement || pts.length < 2 || budget <= 0) return 0;
    var placed = 0;
    final rnd = math.Random(seed);

    for (final side in const [-1.0, 1.0]) {
      var carry = pitchM * rnd.nextDouble();
      for (var i = 1; i < pts.length && placed < budget; i++) {
        final a = pts[i - 1], b = pts[i];
        final seg = b - a;
        final len = seg.length;
        if (len < 1e-6) continue;
        final dir = seg.normalized;
        var s = carry;
        while (s < len && placed < budget) {
          // A third of the slots stay empty. An unbroken run of furniture is
          // as wrong as an empty pavement — it reads as a railing.
          if (rnd.nextDouble() > 0.34) {
            final at = a + dir * s;
            final up = (at + anchorBF).normalized;
            final across = dir.cross(up).normalized * side;
            final prop = _bag[rnd.nextInt(_bag.length)];
            final off = halfWidthM + pavementM * prop.curbFraction;
            final spot = at + across * off;
            if (prop == StreetProp.streetTree && treesOut != null) {
              treesOut.add((spot, rnd.nextDouble() * math.pi * 2));
            } else {
              _place(prop.glazed ? glow : solid, prop, spot, dir, up, rnd,
                  barePlanter: shrubsOut != null);
              if (prop == StreetProp.planter && shrubsOut != null) {
                shrubsOut.add((spot + up * (prop.heightM * 0.85),
                    rnd.nextDouble() * math.pi * 2));
              }
            }
            placed++;
          }
          s += pitchM * (0.55 + rnd.nextDouble() * 0.9);
        }
        carry = s - len;
      }
    }
    return placed;
  }

  static void _place(MeshBuilder m, StreetProp prop, Vector3 at, Vector3 along,
      Vector3 up, math.Random rnd,
      {bool barePlanter = false}) {
    switch (prop) {
      case StreetProp.streetTree:
        // Trunk plus two canopy slabs. Not the scatter system's tree: a street
        // tree is pollarded, sits in a 1 m pit, and there are a handful per
        // block — paying for a full procedural broadleaf here would cost more
        // than the buildings behind it.
        OrientedBox.upright(m, at, along, up, 0.28, 0.28, 3.4);
        for (var i = 0; i < 2; i++) {
          final r = 1.5 - i * 0.45;
          OrientedBox.upright(
              m, at + up * (3.2 + i * 0.9), along, up, r * 2, r * 2, 0.85);
        }
      case StreetProp.busShelter:
        // Roof on two end panels, open to the curb.
        final side = along.cross(up).normalized;
        OrientedBox.upright(m, at, along, up, prop.widthM, prop.depthM, 0.08);
        for (final e in [-1.0, 1.0]) {
          OrientedBox.upright(m, at + along * (prop.depthM / 2 * e), along, up,
              prop.widthM, 0.1, prop.heightM);
        }
        OrientedBox.upright(m, at + side * (prop.widthM / 2 * 0.9), along, up,
            0.1, prop.depthM, prop.heightM);
        OrientedBox.emit(m, at + up * prop.heightM, side, along, up,
            prop.widthM / 2 + 0.2, prop.depthM / 2 + 0.2, 0.09);
      case StreetProp.bench:
        // Seat and back, on two legs.
        final side = along.cross(up).normalized;
        OrientedBox.emit(m, at + up * 0.44, side, along, up, prop.widthM / 2,
            prop.depthM / 2, 0.05);
        OrientedBox.emit(m, at + up * 0.72 + side * (prop.widthM / 2 - 0.06),
            side, along, up, 0.05, prop.depthM / 2, 0.28);
        for (final e in [-1.0, 1.0]) {
          OrientedBox.upright(m, at + along * (prop.depthM / 2 * 0.8 * e),
              along, up, prop.widthM * 0.8, 0.08, 0.42);
        }
      case StreetProp.planter:
        OrientedBox.upright(
            m, at, along, up, prop.widthM, prop.depthM, prop.heightM);
        // Planting, mounded above the rim — unless the caller is growing a
        // real shrub in the pot instead (see [emit]'s shrubsOut).
        if (!barePlanter) {
          OrientedBox.upright(m, at + up * prop.heightM, along, up,
              prop.widthM * 0.86, prop.depthM * 0.86, 0.45);
        }
      case StreetProp.hydrant:
        OrientedBox.upright(m, at, along, up, 0.3, 0.3, 0.6);
        OrientedBox.upright(m, at + up * 0.6, along, up, 0.38, 0.38, 0.16);
        // Side outlets, which is the whole silhouette of the thing.
        final side = along.cross(up).normalized;
        for (final e in [-1.0, 1.0]) {
          OrientedBox.emit(m, at + up * 0.42 + side * (0.2 * e), side, along,
              up, 0.12, 0.12, 0.09);
        }
      default:
        // A yaw off true, so a run of bins does not line up like a fence.
        final skew = (rnd.nextDouble() - 0.5) * 0.5;
        final a2 = (along + along.cross(up) * skew).normalized;
        OrientedBox.upright(
            m, at, a2, up, prop.widthM, prop.depthM, prop.heightM);
    }
  }
}
