// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A7 as whole trips (docs/plans/site-access.md §7.9 A7; agent-traffic.md
/// §7.3 D17 steps 1–2): three cars drive to one two-stall home pad. Two are
/// granted at its gate and park on its stalls; the third finds the lot full
/// on arrival, never crosses the kerb at all, and takes an unmasked kerb slot
/// ahead on the edge it arrived along.
///
/// `lot_full_goes_to_kerb_test` pins the same rule on the tables alone
/// (package D). This is the facade's half: the trips are real trips, the
/// stalls are reserved at the gate by `CityAgents.arrived`, and the kerb slot
/// is the one D17 step 2 reserved for that very car.
library;

import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/access_events.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/parked_cars.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_vehicles.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import '../colony/site_access/site_plan_fixtures.dart';
import 'site_fixture.dart';
import 'traffic_fixture.dart';

void main() {
  setUp(() => AgentTuning.commuteRatePerResident = 0);
  tearDown(AgentTuning.reset);

  test('two stalls, three trips: two park on the pad, the third never enters '
      'and takes an unmasked kerb slot ahead', () {
    final city = town();
    final a = agentsOn(city);
    final lot = lotOf(SyntheticTemplate.home);
    a.debugPlans =
        FixturePlanSource(city.roadGraph, {lot: SyntheticTemplate.home});

    // Three trips to the pad, from three different lots so their routes are
    // their own. They are one-way, so nothing ever leaves the stalls again.
    final from = _origins(city, lot, 3);
    final trips = [for (final f in from) a.forceTrip(f, lot)];
    expect(trips, everyElement(isNot(SlotPool.none)));

    final sites = a.sites!;
    final row = sites.rowOfBuilding(
        SlotPool.slotOf(a.buildings!.handleOfSite(lot)!));
    expect(row, greaterThanOrEqualTo(0));
    expect(sites.plan[row]!.stallCount, 2, reason: 'a home pad holds two');
    expect(sites.lotCap[row], 2);

    // Who crossed the kerb, and where each trip's car ended up.
    final entered = <int>{};
    final kerbBound = <int, int>{};
    final vehicles = <int, int>{};
    for (var i = 0; i < (300 / kStepS).round(); i++) {
      a.advance(kStepS);
      for (var k = 0; k < trips.length; k++) {
        final v = vehicleOfTrip(a, trips[k]);
        if (v != SlotPool.none) vehicles[k] = v;
      }
      final log = a.accessEvents!;
      for (var e = 0; e < log.count; e++) {
        if (log.kind[e] == AccessEventKind.enter.index) {
          entered.add(log.handle[e]);
        }
      }
      final cols = a.siteVehicles!;
      for (final e in vehicles.entries) {
        if (!a.vehicles!.isLive(e.value)) continue;
        final sl = SlotPool.slotOf(e.value);
        if (SitePhase.values[cols.phase[sl]] == SitePhase.kerbBound) {
          kerbBound[e.key] = cols.claim[sl];
        }
      }
      if (a.parkedCars!.count == 3) break;
    }

    final cars = a.parkedCars!;
    expect(cars.lotCars, 2, reason: 'the pad took two');
    expect(cars.kerbCars, 1, reason: 'and the third stood at the kerb');
    expect(cars.garagedCars, 0);
    expect(sites.lotUsed[row], 2);
    expect(a.siteStats.enters, 2, reason: 'two kerb crossings, not three');
    expect(a.siteStats.parkedLot, 2);
    expect(a.siteStats.parkedKerb, 1);
    expect(a.siteStats.gateGiveUps, 0,
        reason: 'the third was refused before the gate, not by it');

    // The third: never an ENTER, and the slot it reserved was ahead of its
    // stop, on the kerb its own lane serves, and unmasked.
    expect(kerbBound.length, 1, reason: 'exactly one went to step 2');
    final which = kerbBound.keys.single;
    expect(entered.contains(vehicles[which]), isFalse,
        reason: 'it never crossed the kerb line');
    final slot = kerbBound[which]!;
    final kerbs = a.kerbs!;
    expect(kerbs.isMasked(slot), isFalse);
    expect(kerbs.carOf(slot), isNot(-1), reason: 'its car stands there');
    final i = SlotPool.slotOf(kerbs.carOf(slot));
    expect(CarWhere.values[cars.where[i]], CarWhere.kerb);
    expect(cars.slot[i], slot);
    expect(cars.edge[i], kerbs.slotEdge(slot));

    // And the mask is what pushed it past the pad: a car in the back-out's
    // swing would block every departure from the drive (§7.5).
    final plan = sites.plan[row]!;
    final lg = a.laneGraph!;
    final cut = lg.travelArc(kerbs.slotEdge(slot), plan.joinRoadS(0));
    if (kerbs.slotEdge(slot) == _edgeOfCut(a, plan)) {
      expect(kerbs.slotT(slot), greaterThan(cut + kHomeSwingDownM));
    }
  });
}

/// The edge the pad's own join is served by, on the lot's side.
int _edgeOfCut(CityAgents a, dynamic plan) {
  final lg = a.laneGraph!;
  final piece = plan.joinPiece(0) as int;
  final fwd = lg.graph.pieceFwdEdge[piece];
  final bwd = lg.graph.pieceBwdEdge[piece];
  final right = plan.joinRight(0) as bool;
  if (fwd >= 0 && (lg.edgeForward[fwd] == 1) == right) return fwd;
  return bwd >= 0 ? bwd : fwd;
}

/// [n] built sites of [city] that are not [except], nearest the origin
/// first: where the trips come from.
List<String> _origins(dynamic city, String except, int n) {
  final out = <String>[];
  for (final lot in city.layout.autoParcels) {
    final id = lot.id as String;
    if (id == except) continue;
    if (!city.parcelBuildings.containsKey(id)) continue;
    out.add(id);
    if (out.length == n) break;
  }
  return out;
}
