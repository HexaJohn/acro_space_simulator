// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic_readout.dart';
import 'package:flutter_test/flutter_test.dart';

/// These enums are stored by index — in typed columns, in the frame the
/// renderer reads, in saves — so their orders are pinned. A new member is
/// appended to its enum AND to its list here; anything else fails, because
/// anything else turns stored values into their neighbours.
void main() {
  List<String> names(List<Enum> values) => [for (final v in values) v.name];

  test('AgentKind declares every kind the design lists, in stored order', () {
    expect(names(AgentKind.values), const [
      'car',
      'truck',
      'semi',
      'bus',
      'garbageTruck',
      'hearse',
      'policeCar',
      'ambulance',
      'fireEngine',
      'mailVan',
      'deliveryVan',
      'train',
      'lTrain',
      'freightTrain',
    ]);
    expect(AgentKind.values.length, lessThanOrEqualTo(256),
        reason: 'a kind is one byte in the vehicle table');
  });

  test('the enums a save writes keep their order', () {
    expect(names(CitizenState.values), const [
      'atHome',
      'travelling',
      'atWork',
      'atErrand',
      'outOfTown',
      'movingIn',
      'leaving',
      'riding',
    ]);
    expect(names(ServiceKind.values), const [
      'garbage',
      'deathcare',
      'police',
      'mail',
      'health',
      'fire',
      'transit',
      'goods',
    ]);
  });

  test('the enums the columns and the frame hold keep theirs', () {
    expect(names(TripPurpose.values), const [
      'commute',
      'homeward',
      'errand',
      'outOfTown',
      'visit',
      'through',
      'moveIn',
      'moveOut',
      'freight',
      'service',
      'transit',
    ]);
    expect(names(TravelMode.values), const ['walk', 'car', 'bus', 'rail']);
    expect(names(NodeControlKind.values), const [
      'deadEnd',
      'stub',
      'danglingDeck',
      'continuation',
      'rampMerge',
      'allWayStop',
      'stop',
      'signals',
      'roundabout',
      'uncontrolled',
    ]);
  });

  test('every trip purpose reads as one of the routes view\'s kinds', () {
    expect(TripPurpose.commute.tripKind, TripKind.commuter);
    expect(TripPurpose.homeward.tripKind, TripKind.commuter,
        reason: "the commute synth's return leg is a commuter too");
    expect(TripPurpose.errand.tripKind, TripKind.shopper);
    expect(TripPurpose.freight.tripKind, TripKind.goods);
    expect(TripPurpose.service.tripKind, TripKind.service);
    expect({for (final p in TripPurpose.values) p.tripKind},
        TripKind.values.toSet(),
        reason: 'every kind the view filters by can be reached');
  });
}
