// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// One section of the sprawl, grown into meshes at a level of detail.
///
/// Four tiers, by distance from the focus:
///
/// - **far**: silhouettes. Each street's houses are runs of one low box —
///   the roofline of a subdivision, the way the plat's block tier is one
///   merged skyline — and nothing is painted on the ground. A distant
///   suburb is a grey texture of roofs, not a coloured parcel.
/// - **mid**: every house a flat block on its street.
/// - **near**: gabled houses with their windows, sidewalks with a curb on
///   every local street, stop signs at every crossing and a roundabout
///   where the collectors cross, yard and park trees, utility poles
///   carrying their wires, bus shelters on the arterials, a water tower
///   here and there.
/// - **close**: the clutter of a street you can stand on — driveways with a
///   car in them, mailboxes at the curb, board fences round back yards,
///   pools, fire hydrants.
///
/// The streets are a NETWORK, not a set of ribbons: every one is drawn
/// through the same [RoadMesher] the platted core uses, every crossing is
/// a junction with its own control, the two collectors on each axis run
/// out to the county highway and meet it at the junction the plan put
/// there, and every other street ends in a turning circle short of the
/// section line — the shape of a real subdivision.
///
/// A section is emitted as parts (see [SprawlSectionBuilder.steps]) so the
/// renderer can spread a build over frames. Everything that must look the
/// same from one tier to the next — which houses stand where, where the
/// water tower is — draws its own seeded random stream, so the order the
/// parts run in, and which tier asked, changes nothing.
library;

import 'dart:math' as math;

import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/architecture/architecture_style.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/colony/city/road_junction.dart';
import '../../../domain/colony/city/sprawl_plan.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/quaternion.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'city_nodes.dart';
import 'city_texture_bakes.dart';
import 'oriented_box.dart';
import 'road_mesher.dart';
import 'street_furniture.dart';
import 'vehicle_meshes.dart';

/// How much of a section is drawn, nearest first.
enum SprawlTier { close, near, mid, far }

/// The ground palette's cursor cyan doubles as pool water: the palette has
/// no water swatch, and a pool is the one blue thing in a suburb.
const int _poolSwatch = 5;

/// Tree crowns take the leaf band of the ground palette: the facade atlas
/// has no green, and a suburb from the air is roofs in trees.
const double _leafU = (kLeafSwatch + 0.5) / kGroundSwatches;

/// The street rides this far above the draped ground, clear of the terrain
/// between its samples, before the mesher's own lift; the sidewalk stands
/// a curb above that.
const double _roadLiftM = 0.4;

/// A local street's half width: two four-metre lanes.
const double _streetHalfM = 3.5;

/// A suburban sidewalk's width, curb to lawn.
const double _walkM = 2.0;

/// The turning circle at a dead end, and how far short of the section
/// line the street stops to make room for it.
const double _bulbRadiusM = 11.0;
const double _deadEndInsetM = 45.0;

/// Roofs, trunks, posts and mailboxes take the dark pressed brick off the
/// facade atlas: dark shingles are what a roof is from above, and it is
/// the contrast with the ground that makes the far silhouettes read.
const double _roofU = (FacadeMaterial.darkBrick + 0.5) / kFacadeMaterials;

/// Grows one section's geometry into a group's builders.
class SprawlSectionBuilder {
  SprawlSectionBuilder(
    this.s,
    this.anchorBF,
    this.groundRadiusAt,
    this.corridors, {
    this.clearings = const [],
    this.nodePoints = const [],
  }) : centre = Vector3(s.px, s.py, s.pz),
       east = Quaternion(s.qw, s.qx, s.qy, s.qz).rotate(Vector3.unitX),
       north = Quaternion(s.qw, s.qx, s.qy, s.qz).rotate(Vector3.unitY),
       up = Quaternion(s.qw, s.qx, s.qy, s.qz).rotate(Vector3.unitZ),
       rnd = math.Random(s.seed),
       centreRadius = Vector3(s.px, s.py, s.pz).length;

  final SprawlSectionSnapshot s;
  final Vector3 anchorBF;
  final double Function(Vector3)? groundRadiusAt;
  final List<List<Vector3>> corridors;

  /// The colony's staked plots as flat e/n polygons: an installation's
  /// site, the station's. Nothing of the section is built on them.
  final List<List<double>> clearings;

  /// Where the plan's junctions are, body-fixed. A collector runs out to
  /// the county highway only where the plan put a junction for it; where
  /// it did not — the highway is broken there, or the ground is somebody's
  /// plot — the street ends in a turning circle like any other.
  final List<Vector3> nodePoints;
  final Vector3 centre, east, north, up;
  final math.Random rnd;
  final double centreRadius;

  double get half => s.sizeM / 2;
  SprawlUse get use =>
      SprawlUse.values[s.use.clamp(0, SprawlUse.values.length - 1)];

  /// Local streets across the section each way: the plan's number, so the
  /// collectors land where the plan put their junctions.
  int get streetsAcross => SprawlSection.streetsAcrossFor(use);

  /// The street grid: which lines the streets run on, and which of them
  /// are the collectors. The section's own survey grid, or — next to the
  /// core — the plat's lines carried on.
  late final _Grid grid = _Grid.of(this);

  /// Whether the streets are the plat's own lines carried on.
  bool get continuesCoreGrid => s.linesE.isNotEmpty || s.linesN.isNotEmpty;

  /// Whether the plan has a junction at local (e, n).
  ///
  /// Measured ACROSS the ground, not through it: the plan's nodes are
  /// draped on the real terrain with a little lift, and the section's own
  /// point may stand on a nominal radius when no ground query is to hand,
  /// so the two can differ by metres radially while being the same place.
  bool hasNodeAt(double e, double n) {
    final p = centre + east * e + north * n;
    final upv = p.normalized;
    for (final q in nodePoints) {
      final d = q - p;
      final flat = d - upv * d.dot(upv);
      if (flat.lengthSquared < 64) return true;
    }
    return false;
  }

  /// A local (e, n) on the section, draped onto the ground, [lift] above
  /// it, relative to the anchor.
  Vector3 at(double e, double n, {double lift = 0}) {
    final flat = centre + east * e + north * n;
    final dir = flat.normalized;
    final ground = groundRadiusAt?.call(dir) ?? centreRadius;
    return dir * (ground + lift) - anchorBF;
  }

  /// The ground radius under a local point, for standing a box on it.
  double groundAt(double e, double n) {
    final dir = (centre + east * e + north * n).normalized;
    return groundRadiusAt?.call(dir) ?? centreRadius;
  }

  /// Whether a local point lies on the platted core, [marginM] out from its
  /// outline. The plat draws its own streets and buildings; the section's
  /// houses keep the depth of the plat's outermost lots off it.
  bool inCore(double e, double n, {double marginM = 60}) {
    if (s.coreRadiusM <= 0) return false;
    final ce = s.originE + e, cn = s.originN + n;
    return math.sqrt(ce * ce + cn * cn) <
        s.coreRadiusAt(math.atan2(cn, ce)) + marginM;
  }

  /// Whether a local point lies in an interstate or ramp corridor, on a
  /// staked plot — or, with [core], on the platted core.
  bool inCorridor(double e, double n, {double clearM = 45, bool core = true}) {
    final ce = s.originE + e, cn = s.originN + n;
    if (core && inCore(e, n)) return true;
    for (final poly in clearings) {
      if (SprawlSpec.inFlatPolygonBox(poly, ce, cn, 12)) return true;
    }
    final p = centre + east * e + north * n;
    for (final pts in corridors) {
      for (var i = 1; i < pts.length; i++) {
        final a = pts[i - 1], b = pts[i];
        // Cheap reject on the segment's bounding sphere.
        if ((p - a).length > 200 && (p - b).length > 200) continue;
        final ab = b - a;
        final len2 = ab.lengthSquared;
        final t = len2 < 1e-9 ? 0.0 : ((p - a).dot(ab) / len2).clamp(0.0, 1.0);
        if ((p - (a + ab * t)).length < clearM) return true;
      }
    }
    return false;
  }

