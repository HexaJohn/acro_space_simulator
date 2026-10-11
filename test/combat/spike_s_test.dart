// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/colony/city/city_war.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart' show Vec2;
import 'package:acro_space_simulator/domain/combat/combat_rng.dart';
import 'package:acro_space_simulator/domain/combat/launch/base_layout.dart';
import 'package:acro_space_simulator/domain/combat/live/battle_raster.dart';
import 'package:acro_space_simulator/domain/combat/live/nav_grid.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/ground_sample_pool.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/register_baked_dems.dart';

/// Spike S, the headless items (docs/plans/combat.md §7F): item 6 (socket
/// room and fit) and item 1 (the battle raster's per-cell cost) on settled
/// starter towns. Measurements first: the results are written into the plan;
/// the asserts hold the lines that passed, so a regression is seen.
void main() {
  setUpAll(registerBakedDemsForTest);

  final system = SampleWorld.realSystem();
  final bodies = system.all.where((b) => !b.isStar).toList();
  const shaper = CityTerrainShaper();

  ({CitySim city, InMemoryTerrainEditsRepository edits, CelestialBody body}) town(String bodyId,
      {double lat = 10, double lon = 20}) {
    final body = system.body(BodyId(bodyId))!;
    final city = CityStarterKit.found(
      bodies: bodies,
      config: CityConfig(bodyId: bodyId, latitude: lat, longitude: lon),
      id: 'spike-$bodyId',
    );
    final edits = InMemoryTerrainEditsRepository();
    double ground(Vector3 dir) {
      final f = body.terrainFieldWith(edits.forBody(body.id));
      return f == null ? body.radius : f.groundRadiusAt(dir.x, dir.y, dir.z);
    }

    for (var pass = 0; pass < 3; pass++) {
      final pending = shaper.pending(city, bodyRadiusM: body.radius, groundRadiusAt: ground);
      if (pending.isEmpty) break;
      for (final p in pending) {
        edits.record(body.id, p.brush);
        CityTerrainShaper.markShaped(city, p.key, p.brush);
      }
    }
    city.loyalty.allegiance = Allegiance.independent;
    return (city: city, edits: edits, body: body);
  }

  const towns = [('moon', 10.0, 20.0), ('mars', 18.0, 77.0), ('earth', -45.03, 168.66)];

  test('item 6: socket room at the best LZ, the fit in one square, outpost ground', () {
    final lines = <String>[];
    for (final (b, lat, lon) in towns) {
      final t = town(b, lat: lat, lon: lon);
      final s = t.city.launchSnapshot();
      final port = s.objectives.where((o) => o.kind == 'port').firstOrNull;
      final goal = s.objectives.where((o) => o.kind == 'seat').firstOrNull ?? port!;
      final anchor = port ?? goal;
      final l = layoutBase(anchorE: anchor.e, anchorN: anchor.n, obstacles: s.obstacles, pads: s.pads);
      final freeM = kLayoutModuleSockets - l.blockedModules.length;
      final freeT = kLayoutTurretSockets - l.blockedTurrets.length;
      // The fit: the LZ's whole turret ring (87 m) and 100 m of the goal in
      // one square, centred between them.
      final gap = math.sqrt(math.pow(l.e - goal.e, 2) + math.pow(l.n - goal.n, 2));
      bool fits(double side) => gap + kTurretRingM + 12 + 100 <= side;
      // Outpost ground: clear 2 + 1 sockets beside each objective.
      var outposts = 0;
      final distinct = <String>[];
      for (final o in s.objectives) {
        if (distinct.contains('${o.e},${o.n}')) continue;
        distinct.add('${o.e},${o.n}');
        if (outpostGround(o.e, o.n, s.obstacles) != null) outposts++;
      }
      lines.add('$b: LZ ${l.distanceM.round()} m out, $freeM/7 module + $freeT/4 turret free; '
          'LZ→goal ${gap.round()} m, fit 1.2 km ${fits(1200)}, 800 m ${fits(800)}, 600 m ${fits(600)}; '
          'outpost ground at $outposts of ${distinct.length} distinct objectives');
      expect(freeM, greaterThanOrEqualTo(5), reason: '$b module sockets');
      expect(freeT, 4, reason: '$b turret sockets');
      expect(fits(1200), isTrue, reason: '$b fits 1.2 km');
    }
    // ignore: avoid_print
    print('Spike S item 6:\n  ${lines.join('\n  ')}');
  });

  test('item 2: squads walk to their objectives on a real town; at most 1 stuck in 20 runs', () {
    final t = town('moon');
    final s = t.city.launchSnapshot();
    final field = t.body.terrainFieldWith(t.edits.forBody(t.body.id))!;
    final port = s.objectives.where((o) => o.kind == 'port').firstOrNull ?? s.objectives.first;
    final l = layoutBase(anchorE: port.e, anchorN: port.n, obstacles: s.obstacles, pads: s.pads);
    final (ce, cn) = BattleRaster.centreFor(l.e, l.n, port.e, port.n);
    final raster = BattleRaster(ce, cn);
    final dirs = Float64List(raster.radii.length * 3);
    for (var k = 0; k < raster.radii.length; k++) {
      final (e, n) = raster.cellCentre(k);
      final bf = t.city.localToBodyFixed(Vec2(e, n), bodyRadiusM: t.body.radius);
      dirs[3 * k] = bf.x;
      dirs[3 * k + 1] = bf.y;
      dirs[3 * k + 2] = bf.z;
    }
    final radii = sampleGround(field, dirs);
    for (var k = 0; k < radii.length; k++) {
      raster.put(k, radii[k]);
    }
    final nav = NavGrid(raster, s.walls);
    // Three objectives in the square: the town's own that fall inside, made
    // up to three with open ground in its far corners.
    final goals = <(double, double)>[
      for (final o in s.objectives)
        if (raster.contains(o.e, o.n)) (o.e, o.n),
    ];
    for (final (fx, fy) in const [(-0.35, 0.35), (0.35, -0.35), (-0.35, -0.35)]) {
      if (goals.length >= 3) break;
      final k = nav.cellOf(ce + fx * raster.sideM, cn + fy * raster.sideM);
      if (k != null && nav.blocked[k] == 0) goals.add(raster.cellCentre(k));
    }
    expect(goals.length, 3);
    var stuck = 0, runs = 0;
    for (var seed = 0; seed < 20; seed++) {
      for (var q = 0; q < 4; q++) {
        runs++;
        final goal = goals[(seed + q) % goals.length];
        final fieldTo = nav.flowTo('g${goal.$1},${goal.$2}', goal.$1, goal.$2);
        // Six soldiers within 60 m of the LZ, on open ground.
        final squad = <(double, double)>[];
        for (var m = 0; squad.length < 6 && m < 60; m++) {
          final e = l.e + 120 * (combatUnit(seed, q * 64 + m, 1) - 0.5);
          final n = l.n + 120 * (combatUnit(seed, q * 64 + m, 2) - 0.5);
          final k = nav.cellOf(e, n);
          if (k != null && nav.blocked[k] == 0) squad.add((e, n));
        }
        double left() {
          var sum = 0.0;
          for (final p in squad) {
            final k = nav.cellOf(p.$1, p.$2);
            final d = k == null ? double.infinity : fieldTo[k];
            sum += d.isFinite ? d : 2000;
          }
          return sum / squad.length;
        }

        var best = left();
        var sinceProgress = 0.0;
        var arrived = false;
        for (var step = 0; step < 1200; step++) {
          for (var i = 0; i < squad.length; i++) {
            final p = squad[i];
            final d = math.sqrt(math.pow(goal.$1 - p.$1, 2) + math.pow(goal.$2 - p.$2, 2));
            if (d < 15) continue;
            final next = d > 20 && !nav.lineOfSight((p.$1, p.$2, 1.0), (goal.$1, goal.$2, 1.0))
                ? nav.step(fieldTo, p.$1, p.$2, 2.5 * 0.25, goal)
                : NavGrid.straight(p.$1, p.$2, goal.$1, goal.$2, 2.5 * 0.25);
            if (next != null) squad[i] = next;
          }
          final now = left();
          if (now < 25) {
            arrived = true;
            break;
          }
          if (now < best - 1) {
            best = now;
            sinceProgress = 0;
          } else {
            sinceProgress += 0.25;
            if (sinceProgress >= 30) break;
          }
        }
        if (!arrived && sinceProgress >= 30) stuck++;
      }
    }
    // ignore: avoid_print
    print('Spike S item 2: $stuck stuck of $runs squad walks (20 seeds × 4 squads), '
        '${nav.built} flow fields built');
    expect(stuck, lessThanOrEqualTo(1));
  });

  test('item 1: the raster\'s per-cell query over a 1.2 km square at 8 m', () {
    final lines = <String>[];
    for (final (b, lat, lon) in towns) {
      final t = town(b, lat: lat, lon: lon);
      final edits = t.edits.forBody(t.body.id);
      final field = t.body.terrainFieldWith(edits);
      if (field == null) {
        lines.add('$b: no terrain field (a sphere): nothing to bake');
        continue;
      }
      const n = 150, cell = 8.0;
      var brushed = 0;
      final sw = Stopwatch()..start();
      // Warm the field (DEM tiles, noise tables) first.
      field.surfaceRadiusAt(1, 0, 0);
      sw.reset();
      var cells = 0;
      for (var i = 0; i < n; i += 3) {
        for (var j = 0; j < n; j += 3) {
          final d = t.city
              .localToBodyFixed(Vec2(-600 + (i + 0.5) * cell, -600 + (j + 0.5) * cell), bodyRadiusM: t.body.radius)
              .normalized;
          if (edits != null && edits.at(d).isNotEmpty) brushed++;
          field.surfaceRadiusAt(d.x, d.y, d.z);
          cells++;
        }
      }
      sw.stop();
      final perMs = sw.elapsedMicroseconds / 1000 / cells;
      final single = perMs * n * n / 1000;
      lines.add('$b: ${t.edits.forBody(t.body.id)?.length ?? 0} brushes, '
          '${(100 * brushed / cells).round()}% of cells under one; ${perMs.toStringAsFixed(3)} ms a cell (JIT) '
          '→ ${single.toStringAsFixed(1)} s one thread, ${(single / 4).toStringAsFixed(1)} s on 4 workers');
      expect(single / 4, lessThan(90), reason: '$b bakes 1.2 km on a 4-worker pool within 90 s');
    }
    // ignore: avoid_print
    print('Spike S item 1:\n  ${lines.join('\n  ')}');
  });
}
