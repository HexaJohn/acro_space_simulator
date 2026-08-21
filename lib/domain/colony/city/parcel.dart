// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Land parcels and the roads they front onto.
///
/// This replaces the fixed cell grid as the unit of buildable land. A grid
/// forces every building into the same square and every road into the same
/// spacing, which is exactly wrong for the things this colony builds: a solar
/// farm wants a kilometre of open ground, a quarry wants a pit you can see from
/// orbit, and a habitat block wants a narrow lot on a street. Parcels are drawn
/// from the road network at whatever frontage and depth the player asks for, so
/// the same city can hold both.
///
/// Everything here is in a LOCAL EAST-NORTH plane in METRES, centred on the
/// colony site. Curving it onto the planet is the placement layer's job — a
/// colony is small enough relative to a body that treating its footprint as
/// flat is accurate to well under a metre, and keeping the geometry planar is
/// what makes subdivision, overlap tests and road offsets tractable.
library;

import 'dart:math' as math;

/// A point on the colony's local ground plane, in metres east/north of the
/// colony site.
class Vec2 {
  final double e, n;
  const Vec2(this.e, this.n);

  Vec2 operator +(Vec2 o) => Vec2(e + o.e, n + o.n);
  Vec2 operator -(Vec2 o) => Vec2(e - o.e, n - o.n);
  Vec2 operator *(double s) => Vec2(e * s, n * s);

  double get length => math.sqrt(e * e + n * n);

  Vec2 get normalized {
    final l = length;
    return l <= 1e-12 ? const Vec2(0, 0) : Vec2(e / l, n / l);
  }

  /// Left-hand perpendicular (90° counter-clockwise).
  Vec2 get perp => Vec2(-n, e);

  double dot(Vec2 o) => e * o.e + n * o.n;

  /// 2D cross product (z of the 3D cross). Sign gives which side of `this` [o]
  /// lies on — the workhorse of the polygon tests below.
  double cross(Vec2 o) => e * o.n - n * o.e;

  double distanceTo(Vec2 o) => (this - o).length;

  /// Heading in radians, measured from north toward east — the same convention
  /// the surface placement uses for a building's yaw.
  double get heading => math.atan2(e, n);

  @override
  String toString() => 'Vec2(${e.toStringAsFixed(1)}, ${n.toStringAsFixed(1)})';
}

/// Road tiers. Width drives both the drawn carriageway and how far parcels get
/// pushed back from the centreline.
enum RoadClass {
  /// Local street: houses, shops, the default.
  street('Street', 8.0, 1, 12),

  /// Multi-lane arterial through the city.
  avenue('Avenue', 16.0, 2, 8),

  /// Grade-separated link between districts and out to the industrial sites.
  highway('Highway', 32.0, 4, 5),

  /// A graded dirt track — the first road a colony has. Cheap, slow, unlit.
  ///
  /// Appended after the paved tiers because saves persist this enum by INDEX;
  /// inserting it first would turn every saved street into a path.
  path('Dirt Path', 4.0, 1, 20),

  /// The service road down the middle of a block.
  ///
  /// The thing that makes a downtown block continuous. Bins, loading, fire
  /// escapes and back-of-house parking all come off the alley, which is
  /// precisely why the STREET frontage can be an unbroken run of shopfronts —
  /// take the alley away and every one of those has to punch a hole through
  /// the street wall instead. No lots front it, no lamps, no curbs.
  alley('Alley', 6.0, 1, 15),

  /// A carriageway on piers, carried over whatever is beneath it.
  elevated('Elevated Highway', 24.0, 3, 5),

  /// Elevated heavy rail on a steel trestle — the L.
  ///
  /// A transit line is a ROAD to the network (it is a route between places,
  /// it splits at junctions, the editor draws it the same way) and nothing
  /// like one to the renderer or the traffic pass: no cars run on it, no lots
  /// front it, and what it carries is a train.
  transit('Elevated Rail', 9.0, 1, 4);

  final String label;

  /// Carriageway width in metres (curb to curb).
  final double width;

  /// Lanes per direction — used for traffic capacity and lamp spacing.
  final int lanesEachWay;