  /// The section's geometry as parts, each a few milliseconds: the caller
  /// runs them across frames. Ordered so the ground and the streets land
  /// before the buildings on them, and the buildings before their clutter.
  List<void Function()> steps(
    SprawlTier tier,
    MeshBuilder ground,
    MeshBuilder road,
    MeshBuilder walk,
    MeshBuilder solid,
    MeshBuilder glass,
  ) {
    final out = <void Function()>[];
    final detailed = tier == SprawlTier.near || tier == SprawlTier.close;
    final close = tier == SprawlTier.close;
    final walks = detailed ? walk : null;
    switch (use) {
      case SprawlUse.parkland:
        if (detailed) {
          for (var k = 0; k < 3; k++) {
            out.add(() => _trees(ground, 30));
          }
          out.add(() => _broadleaves(ground, solid, 40));
        }
      case SprawlUse.farmland:
        out.add(() => _fields(ground, tier));
        if (tier != SprawlTier.far) {
          out.add(() => _farmstead(ground, solid, glass, tier));
        }
      case SprawlUse.residential:
        if (tier == SprawlTier.far) {
          out.add(() => _rows(solid, s.density));
        } else {
          out.add(() => _streets(road, walks, solid, glass, tier));
          out.addAll(_houseSteps(ground, road, solid, glass, tier, s.density));
          if (detailed) {
            out.add(() => _poles(solid));
            out.add(() => _busStops(solid, glass));
            out.add(() => _waterTower(solid, 0.22));
          }
          if (close) out.add(() => _hydrants(solid));
        }
      case SprawlUse.commercial:
        if (tier == SprawlTier.far) {
          out.add(() => _strip(road, solid, glass, tier));
          out.add(() => _rows(solid, s.density * 0.55, inset: 220));
        } else {
          out.add(() => _streets(road, walks, solid, glass, tier));
          out.add(() => _strip(road, solid, glass, tier));
          out.addAll(
            _houseSteps(
              ground,
              road,
              solid,
              glass,
              tier,
              s.density * 0.55,
              inset: 220,
            ),
          );
          if (detailed) {
            out.add(() => _poles(solid));
            out.add(() => _busStops(solid, glass));
            out.add(() => _waterTower(solid, 0.3));
          }
          if (close) out.add(() => _hydrants(solid));
        }
      case SprawlUse.industrial:
        if (tier == SprawlTier.far) {
          out.add(() => _sheds(road, solid, tier));
        } else {
          out.add(() => _streets(road, walks, solid, glass, tier));
          out.add(() => _sheds(road, solid, tier));
          if (detailed) {
            out.add(() => _poles(solid));
            out.add(() => _waterTower(solid, 0.35));
          }
        }
    }
    // Run in the order listed: the caller pops from the end.
    return out.reversed.toList();
  }

  /// A quad on the ground palette, draped on a [subdiv] x [subdiv] lattice
  /// so a big one follows the hills instead of cutting through them.
  void _groundQuad(
    MeshBuilder m,
    double e0,
    double n0,
    double e1,
    double n1,
    int kind, {
    double lift = 0.25,
    int subdiv = 1,
  }) {
    final u = (kind + 0.5) / kGroundSwatches;
    final rows = <List<int>>[];
    for (var j = 0; j <= subdiv; j++) {
      final row = <int>[];
      for (var i = 0; i <= subdiv; i++) {
        final p = at(
          e0 + (e1 - e0) * i / subdiv,
          n0 + (n1 - n0) * j / subdiv,
          lift: lift,
        );
        row.add(m.vertex(_s(p), (p + anchorBF).normalized, u, 0.5));
      }
      rows.add(row);
    }
    for (var j = 0; j < subdiv; j++) {
      for (var i = 0; i < subdiv; i++) {
        m.quad(rows[j][i], rows[j][i + 1], rows[j + 1][i + 1], rows[j + 1][i]);
      }
    }
  }

  /// A quad on the road atlas — asphalt for a lot, concrete for a path, white
  /// for a bay line — draped like [_groundQuad]. Lots, driveways and
  /// footpaths are paving, and paving is what the road material is.
  void _pavedQuad(
    MeshBuilder m,
    double e0,
    double n0,
    double e1,
    double n1,
    int band, {
    double lift = 0.4,
    int subdiv = 1,
  }) {
    if (e1 - e0 < 1e-6 || n1 - n0 < 1e-6) return;
    final u0 = RoadMesher.bandU(band, 0), u1 = RoadMesher.bandU(band, 1);
    final rows = <List<int>>[];
    for (var j = 0; j <= subdiv; j++) {
      final row = <int>[];
      for (var i = 0; i <= subdiv; i++) {
        final p = at(
          e0 + (e1 - e0) * i / subdiv,
          n0 + (n1 - n0) * j / subdiv,
          lift: lift,
        );
        row.add(
          m.vertex(
            _s(p),
            (p + anchorBF).normalized,
            u0 + (u1 - u0) * i / subdiv,
            (n1 - n0) * j / subdiv / RoadMesher.tileM,
          ),
        );
      }
      rows.add(row);
    }
    for (var j = 0; j < subdiv; j++) {
      for (var i = 0; i < subdiv; i++) {
        m.quad(rows[j][i], rows[j][i + 1], rows[j + 1][i + 1], rows[j + 1][i]);
      }
    }
  }

  /// Paint the bay lines of a rank of bays: lines every [bayW] along the
  /// rank from [a0] to [a1], each [bayD] long from [edge] toward [into].
  void _bayLines(
    MeshBuilder road,
    int axis,
    double a0,
    double a1,
    double edge,
    double into, {
    double lift = 0.4,
  }) {
    const bayW = 2.8, bayD = 5.2;
    final lo = math.min(edge, edge + (into - edge).sign * bayD);
    final hi = math.max(edge, edge + (into - edge).sign * bayD);
    for (var a = a0; a <= a1 + 1e-6; a += bayW) {
      if (axis == 0) {
        _pavedQuad(
          road,
          a - 0.06,
          lo,
          a + 0.06,
          hi,
          CityTextureBakes.roadWhite,
          lift: lift + 0.03,
        );
      } else {
        _pavedQuad(
          road,
          lo,
          a - 0.06,
          hi,
          a + 0.06,
          CityTextureBakes.roadWhite,
          lift: lift + 0.03,
        );
      }
    }
  }

  // ---- Far: silhouettes ---------------------------------------------------

  /// Each street's frontage as runs of one low box, both sides, on the
  /// same streets the nearer tiers draw houses along. Each run is a few
  /// houses long with a gap before the next, so the roofline breaks the
  /// way a real street's does.
  void _rows(MeshBuilder solid, double density, {double inset = 0}) {
    if (streetsAcross == 0) return;
    final spacing = 17.0 + (1 - density) * 16;
    for (var axis = 0; axis < 2; axis++) {
      final lines = grid.lines(axis);
      final blocks = grid.blocks(axis);
      for (var k = 0; k < lines.length; k++) {
        final t = lines[k];
        final rowRnd = math.Random(s.seed * 31 + axis * 1009 + (k + 1));
        for (final (b0, b1) in blocks) {
          // A block's frontage, inset from its corners: the other axis has
          // the corner houses, the way [_houseSteps] gives them to it.
          final corner = axis == 1 ? 34.0 : 8.0;
          var a = math.max(-half + 60 + inset, b0 + corner);
          final end = math.min(half - 60 - inset, b1 - corner);
          while (a < end) {
            final run = spacing * (3 + rowRnd.nextInt(4));
            final gap = spacing * (0.6 + rowRnd.nextDouble() * 1.4);
            final b = math.min(end, a + run);
            if (b - a > spacing * 1.5 && rowRnd.nextDouble() < density + 0.2) {
              final h = rowRnd.nextDouble() < 0.35 ? 6.4 : 4.8;
              for (final side in const [-1.0, 1.0]) {
                final off = t + side * 17.5;
                final mid = (a + b) / 2;
                final e = axis == 0 ? mid : off, nn = axis == 0 ? off : mid;
                if (inCorridor(e, nn)) continue;
                _rowBox(
                  solid,
                  e,
                  nn,
                  axis == 0 ? b - a - 3 : 9.5,
                  axis == 0 ? 9.5 : b - a - 3,
                  h,
                );
              }
            }
            a = b + gap;
          }
        }
      }
    }
  }

