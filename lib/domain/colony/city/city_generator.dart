// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Grow a whole colony from a seed.
///
/// Hand-drawing a city to test one is the reason look-and-feel changes were
/// being judged on four buildings and a straight road: laying out something
/// big enough to be representative takes longer than the change being judged.
/// This lays out a plausible one in a call — arterials, streets that bend,
/// subdivided blocks, zoning that varies by distance from the centre, and the
/// sprawling installations pushed out to the edge where they belong.
///
/// The output is a REAL [CitySim]: its roads are committed through the same
/// editor path a player uses, so they split at their junctions; its lots come
/// from the same subdivider; its buildings are placed through the same
/// mutators. That is what makes it worth profiling — a generated city
/// exercises the systems the played one does, rather than a lookalike.
///
/// Deterministic in [CityGenSpec.seed]: the same spec builds the same city,
/// which is what lets a performance number mean anything between two runs.
library;

import 'dart:math' as math;

import '../../shared/vector3.dart';
import '../../universe/celestial_body.dart';
import 'city_building_spec.dart';
import 'city_config.dart';
import 'city_sim.dart';
import 'parcel.dart';
import 'sprawl_plan.dart';

/// What to build.
class CityGenSpec {
  const CityGenSpec({
    this.seed = 1,
    this.bodyId = 'earth',
    this.blocksAcross = 4,
    this.blockM = 220,
    this.blockDepthM = 104,
    this.frontageM = 30,
    this.lotDepthM = 46,
    this.bendM = 34,
    this.buildFraction = 0.85,
    this.industryRing = 0.62,
    this.installations = 4,
    this.megatowers = 1,
    this.alleys = true,
    this.transitLines = 1,
    this.elevatedHighways = 1,
    this.taper = 1.0,
    this.outreachM = 4000,
    this.farms = 8,
    this.railway = true,
    this.sprawlMiles = 20,
    this.latitude,
    this.longitude,
  });

  final int seed;
  final String bodyId;

  /// Streets each way. The road count grows as the square of this, and so does
  /// almost everything downstream — it is the performance dial.
  final int blocksAcross;

  /// Long dimension of a block: spacing between the CROSS streets, metres.
  final double blockM;

  /// Short dimension: spacing between the streets that lots front onto.
  ///
  /// A block is a rectangle, and it matters which way round. Chicago's are
  /// about 200 m by 100 m — two rows of ~38 m lots back to back with a 5 m
  /// alley between them, plus the streets. Laid out square at 220 m both ways
  /// (which is what this generator did) every block had seventy metres of dead
  /// ground down its spine that no lot could reach and nothing was ever built
  /// on, and the alley cut through the middle of it served nobody.
  final double blockDepthM;

  /// Lot frontage along the street.
  ///
  /// 30 m is deliberately BIG against a real single lot (Chicago plats 7.6 m
  /// residential): a generated parcel is the merged assemblage a real tall
  /// building sits on, and the tower fraction is taken off this number. At
  /// 24 m every high-density shaft came out 12-16 m across — pencil towers,
  /// forty storeys on a footprint the size of a house.
  final double frontageM;

  /// Maximum lot depth. Wants to be a little more than half the block's short
  /// dimension so lots run all the way back to the alley and stop THERE,
  /// rather than stopping short and leaving a gap behind every building.
  final double lotDepthM;

  /// How far a street wanders off true. Zero is a grid; a real colony's
  /// streets bend, and bends are what exercise the tapered-lot paths.
  final double bendM;

  /// Share of subdivided lots that get a building.
  final double buildFraction;

  /// Fraction of the city radius beyond which lots zone industrial rather than
  /// residential/commercial.
  final double industryRing;

  /// Sprawling installations (solar farms, quarries, ports) placed outside the
  /// street network.
  final int installations;

  /// Megatowers staked over whole block interiors near the centre — the
  /// buildings allowed past the ordinary height ceiling.
  final int megatowers;

  /// Cut a service alley down the middle of every block.
  ///
  /// This is a LAYOUT change, not decoration. With an alley the lots on both
  /// sides of a block run back to it and every one of them has a back door, so
  /// the street frontage can be continuous. Without one, the lots meet at the
  /// block midline and every service entrance has to come off the street.
  final bool alleys;

  /// Elevated rail lines through the middle of the colony.
  final int transitLines;

  /// Elevated highways skirting it.
  final int elevatedHighways;

  /// How far the built-up outline departs from the block grid's rectangle,
  /// 0..1. At 0 the streets run to every corner of the grid; at 1 they stop
  /// at a rounded, ragged edge (see [CityShape]) and the corners of the grid
  /// are never laid — the town tapers into its outskirts instead of ending
  /// at a wall.
  final double taper;

  /// How far (m) the trunk roads and the railway run on past the last
  /// street. Zero lays none.
  final double outreachM;

  /// Farmsteads scattered along the trunk roads out of town.
  final int farms;

  /// A mainline railway past one side of the colony — a station at the
  /// town's edge, a freight yard by the works, and the line on out of town
  /// both ways.
  final bool railway;

  /// How far across, in miles, the SPRAWL runs: the mile-square sections of
  /// subdivisions, strips, industrial parks and farms past the platted core,
  /// with their county highways and interstates. Zero lays none. Twenty is
  /// a city the size of Chicago; the plat itself stays [blocksAcross] wide.
  final double sprawlMiles;

  /// Where to site it. Null asks the generator to FIND somewhere — which on a
  /// world with oceans means finding dry land, because 0N 0E on Earth is the
  /// Gulf of Guinea and a city built there is a city underwater.
  final double? latitude, longitude;

  double get extentM => blocksAcross * blockM;

  /// Extent across the short axis. Blocks are rectangles, so the city is one
  /// too unless the counts are traded off — which they are, here, to keep it
  /// roughly square on the ground.
  double get depthExtentM => blocksDeep * blockDepthM;

  /// Rows of blocks the short way. Chosen so the colony comes out about as
  /// wide as it is deep whatever the block proportions are.
  int get blocksDeep =>
      math.max(1, (extentM / math.max(1.0, blockDepthM)).round());
}

/// Where a build has got to: a phase name for the label, and 0..1 for the bar.
typedef CityGenProgress = ({String phase, double fraction});

/// The colony's outline: how far the streets run from the centre, per bearing.
///
/// A block grid is a rectangle, and a rectangle of streets built out to its
/// last corner reads as a subdivision on a drawing board, not as a town that
/// grew. Real ones stop raggedly: the grid frays into suburbs, the suburbs
/// into fields. This is that edge — a rounded outline with a little noise on
/// it, blended with the grid's own rectangle by [CityGenSpec.taper] so the
/// old square is still available at 0.
///
/// Everything that needs to know where town ends asks this: the street layer
/// trims each grid line to it, the zoning measures its bands against it (so
/// the last band is the last street on EVERY bearing, not just on the axes),
/// the installations and the railway keep clear of it, and the farms start
/// past it.
class CityShape {
  const CityShape({
    required this.halfW,
    required this.halfD,
    required this.taper,
    required this.phases,
    required this.railBearing,
  });