  /// Steepest grade this tier can be built at, percent. Real limits: a local
  /// street tolerates ~12%, an arterial ~8%, a grade-separated highway ~5%,
  /// and a dirt track will climb what a wheel can grip. This is what makes
  /// mountains COST something: the highway has to go around, the path can go
  /// over.
  final double maxGradePct;

  const RoadClass(this.label, this.width, this.lanesEachWay, this.maxGradePct);

  /// Whether this tier is paved — drives the surface texture, the lamps, and
  /// the traffic capacity. A dirt path is a road to the network and a track to
  /// everything else.
  bool get paved => this != RoadClass.path;

  double get halfWidth => width / 2;

  /// How far the deck stands above the ground, metres. Zero is at grade.
  ///
  /// The elevated tiers are deliberately at different heights: a highway has
  /// to clear a lorry on the street below it, and the rail has to clear the
  /// highway. Stack them at the same height and they intersect.
  double get deckHeightM => switch (this) {
        RoadClass.elevated => 9.5,
        RoadClass.transit => 7.2,
        _ => 0,
      };

  bool get isElevated => deckHeightM > 0;

  /// Whether lots front this road.
  ///
  /// An alley serves the BACKS of lots, and nothing at all fronts a structure
  /// on piers. Platting against either produced lots that faced a service
  /// road or a column line, which is the surest way to break a street wall
  /// you have just finished building.
  bool get platsLots => switch (this) {
        RoadClass.alley || RoadClass.elevated || RoadClass.transit => false,
        _ => true,
      };

  /// Whether road vehicles run on it. False for rail.
  bool get carriesCars => this != RoadClass.transit;

  /// Whether it gets a pavement, curbs and street furniture. An alley has
  /// none of it; neither does anything in the air.
  bool get hasPavement => switch (this) {
        RoadClass.alley || RoadClass.elevated || RoadClass.transit => false,
        RoadClass.path => false,
        _ => true,
      };

  /// Whether the junction pass gives it signals, stop bars and crossings.
  bool get signalised => switch (this) {
        RoadClass.street || RoadClass.avenue || RoadClass.highway => true,
        _ => false,
      };
}

/// A road as a SPLINE rather than a run of tiles.
///
/// Control points are what the player places; [sample] walks a centripetal
/// Catmull-Rom curve through them. Centripetal (alpha = 0.5) rather than
/// uniform parameterisation because uniform Catmull-Rom forms cusps and
/// self-intersections when control points are unevenly spaced — which is
/// exactly what hand-drawn roads are.
class RoadSpline {
  final String id;
  final RoadClass roadClass;
  final List<Vec2> controls;

  /// A closed loop (ring road) joins its last control point back to its first.
  final bool closed;

  /// Laid where the air is NOT breathable, so pedestrians travel in a sealed
  /// pressurised tube alongside the carriageway rather than on a pavement.
  ///
  /// Captured at BUILD time and preserved, matching the rule the grid's
  /// `roadSealed` set already follows for cell roads: terraforming a world
  /// later does not silently unseal everything that was built for vacuum.
  final bool sealed;

  const RoadSpline({
    required this.id,
    required this.controls,
    this.roadClass = RoadClass.street,
    this.closed = false,
    this.sealed = false,
  });

  double get width => roadClass.width;
  double get halfWidth => roadClass.halfWidth;

  /// Points along the curve, spaced at most [stepM] apart.
  ///
  /// Two control points degenerate to a straight line; one is a point. Both are
  /// legal mid-draw states, so neither throws.
  List<Vec2> sample({double stepM = 4.0}) {
    if (controls.length < 2) return List.of(controls);
    final pts = <Vec2>[];
    final n = controls.length;
    final segments = closed ? n : n - 1;
    for (var i = 0; i < segments; i++) {
      final p0 = controls[(i - 1 + n) % n];
      final p1 = controls[i % n];
      final p2 = controls[(i + 1) % n];
      final p3 = controls[(i + 2) % n];
      // Endpoint tangents on an open spline mirror the neighbouring segment so
      // the curve starts and ends straight instead of curling.
      final a = (!closed && i == 0) ? p1 + (p1 - p2) : p0;
      final b = (!closed && i == segments - 1) ? p2 + (p2 - p1) : p3;
      final segLen = p1.distanceTo(p2);
      final steps = math.max(1, (segLen / stepM).ceil());
      for (var s = 0; s < steps; s++) {
        pts.add(_catmullRom(a, p1, p2, b, s / steps));
      }
    }
    if (!closed) pts.add(controls.last);
    return pts;
  }

