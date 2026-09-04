// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:flutter_test/flutter_test.dart';

/// One warrant for every junction in the world, decided from the classes
/// meeting there.
void main() {
  const st = RoadClass.street;
  const av = RoadClass.avenue;
  const ramp = RoadClass.ramp;
  const x6 = RoadClass.expressway6;

  test('two ends meeting is a road carrying on, not a junction', () {
    expect(junctionControlFor([st, st]), JunctionControl.none);
    expect(junctionControlFor([av, av]), JunctionControl.none);
    expect(junctionControlFor([st]), JunctionControl.none);
    expect(junctionControlFor([]), JunctionControl.none);
  });

  test('local streets crossing get an all-way stop', () {
    expect(junctionControlFor([st, st, st, st]), JunctionControl.stop);
    expect(junctionControlFor([st, st, st]), JunctionControl.stop);
  });

  test('two arterial legs warrant signals', () {
    // A crossing of two avenues.
    expect(junctionControlFor([av, av, av, av]), JunctionControl.signals);
    // A street T-ing into an avenue: the avenue runs through.
    expect(junctionControlFor([av, av, st]), JunctionControl.signals);
    // A collector crossing a county highway.
    expect(junctionControlFor([av, av, st, st]), JunctionControl.signals);
    // A trunk artery meeting the mile grid.
    expect(junctionControlFor([av, av, RoadClass.trunk]),
        JunctionControl.signals);
    // A ramp terminal on the highway: the diamond's T.
    expect(junctionControlFor([av, av, ramp]), JunctionControl.signals);
  });

  test('anything meeting an expressway is a merge, never a crossing', () {
    expect(junctionControlFor([x6, x6, ramp]), JunctionControl.merge);
    expect(junctionControlFor([x6, ramp]), JunctionControl.merge,
        reason: 'a ramp landing on the end of a piece');
    expect(junctionControlFor([RoadClass.elevated, RoadClass.elevated, ramp]),
        JunctionControl.merge);
  });

  test('an expressway ending at an arterial ends at a signal', () {
    // The diagonal's terminus on a county-grid crossing.
    expect(junctionControlFor([av, av, av, av, x6]), JunctionControl.signals);
    // A ramp among them is an interchange, not an end.
    expect(junctionControlFor([av, av, x6, ramp]), JunctionControl.merge);
    // Two expressway legs is a through road: a merge.
    expect(junctionControlFor([x6, x6, av]), JunctionControl.merge);
  });

  test('a roundabout where the planner asks for one and the roads allow it',
      () {
    expect(junctionControlFor([st, st, st, st], roundaboutPreferred: true),
        JunctionControl.roundabout);
    expect(junctionControlFor([av, av, st, st], roundaboutPreferred: true),
        JunctionControl.roundabout);
    // Not on a highway, and never with fewer than three legs.
    expect(
        junctionControlFor([RoadClass.highway, RoadClass.highway, st],
            roundaboutPreferred: true),
        JunctionControl.signals);
    expect(junctionControlFor([st, st], roundaboutPreferred: true),
        JunctionControl.none);
    expect(junctionControlFor([x6, x6, ramp], roundaboutPreferred: true),
        JunctionControl.merge);
  });
}