  /// From the spec, drawing the noise phases and the railway's side off
  /// [rnd] so both are part of what the seed decides.
  factory CityShape.of(CityGenSpec spec, math.Random rnd) {
    final phases = [for (var i = 0; i < 3; i++) rnd.nextDouble() * math.pi * 2];
    // North or south, never east or west: a station and a yard are
    // axis-aligned plots whose long side has to run along the line, and the
    // line runs east-west so that it does.
    final rail = rnd.nextBool() ? math.pi / 2 : -math.pi / 2;
    return CityShape(
      halfW: spec.extentM / 2,
      halfD: spec.depthExtentM / 2,
      taper: spec.taper.clamp(0.0, 1.0),
      phases: phases,
      railBearing: rail,
    );
  }

  /// The grid's half extents.
  final double halfW, halfD;

  /// How far toward the rounded outline the edge sits, 0..1.
  final double taper;

  /// Phases of the three harmonics that roughen the outline.
  final List<double> phases;

  /// Which side of town the railway passes: +pi/2 north, -pi/2 south.
  final double railBearing;

  /// The rounded outline's nominal radius: a little past the grid's short
  /// half-extent, so the long axis keeps most of its blocks and the corners
  /// go.
  double get round => math.min(halfW, halfD) * 1.06;

  /// How far the streets reach on [bearing].
  double radiusAt(double bearing) {
    final square = CityGenerator._slabExit(
        Vec2(math.cos(bearing), math.sin(bearing)), halfW, halfD);
    if (taper <= 0) return square;
    final ragged = round *
        (1 +
            0.10 * math.sin(2 * bearing + phases[0]) +
            0.06 * math.sin(3 * bearing + phases[1]) +
            0.045 * math.sin(5 * bearing + phases[2]));
    return square + (ragged - square) * taper;
  }

  /// Where [p] sits against the outline on its own bearing: 0 at the centre,
  /// 1 at the last street, more beyond.
  double fractionOf(Vec2 p) {
    final r = p.length;
    if (r < 1e-9) return 0;
    return r / radiusAt(math.atan2(p.n, p.e));
  }

  /// Whether [p] is inside the outline (scaled by [scale]).
  bool contains(Vec2 p, {double scale = 1.0}) =>
      fractionOf(p) <= scale + 1e-9;

  /// The farthest any street reaches TOWARD [bearing]: the outline's extent
  /// projected onto that axis over a wedge either side of it, so a line laid
  /// past it clears every street.
  double reachToward(double bearing, {double halfAngle = 1.25}) {
    var best = 0.0;
    for (var i = -16; i <= 16; i++) {
      final b = bearing + halfAngle * i / 16;
      final r = radiusAt(b) * math.cos(b - bearing);
      if (r > best) best = r;
    }
    return best;
  }
}

/// One run of the generator, steppable.
///
/// A colony takes seconds to build and every bit of it runs on the main
/// isolate, so the app is frozen for the duration and can neither paint a
/// progress bar nor answer a click. The studio covered that with an estimate,
/// which is the wrong shape of answer: it is a guess about a thing that is
/// already happening.
///
/// So the build is a SEQUENCE. Drive it in a plain loop and it behaves exactly
/// as it always did; drive it from an async loop that yields to the event loop
/// every few steps and the UI paints between them. The work is identical
/// either way — there is one implementation, and [CityGenerator.generate] is
/// the blocking driver for it.
///
/// Not an isolate, deliberately: a CitySim reaches a whole celestial system
/// and its terrain fields, none of which is cheap to send, and the copy back
/// would cost more than the yields do.
class CityBuild {
  CityBuild(this.spec, {required this.bodies});

  final CityGenSpec spec;
  final List<CelestialBody> bodies;

  /// The finished colony. Null until the run completes.
  CitySim? city;

  /// The outline the streets were laid against. Set as the run starts.
  CityShape? shape;

  /// The colony while the run is still going: live, half-built, and exactly
  /// the object being mutated between steps. [city] stays null until the run
  /// completes — that contract holds — but a driver that wants to DRAW the
  /// build as it happens (the studio's slow mode) has to see the sim before
  /// then, and this is the peek it uses. Read it between steps only; never
  /// keep it as the result.
  CitySim? partial;