  /// Centreline length in metres.
  double length({double stepM = 4.0}) {
    final pts = sample(stepM: stepM);
    var sum = 0.0;
    for (var i = 1; i < pts.length; i++) {
      sum += pts[i].distanceTo(pts[i - 1]);
    }
    return sum;
  }

  /// Shortest distance from [p] to the centreline. Used for overlap rejection
  /// (nothing may be built in the carriageway) and for road-frontage queries.
  double distanceTo(Vec2 p, {double stepM = 4.0}) {
    final pts = sample(stepM: stepM);
    if (pts.isEmpty) return double.infinity;
    if (pts.length == 1) return p.distanceTo(pts.first);
    var best = double.infinity;
    for (var i = 1; i < pts.length; i++) {
      final d = _distanceToSegment(p, pts[i - 1], pts[i]);
      if (d < best) best = d;
    }
    return best;
  }

  static Vec2 _catmullRom(Vec2 p0, Vec2 p1, Vec2 p2, Vec2 p3, double t) {
    // Centripetal knot spacing: t_{i+1} = t_i + |p_{i+1} - p_i|^0.5.
    double knot(double ti, Vec2 a, Vec2 b) =>
        ti + math.pow(math.max(a.distanceTo(b), 1e-6), 0.5).toDouble();
    final t0 = 0.0;
    final t1 = knot(t0, p0, p1);
    final t2 = knot(t1, p1, p2);
    final t3 = knot(t2, p2, p3);
    final tt = t1 + (t2 - t1) * t;

    Vec2 lerp(Vec2 a, Vec2 b, double ta, double tb, double x) {
      final d = tb - ta;
      if (d.abs() < 1e-9) return a;
      final w = (x - ta) / d;
      return a * (1 - w) + b * w;
    }

    final a1 = lerp(p0, p1, t0, t1, tt);
    final a2 = lerp(p1, p2, t1, t2, tt);
    final a3 = lerp(p2, p3, t2, t3, tt);
    final b1 = lerp(a1, a2, t0, t2, tt);
    final b2 = lerp(a2, a3, t1, t3, tt);
    return lerp(b1, b2, t1, t2, tt);
  }
}

/// Intersection parameter of ray (o, d) with segment p->q, or null.
///
/// Returns the ray's t (metres along [d] when it is unit length). The graph
/// and the lot subdivision both live on this: junction finding is
/// segment-segment intersection, and lot depth is a ray cast at the block.
double? raySegment(Vec2 o, Vec2 d, Vec2 p, Vec2 q) {
  final r = q - p;
  final denom = d.cross(r);
  if (denom.abs() < 1e-12) return null; // parallel
  final w = p - o;
  final t = w.cross(r) / denom;
  final u = w.cross(d) / denom;
  if (t < 0 || u < -1e-9 || u > 1 + 1e-9) return null;
  return t;
}

/// Intersection of segments a0->a1 and b0->b1 as (paramA, paramB), or null.
(double, double)? segmentSegment(Vec2 a0, Vec2 a1, Vec2 b0, Vec2 b1) {
  final d = a1 - a0;
  final r = b1 - b0;
  final denom = d.cross(r);
  if (denom.abs() < 1e-12) return null;
  final w = b0 - a0;
  final t = w.cross(r) / denom;
  final u = w.cross(d) / denom;
  if (t < -1e-9 || t > 1 + 1e-9 || u < -1e-9 || u > 1 + 1e-9) return null;
  return (t.clamp(0.0, 1.0), u.clamp(0.0, 1.0));
}

