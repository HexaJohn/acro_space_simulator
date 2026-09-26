// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/traffic/agents_codec.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/building_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/citizen_match.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/citizen_population.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/citizen_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/parked_cars.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/population_ledger.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// The agents' save block and switch (docs/plans/agent-traffic.md §14.1,
/// §14.4; §17.4 save_resume, slice 1's part; t4a-implementation.md §4 Q2):
/// the block is the enabled flag and, from T4a, the parked cars; a save and
/// a load keep agents on and keep the cars where they stood; an absent or
/// foreign block leaves the colony without agents; and switching them off
/// drops everything they held.
void main() {
  tearDown(AgentTuning.reset);

  test('the save block is the flag, and a round trip keeps agents on', () {
    expect(AgentsCodec.encode(enabled: true), {'v': 1, 'enabled': true},
        reason: 'a colony that has parked nothing writes what it always did');
    expect(AgentsCodec.enabledOf({'v': 1, 'enabled': true}), isTrue);
    expect(AgentsCodec.enabledOf({'v': 1, 'enabled': false}), isFalse);
    expect(AgentsCodec.enabledOf(null), isNull, reason: 'no block: off');
    expect(AgentsCodec.enabledOf({'v': 2, 'enabled': true}), isTrue,
        reason: 'the version T4a writes when it has cars to write');
    expect(AgentsCodec.enabledOf({'v': 3, 'enabled': true}), isNull,
        reason: 'a block this build cannot read is dropped');
    expect(AgentsCodec.enabledOf({'v': 1}), isNull);
    expect(AgentsCodec.enabledOf('agents'), isNull);

    final city = starterKit();
    final a = agentsOn(city);
    expect(a.hasState, isTrue);
    final json = jsonDecode(jsonEncode(a.toJson()));
    expect((CityAgents(city)..restore(json)).enabled, isTrue);
    expect((CityAgents(city)..restore(null)).enabled, isFalse);
    expect(CityAgents(city).hasState, isFalse,
        reason: 'a colony without agents writes no block');
  });

  test('switched off, the agents drop everything; the A/B knob pauses them',
      () {
    final idle = CityAgents(town());
    expect(idle.vehicles, isNull, reason: 'the constructor builds nothing');
    idle.advance(0.5);
    expect(idle.vehicles, isNull, reason: 'nor does a disabled advance');
    expect(idle.stats.commuteEff, 1.0);

    AgentTuning.commuteRatePerResident = 0.004;
    final a = agentsOn(town());
    runAgents(a, 60);
    expect(a.liveVehicles, greaterThan(0));
    AgentTuning.agentsOn = false;
    expect(a.enabled, isFalse);
    final t = a.timeUs;
    a.advance(0.5);
    expect(a.timeUs, t, reason: 'paused, not dropped');
    expect(a.liveVehicles, greaterThan(0));
    AgentTuning.agentsOn = true;
    final passes = a.readout.passes;
    expect(passes, greaterThan(0));
    a.enabled = false;
    expect(a.vehicles, isNull);
    expect(a.frame.count, 0);
    a.enabled = true;
    expect(a.readout.passes, passes,
        reason: 'the readout\'s count never goes back, even across a restart');
    runAgents(a, 30);
    expect(a.readout.passes, greaterThan(passes));
  });

  group('the parked cars go round (§14.1, §4 Q2)', () {
    /// Two homes with a car each, a kerb car and a garaged one, in a table
    /// whose slot order is NOT the sorted site order.
    (ParkedCarTable, _World) parked() {
      final t = ParkedCarTable(capacity: 16);
      final w = _World(sites: const ['lot-a', 'lot-b']);
      w.carSite[t.parkLot(
          building: 2,
          row: 1,
          stall: 0,
          stallKey: 777,
          ownerKind: CarOwnerKind.homePool,
          owner: 5,
          kind: 0,
          variant: 3)] = 'lot-b';
      w.carSite[t.parkLot(
          building: 1,
          row: 0,
          stall: 2,
          stallKey: 555,
          ownerKind: CarOwnerKind.commuter,
          owner: 6,
          kind: 0,
          variant: 1)] = 'lot-a';
      final kerb = t.parkKerb(
          building: 1,
          edge: 4,
          slot: 9,
          side: 1,
          ownerKind: CarOwnerKind.commuter,
          owner: 7,
          kind: 0,
          variant: 2);
      w.carSite[kerb] = 'lot-a';
      w.pose[kerb] = (12.5, -40.25, 1.5);
      w.carSite[t.garage(
          building: 2,
          ownerKind: CarOwnerKind.homePool,
          owner: 8,
          kind: 0,
          variant: 0)] = 'lot-b';
      return (t, w);
    }

    test('a lot car comes back by (siteId, stallKey), never by index', () {
      final (cars, world) = parked();
      final block = AgentsCodec.encode(
          enabled: true, cars: cars, world: world);
      expect(block['v'], 2);
      expect(block['sites'], ['lot-a', 'lot-b'], reason: 'sorted (§14.1)');
      final rows = (block['cars']! as List).cast<List<num>>();
      expect(rows, hasLength(4));
      expect(
          rows,
          contains(equals([
            CarOwnerKind.commuter.index,
            6,
            CarWhere.lot.index,
            0,
            555,
            0,
            1,
          ])),
          reason: '[ownerKind, ownerIdx, where, siteIdx, stallKey, kind, '
              'variant]');
      expect(
          rows,
          contains(equals([
            CarOwnerKind.commuter.index,
            7,
            CarWhere.kerb.index,
            12.5,
            -40.25,
            1500,
            0,
            2,
          ])),
          reason: 'a kerb car is (e, n, headingMilli)');
      expect(
          rows,
          contains(equals([
            CarOwnerKind.homePool.index,
            8,
            CarWhere.garaged.index,
            1,
            -1,
            0,
            0,
          ])),
          reason: 'a garaged car keeps the site it belongs to, and no key');

      // Through JSON, as the colony's save goes.
      final saved = AgentsCodec.decode(jsonDecode(jsonEncode(block)))!;
      expect(saved.version, 2);
      expect(saved.enabled, isTrue);
      expect(saved.sites, ['lot-a', 'lot-b']);
      expect(saved.cars.count, 4);

      final back = _World(sites: const ['lot-a', 'lot-b'])
        ..keys[0] = {555: 2}
        ..keys[1] = {777: 0};
      expect(back.restore(saved), (lot: 2, kerb: 1, garaged: 1, dropped: 0));
      expect(back.placed, hasLength(4));
      expect(back.placed, contains('lot 0 stall 2 owner 6 variant 1'));
      expect(back.placed, contains('lot 1 stall 0 owner 5 variant 3'),
          reason: 'the key, not the index: stall 0 of the other site');
      expect(back.placed, contains('kerb 12.5,-40.25 @1500 owner 7'));
      expect(back.placed, contains('garage 1 building -1 owner 8'));
    });

    test('a key that is gone takes the nearest free stall, then the garage',
        () {
      final (cars, world) = parked();
      final saved = AgentsCodec.decode(
          jsonDecode(jsonEncode(AgentsCodec.encode(
              enabled: true, cars: cars, world: world))))!;

      // Site 0 kept its key; site 1 re-planned its pad and lost 777, but
      // has a free stall. Its car takes the nearest one.
      final near = _World(sites: const ['lot-a', 'lot-b'])
        ..keys[0] = {555: 2}
        ..free[1] = 3;
      expect(near.restore(saved), (lot: 2, kerb: 1, garaged: 1, dropped: 0));
      expect(near.placed, contains('lot 1 stall 3 owner 5 variant 3'));

      // And with no free stall left, the car is garaged at its site.
      final full = _World(sites: const ['lot-a', 'lot-b'])..keys[0] = {555: 2};
      expect(full.restore(saved), (lot: 1, kerb: 1, garaged: 2, dropped: 0));
      expect(full.placed, contains('garage 1 building -1 owner 5'));

      // A kerb the car cannot be snapped to garages it as well.
      final noKerb = _World(sites: const ['lot-a', 'lot-b'])
        ..keys[0] = {555: 2}
        ..keys[1] = {777: 0}
        ..kerbSnaps = false;
      expect(noKerb.restore(saved), (lot: 2, kerb: 0, garaged: 2, dropped: 0));
      expect(noKerb.placed, contains('garage -1 building -1 owner 7'),
          reason: 'a kerb car belongs to no site row');
    });

    test('an unknown site drops its cars, and only those', () {
      final (cars, world) = parked();
      final saved = AgentsCodec.decode(
          jsonDecode(jsonEncode(AgentsCodec.encode(
              enabled: true, cars: cars, world: world))))!;
      final renamed = _World(sites: const ['lot-a'])..keys[0] = {555: 2};
      expect(renamed.restore(saved), (lot: 1, kerb: 1, garaged: 0, dropped: 2),
          reason: 'lot-b was renamed by a changed plat rule: its parked car '
              'and its garaged car go with it');
      expect(renamed.placed, hasLength(2));
      expect(renamed.placed, contains('lot 0 stall 2 owner 6 variant 1'));
    });

    test('a car garaged at a site with no LOT survives the load', () {
      // The bug this pins: a kerbside site, and a building whose plan has
      // not been made, both have no site row, so reading `rowOfSite` alone
      // could not tell them from a site that is gone — and a car garaged at
      // one was dropped on every load, silently, for good.
      final (cars, world) = parked();
      final saved = AgentsCodec.decode(
          jsonDecode(jsonEncode(AgentsCodec.encode(
              enabled: true, cars: cars, world: world))))!;
      final kerbside = _World(sites: const ['lot-a'])
        ..keys[0] = {555: 2}
        ..lotless.add('lot-b');
      expect(kerbside.restore(saved), (lot: 1, kerb: 1, garaged: 2, dropped: 0),
          reason: 'lot-b keeps its building and loses only its stalls: its '
              'garaged car is garaged again, and the car that stood on a '
              'stall is garaged there too');
      expect(kerbside.placed, hasLength(4));
      expect(kerbside.placed, contains('garage -1 building 200 owner 8'),
          reason: 'garaged at the building it belongs to, so its home pool '
              'can hand it back when its owner drives');
      expect(kerbside.placed, contains('garage -1 building 200 owner 5'));
    });

    test('a lot whose row has not arrived is HELD, and the retry puts its '
        'car on its own key', () {
      // The defect this pins: a site the colony has not synced yet answers
      // −1 to `rowOfSite` exactly as a kerbside one does, and a load was one
      // pass — so a lot car whose plans were still in flight was garaged for
      // good. Now the codec offers it to the world first.
      final (cars, world) = parked();
      final saved = AgentsCodec.decode(
          jsonDecode(jsonEncode(AgentsCodec.encode(
              enabled: true, cars: cars, world: world))))!;

      // Pass 1: lot-b's row is not there yet, and the world is still
      // planning. Its LOT car waits; its GARAGED car does not, because a
      // garaged car is garaged whenever it is asked.
      final late = _World(sites: const ['lot-a'])
        ..keys[0] = {555: 2}
        ..lotless.add('lot-b')
        ..holding = true;
      expect(late.restore(saved), (lot: 1, kerb: 1, garaged: 1, dropped: 0));
      expect(late.held, hasLength(1), reason: 'the one lot car of lot-b');
      expect(late.placed, hasLength(3),
          reason: 'the held car is placed nowhere at all, not garaged');

      // Pass 2: lot-b arrived, with its key. The retry walks only the rows
      // that waited, and puts the car on the very stall it was saved on.
      final rows = Int32List.fromList(late.held);
      final now = _World(sites: const ['lot-a', 'lot-b'])
        ..keys[0] = {555: 2}
        ..keys[1] = {777: 0};
      expect(now.restore(saved, rows: rows, count: rows.length),
          (lot: 1, kerb: 0, garaged: 0, dropped: 0),
          reason: 'the retry touches the held rows and nothing else');
      expect(now.placed, ['lot 1 stall 0 owner 5 variant 3']);
    });

    test('a held row is written back out, so a save-load-save keeps it', () {
      final (cars, world) = parked();
      final block = AgentsCodec.encode(enabled: true, cars: cars, world: world);
      final saved = AgentsCodec.decode(jsonDecode(jsonEncode(block)))!;

      // A colony that placed NOTHING — the load before its first advance —
      // writes the block it is holding back out, byte for byte.
      expect(jsonEncode(AgentsCodec.encode(enabled: true, held: saved)),
          jsonEncode(block));

      // And a colony that placed all but lot-b's lot car writes that row out
      // beside the three it has: the same four rows, the same two sites.
      final part = ParkedCarTable(capacity: 16);
      final pw = _World(sites: const ['lot-a', 'lot-b']);
      for (var i = 0; i < saved.cars.count; i++) {
        if (saved.cars.where[i] == CarWhere.lot.index &&
            saved.cars.stallKey[i] == 777) {
          continue;
        }
        _rebuild(part, pw, saved, i);
      }
      final held = Int32List(1);
      for (var i = 0; i < saved.cars.count; i++) {
        if (saved.cars.where[i] == CarWhere.lot.index &&
            saved.cars.stallKey[i] == 777) {
          held[0] = i;
        }
      }
      expect(
          jsonEncode(AgentsCodec.encode(
              enabled: true,
              cars: part,
              world: pw,
              held: saved,
              heldRows: held,
              heldCount: 1)),
          jsonEncode(block));
    });

    test('a v1 save still loads, with no cars', () {
      final saved = AgentsCodec.decode({'v': 1, 'enabled': true})!;
      expect(saved.version, 1);
      expect(saved.enabled, isTrue);
      expect(saved.sites, isEmpty);
      expect(saved.cars.count, 0);
      final world = _World(sites: const ['lot-a']);
      expect(world.restore(saved), (lot: 0, kerb: 0, garaged: 0, dropped: 0));
      expect(world.placed, isEmpty);

      // And a block of a version this build cannot read is dropped whole.
      expect(AgentsCodec.decode({'v': 3, 'enabled': true, 'cars': []}), isNull);
      expect(AgentsCodec.decode({'v': 0, 'enabled': true}), isNull);
    });

    test('the same cars write the same bytes, whatever order they are in',
        () {
      final (a, wa) = parked();
      final block = AgentsCodec.encode(enabled: true, cars: a, world: wa);

      // The same four cars, made in another order, on other slots, after a
      // row has been freed: exactly what a colony resumed from a save has.
      final b = ParkedCarTable(capacity: 16);
      final wb = _World(sites: const ['lot-a', 'lot-b']);
      final spare = b.garage(
          building: 9,
          ownerKind: CarOwnerKind.none,
          owner: 0,
          kind: 0,
          variant: 0);
      b.remove(spare);
      wb.carSite[b.garage(
          building: 2,
          ownerKind: CarOwnerKind.homePool,
          owner: 8,
          kind: 0,
          variant: 0)] = 'lot-b';
      final kerb = b.parkKerb(
          building: 1,
          edge: 4,
          slot: 9,
          side: 1,
          ownerKind: CarOwnerKind.commuter,
          owner: 7,
          kind: 0,
          variant: 2);
      wb.carSite[kerb] = 'lot-a';
      wb.pose[kerb] = (12.5, -40.25, 1.5);
      wb.carSite[b.parkLot(
          building: 1,
          row: 0,
          stall: 2,
          stallKey: 555,
          ownerKind: CarOwnerKind.commuter,
          owner: 6,
          kind: 0,
          variant: 1)] = 'lot-a';
      wb.carSite[b.parkLot(
          building: 2,
          row: 1,
          stall: 0,
          stallKey: 777,
          ownerKind: CarOwnerKind.homePool,
          owner: 5,
          kind: 0,
          variant: 3)] = 'lot-b';
      expect(jsonEncode(AgentsCodec.encode(enabled: true, cars: b, world: wb)),
          jsonEncode(block));
    });

    test('the car rows are the T4a rows, whether or not there are citizens',
        () {
      // The save-format promise (slice3 §0): slice 3 adds keys to the block
      // and changes NOTHING about how a car is written. The proof that
      // matters is the committed pre-citizens fixture; this is the proof
      // inside one build, and it is the one that fails first when somebody
      // reaches into `_writeCars`.
      final (cars, world) = parked();
      final bare = AgentsCodec.encode(enabled: true, cars: cars, world: world);
      final folk = _People();
      final town = CitizenTable(capacity: 8)
        ..spawn(
            home: 1,
            work: 2,
            car: CitizenTable.carNone,
            state: CitizenState.atHome,
            wakeUs: 5000000);
      final full = AgentsCodec.encode(
          enabled: true,
          cars: cars,
          world: world,
          citizens: town,
          census: folk,
          population: _population(town));
      expect(jsonEncode(full['cars']), jsonEncode(bare['cars']),
          reason: 'not one car row moved');
      expect(full['v'], bare['v']);
      // The citizen's home and job are sites too, so the string table grows
      // — sorted, as it always was — and the CAR rows follow it, exactly as
      // they would if another car had been parked there.
      expect(full['sites'], ['lot-a', 'lot-b', 'site-1', 'site-2']);
      expect(bare['sites'], ['lot-a', 'lot-b']);
      final cit = full['cit']! as Map<String, Object?>;
      expect(cit['home'], [2], reason: 'site-1, after the sort');
      expect(cit['work'], [3]);
    });

    test('the citizens, the budgets and the stream come back as they were',
        () {
      final town = CitizenTable(capacity: 8);
      final a = town.spawn(
          home: 3,
          work: 1,
          car: CitizenTable.carNone,
          state: CitizenState.atWork,
          wakeUs: 61000000,
          flags: CitizenFlags.hasLicence);
      town.spawn(
          home: -1,
          work: -1,
          car: CitizenTable.carNone,
          state: CitizenState.atErrand,
          wakeUs: 1000000);
      final gone = town.spawn(
          home: 2,
          work: -1,
          car: CitizenTable.carNone,
          state: CitizenState.atHome,
          wakeUs: 0);
      town.remove(gone);
      expect(a, isNot(gone));

      final people = _population(town)
        ..ledger.addMigration(1.5)
        ..ledger.addDeath(0.25);
      people.ledger.syncExternal(200);
      people.ledger.writeBack(2);
      people.rng.nextU32();
      people.arrivals = 9;
      people.adopted = 2;
      people.legacyCars = 1;

      final census = _People()..nowUs = 60000000;
      final block = jsonDecode(jsonEncode(AgentsCodec.encode(
          enabled: true,
          citizens: town,
          census: census,
          population: people))) as Map<String, Object?>;
      expect(block['v'], 2,
          reason: 'citizens make it a v2 block even with nothing parked: a '
              'build that reads only the flag must drop it whole (§14.4)');
      expect(block['cars'], isEmpty);
      final cit = block['cit']! as Map<String, Object?>;
      expect(cit['state'],
          [CitizenState.atWork.index, CitizenState.atErrand.index],
          reason: 'dense and in slot order: the dead slot is not written');
      expect(cit['wakeInUs'], [1000000, -59000000],
          reason: 'relative to the save\'s clock (§14.3)');
      expect(cit['flags'], [CitizenFlags.hasLicence, 0]);

      final saved = AgentsCodec.decode(block)!;
      expect(saved.citizens.count, 2);
      final back = CitizenTable(capacity: 8);
      final sink = _People();
      final handles = AgentsCodec.restoreCitizens(saved, back, sink,
          nowUs: 20000000);
      expect(handles, hasLength(2));
      expect(back.liveCount, 2);
      final sl = SlotPool.slotOf(handles[0]);
      expect(back.home[sl], 3, reason: 'site-3 is building 3 again');
      expect(back.work[sl], 1);
      expect(back.state[sl], CitizenState.atWork.index);
      expect(back.wakeUs[sl], 21000000);
      expect(back.flags[sl], CitizenFlags.hasLicence);

      final budgets = PopulationLedger()..restore(saved.ledgerJson);
      expect(budgets.digest(3), people.ledger.digest(3));
      final ranAgain = _population(back)..restore(saved.popJson);
      expect(ranAgain.rng.toJson(), people.rng.toJson(),
          reason: 'the realisation draws the same cars after a load (§17.4)');
      expect(ranAgain.digest(11), people.digest(11));

      // And resumed on the clock it was saved on, the town digests to the
      // town that was saved: the same people, wake for wake (§17.4).
      final twin = CitizenTable(capacity: 8);
      AgentsCodec.restoreCitizens(saved, twin, _People(),
          nowUs: census.nowUs);
      expect(twin.digest(0), town.digest(0));
    });

    test('a home the colony no longer has comes back as no home', () {
      final town = CitizenTable(capacity: 4)
        ..spawn(
            home: 7,
            work: 1,
            car: CitizenTable.carNone,
            state: CitizenState.atHome,
            wakeUs: 0);
      final saved = AgentsCodec.decode(jsonDecode(jsonEncode(
          AgentsCodec.encode(
              enabled: true,
              citizens: town,
              census: _People(),
              population: _population(town)))))!;
      final back = CitizenTable(capacity: 4);
      // `site-7` was renamed by a changed plat rule; `site-1` still stands.
      AgentsCodec.restoreCitizens(saved, back, _People()..gone.add('site-7'),
          nowUs: 0);
      expect(back.home[0], -1, reason: '§14.4: dropped, and re-matched');
      expect(back.work[0], 1);
    });

    test('a citizen\'s car row carries the dense index, never the handle', () {
      // §0 Q4: one direction, one source of truth. The runtime column holds
      // a HANDLE — a generation and a slot — and a handle means nothing to
      // the colony that reads the save back.
      final town = CitizenTable(capacity: 8);
      final first = town.spawn(
          home: 1,
          work: -1,
          car: CitizenTable.carNone,
          state: CitizenState.atHome,
          wakeUs: 0);
      town.remove(first);
      final owner = town.spawn(
          home: 1,
          work: -1,
          car: CitizenTable.carNone,
          state: CitizenState.atHome,
          wakeUs: 0);
      expect(SlotPool.slotOf(owner), 0);
      expect(owner, greaterThan(1), reason: 'a handle, not a slot');

      final cars = ParkedCarTable(capacity: 4);
      final w = _World(sites: const ['site-1']);
      w.carSite[cars.parkLot(
          building: 1,
          row: 0,
          stall: 0,
          stallKey: 4,
          ownerKind: CarOwnerKind.citizen,
          owner: owner,
          kind: 0,
          variant: 0)] = 'site-1';
      final rows = (AgentsCodec.encode(
              enabled: true,
              cars: cars,
              world: w,
              citizens: town,
              census: _People(),
              population: _population(town))['cars']! as List)
          .cast<List<num>>();
      expect(rows.single[0], CarOwnerKind.citizen.index);
      expect(rows.single[1], 0, reason: 'the dense index of the one citizen');

      // And an owner who died between the trip and the save owns nothing.
      town.remove(owner);
      final orphan = (AgentsCodec.encode(
              enabled: true,
              cars: cars,
              world: w,
              citizens: town,
              census: _People(),
              population: _population(town))['cars']! as List)
          .cast<List<num>>();
      expect(orphan.single[1], -1);
    });

    test('an unadopted legacy car is re-saved byte for byte', () {
      // §0 Q3, and the whole promise the pre-citizens fixture stands for: a
      // car whose owner is a BUILDING keeps its kind and its owner until
      // somebody at that building takes it, and a save taken in between is
      // the save that was loaded.
      final cars = ParkedCarTable(capacity: 8);
      final w = _World(sites: const ['home-a', 'home-b']);
      w.carSite[cars.parkLot(
          building: 0,
          row: 0,
          stall: 0,
          stallKey: 5,
          ownerKind: CarOwnerKind.homePool,
          owner: 0,
          kind: 0,
          variant: 1)] = 'home-a';
      w.carSite[cars.garage(
          building: 1,
          ownerKind: CarOwnerKind.commuter,
          owner: 1,
          kind: 0,
          variant: 2)] = 'home-b';
      final town = CitizenTable(capacity: 8);
      final people = _population(town);
      final before = jsonEncode(AgentsCodec.encode(
          enabled: true, cars: cars, world: w));

      // Nobody lives anywhere yet: both cars stand, and the block is the one
      // that was loaded.
      expect(people.adoptLegacy(0, cars), 0);
      expect(people.legacyCars, 2);
      expect(
          jsonEncode(AgentsCodec.encode(
              enabled: true,
              cars: cars,
              world: w,
              citizens: town,
              census: _People(),
              population: people)['cars']),
          jsonEncode(jsonDecode(before)['cars']));

      // One resident moves into home-a. Their car changes hands and nothing
      // else does: the other row is written exactly as it was.
      final c = town.spawn(
          home: 0,
          work: -1,
          car: CitizenTable.carNone,
          state: CitizenState.atHome,
          wakeUs: 0);
      expect(people.adoptLegacy(0, cars), 1);
      expect(people.legacyCars, 1, reason: 'home-b\'s car is still offered');
      expect(town.car[SlotPool.slotOf(c)], isNot(CitizenTable.carNone));
      final after = (AgentsCodec.encode(
              enabled: true,
              cars: cars,
              world: w,
              citizens: town,
              census: _People(),
              population: people)['cars']! as List)
          .cast<List<num>>();
      final legacy = (jsonDecode(before) as Map)['cars']! as List;
      expect(after, hasLength(2));
      expect(jsonEncode(after[0]), jsonEncode(legacy[0]),
          reason: 'the commuter row of home-b, untouched');
      expect(after[1][0], CarOwnerKind.citizen.index);
      expect(after[1][1], 0, reason: 'the dense index of its new owner');
      expect(after[1].sublist(2), legacy[1].sublist(2),
          reason: 'and every other column of it is what it was: the car did '
              'not move, it changed hands');
    });

    test('a row a build did not write is skipped, not half-read', () {
      final saved = AgentsCodec.decode({
        'v': 2,
        'enabled': true,
        'sites': ['lot-a'],
        'cars': [
          [0, 1], // too short
          'not a row',
          [0, 1, 99, 0, 5, 0, 0], // no such `where`
          [0, 1, 1, 12.5, 3.0, 0, 0], // a kerb row without its variant
          [CarOwnerKind.commuter.index, 4, CarWhere.lot.index, 0, 5, 0, 0],
        ],
      })!;
      expect(saved.cars.count, 1, reason: 'the one row that reads');
      expect(saved.cars.owner[0], 4);
      final world = _World(sites: const ['lot-a'])..keys[0] = {5: 1};
      expect(world.restore(saved), (lot: 1, kerb: 0, garaged: 0, dropped: 0));
    });
  });
}

