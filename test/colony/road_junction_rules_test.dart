// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:flutter_test/flutter_test.dart';

/// The city-builder's traffic-light rules, one test per rule as the road
/// tool's brief states them. A leg is one road END at the junction:
/// `startsHere` means the road's first point — the start of travel on a
/// one-way road — is at the junction.
void main() {
  // Two-lane two-way, drawn into the junction (it ENDS here) or away.
  const twoIn = JunctionLeg(RoadClass.street);
  const twoAway = JunctionLeg(RoadClass.street, startsHere: true);
  // Two-lane one-way, arriving or leaving.
  const oneWayIn = JunctionLeg(RoadClass.streetOneWay);
  const oneWayOut = JunctionLeg(RoadClass.streetOneWay, startsHere: true);
  // A four-lane road's two legs where it runs through.
  const fourA = JunctionLeg(RoadClass.avenue);
  const fourB = JunctionLeg(RoadClass.avenue, startsHere: true);
  const sixA = JunctionLeg(RoadClass.boulevard);
  const sixB = JunctionLeg(RoadClass.boulevard, startsHere: true);
  const hwyIn = JunctionLeg(RoadClass.motorway);
  const hwyOut = JunctionLeg(RoadClass.motorway, startsHere: true);
  const rampOut = JunctionLeg(RoadClass.ramp, startsHere: true);
  const rampIn = JunctionLeg(RoadClass.ramp);

  JunctionControl c(List<JunctionLeg> legs, {bool roundabout = false}) =>
      junctionControlForLegs(legs, roundaboutPreferred: roundabout);

  group('two-lane roads', () {
    test('never make lights, one way or two', () {
      expect(c([twoIn, twoAway, twoIn, twoAway]), JunctionControl.stop);
      expect(c([twoIn, twoAway, oneWayIn]), JunctionControl.stop);
      expect(c([oneWayIn, oneWayOut, oneWayIn]), JunctionControl.stop);
    });

    test('two ends is a road carrying on, not a junction', () {
      expect(c([twoIn, twoAway]), JunctionControl.none);
      expect(c([fourA, fourB]), JunctionControl.none);
    });

    test('make roundabouts without lights', () {
      expect(c([twoIn, twoAway, twoIn, twoAway], roundabout: true),
          JunctionControl.roundabout);
    });
  });

  group('four-lane roads', () {
    test('make lights where they cross', () {
      expect(c([fourA, fourB, fourA, fourB]), JunctionControl.signals);
      expect(c([fourA, fourB, twoIn]), JunctionControl.signals,
          reason: 'a two-lane road drawn INTO the four-lane is an approach');
    });

    test('except one-way roads going away from them', () {
      expect(c([fourA, fourB, oneWayOut]), JunctionControl.stop);
      expect(c([fourA, fourB, oneWayIn]), JunctionControl.signals,
          reason: 'a one-way road ARRIVING is an approach');
    });

    test('and, in some cases, two-lane two-way roads drawn away from them',
        () {
      expect(c([fourA, fourB, twoAway]), JunctionControl.stop);
      // Only when every other leg is such a feeder.
      expect(c([fourA, fourB, twoAway, twoIn]), JunctionControl.signals);
    });

    test('override every other no-lights rule: four-lane meets highway', () {
      expect(c([fourA, fourB, hwyOut]), JunctionControl.signals);
      expect(c([fourA, fourB, hwyIn]), JunctionControl.signals);
    });
  });

  group('six-lane roads', () {
    test('make lights at every crossing', () {
      expect(c([sixA, sixB, twoIn]), JunctionControl.signals);
      expect(c([sixA, sixB, twoAway]), JunctionControl.signals,
          reason: 'the drawn-away exception is the four-lane rule only');
      expect(c([sixA, sixB, sixA, sixB]), JunctionControl.signals);
    });

    test('except one-way roads going away from them', () {
      expect(c([sixA, sixB, oneWayOut]), JunctionControl.stop);
      expect(c([sixA, sixB, rampOut]), JunctionControl.stop);
      expect(c([sixA, sixB, oneWayIn]), JunctionControl.signals);
    });
  });

  group('highways', () {
    test('make no lights where they meet only one-way roads', () {
      expect(c([hwyIn, hwyOut, rampOut]), JunctionControl.stop);
      expect(c([hwyIn, hwyOut, rampIn]), JunctionControl.stop);
      expect(c([hwyIn, hwyOut, oneWayIn]), JunctionControl.stop);
    });

    test('and lights where they meet a two-way road', () {
      expect(c([hwyIn, hwyOut, twoIn]), JunctionControl.signals);
      expect(c([hwyIn, hwyOut, twoAway]), JunctionControl.signals);
    });
  });

  test('the generator\'s limited-access roads keep the merge warrant', () {
    const x6 = JunctionLeg(RoadClass.expressway6);
    expect(c([x6, x6, rampOut]), JunctionControl.merge);
    expect(c([x6, rampIn]), JunctionControl.merge);
  });

  group('stop signs', () {
    test('an all-way stop where every road is the same size', () {
      final plan = junctionPlanFor([twoIn, twoAway, twoIn]);
      expect(plan.control, JunctionControl.stop);
      expect(plan.stopLegs, {0, 1, 2});
    });

    test('the smaller road gives way where they are not', () {
      // A two-lane road meeting a four-lane road that runs past with a
      // one-way road leaving: no lights, and only the small roads stop.
      final plan = junctionPlanFor([fourA, fourB, oneWayOut, twoAway]);
      expect(plan.control, JunctionControl.stop);
      expect(plan.stopLegs, {3},
          reason: 'the one-way leg only leaves; the four-lane runs through');
    });

    test('a road leaving the biggest one stops nothing on it', () {
      // A highway's exit: the ramp only leaves, the mainline runs on.
      final exit = junctionPlanFor([hwyIn, hwyOut, rampOut]);
      expect(exit.control, JunctionControl.stop);
      expect(exit.stopLegs, isEmpty);
      // A one-way street leaving a four- or six-lane road: nothing
      // crosses the big road, so nothing on it stops.
      expect(junctionPlanFor([fourA, fourB, oneWayOut]).stopLegs, isEmpty);
      expect(junctionPlanFor([sixA, sixB, oneWayOut]).stopLegs, isEmpty);
      // Joining it, the smaller road gives way: an on-ramp stops, the
      // mainline does not.
      expect(junctionPlanFor([hwyIn, hwyOut, rampIn]).stopLegs, {2});
      // And roads all one size still stop all round, a leg leaving or not.
      expect(junctionPlanFor([oneWayIn, oneWayOut, twoIn]).stopLegs, {0, 2});
    });

    test('nothing stops at lights', () {
      expect(junctionPlanFor([fourA, fourB, twoIn]).stopLegs, isEmpty);
    });
  });

  group('the player\'s overrides', () {
    const at = Vec2(10, 20);

    test('can remove the lights a rule put there', () {
      final plan = junctionPlanFor([fourA, fourB, twoIn],
          override: const JunctionOverride(at: at, lights: false));
      expect(plan.control, JunctionControl.stop);
      expect(plan.lights, isFalse);
    });

    test('can add lights the rules did not', () {
      final plan = junctionPlanFor([twoIn, twoAway, twoIn],
          override: const JunctionOverride(at: at, lights: true));
      expect(plan.control, JunctionControl.signals);
    });

    test('cannot put lights on a two-ended road or a merge', () {
      expect(
          junctionPlanFor([twoIn, twoAway],
                  override: const JunctionOverride(at: at, lights: true))
              .control,
          JunctionControl.none);
    });

    test('choose which legs stop, by heading', () {
      final legs = [
        const JunctionLeg(RoadClass.street, heading: 0),
        const JunctionLeg(RoadClass.street,
            startsHere: true, heading: math.pi / 2),
        const JunctionLeg(RoadClass.street, heading: math.pi),
      ];
      final plan = junctionPlanFor(legs,
          override:
              const JunctionOverride(at: at, stopHeadings: [math.pi + 0.1]));
      expect(plan.stopLegs, {2});
    });

    test('survive a save', () {
      const o = JunctionOverride(at: at, lights: false, stopHeadings: [1.5]);
      final back = JunctionOverride.fromJson(o.toJson());
      expect(back.at.e, at.e);
      expect(back.lights, isFalse);
      expect(back.stopHeadings, [1.5]);
      expect(back.key, o.key);
      expect(const JunctionOverride(at: at).isEmpty, isTrue);
    });
  });
}
