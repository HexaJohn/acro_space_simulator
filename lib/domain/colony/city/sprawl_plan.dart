// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The sprawl: everything past the platted core, out to the county line.
///
/// A real city the size of Chicago is twenty miles across, and almost all of
/// it is not the downtown the plat draws — it is mile-square sections of
/// subdivisions, strip malls along the arterials, industrial parks by the
/// railway, forest preserves, and farmland at the edge, threaded by a grid
/// of county highways and a handful of interstates with interchanges.
///
/// None of that can go through the subdivider: the plat is quadratic in lots
/// and a colony this size would be two hundred thousand of them. So the
/// sprawl is a PLAN, not a plat — a grid of sections each described by a
/// use, a density and a seed, plus the roads that matter at this scale — and
/// the renderer grows the houses and the local streets from the seed where
/// the camera can see them. Deterministic in the seed, so every client draws
/// the same city and a save stores only the spec.
library;

import 'dart:math' as math;

import 'parcel.dart';
import 'road_junction.dart';

/// One mile, metres.
const double kMileM = 1609.344;

/// What to grow.
class SprawlSpec {
  const SprawlSpec({
    this.seed = 1,
    this.radiusM = 10 * kMileM,
    this.coreRadiusM = 1000,
    this.sectionM = kMileM,
    this.interstates = 4,
    this.diagonals = 2,
    this.beltway = true,
    this.railBearing = math.pi / 2,
    this.axisOffsetE = 0,
    this.axisOffsetN = 0,
    this.coreRadii = const [],
    this.railOffsetN = 0,
    this.railInnerReachM = 0,
    this.expressway = false,
    this.coreAvenuesE = const [],
    this.coreAvenuesN = const [],
    this.clearings = const [],
    this.arteries = false,
    this.gridOriginE = 0,
    this.gridOriginN = 0,
    this.gridStepE = 0,
    this.gridStepN = 0,
    this.frontageRoads = const [],
  });

  /// The plat's street grid: north-south streets at
  /// [gridOriginE] + i·[gridStepE], east-west ones at [gridOriginN] +
  /// j·[gridStepN]. Zero steps mean no grid. The sections that touch the
  /// core lay their streets on THESE lines rather than their own survey
  /// grid, so the downtown streets carry on into the inner suburbs instead
  /// of stopping dead at the last block — the way a city's oldest suburbs
  /// share its survey.
  final double gridOriginE, gridOriginN, gridStepE, gridStepN;

  bool get hasGrid => gridStepE > 0 && gridStepN > 0;

  /// The plat's frontage roads under the expressway, each `[n, eastingA,
  /// eastingB]`: an east-west street at northing n from a to b. Where the
  /// deck comes down at the core's edge, these become the slip ramps onto
  /// and off the radial expressway.
  final List<List<double>> frontageRoads;

  /// Whether the plat carries every avenue on past its last street to the
  /// county grid as a trunk road. Then the plan puts a signalised junction
  /// on each county highway where an artery meets it — the plat lays the
  /// road, the plan owns the crossing, and neither draws it twice.
  final bool arteries;

  /// Whether the plat carries the east-west interstate through the core on
  /// an elevated expressway. Then the east and west radials start at deck
  /// height where it ends, and the core gets its own interchanges.
  final bool expressway;

  /// Where the plat's avenues lie: the north-south ones by their easting,
  /// the east-west ones by their northing. The expressway's interchanges
  /// inside the core hang from these.
  final List<double> coreAvenuesE;
  final List<double> coreAvenuesN;

  /// Ground the plan and the suburbs keep off: the plots the plat has
  /// staked for its installations and the railway's ends, each a flat
  /// polygon of colony-local e, n pairs. Rectangles, in practice — the plat
  /// stakes rectangles — and tested as their bounding boxes.
  final List<List<double>> clearings;

  SprawlSpec copyWith({
    bool? expressway,
    List<double>? coreAvenuesE,
    List<double>? coreAvenuesN,
    List<List<double>>? clearings,
    bool? arteries,
    List<List<double>>? frontageRoads,
  }) =>
      SprawlSpec(
        seed: seed,
        radiusM: radiusM,
        coreRadiusM: coreRadiusM,
        sectionM: sectionM,
        interstates: interstates,
        diagonals: diagonals,
        beltway: beltway,
        railBearing: railBearing,
        axisOffsetE: axisOffsetE,
        axisOffsetN: axisOffsetN,
        coreRadii: coreRadii,
        railOffsetN: railOffsetN,
        railInnerReachM: railInnerReachM,
        expressway: expressway ?? this.expressway,
        coreAvenuesE: coreAvenuesE ?? this.coreAvenuesE,
        coreAvenuesN: coreAvenuesN ?? this.coreAvenuesN,
        clearings: clearings ?? this.clearings,
        arteries: arteries ?? this.arteries,
        gridOriginE: gridOriginE,
        gridOriginN: gridOriginN,
        gridStepE: gridStepE,
        gridStepN: gridStepN,
        frontageRoads: frontageRoads ?? this.frontageRoads,
      );

  /// Whether [p] lies on a staked plot, [marginM] out from its edge.
  bool inClearing(Vec2 p, {double marginM = 0}) {
    for (final poly in clearings) {
      if (inFlatPolygonBox(poly, p.e, p.n, marginM)) return true;
    }
    return false;
  }

  /// Whether (x, y) lies within the bounding box of a flat e, n polygon,
  /// grown by [marginM].
  static bool inFlatPolygonBox(List<double> poly, double x, double y, double marginM) {
    if (poly.length < 6) return false;
    var minE = double.infinity, minN = double.infinity;
    var maxE = -double.infinity, maxN = -double.infinity;
    for (var i = 0; i + 1 < poly.length; i += 2) {
      if (poly[i] < minE) minE = poly[i];
      if (poly[i] > maxE) maxE = poly[i];
      if (poly[i + 1] < minN) minN = poly[i + 1];
      if (poly[i + 1] > maxN) maxN = poly[i + 1];
    }
    return x >= minE - marginM &&
        x <= maxE + marginM &&
        y >= minN - marginM &&
        y <= maxN + marginM;
  }

  /// The plat's railway: an east-west line at [railOffsetN], laid by the
  /// plat out to [railInnerReachM] each way. Past that the plan carries it
  /// on into the country — the plat's editor path samples every road at two
  /// metres to find its crossings, and sixty kilometres of track was a
  /// third of a build. Zero lays none.
  final double railOffsetN;
  final double railInnerReachM;

  final int seed;

  /// How far out the sprawl runs from the city centre.
  final double radiusM;

  /// Where the platted core ends; sections inside it are not grown.
  final double coreRadiusM;

  /// Section size: the survey grid the county highways follow.
  final double sectionM;

  /// Radial interstates on the axes (0..4), then [diagonals] more at 45°.
  final int interstates;
  final int diagonals;

  /// A ring interstate at about half the radius.
  final bool beltway;

  /// Which side the railway passes: industry clusters along it.
  final double railBearing;

  /// Where the core's central avenues sit, so the axial interstates carry on
  /// from them rather than a block over.
  final double axisOffsetE;
  final double axisOffsetN;

  /// The core's OUTLINE: how far its streets reach, sampled on evenly spaced
  /// bearings from east round through north. Empty means a circle of
  /// [coreRadiusM]. This is what lets the sprawl come right up to the last
  /// downtown street instead of standing off a nominal circle — a ragged
  /// core edge against a round clearing was a visible ring of bare ground.
  final List<double> coreRadii;

  /// How far the core's streets reach on [bearing].
  double coreRadiusAt(double bearing) {
    if (coreRadii.isEmpty) return coreRadiusM;
    final n = coreRadii.length;
    var t = (bearing % (2 * math.pi)) / (2 * math.pi) * n;
    if (t < 0) t += n;
    final i = t.floor() % n;
    final f = t - t.floor();
    return coreRadii[i] * (1 - f) + coreRadii[(i + 1) % n] * f;
  }

  /// Whether a colony-local point lies on the core's plat.
  bool coreContains(Vec2 p, {double marginM = 0}) =>
      p.length < coreRadiusAt(math.atan2(p.n, p.e)) + marginM;

  double get milesAcross => radiusM * 2 / kMileM;

  Map<String, dynamic> toJson() => {
        'seed': seed,
        'radius': radiusM,
        'core': coreRadiusM,
        'section': sectionM,
        'interstates': interstates,
        'diagonals': diagonals,
        'beltway': beltway,
        'rail': railBearing,
        'axisE': axisOffsetE,
        'axisN': axisOffsetN,
        if (coreRadii.isNotEmpty) 'coreRadii': coreRadii,
        'railN': railOffsetN,
        'railInner': railInnerReachM,
        'expressway': expressway,
        if (coreAvenuesE.isNotEmpty) 'avE': coreAvenuesE,
        if (coreAvenuesN.isNotEmpty) 'avN': coreAvenuesN,
        if (clearings.isNotEmpty) 'clear': clearings,
        if (arteries) 'arteries': true,
        if (hasGrid) 'grid': [gridOriginE, gridOriginN, gridStepE, gridStepN],
        if (frontageRoads.isNotEmpty) 'frontage': frontageRoads,
      };

