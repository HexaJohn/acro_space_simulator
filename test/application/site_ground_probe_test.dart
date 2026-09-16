// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/colony/surface_placement.dart';
import 'package:acro_space_simulator/domain/planetary/planet_surface.dart'
    show Biome;
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/register_baked_dems.dart';

/// The §6.4 probe (docs/plans/site-access.md §6.4, §8.3 R5, and R4's held
/// tick): once the starter kit is shaped, EVERY point of every plan — nodes,
/// vias, stall points, pave ring points — is drawn within a centimetre of
/// the ground under it.
///
/// On the dev colony's own site (earth, lat −45.03, lon 168.66, rolling
/// forest), which is where R4 measured the four utility sites' throats
/// standing −12.9 m to +41.6 m off an unshaped easement. R5 cuts them: this
/// is red without the cut, by tens of metres.
///
/// And on ground STEEP enough to break the cut itself: a kit founded in the
/// Alps (46.5, 8.0, 2848 m up) or the Andes (−13.2, −72.5) drops its
/// platform 90 m and 170 m over the same 56 m throat, and a corridor that
/// steep is not levelled at all by a brush that places its samples by
/// projecting onto its own rising chord — the ends cut, the middle left
/// standing hillside, the drive drawn buried in it by 77.7 m and 156.3 m.
/// `TerrainBrush.planLevel` is that repair, and these two foundings are what
/// pin it: one founding is not an invariant.
///
/// The drawn height is the plan's datum — `ptUp` less the point's own lift
/// `ptDz`, which is the kerb face and the ribbon's thickness, not ground.
void main() {
  setUpAll(registerBakedDemsForTest);

  final system = SampleWorld.realSystem();
  final earth = system.body(const BodyId('earth'))!;
  final bodies = system.all.where((b) => !b.isStar).toList();
  const shaper = CityTerrainShaper();

  /// Every plan point's drawn datum less the ground under it, in metres,
  /// worst first.
  ///
  /// [planBasis] takes "under it" in the shaper's OWN basis — the direction
  /// `CityTerrainShaper.pending` cut at — rather than under the point as the
  /// frame places it. The two differ by the frame's flat tangent plane (the
  /// note under the table in §6.4): a point `s` metres out and `u` metres up
  /// is placed `s·u/R` off in plan, which at the dev colony's own elevation
  /// is millimetres and 2848 m up in the Alps is 0.12 m — enough, on the
  /// ease at a platform's edge, to read a few centimetres of a slope that
  /// the shaping put exactly where it meant to.
  List<(double, String)> probe(double lat, double lon,
      {bool planBasis = false}) {
    final city = CityStarterKit.found(
      bodies: bodies,
      config: CityConfig(
          bodyId: 'earth',
          latitude: lat,
          longitude: lon,
          biome: Biome.forest),
      id: 'city-dev',
    )..funds = 1e6;
    final edits = InMemoryTerrainEditsRepository();
    double groundRadius(Vector3 dir) {
      final f = earth.terrainFieldWith(edits.forBody(earth.id));
      return f == null ? earth.radius : f.groundRadiusAt(dir.x, dir.y, dir.z);
    }

    // What the world tick does after the colony advances
    // (`AdvanceSimulationTick._shapeCityTerrain`), run to a fixed point.
    for (var pass = 0; pass < 3; pass++) {
      final pending = shaper.pending(city,
          bodyRadiusM: earth.radius, groundRadiusAt: groundRadius);
      if (pending.isEmpty) break;
      for (final p in pending) {
        edits.record(earth.id, p.brush);
        CityTerrainShaper.markShaped(city, p.key, p.brush);
      }
    }

    final snap = WorldSnapshot.capture(1, InMemoryVesselRepository(const []),
        system: system,
        cities: InMemoryCityRepository([city]),
        terrainEdits: edits);
    expect(snap.sites, hasLength(1), reason: 'the colony publishes plans');
    final frame = snap.sites.single;
    const placement = SurfacePlacement();
    final latRad = city.cityLat * math.pi / 180.0;
    final lonRad = city.cityLon * math.pi / 180.0;

    /// The drawn radius of local (e, n) at [up] over the frame's datum, and
    /// the direction the ground is asked along under it.
    (double, Vector3) at(double e, double n, double up) {
      final placed = frame.localToBodyFixed(e, n, up);
      if (!planBasis) return (placed.length, placed.normalized);
      return (
        frame.datumRadiusM + up,
        placement
            .place(
                radius: earth.radius,
                lat: latRad,
                lon: lonRad,
                east: e,
                north: n)
            .position
            .normalized,
      );
    }

    final out = <(double, String)>[];
    for (final g in frame.chunks) {
      final c = g.plan;
      for (var k = 0; k < c.siteCount; k++) {
        final id = c.siteId(k);
        for (var p = c.ptStart(k); p < c.ptStart(k + 1); p++) {
          final (r, dir) =
              at(c.ptE(p), c.ptN(p), g.ptUp(p) - c.ptDz(p));
          out.add((
            r - groundRadius(dir),
            '$id ${c.ptHRef(p).name} point ${p - c.ptStart(k)} at '
                '(${c.ptE(p).toStringAsFixed(0)}, ${c.ptN(p).toStringAsFixed(0)})'
          ));
        }
        for (var s = c.stallStart(k); s < c.stallStart(k + 1); s++) {
          final (r, dir) = at(c.stallE(s), c.stallN(s), g.stallUp(s));
          out.add((
            r - groundRadius(dir),
            '$id stall ${s - c.stallStart(k)}'
          ));
        }
      }
    }
    out.sort((a, b) => b.$1.abs().compareTo(a.$1.abs()));
    return out;
  }

  String worstOf(List<(double, String)> offsets) =>
      'worst: ${offsets.first.$1.toStringAsFixed(4)} m at '
      '${offsets.first.$2}; next: ${offsets.skip(1).take(4).map((o) =>
          "${o.$1.toStringAsFixed(3)} (${o.$2})").join(", ")}';

  test('every starter-kit plan point is within 1 cm of the ground under it',
      () {
    final offsets = probe(-45.03, 168.66);
    expect(offsets.length, greaterThan(200),
        reason: 'the kit publishes plans with points to probe');
    expect(offsets.first.$1.abs(), lessThanOrEqualTo(0.01),
        reason: worstOf(offsets));
  });

  test('and on ground steep enough to break the cut: every plan point is '
      'within 1 cm of the ground the shaper cut under it', () {
    for (final (name, lat, lon) in const [
      ('the Alps', 46.5, 8.0),
      ('the Andes', -13.2, -72.5),
      ('the plains', 40.0, -100.0),
    ]) {
      final offsets = probe(lat, lon, planBasis: true);
      expect(offsets.length, greaterThan(200), reason: name);
      expect(offsets.first.$1.abs(), lessThanOrEqualTo(0.01),
          reason: '$name: ${worstOf(offsets)}');
    }
  });

  test('and drawn where the frame places it, a steep kit is off only by the '
      'frame\'s own flat tangent basis', () {
    // The same two foundings measured under the DRAWN point (§6.4's note):
    // the plan error `s·u/R` is 0.12 m in the Alps and 0.4 m in the Andes,
    // and on the ease at a platform's edge that reads as a few centimetres
    // of height. Bounded here so that the shaping failure this replaced —
    // tens of metres — cannot hide behind the basis.
    for (final (name, lat, lon) in const [
      ('the Alps', 46.5, 8.0),
      ('the Andes', -13.2, -72.5),
    ]) {
      final offsets = probe(lat, lon);
      expect(offsets.first.$1.abs(), lessThanOrEqualTo(0.25),
          reason: '$name: ${worstOf(offsets)}');
    }
  });
}
