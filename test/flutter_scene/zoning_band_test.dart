// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_mesher.dart';
import 'package:flutter_test/flutter_test.dart';

/// The zoning view's whole policy: which lots are painted, and in what.
///
/// Out of the scene graph so it can be pinned here — the node that draws the
/// plat is rebuilt the frame something changes, and what it is rebuilt FROM
/// is this function.
void main() {
  int lot(int kind, {bool built = false, bool unzoned = false}) =>
      CityPatchSnapshot.packKind(kind,
          built: built, unzoned: unzoned, lot: true);

  const res = CityPatchSnapshot.kindResidential;
  const com = CityPatchSnapshot.kindCommercial;
  const ind = CityPatchSnapshot.kindIndustrial;
  const sup = CityPatchSnapshot.kindSupport;

  group('the town view (no zone tool held)', () {
    test('a zoned, EMPTY lot is painted its zone colour, pale', () {
      expect(zoningBandFor(lot(res), zoning: false), res + kPaleZoneOffset);
      expect(zoningBandFor(lot(com), zoning: false), com + kPaleZoneOffset);
      expect(zoningBandFor(lot(ind), zoning: false), ind + kPaleZoneOffset);
    });

    test('a lot goes back to bare ground the moment it is built', () {
      expect(zoningBandFor(lot(res, built: true), zoning: false), isNull);
      expect(zoningBandFor(lot(ind, built: true), zoning: false), isNull);
    });

    test('an unzoned lot is not painted — no rows of grey plots', () {
      expect(zoningBandFor(lot(sup, unzoned: true), zoning: false), isNull);
      expect(
          zoningBandFor(lot(sup, unzoned: true, built: true), zoning: false),
          isNull);
    });
  });

  group('the zoning view (zone tool held, or pinned)', () {
    test('every lot is painted, at full strength', () {
      expect(zoningBandFor(lot(res), zoning: true), res);
      expect(zoningBandFor(lot(res, built: true), zoning: true), res);
      expect(zoningBandFor(lot(com, built: true), zoning: true), com);
      expect(zoningBandFor(lot(sup, unzoned: true), zoning: true), sup);
    });
  });

  test('a patch that is not a lot is never the zoning node\'s to draw', () {
    // Road cells and support decks share the palette; the tiles own them.
    for (final zoning in [false, true]) {
      expect(zoningBandFor(CityPatchSnapshot.kindRoad, zoning: zoning), isNull);
      expect(zoningBandFor(sup, zoning: zoning), isNull);
      expect(zoningBandFor(res, zoning: zoning), isNull,
          reason: 'a grid-city zone cell carries no lot flag');
    }
  });

  test('the flags round-trip through the packed kind', () {
    final p = lot(ind, built: true, unzoned: false);
    final snap = CityPatchSnapshot(
      colonyId: 'c',
      body: 'earth',
      px: 0,
      py: 0,
      pz: 0,
      qw: 1,
      qx: 0,
      qy: 0,
      qz: 0,
      sizeM: 10,
      kind: p,
    );
    expect(snap.zoneKind, ind);
    expect(snap.isLot, isTrue);
    expect(snap.built, isTrue);
    expect(snap.unzoned, isFalse);
  });
}