  factory SprawlSpec.fromJson(Map<String, dynamic> j) => SprawlSpec(
        seed: (j['seed'] as num?)?.toInt() ?? 1,
        radiusM: (j['radius'] as num?)?.toDouble() ?? 10 * kMileM,
        coreRadiusM: (j['core'] as num?)?.toDouble() ?? 1000,
        sectionM: (j['section'] as num?)?.toDouble() ?? kMileM,
        interstates: (j['interstates'] as num?)?.toInt() ?? 4,
        diagonals: (j['diagonals'] as num?)?.toInt() ?? 2,
        beltway: j['beltway'] as bool? ?? true,
        railBearing: (j['rail'] as num?)?.toDouble() ?? math.pi / 2,
        axisOffsetE: (j['axisE'] as num?)?.toDouble() ?? 0,
        axisOffsetN: (j['axisN'] as num?)?.toDouble() ?? 0,
        coreRadii: [
          for (final r in (j['coreRadii'] as List?) ?? const [])
            (r as num).toDouble()
        ],
        railOffsetN: (j['railN'] as num?)?.toDouble() ?? 0,
        railInnerReachM: (j['railInner'] as num?)?.toDouble() ?? 0,
        expressway: j['expressway'] as bool? ?? false,
        coreAvenuesE: [
          for (final v in (j['avE'] as List?) ?? const []) (v as num).toDouble()
        ],
        coreAvenuesN: [
          for (final v in (j['avN'] as List?) ?? const []) (v as num).toDouble()
        ],
        clearings: [
          for (final poly in (j['clear'] as List?) ?? const [])
            [for (final v in poly as List) (v as num).toDouble()]
        ],
        arteries: j['arteries'] as bool? ?? false,
        gridOriginE: ((j['grid'] as List?)?[0] as num?)?.toDouble() ?? 0,
        gridOriginN: ((j['grid'] as List?)?[1] as num?)?.toDouble() ?? 0,
        gridStepE: ((j['grid'] as List?)?[2] as num?)?.toDouble() ?? 0,
        gridStepN: ((j['grid'] as List?)?[3] as num?)?.toDouble() ?? 0,
        frontageRoads: [
          for (final f in (j['frontage'] as List?) ?? const [])
            [for (final v in f as List) (v as num).toDouble()]
        ],
      );

  static bool _sameList(List<double> a, List<double> b) =>
      a.length == b.length &&
      Iterable.generate(a.length).every((i) => a[i] == b[i]);

  @override
  bool operator ==(Object other) =>
      other is SprawlSpec &&
      other.seed == seed &&
      other.radiusM == radiusM &&
      other.coreRadiusM == coreRadiusM &&
      other.sectionM == sectionM &&
      other.interstates == interstates &&
      other.diagonals == diagonals &&
      other.beltway == beltway &&
      other.railBearing == railBearing &&
      other.axisOffsetE == axisOffsetE &&
      other.axisOffsetN == axisOffsetN &&
      other.railOffsetN == railOffsetN &&
      other.railInnerReachM == railInnerReachM &&
      other.expressway == expressway &&
      other.arteries == arteries &&
      other.gridOriginE == gridOriginE &&
      other.gridOriginN == gridOriginN &&
      other.gridStepE == gridStepE &&
      other.gridStepN == gridStepN &&
      other.frontageRoads.length == frontageRoads.length &&
      Iterable.generate(frontageRoads.length)
          .every((i) => _sameList(other.frontageRoads[i], frontageRoads[i])) &&
      _sameList(other.coreRadii, coreRadii) &&
      _sameList(other.coreAvenuesE, coreAvenuesE) &&
      _sameList(other.coreAvenuesN, coreAvenuesN) &&
      other.clearings.length == clearings.length &&
      Iterable.generate(clearings.length)
          .every((i) => _sameList(other.clearings[i], clearings[i]));

  @override
  int get hashCode => Object.hash(seed, radiusM, coreRadiusM, sectionM,
      interstates, diagonals, beltway, railBearing, axisOffsetE, axisOffsetN,
      railOffsetN, railInnerReachM, expressway, arteries,
      Object.hashAll([gridOriginE, gridOriginN, gridStepE, gridStepN]),
      Object.hashAll(coreRadii),
      Object.hashAll(coreAvenuesE), Object.hashAll(coreAvenuesN),
      Object.hashAll([for (final c in clearings) Object.hashAll(c)]));
}

/// What a section is mostly.
enum SprawlUse {
  /// Subdivisions: houses on a local street grid.
  residential,

  /// Big boxes and parking along the arterial: the strip.
  commercial,

  /// Sheds and yards: an industrial park.
  industrial,

  /// Fields and a farmstead.
  farmland,

  /// A forest preserve: trees, no streets.
  parkland,
}

/// One mile-square section of the sprawl.
class SprawlSection {
  const SprawlSection({
    required this.i,
    required this.j,
    required this.centre,
    required this.sizeM,
    required this.use,
    required this.density,
    required this.seed,
    this.streetLinesE = const [],
    this.streetLinesN = const [],
    List<double>? collectorOffsetsE,
    List<double>? collectorOffsetsN,
  })  : _collectorOffsetsE = collectorOffsetsE,
        _collectorOffsetsN = collectorOffsetsN;

  final int i, j;

  /// Where this section's streets run, as offsets from its centre: the
  /// north-south streets by easting, the east-west by northing. Empty means
  /// the section's own survey grid ([streetsAcross] each way). A section
  /// touching the core carries the plat's grid on instead — see
  /// [SprawlSpec.hasGrid].
  final List<double> streetLinesE;
  final List<double> streetLinesN;

  /// Whether the streets are the plat's own lines carried on.
  bool get continuesCoreGrid => streetLinesE.isNotEmpty || streetLinesN.isNotEmpty;

  final List<double>? _collectorOffsetsE;
  final List<double>? _collectorOffsetsN;

  /// Colony-local metres, east/north.
  final Vec2 centre;
  final double sizeM;
  final SprawlUse use;

  /// 0..1: how built-up. Houses per street, box count, field count all
  /// scale with it.
  final double density;
  final int seed;

  double get halfM => sizeM / 2;

  /// Local streets across the section each way, by use. Divisible by four
  /// so the collectors — the two streets a quarter of the way in from each
  /// side — fall on the grid exactly; nothing for a field or a forest.
  ///
  /// ONE definition, read by the plan (which puts a junction on the county
  /// highway wherever a collector reaches it) and by the renderer (which
  /// grows the streets), so the two cannot disagree about where a street
  /// meets the arterial.
  static int streetsAcrossFor(SprawlUse use) => switch (use) {
        SprawlUse.residential => 12,
        SprawlUse.commercial => 8,
        SprawlUse.industrial => 4,
        SprawlUse.farmland || SprawlUse.parkland => 0,
      };

  int get streetsAcross => streetsAcrossFor(use);

  /// Where the collectors run, as offsets from the section's centre — the
  /// same on both axes. A quarter of the way in from each side, which is
  /// the half-mile spacing a real township lays its through streets at.
  static List<double> collectorOffsetsFor(SprawlUse use, double sizeM) =>
      streetsAcrossFor(use) == 0 ? const [] : [-sizeM / 4, sizeM / 4];

  /// The collectors' offsets from the centre: the eastings of the
  /// north-south collectors, and the northings of the east-west ones. On
  /// the section's own grid both are the quarter points; on the plat's grid
  /// the plan picks the grid line nearest each quarter point.
  List<double> get collectorOffsetsE =>
      _collectorOffsetsE ?? collectorOffsetsFor(use, sizeM);
  List<double> get collectorOffsetsN =>
      _collectorOffsetsN ?? collectorOffsetsFor(use, sizeM);

  /// Which of the [streetsAcross] streets (1-based, one per grid line) are
  /// the collectors.
  static Set<int> collectorIndices(int streetsAcross) =>
      streetsAcross == 0 ? const {} : {streetsAcross ~/ 4, streetsAcross - streetsAcross ~/ 4};
}

/// The roads the plan lays itself. Local streets inside a section are the
/// renderer's, grown from the section's seed.
enum SprawlRoadKind {
  /// Limited-access, grade-separated, fast. Carried over every crossing.
  interstate,

  /// The mile-grid arterial: county highway, four lanes, signals at the
  /// crossings.
  countyHighway,

  /// An interchange ramp: one lane, curved, joins an interstate to a
  /// highway or a loop of a cloverleaf.
  ramp,

  /// The railway, carried on from the plat's own line out to the county
  /// line and beyond. Interstates bridge it; county highways cross it.
  rail,

  /// A right-of-way of the plat's own — the elevated expressway through the
  /// core, a trunk artery out to the mile grid. Drawn by the plat, not
  /// here; on the plan so the sections keep their houses off it and the
  /// core's interchanges can hang from it.
  corridor;

  /// The road class a kind is laid as unless the plan says otherwise. An
  /// interstate's class depends on where it is — see [SprawlPlan] — and a
  /// county highway is the plat's own four-lane avenue, so the mile grid
  /// and the downtown arterials are the same road drawn the same way.
  RoadClass get defaultClass => switch (this) {
        SprawlRoadKind.interstate => RoadClass.expressway6,
        SprawlRoadKind.countyHighway => RoadClass.avenue,
        SprawlRoadKind.ramp => RoadClass.ramp,
        SprawlRoadKind.rail => RoadClass.rail,
        SprawlRoadKind.corridor => RoadClass.elevated,
      };
}