  /// The build, as steps. Weighted by MEASURED cost, not by step count: the
  /// two subdivision passes are about thirteen of the fourteen seconds a
  /// six-block colony takes, and a bar that gave each phase an equal share
  /// would sit at 20% for ten seconds and then finish instantly.
  Iterable<CityGenProgress> run() sync* {
    yield (phase: 'finding a site', fraction: 0.0);
    final rnd = math.Random(spec.seed);
    final site = spec.latitude != null && spec.longitude != null
        ? (lat: spec.latitude!, lon: spec.longitude!)
        : CityGenerator.dryLandNear(
            bodies.firstWhere((b) => b.id.value == spec.bodyId),
            seed: spec.seed,
          );
    final sim = CitySim.found(
      CityConfig(
        bodyId: spec.bodyId,
        gridSize: 20,
        latitude: site.lat,
        longitude: site.lon,
      ),
      bodies: bodies,
      id: 'studio-${spec.seed}',
      name: 'Studio ${spec.seed}',
    );
    partial = sim;
    // The generator is not a game: it must not stall on affordability.
    sim.stock['ore'] = 1e9;
    sim.funds = 1e9;
    sim.layout.settings = sim.layout.settings.copyWith(
      frontageM: spec.frontageM,
      depthM: spec.lotDepthM,
    );

    // The outline everything else is laid against. Drawn from the SAME
    // random sequence as the rest, so it is part of what the seed decides.
    final outline = shape = CityShape.of(spec, rnd);
    // And the sprawl past it, as a spec: the plan grows from this on demand.
    if (spec.sprawlMiles > 0) {
      sim.sprawlSpec = SprawlSpec(
        seed: spec.seed,
        radiusM: spec.sprawlMiles / 2 * kMileM,
        coreRadiusM: outline.round * 1.12,
        railBearing: outline.railBearing,
        axisOffsetE: CityGenerator._centralAvenue(
            spec.blocksAcross, -spec.extentM / 2, spec.blockM, 3),
        axisOffsetN: CityGenerator._centralAvenue(
            spec.blocksDeep, -spec.depthExtentM / 2, spec.blockDepthM, 4),
        // The plat's real edge, so the sprawl meets it street to street.
        coreRadii: [
          for (var i = 0; i < 48; i++)
            outline.radiusAt(i / 48 * 2 * math.pi),
        ],
        // The plat lays the railway this far; the plan carries it on.
        railOffsetN: spec.railway ? CityGenerator._railOffset(outline) : 0,
        railInnerReachM: spec.railway ? CityGenerator.railInnerReachM : 0,
        // The plat carries the east-west interstate through the core on an
        // elevated expressway, and its avenues are where the core's
        // interchanges go.
        expressway: true,
        coreAvenuesE: [
          for (var i = 0; i <= spec.blocksAcross; i++)
            if (i % 3 == 0) -spec.extentM / 2 + i * spec.blockM,
        ],
        coreAvenuesN: [
          for (var i = 0; i <= spec.blocksDeep; i++)
            if (i % 4 == 0) -spec.depthExtentM / 2 + i * spec.blockDepthM,
        ],
        // The arteries meet the county grid at junctions the plan owns.
        arteries: spec.outreachM > 0,
        // The plat's grid, for the inner suburbs to carry on; the frontage
        // roads, for the slip ramps where the deck comes down.
        gridOriginE: -spec.extentM / 2,
        gridOriginN: -spec.depthExtentM / 2,
        gridStepE: spec.blockM,
        gridStepN: spec.blockDepthM,
        frontageRoads: CityGenerator._frontageRoads(spec, outline),
      );
    }

    yield (phase: 'laying streets', fraction: 0.02);
    const CityGenerator()._layRoads(sim, spec, outline, rnd);

    // One re-cut, for the whole network.
    for (final f in sim.layout.regenerateSteps()) {
      yield (phase: 'platting lots', fraction: 0.04 + f * 0.44);
    }

    // Installations BEFORE the streets are built out — see
    // [CityGenerator.generate] for why.
    yield (phase: 'staking installations', fraction: 0.48);
    // The railway's ends first: they have one place to be, and a random
    // plot staked there would leave the line without them.
    const CityGenerator()._placeStations(sim, spec, outline, rnd);
    const CityGenerator()._placeInstallations(sim, spec, outline, rnd);
    const CityGenerator()._placeMegatowers(sim, spec, rnd);
    const CityGenerator()._placeFarms(sim, spec, outline, rnd);
    // The plan and the suburbs keep off every staked plot: the plan's
    // highways break at them and the sections leave them empty.
    if (sim.sprawlSpec != null) {
      sim.sprawlSpec = sim.sprawlSpec!.copyWith(clearings: [
        for (final id in sim.parcelBuildings.keys)
          if (sim.parcelById(id) case final p? when p.manual)
            [for (final v in p.polygon) ...[v.e, v.n]],
      ]);
    }

    for (final f in sim.layout.regenerateSteps()) {
      yield (phase: 're-platting round the plots', fraction: 0.5 + f * 0.44);
    }

    // Stepped per lot rather than one opaque call: this loop is seconds of
    // work on a big colony, and run between two yields it read as a freeze —
    // the label painted "zoning and building" and then nothing moved until
    // "settling". Per-lot steps are also what let a driver draw the buildings
    // arriving.
    yield (phase: 'zoning and building', fraction: 0.94);
    for (final f
        in const CityGenerator()._zoneAndBuildSteps(sim, spec, outline, rnd)) {
      yield (phase: 'zoning and building', fraction: 0.94 + f * 0.04);
    }

    yield (phase: 'settling', fraction: 0.99);
    sim.recompute();
    // One step, so the colony hands back COHERENT: power, jobs, housing and
    // services are aggregated in `advance`, not in `recompute`, so a city that
    // has never ticked reports zero of everything and reads as dead.
    sim.advance(0.1);

    city = sim;
    yield (phase: 'done', fraction: 1.0);
  }
}

class CityGenerator {
  const CityGenerator();

  /// A land site on [body], searched deterministically from [seed].
  ///
  /// A colony has to stand on ground. The default site of 0N 0E is open ocean
  /// on Earth, so a generated city there was built on the sea floor and read
  /// as one — the studio showed a grid of houses on dark blue water.
  ///
  /// Worlds with no sea (the Moon, Mars) pass the test everywhere and take the
  /// first candidate, which costs one sample.
  static ({double lat, double lon}) dryLandNear(
    CelestialBody body, {
    int seed = 1,
    int tries = 400,
  }) {
    final field = body.terrainField;
    if (field == null) return (lat: 0, lon: 0);
    final sea = field.seaRadius;
    final rnd = math.Random(seed);
    var best = (lat: 0.0, lon: 0.0);
    var bestR = -double.infinity;
    for (var i = 0; i < tries; i++) {
      // Latitude by arcsine so samples spread evenly over the sphere rather
      // than bunching at the poles.
      final lat = math.asin(rnd.nextDouble() * 2 - 1) * 180 / math.pi;
      final lon = rnd.nextDouble() * 360 - 180;
      final la = lat * math.pi / 180, lo = lon * math.pi / 180;
      final d = Vector3(math.cos(la) * math.cos(lo), math.cos(la) * math.sin(lo),
          math.sin(la));
      final r = field.groundRadiusAt(d.x, d.y, d.z);
      // Comfortably above the waterline, not on the beach: a city needs room
      // to spread without half of it going under.
      if (r > sea + 40) return (lat: lat, lon: lon);
      if (r > bestR) {
        bestR = r;
        best = (lat: lat, lon: lon);
      }
    }
    // An ocean world: the highest ground found is the best that exists.
    return best;
  }

  /// Build the colony described by [spec], blocking until it is done.
  ///
  /// The synchronous driver for [CityBuild]. Anything that wants to show
  /// progress steps the build itself instead.
  CitySim generate(CityGenSpec spec, {required List<CelestialBody> bodies}) {
    final build = CityBuild(spec, bodies: bodies);
    for (final _ in build.run()) {}
    return build.city!;
  }

