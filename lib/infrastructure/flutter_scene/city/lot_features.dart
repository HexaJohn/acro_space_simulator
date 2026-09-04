// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What stands on a lot BESIDES the building: fences, and the signs that make
/// a shop read as a shop.
///
/// A colony where every plot is a box on bare ground reads as a model, not a
/// place. What tells you which is which at street level is the boundary
/// treatment — a picket fence around a house, chain link around a works, a lit
/// sign over a shopfront — and each of those is a property of what the lot is
/// ZONED, which the frame already carries in the building's type.
///
/// Derived on the client from the building itself, the way street lamps and
/// junctions already are: the rule is deterministic and a thousand fence posts
/// per colony is a lot of wire for something both ends can compute.
library;

import 'dart:math' as math;

import '../../../domain/architecture/building_massing.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'city_texture_bakes.dart';
import 'road_mesher.dart';
import 'vehicle_meshes.dart';

/// What a lot's boundary is dressed with.
enum LotEdging {
  /// Painted timber pickets. Low and medium density housing.
  picket,

  /// Chain link on steel posts. Medium and heavy industry.
  chainLink,

  /// Nothing — towers meet the pavement, and a works too small to fence.
  none,
}

class LotFeatures {
  const LotFeatures._();

  /// The edging a lot of this zone type takes.
  ///
  /// Density decides as much as kind does: a house has a garden to enclose and
  /// a tower does not, a heavy works has something worth fencing and a
  /// two-person workshop does not.
  static LotEdging edgingFor(String type) => switch (type) {
        'r-low' || 'r-med' => LotEdging.picket,
        'i-med' || 'i-high' => LotEdging.chainLink,
        _ => LotEdging.none,
      };

  /// Whether this lot carries a lit sign. Commercial, at every density — a
  /// corner shop has a sign as surely as a mall does.
  static bool signFor(String type) =>
      type == 'c-low' || type == 'c-med' || type == 'c-high';

  /// Fence the rectangle [halfW] x [halfD] about [centre].
  ///
  /// [along] is the lot's depth axis and [up] its local radial. Posts and
  /// rails are boxes.
  ///
  /// [coarse] swaps the per-picket posts for structural posts only — rails
  /// and spacing a chain-link fence would have. A picket every 16 cm is
  /// sixteen vertices each, which is what a fence IS from arm's length and
  /// several hundred thousand vertices a colony from anywhere else: lots the
  /// camera resolves as boxes were spending far more mesh on their fences
  /// than on their buildings, and the fences were sub-pixel.
  static void emitFence(
    MeshBuilder m,
    LotEdging kind,
    Vector3 centre,
    Vector3 along,
    Vector3 up,
    double halfW,
    double halfD, {
    bool coarse = false,
  }) {
    if (kind == LotEdging.none) return;
    final side = along.cross(up).normalized;
    final picket = kind == LotEdging.picket;
    final height = picket ? 1.05 : 2.4;
    final spacing = picket && !coarse ? 0.16 : 2.6;
    final postR = picket ? 0.035 : 0.05;

    // Walk the four edges. The street edge (front) is left OPEN so the lot has
    // a way in — a fully enclosed plot reads as a compound.
    final corners = <(Vector3, Vector3)>[
      (centre - side * halfW - along * halfD,
          centre - side * halfW + along * halfD),
      (centre + side * halfW - along * halfD,
          centre + side * halfW + along * halfD),
      (centre - side * halfW + along * halfD,
          centre + side * halfW + along * halfD),
    ];

    for (final (a, b) in corners) {
      final run = b - a;
      final len = run.length;
      if (len < 0.5) continue;
      final dir = run * (1 / len);
      final n = dir.cross(up).normalized;

      // Uprights.
      final count = math.max(2, (len / spacing).floor());
      for (var i = 0; i <= count; i++) {
        final p = a + dir * (len * i / count);
        _post(m, p, up, dir, n, postR, height);
      }
      // Rails: a picket has two, chain link a top rail only.
      for (final h in picket ? const [0.35, 0.92] : const [0.98]) {
        _rail(m, a, b, up, n, height * h, picket ? 0.03 : 0.04);
      }
      // Chain link reads as a MESH panel: one thin translucent-ish slab per
      // run, which at any distance a fence is seen from is what the wire does.
      if (!picket) {
        _panel(m, a, b, up, n, height);
      }
    }
  }