  /// A run of roofs: a long low box without its end walls, which from the
  /// height a far section is seen at are sub-pixel — and a section holds
  /// a thousand of these.
  void _rowBox(
    MeshBuilder m,
    double e,
    double n,
    double w,
    double d,
    double h,
  ) {
    final base = at(e, n);
    final upv = (base + anchorBF).normalized;
    final hw = w / 2, hd = d / 2;
    final c = [
      base + east * -hw + north * -hd,
      base + east * hw + north * -hd,
      base + east * hw + north * hd,
      base + east * -hw + north * hd,
    ];
    final t = [for (final p in c) p + upv * h];
    final faces = w >= d
        ? [(0, 1, north * -1), (2, 3, north)]
        : [(1, 2, east), (3, 0, east * -1)];
    for (final (i, j, nn) in faces) {
      m.quad(
        m.vertex(_s(c[i]), nn, 0.5, 0),
        m.vertex(_s(c[j]), nn, 0.5, 0),
        m.vertex(_s(t[j]), nn, 0.5, 1),
        m.vertex(_s(t[i]), nn, 0.5, 1),
      );
    }
    final r = [for (final p in t) m.vertex(_s(p), upv, _roofU, 0.5)];
    m.quad(r[0], r[1], r[2], r[3]);
  }

  // ---- Country ------------------------------------------------------------

  /// Fields: a four-by-four of alternating tilled and green, and a lane.
  void _fields(MeshBuilder ground, SprawlTier tier) {
    final cells = tier == SprawlTier.far ? 2 : 4;
    final size = s.sizeM / cells;
    for (var i = 0; i < cells; i++) {
      for (var j = 0; j < cells; j++) {
        final tilled = rnd.nextDouble() < 0.5;
        final e0 = -half + i * size + 12, n0 = -half + j * size + 12;
        if (inCorridor(e0 + size / 2, n0 + size / 2, clearM: 70)) continue;
        _groundQuad(
          ground,
          e0,
          n0,
          e0 + size - 24,
          n0 + size - 24,
          tilled
              ? CityPatchSnapshot.kindIndustrial
              : CityPatchSnapshot.kindResidential,
          lift: 0.3,
          subdiv: tier == SprawlTier.far ? 4 : 3,
        );
      }
    }
  }

  void _farmstead(
    MeshBuilder ground,
    MeshBuilder solid,
    MeshBuilder glass,
    SprawlTier tier,
  ) {
    final e = (rnd.nextDouble() - 0.5) * s.sizeM * 0.6;
    final n = (rnd.nextDouble() - 0.5) * s.sizeM * 0.6;
    if (inCorridor(e, n, clearM: 80)) return;
    final detailed = tier == SprawlTier.near || tier == SprawlTier.close;
    _house(solid, glass, e, n, 13, 9, 6.5, detailed, rnd.nextBool());
    _box(solid, e + 26, n + 4, 22, 12, 7.5, gable: detailed);
    _box(solid, e + 40, n - 10, 5, 5, 11, gable: false);
    if (detailed) {
      // The shade trees every farmhouse has, and its own pole line.
      final treeRnd = math.Random(s.seed ^ 0x7BEE);
      _broadleaf(ground, solid, e - 12, n + 7, treeRnd);
      _broadleaf(ground, solid, e - 8, n - 9, treeRnd);
      if (tier == SprawlTier.close) {
        final c = at(e + 6, n - 2);
        final upv = (c + anchorBF).normalized;
        _fence(solid, c, north, upv, 24, 14);
      }
    }
  }

  // ---- Streets and what stands on them ------------------------------------

  /// The local street grid, as a network.
  ///
  /// Every street is a two-lane carriageway through the shared mesher,
  /// lanes painted from mid range. The two collectors on each axis run out
  /// to the section line and meet the county highway at the junction the
  /// plan put there; every other street — and a collector the plan gave no
  /// junction — ends in a turning circle short of the edge. Where streets
  /// cross there is a junction: an all-way stop, or a roundabout where the
  /// collectors cross each other. Near, a raised sidewalk with a curb each
  /// side of every block, broken at every crossing so it never bridges the
  /// cross street — the gap is where the curb cut is.
  ///
  /// Next to the core the streets are the plat's own lines carried on, and
  /// each starts a few metres INSIDE the outline, on top of the downtown
  /// street that ends there — one street, two renderers.
  void _streets(
    MeshBuilder road,
    MeshBuilder? walk,
    MeshBuilder solid,
    MeshBuilder glass,
    SprawlTier tier,
  ) {
    if (streetsAcross == 0) return;
    final paint = tier != SprawlTier.far;
    final detailed = tier == SprawlTier.near || tier == SprawlTier.close;
    // On the plat's grid a street overlaps the downtown street it carries
    // on by this much; on its own grid it keeps the depth of the plat's
    // outer lots off the outline.
    final coreMargin = continuesCoreGrid ? -12.0 : 60.0;
    const reachM = 160.0;

    (double, bool) endAt(int axis, double t, double sign, bool collector) {
      if (collector) {
        final e = axis == 0 ? sign * half : t;
        final nn = axis == 0 ? t : sign * half;
        final ei = axis == 0 ? sign * (half - reachM) : t;
        final ni = axis == 0 ? t : sign * (half - reachM);
        if (hasNodeAt(e, nn) && !inCorridor(ei, ni, clearM: 40)) {
          return (sign * half, true);
        }
      }
      return (sign * (half - _deadEndInsetM), false);
    }

    for (var axis = 0; axis < 2; axis++) {
      final lines = grid.lines(axis);
      final cross = grid.lines(1 - axis);
      for (var k = 0; k < lines.length; k++) {
        final t = lines[k];
        final collector = grid.collectors(axis).contains(k);
        final (a0, joinsA) = endAt(axis, t, -1, collector);
        final (a1, joinsB) = endAt(axis, t, 1, collector);
        // The street's runs: clear of the core (to the margin), then of
        // the corridors. The core's edge is found to the metre, so a
        // street on the plat's grid begins exactly where the downtown
        // street ends.
        for (final (r0, r1, atCoreA, atCoreB) in _coreSpans(
          axis,
          t,
          a0,
          a1,
          coreMargin,
        )) {
          var run = <Vector3>[];
          var runStart = r0;
          void flush(double runEnd, bool endsInCore) {
            if (run.length >= 2) {
              RoadMesher.carriageway(
                road,
                run,
                anchorBF,
                RoadClass.street,
                halfWidthM: _streetHalfM,
                liftM: _roadLiftM + RoadMesher.ribbonLiftM,
                paint: paint,
              );
              // Turning circles at the ends that go nowhere: not where the
              // street carries on into the downtown, and not where it
              // joins the highway.
              for (final (a, skip) in [
                (
                  runStart,
                  (runStart <= a0 + 1e-6 && joinsA) ||
                      (runStart <= r0 + 1e-6 && atCoreA),
                ),
                (
                  runEnd,
                  (runEnd >= a1 - 1e-6 && joinsB) ||
                      (runEnd >= r1 - 1e-6 && atCoreB),
                ),
              ]) {
                if (skip) continue;
                final e = axis == 0 ? a : t, nn = axis == 0 ? t : a;
                RoadMesher.culDeSac(
                  road,
                  at(e, nn),
                  anchorBF,
                  _bulbRadiusM,
                  liftM: _roadLiftM + RoadMesher.ribbonLiftM,
                );
              }
            }
            run = <Vector3>[];
          }

          final samples = math.max(2, ((r1 - r0) / 65).round());
          var prevA = r0;
          for (var q = 0; q <= samples; q++) {
            final a = r0 + (r1 - r0) * q / samples;
            final e = axis == 0 ? a : t, nn = axis == 0 ? t : a;
            if (inCorridor(e, nn, clearM: 40, core: false)) {
              flush(prevA, false);
              runStart = a;
              continue;
            }
            if (run.isEmpty) runStart = a;
            run.add(at(e, nn));
            prevA = a;
          }
          flush(r1, true);

          if (walk == null) continue;
          // One run of pavement per block between crossings, three samples
          // so it follows the ground, pulled back from each crossing: the
          // plate and its sign at a stop, the whole roundabout where two
          // collectors cross, the county highway's plate and zebra at a
          // collector's end, the turning circle at a dead end.
          final bounds = <double>[
            r0,
            ...cross.where((c) => c > r0 && c < r1),
            r1,
          ];
          for (var b = 0; b + 1 < bounds.length; b++) {
            final b0 = bounds[b], b1 = bounds[b + 1];
            double pullAt(double a, bool isRun0, bool isRun1) {
              if (isRun0 && a <= a0 + 1e-6) {
                return joinsA
                    ? RoadClass.avenue.halfWidth * 1.45 + 5.5
                    : _bulbRadiusM;
              }
              if (isRun1 && a >= a1 - 1e-6) {
                return joinsB
                    ? RoadClass.avenue.halfWidth * 1.45 + 5.5
                    : _bulbRadiusM;
              }
              if (isRun0 && atCoreA || isRun1 && atCoreB) return 0.0;
              if (isRun0 || isRun1) return _bulbRadiusM;
              final ci = cross.indexOf(a);
              final big =
                  collector &&
                  ci >= 0 &&
                  grid.collectors(1 - axis).contains(ci);
              return big ? 15.0 : _streetHalfM * 1.45 + 0.6;
            }

            final pull0 = pullAt(b0, b == 0, false);
            final pull1 = pullAt(b1, false, b + 2 == bounds.length);
            if (b1 - b0 < pull0 + pull1 + 10) continue;
            final pts = <Vector3>[];
            var clear = true;
            for (var q = 0; q <= 2; q++) {
              final a = b0 + (b1 - b0) * q / 2;
              final e = axis == 0 ? a : t, nn = axis == 0 ? t : a;
              if (inCorridor(e, nn, clearM: 40, core: false)) {
                clear = false;
                break;
              }
              pts.add(at(e, nn, lift: _roadLiftM));
            }
            if (!clear) continue;
            RoadMesher.sidewalks(
              walk,
              pts,
              _streetHalfM,
              _walkM,
              anchorBF,
              pullStart: pull0,
              pullEnd: pull1,
            );
          }
        }
      }
    }

    // The crossings. Stop signs all round, except where the collectors
    // cross: a subdivision builds a roundabout there.
    final junctions = <RoadJunction>[];
    final linesE = grid.lines(1), linesN = grid.lines(0);
    for (var ke = 0; ke < linesE.length; ke++) {
      for (var kn = 0; kn < linesN.length; kn++) {
        final e = linesE[ke], nn = linesN[kn];
        if (inCore(e, nn, marginM: coreMargin)) continue;
        if (inCorridor(e, nn, clearM: 40, core: false)) continue;
        final legs = [
          RoadLeg(east, _streetHalfM, RoadClass.street),
          RoadLeg(east * -1, _streetHalfM, RoadClass.street),
          RoadLeg(north, _streetHalfM, RoadClass.street),
          RoadLeg(north * -1, _streetHalfM, RoadClass.street),
        ];
        final control = junctionControlFor(
          [for (final l in legs) l.roadClass],
          roundaboutPreferred:
              grid.collectors(1).contains(ke) &&
              grid.collectors(0).contains(kn),
        );
        junctions.add(
          RoadJunction(at(e, nn), legs, control, liftM: _roadLiftM),
        );
      }
    }
    RoadMesher.junctions(
      road,
      solid,
      glass,
      junctions,
      anchorBF,
      0,
      furniture: detailed,
    );
  }