  /// Arterials one way, streets the other, every one of them bending, and
  /// every one of them stopping where the outline says town ends.
  ///
  /// The grid is RECTANGULAR. Axis 0 carries the close-spaced streets that
  /// lots front onto; axis 1 carries the widely spaced cross streets. That
  /// asymmetry is what a block IS — get it wrong and the alleys, the lot
  /// depths and the street wall all follow it wrong.
  ///
  /// Each line is laid only along the part of it inside [shape], so the
  /// grid's corners are never built and its edge follows the outline —
  /// which is the whole difference between a town and a plat.
  void _layRoads(
      CitySim city, CityGenSpec spec, CityShape shape, math.Random rnd) {
    final half = spec.extentM / 2;
    final halfDeep = spec.depthExtentM / 2;
    double jitter() => (rnd.nextDouble() * 2 - 1) * spec.bendM;
    // A stub shorter than most of a block is not a street.
    final minLen = spec.blockM * 0.6;

    // Axis 0: the frontage streets, running along x, spaced by blockDepthM.
    for (var i = 0; i <= spec.blocksDeep; i++) {
      final t = -halfDeep + i * spec.blockDepthM;
      final chord = _chord(shape, t, 0, half, minLen);
      if (chord == null) continue;
      // Every fourth is an arterial: a city with one road class reads as a
      // housing estate, and the junction furniture only differentiates when
      // classes differ.
      final cls = i % 4 == 0 ? RoadClass.avenue : RoadClass.street;
      final (a, b) = chord;
      final controls = <Vec2>[
        for (var k = 0; k <= 4; k++)
          Vec2(a + (b - a) * k / 4,
              t + (k == 0 || k == 4 ? 0 : jitter() * 0.5)),
      ];
      // Defer the lot re-cut: every commit would otherwise re-subdivide the
      // whole colony, which is quadratic in roads and was two thirds of the
      // time it took to build a city. Nothing is standing yet, so there is
      // nothing to carry across renames.
      city.commitRoad(controls, cls, regenerateLots: false);
    }

    // Axis 1: the cross streets, running along y, spaced by blockM.
    for (var i = 0; i <= spec.blocksAcross; i++) {
      final t = -half + i * spec.blockM;
      final chord = _chord(shape, t, 1, halfDeep, minLen);
      if (chord == null) continue;
      final cls = i % 3 == 0 ? RoadClass.avenue : RoadClass.street;
      final (a, b) = chord;
      final controls = <Vec2>[
        for (var k = 0; k <= 4; k++)
          Vec2(t + (k == 0 || k == 4 ? 0 : jitter()), a + (b - a) * k / 4),
      ];
      city.commitRoad(controls, cls, regenerateLots: false);
    }

    if (spec.alleys) _layAlleys(city, spec, shape, jitter);
    _layElevated(city, spec, rnd, jitter);
    if (spec.sprawlMiles <= 0) {
      _layOutreach(city, spec, shape, rnd, jitter);
    } else {
      // With sprawl, the interstate comes through the core on an elevated
      // expressway, and every avenue carries on out to the mile grid.
      _layExpressway(city, spec, shape);
      _layArteries(city, spec, shape);
    }
    _layRailway(city, spec, shape, rnd, jitter);
  }

  /// The east-west interstate through the core: an elevated expressway on
  /// the central avenue, from where the plan's west radial ends to where
  /// its east one begins, with a frontage road along the ground each side.
  ///
  /// The frontage roads are what clear the corridor: an elevated road plats
  /// no lots and blocks none either, so on its own the deck would fly over
  /// back gardens. Two streets thirty-four metres out take those lots with
  /// them and plat their own facing away from the deck, which is what a
  /// frontage road does; the ramps of the core's interchanges land on them.
  void _layExpressway(CitySim city, CityGenSpec spec, CityShape shape) {
    final half = spec.extentM / 2;
    final halfDeep = spec.depthExtentM / 2;
    final rowT = _centralAvenue(spec.blocksDeep, -halfDeep, spec.blockDepthM, 4);
    final chord = _chord(shape, rowT, 0, half * 1.5, 0);
    if (chord == null) return;
    final (a, b) = chord;
    city.commitRoad(
      [for (var k = 0; k <= 5; k++) Vec2(a + (b - a) * k / 5, rowT)],
      RoadClass.elevated,
      regenerateLots: false,
    );
    for (final f in _frontageRoads(spec, shape)) {
      final t = f[0], fa = f[1], fb = f[2];
      city.commitRoad(
        [for (var k = 0; k <= 3; k++) Vec2(fa + (fb - fa) * k / 3, t)],
        RoadClass.street,
        regenerateLots: false,
      );
    }
  }

  /// The frontage roads either side of the expressway, each `[n, a, b]`:
  /// thirty-four metres off the central avenue, from thirty metres inside
  /// the outline's chord to thirty metres inside it at the other end. ONE
  /// definition: the sprawl spec carries the same list, so the plan's slip
  /// ramps start exactly where the plat's frontage roads end.
  static List<List<double>> _frontageRoads(CityGenSpec spec, CityShape shape) {
    final half = spec.extentM / 2;
    final halfDeep = spec.depthExtentM / 2;
    final rowT = _centralAvenue(spec.blocksDeep, -halfDeep, spec.blockDepthM, 4);
    final out = <List<double>>[];
    for (final side in const [-1.0, 1.0]) {
      final t = rowT + side * 34;
      final fc = _chord(shape, t, 0, half * 1.5, 0);
      if (fc == null) continue;
      final (fa, fb) = fc;
      if (fb - fa < 80) continue;
      out.add([t, fa + 30, fb - 30]);
    }
    return out;
  }

  /// Every avenue carried on past the last street to the next mile line of
  /// the county grid, as a trunk road — so the plat's arterials meet the
  /// sprawl's instead of ending at the outline with a highway a few hundred
  /// metres off. The central avenues are left out: the interstates are
  /// their continuation.
  void _layArteries(CitySim city, CityGenSpec spec, CityShape shape) {
    // Outreach of zero is "no roads past the streets", sprawl or not.
    if (spec.outreachM <= 0) return;
    final half = spec.extentM / 2;
    final halfDeep = spec.depthExtentM / 2;
    final rowT = _centralAvenue(spec.blocksDeep, -halfDeep, spec.blockDepthM, 4);
    final colT = _centralAvenue(spec.blocksAcross, -half, spec.blockM, 3);
    // The next mile line past [end] along [sign]. The county grid is laid
    // on multiples of a mile from the colony's ORIGIN — not from the central
    // avenue, which is where these once measured from and why every artery
    // ended a couple of hundred metres short of the highway it was meant to
    // reach. The artery ends exactly ON the line: that is the junction the
    // sprawl plan puts there, and an overshoot poked out the far side.
    double milesBeyond(double end, double sign) {
      final k = (end * sign / kMileM).ceil();
      var target = sign * k * kMileM;
      if ((target - end) * sign < 40) target += sign * kMileM;
      return target;
    }

    for (var i = 0; i <= spec.blocksDeep; i++) {
      if (i % 4 != 0) continue;
      final t = -halfDeep + i * spec.blockDepthM;
      if (t == rowT) continue;
      final chord = _chord(shape, t, 0, half, spec.blockM * 0.6);
      if (chord == null) continue;
      for (final sign in const [-1.0, 1.0]) {
        final end = sign > 0 ? chord.$2 : chord.$1;
        final target = milesBeyond(end, sign);
        city.commitRoad(
          [Vec2(end, t), Vec2((end + target) / 2, t), Vec2(target, t)],
          RoadClass.trunk,
          regenerateLots: false,
        );
      }
    }
    for (var i = 0; i <= spec.blocksAcross; i++) {
      if (i % 3 != 0) continue;
      final t = -half + i * spec.blockM;
      if (t == colT) continue;
      final chord = _chord(shape, t, 1, halfDeep, spec.blockM * 0.6);
      if (chord == null) continue;
      for (final sign in const [-1.0, 1.0]) {
        final end = sign > 0 ? chord.$2 : chord.$1;
        final target = milesBeyond(end, sign);
        city.commitRoad(
          [Vec2(t, end), Vec2(t, (end + target) / 2), Vec2(t, target)],
          RoadClass.trunk,
          regenerateLots: false,
        );
      }
    }
  }