/// A road of the plan, as a polyline in colony-local metres.
///
/// A SEGMENT of the network: the plan splits every road where another
/// meets it, so a road runs from one junction to the next and a junction
/// is a place where road ends coincide — the same shape the plat's layout
/// has, and the shape the renderer's junction pass needs.
class SprawlRoad {
  const SprawlRoad({
    required this.id,
    required this.kind,
    required this.points,
    required this.roadClass,
    this.overpasses = const [],
    this.startHalfWidthM,
    this.endHalfWidthM,
    this.soundWalls = false,
  });

  final String id;
  final SprawlRoadKind kind;
  final List<Vec2> points;

  /// What it is laid as: how many lanes, how wide, one way or two. A ramp
  /// runs first point to last.
  final RoadClass roadClass;

  /// Arc-length ranges (metres from [points.first]) where the road is
  /// carried on a bridge over whatever it crosses.
  final List<(double, double)> overpasses;

  /// A different half width at either end, for a piece that tapers into
  /// what it meets: a six-lane radial widening off the viaduct's narrower
  /// deck, or dropping to four lanes at the outline. Null means the road's
  /// own width end to end.
  final double? startHalfWidthM;
  final double? endHalfWidthM;

  /// Built with sound barriers along both edges: the walled variant, laid
  /// where the expressway runs past housing.
  final bool soundWalls;

  double get halfWidthM => roadClass.halfWidth;

  /// The road this is a piece of: 'I-1/3' is the fourth piece of 'I-1'.
  String get baseId {
    final i = id.indexOf('/');
    return i < 0 ? id : id.substring(0, i);
  }

  double get lengthM {
    var l = 0.0;
    for (var i = 1; i < points.length; i++) {
      l += points[i].distanceTo(points[i - 1]);
    }
    return l;
  }
}

/// Where two limited-access roads meet, and how.
enum SprawlInterchangeKind {
  /// Interstate over a county highway: four ramps in a diamond.
  diamond,

  /// Interstate over interstate: four loops and four outer ramps.
  cloverleaf,
}

class SprawlInterchange {
  const SprawlInterchange({required this.at, required this.kind});
  final Vec2 at;
  final SprawlInterchangeKind kind;
}

/// One leg of a junction of the plan: which way it leaves, and what it is.
class SprawlNodeLeg {
  const SprawlNodeLeg(this.dir, this.roadClass);

  /// Unit vector from the node out along the road, colony-local.
  final Vec2 dir;
  final RoadClass roadClass;
  double get halfWidthM => roadClass.halfWidth;
}

/// A junction of the plan: where roads meet, what meets there, and how it
/// is controlled. The plan's roads are split here; the renderer draws the
/// plate, the bars and the signals from this and nothing else.
class SprawlNode {
  const SprawlNode({
    required this.at,
    required this.control,
    required this.legs,
    this.liftM = 0,
  });

  final Vec2 at;
  final JunctionControl control;
  final List<SprawlNodeLeg> legs;

  /// How far above the ground the node sits — a ramp terminal climbing to
  /// a deck. Zero at grade.
  final double liftM;
}

/// The sprawl's outline: how far it reaches, per bearing.
///
/// Not a disc. A metro grows along its highways and is held back by what it
/// runs into, so its edge is lobed and ragged: low harmonics of noise on the
/// nominal radius, plus a bulge on the bearing of every radial interstate.
/// Everything that asks "how far out is this" — the section grid, the
/// density falloff, the farmland edge, where the county highways stop —
/// asks this.
class SprawlOutline {
  const SprawlOutline({
    required this.baseRadiusM,
    required this.phases,
    required this.lobes,
    this.lobeStrength = 0.16,
  });

  factory SprawlOutline.of(double baseRadiusM, List<double> lobeBearings,
      math.Random rnd) {
    return SprawlOutline(
      baseRadiusM: baseRadiusM,
      phases: [for (var i = 0; i < 4; i++) rnd.nextDouble() * 2 * math.pi],
      lobes: lobeBearings,
    );
  }

  final double baseRadiusM;
  final List<double> phases;

  /// Bearings the sprawl reaches further along.
  final List<double> lobes;
  final double lobeStrength;

  /// The sprawl's reach on [bearing].
  double radiusAt(double bearing) {
    var f = 1 +
        0.14 * math.sin(2 * bearing + phases[0]) +
        0.10 * math.sin(3 * bearing + phases[1]) +
        0.06 * math.sin(5 * bearing + phases[2]) +
        0.04 * math.sin(7 * bearing + phases[3]);
    for (final lobe in lobes) {
      final d = _angleBetween(bearing, lobe);
      f += lobeStrength * math.exp(-(d * d) / (2 * 0.22 * 0.22));
    }
    return baseRadiusM * f.clamp(0.6, 1.5);
  }

  /// The furthest the outline reaches on any bearing.
  double get maxRadiusM {
    var best = 0.0;
    for (var i = 0; i < 128; i++) {
      best = math.max(best, radiusAt(i / 128 * 2 * math.pi));
    }
    return best;
  }

  /// Where [p] sits against the outline: 0 at the centre, 1 at the edge.
  double fractionOf(Vec2 p) {
    final r = p.length;
    if (r < 1e-9) return 0;
    return r / radiusAt(math.atan2(p.n, p.e));
  }

  bool contains(Vec2 p) => fractionOf(p) <= 1;

  static double _angleBetween(double a, double b) {
    final d = (a - b) % (2 * math.pi);
    return d > math.pi ? 2 * math.pi - d : d;
  }
}

/// The plan.
class SprawlPlan {
  const SprawlPlan({
    required this.spec,
    required this.outline,
    required this.sections,
    required this.roads,
    required this.interchanges,
    this.nodes = const [],
  });

  final SprawlSpec spec;
  final SprawlOutline outline;
  final List<SprawlSection> sections;

  /// The roads, as SEGMENTS between junctions: every one is split where
  /// another meets it, so [nodes] is where their ends coincide.
  final List<SprawlRoad> roads;
  final List<SprawlInterchange> interchanges;

  /// Every junction of the plan: county highways crossing on the mile grid,
  /// ramp terminals, the collectors of every subdivision meeting its
  /// arterial, the plat's arteries meeting the grid, and the merges where a
  /// ramp joins an expressway.
  final List<SprawlNode> nodes;

  /// Section grid index range: -[n]..[n] either way, for the outline's
  /// furthest reach.
  static int gridReach(SprawlSpec s) =>
      (s.radiusM * 1.5 / s.sectionM).ceil() + 3;

  /// How far past the outline an interstate runs on into the country: far
  /// enough that its end is never in the same view as the city.
  static double outreachFor(SprawlSpec s) => math.max(8000.0, s.radiusM * 0.6);

  /// How far along a county highway from the crossing a diamond's ramps
  /// land: the ramp terminal, a signalised T on the highway.
  static const double diamondTerminalM = 110;

  /// How far along the expressway from the crossing a diamond's ramps
  /// merge with it.
  static const double diamondMergeM = 420;

  /// A cloverleaf's loop radius, and the radius of its outer connectors.
  static const double loopRadiusM = 75;
  static const double connectorRadiusM = 400;

  /// How high a bridge deck stands over what it crosses, and over how much
  /// road it rises to that height.
  static const double bridgeHeightM = 9.5;
  static const double bridgeRampM = 130.0;

  /// Deck lift at arc length [s] over the bridged [ranges]: a smooth rise
  /// over the first and last stretch of each, full height between. The
  /// renderer draws decks and lifts traffic with exactly this.
  static double bridgeLiftAt(double s, List<(double, double)> ranges) {
    for (final (a, b) in ranges) {
      if (s < a || s > b) continue;
      final t = math.min(1.0, math.min((s - a) / bridgeRampM, (b - s) / bridgeRampM));
      return bridgeHeightM * t * t * (3 - 2 * t);
    }
    return 0;
  }