  /// The stretches of a street along [axis] at [t], between [a0] and [a1],
  /// that lie outside the core by [marginM]: each with whether its start
  /// and its end are AT the core (rather than at a0/a1). Walked in short
  /// steps and refined by bisection, so the edge is found to the metre.
  List<(double, double, bool, bool)> _coreSpans(
    int axis,
    double t,
    double a0,
    double a1,
    double marginM,
  ) {
    if (s.coreRadiusM <= 0) return [(a0, a1, false, false)];
    bool inside(double a) =>
        inCore(axis == 0 ? a : t, axis == 0 ? t : a, marginM: marginM);
    double edge(double lo, double hi) {
      // lo inside, hi outside (or the reverse): bisect to the metre.
      for (var i = 0; i < 12; i++) {
        final mid = (lo + hi) / 2;
        if (inside(mid) == inside(lo)) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      return (lo + hi) / 2;
    }

    final out = <(double, double, bool, bool)>[];
    const step = 24.0;
    double? open;
    var openAtCore = false;
    var prev = a0;
    var prevIn = inside(a0);
    if (!prevIn) open = a0;
    for (var a = a0 + step; a < a1 + step; a += step) {
      final here = math.min(a, a1);
      final nowIn = inside(here);
      if (nowIn != prevIn) {
        final x = edge(prev, here);
        if (nowIn) {
          // Went into the core: close the run.
          if (open != null) out.add((open, x, openAtCore, true));
          open = null;
        } else {
          open = x;
          openAtCore = true;
        }
      }
      prev = here;
      prevIn = nowIn;
      if (here >= a1) break;
    }
    if (open != null) out.add((open, a1, openAtCore, false));
    return [
      for (final r in out)
        if (r.$2 - r.$1 > 20) r,
    ];
  }

  /// Houses along every street, both sides, [pitch] apart across streets —
  /// one part per street, so a subdivision arrives a street at a time.
  ///
  /// Near, each house gets a front-yard tree at times; close, its driveway
  /// and what is parked on it, a mailbox, and behind it a fence or a pool.
  List<void Function()> _houseSteps(
    MeshBuilder ground,
    MeshBuilder road,
    MeshBuilder solid,
    MeshBuilder glass,
    SprawlTier tier,
    double density, {
    double inset = 0,
  }) {
    if (streetsAcross == 0) return const [];
    final spacing = 17.0 + (1 - density) * 16;
    final detailed = tier == SprawlTier.near || tier == SprawlTier.close;
    final close = tier == SprawlTier.close;
    final out = <void Function()>[];
    for (var axis = 0; axis < 2; axis++) {
      final lines = grid.lines(axis);
      final cross = grid.lines(1 - axis);
      for (var k = 0; k < lines.length; k++) {
        final t = lines[k];
        // Each street draws its own random stream, so the order the parts
        // run in does not change the houses.
        final streetRnd = math.Random(s.seed * 31 + axis * 1009 + (k + 1));
        out.add(() {
          var i = 0;
          for (
            var a = -half + 60 + inset;
            a < half - 60 - inset;
            a += spacing
          ) {
            for (final side in const [-1.0, 1.0]) {
              i++;
              if (streetRnd.nextDouble() > density) continue;
              final off = t + side * (3.5 + 14);
              final e = axis == 0 ? a : off, nn = axis == 0 ? off : a;
              if (inCorridor(e, nn)) continue;
              // Only one axis's houses per block corner: the frontage wins.
              if (axis == 1 && cross.any((c) => a - c >= 0 && a - c < 34)) {
                continue;
              }
              final w = 10 + streetRnd.nextDouble() * 4;
              final d = 8 + streetRnd.nextDouble() * 3;
              final h = streetRnd.nextDouble() < 0.4 ? 7.0 : 4.6;
              _house(
                solid,
                glass,
                e,
                nn,
                axis == 0 ? w : d,
                axis == 0 ? d : w,
                h,
                detailed,
                axis == 0,
              );
              if (!detailed) continue;
              // The yard's own stream: the same tree and car whichever of
              // the two detailed tiers is asking.
              final yardRnd = math.Random(
                s.seed * 7 + axis * 100003 + k * 1009 + i,
              );
              if (yardRnd.nextDouble() < 0.4) {
                final along = a - w / 2 - 3.5, perp = t + side * 8.5;
                _broadleaf(
                  ground,
                  solid,
                  axis == 0 ? along : perp,
                  axis == 0 ? perp : along,
                  yardRnd,
                );
              }
              if (close) {
                _yard(
                  ground,
                  road,
                  solid,
                  glass,
                  yardRnd,
                  axis,
                  side,
                  a,
                  off,
                  t,
                  w,
                  d,
                );
              }
            }
          }
        });
      }
    }
    return out;
  }

  /// One house's clutter. [a] is its centre along the street, [off] its
  /// centre across it, [t] the street's centreline, [side] which side of
  /// the street it stands on, [w] its frontage and [d] its depth.
  void _yard(
    MeshBuilder ground,
    MeshBuilder road,
    MeshBuilder solid,
    MeshBuilder glass,
    math.Random rnd,
    int axis,
    double side,
    double a,
    double off,
    double t,
    double w,
    double d,
  ) {
    // (along the street, across it) -> (e, n).
    (double, double) en(double along, double perp) =>
        axis == 0 ? (along, perp) : (perp, along);
    final alongAxis = axis == 0 ? east : north;
    final toBack = (axis == 0 ? north : east) * side;

    // The driveway: beside the house, curb to front wall, concrete — over
    // the sidewalk with a dropped curb, the way a driveway crosses it.
    const dw = 3.0;
    final da = a + w / 2 + 0.6 + dw / 2;
    final curb = t + side * 3.4;
    final front = off - side * (d / 2);
    {
      final (e0, n0) = en(da - dw / 2, math.min(curb, front));
      final (e1, n1) = en(da + dw / 2, math.max(curb, front));
      _pavedQuad(
        road,
        e0,
        n0,
        e1,
        n1,
        CityTextureBakes.roadConcrete,
        lift: _roadLiftM + RoadMesher.walkTopLiftM + 0.02,
      );
    }
    // The footpath from the driveway along the front of the house to its
    // door: a metre and a half wide, the door in the middle of the front.
    {
      final (e0, n0) = en(
        math.min(a, da - dw / 2),
        math.min(front, front - side * 1.5),
      );
      final (e1, n1) = en(
        math.max(a + 0.75, da - dw / 2),
        math.max(front, front - side * 1.5),
      );
      _pavedQuad(
        road,
        e0,
        n0,
        e1,
        n1,
        CityTextureBakes.roadConcrete,
        lift: _roadLiftM + 0.16,
      );
    }
    // A car on it, nose to the house.
    if (rnd.nextDouble() < 0.45) {
      final (ce, cn) = en(da, t + side * 9.0);
      final base = at(ce, cn);
      final upv = (base + anchorBF).normalized;
      final kind = rnd.nextDouble() < 0.5
          ? VehicleKind.sedan
          : VehicleKind.coupe;
      VehicleMeshes.emit(solid, glass, kind, base, toBack, upv, u: 0.5);
    }
    // The mailbox at the curb, across the driveway from the house.
    {
      final (me, mn) = en(da + dw / 2 + 0.6, t + side * 5.6);
      final base = at(me, mn);
      final upv = (base + anchorBF).normalized;
      OrientedBox.upright(
        solid,
        base,
        alongAxis,
        upv,
        0.1,
        0.1,
        1.05,
        u: _roofU,
      );
      OrientedBox.upright(
        solid,
        base + upv * 1.05,
        toBack,
        upv,
        0.22,
        0.48,
        0.24,
        u: _roofU,
      );
    }
    // The back yard: a board fence round some, a pool in a few.
    if (rnd.nextDouble() < 0.22) {
      final (fe, fn) = en(a, off + side * (d / 2 + 6.5));
      final c = at(fe, fn);
      final upv = (c + anchorBF).normalized;
      _fence(solid, c, toBack, upv, w / 2 + 2.5, 6.5);
    }
    if (rnd.nextDouble() < 0.12) {
      final (p0e, p0n) = en(a - 4, off + side * (d / 2 + 2.5));
      final (p1e, p1n) = en(a + 4, off + side * (d / 2 + 6.5));
      _groundQuad(
        ground,
        math.min(p0e, p1e),
        math.min(p0n, p1n),
        math.max(p0e, p1e),
        math.max(p0n, p1n),
        _poolSwatch,
        lift: 0.35,
      );
    }
  }

  /// A board fence round a back yard: posts and a panel per run, the
  /// street side open. Pickets are sub-pixel from the road and a section
  /// has hundreds of yards; boards are what most back yards have anyway.
  void _fence(
    MeshBuilder solid,
    Vector3 c,
    Vector3 back,
    Vector3 upv,
    double halfW,
    double halfD,
  ) {
    final side = back.cross(upv).normalized;
    final runs = <(Vector3, Vector3)>[
      (c - side * halfW - back * halfD, c - side * halfW + back * halfD),
      (c + side * halfW - back * halfD, c + side * halfW + back * halfD),
      (c - side * halfW + back * halfD, c + side * halfW + back * halfD),
    ];
    for (final (a, b) in runs) {
      final len = (b - a).length;
      if (len < 1) continue;
      final dir = (b - a) * (1 / len);
      final posts = math.max(1, (len / 2.6).round());
      for (var i = 0; i <= posts; i++) {
        OrientedBox.upright(
          solid,
          a + dir * (len * i / posts),
          dir,
          upv,
          0.12,
          0.12,
          1.9,
          u: _roofU,
        );
      }
      OrientedBox.emit(
        solid,
        (a + b) * 0.5 + upv * 0.95,
        dir.cross(upv).normalized,
        dir,
        upv,
        0.03,
        len / 2,
        0.85,
      );
    }
  }

  /// Utility poles down one verge of every east-west street, the wires
  /// slung between them. The cross streets go without: one line per block
  /// is what a subdivision has, and twice the poles for no more look.
  void _poles(MeshBuilder solid) {
    if (streetsAcross == 0) return;
    final poleRnd = math.Random(s.seed ^ 0x9E37);
    for (final line in grid.lines(0)) {
      final t = line - 5.9;
      Vector3? prevTop;
      for (
        var a = -half + 70 + poleRnd.nextDouble() * 20;
        a < half - 70;
        a += 50
      ) {
        if (inCorridor(a, t, clearM: 40)) {
          prevTop = null;
          continue;
        }
        final base = at(a, t);
        final upv = (base + anchorBF).normalized;
        OrientedBox.upright(solid, base, east, upv, 0.32, 0.32, 10.5);
        OrientedBox.emit(
          solid,
          base + upv * 9.9,
          north,
          east,
          upv,
          1.1,
          0.07,
          0.07,
        );
        final top = base + upv * 9.95;
        if (prevTop != null) {
          for (final off in const [-0.9, 0.9]) {
            OrientedBox.span(
              solid,
              prevTop + north * off,
              top + north * off,
              upv,
              0.07,
              0.07,
            );
          }
        }
        prevTop = top;
      }
    }
  }

  /// Hydrants along the curbs, a couple to a block.
  void _hydrants(MeshBuilder solid) {
    if (streetsAcross == 0) return;
    final r = math.Random(s.seed ^ 0xF1DE);
    for (var axis = 0; axis < 2; axis++) {
      for (final line in grid.lines(axis)) {
        final t = line + 5.6;
        for (
          var a = -half + 80 + r.nextDouble() * 60;
          a < half - 80;
          a += 140 + r.nextDouble() * 60
        ) {
          final e = axis == 0 ? a : t, nn = axis == 0 ? t : a;
          if (inCorridor(e, nn, clearM: 40)) continue;
          final base = at(e, nn);
          final upv = (base + anchorBF).normalized;
          StreetFurniture.place(
            solid,
            StreetProp.hydrant,
            base,
            axis == 0 ? east : north,
            upv,
            r,
          );
        }
      }
    }
  }

  /// Bus shelters along the section's four arterial edges, backs to the
  /// houses, with the stop's sign a few paces up the road.
  void _busStops(MeshBuilder solid, MeshBuilder glass) {
    final r = math.Random(s.seed ^ 0xB05);
    for (var edge = 0; edge < 4; edge++) {
      for (var i = 0; i < 3; i++) {
        final along = -half + 250 + i * 530 + (r.nextDouble() - 0.5) * 120;
        final set = half - 16.5;
        // The shelter's back panel stands to the right of its facing, so
        // each edge faces the way that turns the back on the road.
        final (e, n, dir) = switch (edge) {
          0 => (along, -set, east * -1),
          1 => (along, set, east),
          2 => (-set, along, north),
          _ => (set, along, north * -1),
        };
        if (inCorridor(e, n, clearM: 40)) continue;
        final base = at(e, n);
        final upv = (base + anchorBF).normalized;
        StreetFurniture.place(glass, StreetProp.busShelter, base, dir, upv, r);
        final post = base + dir * 4.5;
        OrientedBox.upright(solid, post, dir, upv, 0.08, 0.08, 2.6);
        OrientedBox.emit(
          solid,
          post + upv * 2.35,
          dir.cross(upv).normalized,
          dir,
          upv,
          0.25,
          0.03,
          0.2,
        );
      }
    }
  }

  /// A water tower on some sections: four legs and a drum, the one thing
  /// that stands above a suburb's trees.
  void _waterTower(MeshBuilder solid, double chance) {
    final r = math.Random(s.seed ^ 0x5A17);
    if (r.nextDouble() > chance) return;
    final e = (r.nextDouble() - 0.5) * s.sizeM * 0.7;
    final n = (r.nextDouble() - 0.5) * s.sizeM * 0.7;
    if (inCorridor(e, n, clearM: 60)) return;
    final base = at(e, n);
    final upv = (base + anchorBF).normalized;
    const legH = 27.0, tankR = 5.5;
    for (final (le, ln) in const [
      (-3.4, -3.4),
      (3.4, -3.4),
      (3.4, 3.4),
      (-3.4, 3.4),
    ]) {
      OrientedBox.upright(
        solid,
        base + east * le + north * ln,
        east,
        upv,
        0.55,
        0.55,
        legH,
      );
    }
    _drum(
      solid,
      base,
      upv,
      tankR,
      legH - 3,
      legH + 7,
      coneTop: 3.5,
      coneBottom: 3.0,
    );
  }

  /// An octagonal drum about [upv] from [z0] to [z1] above [base], closed
  /// with a cone each end.
  void _drum(
    MeshBuilder m,
    Vector3 base,
    Vector3 upv,
    double r,
    double z0,
    double z1, {
    double coneTop = 0,
    double coneBottom = 0,
  }) {
    const sides = 8;
    final lo = <int>[], hi = <int>[];
    for (var i = 0; i < sides; i++) {
      final a = i / sides * 2 * math.pi;
      final radial = (east * math.cos(a) + north * math.sin(a)).normalized;
      lo.add(m.vertex(_s(base + radial * r + upv * z0), radial, 0.5, 0));
      hi.add(m.vertex(_s(base + radial * r + upv * z1), radial, 0.5, 1));
    }
    for (var i = 0; i < sides; i++) {
      final j = (i + 1) % sides;
      m.quad(lo[i], lo[j], hi[j], hi[i]);
    }
    final top = m.vertex(_s(base + upv * (z1 + coneTop)), upv, 0.5, 1);
    final bottom = m.vertex(
      _s(base + upv * (z0 - coneBottom)),
      upv * -1,
      0.5,
      0,
    );
    for (var i = 0; i < sides; i++) {
      final j = (i + 1) % sides;
      m.triangle(hi[i], hi[j], top);
      m.triangle(lo[j], lo[i], bottom);
    }
  }

  // ---- Boxes, strips, sheds -----------------------------------------------

  /// Big boxes with their parking along the section's arterial edges. Far,
  /// the boxes alone; mid, the lot between each box and the road, with a
  /// driveway off the arterial and a footpath to the door; near, its bay
  /// lines; close, cars in the bays.
  void _strip(
    MeshBuilder road,
    MeshBuilder solid,
    MeshBuilder glass,
    SprawlTier tier,
  ) {
    final carRnd = math.Random(s.seed ^ 0xCA5);
    final detailed = tier == SprawlTier.near || tier == SprawlTier.close;
    for (var edge = 0; edge < 4; edge++) {
      for (var a = -half + 120; a < half - 120; a += 115) {
        if (rnd.nextDouble() > s.density) continue;
        final along = a + (rnd.nextDouble() - 0.5) * 20;
        final set = half - 110;
        final (e, n, alongE) = switch (edge) {
          0 => (along, -set, true),
          1 => (along, set, true),
          2 => (-set, along, false),
          _ => (set, along, false),
        };
        if (inCorridor(e, n, clearM: 70)) continue;
        final bw = 60 + rnd.nextDouble() * 30, bd = 40 + rnd.nextDouble() * 15;
        _box(
          solid,
          e,
          n,
          alongE ? bw : bd,
          alongE ? bd : bw,
          8 + rnd.nextDouble() * 3,
          gable: false,
        );
        if (tier == SprawlTier.far) continue;
        // Everything below is laid in (along the road, out from the box
        // toward the road) and turned into (e, n) at the end.
        final toward = edge == 0 || edge == 2 ? -1.0 : 1.0;
        final centre = alongE ? n : e;
        (double, double) en(double al, double out) =>
            alongE ? (al, centre + toward * out) : (centre + toward * out, al);
        void quad(
          double a0,
          double o0,
          double a1,
          double o1,
          int band, {
          double lift = 0.4,
        }) {
          final (e0, n0) = en(a0, o0);
          final (e1, n1) = en(a1, o1);
          _pavedQuad(
            road,
            math.min(e0, e1),
            math.min(n0, n1),
            math.max(e0, e1),
            math.max(n0, n1),
            band,
            lift: lift,
          );
        }

        // The lot, between the box's front and the road: asphalt from 32 m
        // out from the box's centre to 88 m — which leaves 22 m to the
        // arterial's centreline, room for its sidewalk and a verge.
        const lot0 = 32.0, lot1 = 88.0;
        quad(
          along - bw / 2,
          lot0,
          along + bw / 2,
          lot1,
          CityTextureBakes.roadAsphalt,
        );
        // The driveway off the arterial: from the lot's road edge over the
        // sidewalk to the curb (the avenue's half width), at the lot's end,
        // at the walk's own height with a dropped curb.
        final roadCentre = 110.0; // the section line
        final curb = roadCentre - RoadClass.avenue.halfWidth;
        quad(
          along + bw / 2 - 9,
          lot1 - 0.3,
          along + bw / 2 - 2,
          curb + 0.3,
          CityTextureBakes.roadConcrete,
          lift: _roadLiftM + RoadMesher.walkTopLiftM + 0.02,
        );
        // The footpath from the lot to the door in the middle of the front.
        quad(
          along - 0.9,
          bd / 2 - 0.1,
          along + 0.9,
          lot0 + 0.3,
          CityTextureBakes.roadConcrete,
          lift: 0.43,
        );
        if (!detailed) continue;
        // Two ranks of bays back to back down the middle of the lot, a
        // drive aisle each side, the driveway's lane kept clear.
        final mid = (lot0 + lot1) / 2;
        final rankA0 = along - bw / 2 + 1.0, rankA1 = along + bw / 2 - 12;
        for (final (edgeO, intoO) in [(mid, mid - 5.2), (mid, mid + 5.2)]) {
          for (var x = rankA0; x <= rankA1 + 1e-6; x += 2.8) {
            quad(
              x - 0.06,
              math.min(edgeO, intoO),
              x + 0.06,
              math.max(edgeO, intoO),
              CityTextureBakes.roadWhite,
              lift: 0.43,
            );
          }
        }
        if (tier != SprawlTier.close) continue;
        // Cars in the bays, nose to the middle from both sides.
        final slots = ((rankA1 - rankA0) / 2.8).floor();
        for (var i = 0; i < slots; i++) {
          if (carRnd.nextDouble() > 0.5) continue;
          final x = rankA0 + (i + 0.5) * 2.8;
          final sideOfMid = i.isEven ? -1.0 : 1.0;
          final (ce, cn) = en(x, mid + sideOfMid * 2.6);
          final base = at(ce, cn);
          final upv = (base + anchorBF).normalized;
          final nose = (alongE ? north : east) * (toward * -sideOfMid);
          VehicleMeshes.emit(
            solid,
            glass,
            i.isEven ? VehicleKind.sedan : VehicleKind.coupe,
            base,
            nose,
            upv,
            u: 0.5,
          );
        }
      }
    }
  }

  /// Sheds in the blocks of the section's streets, each with its yard
  /// between it and the block's south street, a driveway off that street
  /// and a footpath to its door. Far, the sheds alone. A works fronts a
  /// street: the old coarse grid put sheds astride the streets themselves.
  void _sheds(MeshBuilder road, MeshBuilder solid, SprawlTier tier) {
    final detailed = tier == SprawlTier.near || tier == SprawlTier.close;
    final boundsE = [-half, ...grid.lines(1), half];
    final boundsN = [-half, ...grid.lines(0), half];
    for (var i = 0; i + 1 < boundsE.length; i++) {
      for (var j = 0; j + 1 < boundsN.length; j++) {
        final be0 = boundsE[i], be1 = boundsE[i + 1];
        final n0 = boundsN[j], n1 = boundsN[j + 1];
        final bw = be1 - be0, cd = n1 - n0;
        if (bw < 120 || cd < 120) continue;
        // Two works side by side along a full block, one on a short one.
        final plots = bw >= 240 ? 2 : 1;
        for (var k = 0; k < plots; k++) {
          if (rnd.nextDouble() > s.density) continue;
          final e0 = be0 + bw * k / plots, e1 = be0 + bw * (k + 1) / plots;
          final cw = e1 - e0;
          final w = math.min(cw * 0.6, 70 + rnd.nextDouble() * 50);
          final d = math.min(cd * 0.3, 40 + rnd.nextDouble() * 20);
          final e = (e0 + e1) / 2 + (rnd.nextDouble() - 0.5) * 20;
          final nn = n0 + cd * 0.55 + (rnd.nextDouble() - 0.5) * 20;
          if (inCorridor(e, nn, clearM: 80)) continue;
          _box(solid, e, nn, w, d, 9 + rnd.nextDouble() * 4, gable: detailed);
          if (tier == SprawlTier.far) continue;
          // The yard: asphalt from the shed's front to a verge off the
          // street's sidewalk.
          final y0 = n0 + _streetHalfM + _walkM + 6;
          final y1 = nn - d / 2 - 6;
          if (y1 - y0 < 15) continue;
          if (inCorridor(e, (y0 + y1) / 2, clearM: 60)) continue;
          _pavedQuad(
            road,
            e - w / 2 - 6,
            y0,
            e + w / 2 + 6,
            y1,
            CityTextureBakes.roadAsphalt,
          );
          // The driveway: the yard's street edge over the sidewalk to the
          // curb, at the yard's east end, at the walk's height.
          _pavedQuad(
            road,
            e + w / 2 - 4,
            n0 + _streetHalfM - 0.3,
            e + w / 2 + 4,
            y0 + 0.3,
            CityTextureBakes.roadConcrete,
            lift: _roadLiftM + RoadMesher.walkTopLiftM + 0.02,
          );
          // The footpath from the yard to the door in the middle of the front.
          _pavedQuad(
            road,
            e - 0.9,
            y1 - 0.3,
            e + 0.9,
            nn - d / 2 + 0.1,
            CityTextureBakes.roadConcrete,
            lift: 0.43,
          );
          if (!detailed) continue;
          // A rank of bays along the yard's street edge, facing the street.
          _bayLines(road, 1, e - w / 2 - 4, e + w / 2 - 10, y0 + 1.0, y0 + 6.2);
        }
      }
    }
  }

  // ---- Trees --------------------------------------------------------------

  /// Conifers, as cones.
  void _trees(MeshBuilder ground, int count) {
    for (var k = 0; k < count; k++) {
      final e = (rnd.nextDouble() - 0.5) * s.sizeM * 0.9;
      final n = (rnd.nextDouble() - 0.5) * s.sizeM * 0.9;
      if (inCorridor(e, n, clearM: 50)) continue;
      final base = at(e, n);
      final upv = (base + anchorBF).normalized;
      final h = 9 + rnd.nextDouble() * 6;
      final r = 3 + rnd.nextDouble() * 2;
      final top = ground.vertex(_s(base + upv * h), upv, _leafU, 0.5);
      final ring = <int>[];
      for (var i = 0; i < 6; i++) {
        final a = i / 6 * 2 * math.pi;
        final p = base + east * (math.cos(a) * r) + north * (math.sin(a) * r);
        final nn =
            (east * math.cos(a) + north * math.sin(a) + upv * 0.5).normalized;
        ring.add(ground.vertex(_s(p), nn, _leafU, 0.5));
      }
      for (var i = 0; i < 6; i++) {
        ground.triangle(ring[i], ring[(i + 1) % 6], top);
      }
    }
  }

  /// Broadleaves scattered over the section.
  void _broadleaves(MeshBuilder ground, MeshBuilder solid, int count) {
    final r = math.Random(s.seed ^ 0x1EAF);
    for (var k = 0; k < count; k++) {
      final e = (r.nextDouble() - 0.5) * s.sizeM * 0.9;
      final n = (r.nextDouble() - 0.5) * s.sizeM * 0.9;
      if (inCorridor(e, n, clearM: 50)) continue;
      _broadleaf(ground, solid, e, n, r);
    }
  }

  /// One broadleaf: a trunk under a crown of three rings of five, turned
  /// against each other so no two trees are the same lump — thirty
  /// triangles, which at yard-tree numbers is what a tree can afford to be.
  /// The crown goes on the ground palette for its green.
  void _broadleaf(
    MeshBuilder ground,
    MeshBuilder solid,
    double e,
    double n,
    math.Random rnd,
  ) {
    final base = at(e, n);
    final upv = (base + anchorBF).normalized;
    final trunk = 2.0 + rnd.nextDouble() * 1.2;
    final r = 2.0 + rnd.nextDouble() * 1.4;
    OrientedBox.upright(
      solid,
      base,
      east,
      upv,
      0.38,
      0.38,
      trunk + 0.6,
      u: _roofU,
    );
    final c = base + upv * (trunk + r * 0.9);
    final twist = rnd.nextDouble() * math.pi;
    final rings = <List<int>>[];
    for (final (z, rr) in const [(-0.5, 0.72), (0.05, 1.0), (0.6, 0.72)]) {
      final ring = <int>[];
      for (var i = 0; i < 5; i++) {
        final a = i / 5 * 2 * math.pi + z * 1.7 + twist;
        final radial = east * math.cos(a) + north * math.sin(a);
        final p = c + radial * (r * rr) + upv * (r * z);
        ring.add(
          ground.vertex(_s(p), (radial + upv * z).normalized, _leafU, 0.5),
        );
      }
      rings.add(ring);
    }
    final apex = ground.vertex(_s(c + upv * (r * 1.1)), upv, _leafU, 0.5);
    final foot = ground.vertex(_s(c - upv * (r * 0.9)), upv * -1, _leafU, 0.5);
    for (var i = 0; i < 5; i++) {
      final j = (i + 1) % 5;
      ground.triangle(rings[2][i], rings[2][j], apex);
      ground.triangle(rings[0][j], rings[0][i], foot);
      for (var k = 0; k < 2; k++) {
        ground.quad(rings[k][i], rings[k][j], rings[k + 1][j], rings[k + 1][i]);
      }
    }
  }

  // ---- Primitives ---------------------------------------------------------

  /// One house: a box with a pitched roof and, near, its windows.
  void _house(
    MeshBuilder solid,
    MeshBuilder glass,
    double e,
    double n,
    double w,
    double d,
    double h,
    bool near,
    bool ridgeAlongE,
  ) {
    _box(solid, e, n, w, d, h, gable: near, ridgeAlongE: ridgeAlongE);
    if (near) _windows(glass, e, n, w, d);
  }

  /// A row of windows on each wall at eye height, glazed so they light at
  /// night the way the plat's do. One band round the house read as a
  /// container's stripe; windows are what make a box a house. Each maps a
  /// two-by-two block of the glazing sheet's panes — a frame and a cross
  /// mullion — rather than a column of six storeys, and which block varies
  /// so the night's lit ones scatter.
  void _windows(MeshBuilder glass, double e, double n, double w, double d) {
    final pick = (e * 7 + n * 13).round();
    final base = at(e, n);
    final upv = (base + anchorBF).normalized;
    final hw = w / 2, hd = d / 2;
    final c = [
      base + east * -hw + north * -hd,
      base + east * hw + north * -hd,
      base + east * hw + north * hd,
      base + east * -hw + north * hd,
    ];
    final normals = [north * -1, east, north, east * -1];
    for (var f = 0; f < 4; f++) {
      final a = c[f], b = c[(f + 1) % 4];
      final nn = normals[f];
      final run = b - a;
      final len = run.length;
      final count = math.max(1, (len / 3.4).floor());
      final dir = run * (1 / len);
      for (var i = 0; i < count; i++) {
        final mid =
            a + dir * (len * (i + 0.5) / count) + nn * 0.06 + upv * 1.35;
        final block = (pick + f * 5 + i * 7) % 9;
        final u0 = (block % 3) * 2 / 6, v0 = (block ~/ 3) * 2 / 6;
        const span = 2 / 6;
        glass.quad(
          glass.vertex(_s(mid - dir * 0.6 - upv * 0.55), nn, u0, v0),
          glass.vertex(_s(mid + dir * 0.6 - upv * 0.55), nn, u0 + span, v0),
          glass.vertex(
            _s(mid + dir * 0.6 + upv * 0.55),
            nn,
            u0 + span,
            v0 + span,
          ),
          glass.vertex(_s(mid - dir * 0.6 + upv * 0.55), nn, u0, v0 + span),
        );
      }
    }
  }

  /// An axis-aligned box standing on the ground at (e, n), optionally under
  /// a pitched roof.
  void _box(
    MeshBuilder m,
    double e,
    double n,
    double w,
    double d,
    double h, {
    required bool gable,
    bool ridgeAlongE = true,
  }) {
    final base = at(e, n);
    final upv = (base + anchorBF).normalized;
    final hw = w / 2, hd = d / 2;
    final wallH = gable ? h * 0.72 : h;
    final c = [
      base + east * -hw + north * -hd,
      base + east * hw + north * -hd,
      base + east * hw + north * hd,
      base + east * -hw + north * hd,
    ];
    final t = [for (final p in c) p + upv * wallH];
    final normals = [north * -1, east, north, east * -1];
    for (var f = 0; f < 4; f++) {
      final a = c[f], b = c[(f + 1) % 4];
      final ta = t[f], tb = t[(f + 1) % 4];
      final nn = normals[f];
      final i0 = m.vertex(_s(a), nn, 0.5, 0);
      final i1 = m.vertex(_s(b), nn, 0.5, 0);
      final i2 = m.vertex(_s(tb), nn, 0.5, 1);
      final i3 = m.vertex(_s(ta), nn, 0.5, 1);
      m.quad(i0, i1, i2, i3);
    }
    if (!gable) {
      final i = [for (final p in t) m.vertex(_s(p), upv, _roofU, 0.5)];
      m.quad(i[0], i[1], i[2], i[3]);
      return;
    }
    // The roof: two slopes to a ridge, gables closed.
    final ridgeH = h - wallH;
    if (ridgeAlongE) {
      final ra = base + east * -hw + upv * h, rb = base + east * hw + upv * h;
      final nS = (north * -ridgeH + upv * hd).normalized;
      final nN = (north * ridgeH + upv * hd).normalized;
      m.quad(
        m.vertex(_s(t[0]), nS, _roofU, 0),
        m.vertex(_s(t[1]), nS, _roofU, 0),
        m.vertex(_s(rb), nS, _roofU, 1),
        m.vertex(_s(ra), nS, _roofU, 1),
      );
      m.quad(
        m.vertex(_s(t[2]), nN, _roofU, 0),
        m.vertex(_s(t[3]), nN, _roofU, 0),
        m.vertex(_s(ra), nN, _roofU, 1),
        m.vertex(_s(rb), nN, _roofU, 1),
      );
      m.triangle(
        m.vertex(_s(t[1]), east, 0.5, 0),
        m.vertex(_s(t[2]), east, 0.5, 0),
        m.vertex(_s(rb), east, 0.5, 1),
      );
      m.triangle(
        m.vertex(_s(t[3]), east * -1, 0.5, 0),
        m.vertex(_s(t[0]), east * -1, 0.5, 0),
        m.vertex(_s(ra), east * -1, 0.5, 1),
      );
    } else {
      final ra = base + north * -hd + upv * h, rb = base + north * hd + upv * h;
      final nE = (east * ridgeH + upv * hw).normalized;
      final nW = (east * -ridgeH + upv * hw).normalized;
      m.quad(
        m.vertex(_s(t[1]), nE, _roofU, 0),
        m.vertex(_s(t[2]), nE, _roofU, 0),
        m.vertex(_s(rb), nE, _roofU, 1),
        m.vertex(_s(ra), nE, _roofU, 1),
      );
      m.quad(
        m.vertex(_s(t[3]), nW, _roofU, 0),
        m.vertex(_s(t[0]), nW, _roofU, 0),
        m.vertex(_s(ra), nW, _roofU, 1),
        m.vertex(_s(rb), nW, _roofU, 1),
      );
      m.triangle(
        m.vertex(_s(t[2]), north, 0.5, 0),
        m.vertex(_s(t[3]), north, 0.5, 0),
        m.vertex(_s(rb), north, 0.5, 1),
      );
      m.triangle(
        m.vertex(_s(t[0]), north * -1, 0.5, 0),
        m.vertex(_s(t[1]), north * -1, 0.5, 0),
        m.vertex(_s(ra), north * -1, 0.5, 1),
      );
    }
  }

  static Vector3 _s(Vector3 metres) => metres * kRenderScale;
}

/// A section's street lines and collectors, per axis: axis 0 is the
/// east-west streets (by northing), axis 1 the north-south (by easting),
/// both as offsets from the section's centre.
class _Grid {
  const _Grid(this.lines0, this.lines1, this.coll0, this.coll1, this.half);