  /// Where a straight line at [offset] across [axis] (0: along east, 1:
  /// along north) enters and leaves the outline, or null when its middle
  /// runs clear of it or the piece inside is shorter than [minLen].
  ///
  /// Walked outward from the centre in short steps rather than solved: the
  /// outline is a sum of harmonics with no closed-form chord, and a few
  /// hundred containment tests per road is nothing against the plat.
  static (double, double)? _chord(
    CityShape shape,
    double offset,
    int axis,
    double halfLen,
    double minLen, {
    double scale = 1.0,
  }) {
    Vec2 at(double s) => axis == 0 ? Vec2(s, offset) : Vec2(offset, s);
    if (!shape.contains(at(0), scale: scale)) return null;
    double reach(double sign) {
      var s = 0.0;
      while (s < halfLen) {
        final n = math.min(halfLen, s + 8);
        if (!shape.contains(at(sign * n), scale: scale)) break;
        s = n;
      }
      return s;
    }

    final a = -reach(-1), b = reach(1);
    if (b - a < minLen) return null;
    return (a, b);
  }

  /// A service road down the middle of every block, parallel to the streets
  /// that front it — in the TOWN, not the suburbs.
  ///
  /// One axis only, which is what a real plat does: a block is a long
  /// rectangle, the lots front its two LONG sides, and the alley runs down its
  /// spine between their back fences. Cutting alleys both ways would leave
  /// nothing but corner lots.
  ///
  /// Alleys stop at three quarters of the outline. Past that the lots are
  /// houses on their own plots, and a house with a service lane behind it is
  /// a terrace, which is the wrong picture for the edge of town.
  void _layAlleys(CitySim city, CityGenSpec spec, CityShape shape,
      double Function() jitter) {
    final half = spec.extentM / 2;
    final halfDeep = spec.depthExtentM / 2;
    for (var i = 0; i < spec.blocksDeep; i++) {
      final t = -halfDeep + (i + 0.5) * spec.blockDepthM;
      final chord =
          _chord(shape, t, 0, half, spec.blockM * 0.6, scale: alleyReach);
      if (chord == null) continue;
      final (a, b) = chord;
      final controls = <Vec2>[
        for (var k = 0; k <= 4; k++)
          // Half the street's wander: an alley is surveyed off the block it
          // splits, so it follows the streets rather than doing its own thing.
          Vec2(a + (b - a) * k / 4,
              t + (k == 0 || k == 4 ? 0 : jitter() * 0.25)),
      ];
      city.commitRoad(controls, RoadClass.alley, regenerateLots: false);
    }
  }

  /// How far out, as a fraction of the outline, blocks still get alleys.
  static const double alleyReach = 0.74;

  /// The lines in the air: rail over the middle, highway round the edge.
  ///
  /// The rail deliberately runs ALONG the grain of the grid and near the
  /// centre, because that is where it is worth having and because a structure
  /// over the densest street is the whole point of an elevated railway. The
  /// highway is pushed to the outside, where a real one is.
  void _layElevated(
      CitySim city, CityGenSpec spec, math.Random rnd, double Function() jitter) {
    final half = spec.extentM / 2;
    const steps = 5;

    for (var line = 0; line < spec.transitLines; line++) {
      // On a street centreline, so the trestle's columns land in the
      // carriageway rather than inside the buildings — and two blocks off
      // the central avenue when the expressway runs along that one, or the
      // L and the viaduct would stand on the same street.
      final t = (line - (spec.transitLines - 1) / 2) * spec.blockDepthM * 3 +
          (spec.sprawlMiles > 0 ? spec.blockDepthM * 2 : 0);
      final controls = <Vec2>[
        for (var k = 0; k <= steps; k++)
          Vec2(-half * 1.1 + spec.extentM * 1.1 * k / steps,
              t + (k == 0 || k == steps ? 0 : jitter() * 0.4)),
      ];
      city.commitRoad(controls, RoadClass.transit, regenerateLots: false);
    }

    // With sprawl the interstate itself comes through the core on the
    // expressway; the edge highways were what stopped at the city line.
    if (spec.sprawlMiles > 0) return;
    for (var i = 0; i < spec.elevatedHighways; i++) {
      final side = i.isEven ? 1.0 : -1.0;
      final t = side * (half * (0.82 + rnd.nextDouble() * 0.1));
      final controls = <Vec2>[
        for (var k = 0; k <= steps; k++)
          Vec2(t + (k == 0 || k == steps ? 0 : jitter() * 0.6),
              -spec.depthExtentM * 0.575 +
                  spec.depthExtentM * 1.15 * k / steps),
      ];
      city.commitRoad(controls, RoadClass.elevated, regenerateLots: false);
    }
  }

  /// The avenue nearest the centre on one axis: the arterial the trunk
  /// roads carry on from.
  static double _centralAvenue(
      int count, double start, double step, int every) {
    var best = double.infinity;
    for (var i = 0; i <= count; i++) {
      if (i % every != 0) continue;
      final t = start + i * step;
      if (t.abs() < best.abs()) best = t;
    }
    return best;
  }

  /// The trunk roads out of town: the central avenue on each axis, carried
  /// on past the last street for [CityGenSpec.outreachM] in both directions.
  ///
  /// [RoadClass.trunk] plats no lots — a road that did once turned a colony
  /// into 8,736 lots and a six-minute build — so the country these run
  /// through stays country, and the farms along them claim their own plots.
  /// The wander grows with distance: near town the road is surveyed off the
  /// grid, out in the fields it bends with the land.
  void _layOutreach(CitySim city, CityGenSpec spec, CityShape shape,
      math.Random rnd, double Function() jitter) {
    if (spec.outreachM <= 0) return;
    final half = spec.extentM / 2;
    final halfDeep = spec.depthExtentM / 2;
    final rowT = _centralAvenue(spec.blocksDeep, -halfDeep, spec.blockDepthM, 4);
    final colT = _centralAvenue(spec.blocksAcross, -half, spec.blockM, 3);
    const steps = 6;
    for (final (axis, offset, halfLen) in [(0, rowT, half), (1, colT, halfDeep)]) {
      final chord = _chord(shape, offset, axis, halfLen, 0);
      if (chord == null) continue;
      for (final sign in const [1.0, -1.0]) {
        // Starts exactly on the avenue's own end, which is what lets the
        // commit snap the two into one junction.
        final start = sign > 0 ? chord.$2 : chord.$1;
        final controls = <Vec2>[];
        for (var k = 0; k <= steps; k++) {
          final d = start + sign * spec.outreachM * k / steps;
          final w = k == 0 ? 0.0 : jitter() * (1.0 + k * 0.7);
          controls.add(axis == 0 ? Vec2(d, offset + w) : Vec2(offset + w, d));
        }
        city.commitRoad(controls, RoadClass.trunk, regenerateLots: false);
      }
    }
  }

  /// Clear ground between the last street and the railway, metres: room
  /// for the station and the yard between the two, and a corridor a
  /// mainline would keep anyway.
  static const double railClearM = 170;