  /// A lit sign standing at the front of a commercial lot.
  ///
  /// Two pieces: a dark box on a post ([solid]) and the face ([glow]), which
  /// goes on the glazing material so it lights at night the way the windows
  /// already do.
  static void emitSign(
    MeshBuilder solid,
    MeshBuilder glow,
    Vector3 centre,
    Vector3 along,
    Vector3 up,
    double halfW,
    double halfD,
    double scale,
  ) {
    final side = along.cross(up).normalized;
    // At the street edge, offset to one side so it never sits in a doorway.
    final base = centre - along * (halfD * 0.92) + side * (halfW * 0.55);
    final postH = (2.4 * scale).clamp(2.0, 7.0);
    final boardW = (1.9 * scale).clamp(1.2, 5.0);
    final boardH = (0.85 * scale).clamp(0.6, 2.4);

    _post(solid, base, up, along, side, 0.07, postH);
    final face = base + up * (postH + boardH / 2);
    // Board back, then the lit face a hair in front of it so the two never
    // z-fight for the same pixels.
    _board(solid, face, side, up, boardW / 2, boardH / 2, along * -0.03);
    _board(glow, face, side, up, boardW / 2 * 0.92, boardH / 2 * 0.86,
        along * 0.03);
  }

  static void _post(MeshBuilder m, Vector3 base, Vector3 up, Vector3 along,
      Vector3 side, double r, double h) {
    final c = [
      base - side * r - along * r,
      base + side * r - along * r,
      base + side * r + along * r,
      base - side * r + along * r,
    ];
    final top = [for (final v in c) v + up * h];
    for (var i = 0; i < 4; i++) {
      final j = (i + 1) % 4;
      final n = (c[i] + c[j]) * 0.5 - base;
      final nn = n.length < 1e-6 ? up : n.normalized;
      final q = [
        m.vertex(c[i] * kRenderScale, nn, 0, 1),
        m.vertex(c[j] * kRenderScale, nn, 1, 1),
        m.vertex(top[j] * kRenderScale, nn, 1, 0),
        m.vertex(top[i] * kRenderScale, nn, 0, 0),
      ];
      m.quad(q[0], q[1], q[2], q[3]);
    }
  }

  static void _rail(MeshBuilder m, Vector3 a, Vector3 b, Vector3 up, Vector3 n,
      double h, double t) {
    final lo = h - t, hi = h + t;
    final q = [
      m.vertex((a + up * lo) * kRenderScale, n, 0, 1),
      m.vertex((b + up * lo) * kRenderScale, n, 1, 1),
      m.vertex((b + up * hi) * kRenderScale, n, 1, 0),
      m.vertex((a + up * hi) * kRenderScale, n, 0, 0),
    ];
    m.quad(q[0], q[1], q[2], q[3]);
  }

  static void _panel(MeshBuilder m, Vector3 a, Vector3 b, Vector3 up, Vector3 n,
      double h) {
    final q = [
      m.vertex((a + up * 0.05) * kRenderScale, n, 0, 1),
      m.vertex((b + up * 0.05) * kRenderScale, n, 1, 1),
      m.vertex((b + up * h) * kRenderScale, n, 1, 0),
      m.vertex((a + up * h) * kRenderScale, n, 0, 0),
    ];
    m.quad(q[0], q[1], q[2], q[3]);
  }

  static void _board(MeshBuilder m, Vector3 centre, Vector3 side, Vector3 up,
      double hw, double hh, Vector3 offset) {
    final n = offset.length < 1e-9 ? up : offset.normalized;
    final c = centre + offset;
    final q = [
      m.vertex((c - side * hw - up * hh) * kRenderScale, n, 0, 1),
      m.vertex((c + side * hw - up * hh) * kRenderScale, n, 1, 1),
      m.vertex((c + side * hw + up * hh) * kRenderScale, n, 1, 0),
      m.vertex((c - side * hw + up * hh) * kRenderScale, n, 0, 0),
    ];
    m.quad(q[0], q[1], q[2], q[3]);
  }