  static SprawlPlan generate(SprawlSpec spec) {
    final rnd = math.Random(spec.seed * 7919 + 13);
    final n = gridReach(spec);
    final sectionM = spec.sectionM;
    // The outline bulges along the radial interstates.
    final outline = SprawlOutline.of(
      spec.radiusM,
      [
        for (var a = 0; a < math.min(4, spec.interstates); a++) a * math.pi / 2,
        for (var a = 0; a < math.min(4, spec.diagonals); a++)
          math.pi / 4 + a * math.pi / 2,
      ],
      rnd,
    );
    final net = _Net();

    // ---- The interstates and the beltway --------------------------------
    //
    // Straight-ish radials on the axes, from the core's central avenues to
    // the county line, bending gently once out in the sections; the
    // diagonals likewise; the beltway a ring at 0.48 R. Interstates never
    // run down a section line — they cut the sections, which is what a real
    // one does to a grid laid before it.
    final interstates = <_Draft>[];
    List<Vec2> radial(double bearing, double offset, {double? startM}) {
      final dir = Vec2(math.cos(bearing), math.sin(bearing));
      final side = dir.perp;
      final out = <Vec2>[];
      const steps = 12;
      final start = startM ?? spec.coreRadiusAt(bearing) * 0.98;
      final end = outline.radiusAt(bearing) + outreachFor(spec);
      var wander = 0.0;
      for (var k = 0; k <= steps; k++) {
        final d = start + (end - start) * k / steps;
        if (k > 1) wander += (rnd.nextDouble() - 0.5) * 140;
        wander *= 0.85;
        out.add(dir * d + side * (offset + wander));
      }
      return out;
    }

    var count = 0;
    // The axial interstates on the plat's central avenues: east and west
    // on one line, north and south on the other. The lateral offset is in
    // each radial's own frame — side is dir.perp — so opposite bearings
    // take opposite signs to land on the same line. Where the plat carries
    // the east-west line through the core on its expressway, those two
    // start at deck height and come down to grade over their first
    // hundred and thirty metres.
    for (var a = 0; a < math.min(4, spec.interstates); a++) {
      final bearing = a * math.pi / 2;
      final lateral = switch (a) {
        0 => spec.axisOffsetN,
        1 => -spec.axisOffsetE,
        2 => -spec.axisOffsetN,
        _ => spec.axisOffsetE,
      };
      final d = net.add(_Draft('I-${++count}', SprawlRoadKind.interstate,
          radial(bearing, lateral)))
        ..radial = true;
      interstates.add(d);
      if (spec.expressway && a.isEven) {
        // Off the deck: at its height to begin with, and as wide as it —
        // the shoulders open out to the expressway's own over the descent.
        d.overpasses.add((-bridgeRampM, bridgeRampM));
        d.startHalfWidthM = RoadClass.elevated.halfWidth;
      } else {
        // The expressway ENDS at the core: it carries on as the plat's
        // central avenue, and widens out of the avenue's width over its
        // first stretch rather than stepping.
        d.startHalfWidthM = RoadClass.avenue.halfWidth;
      }
    }
    // A diagonal has no avenue to carry on from: it begins at the first
    // crossing of the county grid clear of the core — which lies exactly
    // on its bearing — where it ends at a signal with the two highways.
    final diagonalStarts = <_Draft, Vec2>{};
    for (var a = 0; a < math.min(4, spec.diagonals); a++) {
      final bearing = math.pi / 4 + a * math.pi / 2;
      final k = ((spec.coreRadiusAt(bearing) * 0.98 + 300) / (sectionM * math.sqrt2)).ceil();
      final startAt = Vec2(math.cos(bearing), math.sin(bearing)) * (k * sectionM * math.sqrt2);
      final d = net.add(_Draft('I-${++count}', SprawlRoadKind.interstate,
          radial(bearing, 0, startM: k * sectionM * math.sqrt2)))
        ..radial = true
        ..diagonal = true;
      diagonalStarts[d] = startAt;
      interstates.add(d);
    }
    if (spec.beltway) {
      final pts = <Vec2>[];
      const steps = 48;
      for (var k = 0; k <= steps; k++) {
        final a = k / steps * 2 * math.pi;
        // Half the outline's reach, averaged over a wedge so the ring bends
        // gently where the edge is ragged.
        var rr = 0.0;
        for (var j = -3; j <= 3; j++) {
          rr += outline.radiusAt(a + j * 0.12);
        }
        rr = rr / 7 * 0.5;
        pts.add(Vec2(math.cos(a) * rr, math.sin(a) * rr));
      }
      final d = net.add(_Draft('I-${++count}', SprawlRoadKind.interstate, pts))
        ..beltway = true;
      interstates.add(d);
    }
    // Where each radial leaves the built-up outline: past it the road drops
    // from six lanes to four. Six inside, because that is what the viaduct
    // through the core carries and a mainline does not change its lane
    // count where a deck happens to end.
    for (final d in interstates) {
      if (!d.radial) continue;
      for (var k = 0; k < d.points.length; k++) {
        if (outline.fractionOf(d.points[k]) > 1.0) {
          d.outS = d.cum[k];
          break;
        }
      }
    }

    // ---- The railway, on from the plat's line ------------------------------
    //
    // Straight off the end of the plat's own track, wandering a little once
    // it is out in the fields, to well past the outline both ways.
    final rails = <_Draft>[];
    if (spec.railInnerReachM > 0) {
      for (final sign in const [1.0, -1.0]) {
        final bearing = sign > 0 ? 0.0 : math.pi;
        final end = outline.radiusAt(bearing) + outreachFor(spec) + 3000;
        final pts = <Vec2>[];
        const steps = 10;
        var wander = 0.0;
        for (var k = 0; k <= steps; k++) {
          final x = sign * (spec.railInnerReachM + (end - spec.railInnerReachM) * k / steps);
          if (k > 0) wander += (rnd.nextDouble() - 0.5) * 60;
          wander *= 0.8;
          pts.add(Vec2(x, spec.railOffsetN + (k == 0 ? 0 : wander)));
        }
        rails.add(net.add(
            _Draft('RR-${sign > 0 ? 'E' : 'W'}', SprawlRoadKind.rail, pts)));
      }
    }

    // ---- The county highways: the section-line grid ----------------------
    final highways = <_Draft>[];
    final maxR = outline.maxRadiusM;
    // A section line an axial interstate runs along is the interstate's
    // corridor, not a county highway's: a grid line laid there sat under
    // the expressway, crossed it wherever it wandered, and grew a diamond
    // at every crossing.
    bool underInterstate(int axis, double t) {
      final lines = axis == 0
          ? [if (spec.interstates >= 1) spec.axisOffsetN]
          : [if (spec.interstates >= 2) spec.axisOffsetE];
      return lines.any((l) => (l - t).abs() < 250);
    }

    for (var axis = 0; axis < 2; axis++) {
      for (var i = -n; i <= n; i++) {
        final t = i * sectionM;
        if (t.abs() > maxR) continue;
        if (underInterstate(axis, t)) continue;
        // Walk out from the centre each way until the outline ends: the edge
        // is ragged, so each line finds its own reach.
        Vec2 at(double s) => axis == 0 ? Vec2(s, t) : Vec2(t, s);
        // On past the outline by a couple of sections: the survey grid does
        // not stop where the houses do, and a road that ended exactly at
        // the last subdivision would show its end from the next one.
        double reachTo(double sign) {
          var s = 0.0;
          while (s < maxR && outline.contains(at(sign * (s + 50)))) {
            s += 50;
          }
          return s + sectionM * 2;
        }
        if (!outline.contains(at(0))) continue;
        final reachA = reachTo(-1), reachB = reachTo(1);
        // The core has its own streets and a staked plot is somebody's
        // ground: the highway stops at the edge of either and resumes the
        // far side. Walked in steps, so a line finds every gap it crosses.
        bool blocked(Vec2 p) =>
            spec.coreContains(p, marginM: 40) || spec.inClearing(p, marginM: 30);
        final spans = <(double, double)>[];
        double? open;
        for (var s = -reachA; s <= reachB + 1e-6; s += 20) {
          final b = blocked(at(s));
          if (!b && open == null) open = s;
          if (b && open != null) {
            spans.add((open, s - 20));
            open = null;
          }
        }
        if (open != null) spans.add((open, reachB));
        for (final (a, b) in spans) {
          if (b - a < sectionM * 0.6) continue;
          final pts = [
            for (var s = a; s <= b + 1e-6; s += sectionM / 4)
              axis == 0 ? Vec2(math.min(s, b), t) : Vec2(t, math.min(s, b)),
          ];
          if (pts.last.distanceTo(axis == 0 ? Vec2(b, t) : Vec2(t, b)) > 1e-6) {
            pts.add(axis == 0 ? Vec2(b, t) : Vec2(t, b));
          }
          final d = net.add(_Draft(
              'CH-${axis == 0 ? 'E' : 'N'}$i${a < 0 ? 'a' : 'b'}',
              SprawlRoadKind.countyHighway,
              pts))
            ..axis = axis
            ..line = i
            ..a = a
            ..b = b;
          highways.add(d);
        }
      }
    }

    // ---- The expressway through the core ----------------------------------
    //
    // The plat draws it — an elevated expressway on the central avenue with
    // frontage roads under it — so here it is a corridor, not a road: what
    // the sections keep their houses off, and what the core's own
    // interchanges hang from. A diamond wherever it crosses one of the
    // plat's north-south avenues, well inside the core and well apart,
    // with the ramps climbing to the deck over their last stretch.
    final interchanges = <SprawlInterchange>[];
    var rampCount = 0;
    if (spec.expressway) {
      final y = spec.axisOffsetN;
      final west = -spec.coreRadiusAt(math.pi) * 0.98;
      final east = spec.coreRadiusAt(0) * 0.98;
      final cpts = [
        for (var k = 0; k <= 10; k++) Vec2(west + (east - west) * k / 10, y),
      ];
      net.add(_Draft('X-EW', SprawlRoadKind.corridor, cpts,
          roadClass: RoadClass.elevated));
      // The whole line, west radial to east radial through the corridor,
      // so a ramp near the core's edge can run on out along the interstate
      // rather than bunch at the corridor's end.
      final westward = interstates.length > 2 ? interstates[2] : null;
      final eastward = interstates.isNotEmpty ? interstates[0] : null;
      final through = [
        if (westward != null) ...westward.points.reversed,
        ...cpts,
        if (eastward != null) ...eastward.points,
      ];
      final tcum = _cumulative(through);
      final origin = westward != null ? tcum[westward.points.length] : 0.0;
      final corridorLen = _cumulative(cpts).last;
      final map = _ThroughMap(westward, eastward, origin, corridorLen);
      var last = double.negativeInfinity;
      final avenues = [...spec.coreAvenuesE]..sort();
      for (final x in avenues) {
        if ((x - spec.axisOffsetE).abs() < 200) continue;
        final p = Vec2(x, y);
        if (!spec.coreContains(p, marginM: -100)) continue;
        final s = origin + (x - west);
        if ((s - last).abs() < 700) continue;
        last = s;
        final avenue = [Vec2(x, y - 600), Vec2(x, y + 600)];
        final onI = _Along(through, tcum, s);
        final onO = _Along(avenue, _cumulative(avenue), 600);
        interchanges.add(SprawlInterchange(at: p, kind: SprawlInterchangeKind.diamond));
        // The terminals land on the PLAT's avenue, which the plan does not
        // own: the node is made outright, its through legs the avenue's.
        _diamond(
          net,
          p,
          onI,
          onO,
          'R-${++rampCount}',
          cutI: map.cut,
          cutO: (so, leg) => net.extraNodes.add(SprawlNode(
            at: onO.at(so),
            control: junctionControlFor(
                [RoadClass.avenue, RoadClass.avenue, leg.roadClass]),
            legs: [
              SprawlNodeLeg(onO.dir, RoadClass.avenue),
              SprawlNodeLeg(onO.dir * -1.0, RoadClass.avenue),
              leg,
            ],
          )),
          classI: map.classAt,
          liftI: map.liftAt,
        );
      }

      // The frontage roads under the deck carry on as slip ramps where it
      // comes down: traffic keeps right, so the south one is eastbound and
      // the north one westbound; each becomes an on-ramp at the end it
      // drives toward and receives an off-ramp at the other. Nothing
      // stops dead at the core's edge, and the plat's frontage road end
      // and the ramp's start are one point.
      final dir = const Vec2(1, 0); // through line: west to east
      double arcOf(double x) => origin + (x - west);
      for (final f in spec.frontageRoads) {
        if (f.length < 3) continue;
        final t = f[0], a = f[1], b = f[2];
        final south = t < y;
        final so = south ? -1.0 : 1.0; // which side of the line it is on
        // Eastbound uses the south road and runs west to east; westbound
        // the north road, east to west.
        final east = south;
        final onEnd = east ? b : a, offEnd = east ? a : b;
        final travel = dir * (east ? 1.0 : -1.0);
        final sOn = arcOf(onEnd) + (east ? 350 : -350);
        final sOff = arcOf(offEnd) - (east ? 350 : -350);
        for (final (isOn, sMerge, endX) in [(true, sOn, onEnd), (false, sOff, offEnd)]) {
          final along = _Along(through, tcum, sMerge);
          final edge = _edgeOf(map.classAt(sMerge));
          // On the line's outer edge, the frontage road's side of it,
          // wherever the line has bent to by then.
          final merge = along.at(0) + along.dir.perp * (so * edge);
          final road = Vec2(endX, t);
          final List<Vec2> pts = isOn
              ? _cubic(road, road + travel * 150, merge - along.dir * (east ? 200 : -200), merge)
              : _cubic(merge, merge + along.dir * (east ? 200 : -200), road - travel * 150, road);
          net.add(_Draft('R-F${++rampCount}', SprawlRoadKind.ramp, pts,
              roadClass: RoadClass.ramp));
          map.cut(sMerge, SprawlNodeLeg(Vec2(0, so), RoadClass.ramp));
        }
      }
    }

    // ---- Interchanges: where an interstate crosses anything ---------------
    //
    // The interstate is carried over on a bridge; a diamond of ramps joins it
    // to a county highway, a cloverleaf to another interstate. Crossings
    // closer than a mile to the last on the same interstate get the bridge
    // but no ramps — real interchanges are a mile or more apart.
    for (var ii = 0; ii < interstates.length; ii++) {
      final d = interstates[ii];
      final ipts = d.points;
      final icum = d.cum;
      final ramped = <double>[];
      void crossings(_Draft o, bool otherIsInterstate, {bool ramps = true}) {
        final other = o.points;
        final ocum = o.cum;
        for (var a = 1; a < ipts.length; a++) {
          for (var b = 1; b < other.length; b++) {
            final hit = _segmentHit(ipts[a - 1], ipts[a], other[b - 1], other[b]);
            if (hit == null) continue;
            final (t, p) = hit;
            final s = icum[a - 1] + (icum[a] - icum[a - 1]) * t;
            // Too near an end to bridge: skip (the core edge, the county line).
            if (s < 260 || s > icum.last - 260) continue;
            d.overpasses.add((s - 190, s + 190));
            final os = ocum[b - 1] + (p - other[b - 1]).length;
            if (!ramps) continue;
            final near = ramped.any((r) => (r - s).abs() < sectionM * 0.9);
            if (near) continue;
            ramped.add(s);
            final onI = _Along(ipts, icum, s);
            final onO = _Along(other, ocum, os);
            if (otherIsInterstate) {
              // Both are interstates: only the lower-indexed one owns the
              // cloverleaf, so the pair is not built twice.
              interchanges.add(SprawlInterchange(at: p, kind: SprawlInterchangeKind.cloverleaf));
              _cloverleaf(net, p, onI, onO, 'R-${++rampCount}',
                  cutI: (s, leg) => d.cuts.add(_Cut(s, legs: [leg])),
                  cutO: (s, leg) => o.cuts.add(_Cut(s, legs: [leg])),
                  classI: d.classAt,
                  classO: o.classAt);
            } else {
              interchanges.add(SprawlInterchange(at: p, kind: SprawlInterchangeKind.diamond));
              _diamond(net, p, onI, onO, 'R-${++rampCount}',
                  cutI: (s, leg) => d.cuts.add(_Cut(s, legs: [leg])),
                  cutO: (s, leg) => o.cuts.add(_Cut(s, legs: [leg])),
                  classI: d.classAt);
            }
          }
        }
      }
      for (var jj = ii + 1; jj < interstates.length; jj++) {
        crossings(interstates[jj], true);
      }
      for (final h in highways) {
        crossings(h, false);
      }
      for (final rr in rails) {
        crossings(rr, false, ramps: false);
      }
      // The lane count changes with position: a split, not a junction.
      if (d.radial && d.outS.isFinite) d.cuts.add(_Cut(d.outS, node: false));
    }
    for (final d in interstates) {
      d.overpasses
        ..sort((a, b) => a.$1.compareTo(b.$1))
        ..replaceRange(0, d.overpasses.length, _mergeRanges(List.of(d.overpasses)));
    }

    // ---- The sections ---------------------------------------------------
    //
    // Use by radius with noise, and by what is nearby: industry along the
    // railway side and the beltway, commerce at the interchanges, forest
    // preserves scattered, farms past the built edge.
    final sections = <SprawlSection>[];
    for (var i = -n; i <= n; i++) {
      for (var j = -n; j <= n; j++) {
        final c = Vec2((i + 0.5) * sectionM, (j + 0.5) * sectionM);
        final r = c.length;
        final seed = spec.seed * 100003 + i * 1009 + j * 31;
        final local = math.Random(seed);
        final noise = (local.nextDouble() - 0.5) * 0.16;
        // Against the OUTLINE, with the section's own noise: the edge frays
        // section by section rather than following a curve.
        final t = outline.fractionOf(c) + noise;
        if (t > 1.0) continue;
        // Every section that reaches past the plat is grown, the four round
        // downtown included: the renderer keeps their houses off the plat,
        // and the rest of each comes right up to the last downtown street.
        if (r + sectionM * 0.7 < spec.coreRadiusAt(math.atan2(c.n, c.e))) {
          continue;
        }
        final bearing = math.atan2(c.n, c.e);
        final railSide = _angleBetween(bearing, spec.railBearing) < 0.55;
        final nearInterchange = interchanges.any((x) => x.at.distanceTo(c) < sectionM * 0.9);
        SprawlUse use;
        double density;
        if (t > 0.86) {
          use = SprawlUse.farmland;
          density = 0.3;
        } else if (railSide && t > 0.3 && local.nextDouble() < 0.55) {
          use = SprawlUse.industrial;
          density = 0.6;
        } else if (nearInterchange && local.nextDouble() < 0.7) {
          use = SprawlUse.commercial;
          density = 0.7;
        } else if (local.nextDouble() < 0.07) {
          use = SprawlUse.parkland;
          density = 0;
        } else {
          use = SprawlUse.residential;
          density = (1.15 - t).clamp(0.25, 0.95);
        }
        if (t > 0.78 && use != SprawlUse.farmland && local.nextDouble() < 0.5) {
          use = SprawlUse.farmland;
          density = 0.3;
        }
        sections.add(SprawlSection(
            i: i, j: j, centre: c, sizeM: sectionM, use: use, density: density, seed: seed));
      }
    }

    // ---- The inner suburbs carry the plat's grid on ------------------------
    //
    // A section that touches the core lays its streets on the plat's own
    // lines, so a downtown street runs on into the suburb instead of
    // stopping dead at the last block. Its collectors are the grid lines
    // nearest the quarter points; the avenues are left to the arteries
    // the plat itself carries out to the county grid.
    if (spec.hasGrid) {
      for (var k = 0; k < sections.length; k++) {
        final sec = sections[k];
        if (sec.streetsAcross == 0) continue;
        final bearing = math.atan2(sec.centre.n, sec.centre.e);
        final reach = sec.centre.length - sec.sizeM * math.sqrt2 / 2;
        if (reach > spec.coreRadiusAt(bearing) + 300) continue;
        final half = sec.halfM;
        List<double> lines(double origin, double step, double centre,
            List<double> avenues) {
          final out = <double>[];
          final k0 = ((centre - half + 40 - origin) / step).ceil();
          final k1 = ((centre + half - 40 - origin) / step).floor();
          for (var i = k0; i <= k1; i++) {
            final t = origin + i * step;
            if (avenues.any((a) => (a - t).abs() < 1)) continue;
            out.add(t - centre);
          }
          return out;
        }

        final linesE = lines(spec.gridOriginE, spec.gridStepE, sec.centre.e,
            spec.coreAvenuesE);
        final linesN = lines(spec.gridOriginN, spec.gridStepN, sec.centre.n,
            spec.coreAvenuesN);
        if (linesE.isEmpty || linesN.isEmpty) continue;
        double nearest(List<double> ls, double target) => ls.reduce(
            (a, b) => (a - target).abs() < (b - target).abs() ? a : b);
        final q = sec.sizeM / 4;
        sections[k] = SprawlSection(
          i: sec.i,
          j: sec.j,
          centre: sec.centre,
          sizeM: sec.sizeM,
          use: sec.use,
          density: sec.density,
          seed: sec.seed,
          streetLinesE: linesE,
          streetLinesN: linesN,
          collectorOffsetsE: [nearest(linesE, -q), nearest(linesE, q)],
          collectorOffsetsN: [nearest(linesN, -q), nearest(linesN, q)],
        );
      }
    }

    // ---- The county grid's own junctions ----------------------------------
    //
    // Highways crossing on the mile grid; every subdivision's collectors
    // meeting the highway on its section line; the plat's arteries meeting
    // the first mile line past the core. Each is a cut on the highway it
    // lands on, so the highway is a run of segments between real junctions
    // rather than one ribbon the streets stop short of.
    _Draft? highwayAt(int axis, int line, double coord, {double margin = 20}) {
      for (final h in highways) {
        if (h.axis != axis || h.line != line) continue;
        if (coord >= h.a + margin && coord <= h.b - margin) return h;
      }
      return null;
    }

    for (final e in highways) {
      if (e.axis != 0) continue;
      for (final nn in highways) {
        if (nn.axis != 1) continue;
        final x = nn.line * sectionM, y = e.line * sectionM;
        if (x < e.a + 20 || x > e.b - 20) continue;
        if (y < nn.a + 20 || y > nn.b - 20) continue;
        e.cuts.add(_Cut(x - e.a));
        nn.cuts.add(_Cut(y - nn.a));
      }
    }
    // The diagonals' termini: a leg of the expressway on the crossing it
    // starts from, so the crossing is an expressway's end, not a merge.
    diagonalStarts.forEach((d, at) {
      final leg = SprawlNodeLeg(d.dirAt(0), d.classAt(0));
      final e = highwayAt(0, (at.n / sectionM).round(), at.e, margin: 1);
      final nn = highwayAt(1, (at.e / sectionM).round(), at.n, margin: 1);
      // The expressway's leg once, on whichever highway is there: the two
      // cuts land on one node, and a leg counted twice reads as a through
      // expressway rather than one ending.
      if (e != null) e.cuts.add(_Cut(at.e - e.a, legs: [leg]));
      if (nn != null) {
        nn.cuts.add(_Cut(at.n - nn.a, legs: e == null ? [leg] : const []));
      }
    });

    // The corridors the sections keep their streets off: an interstate or a
    // ramp within a street's clearance means no street, so no leg either.
    final corridorRoads = [
      for (final d in net.drafts)
        if (d.kind == SprawlRoadKind.interstate || d.kind == SprawlRoadKind.ramp) d
    ];
    bool nearCorridor(Vec2 p, {double clearM = 45}) {
      for (final d in corridorRoads) {
        if (p.e < d.minE - clearM || p.e > d.maxE + clearM) continue;
        if (p.n < d.minN - clearM || p.n > d.maxN + clearM) continue;
        for (var i = 1; i < d.points.length; i++) {
          if (_distanceToSegment(p, d.points[i - 1], d.points[i]) < clearM) {
            return true;
          }
        }
      }
      return false;
    }

    bool streetBlocked(Vec2 p) =>
        spec.coreContains(p, marginM: 60) ||
        spec.inClearing(p, marginM: 12) ||
        nearCorridor(p);

    // A collector that is blocked just inside the section — a staked plot
    // a hundred metres in — would be a stub off the highway to nowhere:
    // no junction for those either.
    const collectorReachM = 160.0;
    for (final s in sections) {
      if (s.streetsAcross == 0) continue;
      final half = s.halfM;
      for (final off in s.collectorOffsetsE) {
        // South and north edges: on the east-west highways.
        for (final sign in const [-1.0, 1.0]) {
          final edgeN = s.centre.n + sign * half;
          final at = Vec2(s.centre.e + off, edgeN);
          final inward = Vec2(0, -sign);
          if (streetBlocked(at) || streetBlocked(at + inward * collectorReachM)) {
            continue;
          }
          final h = highwayAt(0, (edgeN / sectionM).round(), at.e);
          if (h == null) continue;
          h.cuts.add(_Cut(at.e - h.a,
              legs: [SprawlNodeLeg(inward, RoadClass.street)]));
        }
      }
      for (final off in s.collectorOffsetsN) {
        // West and east edges: on the north-south highways.
        for (final sign in const [-1.0, 1.0]) {
          final edgeE = s.centre.e + sign * half;
          final at = Vec2(edgeE, s.centre.n + off);
          final inward = Vec2(-sign, 0);
          if (streetBlocked(at) || streetBlocked(at + inward * collectorReachM)) {
            continue;
          }
          final h = highwayAt(1, (edgeE / sectionM).round(), at.n);
          if (h == null) continue;
          h.cuts.add(_Cut(at.n - h.a,
              legs: [SprawlNodeLeg(inward, RoadClass.street)]));
        }
      }
    }

    if (spec.arteries) {
      // The plat's avenues carried on to the county grid as trunk roads:
      // each meets the first mile line at least forty metres past the last
      // street — the rule the plat lays them by — at a signalised T.
      void artery(double along, int axis) {
        for (final sign in const [-1.0, 1.0]) {
          var edge = 0.0;
          Vec2 at(double d) => axis == 0 ? Vec2(along, sign * d) : Vec2(sign * d, along);
          while (edge < spec.coreRadiusM * 3 && spec.coreContains(at(edge))) {
            edge += 8;
          }
          final k = ((edge + 40) / sectionM).ceil();
          final line = (sign * k).round();
          // An east-west avenue runs north-south out of town and meets the
          // east-west highway on line k; axis 0 here means "the avenue at
          // easting [along]".
          final h = highwayAt(axis == 0 ? 0 : 1, line, along, margin: 60);
          if (h == null) continue;
          h.cuts.add(_Cut(along - h.a, legs: [
            SprawlNodeLeg(axis == 0 ? Vec2(0, -sign) : Vec2(-sign, 0), RoadClass.trunk),
          ]));
        }
      }

      for (final x in spec.coreAvenuesE) {
        if ((x - spec.axisOffsetE).abs() < 1) continue;
        artery(x, 0);
      }
      for (final y in spec.coreAvenuesN) {
        if ((y - spec.axisOffsetN).abs() < 1) continue;
        artery(y, 1);
      }
    }

    // Sound barriers where an expressway runs past housing: the walled
    // variant on every piece whose middle lies in a built-up residential
    // section, open everywhere else.
    bool wallsAt(Vec2 p) {
      for (final sec in sections) {
        if ((p.e - sec.centre.e).abs() > sec.halfM ||
            (p.n - sec.centre.n).abs() > sec.halfM) {
          continue;
        }
        return sec.use == SprawlUse.residential && sec.density >= 0.4;
      }
      return false;
    }

    final (roads, nodes) = net.build(wallsAt);
    return SprawlPlan(
        spec: spec,
        outline: outline,
        sections: sections,
        roads: roads,
        interchanges: interchanges,
        nodes: nodes);
  }