  /// How far each way from the centre the PLAT lays the railway when there
  /// is sprawl to carry it on: through the core and the near suburbs.
  static const double railInnerReachM = 6000;

  /// Where the mainline runs: its offset from the centre across the
  /// outline's [CityShape.railBearing] side.
  static double _railOffset(CityShape shape) =>
      math.sin(shape.railBearing).sign *
      (shape.reachToward(shape.railBearing) + railClearM);

  /// The mainline: east-west past one side of the colony, clear of every
  /// street, and on out of town both ways.
  ///
  /// Straight across the town's own span — the station and the yard are
  /// axis-aligned plots laid against its nominal line, and a line that
  /// wandered there would put a platform on the track — and bending gently
  /// once it is out in the country.
  void _layRailway(CitySim city, CityGenSpec spec, CityShape shape,
      math.Random rnd, double Function() jitter) {
    if (!spec.railway) return;
    final y = _railOffset(shape);
    // Without sprawl, well past the farms; with it, only to the near
    // suburbs — the sprawl plan carries the line on from there, and lays it
    // for nothing where the plat's editor path would sample every metre.
    final reach = spec.sprawlMiles > 0
        ? railInnerReachM
        : spec.extentM / 2 + math.max(spec.outreachM, 1500.0);
    const steps = 10;
    final straight = shape.halfW * 1.35;
    final controls = <Vec2>[
      for (var k = 0; k <= steps; k++)
        () {
          final x = -reach + 2 * reach * k / steps;
          final w = x.abs() > straight && k != 0 && k != steps
              ? jitter() * 0.6
              : 0.0;
          return Vec2(x, y + w);
        }(),
    ];
    city.commitRoad(controls, RoadClass.rail, regenerateLots: false);
  }

  /// Zone what the roads cut, then build most of it — one lot per step.
  ///
  /// Yields progress 0..1 after EVERY lot, taken or skipped.
  ///
  /// Bands are measured against the OUTLINE, not the grid's half-extent: a
  /// lot's band is where it sits between the centre and the last street on
  /// its own bearing, so the outermost band is the edge of town whichever
  /// way you look. The outer band is the suburbs — houses, corner shops, a
  /// park — and the works cluster in a sector on the railway's side rather
  /// than ringing the whole town; a ring of industry round a city is what a
  /// rectangular generator produces, not what a town does.
  Iterable<double> _zoneAndBuildSteps(
      CitySim city, CityGenSpec spec, CityShape shape, math.Random rnd) sync* {
    // Where industry takes over on its sector, as a fraction of the
    // outline. `industryRing` is the knob; the default puts the works in the
    // last quarter of the town on the railway side.
    final industryFrom = (spec.industryRing * 1.25).clamp(0.5, 1.2);
    final park = kUtilCatalog.firstWhere((s) => s.type == 'park');

    // Snapshot: `setUse` swaps the auto list copy-on-write under the loop.
    final lots = List.of(city.layout.autoParcels);
    for (var i = 0; i < lots.length; i++) {
      final lot = lots[i];
      final c = lot.centroid;
      final bearing = math.atan2(c.n, c.e);
      // Jittered so each boundary is a ragged transition rather than a
      // visible ring.
      final t = shape.fractionOf(c).clamp(0.0, 1.6) +
          (rnd.nextDouble() - 0.5) * 0.14;
      // The outskirts thin out: past the last-but-one band the odds of a lot
      // being built fall away, so the edge of town is lots with nothing on
      // them yet rather than a wall of houses ending at a field.
      final fade = t < 0.78
          ? 1.0
          : (1.0 - (t - 0.78) / 0.22 * 0.65).clamp(0.35, 1.0);
      if (rnd.nextDouble() > spec.buildFraction * fade) {
        yield (i + 1) / lots.length;
        continue;
      }
      final inWorks = _angleBetween(bearing, shape.railBearing) < 0.75 &&
          t > industryFrom;

      final CityBuildingSpec pick;
      final ParcelUse use;
      // ONE ordering, centre outward: business district, then apartments,
      // then mid-rise, then houses — with the works on their own side.
      if (t < 0.34) {
        // THE HEART. Overwhelmingly commercial and all of it high density —
        // this is the band the skyline comes from.
        final commercial = rnd.nextDouble() < 0.74;
        pick = commercial
            ? kZoneSpecs['commercial']![Density.high]!
            : kZoneSpecs['residential']![Density.high]!;
        use = commercial ? ParcelUse.commercial : ParcelUse.residential;
      } else if (t < 0.60) {
        // Inner ring: apartments over shops, stepping DOWN out of the core.
        if (rnd.nextDouble() < 0.3) {
          pick = kZoneSpecs['commercial']![Density.medium]!;
          use = ParcelUse.commercial;
        } else {
          pick = kZoneSpecs['residential']![
              rnd.nextDouble() < 0.5 ? Density.high : Density.medium]!;
          use = ParcelUse.residential;
        }
      } else if (inWorks) {
        // The works: heavier the further out, by the line.
        final heavy = rnd.nextDouble() < (t > 1.0 ? 0.5 : 0.25);
        pick = kZoneSpecs['industrial']![
            heavy ? Density.high : (t > 0.9 ? Density.medium : Density.low)]!;
        use = ParcelUse.industrial;
      } else if (t < 0.80) {
        // The bulk of the city: mid-rise housing with corner shops, and the
        // first houses creeping in toward the suburbs.
        final roll = rnd.nextDouble();
        if (roll < 0.18) {
          pick = kZoneSpecs['commercial']![Density.low]!;
          use = ParcelUse.commercial;
        } else {
          final house = rnd.nextDouble() < (t - 0.6) / 0.2 * 0.45;
          pick = kZoneSpecs['residential']![
              house ? Density.low : Density.medium]!;
          use = ParcelUse.residential;
        }
      } else {
        // The suburbs: houses on their own plots, a corner shop, a park, and
        // the odd workshop.
        final roll = rnd.nextDouble();
        if (roll < 0.08) {
          pick = kZoneSpecs['commercial']![Density.low]!;
          use = ParcelUse.commercial;
        } else if (roll < 0.15) {
          pick = park;
          use = ParcelUse.civic;
        } else if (roll < 0.20) {
          pick = kZoneSpecs['industrial']![Density.low]!;
          use = ParcelUse.industrial;
        } else {
          pick = kZoneSpecs['residential']![Density.low]!;
          use = ParcelUse.residential;
        }
      }

      city.layout.setUse(lot.id, use);
      city.placeOnParcel(lot.id, pick);
      yield (i + 1) / lots.length;
    }
  }

  /// Unsigned angle between two bearings, radians, 0..pi.
  static double _angleBetween(double a, double b) {
    final d = (a - b) % (2 * math.pi);
    return d > math.pi ? 2 * math.pi - d : d;
  }

