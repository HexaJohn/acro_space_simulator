// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Shared helpers of the site access book tests (docs/plans/site-access.md
/// §4): chunk byte compares, plan fingerprints and a far street of houses.
library;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_book.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';

import '../../traffic/traffic_fixture.dart';

/// The low-density house.
final CityBuildingSpec house = kZoneSpecs['residential']![Density.low]!;

bool _sameList(List a, List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i], y = b[i];
    // NaN-safe, and ids by value.
    if (x is double && y is double) {
      if (x.isNaN && y.isNaN) continue;
    }
    if (x != y) return false;
  }
  return true;
}

/// Whether [a] and [b] hold the same bytes and site ids.
bool sameChunk(SiteAccessChunk a, SiteAccessChunk b) {
  final x = a.debugRetained, y = b.debugRetained;
  for (var i = 0; i < x.length; i++) {
    if (!_sameList(x[i] as List, y[i] as List)) return false;
  }
  return true;
}

/// Whether two chunk lists are byte-identical, chunk by chunk.
bool sameChunks(List<SiteAccessChunk> a, List<SiteAccessChunk> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!sameChunk(a[i], b[i])) return false;
  }
  return true;
}

/// A chunk's lists, copied (to prove a published chunk is never written).
List<List> copyOf(SiteAccessChunk c) => [
      for (final o in c.debugRetained) List.of(o as List),
    ];

/// Whether [c] still holds exactly [copy].
bool unchanged(SiteAccessChunk c, List<List> copy) {
  final now = c.debugRetained;
  for (var i = 0; i < now.length; i++) {
    if (!_sameList(now[i] as List, copy[i])) return false;
  }
  return true;
}

/// Every plan of [book] by site id: `program rev key,key,…` (stall keys in
/// stall order).
Map<String, String> plansOf(SiteAccessBook book) => {
      for (final c in book.chunks)
        for (var k = 0; k < c.siteCount; k++)
          c.siteId(k): '${c.program(k).name} ${c.rev(k)} ${keysOf(c.plan(k))}',
    };

/// A plan's program and stall keys, without its `rev`.
String programAndKeys(SiteAccessPlan p) => '${p.program.name} ${keysOf(p)}';

String keysOf(SiteAccessPlan p) =>
    [for (var i = 0; i < p.stallCount; i++) p.stallKey(i)].join(',');

/// Every site id of [book], in chunk order.
List<String> idsOf(SiteAccessBook book) => [
      for (final c in book.chunks) ...c.siteIds,
    ];

/// Commits a street through [controls] and puts a house on every lot it
/// platted — placed, or with [grown] zoned and grown (what a save keeps: it
/// restores only catalogue buildings as placed ones); returns those lots.
List<Parcel> houseStreet(CitySim city, List<Vec2> controls,
    {bool grown = false}) {
  final road = commit(city, FixtureRoad(controls));
  final lots = [
    for (final p in city.layout.autoParcels)
      if (p.roadId == road && !city.parcelBuildings.containsKey(p.id)) p,
  ];
  for (final p in lots) {
    if (grown) {
      city.layout.setUse(p.id, ParcelUse.residential);
      city.grownParcels[p.id] = 1.0;
    } else {
      city.placeOnParcel(p.id, house);
    }
  }
  return lots;
}
