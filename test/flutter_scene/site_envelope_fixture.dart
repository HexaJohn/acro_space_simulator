// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The colony R4's placement tests draw (docs/plans/site-access.md §8.3 R4).
///
/// The site town of the wire tests, plus the two cases §3.1 says only R4 can
/// turn: a FRONTAGE-LESS claimed site (its plan finds the road it really
/// fronts) and a GRID CELL (whose stored north edge is fake). Every plan is
/// drained before the fixture returns, so a capture sees them all.
library;

import 'dart:math' as math;

import 'package:acro_space_simulator/application/snapshot/city_site_frame.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/architecture/architecture_style.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/architecture/building_massing.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_book.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/surface_placement.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/coord_convert.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../application/site_town_fixture.dart';
import '../traffic/traffic_fixture.dart';

/// A works, so the fixture carries an `i-med` massing as well as the homes
/// and shops the streets grow.
final CityBuildingSpec envelopeWorks =
    kZoneSpecs['industrial']![Density.medium]!;

/// The shop the fixture builds beside the houses.
final CityBuildingSpec envelopeShop =
    kZoneSpecs['commercial']![Density.low]!;

/// The utility the fixture stands on a grid cell.
final CityBuildingSpec envelopeCellSpec =
    kUtilCatalog.firstWhere((s) => s.type == 'water');

/// The installation the fixture claims a plot for, with NO stored frontage.
final CityBuildingSpec envelopeClaimSpec =
    kUtilCatalog.firstWhere((s) => s.type == 'aquifer');

/// The id of the claimed site, once [envelopeTown] has made one.
String? envelopeClaimedId;

/// The grid cell the fixture stands [envelopeCellSpec] on.
int? envelopeCell;

/// The id of the lot whose plan has NO envelope, once [envelopeTown] has made
/// one: a published plan with nothing to stand on, which is legacy on both
/// sides of the knob (§5.2).
String? envelopeNoEnvelopeId;

/// The site town, with a shop, a works, a frontage-less claimed plot and a
/// grid-cell utility added, every plan drained.
CitySim envelopeTown() {
  final city = siteTown();
  city
    ..funds = 1e12
    ..ignoreUnlocks = true
    ..stock['ore'] = 5e6;

  // One more street, with a shop and a works on its own lots, so the fixture
  // carries a c-low and an i-med massing beside the r-low houses.
  final id = commit(
      city, const FixtureRoad([Vec2(-300, 400), Vec2(300, 400)]));
  var placed = 0;
  for (final p in city.layout.autoParcels) {
    if (p.roadId != id || city.parcelBuildings.containsKey(p.id)) continue;
    city.placeOnParcel(p.id, placed.isEven ? envelopeShop : envelopeWorks);
    if (++placed >= 6) break;
  }

  // A claimed plot with no frontage of its own: its plan has to find the
  // road it fronts, and R4 turns the building onto it (§10.2 Q10).
  final claimed = _claim(city);
  envelopeClaimedId = claimed?.id;

  // And a grid-cell utility, whose stored north edge is fake.
  envelopeCell = _cell(city);

  // A lot whose stored frontage is 2.5 m wide: the site frame is that wide,
  // so no rectangle fits inside the side setbacks and the plan is published
  // with an EMPTY envelope. Such a site has nothing to stand on, so it is
  // legacy on BOTH sides of the knob (§5.2) — this is the fixture that says
  // so.
  envelopeNoEnvelopeId = _narrowFrontage(city)?.id;

  city.advance(0.5);
  final done = city.siteAccess.sync(city, city.roadGraph,
      maxUnits: SiteAccessBook.unlimited, maxChecks: SiteAccessBook.unlimited);
  if (!done) throw StateError('the envelope town did not drain');
  return city;
}

