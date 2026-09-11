// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The layout's side of the road tool: decks that pass over (and under)
/// what they cross, decks sliced with the roads they are cut into, the
/// road-tool attributes carried by every split, and the in-place edits —
/// upgrade, reverse, rename — that keep a road's id.
library;

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  RoadDeck ramp(double h0, double h1,
          {List<(double, double)> structures = const [],
          List<(double, double)> tunnels = const []}) =>
      RoadDeck(
          startM: h0,
          endM: h1,
          startOffsetM: h0,
          endOffsetM: h1,
          structures: structures,
          tunnels: tunnels);
  const ns = [Vec2(400, -300), Vec2(400, 300)];
  const ew = [Vec2(0, 0), Vec2(800, 0)];

  group('crossings', () {
    test('a deck is sliced onto the pieces a crossing cuts it into', () {
      final l = CityLayout();
      l.commitRoad(controls: ns, regenerateLots: false);
      // 0 m to 8 m over 800 m: 4 m up where it crosses — inside the
      // separation, so a junction, and the deck is cut there.
      final r = l.commitRoad(
          controls: ew,
          deck: ramp(0, 8, structures: const [(250, 800)]),
          regenerateLots: false);
      expect(r.crossings.single.bridged, isFalse);
      final a = l.roadById('r1x0')!.deck!, b = l.roadById('r1x1')!.deck!;
      expect(a.startM, closeTo(0, 1e-9));
      expect(a.endM, closeTo(4, 1e-6));
      expect(b.startM, closeTo(4, 1e-6));
      expect(b.endM, closeTo(8, 1e-9));
      // No ground to ask: the offsets at the cut are interpolated.
      expect(a.endOffsetM, closeTo(4, 1e-6));
      expect(b.startOffsetM, closeTo(4, 1e-6));
      // The pier stretch is clipped to each piece and shifted to its start.
      expect(a.structures.single.$1, closeTo(250, 1e-6));
      expect(a.structures.single.$2, closeTo(400, 1e-6));
      expect(b.structures.single.$1, closeTo(0, 1e-6));
      expect(b.structures.single.$2, closeTo(400, 1e-6));
      // The street it crossed has no deck to slice.
      expect(l.roadById('r0x0')!.deck, isNull);
      expect(l.roadById('r0x1')!.deck, isNull);
    });

    test("with the ground to ask, each cut's offset is measured from it", () {
      final l = CityLayout();
      l.commitRoad(controls: ns, regenerateLots: false);
      l.commitRoad(
          controls: ew,
          deck: ramp(0, 8),
          groundAt: (_) => 1.0,
          regenerateLots: false);
      final a = l.roadById('r1x0')!.deck!;
      expect(a.startOffsetM, closeTo(-1, 1e-9));
      expect(a.endOffsetM, closeTo(3, 1e-6));
    });

    test('an existing deck is sliced where a new road cuts it', () {
      final l = CityLayout();
      l.commitRoad(controls: ew, deck: ramp(0, 8), regenerateLots: false);
      l.commitRoad(controls: ns, regenerateLots: false);
      final a = l.roadById('r0x0')!.deck!, b = l.roadById('r0x1')!.deck!;
      expect(a.endM, closeTo(4, 1e-6));
      expect(b.startM, closeTo(4, 1e-6));
      expect(b.endM, closeTo(8, 1e-9));
    });

    test('a raised road passes over a street: no junction, neither cut', () {
      final l = CityLayout();
      l.commitRoad(controls: ns, regenerateLots: false);
      final r = l.commitRoad(
          controls: ew,
          deck: ramp(12, 12, structures: const [(0, 800)]),
          regenerateLots: false);
      expect(l.roads.length, 2);
      expect(r.crossings.single.bridged, isTrue);
      // Either way round.
      final m = CityLayout();
      m.commitRoad(
          controls: ew,
          deck: ramp(12, 12, structures: const [(0, 800)]),
          regenerateLots: false);
      final s = m.commitRoad(controls: ns, regenerateLots: false);
      expect(m.roads.length, 2);
      expect(s.crossings.single.bridged, isTrue);
    });

    test('a deck at grade meets the street: a junction, both cut', () {
      final l = CityLayout();
      l.commitRoad(controls: ns, regenerateLots: false);
      final r =
          l.commitRoad(controls: ew, deck: ramp(0, 0), regenerateLots: false);
      expect(r.crossings.single.bridged, isFalse);
      expect(l.roads.length, 4);
    });

    test('a draped road stands on the ground the caller measures', () {
      // A deck 12 m above the datum over ground 10 m above it clears the
      // street by two metres: a junction, not a bridge.
      final l = CityLayout();
      l.commitRoad(controls: ns, regenerateLots: false);
      l.commitRoad(
          controls: ew,
          deck: ramp(12, 12),
          groundAt: (_) => 10,
          regenerateLots: false);
      expect(l.roads.length, 4);
    });

    test('two decks meet at one height and pass at two', () {
      final l = CityLayout();
      l.commitRoad(controls: ns, deck: ramp(12, 12), regenerateLots: false);
      l.commitRoad(controls: ew, deck: ramp(12, 12), regenerateLots: false);
      expect(l.roads.length, 4, reason: 'one junction in the air');
      final m = CityLayout();
      m.commitRoad(controls: ns, deck: ramp(12, 12), regenerateLots: false);
      final r =
          m.commitRoad(controls: ew, deck: ramp(24, 24), regenerateLots: false);
      expect(m.roads.length, 2);
      expect(r.crossings.single.bridged, isTrue);
    });

    test("two roads on the ground keep today's rules", () {
      final l = CityLayout();
      l.commitRoad(controls: ns, regenerateLots: false);
      final r = l.commitRoad(controls: ew, regenerateLots: false);
      expect(r.crossings.single.bridged, isFalse);
      expect(l.roads.length, 4);
      expect(l.roads.every((x) => x.deck == null), isTrue);
    });
  });

  group('attributes ride every split', () {
    test('a crossed road keeps its dressing, direction and name', () {
      final l = CityLayout();
      l.commitRoad(
          controls: ew,
          roadClass: RoadClass.streetOneWay,
          decoration: RoadDecoration.grass,
          reversed: true,
          name: 'Main',
          regenerateLots: false);
      l.commitRoad(controls: ns, regenerateLots: false);
      for (final id in ['r0x0', 'r0x1']) {
        final p = l.roadById(id)!;
        expect(p.decoration, RoadDecoration.grass, reason: id);
        expect(p.reversed, isTrue, reason: id);
        expect(p.name, 'Main', reason: id);
      }
    });

    test('so does a new road cut by what it crosses', () {
      final l = CityLayout();
      l.commitRoad(controls: ns, regenerateLots: false);
      l.commitRoad(
          controls: ew,
          roadClass: RoadClass.avenue,
          decoration: RoadDecoration.trees,
          name: 'Cross',
          regenerateLots: false);
      for (final id in ['r1x0', 'r1x1']) {
        final p = l.roadById(id)!;
        expect(p.decoration, RoadDecoration.trees, reason: id);
        expect(p.name, 'Cross', reason: id);
      }
    });

    test('and a road cut with splitRoadAt', () {
      final l = CityLayout();
      l.commitRoad(
          controls: ew,
          roadClass: RoadClass.streetOneWay,
          decoration: RoadDecoration.trees,
          reversed: true,
          name: 'Split',
          deck: ramp(0, 8),
          regenerateLots: false);
      final ids = l.splitRoadAt('r0', 200, groundAt: (_) => 0.5)!;
      final a = l.roadById(ids[0])!, b = l.roadById(ids[1])!;
      for (final p in [a, b]) {
        expect(p.decoration, RoadDecoration.trees);
        expect(p.reversed, isTrue);
        expect(p.name, 'Split');
      }
      expect(a.deck!.endM, closeTo(2, 1e-6));
      expect(a.deck!.endOffsetM, closeTo(1.5, 1e-6));
      expect(b.deck!.startM, closeTo(2, 1e-6));
    });

    test('dressing and direction only where the class has them', () {
      final l = CityLayout();
      l.commitRoad(
          controls: ew,
          roadClass: RoadClass.motorway,
          decoration: RoadDecoration.trees,
          regenerateLots: false);
      expect(l.roadById('r0')!.decoration, RoadDecoration.none,
          reason: 'a highway has no verge to plant');
      l.commitRoad(
          controls: const [Vec2(0, 500), Vec2(800, 500)],
          reversed: true,
          regenerateLots: false);
      expect(l.roadById('r1')!.reversed, isFalse,
          reason: 'a two-way street has no direction to reverse');
    });
  });

  group('in-place edits', () {
    test('every road mutation moves the revision', () {
      final l = CityLayout();
      var rev = l.revision;
      void moved(String what) {
        expect(l.revision, greaterThan(rev), reason: what);
        rev = l.revision;
      }

      l.addRoad(const RoadSpline(
          id: 'a', controls: [Vec2(0, 1000), Vec2(300, 1000)]));
      moved('addRoad');
      l.commitRoad(
          controls: ew,
          roadClass: RoadClass.streetOneWay,
          regenerateLots: false);
      moved('commitRoad');
      l.splitRoadAt('r0', 300);
      moved('splitRoadAt');
      l.updateRoad(l.roadById('r0x0')!.copyWith(collector: true));
      moved('updateRoad');
      l.upgradeRoad('r0x0', decoration: RoadDecoration.grass);
      moved('upgradeRoad');
      l.reverseRoad('r0x0');
      moved('reverseRoad');
      l.renameRoad('r0x0', 'Elm');
      moved('renameRoad');
      l.removeRoad('a');
      moved('removeRoad');
    });

    test('an upgrade keeps the id and the line, and re-cuts the lots wider',
        () {
      final l = CityLayout();
      l.commitRoad(controls: const [Vec2(0, -300), Vec2(0, 300)]);
      final lot = l.autoParcels.firstWhere((p) => p.roadId == 'r0');
      l.setUse(lot.id, ParcelUse.residential);
      double setback(Parcel p) => p.frontageMidpoint!.e.abs();
      expect(setback(lot), closeTo(4 + 3, 1e-6));
      final version = l.version;
      final renamed = l.upgradeRoad('r0', roadClass: RoadClass.avenue);
      expect(renamed, isNotNull);
      expect(l.version, greaterThan(version), reason: 're-platted');
      final road = l.roadById('r0')!;
      expect(road.roadClass, RoadClass.avenue);
      expect(road.controls.first.n, closeTo(-300, 1e-9));
      expect(road.controls.last.n, closeTo(300, 1e-9));
      expect(l.roadIndex.byId('r0')!.road.roadClass, RoadClass.avenue,
          reason: 'the index record follows');
      final again = l.parcelById(renamed![lot.id] ?? lot.id)!;
      expect(setback(again), closeTo(8 + 3, 1e-6));
      expect(again.use, ParcelUse.residential, reason: 'zoning rides along');
      expect(l.upgradeRoad('ghost', roadClass: RoadClass.avenue), isNull);
    });

    test('an upgrade to a road that fronts nothing takes its lots away', () {
      final l = CityLayout();
      l.commitRoad(controls: const [Vec2(0, -300), Vec2(0, 300)]);
      l.upgradeRoad('r0',
          roadClass: RoadClass.motorway,
          decoration: RoadDecoration.trees,
          soundWalls: true);
      final road = l.roadById('r0')!;
      expect(road.decoration, RoadDecoration.none);
      expect(road.soundWalls, isTrue);
      expect(l.autoParcels.where((p) => p.roadId == 'r0'), isEmpty);
    });

    test('reversing flips the direction and nothing else', () {
      final l = CityLayout();
      l.commitRoad(
          controls: const [Vec2(0, -300), Vec2(0, 300)],
          roadClass: RoadClass.streetOneWay);
      final lots = [for (final p in l.autoParcels) p.id];
      final version = l.version;
      expect(l.reverseRoad('r0'), isTrue);
      expect(l.roadById('r0')!.reversed, isTrue);
      expect(l.roadIndex.byId('r0')!.road.reversed, isTrue);
      expect(l.version, version, reason: 'no lot moves, so nothing is re-cut');
      expect([for (final p in l.autoParcels) p.id], lots);
      expect(l.reverseRoad('r0'), isTrue);
      expect(l.roadById('r0')!.reversed, isFalse);
      l.commitRoad(controls: const [Vec2(500, -300), Vec2(500, 300)]);
      expect(l.reverseRoad('r1'), isFalse, reason: 'a two-way street');
      expect(l.reverseRoad('ghost'), isFalse);
    });

    test('a name is set on one piece, and cleared', () {
      final l = CityLayout();
      l.commitRoad(controls: ew, regenerateLots: false);
      expect(l.renameRoad('r0', '  Elm Street '), isTrue);
      expect(l.roadById('r0')!.name, 'Elm Street');
      expect(l.roadIndex.byId('r0')!.road.name, 'Elm Street');
      expect(l.renameRoad('r0', ''), isTrue);
      expect(l.roadById('r0')!.name, isNull);
      expect(l.renameRoad('ghost', 'x'), isFalse);
    });

    test('a re-laid piece gets an id that keeps its base road', () {
      final l = CityLayout();
      l.addRoad(const RoadSpline(id: 'r3', controls: [Vec2(0, 0), Vec2(100, 0)]));
      expect(l.childIdFor('r3'), 'r3x0');
      l.addRoad(
          const RoadSpline(id: 'r3x0', controls: [Vec2(0, 50), Vec2(100, 50)]));
      expect(l.childIdFor('r3'), 'r3x1');
      expect(CityLayout.baseRoadId('r3x1x0'), 'r3');
      expect(CityLayout.baseRoadId('main'), 'main');
    });
  });

  group('the plat', () {
    test("nothing fronts a raised road's piers", () {
      final l = CityLayout();
      // 600 m, on piers from 200 m to 400 m along.
      l.addRoad(RoadSpline(
          id: 'deck',
          controls: const [Vec2(0, -300), Vec2(0, 300)],
          deck: ramp(0, 0, structures: const [(200, 400)])));
      final lots = l.autoParcels.where((p) => p.roadId == 'deck').toList();
      expect(lots, isNotEmpty,
          reason: 'the stretches on the ground still front lots');
      for (final p in lots) {
        final (a, b) = p.frontage!;
        final s0 = math.min(a.n, b.n) + 300, s1 = math.max(a.n, b.n) + 300;
        expect(s1 <= 200 + 1e-6 || s0 >= 400 - 1e-6, isTrue,
            reason: '${p.id} fronts the piers ($s0..$s1)');
      }
    });

    test('a tunnel under a block neither clips its lots nor is a street to them',
        () {
      String plat(CityLayout l) => [
            for (final p in l.autoParcels.where((p) => p.roadId == 'street'))
              '${p.id} ${p.isCorner} '
                  '${p.polygon.map((v) => '${v.e.toStringAsFixed(3)},${v.n.toStringAsFixed(3)}').join(' ')}',
          ].join('\n');
      const street = RoadSpline(
          id: 'street', controls: [Vec2(0, -300), Vec2(0, 300)]);
      final bare = CityLayout()..addRoad(street);
      final tunnelled = CityLayout()
        ..addRoad(street)
        ..addRoad(const RoadSpline(
            id: 'tunnel',
            controls: [Vec2(-200, 20), Vec2(200, 20)],
            deck: RoadDeck(
                startM: -12,
                endM: -12,
                startOffsetM: -12,
                endOffsetM: -12,
                tunnels: [(0, 400)])));
      expect(plat(tunnelled), plat(bare));
      // The same road on the ground does cut into them.
      final crossed = CityLayout()
        ..addRoad(street)
        ..addRoad(const RoadSpline(
            id: 'road', controls: [Vec2(-200, 20), Vec2(200, 20)]));
      expect(plat(crossed), isNot(plat(bare)));
    });
  });
}
