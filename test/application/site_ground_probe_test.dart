// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
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
/// The drawn height is the plan's datum — `ptUp` less the point's own lift
/// `ptDz`, which is the kerb face and the ribbon's thickness, not ground.
void main() {
  setUpAll(registerBakedDemsForTest);

  final system = SampleWorld.realSystem();
  final earth = system.body(const BodyId('earth'))!;
  const shaper = CityTerrainShaper();

  /// Every plan point's drawn datum less the ground under it, in metres,
  /// worst first.
  List<(double, String)> probe() {
    final city = CityStarterKit.found(
      bodies: system.all.where((b) => !b.isStar).toList(),
      config: const CityConfig(
          bodyId: 'earth',
          latitude: -45.03,
          longitude: 168.66,
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
    final out = <(double, String)>[];
    for (final g in frame.chunks) {
      final c = g.plan;
      for (var k = 0; k < c.siteCount; k++) {
        final id = c.siteId(k);
        for (var p = c.ptStart(k); p < c.ptStart(k + 1); p++) {
          final at = frame.localToBodyFixed(
              c.ptE(p), c.ptN(p), g.ptUp(p) - c.ptDz(p));
          out.add((
            at.length - groundRadius(at.normalized),
            '$id ${c.ptHRef(p).name} point ${p - c.ptStart(k)} at '
                '(${c.ptE(p).toStringAsFixed(0)}, ${c.ptN(p).toStringAsFixed(0)})'
          ));
        }
        for (var s = c.stallStart(k); s < c.stallStart(k + 1); s++) {
          final at =
              frame.localToBodyFixed(c.stallE(s), c.stallN(s), g.stallUp(s));
          out.add((
            at.length - groundRadius(at.normalized),
            '$id stall ${s - c.stallStart(k)}'
          ));
        }
      }
    }
    out.sort((a, b) => b.$1.abs().compareTo(a.$1.abs()));
    return out;
  }

  test('every starter-kit plan point is within 1 cm of the ground under it',
      () {
    final offsets = probe();
    expect(offsets.length, greaterThan(200),
        reason: 'the kit publishes plans with points to probe');
    final worst = offsets.first;
    expect(worst.$1.abs(), lessThanOrEqualTo(0.01),
        reason: 'worst: ${worst.$1.toStringAsFixed(4)} m at ${worst.$2}; '
            'next: ${offsets.take(5).map((o) => "${o.$1.toStringAsFixed(3)} "
                "(${o.$2})").join(", ")}');
  });
}