/// A realisation over [citizens] with nothing but tables behind it: the
/// citizen half of the save needs the budgets and the stream a
/// [CitizenPopulation] carries, and the codec asks it for nothing else.
CitizenPopulation _population(CitizenTable citizens) {
  final buildings = BuildingTable();
  return CitizenPopulation(
      citizens: citizens,
      buildings: buildings,
      ledger: PopulationLedger(),
      match: CitizenMatch(citizens, buildings, TrafficRng(1)),
      rng: TrafficRng(2));
}

/// The colony a citizen is written out of and read back into: building slot
/// `n` is the site `site-n`, and [gone] names the sites a changed plat rule
/// renamed away while the save sat on disk.
class _People implements CitizenSaveSource, CitizenRestoreSink {
  /// The clock the wakes are written against (§14.3).
  @override
  int nowUs = 0;

  final List<String> gone = [];

  @override
  String? siteIdOfBuilding(int buildingSlot) =>
      buildingSlot < 0 ? null : 'site-$buildingSlot';

  @override
  int buildingOfSite(String siteId) {
    if (gone.contains(siteId)) return -1;
    return int.tryParse(siteId.replaceFirst('site-', '')) ?? -1;
  }
}

/// Saved row [i] of [saved] made a live car of [cars] again, with [world]
/// told which site it belongs to and where a kerb car of it stands: the state
/// a colony that PLACED that row holds, so what it writes next can be
/// compared with what it read.
void _rebuild(
    ParkedCarTable cars, _World world, SavedAgents saved, int i) {
  final c = saved.cars;
  final s = c.site[i];
  final ownerKind = CarOwnerKind.values[c.ownerKind[i]];
  final int car;
  switch (CarWhere.values[c.where[i]]) {
    case CarWhere.lot:
      car = cars.parkLot(
          building: 1,
          row: 0,
          stall: 0,
          stallKey: c.stallKey[i],
          ownerKind: ownerKind,
          owner: c.owner[i],
          kind: c.kind[i],
          variant: c.variant[i]);
    case CarWhere.kerb:
      car = cars.parkKerb(
          building: 1,
          edge: 4,
          slot: 9,
          side: 1,
          ownerKind: ownerKind,
          owner: c.owner[i],
          kind: c.kind[i],
          variant: c.variant[i]);
      world.pose[car] = (c.e[i], c.n[i], c.heading[i]);
    case CarWhere.garaged:
      car = cars.garage(
          building: 2,
          ownerKind: ownerKind,
          owner: c.owner[i],
          kind: c.kind[i],
          variant: c.variant[i]);
  }
  if (s >= 0) world.carSite[car] = saved.sites[s];
}