/// Claims a frontage-less plot somewhere clear, or null when nothing takes.
/// Swept rather than placed by hand: what matters is that the plot has no
/// stored frontage and a road within reach, not where it ends up.
Parcel? _claim(CitySim city) {
  for (var n = 500.0; n <= 1400; n += 100) {
    for (var e = -1200.0; e <= 1200; e += 200) {
      final lot = city.claimSite(envelopeClaimSpec, Vec2(e, n));
      if (lot != null) return lot;
    }
  }
  return null;
}

/// Stakes a 30 m lot with a 2.5 m stored FRONTAGE near the north street and
/// builds on it, or null when nothing takes. The site frame is as wide as the
/// frontage, so `largestFreeRect` finds nothing inside the 1.5 m side
/// setbacks and the kerbside plan carries `SiteEnvelope.empty` (§6.1).
Parcel? _narrowFrontage(CitySim city) {
  for (var n = 405.0; n <= 600; n += 15) {
    for (var e = -300.0; e <= 400; e += 25) {
      final poly = [
        Vec2(e, n),
        Vec2(e + 30, n),
        Vec2(e + 30, n + 30),
        Vec2(e, n + 30),
      ];
      final mid = e + 15;
      final p = city.layout.addManualParcel(poly,
          frontage: (Vec2(mid - 1.25, n), Vec2(mid + 1.25, n)));
      if (p == null) continue;
      if (city.placeOnParcel(p.id, envelopeShop)) return p;
    }
  }
  return null;
}

/// Stands the cell utility on the empty cell NEAREST a road, so its plan has
/// a frontage to find, and returns it (null if none took).
int? _cell(CitySim city) {
  final half = city.grid ~/ 2;
  int? best;
  var bestD = double.infinity;
  for (var gy = -half; gy < half; gy++) {
    for (var gx = -half; gx < half; gx++) {
      final k = (gx + half) + (gy + half) * city.grid;
      if (city.zones.containsKey(k) ||
          city.utils.containsKey(k) ||
          city.roads.contains(k) ||
          city.anchorOf(k) != null) {
        continue;
      }
      final at = Vec2((gx + 0.5) * CitySim.cellM, (gy + 0.5) * CitySim.cellM);
      for (final road in city.layout.roads) {
        for (final p in road.sample(stepM: 8)) {
          final d = p.distanceTo(at);
          if (d < bestD) {
            bestD = d;
            best = k;
          }
        }
      }
    }
  }
  if (best == null) return null;
  city.placeUtil(best, envelopeCellSpec);
  return best;
}

/// One drawn colony: the plans, the frame, and the library the tiles would
/// build from, so a test can ask where a building's door, gate or walls
/// actually LAND in colony-local metres.
class EnvelopeScene {
  EnvelopeScene(this.city, this.snapshot, this.style, {this.bucketM = 6})
      : libraries = CityBuildingLibraries()..sync(style.id, bucketM, 4) {
    final basis = const SurfacePlacement()
        .place(
          radius: 1,
          lat: city.cityLat * math.pi / 180.0,
          lon: city.cityLon * math.pi / 180.0,
        )
        .orientation;
    east = basis.rotate(Vector3.unitX);
    north = basis.rotate(Vector3.unitY);
    toColony = basis.conjugate;
  }

  /// [city] captured with the envelope knob ON, in [style].
  factory EnvelopeScene.of(CitySim city, ArchitectureStyle style,
      {double bucketM = 6}) {
    SiteCapture.envelopePlacement = true;
    try {
      return EnvelopeScene(city, captureSiteTown(city), style,
          bucketM: bucketM);
    } finally {
      SiteCapture.envelopePlacement = false;
    }
  }

  final CitySim city;
  final WorldSnapshot snapshot;
  final ArchitectureStyle style;
  final double bucketM;
  final CityBuildingLibraries libraries;

  late final Vector3 east, north;

  /// Body-fixed to colony-local rotation (the tangent basis' conjugate).
  late final Quaternion toColony;