  // ---- Interchange geometry -------------------------------------------------

  /// Which sign of [odir] lies to the RIGHT of travel along [dir]. Traffic
  /// keeps right, so this is what decides which quadrant's ramp is an
  /// on-ramp and which an off-ramp.
  static double _rightOf(Vec2 dir, Vec2 odir) =>
      Vec2(dir.n, -dir.e).dot(odir) >= 0 ? 1.0 : -1.0;

  /// The lateral offset of a road's outer edge line — where a ramp merges.
  static double _edgeOf(RoadClass cls) =>
      cls.halfWidth - (cls.lanes?.shoulderM ?? 0);

  /// A diamond: the expressway passes over the other road at [p]. Four
  /// ramps, one per quadrant, each a T on the other road [diamondTerminalM]
  /// from the crossing and a merge on the expressway's outer edge
  /// [diamondMergeM] along it — ON the expressway, wherever its bends have
  /// taken it by then.
  ///
  /// Two are on-ramps and two off-ramps, by which side of the expressway
  /// the quadrant is: traffic keeps right, joins after the crossing and
  /// leaves before it. An on-ramp runs terminal to merge; an off-ramp is
  /// laid the other way round, because a ramp's direction IS its point
  /// order.
  static void _diamond(
    _Net net,
    Vec2 p,
    _Along i,
    _Along o,
    String id, {
    required _Cutter cutI,
    required _Cutter cutO,
    required _ClassAt classI,
    double Function(double s)? liftI,
  }) {
    var k = 0;
    final dir = i.dir, odir = o.dir;
    final right = _rightOf(dir, odir);
    for (final si in const [-1.0, 1.0]) {
      for (final so in const [-1.0, 1.0]) {
        final terminal = o.at(so * diamondTerminalM);
        final mergeS = i.s + si * diamondMergeM;
        final edge = _edgeOf(classI(mergeS));
        final merge = i.at(si * diamondMergeM) + odir * (so * edge);
        final mergeDir = i.dirAt(si * diamondMergeM);
        // Leaves the other road square-on, runs parallel to the expressway
        // and eases into its outer lane — along the expressway as it
        // actually runs there, bends and all.
        var pts = _cubic(terminal, terminal + dir * (si * 160),
            merge - mergeDir * (si * 200), merge);
        final onRamp = si * so * right > 0;
        if (!onRamp) pts = pts.reversed.toList();
        final d = _Draft('$id${String.fromCharCode(97 + k++)}',
            SprawlRoadKind.ramp, pts,
            roadClass: RoadClass.ramp);
        if (liftI != null && liftI(mergeS) > bridgeHeightM / 2) {
          // The mainline is on its deck where this ramp meets it: climb to
          // it over the last stretch, or come down off it over the first.
          final l = d.length;
          d.overpasses.add(onRamp
              ? (l - bridgeRampM, l + bridgeRampM)
              : (-bridgeRampM, bridgeRampM));
        }
        net.add(d);
        cutO(o.s + so * diamondTerminalM, SprawlNodeLeg(dir * si, RoadClass.ramp));
        cutI(mergeS, SprawlNodeLeg(odir * so, RoadClass.ramp));
      }
    }
  }

