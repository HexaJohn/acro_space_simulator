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

/// What to build.
class CityGenSpec {
  const CityGenSpec({
    this.seed = 1,
    this.bodyId = 'earth',
    this.blocksAcross = 4,
    this.blockM = 220,
    this.blockDepthM = 104,
    this.frontageM = 24,
    this.lotDepthM = 46,
    this.bendM = 34,
    this.buildFraction = 0.85,
    this.industryRing = 0.62,
    this.installations = 4,
    this.alleys = true,
    this.transitLines = 1,
    this.elevatedHighways = 1,
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

  /// Build the colony described by [spec].
  CitySim generate(CityGenSpec spec, {required List<CelestialBody> bodies}) {
    final rnd = math.Random(spec.seed);
    final site = spec.latitude != null && spec.longitude != null
        ? (lat: spec.latitude!, lon: spec.longitude!)
        : dryLandNear(
            bodies.firstWhere((b) => b.id.value == spec.bodyId),
            seed: spec.seed,
          );
    final city = CitySim.found(
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
    // The generator is not a game: it must not stall on affordability.
    city.stock['ore'] = 1e9;
    city.funds = 1e9;
    city.layout.settings = city.layout.settings.copyWith(
      frontageM: spec.frontageM,
      depthM: spec.lotDepthM,
    );

    _layRoads(city, spec, rnd);
    city.layout.regenerate(); // one re-cut, for the whole network
    // Installations BEFORE the streets are built out. Staking a big plot
    // re-cuts the automatic subdivision around it, and lots that are re-cut
    // are lots that get renamed — so anything already standing on them has to
    // be carried across. `CitySim.claimSite` does carry it, but a generator
    // that avoids the question entirely is both simpler and truer to how a
    // colony grows: the quarry and the solar farm are sited first, and the
    // streets fill in around them.
    _placeInstallations(city, spec, rnd);
    city.layout.regenerate(); // one re-cut, after the whole ring is staked
    _zoneAndBuild(city, spec, rnd);
    city.recompute();
    // One step, so the colony hands back COHERENT: power, jobs, housing and
    // services are aggregated in `advance`, not in `recompute`, so a city that
    // has never ticked reports zero of everything and reads as dead.
    city.advance(0.1);
    return city;
  }

  /// Arterials one way, streets the other, every one of them bending.
  ///
  /// The grid is RECTANGULAR. Axis 0 carries the close-spaced streets that
  /// lots front onto; axis 1 carries the widely spaced cross streets. That
  /// asymmetry is what a block IS — get it wrong and the alleys, the lot
  /// depths and the street wall all follow it wrong.
  void _layRoads(CitySim city, CityGenSpec spec, math.Random rnd) {
    final half = spec.extentM / 2;
    final halfDeep = spec.depthExtentM / 2;
    double jitter() => (rnd.nextDouble() * 2 - 1) * spec.bendM;

    // Axis 0: the frontage streets, running along x, spaced by blockDepthM.
    for (var i = 0; i <= spec.blocksDeep; i++) {
      final t = -halfDeep + i * spec.blockDepthM;
      // Every fourth is an arterial: a city with one road class reads as a
      // housing estate, and the junction furniture only differentiates when
      // classes differ.
      final cls = i % 4 == 0 ? RoadClass.avenue : RoadClass.street;
      final controls = <Vec2>[
        for (var k = 0; k <= 4; k++)
          Vec2(-half + spec.extentM * k / 4,
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
      final cls = i % 3 == 0 ? RoadClass.avenue : RoadClass.street;
      final controls = <Vec2>[
        for (var k = 0; k <= 4; k++)
          Vec2(t + (k == 0 || k == 4 ? 0 : jitter()),
              -halfDeep + spec.depthExtentM * k / 4),
      ];
      city.commitRoad(controls, cls, regenerateLots: false);
    }

    if (spec.alleys) _layAlleys(city, spec, jitter);
    _layElevated(city, spec, rnd, jitter);
  }

  /// A service road down the middle of every block, parallel to the streets
  /// that front it.
  ///
  /// One axis only, which is what a real plat does: a block is a long
  /// rectangle, the lots front its two LONG sides, and the alley runs down its
  /// spine between their back fences. Cutting alleys both ways would leave
  /// nothing but corner lots.
  void _layAlleys(CitySim city, CityGenSpec spec, double Function() jitter) {
    final half = spec.extentM / 2;
    final halfDeep = spec.depthExtentM / 2;
    for (var i = 0; i < spec.blocksDeep; i++) {
      final t = -halfDeep + (i + 0.5) * spec.blockDepthM;
      final controls = <Vec2>[
        for (var k = 0; k <= 4; k++)
          // Half the street's wander: an alley is surveyed off the block it
          // splits, so it follows the streets rather than doing its own thing.
          Vec2(-half + spec.extentM * k / 4,
              t + (k == 0 || k == 4 ? 0 : jitter() * 0.25)),
      ];
      city.commitRoad(controls, RoadClass.alley, regenerateLots: false);
    }
  }

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
      // Offset half a block off a street centreline, so the trestle's columns
      // land in the carriageway rather than inside the buildings.
      final t = (line - (spec.transitLines - 1) / 2) * spec.blockDepthM * 3;
      final controls = <Vec2>[
        for (var k = 0; k <= steps; k++)
          Vec2(-half * 1.1 + spec.extentM * 1.1 * k / steps,
              t + (k == 0 || k == steps ? 0 : jitter() * 0.4)),
      ];
      city.commitRoad(controls, RoadClass.transit, regenerateLots: false);
    }

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

  /// Zone what the roads cut, then build most of it.
  void _zoneAndBuild(CitySim city, CityGenSpec spec, math.Random rnd) {
    final edge = spec.extentM * 0.5;

    // Where industry takes over, as a fraction of the city's half-extent.
    // `industryRing` is the knob; it used to gate a separate `outer` test that
    // fought the density bands, and now it simply ends the sequence.
    final industryFrom = (spec.industryRing * 1.9).clamp(0.6, 2.0);

    for (final lot in city.layout.autoParcels) {
      if (rnd.nextDouble() > spec.buildFraction) continue;
      final r = lot.centroid.length;

      // ONE ordering, centre outward: business district, then apartments,
      // then houses, then industry. Use and density were being decided
      // independently off two different thresholds, which is how a colony
      // ended up with 102 industrial sheds against 26 office towers — the
      // outskirts of a rectangular city are most of its lots, and both rules
      // called most of them "outer".
      //
      // Jittered so each boundary is a ragged transition rather than a
      // visible ring.
      final t = (r / edge).clamp(0.0, 1.6) + (rnd.nextDouble() - 0.5) * 0.18;

      final (String kind, Density density) = switch (t) {
        // THE HEART. Overwhelmingly commercial and all of it high density —
        // this is the band the skyline comes from, and it has to be a real
        // cluster rather than a scatter of towers among houses.
        < 0.34 => rnd.nextDouble() < 0.74
            ? ('commercial', Density.high)
            : ('residential', Density.high),
        // Inner ring: apartments over shops, stepping DOWN out of the core
        // rather than holding the same height — a wall of forty-storey
        // housing round a business district is a different city from the one
        // in the reference photographs.
        < 0.62 => rnd.nextDouble() < 0.3
            ? ('commercial', Density.medium)
            : (
                'residential',
                rnd.nextDouble() < 0.42 ? Density.high : Density.medium
              ),
        // The bulk of the city: mid-rise housing with corner shops.
        < 0.95 => rnd.nextDouble() < 0.18
            ? ('commercial', Density.low)
            : ('residential', Density.medium),
        // Edge: houses, and the works beyond them. A pattern arm has to be a
        // constant, and where industry starts is a spec knob, so the last two
        // bands are a plain conditional.
        _ => t < industryFrom
            ? (rnd.nextDouble() < 0.3
                ? ('industrial', Density.medium)
                : ('residential', Density.low))
            : (
                'industrial',
                rnd.nextDouble() < 0.45 ? Density.high : Density.low
              ),
      };

      city.layout.setUse(lot.id, switch (kind) {
        'commercial' => ParcelUse.commercial,
        'industrial' => ParcelUse.industrial,
        _ => ParcelUse.residential,
      });
      city.placeOnParcel(lot.id, kZoneSpecs[kind]![density]!);
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
  void _placeInstallations(CitySim city, CityGenSpec spec, math.Random rnd) {
    final big = kUtilCatalog.where((s) => s.claimsOwnSite).toList();
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
    var placed = 0;
    for (var attempt = 0; attempt < spec.installations * 40; attempt++) {
      if (placed >= spec.installations) break;
      final pick = big[rnd.nextInt(big.length)];
      final site = pick.siteMetres();
      final a = rnd.nextDouble() * math.pi * 2;
      final dir = Vec2(math.cos(a), math.sin(a));
      final cityEdge =
          _slabExit(dir, spec.extentM / 2, spec.depthExtentM / 2);
      final plotEdge = _slabExit(dir, site.width / 2, site.depth / 2);
      final at = dir * (cityEdge + plotEdge + 55);

      // Deferred re-cut: each staked plot would otherwise re-subdivide the
      // whole colony. Nothing is built yet, so nothing can be orphaned.
      if (city.claimSite(pick, at, regenerateLots: false) != null) placed++;
    }
  }

}
