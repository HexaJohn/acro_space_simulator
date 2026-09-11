// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_elevation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Raised and sunk roads: the elevation steps, the deck, and the survey
/// that says which stretch is a bridge and which a tunnel.
void main() {
  group('the elevation step', () {
    test('moves by the step and lands on a multiple of it', () {
      expect(RoadElevation.step(0, 1, 12, RoadClass.street), 12);
      expect(RoadElevation.step(12, 1, 12, RoadClass.street), 24);
      expect(RoadElevation.step(6, 1, 12, RoadClass.street), 12);
      expect(RoadElevation.step(0, -1, 3, RoadClass.street), -3);
      expect(RoadElevation.step(-3, 1, 6, RoadClass.street), 0);
    });

    test('stops at sixty metres up and thirty-six down', () {
      var e = 0.0;
      for (var i = 0; i < 20; i++) {
        e = RoadElevation.step(e, 1, 12, RoadClass.avenue);
      }
      expect(e, RoadElevation.maxHeightM);
      for (var i = 0; i < 40; i++) {
        e = RoadElevation.step(e, -1, 12, RoadClass.avenue);
      }
      expect(e, -RoadElevation.maxDepthM);
    });

    test('a gravel road never goes underground', () {
      expect(RoadElevation.step(0, -1, 12, RoadClass.path), 0);
      expect(RoadElevation.step(0, 1, 12, RoadClass.path), 12);
    });

    test('offers 3, 6 and 12 m, 12 by default', () {
      expect(RoadElevation.stepChoicesM, [3, 6, 12]);
      expect(RoadElevation.defaultStepM, 12);
    });
  });

  group('the deck', () {
    const deck = RoadDeck(
      startM: 100,
      endM: 124,
      startOffsetM: 0,
      endOffsetM: 12,
      structures: [(50, 150)],
      tunnels: [(160, 180)],
    );

    test('runs a straight grade between its ends', () {
      expect(deck.heightAt(0, 200), 100);
      expect(deck.heightAt(100, 200), 112);
      expect(deck.heightAt(200, 200), 124);
      expect(deck.gradePct(200), closeTo(12, 1e-9));
      expect(RoadGradeCheck.ofDeck(deck, 200, RoadClass.street).ok, isTrue);
      expect(RoadGradeCheck.ofDeck(deck, 200, RoadClass.motorway).ok, isFalse);
    });

    test('knows which ends are at grade', () {
      expect(deck.startAtGrade, isTrue);
      expect(deck.endAtGrade, isFalse);
    });

    test('is sliced with its road, heights and ranges alike', () {
      final piece = deck.slice(100, 200, 200);
      expect(piece.startM, 112);
      expect(piece.endM, 124);
      expect(piece.startOffsetM, 6, reason: 'interpolated with no ground');
      expect(piece.structures, [(0.0, 50.0)]);
      expect(piece.tunnels, [(60.0, 80.0)]);
      final sampled = deck.slice(0, 100, 200, groundEndM: 110);
      expect(sampled.endOffsetM, 2, reason: 'deck 112 over ground 110');
      expect(sampled.tunnels, isEmpty);
    });

    test('survives a save', () {
      final back = RoadDeck.fromJson(deck.toJson());
      expect(back, deck);
      expect(RoadDeck.fromJson(null), isNull);
      expect(RoadDeck.fromJson({'h': [1]}), isNull);
    });
  });

  group('the survey', () {
    const line = [Vec2(0, 0), Vec2(0, 400)];

    test('a deck on the ground is all graded', () {
      final s = surveyDeck(line, startM: 0, endM: 0, groundAt: (_) => 0);
      expect(s.structures, isEmpty);
      expect(s.tunnels, isEmpty);
      expect(s.lengthM, closeTo(400, 1e-9));
    });

    test('a deck over a valley stands on piers, a bridge where it is tall',
        () {
      // Flat deck at 10 m; the ground drops to -30 between 100 and 300.
      double ground(Vec2 p) => p.n > 100 && p.n < 300 ? -30 : 10;
      final s = surveyDeck(line, startM: 10, endM: 10, groundAt: ground);
      expect(s.structures, hasLength(1));
      final (a, b) = s.structures.single;
      expect(a, closeTo(100, RoadElevation.surveyStepM));
      expect(b, closeTo(300, RoadElevation.surveyStepM));
      expect(s.bridgeM, closeTo(s.structureM, RoadElevation.surveyStepM),
          reason: '40 m up is a bridge');
      expect(s.maxClearanceM, closeTo(40, 1e-9));
    });

    test('a deck through a hill is a tunnel', () {
      double ground(Vec2 p) => p.n > 150 && p.n < 250 ? 40 : 0;
      final s = surveyDeck(line, startM: 0, endM: 0, groundAt: ground);
      expect(s.tunnels, hasLength(1));
      expect(s.tunnelM, closeTo(100, 2 * RoadElevation.surveyStepM));
      expect(s.maxCoverM, closeTo(40, 1e-9));
    });

    test('a shallow cut or a low fill is graded, not a structure', () {
      final low = surveyDeck(line, startM: 2, endM: 2, groundAt: (_) => 0);
      expect(low.structures, isEmpty);
      final cut = surveyDeck(line, startM: -4, endM: -4, groundAt: (_) => 0);
      expect(cut.tunnels, isEmpty);
    });
  });

  group('the checks', () {
    DeckRefusal? check(RoadClass cls,
            {double s = 0, double e = 0, double len = 200, bool tunnel = false}) =>
        checkDeck(cls,
            startM: s,
            endM: e,
            startOffsetM: s,
            endOffsetM: e,
            lengthM: len,
            survey: tunnel
                ? const DeckSurvey(lengthM: 200, tunnels: [(50, 150)])
                : const DeckSurvey(lengthM: 200));

    test('refuse a deck steeper than the class allows', () {
      expect(check(RoadClass.street, e: 12, len: 200), isNull); // 6%
      expect(check(RoadClass.motorway, e: 12, len: 200),
          DeckRefusal.tooSteep); // 6% > 5%
    });

    test('refuse the heights past the limits', () {
      expect(check(RoadClass.street, s: 72, e: 72), DeckRefusal.tooHigh);
      expect(check(RoadClass.street, s: -48, e: -48), DeckRefusal.tooDeep);
    });

    test('refuse a gravel tunnel and a raised class-held deck', () {
      expect(check(RoadClass.path, tunnel: true), DeckRefusal.noTunnel);
      expect(check(RoadClass.elevated, s: 12, e: 12), DeckRefusal.noElevation);
    });
  });
}