  /// A cloverleaf at [p]: four loop ramps, one per quadrant, each three
  /// quarters of a circle tangent to both roads' outer edges, plus four
  /// outer connectors — quarter circles well outside the loops — for the
  /// right turns.
  ///
  /// The loops carry the left turns: leave after the crossing, wind round,
  /// join the other road before it. Which way each runs follows from
  /// keeping right, the same rule as the diamond's.
  static void _cloverleaf(
    _Net net,
    Vec2 p,
    _Along i,
    _Along o,
    String id, {
    required _Cutter cutI,
    required _Cutter cutO,
    required _ClassAt classI,
    required _ClassAt classO,
  }) {
    var k = 0;
    final dir = i.dir, odir = o.dir;
    final right = _rightOf(dir, odir);
    final edgeI = _edgeOf(classI(i.s));
    final edgeO = _edgeOf(classO(o.s));
    for (final si in const [-1.0, 1.0]) {
      for (final so in const [-1.0, 1.0]) {
        // The loop's two tangent points, ON each road's edge line where
        // that road actually runs — a loop radius past the crossing.
        final lI = si * (loopRadiusM + edgeO), lO = so * (loopRadiusM + edgeI);
        final loopStart = i.at(lI) + odir * (so * edgeI);
        final loopEnd = o.at(lO) + dir * (si * edgeO);
        // A circle tangent to the expressway at its start: centre a loop
        // radius in from the start, across the road.
        final centre = loopStart + odir * (so * loopRadiusM);
        // In the roads' own frame — cos along [dir], sin along [odir] —
        // from the point nearest the expressway, three quarters of a turn
        // round to the point nearest the other road.
        final a0 = -so * math.pi / 2;
        final sweep = (si * so > 0 ? 1 : -1) * 1.5 * math.pi;
        const steps = 27;
        final circleEnd = centre +
            dir * (loopRadiusM * math.cos(a0 + sweep)) +
            odir * (loopRadiusM * math.sin(a0 + sweep));
        // Where the roads bend, the circle's end misses the other road's
        // edge by a few metres: ease the last stretch onto it.
        final miss = loopEnd - circleEnd;
        var pts = <Vec2>[
          for (var s = 0; s <= steps; s++)
            () {
              final t = s / steps;
              final a = a0 + sweep * t;
              final ease = t < 0.6 ? 0.0 : ((t - 0.6) / 0.4) * ((t - 0.6) / 0.4);
              return centre +
                  dir * (loopRadiusM * math.cos(a)) +
                  odir * (loopRadiusM * math.sin(a)) +
                  miss * ease;
            }(),
        ];
        final fromI = si * so * right > 0;
        if (!fromI) pts = pts.reversed.toList();
        net.add(_Draft('$id${String.fromCharCode(97 + k++)}',
            SprawlRoadKind.ramp, pts,
            roadClass: RoadClass.ramp));
        cutI(i.s + lI, SprawlNodeLeg(odir * so, RoadClass.ramp));
        cutO(o.s + lO, SprawlNodeLeg(dir * si, RoadClass.ramp));

        // The outer connector of the same quadrant: a quarter turn between
        // the two roads well outside the loop, tangent to each where it
        // leaves and where it lands.
        final cI = si * (connectorRadiusM + edgeO), cO = so * (connectorRadiusM + edgeI);
        final connStart = i.at(cI) + odir * (so * edgeI);
        final connEnd = o.at(cO) + dir * (si * edgeO);
        final dirStart = i.dirAt(cI), dirEnd = o.dirAt(cO);
        // The cubic that best fits a quarter circle pulls its controls
        // 0.5523 of the radius along each tangent.
        final pull = 0.5523 * connectorRadiusM;
        var cpts = _cubic(
          connStart,
          connStart - dirStart * (si * pull),
          connEnd - dirEnd * (so * pull),
          connEnd,
          steps: 14,
        );
        final cFromI = si * so * right < 0;
        if (!cFromI) cpts = cpts.reversed.toList();
        net.add(_Draft('$id${String.fromCharCode(97 + k++)}',
            SprawlRoadKind.ramp, cpts,
            roadClass: RoadClass.ramp));
        cutI(i.s + cI, SprawlNodeLeg(odir * so, RoadClass.ramp));
        cutO(o.s + cO, SprawlNodeLeg(dir * si, RoadClass.ramp));
      }
    }
  }