  factory _Grid.of(SprawlSectionBuilder b) {
    final s = b.s;
    final n = b.streetsAcross;
    if (n == 0) return _Grid(const [], const [], const {}, const {}, b.half);
    if (s.linesE.isNotEmpty && s.linesN.isNotEmpty) {
      Set<int> pick(List<double> lines, List<double> chosen) => {
        for (var i = 0; i < lines.length; i++)
          if (chosen.any((c) => (c - lines[i]).abs() < 0.5)) i,
      };
      return _Grid(
        s.linesN,
        s.linesE,
        pick(s.linesN, s.collectorsN),
        pick(s.linesE, s.collectorsE),
        b.half,
      );
    }
    final step = s.sizeM / n;
    final lines = [for (var k = 1; k < n; k++) -b.half + k * step];
    final coll = {for (final k in SprawlSection.collectorIndices(n)) k - 1};
    return _Grid(lines, lines, coll, coll, b.half);
  }

  final List<double> lines0, lines1;
  final Set<int> coll0, coll1;
  final double half;

  List<double> lines(int axis) => axis == 0 ? lines0 : lines1;
  Set<int> collectors(int axis) => axis == 0 ? coll0 : coll1;

  /// The blocks along a street of [axis]: the intervals between the cross
  /// streets, from the section's edge to its edge.
  List<(double, double)> blocks(int axis) {
    final bounds = [-half, ...lines(1 - axis), half];
    return [
      for (var i = 0; i + 1 < bounds.length; i++) (bounds[i], bounds[i + 1]),
    ];
  }
}