  /// Every building of this colony, in id order.
  List<BuildingSnapshot> get buildings {
    final out = [
      for (final b in snapshot.buildings.values)
        if (b.colonyId == city.id) b,
    ];
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  /// [b]'s plan, or null when it is legacy.
  SiteAccessPlan? planOf(BuildingSnapshot b) => b.siteSlot < 0
      ? null
      : city.siteAccess.planOf(
          int.tryParse(b.id) == null
              ? b.id
              : CitySim.siteIdOfCell(int.parse(b.id)));

  /// The plan brief [b] is drawn from with the knob on.
  SiteGate? gateOf(BuildingSnapshot b) =>
      CityTileMesher.gateOf(b, siteAccess: true);

  /// The massing the tiles draw [b] from at [tier].
  GeneratedBuilding builtOf(BuildingSnapshot b,
          [BuildingDetail tier = BuildingDetail.full]) =>
      libraries.forTier(tier).get(
          CityTileMesher.specOf(b), CityTileMesher.parcelOf(b, style),
          seed: b.id.hashCode, detail: tier, gate: gateOf(b));

  /// The massing the tiles would draw [b] from with the knob OFF: the
  /// legacy path, whatever its plan says.
  GeneratedBuilding legacyBuiltOf(BuildingSnapshot b,
          [BuildingDetail tier = BuildingDetail.full]) =>
      libraries.forTier(tier).get(
          CityTileMesher.specOf(b), CityTileMesher.parcelOf(b, style),
          seed: b.id.hashCode, detail: tier);

  /// Colony-local east/north of body-fixed [p]. The tangent basis is
  /// orthonormal, so the radius falls out of both dot products.
  Vec2 localOf(Vector3 p) => Vec2(p.dot(east), p.dot(north));

  /// Where building-local ([x], [y]) on [b] lands, colony-local metres:
  /// exactly the transform the tiles instance it with.
  Vec2 drawn(BuildingSnapshot b, double x, double y,
      [BuildingDetail tier = BuildingDetail.full]) {
    final anchor = Vector3(b.px, b.py, b.pz);
    final m = CityTileMesher.instanceTransform(anchor, b,
        gate: gateOf(b),
        style: style,
        bucketM: libraries.forTier(tier).bucketM);
    final s = m.transform3(vm.Vector3(x, y, 0));
    return localOf(anchor +
        Vector3(s.x / kRenderScale, s.y / kRenderScale, s.z / kRenderScale));
  }

  /// [b]'s local axes in colony-local east/north: +X along the frontage and
  /// +Y into the lot.
  (Vec2, Vec2) axesOf(BuildingSnapshot b) {
    final q = Quaternion(b.qw, b.qx, b.qy, b.qz);
    final x = toColony.rotate(q.rotate(Vector3.unitX));
    final y = toColony.rotate(q.rotate(Vector3.unitY));
    return (Vec2(x.x, x.y), Vec2(y.x, y.y));
  }
}

/// Helpers that need a building's SITE, which is not always its own id.
extension EnvelopeSites on EnvelopeScene {
  /// The site id of [b]: its lot id, or `cell-<k>` for a grid building,
  /// whose snapshot id is the bare cell key.
  String siteIdOf(BuildingSnapshot b) {
    final cell = int.tryParse(b.id);
    return cell == null ? b.id : CitySim.siteIdOfCell(cell);
  }

  /// [b]'s colony-local position, as placed.
  Vec2 positionOf(BuildingSnapshot b) =>
      localOf(Vector3(b.px, b.py, b.pz));

  /// The MESH's own front edge for [b] at [tier], in its local metres: what
  /// the instance shift maps onto the envelope's real front edge. It is the
  /// entrance's y by construction on a plan-served massing (§6.2).
  double frontEdgeOf(BuildingSnapshot b,
          [BuildingDetail tier = BuildingDetail.full]) =>
      builtOf(b, tier).massing.entrance.$2;
}