  // ---- Geometry helpers -----------------------------------------------------

  /// A point on a polyline reached by arc length, and how to step along it.
  static Vec2 _pointAt(List<Vec2> pts, List<double> cum, double s) {
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

  static List<double> _cumulative(List<Vec2> pts) {
    final cum = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum[i - 1] + pts[i].distanceTo(pts[i - 1]));
    }
    return cum;
  }

  /// Where segment a0-a1 crosses b0-b1: the parameter along a and the point,
  /// or null.
  static (double, Vec2)? _segmentHit(Vec2 a0, Vec2 a1, Vec2 b0, Vec2 b1) {
    final d = a1 - a0;
    final r = b1 - b0;
    final denom = d.cross(r);
    if (denom.abs() < 1e-9) return null;
    final w = b0 - a0;
    final t = w.cross(r) / denom;
    final u = w.cross(d) / denom;
    if (t < 0 || t > 1 || u < 0 || u > 1) return null;
    return (t, a0 + d * t);
  }

  static double _distanceToSegment(Vec2 p, Vec2 a, Vec2 b) {
    final ab = b - a;
    final len2 = ab.dot(ab);
    final t = len2 < 1e-12 ? 0.0 : ((p - a).dot(ab) / len2).clamp(0.0, 1.0);
    return (a + ab * t).distanceTo(p);
  }

  static List<(double, double)> _mergeRanges(List<(double, double)> ranges) {
    final out = <(double, double)>[];
    for (final r in ranges) {
      if (out.isNotEmpty && r.$1 <= out.last.$2) {
        out[out.length - 1] = (out.last.$1, math.max(out.last.$2, r.$2));
      } else {
        out.add(r);
      }
    }
    return out;
  }

  static double _angleBetween(double a, double b) {
    final d = (a - b) % (2 * math.pi);
    return d > math.pi ? 2 * math.pi - d : d;
  }

  /// A cubic Bézier from [a] to [b] with controls [c1], [c2], sampled.
  static List<Vec2> _cubic(Vec2 a, Vec2 c1, Vec2 c2, Vec2 b, {int steps = 16}) => [
        for (var k = 0; k <= steps; k++)
          () {
            final t = k / steps;
            final u = 1 - t;
            return a * (u * u * u) +
                c1 * (3 * u * u * t) +
                c2 * (3 * u * t * t) +
                b * (t * t * t);
          }(),
      ];

  /// Cut a polyline at the given arc positions (sorted, interior). Each
  /// piece comes back with the arc length it starts at on the original.
  static List<(List<Vec2>, double)> _splitAt(
      List<Vec2> pts, List<double> cum, List<double> cuts) {
    if (cuts.isEmpty) return [(pts, 0.0)];
    final out = <(List<Vec2>, double)>[];
    var piece = <Vec2>[pts.first];
    var pieceStart = 0.0;
    var next = 0;
    for (var i = 1; i < pts.length; i++) {
      while (next < cuts.length && cuts[next] <= cum[i] && cuts[next] > cum[i - 1]) {
        final segLen = cum[i] - cum[i - 1];
        final t = segLen <= 1e-9 ? 0.0 : (cuts[next] - cum[i - 1]) / segLen;
        final cut = pts[i - 1] + (pts[i] - pts[i - 1]) * t;
        piece.add(cut);
        out.add((piece, pieceStart));
        piece = <Vec2>[cut];
        pieceStart = cuts[next];
        next++;
      }
      // A cut ON a vertex has already put that vertex at the head of the
      // new piece; adding it again would give the piece a zero-length
      // first segment.
      if (piece.length == 1 && piece.first.distanceTo(pts[i]) < 1e-9) continue;
      piece.add(pts[i]);
    }
    out.add((piece, pieceStart));
    return out;
  }
}