/// Clip [poly] to the half-plane `n . (x - p) >= keep` (Sutherland-Hodgman).
///
/// Convex in, convex out — which holds for every lot this file cuts, since
/// they start as quads and only ever lose corners to half-planes.
List<Vec2> clipHalfPlane(List<Vec2> poly, Vec2 p, Vec2 n, double keep) {
  if (poly.isEmpty) return poly;
  final out = <Vec2>[];
  double side(Vec2 v) => n.dot(v - p) - keep;
  for (var i = 0; i < poly.length; i++) {
    final a = poly[i];
    final b = poly[(i + 1) % poly.length];
    final sa = side(a), sb = side(b);
    if (sa >= 0) out.add(a);
    if ((sa >= 0) != (sb >= 0)) {
      final t = sa / (sa - sb);
      out.add(a + (b - a) * t);
    }
  }
  return out;
}

double _distanceToSegment(Vec2 p, Vec2 a, Vec2 b) {
  final ab = b - a;
  final len2 = ab.dot(ab);
  if (len2 <= 1e-12) return p.distanceTo(a);
  final t = ((p - a).dot(ab) / len2).clamp(0.0, 1.0);
  return p.distanceTo(a + ab * t);
}

/// What a parcel is zoned for. Mirrors the RCI zones plus the hand-placed
/// categories, so a parcel can be reserved for a specific use before anything
/// is built on it.
enum ParcelUse { residential, commercial, industrial, civic, utility, unzoned }

/// One unit of buildable land.
///
/// The polygon is a convex quad for auto-subdivided lots and an arbitrary
/// simple polygon for hand-drawn ones, wound counter-clockwise either way.
class Parcel {
  final String id;

  /// Boundary, counter-clockwise, in local east/north metres.
  final List<Vec2> polygon;

  /// The road this parcel fronts onto (null for a hand-drawn interior lot).
  final String? roadId;

  /// The frontage edge — the two polygon corners that touch the street. Driving
  /// building orientation, driveways and lamp placement off a stored edge is
  /// what keeps a building facing the road it was subdivided from, even after
  /// the road is later moved or reclassified.
  final (Vec2, Vec2)? frontage;

  /// A SECOND street edge, for a lot on a corner.
  ///
  /// A corner building is a different building. It has two public faces, so
  /// neither of them can be the blank party wall a mid-block lot puts on its
  /// sides; its entrance goes on the chamfer between them; and it is the one
  /// building on the block that gets to be taller, because it is the one you
  /// can see from two directions. Every one of those needs to know WHICH edge
  /// is the other street, which is why this is stored on the plat rather than
  /// guessed from geometry later.
  final (Vec2, Vec2)? sideStreet;

  bool get isCorner => sideStreet != null;

  final ParcelUse use;

  /// True when the player drew this lot by hand. Manual parcels are never
  /// regenerated or trimmed by the subdivider — they are the override that lets
  /// a quarry or a solar farm ignore the street pattern entirely.
  final bool manual;

  const Parcel({
    required this.id,
    required this.polygon,
    this.roadId,
    this.frontage,
    this.sideStreet,
    this.use = ParcelUse.unzoned,
    this.manual = false,
  });

