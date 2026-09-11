// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/access_points.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// The building table (docs/plans/agent-traffic.md §2.6, §3.10; the rename
/// and clear seams E12–E14): every built site, with the homes and jobs the
/// tick itself counts, its access on the lane graph, and a handle that
/// stays on its building through a rename — so a trip to a lot a road edit
/// renamed still has somewhere to go.
void main() {
  /// [city]'s agents with the network and the buildings read, and no
  /// sub-step run: 0.02 s is a tenth of one.
  CityAgents primed(CitySim city) => agentsOn(city)..advance(0.02);

  test('every built site is in, with the homes and jobs the tick counts', () {
    final placed = town();
    final grown = starterKit();
    zoneAll(grown);
    growAll(grown, progress: 0.65);
    for (final city in [placed, grown]) {
      final a = primed(city);
      final b = a.buildings!;
      final net = city.parcelNetwork();
      var built = 0, halfLet = 0;
      for (final lot in [
        ...city.layout.manualParcels,
        ...city.layout.autoParcels,
      ]) {
        final placedSpec = city.parcelBuildings[lot.id];
        final spec = placedSpec ?? city.parcelGrownSpec(lot.id, lot.use);
        final h = b.handleOfSite(lot.id);
        if (spec == null) {
          expect(h, isNull, reason: '${lot.id} has nothing built');
          continue;
        }
        built++;
        expect(h, isNotNull, reason: lot.id);
        final sl = SlotPool.slotOf(h!);
        final uf = placedSpec != null ? 1.0 : city.parcelUtil(lot.id);
        expect(b.housing[sl], (spec.housing * uf).round(), reason: lot.id);
        expect(b.jobs[sl], (spec.jobs * uf).round(), reason: lot.id);
        expect(b.served[sl] == 1, net.lotServed(lot.id), reason: lot.id);
        expect(identical(b.spec[sl], spec), isTrue, reason: lot.id);
        expect(b.siteOf(h), lot.id);
        if (placedSpec == null && spec.housing > 0 && (uf - 0.5).abs() < 1e-9) {
          expect(b.housing[sl], (spec.housing / 2).round());
          halfLet++;
        }
      }
      expect(b.liveCount, built, reason: 'nothing else is in the table');
      expect(built, greaterThan(10));
      if (identical(city, grown)) {
        expect(halfLet, greaterThan(0),
            reason: 'a lot grown to 0.65 is half let, and houses half');
      }
    }
  });

  test('access is each lot\'s access point on the graph the vehicles drive',
      () {
    final a = primed(town());
    final b = a.buildings!, lg = a.laneGraph!;
    var checked = 0;
    for (var sl = 0; sl < b.highWater; sl++) {
      if (!b.isSlotLive(sl)) continue;
      final ap = AccessPoints.ofLot(lg, b.siteId[sl]);
      if (ap == null) {
        expect(b.accFwd[sl], -1);
        expect(b.accBwd[sl], -1);
        continue;
      }
      final h = b.handleOf(sl);
      expect(b.accFwd[sl], ap.fwdEdge);
      expect(b.accBwd[sl], ap.bwdEdge);
      for (final e in [ap.fwdEdge, ap.bwdEdge]) {
        if (e < 0) continue;
        final fwd = e == ap.fwdEdge;
        expect(fwd ? b.accFwdT[sl] : b.accBwdT[sl],
            closeTo(ap.sOn(lg, e), 1e-3));
        expect(fwd ? b.accFwdLane[sl] : b.accBwdLane[sl], ap.destLane(lg, e));
        expect(b.leftOf(h, e), !ap.rightOfTravel(lg, e));
      }
      checked++;
    }
    expect(checked, greaterThan(10));
  });

  test('a building the grid placed hangs on a road by the footprint rule',
      () {
    final city = town();
    final spec = kUtilCatalog.firstWhere((s) => s.cellCount == 1);
    // A cell just north-east of the crossroads.
    final half = city.grid ~/ 2;
    final anchor = (half + 1) * city.grid + (half + 1);
    city.utils[anchor] = spec;
    final a = primed(city);
    final b = a.buildings!;
    final h = b.handleOfSite(CitySim.siteIdOfCell(anchor));
    expect(h, isNotNull, reason: 'cell-$anchor is a site like any lot');
    final fp = city.parcelForCell(anchor, spec);
    final ap = AccessPoints.ofFootprint(a.laneGraph!, fp.polygon,
        centroid: fp.centroid);
    expect(ap, isNotNull);
    final sl = SlotPool.slotOf(h!);
    expect(b.accFwd[sl], ap!.fwdEdge);
    expect(b.accBwd[sl], ap.bwdEdge);
    expect(b.jobs[sl], spec.jobs);
  });

  test('a renamed lot keeps its building, and every trip that names it', () {
    final a = primed(town());
    final b = a.buildings!;
    final ids = [
      for (var sl = 0; sl < b.highWater; sl++)
        if (b.isSlotLive(sl)) b.siteId[sl],
    ];
    final x = ids[3], y = ids[4];
    final hx = b.handleOfSite(x)!, hy = b.handleOfSite(y)!;

    a.onLotsRenamed({x: 'lot-renamed'});
    expect(b.handleOfSite('lot-renamed'), hx);
    expect(b.handleOfSite(x), isNull);
    expect(b.siteOf(hx), 'lot-renamed');
    expect(b.isLive(hx), isTrue);

    // Two lots trading names keep both buildings, each under the other's.
    a.onLotsRenamed({'lot-renamed': y, y: 'lot-renamed'});
    expect(b.handleOfSite(y), hx);
    expect(b.handleOfSite('lot-renamed'), hy);
    expect(b.isLive(hx) && b.isLive(hy), isTrue);
    expect(b.renames, 3);
  });

  test('a cleared lot is gone at once; a sync tears down what the colony '
      'took away without saying', () {
    final city = town();
    final a = primed(city);
    final b = a.buildings!;
    final lots = [
      for (final p in city.layout.autoParcels)
        if (city.parcelBuildings.containsKey(p.id)) p.id,
    ];
    final hx = b.handleOfSite(lots[0])!, hy = b.handleOfSite(lots[1])!;
    city.clearParcel(lots[0]);
    a.onLotCleared(lots[0]);
    expect(b.isLive(hx), isFalse, reason: 'E14 tears it down at once');
    expect(b.isLive(hy), isTrue);

    city.clearParcel(lots[1]);
    a.advance(0.02);
    expect(b.isLive(hy), isFalse, reason: 'the next sync saw it go');
    expect(b.handleOfSite(lots[0]), isNull);
    expect(b.handleOfSite(lots[1]), isNull);
  });

  test('a job is drawn in proportion to its jobs, and never the home itself',
      () {
    final a = primed(town());
    final b = a.buildings!;
    final rng = TrafficRng(11);
    const n = 40000;
    final counts = <int, int>{};
    for (var i = 0; i < n; i++) {
      final h = b.drawJob(rng);
      counts[h] = (counts[h] ?? 0) + 1;
    }
    var total = 0;
    final jobSlots = <int>[];
    for (var sl = 0; sl < b.highWater; sl++) {
      if (b.isSlotLive(sl) && b.jobs[sl] > 0 && b.reachable(sl)) {
        total += b.jobs[sl];
        jobSlots.add(sl);
      }
    }
    expect(jobSlots.length, greaterThan(2));
    for (final sl in jobSlots) {
      expect((counts[b.handleOf(sl)] ?? 0) / n,
          closeTo(b.jobs[sl] / total, 0.015),
          reason: b.siteId[sl]);
    }
    expect(counts.length, jobSlots.length,
        reason: 'nothing without jobs, or unreachable, is ever drawn');
    final home = jobSlots.first;
    for (var i = 0; i < 2000; i++) {
      expect(b.drawJob(rng, except: home), isNot(b.handleOf(home)));
    }
  });
}