/// The colony a save is written from and read back into: which site each car
/// belongs to, where a kerb car stood, and what the site table answers about
/// stalls once the plans have been drained again.
class _World implements CarSaveSource, CarRestoreSink {
  _World({required this.sites});

  /// Site ids the colony still has a LOT at, in the save's own order.
  final List<String> sites;

  /// Site ids whose building is still standing but has no lot to park in: a
  /// kerbside plan, or one that has not been made. Their cars are garaged
  /// there, never dropped.
  final List<String> lotless = [];

  /// Per car handle: its site id, and a kerb car's pose.
  final Map<int, String> carSite = {};
  final Map<int, (double, double, double)> pose = {};

  /// Per site row: the stall each surviving key names, and the free stall
  /// the nearest-free fallback would take (−1 for none).
  final Map<int, Map<int, int>> keys = {};
  final Map<int, int> free = {};

  /// Whether a saved kerb car can still be snapped to a slot.
  bool kerbSnaps = true;

  /// Whether this colony's plans are still arriving, so a lot car whose site
  /// has no row is HELD rather than garaged (§14.1 as built). A settled
  /// colony — every test above — holds nothing.
  bool holding = false;

  /// The rows [holdForSite] took, in the order the codec offered them.
  final List<int> held = [];

  /// What was put back, in the order the codec put it.
  final List<String> placed = [];

