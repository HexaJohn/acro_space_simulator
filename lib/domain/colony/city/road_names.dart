// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Street names, for the roads nobody has named.
///
/// A city builder names every road it draws — "Maple Street", "Kepler
/// Avenue" — so the Adjust Roads panel and the route view have something to
/// call a road by before the player gets round to it. The name is not
/// stored: it is DERIVED from the road's base id (the id it was laid under,
/// before any junction split it — every piece of one drawn road shares it)
/// and its class, so it is the same on every load, on every client, and
/// for every piece of the road; and a player's own name, which IS stored
/// (`RoadSpline.name`), always wins over it.
library;

import 'parcel.dart';

class RoadNames {
  const RoadNames._();

  /// The stock: trees for a street, and the names a spacefaring colony
  /// would put on its signs.
  static const List<String> stock = [
    'Maple', 'Oak', 'Cedar', 'Elm', 'Birch', 'Willow', 'Aspen', 'Juniper', //
    'Hawthorn', 'Linden', 'Poplar', 'Sycamore', 'Magnolia', 'Chestnut',
    'Laurel', 'Rowan', 'Alder', 'Hazel', 'Spruce', 'Cypress', //
    'Armstrong', 'Aldrin', 'Collins', 'Gagarin', 'Tereshkova', 'Glenn',
    'Ride', 'Shepard', 'Leonov', 'Jemison', 'Korolev', 'Tsiolkovsky',
    'Goddard', 'Oberth', 'Kepler', 'Tycho', 'Galileo', 'Huygens',
    'Herschel', 'Sagan',
  ];

  /// What a road of [cls] is called after its name. Exhaustive on purpose:
  /// a new class must say what its signs read.
  static String suffixFor(RoadClass cls) => switch (cls) {
        RoadClass.path || RoadClass.alley => 'Lane',
        RoadClass.street || RoadClass.streetOneWay => 'Street',
        RoadClass.avenue => 'Avenue',
        RoadClass.boulevard || RoadClass.highway => 'Boulevard',
        RoadClass.trunk => 'Road',
        RoadClass.motorway ||
        RoadClass.expressway4 ||
        RoadClass.expressway6 ||
        RoadClass.expressway8 ||
        RoadClass.elevated =>
          'Highway',
        RoadClass.ramp => 'Ramp',
        RoadClass.rail || RoadClass.transit => 'Line',
      };

  /// The generated name of a road laid under [baseId], as a [cls].
  static String generated(String baseId, RoadClass cls) =>
      '${stock[_mix(_seedOf(baseId)) % stock.length]} ${suffixFor(cls)}';

  /// The number in a road id (`r12` -> 12); an id with none hashes its
  /// characters. Never `String.hashCode`, which no platform promises is
  /// the same on the next run.
  static int _seedOf(String id) {
    final m = RegExp(r'\d+').firstMatch(id);
    if (m != null) {
      final digits = m.group(0)!;
      final n = int.tryParse(
          digits.length > 9 ? digits.substring(digits.length - 9) : digits);
      if (n != null) return n;
    }
    var h = 7;
    for (final c in id.codeUnits) {
      h = (h * 31 + c) & 0xffffffff;
    }
    return h;
  }

  /// Scatter consecutive ids across the stock, so roads laid one after
  /// another do not come out alphabetical. Every product stays under 2^53
  /// (a 32-bit value times a multiplier under 2^18), so the web build's
  /// doubles compute exactly what the VM does.
  static int _mix(int n) {
    var x = (n & 0xffffffff) ^ 0x5bd1e995;
    x = ((x ^ (x >> 15)) * 0x1b873) & 0xffffffff;
    x = ((x ^ (x >> 13)) * 0x2c9b1) & 0xffffffff;
    return x ^ (x >> 16);
  }
}