  /// The largest rectangle CENTRED on the centroid and aligned to the frontage
  /// that lies wholly INSIDE this lot.
  ///
  /// [buildableExtent] is a bounding box, which for a rectangular lot is the
  /// lot and for a tapered one is bigger than it. Subdivision along a kinked
  /// road produces plenty of tapered quads, and a pad cut to the bounding box
  /// there does two wrong things at once: it spills over the narrow end into
  /// the neighbour and re-levels it, and it still misses its own wide corners.
  /// A rectangle that fits INSIDE the lot can do neither.
  ({double width, double depth}) get inscribedExtent {
    final box = buildableExtent;
    if (polygon.length < 3 || box.width <= 0 || box.depth <= 0) return box;
    final f = frontage;
    final along = f == null ? const Vec2(1, 0) : (f.$2 - f.$1).normalized;
    final away = along.perp;
    final c = centroid;

    bool fitsAt(double scale) {
      for (final sw in const [-1.0, 1.0]) {
        for (final sd in const [-1.0, 1.0]) {
          final hw = sw * box.width * scale / 2;
          final hd = sd * box.depth * scale / 2;
          if (!contains(Vec2(
            c.e + along.e * hw + away.e * hd,
            c.n + along.n * hw + away.n * hd,
          ))) {
            return false;
          }
        }
      }
      return true;
    }

    // Convex lots make corner containment sufficient, so a bisection on one
    // uniform scale is enough — and cheap enough to run per lot per edit.
    if (fitsAt(1.0)) return box;
    var lo = 0.0, hi = 1.0;
    for (var i = 0; i < 20; i++) {
      final mid = (lo + hi) / 2;
      if (fitsAt(mid)) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (width: box.width * lo, depth: box.depth * lo);
  }

  /// Shoelace area in m². Always positive for a correctly wound polygon.
  double get area {
    var sum = 0.0;
    for (var i = 0; i < polygon.length; i++) {
      final a = polygon[i];
      final b = polygon[(i + 1) % polygon.length];
      sum += a.cross(b);
    }
    return sum.abs() / 2;
  }

  Vec2 get centroid {
    var e = 0.0, n = 0.0;
    for (final p in polygon) {
      e += p.e;
      n += p.n;
    }
    final c = polygon.length;
    return c == 0 ? const Vec2(0, 0) : Vec2(e / c, n / c);
  }

  /// Mid-point of the street edge — where a driveway meets the road.
  Vec2? get frontageMidpoint {
    final f = frontage;
    return f == null ? null : (f.$1 + f.$2) * 0.5;
  }

  /// Frontage width in metres (0 for an interior lot).
  double get frontageWidth {
    final f = frontage;
    return f == null ? 0 : f.$1.distanceTo(f.$2);
  }

  /// Direction a building on this lot faces: from the lot centre out toward the
  /// street. Interior lots face north by convention.
  Vec2 get facing {
    final mid = frontageMidpoint;
    if (mid == null) return const Vec2(0, 1);
    final d = (mid - centroid);
    return d.length <= 1e-9 ? const Vec2(0, 1) : d.normalized;
  }

  /// Yaw (radians, north-toward-east) for a building placed on this lot.
  double get heading => facing.heading;

  /// The SAFE building envelope, as (width along the frontage, depth away
  /// from it).
  ///
  /// Width spans the frontage; depth is the distance to the NEAREST back
  /// vertex, not the farthest. Lots are irregular now — slanted backs against
  /// a facing street, corners clipped at a junction — and a building sized to
  /// the bounding box would overhang the clipped part of its own lot. The
  /// conservative depth keeps the building inside the polygon; the slack
  /// beyond it is the yard.
  ({double width, double depth}) get buildableExtent {
    if (polygon.isEmpty) return (width: 0, depth: 0);
    final f = frontage;
    final along = f == null ? const Vec2(1, 0) : (f.$2 - f.$1).normalized;
    final away = along.perp;
    var minA = double.infinity, maxA = -double.infinity;
    var minB = double.infinity, maxB = -double.infinity;
    for (final p in polygon) {
      final a = p.dot(along), b = p.dot(away);
      if (a < minA) minA = a;
      if (a > maxA) maxA = a;
      if (b < minB) minB = b;
      if (b > maxB) maxB = b;
    }
    final width = maxA - minA;
    var depth = maxB - minB;
    if (f != null) {
      final frontB = f.$1.dot(away);
      var nearestBack = double.infinity;
      for (final p in polygon) {
        final d = (p.dot(away) - frontB).abs();
        // Vertices ON the frontage edge are the front, not a shallow back.
        if (d > 1.0 && d < nearestBack) nearestBack = d;
      }
      if (nearestBack.isFinite) depth = math.min(depth, nearestBack);
    }
    return (width: width, depth: depth);
  }

  bool contains(Vec2 p) {
    // Winding test: for a convex CCW polygon every edge cross is >= 0. Falls
    // back to a ray cast for the concave hand-drawn case.
    var allLeft = true, allRight = true;
    for (var i = 0; i < polygon.length; i++) {
      final a = polygon[i];
      final b = polygon[(i + 1) % polygon.length];
      final c = (b - a).cross(p - a);
      if (c < 0) allLeft = false;
      if (c > 0) allRight = false;
    }
    if (allLeft || allRight) return true;
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final a = polygon[i], b = polygon[j];
      if ((a.n > p.n) != (b.n > p.n) &&
          p.e < (b.e - a.e) * (p.n - a.n) / (b.n - a.n) + a.e) {
        inside = !inside;
      }
    }
    return inside;
  }

