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
import 'city_layout.dart';
import 'city_sim.dart';
import 'parcel.dart';
import 'spatial_index.dart';
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
    this.sprawlMiles = 0,
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

  /// Zero by default: the sprawl is platted now — every section's streets,
  /// lots and buildings are real — so twenty miles of it is a real cost,
  /// and a test or a tool that wants only the town should not pay it. The
  /// studio asks for twenty, which is Chicago.
  ///
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

    // The sprawl, PLATTED: every section's streets, lots and plots through
    // the same subdivider as the downtown's, ahead of the one re-cut that
    // cuts them all. The plan still lays the roads at the mile scale and
    // zones the sections; the sections' own streets, lots, houses, strips,
    // sheds and farms are the plat's from here on.
    // The sprawl's mile-scale network first — county highways, the railway
    // on, the interstates with their bridges and interchanges — so the
    // sections' collectors have a real highway to end on. Where the
    // interchanges landed goes on the spec, the way the plots did: the
    // zoning puts commerce round them.
    yield (phase: 'laying the county grid', fraction: 0.485);
    if (sim.sprawlSpec != null) {
      final interchanges = const CityGenerator()._laySprawlRoads(sim);
      sim.sprawlSpec = sim.sprawlSpec!.copyWith(interchanges: [
        for (final p in interchanges) [p.e, p.n],
      ]);
    }
    yield (phase: 'platting the sprawl', fraction: 0.49);
    final sectionRoads = <String, int>{};
    final plan = sim.sprawl;
    if (plan != null) {
      const CityGenerator()._wallExpressways(sim, plan);
      sectionRoads.addAll(
          const CityGenerator()._laySections(sim, spec, outline, plan));
    }

    for (final f in sim.layout.regenerateSteps()) {
      yield (phase: 're-platting round the plots', fraction: 0.5 + f * 0.40);
    }

    // Stepped per lot rather than one opaque call: this loop is seconds of
    // work on a big colony, and run between two yields it read as a freeze —
    // the label painted "zoning and building" and then nothing moved until
    // "settling". Per-lot steps are also what let a driver draw the buildings
    // arriving.
    yield (phase: 'zoning and building', fraction: 0.90);
    for (final f in const CityGenerator()._zoneAndBuildSteps(
        sim, spec, outline, rnd,
        skipRoads: sectionRoads.keys.toSet())) {
      yield (phase: 'zoning and building', fraction: 0.90 + f * 0.05);
    }
    if (plan != null) {
      yield (phase: 'zoning the sprawl', fraction: 0.95);
      const CityGenerator()._zoneSections(sim, plan, sectionRoads);
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
      CitySim city, CityGenSpec spec, CityShape shape, math.Random rnd,
      {Set<String> skipRoads = const {}}) sync* {
    // Where industry takes over on its sector, as a fraction of the
    // outline. `industryRing` is the knob; the default puts the works in the
    // last quarter of the town on the railway side.
    final industryFrom = (spec.industryRing * 1.25).clamp(0.5, 1.2);
    final park = kUtilCatalog.firstWhere((s) => s.type == 'park');

    // Snapshot: `setUse` swaps the auto list copy-on-write under the loop.
    final lots = List.of(city.layout.autoParcels);
    for (var i = 0; i < lots.length; i++) {
      final lot = lots[i];
      // The sprawl's lots are zoned by their sections, not by the bands.
      if (lot.roadId case final rid? when skipRoads.contains(baseRoadId(rid))) {
        yield (i + 1) / lots.length;
        continue;
      }
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

  /// The road a piece was committed as: `r12x0x1` is a piece of `r12`.
  static String baseRoadId(String id) {
    final i = id.indexOf('x');
    return i < 0 ? id : id.substring(0, i);
  }

  // ---- The sprawl's roads ----------------------------------------------------

  /// How far along a county highway from the crossing a diamond's ramps
  /// land: the ramp terminal, a signalised T on the highway.
  static const double diamondTerminalM = 110;

  /// How far along the expressway from the crossing a diamond's ramps
  /// merge with it.
  static const double diamondMergeM = 420;

  /// A cloverleaf's loop radius, and the radius of its outer connectors.
  static const double loopRadiusM = 75;
  static const double connectorRadiusM = 400;

  /// How far past the outline an interstate runs on into the country: far
  /// enough that its end is never in the same view as the city.
  static double sprawlOutreachFor(SprawlSpec s) =>
      math.max(8000.0, s.radiusM * 0.6);

  /// Lay the sprawl's mile-scale network as plat.
  ///
  /// The county highways on the section grid, broken at the core and at
  /// every staked plot; the railway carried on from the plat's line; the
  /// interstates — the axial radials from the core's central avenues, the
  /// diagonals from the first grid crossing clear of it, the beltway at
  /// half the reach — six lanes to the outline and four beyond, tapering
  /// at the drop; a diamond wherever an interstate crosses a county
  /// highway and a cloverleaf where it crosses another, a mile or more
  /// apart; the core's own diamonds on the expressway through it, their
  /// ramps climbing to the deck; and the slip ramps its frontage roads
  /// become where the deck comes down.
  ///
  /// Every road goes through [CitySim.commitRoad]: it splits where it
  /// crosses, an expressway bridges whatever crosses it, a ramp's terminal
  /// cuts the road it lands on into a signalised T, and its merge splits
  /// the expressway it joins. What was a graph the plan built for itself
  /// is the plat's own topology. Returns where the interchanges are.
  List<Vec2> _laySprawlRoads(CitySim city) {
    final s = city.sprawlSpec;
    if (s == null) return const [];
    final layout = city.layout;
    final outline = SprawlPlan.outlineOf(s);
    final rnd = math.Random(s.seed * 104729 + 7);
    final sectionM = s.sectionM;
    final n = SprawlPlan.gridReach(s);
    final maxR = outline.maxRadiusM;
    final outreach = sprawlOutreachFor(s);

    // ---- The county highways: the section-line grid ----------------------
    //
    // A section line an axial interstate runs along is the interstate's
    // corridor, not a county highway's: a grid line laid there sat under
    // the expressway, crossed it wherever it wandered, and grew a diamond
    // at every crossing.
    bool underInterstate(int axis, double t) {
      final lines = axis == 0
          ? [if (s.interstates >= 1) s.axisOffsetN]
          : [if (s.interstates >= 2) s.axisOffsetE];
      return lines.any((l) => (l - t).abs() < 250);
    }

    for (var axis = 0; axis < 2; axis++) {
      for (var i = -n; i <= n; i++) {
        final t = i * sectionM;
        if (t.abs() > maxR) continue;
        if (underInterstate(axis, t)) continue;
        Vec2 at(double a) => axis == 0 ? Vec2(a, t) : Vec2(t, a);
        // Walk out from the centre each way until the outline ends: the
        // edge is ragged, so each line finds its own reach. On past the
        // outline by a couple of sections: the survey grid does not stop
        // where the houses do.
        double reachTo(double sign) {
          var a = 0.0;
          while (a < maxR && outline.contains(at(sign * (a + 50)))) {
            a += 50;
          }
          return a + sectionM * 2;
        }

        if (!outline.contains(at(0))) continue;
        final reachA = reachTo(-1), reachB = reachTo(1);
        // The core has its own streets and a staked plot is somebody's
        // ground: the highway stops at the edge of either and resumes the
        // far side. Walked in steps, so a line finds every gap it crosses.
        bool blocked(Vec2 p) =>
            s.coreContains(p, marginM: 40) || s.inClearing(p, marginM: 30);
        final spans = <(double, double)>[];
        double? open;
        for (var a = -reachA; a <= reachB + 1e-6; a += 20) {
          final b = blocked(at(a));
          if (!b && open == null) open = a;
          if (b && open != null) {
            spans.add((open, a - 20));
            open = null;
          }
        }
        if (open != null) spans.add((open, reachB));
        for (final (a, b) in spans) {
          if (b - a < sectionM * 0.6) continue;
          // The county highway is the plat's own four-lane avenue, drawn
          // the same way; it fronts nothing, and it follows the land.
          city.commitRoad([at(a), at(b)], RoadClass.avenue,
              regenerateLots: false, frontsLots: false, graded: false);
        }
      }
    }

    // ---- The railway, on from the plat's line ------------------------------
    //
    // Straight off the end of the plat's own track, wandering a little once
    // it is out in the fields, to well past the outline both ways.
    if (s.railInnerReachM > 0) {
      for (final sign in const [1.0, -1.0]) {
        final bearing = sign > 0 ? 0.0 : math.pi;
        final end = outline.radiusAt(bearing) + outreach + 3000;
        final pts = <Vec2>[];
        const steps = 10;
        var wander = 0.0;
        for (var k = 0; k <= steps; k++) {
          final x = sign *
              (s.railInnerReachM + (end - s.railInnerReachM) * k / steps);
          if (k > 0) wander += (rnd.nextDouble() - 0.5) * 60;
          wander *= 0.8;
          pts.add(Vec2(x, s.railOffsetN + (k == 0 ? 0 : wander)));
        }
        city.commitRoad(pts, RoadClass.rail,
            regenerateLots: false, frontsLots: false, graded: false);
      }
    }

    // ---- The interstates ---------------------------------------------------
    //
    // Straight-ish radials on the axes, from the core's central avenues to
    // the county line, bending gently once out in the sections; the
    // diagonals likewise; the beltway a ring at 0.48 R. Interstates never
    // run down a section line — they cut the sections, which is what a real
    // one does to a grid laid before it.
    List<Vec2> radial(double bearing, double offset, {double? startM}) {
      final dir = Vec2(math.cos(bearing), math.sin(bearing));
      final side = dir.perp;
      final out = <Vec2>[];
      const steps = 12;
      final start = startM ?? s.coreRadiusAt(bearing) * 0.98;
      final end = outline.radiusAt(bearing) + outreach;
      var wander = 0.0;
      for (var k = 0; k <= steps; k++) {
        final d = start + (end - start) * k / steps;
        if (k > 1) wander += (rnd.nextDouble() - 0.5) * 140;
        wander *= 0.85;
        out.add(dir * d + side * (offset + wander));
      }
      return out;
    }

    final laid = <_Interstate>[];
    var count = 0;
    // The axial interstates on the plat's central avenues: east and west
    // on one line, north and south on the other. The lateral offset is in
    // each radial's own frame — side is dir.perp — so opposite bearings
    // take opposite signs to land on the same line. Where the plat carries
    // the east-west line through the core on its expressway, those two
    // start at deck height and as wide as it, and come down to grade over
    // their first hundred and thirty metres; the others carry on as the
    // plat's central avenue and widen out of its width.
    for (var a = 0; a < math.min(4, s.interstates); a++) {
      final bearing = a * math.pi / 2;
      final lateral = switch (a) {
        0 => s.axisOffsetN,
        1 => -s.axisOffsetE,
        2 => -s.axisOffsetN,
        _ => s.axisOffsetE,
      };
      final deck = s.expressway && a.isEven;
      laid.add(_layInterstate(city, 'I-${++count}', radial(bearing, lateral),
          outline,
          startHalfWidthM:
              deck ? RoadClass.elevated.halfWidth : RoadClass.avenue.halfWidth,
          bridges: deck
              ? const [(-SprawlPlan.bridgeRampM, SprawlPlan.bridgeRampM)]
              : const [],
          radial: true));
    }
    // A diagonal has no avenue to carry on from: it begins at the first
    // crossing of the county grid clear of the core — which lies exactly
    // on its bearing — where it ends at a signal with the two highways.
    for (var a = 0; a < math.min(4, s.diagonals); a++) {
      final bearing = math.pi / 4 + a * math.pi / 2;
      final k = ((s.coreRadiusAt(bearing) * 0.98 + 300) /
              (sectionM * math.sqrt2))
          .ceil();
      laid.add(_layInterstate(
          city,
          'I-${++count}',
          radial(bearing, 0, startM: k * sectionM * math.sqrt2),
          outline,
          radial: true));
    }
    if (s.beltway) {
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
      laid.add(_layInterstate(city, 'I-${++count}', pts, outline,
          beltway: true));
    }

    // ---- Interchanges: where an interstate crosses anything ---------------
    //
    // The interstate is carried over on a bridge (commitRoad's own rule);
    // a diamond of ramps joins it to a county highway, a cloverleaf to
    // another interstate. Crossings closer than a mile to the last on the
    // same interstate get the bridge but no ramps — real interchanges are a
    // mile or more apart.
    final interchanges = <Vec2>[];
    var rampCount = 0;
    for (final road in laid) {
      road.crossings.sort((a, b) => a.$2.compareTo(b.$2));
    }
    // Interchanges keep their distance from one another WHATEVER road
    // they are on: a diamond's ramps run four hundred metres along the
    // expressway, and one built beside a cloverleaf ran straight through
    // its loops. The cloverleafs go first — an expressway meeting an
    // expressway is the interchange that matters — then the diamonds in
    // the room that is left.
    // And clear of every OTHER county highway: a diamond's ramps reach four
    // hundred metres along the expressway and a cloverleaf's connectors
    // four hundred out, and either laid beside a grid line ran through it.
    // The pieces of the line crossed at [at] are its own, not others.
    bool clearOfHighways(Vec2 at) {
      var clear = true;
      layout.roadIndex.visit(Box2.around(at, 480), 0, (slot, rec, seg) {
        if (!clear) return;
        final r = rec.road;
        if (r.roadClass != RoadClass.avenue || r.platsLots) return;
        if (rec.sampleCount < 2) return;
        // On the line through [at]: the crossed highway, whatever piece.
        final a = rec.sampleAt(0), b = rec.sampleAt(rec.sampleCount - 1);
        final ab = b - a;
        final len = ab.length;
        if (len > 1e-6 && ((at - a).cross(ab)).abs() / len < 2) return;
        final d = seg == 0
            ? at.distanceTo(rec.sampleAt(0))
            : rec.distanceToSegment(at, seg);
        if (d < 480) clear = false;
      });
      return clear;
    }

    bool clearOfInterchanges(Vec2 p) =>
        interchanges.every((q) => q.distanceTo(p) >= sectionM * 0.6);
    // A ring has no ends.
    bool nearEnd(_Interstate road, double sG) =>
        !road.beltway && (sG < 260 || sG > road.length - 260);

    for (final road in laid) {
      for (final (c, sG) in road.crossings) {
        if (!c.bridged || nearEnd(road, sG) || !clearOfInterchanges(c.at)) {
          continue;
        }
        final other = _roadUnder(
            layout,
            c.at,
            (r) =>
                r.roadClass.isExpressway &&
                !road.baseIds.contains(baseRoadId(r.id)));
        if (other == null) continue;
        final onI = _Along(road.pts, road.cum, sG);
        final onO = _Along.ofRoad(layout, other, c.at);
        if (onO == null) continue;
        // Both are interstates: the pair is built once, from the one laid
        // later, which passes under. The loops always; the outer
        // connectors, which reach four hundred metres out, only where no
        // county highway runs through that.
        final over = laid.firstWhere(
            (x) => x.baseIds.contains(baseRoadId(other.id)),
            orElse: () => road);
        interchanges.add(c.at);
        _cloverleaf(city, onI, onO, road.classAt, over.classAt,
            'R-${++rampCount}',
            mergeI: (point) => _mergeAt(city, road, point),
            mergeO: (point) => _mergeAt(city, over, point),
            connectors: clearOfHighways(c.at));
      }
    }
    for (final road in laid) {
      final ramped = <double>[];
      for (final (c, sG) in road.crossings) {
        if (!c.bridged || nearEnd(road, sG)) continue;
        // A mile or more apart along the same road, and clear of every
        // interchange already built and of every other highway.
        if (ramped.any((r) => (r - sG).abs() < sectionM * 0.9)) continue;
        if (!clearOfInterchanges(c.at) || !clearOfHighways(c.at)) continue;
        final highway = _roadUnder(layout, c.at,
            (r) => r.roadClass == RoadClass.avenue && !r.platsLots);
        if (highway == null) continue;
        final onI = _Along(road.pts, road.cum, sG);
        final onO = _Along.ofRoad(layout, highway, c.at);
        if (onO == null) continue;
        ramped.add(sG);
        interchanges.add(c.at);
        _diamond(city, onI, onO, road.classAt, 'R-${++rampCount}',
            merge: (sM, point) => _mergeAt(city, road, point));
      }
    }

    // ---- The expressway through the core ----------------------------------
    //
    // The plat drew it — an elevated expressway on the central avenue with
    // frontage roads under it. A diamond wherever it crosses one of the
    // plat's north-south avenues, well inside the core and well apart, with
    // the ramps climbing to the deck over their last stretch; and the
    // frontage roads carrying on as slip ramps where the deck comes down.
    if (s.expressway) {
      final y = s.axisOffsetN;
      final west = -s.coreRadiusAt(math.pi) * 0.98;
      final east = s.coreRadiusAt(0) * 0.98;
      final cpts = [
        for (var k = 0; k <= 10; k++) Vec2(west + (east - west) * k / 10, y),
      ];
      // The whole line, west radial to east radial through the corridor,
      // so a ramp near the core's edge can run on out along the interstate
      // rather than bunch at the corridor's end.
      final westward = laid.length > 2 && s.interstates >= 3 ? laid[2] : null;
      final eastward = laid.isNotEmpty && s.interstates >= 1 ? laid[0] : null;
      final through = [
        if (westward != null) ...westward.pts.reversed,
        ...cpts,
        if (eastward != null) ...eastward.pts,
      ];
      final tcum = _cumOf(through);
      final origin = westward != null ? tcum[westward.pts.length] : 0.0;
      final corridorLen = _cumOf(cpts).last;
      RoadClass classAt(double sT) {
        if (sT < origin) return westward?.classAt(origin - sT) ?? RoadClass.elevated;
        if (sT > origin + corridorLen) {
          return eastward?.classAt(sT - origin - corridorLen) ?? RoadClass.elevated;
        }
        return RoadClass.elevated;
      }

      // How high the line is at [sT]: the deck's height on the corridor,
      // and the radials' own descent off it either side.
      double liftAt(double sT) {
        if (sT < origin) {
          return westward == null
              ? 0
              : SprawlPlan.bridgeLiftAt(origin - sT, westward.startBridges);
        }
        if (sT > origin + corridorLen) {
          return eastward == null
              ? 0
              : SprawlPlan.bridgeLiftAt(
                  sT - origin - corridorLen, eastward.startBridges);
        }
        return SprawlPlan.bridgeHeightM;
      }

      // A merge on the deck is in the air and the plat draws the structure;
      // one on a radial splits it there.
      void mergeOn(double sT, Vec2 point) {
        if (sT < origin) {
          if (westward != null) _mergeAt(city, westward, point);
        } else if (sT > origin + corridorLen && eastward != null) {
          _mergeAt(city, eastward, point);
        }
      }

      var last = double.negativeInfinity;
      final avenues = [...s.coreAvenuesE]..sort();
      for (final x in avenues) {
        if ((x - s.axisOffsetE).abs() < 200) continue;
        final p = Vec2(x, y);
        if (!s.coreContains(p, marginM: -100)) continue;
        final sT = origin + (x - west);
        if ((sT - last).abs() < 700) continue;
        last = sT;
        final avenue = [Vec2(x, y - 600), Vec2(x, y + 600)];
        final onI = _Along(through, tcum, sT);
        final onO = _Along(avenue, _cumOf(avenue), 600);
        interchanges.add(p);
        _diamond(city, onI, onO, classAt, 'R-${++rampCount}',
            liftAt: liftAt, merge: mergeOn);
      }

      // The frontage roads under the deck carry on as slip ramps where it
      // comes down: traffic keeps right, so the south one is eastbound and
      // the north one westbound; each becomes an on-ramp at the end it
      // drives toward and receives an off-ramp at the other. Nothing
      // stops dead at the core's edge, and the plat's frontage road end
      // and the ramp's start are one point.
      double arcOf(double x) => origin + (x - west);
      for (final f in s.frontageRoads) {
        if (f.length < 3) continue;
        final t = f[0], a = f[1], b = f[2];
        final south = t < y;
        final so = south ? -1.0 : 1.0; // which side of the line it is on
        // Eastbound uses the south road and runs west to east; westbound
        // the north road, east to west.
        final eastBound = south;
        final onEnd = eastBound ? b : a, offEnd = eastBound ? a : b;
        final sOn = arcOf(onEnd) + (eastBound ? 350 : -350);
        final sOff = arcOf(offEnd) - (eastBound ? 350 : -350);
        for (final (isOn, sMerge, endX) in [
          (true, sOn, onEnd),
          (false, sOff, offEnd)
        ]) {
          final along = _Along(through, tcum, sMerge);
          final edge = _edgeOf(classAt(sMerge));
          // From the frontage road's end onto the line's outer edge — the
          // road's own side of it, wherever the line has bent to by then —
          // and along it to the merge.
          final roadEnd = Vec2(endX, t);
          final side = along.dir.perp.dot(Vec2(0, so)) >= 0 ? 1.0 : -1.0;
          var pts = _rampAlong(along, roadEnd, 0, side, edge);
          if (!isOn) pts = pts.reversed.toList();
          city.commitRoad(pts, RoadClass.ramp,
              regenerateLots: false,
              frontsLots: false,
              graded: false,
              snapStart: isOn,
              snapEnd: !isOn);
          mergeOn(sMerge, along.at(0));
        }
      }
    }
    return interchanges;
  }

  /// Lay one interstate: six lanes to the outline and four beyond, as two
  /// roads meeting end to end with the first tapering to the second's
  /// width; the beltway eight throughout. Its crossings, as commitRoad
  /// found them, come back positioned along the whole line.
  _Interstate _layInterstate(
    CitySim city,
    String name,
    List<Vec2> pts,
    SprawlOutline outline, {
    double? startHalfWidthM,
    List<(double, double)> bridges = const [],
    bool radial = false,
    bool beltway = false,
  }) {
    final road = _Interstate(name, pts, _cumOf(pts), beltway: beltway)
      ..startBridges = bridges;
    void commit(List<Vec2> piece, RoadClass cls, double offset,
        {double? hw0,
        double? hw1,
        List<(double, double)> br = const [],
        double clearStart = CityLayout.bridgeEndClearM,
        double clearEnd = CityLayout.bridgeEndClearM}) {
      final id = city.commitRoad(piece, cls,
          regenerateLots: false,
          frontsLots: false,
          graded: false,
          startHalfWidthM: hw0,
          endHalfWidthM: hw1,
          bridges: br,
          bridgeClearStartM: clearStart,
          bridgeClearEndM: clearEnd);
      if (id != null) road.baseIds.add(id);
      for (final c in city.lastCommitCrossings) {
        road.crossings.add((c, offset + c.sNew));
      }
    }

    if (beltway) {
      // A ring: its two ends meet, and neither is an end anything need
      // keep clear of.
      commit(pts, RoadClass.expressway8, 0,
          hw0: startHalfWidthM, br: bridges, clearStart: 0, clearEnd: 0);
      return road;
    }
    // Where the radial leaves the built-up outline: past it the road drops
    // from six lanes to four. Six inside, because that is what the viaduct
    // through the core carries and a mainline does not change its lane
    // count where a deck happens to end.
    var outS = double.infinity;
    var outK = -1;
    for (var k = 0; k < pts.length; k++) {
      if (outline.fractionOf(pts[k]) > 1.0) {
        outS = road.cum[k];
        outK = k;
        break;
      }
    }
    road.outS = outS;
    if (outK <= 0 || outK >= pts.length - 1) {
      commit(pts, outK <= 0 ? RoadClass.expressway4 : RoadClass.expressway6, 0,
          hw0: startHalfWidthM, br: bridges);
      return road;
    }
    // The seam where the lanes drop is not an end: a crossing beside it is
    // bridged like any other.
    final inner = pts.sublist(0, outK + 1);
    final outer = pts.sublist(outK);
    commit(inner, RoadClass.expressway6, 0,
        hw0: startHalfWidthM,
        hw1: RoadClass.expressway4.halfWidth,
        br: bridges,
        clearEnd: 0);
    commit(outer, RoadClass.expressway4, outS, clearStart: 0);
    return road;
  }

  /// A diamond: the expressway passes over the other road at [i]'s point.
  /// Four ramps, one per quadrant, each a T on the other road
  /// [diamondTerminalM] from the crossing and a merge on the expressway's
  /// outer edge [diamondMergeM] along it — ON the expressway, wherever its
  /// bends have taken it by then.
  ///
  /// Two are on-ramps and two off-ramps, by which side of the expressway
  /// the quadrant is: traffic keeps right, joins after the crossing and
  /// leaves before it. An on-ramp runs terminal to merge; an off-ramp is
  /// laid the other way round, because a ramp's direction IS its point
  /// order. The terminal end snaps onto the other road and cuts it into a
  /// T; the merge end lands on the edge, unsnapped, and [merge] splits the
  /// expressway there.
  void _diamond(
    CitySim city,
    _Along i,
    _Along o,
    RoadClass Function(double s) classI,
    String id, {
    double Function(double s)? liftAt,
    required void Function(double sM, Vec2 point) merge,
  }) {
    final dir = i.dir, odir = o.dir;
    final right = _rightOf(dir, odir);
    for (final si in const [-1.0, 1.0]) {
      for (final so in const [-1.0, 1.0]) {
        final terminal = o.at(so * diamondTerminalM);
        final mergeS = i.s + si * diamondMergeM;
        final edge = _edgeOf(classI(mergeS));
        final mergePoint = i.at(si * diamondMergeM);
        // The quadrant's side of the expressway, as a sign on its own
        // lateral: where the terminal stands.
        final side = odir.dot(dir.perp) * so >= 0 ? 1.0 : -1.0;
        // From the terminal onto the expressway's outer edge and along it
        // to the merge — following the line as it actually runs there,
        // bends and all. A cubic drawn in the plane cut the chord of a
        // bend, crossed the centreline, and was cut there as a junction.
        var pts = _rampAlong(i, terminal, si * diamondMergeM, side, edge);
        final onRamp = si * so * right > 0;
        if (!onRamp) pts = pts.reversed.toList();
        var bridges = const <(double, double)>[];
        if (liftAt != null && liftAt(mergeS) > SprawlPlan.bridgeHeightM / 2) {
          // The mainline is on its deck where this ramp meets it: climb to
          // it over the last stretch, or come down off it over the first.
          final l = _cumOf(pts).last;
          bridges = onRamp
              ? [(l - SprawlPlan.bridgeRampM, l + SprawlPlan.bridgeRampM)]
              : const [(-SprawlPlan.bridgeRampM, SprawlPlan.bridgeRampM)];
        }
        city.commitRoad(pts, RoadClass.ramp,
            regenerateLots: false,
            frontsLots: false,
            graded: false,
            bridges: bridges,
            snapStart: onRamp,
            snapEnd: !onRamp);
        merge(mergeS, mergePoint);
      }
    }
  }

  /// A cloverleaf where [i] crosses [o]: four loop ramps, one per quadrant,
  /// each three quarters of a circle tangent to both roads' outer edges,
  /// plus four outer connectors — quarter circles well outside the loops —
  /// for the right turns. Each end lands on an edge, unsnapped, and the
  /// road it lands on is split there.
  void _cloverleaf(
    CitySim city,
    _Along i,
    _Along o,
    RoadClass Function(double s) classI,
    RoadClass Function(double s) classO,
    String id, {
    required void Function(Vec2 point) mergeI,
    required void Function(Vec2 point) mergeO,
    bool connectors = true,
  }) {
    final dir = i.dir, odir = o.dir;
    final right = _rightOf(dir, odir);
    final edgeI = _edgeOf(classI(i.s));
    final edgeO = _edgeOf(classO(o.s));
    void ramp(List<Vec2> pts) => city.commitRoad(pts, RoadClass.ramp,
        regenerateLots: false,
        frontsLots: false,
        graded: false,
        snapStart: false,
        snapEnd: false);
    for (final si in const [-1.0, 1.0]) {
      for (final so in const [-1.0, 1.0]) {
        // The loop's two tangent points, ON each road's edge line where
        // that road actually runs — a loop radius past the crossing.
        final lI = si * (loopRadiusM + edgeO), lO = so * (loopRadiusM + edgeI);
        final loopStart = i.at(lI) + odir * (so * edgeI);
        final loopEnd = o.at(lO) + dir * (si * edgeO);
        final centre = loopStart + odir * (so * loopRadiusM);
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
          for (var k = 0; k <= steps; k++)
            () {
              final t = k / steps;
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
        ramp(pts);
        mergeI(i.at(lI));
        mergeO(o.at(lO));
        if (!connectors) continue;

        // The outer connector of the same quadrant: a quarter turn between
        // the two roads well outside the loop, tangent to each where it
        // leaves and where it lands.
        final cI = si * (connectorRadiusM + edgeO);
        final cO = so * (connectorRadiusM + edgeI);
        final connStart = i.at(cI) + odir * (so * edgeI);
        final connEnd = o.at(cO) + dir * (si * edgeO);
        final dirStart = i.dirAt(cI), dirEnd = o.dirAt(cO);
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
        ramp(cpts);
        mergeI(i.at(cI));
        mergeO(o.at(cO));
      }
    }
  }

  /// Split the piece of [road] under [point] there: a merge, or a tangent.
  /// Nothing on a deck — a merge in the air is the structure's business.
  void _mergeAt(CitySim city, _Interstate road, Vec2 point) {
    final layout = city.layout;
    final piece = _roadUnder(layout, point,
        (r) => r.roadClass.isExpressway && road.baseIds.contains(baseRoadId(r.id)));
    if (piece == null) return;
    final rec = layout.roadIndex.byId(piece.id);
    if (rec == null) return;
    final hit = layout.roadIndex.nearest(point, startM: 8, maxM: 64);
    if (hit == null || hit.road.road.id != piece.id) return;
    final seg = hit.seg;
    if (seg == 0) return;
    final a = rec.sampleAt(seg - 1);
    final len = rec.sampleAt(seg).distanceTo(a);
    final u = len <= 1e-9 ? 0.0 : (hit.point.distanceTo(a) / len).clamp(0.0, 1.0);
    layout.splitRoadAt(piece.id, rec.arcAt(seg, u));
  }

  /// The road passing within a lane of [point] that [where] accepts, the
  /// nearest first.
  static RoadSpline? _roadUnder(
      CityLayout layout, Vec2 point, bool Function(RoadSpline) where) {
    RoadSpline? best;
    var bestD = 4.0;
    layout.roadIndex.visit(Box2.around(point, 4), 0, (slot, rec, seg) {
      if (!where(rec.road)) return;
      final d = seg == 0
          ? point.distanceTo(rec.sampleAt(0))
          : rec.distanceToSegment(point, seg);
      if (d < bestD) {
        bestD = d;
        best = rec.road;
      }
    });
    return best;
  }

  /// Sound barriers where an expressway runs past housing: the walled
  /// variant on every piece whose middle lies in a built-up residential
  /// section, open everywhere else.
  void _wallExpressways(CitySim city, SprawlPlan plan) {
    bool wallsAt(Vec2 p) {
      for (final sec in plan.sections) {
        if ((p.e - sec.centre.e).abs() > sec.halfM ||
            (p.n - sec.centre.n).abs() > sec.halfM) {
          continue;
        }
        return sec.use == SprawlUse.residential && sec.density >= 0.4;
      }
      return false;
    }

    final layout = city.layout;
    for (final r in layout.roads.toList()) {
      if (!r.roadClass.canHaveSoundWalls || !r.roadClass.isExpressway) continue;
      final rec = layout.roadIndex.byId(r.id);
      if (rec == null || rec.sampleCount == 0) continue;
      if (wallsAt(rec.sampleAt(rec.sampleCount ~/ 2))) {
        layout.updateRoad(r.copyWith(soundWalls: true));
      }
    }
  }

  /// Which sign of [odir] lies to the RIGHT of travel along [dir]. Traffic
  /// keeps right, so this is what decides which quadrant's ramp is an
  /// on-ramp and which an off-ramp.
  static double _rightOf(Vec2 dir, Vec2 odir) =>
      Vec2(dir.n, -dir.e).dot(odir) >= 0 ? 1.0 : -1.0;

  /// The lateral offset of a road's outer edge line — where a ramp merges.
  static double _edgeOf(RoadClass cls) =>
      cls.halfWidth - (cls.lanes?.shoulderM ?? 0);

  static List<double> _cumOf(List<Vec2> pts) {
    final cum = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum[i - 1] + pts[i].distanceTo(pts[i - 1]));
    }
    return cum;
  }

  /// A ramp from [from] onto the outer edge of the road [i] runs along and
  /// along it to [dTo] metres from [i]'s own point: it eases from where
  /// [from] stands off the line onto the edge — [edge] metres off the
  /// centreline on [side] (a sign on the line's lateral) — and then
  /// follows the line, bend for bend. Built ALONG the road rather than as
  /// a curve in the plane, so it can neither cut the chord of a bend nor
  /// cross the centreline at a shallow crossing.
  static List<Vec2> _rampAlong(
      _Along i, Vec2 from, double dTo, double side, double edge,
      {int steps = 20}) {
    final origin = i.at(0);
    final d0 = (from - origin).dot(i.dir);
    final l0 = (from - i.at(d0)).dot(i.dirAt(d0).perp);
    final pts = <Vec2>[from];
    for (var k = 1; k <= steps; k++) {
      final u = k / steps;
      final d = d0 + (dTo - d0) * u;
      final ease = u * u * (3 - 2 * u);
      final l = l0 * (1 - ease) + side * edge * ease;
      pts.add(i.at(d) + i.dirAt(d).perp * l);
    }
    return pts;
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

  // ---- The sprawl, platted ---------------------------------------------------

  /// How far short of its section line a street that goes nowhere stops,
  /// leaving room for its turning circle.
  static const double sectionDeadEndInsetM = 45;

  /// Lay every section of [plan] as plat, and say which committed road
  /// (by base id) belongs to which section.
  ///
  /// The section builder used to grow all of this at draw time from the
  /// section's seed: a street grid with two collectors per axis running out
  /// to the county highway where the plan put a junction and every other
  /// street ending in a turning circle short of the line; houses along the
  /// streets by density; strip malls along the arterial; sheds in the
  /// blocks of an industrial park; fields and a farmstead. It is the same
  /// layout, laid as real streets through [CitySim.commitRoad] — so they
  /// split where they cross, cut real lots by the subdivider with a
  /// suburb's frontage, and take real buildings — and real plots for the
  /// strips and the quarter-section farms. Nothing of it is drawn
  /// differently from the downtown, because none of it is different.
  ///
  /// Streets keep off the platted core, off the plan's interstates, ramps
  /// and railway, and off every staked plot, the way the builder's did.
  Map<String, int> _laySections(
      CitySim city, CityGenSpec spec, CityShape shape, SprawlPlan plan) {
    final out = <String, int>{};
    final sspec = plan.spec;
    final layout = city.layout;

    // Where the county highways are: a collector runs out to its section
    // line only where a highway runs along it there — the highways break
    // at the core and at every staked plot.
    bool highwayAt(Vec2 p) {
      final hit = layout.nearestRoadPoint(p, withinM: 8);
      if (hit == null) return false;
      final r = layout.roadById(hit.roadId);
      return r != null && r.roadClass == RoadClass.avenue && !r.platsLots;
    }

    // The corridors the streets keep off: the expressways, their ramps and
    // the railway, as laid. A county highway is what the collectors run
    // out to, and everything else is a road a street may meet.
    bool nearCorridor(Vec2 p, double clearM) {
      var hit = false;
      layout.roadIndex.visit(Box2.around(p, clearM), 0, (slot, rec, seg) {
        if (hit) return;
        final cls = rec.road.roadClass;
        if (!(cls.isExpressway || cls == RoadClass.ramp || cls == RoadClass.rail)) {
          return;
        }
        final d = seg == 0
            ? p.distanceTo(rec.sampleAt(0))
            : rec.distanceToSegment(p, seg);
        if (d < clearM) hit = true;
      });
      return hit;
    }

    bool inCore(Vec2 p, double marginM) =>
        p.length < shape.radiusAt(math.atan2(p.n, p.e)) + marginM;
    bool blocked(Vec2 p, {double corridorM = 40, double clearingM = 12}) =>
        nearCorridor(p, corridorM) || sspec.inClearing(p, marginM: clearingM);

    /// Whether a plot [hw] by [hd] about [c] is clear of the core, the
    /// corridors and every staked plot, probed on a five-by-five lattice
    /// so a corridor cannot slip between its corners.
    bool plotClear(Vec2 c, double hw, double hd, double corridorM) {
      for (var i = 0; i < 5; i++) {
        for (var j = 0; j < 5; j++) {
          final p = Vec2(c.e - hw + hw * i / 2, c.n - hd + hd * j / 2);
          if (inCore(p, 60) || blocked(p, corridorM: corridorM)) return false;
        }
      }
      return true;
    }

    final quarter = kUtilCatalog
        .firstWhere((s) => s.type == 'farm' && s.siteWidthM >= 700);

    for (var si = 0; si < plan.sections.length; si++) {
      final s = plan.sections[si];
      final rnd = math.Random(s.seed ^ 0x5EC7);
      final half = s.halfM;
      final c = s.centre;
      Vec2 at(int axis, double t, double a) =>
          axis == 0 ? Vec2(c.e + a, c.n + t) : Vec2(c.e + t, c.n + a);

      switch (s.use) {
        case SprawlUse.parkland:
          // A forest preserve: the ground as the planet made it.
          continue;
        case SprawlUse.farmland:
          // The four quarter sections of a township's mile square, each a
          // farm with its rows, its farmhouse and its barn.
          final q = quarter.siteMetres();
          for (final (dx, dy) in const [
            (-1.0, -1.0),
            (1.0, -1.0),
            (-1.0, 1.0),
            (1.0, 1.0)
          ]) {
            final centre = Vec2(c.e + dx * half / 2, c.n + dy * half / 2);
            if (!plotClear(centre, q.width / 2, q.depth / 2, 45)) continue;
            // A farm follows the land: nothing levels a quarter section.
            city.claimSite(quarter, centre,
                regenerateLots: false,
                checkAccess: false,
                facing: Vec2(dx, 0),
                graded: false);
          }
          continue;
        case SprawlUse.residential:
        case SprawlUse.commercial:
        case SprawlUse.industrial:
          break;
      }

      final n = s.streetsAcross;
      if (n == 0) continue;
      // The grid: which lines the streets run on per axis (0: east-west
      // streets by northing, 1: north-south by easting), and which of them
      // are the collectors. The section's own survey grid, or — next to
      // the core — the plat's lines carried on.
      final List<double> lines0, lines1;
      final Set<int> coll0, coll1;
      if (s.continuesCoreGrid) {
        lines0 = s.streetLinesN;
        lines1 = s.streetLinesE;
        Set<int> pick(List<double> lines, List<double> chosen) => {
              for (var i = 0; i < lines.length; i++)
                if (chosen.any((v) => (v - lines[i]).abs() < 0.5)) i,
            };
        coll0 = pick(lines0, s.collectorOffsetsN);
        coll1 = pick(lines1, s.collectorOffsetsE);
      } else {
        final step = s.sizeM / n;
        lines0 = lines1 = [for (var k = 1; k < n; k++) -half + k * step];
        coll0 = coll1 = {
          for (final k in SprawlSection.collectorIndices(n)) k - 1
        };
      }
      // A suburb's lots: house lots at the builder's house pitch, strip
      // lots along a commercial section's streets, works plots in a park.
      final (frontage, depth) = switch (s.use) {
        SprawlUse.residential => (17.0 + (1 - s.density) * 16, 36.0),
        SprawlUse.commercial => (60.0, 80.0),
        _ => (90.0, 70.0),
      };
      // On the plat's grid a street begins at the outline, on the end of
      // the downtown street it carries on — the commit snaps the two into
      // one. On its own grid it keeps the depth of the plat's outer lots
      // off the outline.
      final coreMargin = s.continuesCoreGrid ? 0.0 : 60.0;

      for (var axis = 0; axis < 2; axis++) {
        final lines = axis == 0 ? lines0 : lines1;
        final colls = axis == 0 ? coll0 : coll1;
        for (var k = 0; k < lines.length; k++) {
          final t = lines[k];
          final collector = colls.contains(k);
          double endAt(double sign) {
            if (collector) {
              final edge = at(axis, t, sign * half);
              final inward = at(axis, t, sign * (half - 160));
              if (highwayAt(edge) && !nearCorridor(inward, 40)) {
                return sign * half;
              }
            }
            return sign * (half - sectionDeadEndInsetM);
          }

          final a0 = endAt(-1), a1 = endAt(1);
          void commit(double from, double to) {
            // Draped, not graded: a suburb's streets and lots follow the
            // land, the way the section builder's did.
            final id = city.commitRoad(
              [at(axis, t, from), at(axis, t, to)],
              RoadClass.street,
              regenerateLots: false,
              lotFrontageM: frontage,
              lotDepthM: depth,
              collector: collector,
              graded: false,
            );
            if (id != null) out[id] = si;
          }

          for (final (r0, r1) in _outsideCore(
              (a) => inCore(at(axis, t, a), coreMargin), a0, a1)) {
            // Break the run at corridors and plots, walked in short steps.
            final steps = math.max(2, ((r1 - r0) / 65).round());
            double? open;
            var prev = r0;
            for (var q = 0; q <= steps; q++) {
              final a = r0 + (r1 - r0) * q / steps;
              if (blocked(at(axis, t, a))) {
                if (open != null && prev - open >= 30) commit(open, prev);
                open = null;
              } else {
                open ??= a;
              }
              prev = a;
            }
            if (open != null && r1 - open >= 30) commit(open, r1);
          }
        }
      }

      // The strip: big boxes along the arterial on every side of a
      // commercial section, each on its own plot facing the highway with
      // its car park between.
      if (s.use == SprawlUse.commercial) {
        final site = kStripMallSpec.siteMetres();
        for (var edge = 0; edge < 4; edge++) {
          for (var a = -half + 120; a < half - 120; a += 115) {
            if (rnd.nextDouble() > s.density) continue;
            final along = a + (rnd.nextDouble() - 0.5) * 20;
            final set = half - 110;
            final (e, nn, facing) = switch (edge) {
              0 => (along, -set, const Vec2(0, -1)),
              1 => (along, set, const Vec2(0, 1)),
              2 => (-set, along, const Vec2(-1, 0)),
              _ => (set, along, const Vec2(1, 0)),
            };
            final p = Vec2(c.e + e, c.n + nn);
            if (!plotClear(p, site.width / 2, site.depth / 2, 45)) continue;
            city.claimSite(kStripMallSpec, p,
                regenerateLots: false,
                checkAccess: false,
                facing: facing,
                graded: false);
          }
        }
      }
    }
    return out;
  }

  /// The stretches of [a0]..[a1] where [inside] is false, each edge found
  /// to the metre by bisection. Runs shorter than 20 m are dropped.
  static List<(double, double)> _outsideCore(
      bool Function(double a) inside, double a0, double a1) {
    double edge(double lo, double hi) {
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

    final out = <(double, double)>[];
    const step = 24.0;
    double? open;
    var prev = a0;
    var prevIn = inside(a0);
    if (!prevIn) open = a0;
    for (var a = a0 + step; a < a1 + step; a += step) {
      final here = math.min(a, a1);
      final nowIn = inside(here);
      if (nowIn != prevIn) {
        final x = edge(prev, here);
        if (nowIn) {
          if (open != null) out.add((open, x));
          open = null;
        } else {
          open = x;
        }
      }
      prev = here;
      prevIn = nowIn;
      if (here >= a1) break;
    }
    if (open != null) out.add((open, a1));
    return [
      for (final r in out)
        if (r.$2 - r.$1 > 20) r,
    ];
  }

  /// Point on a polyline reached by arc length.
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

  /// Zone and build the sections' lots by their sections: houses on a
  /// subdivision's lots at its density, shops or a mall on a strip's,
  /// workshops or factories in a park's. What the builder drew from the
  /// seed, now standing on real lots the sim can count.
  void _zoneSections(CitySim city, SprawlPlan plan, Map<String, int> roads) {
    for (final lot in city.layout.autoParcels) {
      final rid = lot.roadId;
      if (rid == null) continue;
      final si = roads[baseRoadId(rid)];
      if (si == null) continue;
      final s = plan.sections[si];
      final dense = s.density >= 0.5;
      final (use, spec) = switch (s.use) {
        SprawlUse.residential => (
            ParcelUse.residential,
            kZoneSpecs['residential']![Density.low]!
          ),
        SprawlUse.commercial => (
            ParcelUse.commercial,
            kZoneSpecs['commercial']![dense ? Density.medium : Density.low]!
          ),
        _ => (
            ParcelUse.industrial,
            kZoneSpecs['industrial']![dense ? Density.medium : Density.low]!
          ),
      };
      city.layout.setUse(lot.id, use);
      // Built by density, decided per lot from the section's seed and the
      // lot's own name, so the same city stands however it is walked.
      var h = s.seed ^ lot.id.hashCode;
      h = (h ^ (h >> 16)) * 0x45d9f3b & 0xffffffff;
      h = (h ^ (h >> 16)) & 0xffff;
      if (h / 0xffff < s.density) city.placeOnParcel(lot.id, spec);
    }
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

/// An interstate while the sprawl is being laid: its line, where it leaves
/// the outline, the roads it was committed as, and every crossing it made.
class _Interstate {
  _Interstate(this.name, this.pts, this.cum, {this.beltway = false});
  final String name;
  final List<Vec2> pts;
  final List<double> cum;
  final bool beltway;

  /// Where it drops from six lanes to four.
  double outS = double.infinity;

  /// The bridge ranges it started with: the descent off the deck.
  List<(double, double)> startBridges = const [];

  /// The base ids of the roads it was committed as.
  final List<String> baseIds = [];

  /// Every crossing commitRoad found, with its position along the whole
  /// line.
  final List<(RoadCrossing, double)> crossings = [];

  double get length => cum.last;

  RoadClass classAt(double s) {
    if (beltway) return RoadClass.expressway8;
    return s < outS ? RoadClass.expressway6 : RoadClass.expressway4;
  }
}

/// A place on a polyline, with the means to step along it: [at] gives the
/// point [d] metres further along (or back), on the line however it bends.
class _Along {
  _Along(this.pts, this.cum, this.s) : dir = _dirAt(pts, cum, s);

  /// On a laid road, at the point of it nearest [near]: its own samples.
  static _Along? ofRoad(CityLayout layout, RoadSpline road, Vec2 near) {
    final rec = layout.roadIndex.byId(road.id);
    if (rec == null || rec.sampleCount < 2) return null;
    final pts = rec.samples;
    final cum = [for (var i = 0; i < rec.sampleCount; i++) rec.cum[i]];
    var bestS = 0.0;
    var bestD = double.infinity;
    for (var i = 1; i < pts.length; i++) {
      final (q, d) = rec.nearestOnSegment(near, i);
      if (d < bestD) {
        bestD = d;
        bestS = cum[i - 1] + q.distanceTo(pts[i - 1]);
      }
    }
    return _Along(pts, cum, bestS);
  }

  final List<Vec2> pts;
  final List<double> cum;
  final double s;
  final Vec2 dir;

  static Vec2 _dirAt(List<Vec2> pts, List<double> cum, double s) {
    final a = CityGenerator._pointAt(pts, cum, s - 1);
    final b = CityGenerator._pointAt(pts, cum, s + 1);
    return (b - a).normalized;
  }

  Vec2 at(double d) =>
      CityGenerator._pointAt(pts, cum, (s + d).clamp(0.0, cum.last));

  /// The line's own direction [d] metres along from here — where its
  /// bends have taken it, not where a straight line would be.
  Vec2 dirAt(double d) => _dirAt(pts, cum, (s + d).clamp(1.0, cum.last - 1));
}
