// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The sprawl's ZONING: everything past the platted core, out to the county
/// line, as mile-square sections each with a use and a density.
///
/// A real city the size of Chicago is twenty miles across, and almost all of
/// it is not the downtown the plat draws first — it is mile-square sections
/// of subdivisions, strip malls along the arterials, industrial parks by the
/// railway, forest preserves, and farmland at the edge. This decides which
/// section is which, from the seed and the shape of the metro: an organic
/// outline lobed along the interstates, farms past its edge, industry on
/// the railway's side, commerce at the interchanges.
///
/// It decides nothing else. The roads — county highways on the section
/// grid, the interstates and their interchanges, the railway carried on —
/// and the sections' own streets, lots and buildings are all PLAT, laid by
/// the generator through the same editor paths as the downtown. What was a
/// plan the renderer grew from is now a zoning the plat is cut to.
library;

import 'dart:math' as math;

import 'parcel.dart';

/// One mile, metres.
const double kMileM = 1609.344;

/// What the sprawl is shaped by: the seed, how far it runs, where the
/// core's edge is, and what the plat laid that the sprawl must meet.
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
    this.interchanges = const [],
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
  /// county grid as a trunk road.
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

  /// Ground the highways and the suburbs keep off: the plots the plat has
  /// staked for its installations and the railway's ends, each a flat
  /// polygon of colony-local e, n pairs. Rectangles, in practice — the plat
  /// stakes rectangles — and tested as their bounding boxes.
  final List<List<double>> clearings;

  /// Where the interchanges are, each an `[e, n]` pair, once the roads are
  /// laid: commerce zones around them. Set by the generator after it lays
  /// the interstates, the way [clearings] is set after it stakes the plots.
  final List<List<double>> interchanges;

  SprawlSpec copyWith({
    bool? expressway,
    List<double>? coreAvenuesE,
    List<double>? coreAvenuesN,
    List<List<double>>? clearings,
    bool? arteries,
    List<List<double>>? frontageRoads,
    List<List<double>>? interchanges,
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
        interchanges: interchanges ?? this.interchanges,
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
  /// plat out to [railInnerReachM] each way. Past that the generator
  /// carries it on into the country. Zero lays none.
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
  /// downtown street instead of standing off a nominal circle.
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
        if (interchanges.isNotEmpty) 'ix': interchanges,
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
        interchanges: [
          for (final f in (j['ix'] as List?) ?? const [])
            [for (final v in f as List) (v as num).toDouble()]
        ],
      );

  static bool _sameList(List<double> a, List<double> b) =>
      a.length == b.length &&
      Iterable.generate(a.length).every((i) => a[i] == b[i]);

  static bool _sameLists(List<List<double>> a, List<List<double>> b) =>
      a.length == b.length &&
      Iterable.generate(a.length).every((i) => _sameList(a[i], b[i]));

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
      _sameLists(other.frontageRoads, frontageRoads) &&
      _sameList(other.coreRadii, coreRadii) &&
      _sameList(other.coreAvenuesE, coreAvenuesE) &&
      _sameList(other.coreAvenuesN, coreAvenuesN) &&
      _sameLists(other.clearings, clearings) &&
      _sameLists(other.interchanges, interchanges);

  @override
  int get hashCode => Object.hash(seed, radiusM, coreRadiusM, sectionM,
      interstates, diagonals, beltway, railBearing, axisOffsetE, axisOffsetN,
      railOffsetN, railInnerReachM, expressway, arteries,
      Object.hashAll([gridOriginE, gridOriginN, gridStepE, gridStepN]),
      Object.hashAll(coreRadii),
      Object.hashAll(coreAvenuesE), Object.hashAll(coreAvenuesN),
      Object.hashAll([for (final c in clearings) Object.hashAll(c)]),
      Object.hashAll([for (final c in interchanges) Object.hashAll(c)]));
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
  /// the zoning picks the grid line nearest each quarter point.
  List<double> get collectorOffsetsE =>
      _collectorOffsetsE ?? collectorOffsetsFor(use, sizeM);
  List<double> get collectorOffsetsN =>
      _collectorOffsetsN ?? collectorOffsetsFor(use, sizeM);

  /// Which of the [streetsAcross] streets (1-based, one per grid line) are
  /// the collectors.
  static Set<int> collectorIndices(int streetsAcross) =>
      streetsAcross == 0 ? const {} : {streetsAcross ~/ 4, streetsAcross - streetsAcross ~/ 4};
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

/// The zoning: the outline and the sections, deterministic in the spec.
class SprawlPlan {
  const SprawlPlan({
    required this.spec,
    required this.outline,
    required this.sections,
  });

  final SprawlSpec spec;
  final SprawlOutline outline;
  final List<SprawlSection> sections;

  /// Section grid index range: -[n]..[n] either way, for the outline's
  /// furthest reach.
  static int gridReach(SprawlSpec s) =>
      (s.radiusM * 1.5 / s.sectionM).ceil() + 3;

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

  /// The outline [spec] draws: lobed along the radial interstates and the
  /// diagonals, its noise from the seed.
  static SprawlOutline outlineOf(SprawlSpec spec) {
    final rnd = math.Random(spec.seed * 7919 + 13);
    return SprawlOutline.of(
      spec.radiusM,
      [
        for (var a = 0; a < math.min(4, spec.interstates); a++) a * math.pi / 2,
        for (var a = 0; a < math.min(4, spec.diagonals); a++)
          math.pi / 4 + a * math.pi / 2,
      ],
      rnd,
    );
  }

  static SprawlPlan generate(SprawlSpec spec) {
    final n = gridReach(spec);
    final sectionM = spec.sectionM;
    final outline = outlineOf(spec);
    final interchanges = [
      for (final x in spec.interchanges)
        if (x.length >= 2) Vec2(x[0], x[1]),
    ];

    // ---- The sections ---------------------------------------------------
    //
    // Use by radius with noise, and by what is nearby: industry along the
    // railway side, commerce at the interchanges, forest preserves
    // scattered, farms past the built edge.
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
        // Every section that reaches past the plat is zoned, the four round
        // downtown included: the plat keeps their streets off itself, and
        // the rest of each comes right up to the last downtown street.
        if (r + sectionM * 0.7 < spec.coreRadiusAt(math.atan2(c.n, c.e))) {
          continue;
        }
        final bearing = math.atan2(c.n, c.e);
        final railSide = _angleBetween(bearing, spec.railBearing) < 0.55;
        final nearInterchange = interchanges.any((x) => x.distanceTo(c) < sectionM * 0.9);
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

    return SprawlPlan(spec: spec, outline: outline, sections: sections);
  }

  static double _angleBetween(double a, double b) {
    final d = (a - b) % (2 * math.pi);
    return d > math.pi ? 2 * math.pi - d : d;
  }
}
