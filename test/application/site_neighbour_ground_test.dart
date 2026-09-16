// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_book.dart';
import 'package:acro_space_simulator/domain/colony/surface_placement.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/register_baked_dems.dart';

/// A site's corridor must never BURY a neighbour (docs/plans/site-access.md
/// §6.3, the R5 review round 2).
///
/// The §6.4 probe (site_ground_probe_test) asks whether a plan is drawn on
/// the ground; it is measured on the starter kit, where the five sites stand
/// far apart. A generated town stands them shoulder to shoulder, and there
/// the corridor brush's EASE was the hazard: it ran a full `roadFalloffM`
/// past the levelled width, reached across the lot line, and moved ground a
/// neighbour's paving is still drawn on its own pad datum. Nothing re-cuts
/// that neighbour afterwards — the site section records each lot's `sitepad:`
/// re-cut BEFORE the corridors — so the neighbour stayed buried.
///
/// The measure is an A/B against the town's OWN shaping with only the
/// `site:` corridor brushes withheld from the ground: the same plans, the
/// same drawn heights (a graded lot's points are drawn from `padDatums` and
/// `corridorDatums`, never from the ground — §6.4), so the only thing that
/// moves between the two sides is the ground under the point. A corridor may
/// pull a point ONTO the ground — that is what it is for, and the site's own
/// throat goes from tens of metres off to millimetres — but it may not push
/// any graded lot's point further off than it already was.
void main() {
  setUpAll(registerBakedDemsForTest);

  final system = SampleWorld.realSystem();
  final earth = system.body(const BodyId('earth'))!;
  final bodies = system.all.where((b) => !b.isStar).toList();
  const shaper = CityTerrainShaper();

  /// Every graded lot's plan point on a town of [blocks] blocks founded at
  /// the dev colony's own site, as (how much worse the site corridors left
  /// it, its offset with them, its offset without them, where it is).
  ///
  /// Worst first. Positive "worse" is ground the corridors moved AWAY from
  /// the paving drawn over it.
  List<(double, double, double, String)> probe(int blocks) {
    final town = const CityGenerator().generate(
        CityGenSpec(
            blocksAcross: blocks,
            seed: 1,
            sprawlMiles: 2,
            latitude: -45.03,
            longitude: 168.66),
        bodies: bodies);
    town.siteAccess.sync(town, town.roadGraph,
        maxUnits: SiteAccessBook.unlimited, maxChecks: SiteAccessBook.unlimited);

    // The same shaping recorded into two grounds: everything, and everything
    // but the `site:` corridors. The town's own bookkeeping — `shapedTerrain`,
    // `padDatums`, `corridorDatums`, `siteCutRev` — is the full one either
    // way, so both sides draw identically and only the ground differs.
    final full = InMemoryTerrainEditsRepository();
    final noCorridor = InMemoryTerrainEditsRepository();
    for (var pass = 0; pass < 3; pass++) {
      final field = earth.terrainFieldWith(full.forBody(earth.id));
      final pending = shaper.pending(town,
          bodyRadiusM: earth.radius,
          groundRadiusAt: (d) => field == null
              ? earth.radius
              : field.groundRadiusAt(d.x, d.y, d.z));
      if (pending.isEmpty) break;
      for (final p in pending) {
        full.record(earth.id, p.brush);
        if (!p.key.startsWith('site:')) noCorridor.record(earth.id, p.brush);
        CityTerrainShaper.markShaped(town, p.key, p.brush);
      }
    }
    final fieldFull = earth.terrainFieldWith(full.forBody(earth.id));
    final fieldNone = earth.terrainFieldWith(noCorridor.forBody(earth.id));
    double groundOn(TerrainField? f, Vector3 dir) =>
        f == null ? earth.radius : f.groundRadiusAt(dir.x, dir.y, dir.z);

    final snap = WorldSnapshot.capture(1, InMemoryVesselRepository(const []),
        system: system,
        cities: InMemoryCityRepository([town]),
        terrainEdits: full);
    final frame = snap.sites.single;
    const placement = SurfacePlacement();
    final latRad = town.cityLat * math.pi / 180.0;
    final lonRad = town.cityLon * math.pi / 180.0;
    Vector3 dirOf(double e, double n) => placement
        .place(
            radius: earth.radius,
            lat: latRad,
            lon: lonRad,
            east: e,
            north: n)
        .position
        .normalized;

    final out = <(double, double, double, String)>[];
    void measure(double e, double n, double up, String where) {
      final dir = dirOf(e, n);
      final r = frame.datumRadiusM + up;
      final withIt = (r - groundOn(fieldFull, dir)).abs();
      final without = (r - groundOn(fieldNone, dir)).abs();
      out.add((withIt - without, withIt, without, where));
    }

    for (final g in frame.chunks) {
      final c = g.plan;
      for (var k = 0; k < c.siteCount; k++) {
        final id = c.siteId(k);
        if (town.layout.parcelById(id)?.graded != true) continue;
        for (var p = c.ptStart(k); p < c.ptStart(k + 1); p++) {
          measure(
              c.ptE(p),
              c.ptN(p),
              g.ptUp(p) - c.ptDz(p),
              '$id ${c.ptHRef(p).name} pt ${p - c.ptStart(k)} at '
                  '(${c.ptE(p).toStringAsFixed(0)}, '
                  '${c.ptN(p).toStringAsFixed(0)})');
        }
        for (var s = c.stallStart(k); s < c.stallStart(k + 1); s++) {
          measure(c.stallE(s), c.stallN(s), g.stallUp(s),
              '$id stall ${s - c.stallStart(k)}');
        }
      }
    }
    expect(out.length, greaterThan(200),
        reason: 'a $blocks-block town publishes graded plans to probe');
    out.sort((a, b) => b.$1.compareTo(a.$1));
    return out;
  }

  String worstOf(List<(double, double, double, String)> rows) {
    final worse = rows.where((r) => r.$1 > _tolM).length;
    return 'worse: $worse of ${rows.length} points; '
        '${rows.take(4).map((r) => "${r.$4}: "
            "${r.$3.toStringAsFixed(3)} m -> ${r.$2.toStringAsFixed(3)} m "
            "(+${r.$1.toStringAsFixed(3)})").join("; ")}';
  }

  for (final blocks in const [2, 4]) {
    test('a $blocks-block town: no graded lot is left further off the ground '
        'by the site corridors than it was without them', () {
      final rows = probe(blocks);
      expect(rows.first.$1, lessThanOrEqualTo(_tolM), reason: worstOf(rows));
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}

/// A millimetre, which is twenty times the residual the repaired shaper
/// leaves (0.055 mm on the 2-block town, 0.068 mm on the 4-block) and a
/// thousandth of what it left before it (1.248 m and 41.044 m).
const double _tolM = 0.001;