  /// Axis-aligned bounds, for broad-phase overlap tests.
  ({double minE, double minN, double maxE, double maxN}) get bounds {
    var minE = double.infinity, minN = double.infinity;
    var maxE = -double.infinity, maxN = -double.infinity;
    for (final p in polygon) {
      if (p.e < minE) minE = p.e;
      if (p.n < minN) minN = p.n;
      if (p.e > maxE) maxE = p.e;
      if (p.n > maxN) maxN = p.n;
    }
    return (minE: minE, minN: minN, maxE: maxE, maxN: maxN);
  }

  /// Convex separating-axis overlap. Auto lots are quads and manual lots are
  /// usually convex too; a concave manual lot degrades to its convex hull for
  /// this test, which errs toward rejecting a placement rather than allowing an
  /// overlap.
  bool overlaps(Parcel other) {
    final a = bounds, b = other.bounds;
    if (a.maxE <= b.minE || b.maxE <= a.minE) return false;
    if (a.maxN <= b.minN || b.maxN <= a.minN) return false;
    for (final poly in [polygon, other.polygon]) {
      for (var i = 0; i < poly.length; i++) {
        final edge = poly[(i + 1) % poly.length] - poly[i];
        final axis = edge.perp.normalized;
        var aMin = double.infinity, aMax = -double.infinity;
        var bMin = double.infinity, bMax = -double.infinity;
        for (final p in polygon) {
          final d = p.dot(axis);
          if (d < aMin) aMin = d;
          if (d > aMax) aMax = d;
        }
        for (final p in other.polygon) {
          final d = p.dot(axis);
          if (d < bMin) bMin = d;
          if (d > bMax) bMax = d;
        }
        // A shared edge is a touch, not an overlap — neighbouring lots along a
        // street share their side boundary by construction.
        if (aMax <= bMin + 1e-6 || bMax <= aMin + 1e-6) return false;
      }
    }
    return true;
  }

  Parcel copyWith({ParcelUse? use}) => Parcel(
        id: id,
        polygon: polygon,
        roadId: roadId,
        frontage: frontage,
        sideStreet: sideStreet,
        use: use ?? this.use,
        manual: manual,
      );
}

/// Grade (slope) audit of a route against a road tier's limit.
class RoadGradeCheck {
  const RoadGradeCheck({required this.maxPct, required this.limitPct});

  /// Steepest grade found along the route, percent.
  final double maxPct;

  /// The tier's limit.
  final double limitPct;

  bool get ok => maxPct <= limitPct + 1e-9;

  /// Walk [samples] (already spline-sampled route points) over [groundAt]
  /// (metres of ground radius under a local point) and find the steepest
  /// run. Windows shorter than [windowM] are ignored: sampling noise over a
  /// couple of metres is not a hill, and real grade limits are measured over
  /// tens of metres of carriageway.
  static RoadGradeCheck of(
    List<Vec2> samples,
    double Function(Vec2) groundAt,
    RoadClass roadClass, {
    double windowM = 10,
  }) {
    var worst = 0.0;
    if (samples.length >= 2) {
      var anchor = samples.first;
      var anchorH = groundAt(anchor);
      var arc = 0.0;
      for (var i = 1; i < samples.length; i++) {
        arc += samples[i].distanceTo(samples[i - 1]);
        if (arc < windowM && i < samples.length - 1) continue;
        final h = groundAt(samples[i]);
        if (arc > 1e-6) {
          final grade = ((h - anchorH).abs() / arc) * 100;
          if (grade > worst) worst = grade;
        }
        anchor = samples[i];
        anchorH = h;
        arc = 0;
      }
    }
    return RoadGradeCheck(maxPct: worst, limitPct: roadClass.maxGradePct);
  }
}