  /// Where a ray from a rectangle's centre leaves it, in the rectangle's own
  /// axes. The standard slab test — the near face on each axis, whichever
  /// comes first.
  static double _slabExit(Vec2 dir, double hw, double hd) {
    final tx = dir.e.abs() < 1e-9 ? double.infinity : hw / dir.e.abs();
    final ty = dir.n.abs() < 1e-9 ? double.infinity : hd / dir.n.abs();
    final t = math.min(tx, ty);
    return t.isFinite ? t : math.max(hw, hd);
  }

  /// The sprawling installations, pushed out past the streets.
  ///
  /// They claim their own plots, so they go where there is room for them —
  /// which is exactly the placement rule the editor enforces, run headless.
  void _placeInstallations(
      CitySim city, CityGenSpec spec, CityShape shape, math.Random rnd) {
    // One of each: every installation that stakes its own site, save the
    // railway's ends and the farms, which are placed by their own rules.
    // Biggest first, so the ones that need the most room find it while
    // there is still room to find; each tries bearings spread by the golden
    // angle from a random start until its plot is accepted.
    const placedElsewhere = {'station', 'freightyard', 'farm'};
    double area(CityBuildingSpec s) {
      final m = s.siteMetres();
      return m.width * m.depth;
    }
    final big = kUtilCatalog
        .where((s) => s.claimsOwnSite && !placedElsewhere.contains(s.type))
        .toList()
      ..sort((a, b) => area(b).compareTo(area(a)));
    if (big.isEmpty) return;
    // Just outside the city EDGE ON THIS BEARING — not outside its corner,
    // and not out in a ring of its own.
    //
    // Two bugs met here. A ring at 1.25 half-widths is outside the grid on the
    // axes and INSIDE it on the diagonals, so plots landed on live blocks and
    // staking one re-cuts everything under it: ten installations turned 1340
    // lots into 193. Pushing the ring out past the corner fixed that and broke
    // the other end — a site must be within `siteAccessReachM` of a curb, and
    // out past the corner nothing is, so eight of ten placements were refused.
    //
    // Running haul roads out to them was worse again: a spur is a road, roads
    // plat lots, and a colony came back with 8,736 lots and took six minutes.
    //
    // Measuring the city's own edge along the SAME bearing the plot sits on
    // solves both at once. The plot's near face lands a fixed margin past the
    // last street whichever way it went out, which is inside the access reach
    // and outside every block.
    var bearing = rnd.nextDouble() * math.pi * 2;
    const golden = 2.399963229728653;
    // With sprawl, a plot that finds no room against the town goes out in
    // rings through the suburbs — a quarry or a starport sits miles out —
    // and needs no curb of the plat's: the county grid is its road, and
    // the plan breaks that grid at its fence. Without sprawl there is only
    // the ring against the town, within reach of a street.
    final sprawl = spec.sprawlMiles > 0;
    final farthest = sprawl ? spec.sprawlMiles / 2 * kMileM * 0.7 : 0.0;
    final sprawlSpec = city.sprawlSpec;
    // A plot must not sit on an interstate: the plan cannot bend them, so
    // the plot keeps off the axial lines and the diagonals instead.
    bool onInterstate(Vec2 c, double hw, double hd) {
      if (sprawlSpec == null) return false;
      if ((c.n - sprawlSpec.axisOffsetN).abs() < hd + 40) return true;
      if ((c.e - sprawlSpec.axisOffsetE).abs() < hw + 40) return true;
      final reach = (hw + hd) / math.sqrt2 + 40;
      return (c.e - c.n).abs() / math.sqrt2 < reach ||
          (c.e + c.n).abs() / math.sqrt2 < reach;
    }
    for (final pick in big) {
      final site = pick.siteMetres();
      var placed = false;
      for (var ring = 0.0; ring <= farthest && !placed; ring += 700) {
        for (var attempt = 0; attempt < 16 && !placed; attempt++) {
          final a = bearing;
          bearing += golden;
          final dir = Vec2(math.cos(a), math.sin(a));
          // The OUTLINE's edge on this bearing, so a plot lands a fixed
          // margin past the last street however far out that street
          // reaches here — inside the access reach of a curb, outside
          // every block — or that far again out in the sections.
          final cityEdge = shape.radiusAt(a);
          final plotEdge = _slabExit(dir, site.width / 2, site.depth / 2);
          final at = dir * (cityEdge + plotEdge + 55 + ring);
          if (onInterstate(at, site.width / 2, site.depth / 2)) continue;
          // Deferred re-cut: each staked plot would otherwise re-subdivide
          // the whole colony. Nothing is built yet, so nothing can be
          // orphaned.
          placed = city.claimSite(pick, at,
                  regenerateLots: false, checkAccess: !sprawl || ring == 0) !=
              null;
        }
      }
    }
  }

  /// The railway's station and freight yard, on the town side of the line.
  ///
  /// The station sits a block along from the trunk road so the two never
  /// cross; the yard goes the other way, toward the works, and gets a
  /// siding of its own — a second track parallel to the main, the far side
  /// of it, so a freight train can stand clear of the line.
  void _placeStations(
      CitySim city, CityGenSpec spec, CityShape shape, math.Random rnd) {
    if (!spec.railway) return;
    final side = math.sin(shape.railBearing).sign;
    final nominalY = _railOffset(shape);
    final railHalf = RoadClass.rail.halfWidth;
    final colT = _centralAvenue(
        spec.blocksAcross, -spec.extentM / 2, spec.blockM, 3);
    final station = kUtilCatalog.firstWhere((s) => s.type == 'station');
    final yard = kUtilCatalog.firstWhere((s) => s.type == 'freightyard');
    final rails = [
      for (final r in city.layout.roads)
        if (r.roadClass == RoadClass.rail) ...r.sample(stepM: 12)
    ];
    if (rails.isEmpty) return;

    // Where the line actually runs at [x]: the spline bows a few metres off
    // its nominal offset even where its controls are straight, and a
    // platform laid against the nominal line had its corner on the track.
    double railYAt(double x) {
      Vec2? best;
      for (final p in rails) {
        if (best == null || (p.e - x).abs() < (best.e - x).abs()) best = p;
      }
      return best?.n ?? nominalY;
    }

    // Between the line and the town, its far edge a lane off the track, at
    // the track's own height across the site's span.
    Vec2 beside(CityBuildingSpec s, double x) {
      final w = s.siteMetres().width / 2;
      final railY = side > 0
          ? math.min(railYAt(x - w), railYAt(x + w))
          : math.max(railYAt(x - w), railYAt(x + w));
      return Vec2(x, railY - side * (railHalf + 16 + s.siteMetres().depth / 2));
    }

    final stationX = colT + math.max(spec.blockM, 220.0);
    for (var t = 0; t < 6; t++) {
      if (city.claimSite(station, beside(station, stationX + t * 40),
              regenerateLots: false) !=
          null) {
        break;
      }
    }
    final yardX = colT - (shape.halfW * 0.55 + 220);
    for (var t = 0; t < 6; t++) {
      final at = beside(yard, yardX - t * 60);
      if (city.claimSite(yard, at, regenerateLots: false) != null) {
        // The siding, the far side of the main from the yard.
        final sy = railYAt(at.e) + side * 14;
        city.commitRoad(
          [Vec2(at.e - 260, sy), Vec2(at.e, sy), Vec2(at.e + 260, sy)],
          RoadClass.rail,
          regenerateLots: false,
        );
        break;
      }
    }
  }

