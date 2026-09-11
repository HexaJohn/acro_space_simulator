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
      // 0 m to 8 m over 800 m, on piers from 500 m: graded into the ground
      // where it crosses at 400 m, so a junction, and the deck is cut there.
      final r = l.commitRoad(
          controls: ew,
          deck: ramp(0, 8, structures: const [(500, 800)]),
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
      // The pier stretch is clipped to the piece it is on and shifted to
      // its start; the piece short of it has none.
      expect(a.structures, isEmpty);
      expect(b.structures.single.$1, closeTo(100, 1e-6));
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

    test("a deck meets a street by its own survey, not the ground's height",
        () {
      // On its piers, however low: passed over, neither cut.
      final low = CityLayout();
      low.commitRoad(controls: ns, regenerateLots: false);
      final over = low.commitRoad(
          controls: ew,
          deck: ramp(3, 3, structures: const [(0, 800)]),
          regenerateLots: false);
      expect(over.crossings.single.bridged, isTrue);
      expect(low.roads.length, 2);
      // Graded into the ground — here a cutting 4.6 m below the street's
      // ground, which the survey found shallow enough to dig rather than
      // tunnel — it meets it: the ground is cut to the deck, and the
      // street on that ground with it. Whatever the ground is said to be.
      final cut = CityLayout();
      cut.commitRoad(controls: ns, regenerateLots: false);
      final meet = cut.commitRoad(
          controls: ew,
          deck: const RoadDeck(startM: -4.6, endM: -4.6),
          groundAt: (_) => 0,
          regenerateLots: false);
      expect(meet.crossings.single.bridged, isFalse);
      expect(cut.roads.length, 4);
    });

    test('the rule is one rule, and every caller asks it', () {
      const onGround = null;
      const piers3 = (heightM: 3.0, offGround: true);
      const graded6 = (heightM: 6.0, offGround: false);
      const deck12 = (heightM: 12.0, offGround: true);
      const deck14 = (heightM: 14.0, offGround: true);
      expect(CityLayout.levelsSeparated(onGround, onGround), isFalse);
      expect(CityLayout.levelsSeparated(piers3, onGround), isTrue);
      expect(CityLayout.levelsSeparated(onGround, piers3), isTrue);
      expect(CityLayout.levelsSeparated(graded6, onGround), isFalse);
      expect(CityLayout.levelsSeparated(deck12, deck14), isFalse,
          reason: 'two decks within the separation are one junction');
      expect(CityLayout.levelsSeparated(deck12, graded6), isTrue);
      expect(CityLayout.levelsSeparated(piers3, graded6), isFalse,
          reason: 'two decks are judged by their heights alone');
    });

    test("a road's end reads its survey's end, however it was re-measured",
        () {
      // Surveyed over 57.3 m, on its piers all the way; re-sampled from a
      // save, 57.302 m long. Its end still stands on its piers.
      final piers = ramp(12, 12, structures: const [(0, 57.3)]);
      expect(CityLayout.levelOf(piers, 57.302, 57.302)!.offGround, isTrue);
      expect(CityLayout.levelOf(piers, 57.3, 57.3)!.offGround, isTrue);
      // Re-measured a little short, the same.
      expect(CityLayout.levelOf(piers, 57.29, 57.29)!.offGround, isTrue);
      // A graded tail is at least half a survey step long, and reads graded.
      final tail = ramp(12, 0.5, structures: const [(0, 56.8)]);
      expect(CityLayout.levelOf(tail, 57.3, 57.3)!.offGround, isFalse);
      expect(CityLayout.levelOf(tail, 57.302, 57.302)!.offGround, isFalse);
      expect(CityLayout.levelOf(tail, 0, 57.3)!.offGround, isTrue);
      // A road shorter than one step has its one boundary half way along.
      final stub = ramp(3, 3, structures: const [(0.2, 0.4)]);
      expect(CityLayout.levelOf(stub, 0.4, 0.4)!.offGround, isTrue);
      final stubTail = ramp(3, 3, structures: const [(0, 0.2)]);
      expect(CityLayout.levelOf(stubTail, 0.4, 0.4)!.offGround, isFalse);
      // The height is still read where it was asked.
      expect(CityLayout.levelOf(ramp(0, 10), 50, 50)!.heightM, 10);
    });

    test("a deck that knows its survey's length reads it exactly, at any "
        'drift', () {
      // Past the quarter metre an unmeasured deck's end is read back by.
      const piers = RoadDeck(
          startM: 12,
          endM: 12,
          startOffsetM: 12,
          endOffsetM: 12,
          structures: [(0, 57.3)],
          rangeLengthM: 57.3);
      for (final now in [56.8, 57.3, 57.302, 57.8, 60.0]) {
        expect(CityLayout.levelOf(piers, now, now)!.offGround, isTrue,
            reason: 're-measured $now m');
      }
      const tail = RoadDeck(
          startM: 12,
          endM: 0.5,
          startOffsetM: 12,
          endOffsetM: 0.5,
          structures: [(0, 56.8)],
          rangeLengthM: 57.3);
      for (final now in [56.8, 57.3, 57.8, 60.0]) {
        expect(CityLayout.levelOf(tail, now, now)!.offGround, isFalse,
            reason: 're-measured $now m');
        expect(CityLayout.levelOf(tail, 0, now)!.offGround, isTrue);
      }
      // A piece a crossing cut 5 cm past its piers ends at the cut: no
      // pull-back reads it onto them.
      const cut = RoadDeck(
          startM: 12,
          endM: 2.6,
          startOffsetM: 12,
          endOffsetM: 2.6,
          structures: [(0, 156)],
          rangeLengthM: 156.05);
      expect(CityLayout.levelOf(cut, 156.05, 156.05)!.offGround, isFalse);
      expect(CityLayout.levelOf(cut, 155.9, 156.05)!.offGround, isTrue);
      // The height is read along the road as it is now.
      expect(CityLayout.levelOf(tail, 60, 60)!.heightM, closeTo(0.5, 1e-9));
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

  group('the end snap', () {
    final viaduct = ramp(12, 12, structures: const [(0, 800)]);

    test("a street's end is not pulled onto a viaduct it would pass under",
        () {
      final l = CityLayout();
      l.commitRoad(controls: ew, deck: viaduct, regenerateLots: false);
      l.commitRoad(
          controls: const [Vec2(400, 300), Vec2(400, 10)],
          regenerateLots: false);
      expect(l.roadById('r1')!.controls.last.n, closeTo(10, 1e-9),
          reason: 'left where it was drawn, not a stub under the deck');
      expect(l.roads.length, 2, reason: 'the viaduct is not cut');
    });

    test('it lands on the next road it can meet', () {
      final l = CityLayout();
      l.commitRoad(controls: ew, deck: viaduct, regenerateLots: false);
      // A street 12 m off, passing under the viaduct: further than the
      // viaduct's 10 m, but a road the end can join.
      l.commitRoad(
          controls: const [Vec2(412, -300), Vec2(412, 100)],
          regenerateLots: false);
      expect(l.roads.length, 2, reason: 'it passed under the viaduct');
      l.commitRoad(
          controls: const [Vec2(400, 300), Vec2(400, 10)],
          regenerateLots: false);
      final end = l.roadById('r2')!.controls.last;
      expect(end.e, closeTo(412, 1e-9));
      expect(end.n, closeTo(10, 1e-9));
      expect(l.roads.length, 4, reason: 'a T that cuts the street');
    });

    test('a raised end is not pulled onto the street beneath it', () {
      final l = CityLayout();
      l.commitRoad(controls: ew, regenerateLots: false);
      l.commitRoad(
          controls: const [Vec2(400, 300), Vec2(400, 10)],
          deck: ramp(0, 12, structures: const [(100, 290)]),
          regenerateLots: false);
      expect(l.roadById('r1')!.controls.last.n, closeTo(10, 1e-9));
      expect(l.roads.length, 2);
    });

    test('a raised end meets a deck at its own height', () {
      final l = CityLayout();
      l.commitRoad(controls: ew, deck: viaduct, regenerateLots: false);
      l.commitRoad(
          controls: const [Vec2(400, 300), Vec2(400, 10)],
          deck: ramp(12, 12, structures: const [(0, 290)]),
          regenerateLots: false);
      expect(l.roadById('r1')!.controls.last.n, closeTo(0, 1e-9));
      expect(l.roads.length, 3, reason: 'a junction in the air');
    });

    test('ends and roads on the ground snap as they always have', () {
      final l = CityLayout();
      l.commitRoad(controls: ew, regenerateLots: false);
      expect(l.snapPoint(const Vec2(400, 10)), isNotNull);
      expect(l.snapPoint(const Vec2(400, 10))!.point.n,
          l.nearestRoadPoint(const Vec2(400, 10))!.point.n);
      expect(l.snapPoint(const Vec2(400, 10), excludeId: 'r0'), isNull);
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

    test('a new class fronts lots by its own say, not the old road\'s', () {
      // The generator's county highway: an avenue told to front nothing.
      final l = CityLayout();
      l.commitRoad(
          controls: const [Vec2(0, -300), Vec2(0, 300)],
          roadClass: RoadClass.avenue,
          frontsLots: false);
      expect(l.autoParcels.where((p) => p.roadId == 'r0'), isEmpty);
      // Re-dressed, it is the same road: still fronting nothing.
      l.upgradeRoad('r0', decoration: RoadDecoration.trees);
      expect(l.roadById('r0')!.frontsLots, isFalse);
      expect(l.autoParcels.where((p) => p.roadId == 'r0'), isEmpty);
      // A six-lane road is zoned.
      l.upgradeRoad('r0', roadClass: RoadClass.boulevard);
      expect(l.roadById('r0')!.frontsLots, isNull);
      expect(l.autoParcels.where((p) => p.roadId == 'r0'), isNotEmpty);
    });

    test('a downgraded interstate sheds its tapers, keeps its bridges', () {
      final l = CityLayout();
      // 800 m of six-lane expressway: widening from a viaduct's deck at
      // one end, narrowing to four lanes at the other, carried over
      // whatever crosses it between 200 m and 400 m.
      l.commitRoad(
          controls: ew,
          roadClass: RoadClass.expressway6,
          frontsLots: false,
          startHalfWidthM: RoadClass.elevated.halfWidth,
          endHalfWidthM: RoadClass.expressway4.halfWidth,
          bridges: const [(200, 400)],
          lotFrontageM: 20);
      l.upgradeRoad('r0', roadClass: RoadClass.street);
      final street = l.roadById('r0')!;
      expect(street.startHalfWidthM, isNull,
          reason: "a viaduct's mouth on a two-lane street");
      expect(street.endHalfWidthM, isNull);
      expect(street.frontsLots, isNull);
      expect(street.bridges, [(200.0, 400.0)],
          reason: 'what it passed over was never cut for it');
      expect(street.lotFrontageM, 20, reason: 'how its district is cut');
      final lots = l.autoParcels.where((p) => p.roadId == 'r0').toList();
      expect(lots, isNotEmpty, reason: 'a street is zoned');
      for (final p in lots) {
        final (a, b) = p.frontage!;
        final s0 = math.min(a.e, b.e), s1 = math.max(a.e, b.e);
        expect(s1 <= 200 + 1e-6 || s0 >= 400 - 1e-6, isTrue,
            reason: '${p.id} fronts the bridge ($s0..$s1)');
      }
      // And back: an expressway fronts nothing, by its class.
      l.upgradeRoad('r0', roadClass: RoadClass.expressway6);
      expect(l.roadById('r0')!.bridges, [(200.0, 400.0)]);
      expect(l.autoParcels.where((p) => p.roadId == 'r0'), isEmpty);
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