typedef _Cutter = void Function(double s, SprawlNodeLeg leg);
typedef _ClassAt = RoadClass Function(double s);

/// A road while the plan is being laid: its polyline, and every place
/// something meets it. [SprawlPlan] turns it into segments and nodes.
class _Draft {
  _Draft(this.id, this.kind, this.points, {RoadClass? roadClass})
      : cum = SprawlPlan._cumulative(points),
        _class = roadClass {
    for (final p in points) {
      if (p.e < minE) minE = p.e;
      if (p.e > maxE) maxE = p.e;
      if (p.n < minN) minN = p.n;
      if (p.n > maxN) maxN = p.n;
    }
  }

  final String id;
  final SprawlRoadKind kind;
  final List<Vec2> points;
  final List<double> cum;
  final RoadClass? _class;
  final List<(double, double)> overpasses = [];
  final List<_Cut> cuts = [];
  double minE = double.infinity, maxE = -double.infinity;
  double minN = double.infinity, maxN = -double.infinity;

  /// An interstate's shape, for its lane count: a radial — axial or
  /// diagonal — is six lanes to the outline and four past it; the beltway
  /// is eight throughout, the busiest road a metro has.
  bool radial = false;
  bool diagonal = false;
  bool beltway = false;
  double outS = double.infinity;

  /// A narrower start than the class's own: the first piece of a radial
  /// coming off the viaduct's deck.
  double? startHalfWidthM;

  /// A county highway's place on the survey grid: which axis it runs
  /// along, which line, and the span it covers.
  int axis = -1;
  int line = 0;
  double a = 0, b = 0;

  double get length => cum.last;

  RoadClass classAt(double s) {
    final fixed = _class;
    if (fixed != null) return fixed;
    if (kind != SprawlRoadKind.interstate) return kind.defaultClass;
    if (beltway) return RoadClass.expressway8;
    return s < outS ? RoadClass.expressway6 : RoadClass.expressway4;
  }

  Vec2 pointAt(double s) => SprawlPlan._pointAt(points, cum, s);

  Vec2 dirAt(double s) {
    final a = pointAt((s - 1).clamp(0.0, length));
    final b = pointAt((s + 1).clamp(0.0, length));
    return (b - a).normalized;
  }
}

/// A place along a draft where it is cut: a junction with [legs] beyond the
/// road's own two, or — with [node] false — a bare change of class.
class _Cut {
  const _Cut(this.s, {this.legs = const [], this.node = true});
  final double s;
  final List<SprawlNodeLeg> legs;
  final bool node;
}

class _NodeAcc {
  _NodeAcc(this.at);
  final Vec2 at;
  final List<SprawlNodeLeg> legs = [];
}

/// The network under construction.
class _Net {
  final List<_Draft> drafts = [];

  /// Nodes made outright, on roads the plan does not own — the plat's.
  final List<SprawlNode> extraNodes = [];

  _Draft add(_Draft d) {
    drafts.add(d);
    return d;
  }

  /// Split every draft at its cuts and gather the nodes where they meet.
  /// [wallsAt] says whether an expressway piece whose middle is there is
  /// built as the walled variant.
  (List<SprawlRoad>, List<SprawlNode>) build(bool Function(Vec2) wallsAt) {
    final roads = <SprawlRoad>[];
    final acc = <String, _NodeAcc>{};
    String keyOf(Vec2 p) => '${(p.e / 2).round()}:${(p.n / 2).round()}';
    void legsAt(Vec2 at, List<SprawlNodeLeg> legs) =>
        acc.putIfAbsent(keyOf(at), () => _NodeAcc(at)).legs.addAll(legs);

    for (final d in drafts) {
      final len = d.length;
      final sorted = [
        for (final c in d.cuts)
          if (c.s > -1e-6 && c.s < len + 1e-6) c
      ]..sort((a, b) => a.s.compareTo(b.s));
      // A crossing found twice is one junction, not two.
      final merged = <_Cut>[];
      for (final c in sorted) {
        if (merged.isNotEmpty && c.s - merged.last.s < 2.0) {
          final last = merged.removeLast();
          merged.add(_Cut(last.s,
              legs: [...last.legs, ...c.legs], node: last.node || c.node));
        } else {
          merged.add(c);
        }
      }
      for (final c in merged) {
        if (!c.node) continue;
        final at = d.pointAt(c.s);
        final t = d.dirAt(c.s);
        final cls = d.classAt(c.s);
        legsAt(at, [
          ...c.legs,
          if (c.s > 8) SprawlNodeLeg(t * -1.0, cls),
          if (c.s < len - 8) SprawlNodeLeg(t, cls),
        ]);
      }
      final splits = [
        for (final c in merged)
          if (c.s > 8 && c.s < len - 8) c.s
      ];
      final pieces = SprawlPlan._splitAt(d.points, d.cum, splits);
      final classes = <RoadClass>[];
      for (final (pts, s0) in pieces) {
        classes.add(d.classAt(s0 + SprawlPlan._cumulative(pts).last / 2));
      }
      for (var k = 0; k < pieces.length; k++) {
        final (pts, s0) = pieces[k];
        final pieceLen = SprawlPlan._cumulative(pts).last;
        final cls = classes[k];
        // Where the class changes, the WIDER piece tapers to the narrower
        // one's width at their shared end: a lane drop is a taper, not a
        // step. The first piece may start at the deck's width it comes off.
        double? hw0 = k == 0 ? d.startHalfWidthM : null;
        double? hw1;
        if (k > 0 && classes[k - 1].halfWidth < cls.halfWidth) {
          hw0 = classes[k - 1].halfWidth;
        }
        if (k + 1 < pieces.length && classes[k + 1].halfWidth < cls.halfWidth) {
          hw1 = classes[k + 1].halfWidth;
        }
        roads.add(SprawlRoad(
          id: pieces.length == 1 ? d.id : '${d.id}/$k',
          kind: d.kind,
          points: pts,
          roadClass: cls,
          // A bridge's range shifts with the piece but is never clipped to
          // it: the deck must not ramp down at a split.
          overpasses: [
            for (final (a, b) in d.overpasses)
              if (b > s0 && a < s0 + pieceLen) (a - s0, b - s0)
          ],
          startHalfWidthM: hw0,
          endHalfWidthM: hw1,
          soundWalls: cls.canHaveSoundWalls &&
              wallsAt(SprawlPlan._pointAt(pts, SprawlPlan._cumulative(pts), pieceLen / 2)),
        ));
      }
    }
    final nodes = <SprawlNode>[...extraNodes];
    for (final a in acc.values) {
      final control = junctionControlFor([for (final l in a.legs) l.roadClass]);
      if (control == JunctionControl.none) continue;
      nodes.add(SprawlNode(at: a.at, control: control, legs: a.legs));
    }
    return (roads, nodes);
  }
}

/// The east-west line through the core as one arc: the west radial
/// reversed, the corridor, the east radial. Maps a position on it back to
/// the draft that owns it — and to nothing on the deck itself, where a
/// merge is in the air and the plat draws the structure.
class _ThroughMap {
  const _ThroughMap(this.west, this.east, this.origin, this.corridorLen);
  final _Draft? west;
  final _Draft? east;
  final double origin;
  final double corridorLen;

  void cut(double s, SprawlNodeLeg leg) {
    final w = west, e = east;
    if (s < origin) {
      if (w != null) w.cuts.add(_Cut(origin - s, legs: [leg]));
    } else if (s > origin + corridorLen && e != null) {
      e.cuts.add(_Cut(s - origin - corridorLen, legs: [leg]));
    }
  }

  RoadClass classAt(double s) {
    final w = west, e = east;
    if (s < origin) return w?.classAt(origin - s) ?? RoadClass.elevated;
    if (s > origin + corridorLen) {
      return e?.classAt(s - origin - corridorLen) ?? RoadClass.elevated;
    }
    return RoadClass.elevated;
  }

  /// How high the line is at [s]: the deck's height on the corridor, and
  /// the radials' own descent off it either side.
  double liftAt(double s) {
    final w = west, e = east;
    if (s < origin) {
      return w == null ? 0 : SprawlPlan.bridgeLiftAt(origin - s, w.overpasses);
    }
    if (s > origin + corridorLen) {
      return e == null
          ? 0
          : SprawlPlan.bridgeLiftAt(s - origin - corridorLen, e.overpasses);
    }
    return SprawlPlan.bridgeHeightM;
  }
}

/// A place on a polyline, with the means to step along it: [at] gives the
/// point [d] metres further along (or back), on the line however it bends.
class _Along {
  _Along(this.pts, this.cum, this.s) : dir = _dirAt(pts, cum, s);

  final List<Vec2> pts;
  final List<double> cum;
  final double s;
  final Vec2 dir;

  static Vec2 _dirAt(List<Vec2> pts, List<double> cum, double s) {
    final a = SprawlPlan._pointAt(pts, cum, s - 1);
    final b = SprawlPlan._pointAt(pts, cum, s + 1);
    return (b - a).normalized;
  }

  Vec2 at(double d) =>
      SprawlPlan._pointAt(pts, cum, (s + d).clamp(0.0, cum.last));

  /// The line's own direction [d] metres along from here — where its
  /// bends have taken it, not where a straight line would be.
  Vec2 dirAt(double d) => _dirAt(pts, cum, (s + d).clamp(1.0, cum.last - 1));
}