  /// The cars of the save being restored, set by [restore].
  SavedCars? cars;

  /// [saved] put back into this colony: the codec names cars by their row in
  /// the block it decoded, so the world reads their columns from it. [rows]
  /// is a retry over the rows a previous pass held, [count] of them.
  RestoreTally restore(SavedAgents saved, {Int32List? rows, int count = 0}) {
    cars = saved.cars;
    return AgentsCodec.restoreCars(saved, this, rows: rows, count: count);
  }

  @override
  String? siteIdOf(int car) => carSite[car];

  @override
  bool kerbPoseOf(int car, Float64List out) {
    final p = pose[car];
    if (p == null) return false;
    out[0] = p.$1;
    out[1] = p.$2;
    out[2] = p.$3;
    return true;
  }

  @override
  int rowOfSite(String siteId) => sites.indexOf(siteId);

  @override
  int buildingOfSite(String siteId) {
    final row = sites.indexOf(siteId);
    if (row >= 0) return 100 + row;
    final k = lotless.indexOf(siteId);
    return k < 0 ? -1 : 200 + k;
  }

  @override
  int stallOfKey(int row, int stallKey) => keys[row]?[stallKey] ?? -1;

  @override
  int nearestFreeStall(int row, int stallKey) => free[row] ?? -1;

  @override
  void parkLot(int car, int row, int stall) => placed.add(
      'lot $row stall $stall owner ${_owner(car)} variant ${_variant(car)}');

  @override
  bool parkKerb(int car) {
    if (!kerbSnaps) return false;
    final c = cars!;
    placed.add('kerb ${c.e[car]},${c.n[car]} '
        '@${(c.heading[car] * AgentsCodec.headingScale).round()} '
        'owner ${_owner(car)}');
    return true;
  }

  @override
  void garage(int car, int row, int building) =>
      placed.add('garage $row building $building owner ${_owner(car)}');

  @override
  bool holdForSite(int car, int building) {
    if (!holding) return false;
    held.add(car);
    return true;
  }

  int _owner(int car) => cars!.owner[car];

  int _variant(int car) => cars!.variant[car];
}