  /// A parking bay: how wide and how deep.
  static const double bayW = 2.6;
  static const double bayD = 5.2;

  /// The aisle between two facing ranks of bays.
  static const double aisleM = 6.0;

  /// A driveway's width, and a footpath's.
  static const double drivewayM = 6.0;
  static const double pathM = 1.5;

  /// The car park the massing put INSIDE the parcel, dressed: the bays
  /// painted on it and the cars standing in them, the driveway joining it to
  /// its road — across the sidewalk with a curb cut when the road is out
  /// front, into the alley when the lot is at the back — and the footpath
  /// from the lot to the building's entrance.
  ///
  /// Everything is in the building's own plan frame: [centre] is the
  /// parcel's centroid, [side] runs along the street, [along] from the
  /// street into the lot. [lot] and [entrance] are the massing's, so the
  /// paint lands on the slab the building mesh already carries and the
  /// path ends at the door the facade actually has. [frontLineY] and
  /// [rearLineY] are the parcel's lot lines; [sidewalkM] the walk between
  /// the front line and the curb. With [behind], the lot is at the back and
  /// the driveway leaves by the rear line; [rearDoorY] is the back wall the
  /// path then runs to. [occupancy] is the share of bays filled.
  ///
  /// Returns the number of cars placed, so a caller can budget them.
  static int emitLot(
    MeshBuilder paving,
    MeshBuilder cars,
    MeshBuilder glass,
    Vector3 centre,
    Vector3 side,
    Vector3 along,
    Vector3 up,
    ParkingLot lot,
    (double, double) entrance, {
    required double frontLineY,
    required double rearLineY,
    required bool behind,
    required double rearDoorY,
    required double occupancy,
    required bool airless,
    double sidewalkM = 3.0,
    int maxCars = 24,
    bool detailed = true,
  }) {
    Vector3 at(double x, double y) => centre + side * x + along * y;
    final x0 = lot.x - lot.width / 2, x1 = lot.x + lot.width / 2;
    final y0 = lot.y - lot.depth / 2, y1 = lot.y + lot.depth / 2;
    // Over the slab the building mesh draws (8 cm) and the zoned-lot patch
    // under it, under nothing else.
    const slabTop = 0.10;
    const paintLift = slabTop + RoadMesher.paintLiftM;
    final asphalt = CityTextureBakes.roadAsphalt;
    final concrete = CityTextureBakes.roadConcrete;
    final white = CityTextureBakes.roadWhite;

    // The lot's surface: asphalt over the massing's concrete slab, so a car
    // park reads as tarmac against the pale slab and the lot's green.
    _quad(paving, at, up, x0, y0, x1, y1, asphalt, slabTop);

    // ---- The driveway: the lot's road-side edge to the road ---------------
    //
    // At the end of the lot away from the entrance, so the drive and the
    // footpath never cross; six metres wide, two cars passing.
    final driveX = entrance.$1 <= lot.x
        ? x1 - drivewayM / 2 - 0.5
        : x0 + drivewayM / 2 + 0.5;
    if (behind) {
      // Out the back into the alley: a metre past the lot line, so the two
      // surfaces overlap rather than meet at a seam.
      _quad(paving, at, up, driveX - drivewayM / 2, y1, driveX + drivewayM / 2,
          rearLineY + 1.0, asphalt, slabTop);
    } else {
      // Across the front setback to the lot line...
      if (frontLineY < y0 - 0.2) {
        _quad(paving, at, up, driveX - drivewayM / 2, frontLineY,
            driveX + drivewayM / 2, y0 + 0.3, asphalt, slabTop);
      }
      // ...and over the sidewalk to the curb as a concrete apron at the
      // walk's own height — the dropped curb a driveway crosses the
      // pavement on. It overlaps the walk rather than cutting it.
      if (sidewalkM > 0) {
        _quad(paving, at, up, driveX - drivewayM / 2 - 0.4,
            frontLineY - sidewalkM, driveX + drivewayM / 2 + 0.4,
            frontLineY + 0.2, concrete, RoadMesher.walkTopLiftM + 0.02);
      }
    }

    // ---- The bays -----------------------------------------------------------
    //
    // Ranks of bays perpendicular to the street along the lot's long edges:
    // one rank against the building side when the lot is shallow, two facing
    // each other across an aisle when there is room. The driveway's own lane
    // is kept clear.
    final twoRanks = lot.depth >= bayD * 2 + aisleM;
    final buildingSide = behind ? y0 : y1;
    final streetSide = behind ? y1 : y0;
    final ranks = <(double edgeY, double nose)>[
      // (the edge the bay backs onto, which way the car's nose points)
      (buildingSide, behind ? -1.0 : 1.0),
      if (twoRanks) (streetSide, behind ? 1.0 : -1.0),
    ];
    final family = airless ? VehicleKind.airless : VehicleKind.road;
    var placed = 0;
    final filled = (lot.spaces * occupancy.clamp(0.0, 1.0)).round();
    var bay = 0;
    for (final (edgeY, nose) in ranks) {
      final count = ((x1 - x0 - 1.0) / bayW).floor();
      if (count <= 0) continue;
      final start = x0 + 0.5 + ((x1 - x0 - 1.0) - count * bayW) / 2;
      final inner = edgeY - nose * bayD; // the aisle side of the rank
      for (var i = 0; i <= count; i++) {
        final x = start + i * bayW;
        // The line between bays, from the edge into the lot.
        if (detailed) {
          _quad(paving, at, up, x - 0.06, math.min(edgeY, inner), x + 0.06,
              math.max(edgeY, inner), white, paintLift);
        }
        if (i == count) break;
        final cx = x + bayW / 2;
        if ((cx - driveX).abs() < drivewayM / 2 + bayW / 2) continue;
        // A car in this bay? Fill from the entrance end, so a half-full lot
        // reads as half full rather than as randomly speckled.
        if (placed < filled && placed < maxCars && bay < lot.spaces) {
          final kind = family[(bay * 7 + i) % family.length];
          if (kind.lengthM <= bayD * 1.1) {
            final carAt = at(cx, edgeY - nose * bayD / 2);
            VehicleMeshes.emit(cars, glass, kind, carAt, along * nose, up,
                u: 0.5);
            placed++;
          }
        }
        bay++;
      }
    }

    // ---- The footpath -------------------------------------------------------
    //
    // From the entrance to the street: across the front setback (and the
    // front lot if there is one, as a marked walkway over it) to the lot
    // line, where the sidewalk takes over. And from a rear lot to the back
    // door, which is what a rear lot is for.
    final (ex, ey) = entrance;
    if (ey - frontLineY > 0.6) {
      _quad(paving, at, up, ex - pathM / 2, frontLineY - 0.2, ex + pathM / 2,
          ey + 0.1, concrete, paintLift + 0.005);
    }
    if (behind && y0 - rearDoorY > 0.3) {
      _quad(paving, at, up, ex - pathM / 2, rearDoorY - 0.1, ex + pathM / 2,
          y0 + 0.2, concrete, paintLift + 0.005);
    }
    return placed;
  }

  /// A flat quad in plan metres, [x0]..[x1] across and [y0]..[y1] along,
  /// mapping one band of the road atlas across itself.
  static void _quad(
    MeshBuilder m,
    Vector3 Function(double x, double y) at,
    Vector3 up,
    double x0,
    double y0,
    double x1,
    double y1,
    int band,
    double lift,
  ) {
    if (x1 - x0 < 1e-6 || y1 - y0 < 1e-6) return;
    final o = up * lift;
    final u0 = RoadMesher.bandU(band, 0), u1 = RoadMesher.bandU(band, 1);
    final v1 = (y1 - y0) / RoadMesher.tileM;
    final q = [
      m.vertex((at(x0, y0) + o) * kRenderScale, up, u0, 0),
      m.vertex((at(x1, y0) + o) * kRenderScale, up, u1, 0),
      m.vertex((at(x1, y1) + o) * kRenderScale, up, u1, v1),
      m.vertex((at(x0, y1) + o) * kRenderScale, up, u0, v1),
    ];
    m.quad(q[0], q[1], q[2], q[3]);
  }
}
