// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// `site_access_tick_order_test` (docs/plans/site-access.md §4.1, §8.3 R2):
/// `siteAccess.sync` runs inside `CitySim.advance` before
/// `roadTraffic.advance` and `agents.advance`; a plan made this tick is
/// visible to the agents this tick; `isCurrentFor` flips false on a road edit
/// and true after the re-check, identically in a headless run and a rendered
/// one (a world capture between the ticks), and the two runs' plans stay
/// byte-identical.
library;

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';
import 'site_access_book_fixtures.dart';

void main() {
  test('the book syncs before the routed traffic and the agents', () {
    final city = starterKit(agentTraffic: true);
    final phases = <String>[];
    city.debugTickProbe = phases.add;
    city.advance(0.5);
    expect(phases, ['siteAccess.sync', 'roadTraffic.advance', 'agents.advance']);
  });

  test('a plan made this tick is visible to the agents this tick', () {
    final city = starterKit(agentTraffic: true);
    final g = city.roadGraph;
    final crossed = {for (final lot in g.joinCrossLot) g.lotIds[lot]};
    final lot = freeLots(city).firstWhere((p) => !crossed.contains(p.id));
    expect(city.placeOnParcel(lot.id, house), isTrue);
    expect(city.siteAccess.planOf(lot.id), isNull);
    bool? seen;
    city.debugTickProbe = (phase) {
      if (phase == 'agents.advance') {
        seen = city.siteAccess.isCurrentFor(lot.id, city.roadGraph);
      }
    };
    city.advance(0.5);
    expect(seen, isTrue);
  });

  test('isCurrentFor flips on a road edit and back after the re-check, the '
      'same headless and rendered', () {
    final system = SampleWorld.realSystem();
    List<Object> trace(bool rendered) {
      final city = town();
      houseStreet(city, const [Vec2(1500, -150), Vec2(1500, 150)]);
      // The built lots that store a plan (a lot with no join slot stores
      // none, and is never current).
      final ids = <String>[];
      final out = <Object>[];
      void step() {
        city.advance(0.5);
        if (rendered) {
          WorldSnapshot.capture(
            0,
            InMemoryVesselRepository(const []),
            system: system,
            cities: InMemoryCityRepository([city]),
          );
        }
        final g = city.roadGraph;
        out.add([
          for (final id in ids)
            if (city.layout.parcelById(id) != null)
              city.siteAccess.isCurrentFor(id, g),
        ]);
        out.add(city.siteAccess.sitesRev);
      }

      // Budgeted ticks (128 units) until the new street's houses are planned.
      void settle() {
        var n = 0;
        do {
          step();
          expect(++n, lessThan(40));
        } while (!city.siteAccess.lastSync.complete);
      }

      settle();
      for (final (p, _) in city.parcelBuiltLots()) {
        if (city.siteAccess.planOf(p.id) != null) ids.add(p.id);
      }
      final before = out.length;
      commit(city, const FixtureRoad([Vec2(1650, -150), Vec2(1650, 150)]));
      final g = city.roadGraph;
      // Before any tick: every plan was resolved against the old structure.
      final off = [
        for (final id in ids)
          if (city.layout.parcelById(id) != null)
            city.siteAccess.isCurrentFor(id, g),
      ];
      settle();
      final on = [
        for (final id in ids)
          if (city.layout.parcelById(id) != null)
            city.siteAccess.isCurrentFor(id, g),
      ];
      return [
        ids,
        off,
        on,
        out.sublist(0, before),
        out.sublist(before),
        copyOf(city.siteAccess.chunks.first),
      ];
    }

    final headless = trace(false), rendered = trace(true);
    expect((headless[0] as List).length, greaterThan(60));
    expect(headless[1] as List, everyElement(isFalse));
    expect(headless[2] as List, everyElement(isTrue));
    expect((headless[1] as List).length, greaterThan(60));
    for (var i = 0; i < headless.length - 1; i++) {
      expect(rendered[i], headless[i], reason: 'part $i');
    }
    final a = headless.last as List<List>, b = rendered.last as List<List>;
    for (var i = 0; i < a.length; i++) {
      expect(b[i], a[i]);
    }
  });
}