  /// Farmsteads along the trunk roads, past the outskirts.
  ///
  /// Each is a field with its near face a short lane off the road (inside
  /// the site-access reach, clear of the carriageway) and a house beside it
  /// at the road; one in five is a wind farm instead. Spaced so the country
  /// stays country between them.
  void _placeFarms(
      CitySim city, CityGenSpec spec, CityShape shape, math.Random rnd) {
    // The sprawl's farmland sections carry the farms instead.
    if (spec.farms <= 0 || spec.sprawlMiles > 0) return;
    final farm = kUtilCatalog.firstWhere((s) => s.type == 'farm');
    final wind = kUtilCatalog.firstWhere((s) => s.type == 'wind');
    final house = kZoneSpecs['residential']![Density.low]!;
    final trunks = city.layout.roads
        .where((r) => r.roadClass == RoadClass.trunk)
        .toList();
    if (trunks.isEmpty) return;
    final placed = <Vec2>[];
    var count = 0;
    for (var attempt = 0;
        attempt < spec.farms * 14 && count < spec.farms;
        attempt++) {
      final road = trunks[rnd.nextInt(trunks.length)];
      final pts = road.sample(stepM: 24);
      if (pts.length < 3) continue;
      final i = 1 + rnd.nextInt(pts.length - 2);
      final p = pts[i];
      // Past the outskirts: a farm beside the last street is a park.
      if (shape.fractionOf(p) < 1.35) continue;
      final along = (pts[i + 1] - pts[i - 1]).normalized;
      final normal = along.perp;
      final sideSign = rnd.nextBool() ? 1.0 : -1.0;
      final pick = rnd.nextDouble() < 0.2 ? wind : farm;
      final site = pick.siteMetres();
      final reach = math.max(site.width, site.depth) / 2;
      final centre = p + normal * (sideSign * (road.halfWidth + 30 + reach));
      if (placed.any((q) => q.distanceTo(centre) < reach * 2 + 160)) continue;
      if (city.claimSite(pick, centre, regenerateLots: false) == null) {
        continue;
      }
      placed.add(centre);
      count++;
      if (identical(pick, farm)) {
        final houseAt = p +
            along * (site.width / 2 + 40) +
            normal * (sideSign * (road.halfWidth + 26));
        city.claimSite(house, houseAt, regenerateLots: false);
      }
    }
  }

  /// Megatowers, staked over block interiors near the centre.
  ///
  /// Placed exactly as the installations are — a claimed own-site plot with
  /// the re-cut deferred — but INWARD: the candidate centres are the nominal
  /// grid's block interiors, tried centre-out.
  ///
  /// Every alleyed block refuses a block-filling site out of the box: the
  /// service alley runs down the block's spine, exactly where the plot's
  /// middle is. That is not an obstacle, it is the assemblage — a real
  /// megablock buys its alley and vacates it — so a candidate block first
  /// checks that no REAL street clips the site, then removes the alleys
  /// under it and stakes. The check runs before any alley is touched, so a
  /// bent street rejects the block without costing it its alley.
  void _placeMegatowers(CitySim city, CityGenSpec spec, math.Random rnd) {
    if (spec.megatowers <= 0) return;
    final site = kMegatowerSpec.siteMetres();
    final hw = site.width / 2, hd = site.depth / 2;

    final cells = <Vec2>[];
    for (var i = 0; i < spec.blocksAcross; i++) {
      for (var j = 0; j < spec.blocksDeep; j++) {
        cells.add(Vec2(
          -spec.extentM / 2 + (i + 0.5) * spec.blockM,
          -spec.depthExtentM / 2 + (j + 0.5) * spec.blockDepthM,
        ));
      }
    }
    cells.sort((a, b) => a.length.compareTo(b.length));

    // The plot check's own clearance: a street is a hit inside this of a
    // corner, or anywhere through the plot.
    final clearance = <RoadClass, double>{
      for (final cls in RoadClass.values)
        cls: cls.halfWidth + city.layout.settings.sidewalkM * 0.5,
    };
    final streets = [
      for (final r in city.layout.roads)
        if (r.roadClass != RoadClass.alley) (r, r.sample(stepM: 8)),
    ];
    // Whether the site at [at] is clear of every road that is NOT an alley —
    // the same judgement [claimSite] will make once the alleys are gone,
    // made BEFORE any alley is touched. The old placer skipped this screen,
    // bought out a block's alley, and then let claimSite refuse the block: a
    // small city could lose every alley it had to towers that never stood.
    bool clearOfStreets(Vec2 at) {
      final poly = city.siteFootprint(kMegatowerSpec, at);
      final probe = Parcel(id: '__mega', polygon: poly, manual: true);
      final probes = [...poly, at];
      for (final (road, pts) in streets) {
        final c = clearance[road.roadClass]!;
        for (final p in pts) {
          if (probe.contains(p)) return false;
          for (final v in probes) {
            if ((p - v).length < c) return false;
          }
        }
      }
      return true;
    }

    var placed = 0;
    for (final c in cells) {
      if (placed >= spec.megatowers) break;
      // A handful of tries per block, jittered mostly ALONG the block: the
      // interior is over twice the site's width, so sliding sideways is how
      // a plot dodges the bend that clips it at dead centre — the same
      // attempts-per-site trick the installations use.
      // More tries than the installations get, and a wider slide: the
      // screen is exact, so a block that CAN take the tower somewhere along
      // its length should be found rather than skipped for the next one out.
      Vec2? at;
      for (var t = 0; t < 24 && at == null; t++) {
        final try_ = t == 0
            ? c
            : Vec2(c.e + (rnd.nextDouble() - 0.5) * 150,
                c.n + (rnd.nextDouble() - 0.5) * 30);
        if (clearOfStreets(try_)) at = try_;
      }
      if (at == null) continue;
      // Buy out the alleys under the footprint — the block's spine runs
      // exactly where the plot's middle is, and [claimSite] would rightly
      // refuse the incursion. Only now, for a block the streets allow.
      for (final road in city.layout.roads.toList()) {
        if (road.roadClass != RoadClass.alley) continue;
        for (final p in road.sample(stepM: 24)) {
          if ((p.e - at.e).abs() < hw + 55 && (p.n - at.n).abs() < hd + 12) {
            city.layout.removeRoad(road.id, regenerateLots: false);
            break;
          }
        }
      }
      if (city.claimSite(kMegatowerSpec, at, regenerateLots: false) != null) {
        placed++;
      }
    }
  }
}
