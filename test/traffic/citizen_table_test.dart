// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/traffic/citizen_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:flutter_test/flutter_test.dart';

/// The citizen table: slots, handles and the per-building lists
/// (docs/plans/agent-traffic.md §2.5, §6.2, §6.3;
/// docs/plans/slice3-implementation.md §1.1). The activity wheel is
/// `activity_wheel_test.dart`.
///
/// Three things here are load-bearing for the packages built on it:
///
/// - a handle survives a doubling, and a handle kept past a death never
///   names the next person to take the slot;
/// - the per-building lists are in ARRIVAL order, because an eviction takes
///   the newest resident and a lay-off the last hired (§6.2, §6.3);
/// - [CitizenTable.digest] is over the columns in slot order, so it does not
///   depend on how the table was filled.
void main() {
  test('a citizen is a handle, and the columns are its slot', () {
    final t = CitizenTable(capacity: 8);
    final c = t.spawn(
        home: 2,
        work: 3,
        car: CitizenTable.carNone,
        state: CitizenState.atWork,
        wakeUs: 1500000,
        flags: CitizenFlags.hasLicence);
    expect(t.isLive(c), isTrue);
    expect(t.liveCount, 1);
    expect(t.highWater, 1);
    final i = CitizenTable.slotOf(c);
    expect(t.home[i], 2);
    expect(t.work[i], 3);
    expect(t.car[i], CitizenTable.carNone);
    expect(t.agent[i], -1);
    expect(t.sleepsNear[i], -1);
    expect(t.state[i], CitizenState.atWork.index);
    expect(t.flags[i], CitizenFlags.hasLicence);
    expect(t.wakeUs[i], 1500000);
    expect(t.itS1[i], -1, reason: 'slice 9 has not shipped');
    expect(t.itS2[i], -1);
    expect(t.handleOf(i), c);
    expect(t.isSlotLive(i), isTrue);
    expect(t.isScheduled(c), isTrue, reason: 'spawn puts them on the wheel');
  });

  test('a full table answers none, and its owner decides to grow', () {
    final t = CitizenTable(capacity: 4);
    final made = [for (var i = 0; i < 4; i++) _add(t, home: i)];
    expect(t.capacity, 4);
    expect(_add(t, home: 0), SlotPool.none,
        reason: 'the table never grows by itself (§2.1)');
    expect(t.liveCount, 4);
    t.grow(8);
    final more = _add(t, home: 1);
    expect(more, isNot(SlotPool.none));
    expect(t.capacity, 8);
    for (final c in made) {
      expect(t.isLive(c), isTrue, reason: 'the doubling kept every handle');
    }
  });

  test('handles, homes and the wheel survive a doubling past 16,384', () {
    final t = CitizenTable();
    expect(t.capacity, 16384, reason: '§2.5 opens at 16,384');
    // Two homes, so the arrival lists are long enough to be worth checking
    // after the copy, and a wake each so the wheel's links move too.
    final made = <int>[];
    for (var i = 0; i < 16384; i++) {
      made.add(_add(t, home: i % 2, work: 2 + i % 3, wakeUs: 1.0 * i));
    }
    expect(_add(t, home: 0), SlotPool.none);
    expect(t.residentsOf(0), 8192);
    expect(t.residentsOf(1), 8192);
    final before = t.digest(kFnvOffset32);

    t.grow(32768);
    expect(t.capacity, 32768);
    expect(t.liveCount, 16384);
    expect(t.digest(kFnvOffset32), before,
        reason: 'a doubling moves nothing but the buffers');
    for (var i = 0; i < 16384; i += 997) {
      final c = made[i];
      expect(t.isLive(c), isTrue);
      expect(t.home[CitizenTable.slotOf(c)], i % 2);
      expect(t.isScheduled(c), isTrue);
    }
    expect(t.newestResident(0), made[16382]);
    expect(t.newestResident(1), made[16383]);

    final past = _add(t, home: 0, work: 2);
    expect(past, isNot(SlotPool.none));
    expect(CitizenTable.slotOf(past), 16384, reason: 'a slot past the old end');
    expect(t.newestResident(0), past);
    expect(t.residentsOf(0), 8193);
    expect(t.liveCount, 16385);
  });

  test('a removed handle never names the next person to take the slot', () {
    final t = CitizenTable(capacity: 4);
    final gone = _add(t, home: 1, work: 5);
    final kept = _add(t, home: 1);
    t.remove(gone);
    expect(t.isLive(gone), isFalse);
    expect(t.liveCount, 1);
    expect(t.residentsOf(1), 1);
    expect(t.workersOf(5), 0, reason: 'a death leaves the job as well');

    final fresh = _add(t, home: 2);
    expect(CitizenTable.slotOf(fresh), CitizenTable.slotOf(gone),
        reason: 'the slot is reused, as SlotPool promises');
    expect(fresh, isNot(gone), reason: 'the handle is not');
    expect(t.isLive(gone), isFalse);
    // Every way in reads the stale handle as nobody, rather than as the new
    // occupant: this is what a citizen handle held over a tick is worth.
    t.remove(gone);
    t.setHome(gone, 9);
    t.setWork(gone, 9);
    t.schedule(gone, 5000000);
    t.unschedule(fresh);
    expect(t.isLive(fresh), isTrue);
    expect(t.home[CitizenTable.slotOf(fresh)], 2);
    expect(t.residentsOf(9), 0);
    expect(t.workersOf(9), 0);
    expect(t.isScheduled(gone), isFalse);
    expect(t.liveCount, 2);
    expect(t.newestResident(1), kept);
  });

  test('the residents of a home are in arrival order, newest last', () {
    final t = CitizenTable(capacity: 8);
    t.ensureBuildings(4);
    final a = _add(t, home: 1);
    final b = _add(t, home: 1);
    final c = _add(t, home: 1);
    expect(t.residentsOf(1), 3);
    expect(_residents(t, 1), [a, b, c]);
    expect(t.firstResident(1), a);
    expect(t.newestResident(1), c, reason: 'an eviction takes this one');

    // Moving house is an arrival at the new home and a departure from the
    // old one; moving in where they already live is neither.
    t.setHome(b, 2);
    expect(_residents(t, 1), [a, c]);
    expect(_residents(t, 2), [b]);
    t.setHome(a, 1);
    expect(_residents(t, 1), [a, c], reason: 'not a new arrival');

    final d = _add(t, home: 1);
    expect(_residents(t, 1), [a, c, d]);
    expect(t.newestResident(1), d);
  });

  test('a resident taken out of the middle leaves both neighbours linked',
      () {
    final t = CitizenTable(capacity: 8);
    final made = [for (var i = 0; i < 5; i++) _add(t, home: 3)];
    // The middle one by eviction, the next by death: both are a middle
    // removal, and the list has to close over each.
    t.setHome(made[2], -1);
    expect(_residents(t, 3), [made[0], made[1], made[3], made[4]]);
    expect(t.residentsOf(3), 4);
    expect(t.home[CitizenTable.slotOf(made[2])], -1, reason: 'homeless');

    t.remove(made[1]);
    expect(_residents(t, 3), [made[0], made[3], made[4]]);
    expect(t.residentsOf(3), 3);
    expect(t.firstResident(3), made[0]);
    expect(t.newestResident(3), made[4]);

    // The ends as well: a head and a tail removal must move the head and the
    // tail, not orphan them.
    t.remove(made[0]);
    expect(_residents(t, 3), [made[3], made[4]]);
    expect(t.firstResident(3), made[3]);
    t.remove(made[4]);
    expect(_residents(t, 3), [made[3]]);
    expect(t.newestResident(3), made[3]);
    t.remove(made[3]);
    expect(_residents(t, 3), isEmpty);
    expect(t.residentsOf(3), 0);
    expect(t.firstResident(3), SlotPool.none);
    expect(t.newestResident(3), SlotPool.none);
  });

  test('the workers of a job are last hired, last: a lay-off reads the tail',
      () {
    final t = CitizenTable(capacity: 8);
    final a = _add(t, home: 0, work: 7);
    final b = _add(t, home: 0, work: 7);
    final c = _add(t, home: 0, work: 7);
    expect(t.workersOf(7), 3);
    expect(_workers(t, 7), [a, b, c]);
    expect(t.firstWorker(7), a);
    expect(t.newestWorker(7), c);

    // §6.3's job loss: last hired, first out, and the next lay-off takes the
    // one hired before them.
    t.setWork(t.newestWorker(7), -1);
    expect(t.newestWorker(7), b);
    t.setWork(t.newestWorker(7), -1);
    expect(t.newestWorker(7), a);
    expect(t.workersOf(7), 1);
    expect(t.workersOf(-1), 0, reason: 'unemployment is not a building');
  });

  test('a building slot past the last sync is followed, not dropped', () {
    final t = CitizenTable(capacity: 8);
    // The heads are sized by [ensureBuildings] after a building sync, but a
    // citizen housed in a lot built since must still be linked.
    final far = _add(t, home: 300, work: 301);
    expect(t.residentsOf(300), 1);
    expect(t.workersOf(301), 1);
    expect(t.newestResident(300), far);
    t.ensureBuildings(64);
    expect(t.residentsOf(300), 1, reason: 'a smaller sync shrinks nothing');
    expect(t.newestResident(300), far);
    expect(t.residentsOf(1 << 20), 0, reason: 'a slot nobody lives at');
  });

  test('the digest is the columns in slot order, not the filling order', () {
    final a = CitizenTable(capacity: 4);
    _add(a, home: 7, work: 8, wakeUs: 3000000);
    _add(a, home: 9, work: 10, wakeUs: 9000000);

    // The same two people, taken on with nothing and then housed, hired and
    // scheduled in the other order: a different history, the same columns.
    final b = CitizenTable(capacity: 4);
    final b0 = _add(b);
    final b1 = _add(b);
    b.setHome(b1, 9);
    b.setWork(b1, 10);
    b.schedule(b1, 9000000);
    b.setHome(b0, 7);
    b.setWork(b0, 8);
    b.schedule(b0, 3000000);
    expect(b.digest(kFnvOffset32), a.digest(kFnvOffset32));

    // The same people in the other slots IS another table: slot order is
    // what the digest reads, and what a save writes the rows in (§14.1).
    final c = CitizenTable(capacity: 4);
    _add(c, home: 9, work: 10, wakeUs: 9000000);
    _add(c, home: 7, work: 8, wakeUs: 3000000);
    expect(c.digest(kFnvOffset32), isNot(a.digest(kFnvOffset32)));
  });

  test('the digest moves when any column does', () {
    CitizenTable build() {
      final t = CitizenTable(capacity: 4);
      t.spawn(
          home: 1,
          work: 2,
          car: 44,
          state: CitizenState.atWork,
          wakeUs: 2500000,
          flags: CitizenFlags.hasLicence);
      return t;
    }

    final base = build().digest(kFnvOffset32);
    // Every column, written the way its owner writes it — through the
    // setters where there are setters, in place where C, D and E write the
    // cell themselves — and each one moves the digest.
    for (final write in <void Function(CitizenTable)>[
      (t) => t.setHome(t.handleOf(0), 3),
      (t) => t.setWork(t.handleOf(0), 3),
      (t) => t.schedule(t.handleOf(0), 4500000),
      (t) => _add(t, home: 1),
      (t) => t.car[0] = CitizenTable.carDriving,
      (t) => t.agent[0] = 9,
      (t) => t.sleepsNear[0] = 4,
      (t) => t.state[0] = CitizenState.travelling.index,
      (t) => t.flags[0] = CitizenFlags.sick,
      (t) => t.itS1[0] = 2,
      (t) => t.itL1[0] = 2,
      (t) => t.itX1[0] = 2,
      (t) => t.itX2[0] = 2,
      (t) => t.itL2[0] = 2,
      (t) => t.itS2[0] = 2,
    ]) {
      final t = build();
      write(t);
      expect(t.digest(kFnvOffset32), isNot(base));
    }
    // A wake an hour on from another is not the same wake: microseconds pass
    // 2^32 in 71 agent minutes, and a digest folding one word would tie.
    final near = build();
    near.schedule(near.handleOf(0), 1000000);
    final far = build();
    far.schedule(far.handleOf(0), 1000000 + 4294967296.0);
    expect(near.digest(kFnvOffset32), isNot(base));
    expect(far.digest(kFnvOffset32), isNot(near.digest(kFnvOffset32)));
  });

  test('a dead row folds nothing, whatever it held', () {
    final t = CitizenTable(capacity: 4);
    final alone = CitizenTable(capacity: 4);
    final gone = _add(t, home: 5, work: 6, wakeUs: 7000000);
    t.car[CitizenTable.slotOf(gone)] = 12;
    t.agent[CitizenTable.slotOf(gone)] = 13;
    _add(t, home: 1);
    _add(alone, home: 1);
    // The live citizen is in slot 1 either way; the dead one is only a hole.
    t.remove(gone);
    expect(t.liveCount, 1);
    expect(t.digest(kFnvOffset32), isNot(alone.digest(kFnvOffset32)),
        reason: 'the live citizen sits in a different slot');
    final hole = CitizenTable(capacity: 4);
    final holeGone = _add(hole, home: 2);
    _add(hole, home: 1);
    hole.remove(holeGone);
    expect(hole.digest(kFnvOffset32), t.digest(kFnvOffset32),
        reason: 'what the dead row held is not state');
  });
}

/// A citizen with a car of their own choosing left out, since only the
/// columns under test vary here.
int _add(CitizenTable t,
        {int home = -1, int work = -1, double wakeUs = 0}) =>
    t.spawn(
        home: home,
        work: work,
        car: CitizenTable.carNone,
        state: CitizenState.atHome,
        wakeUs: wakeUs);

/// Every resident of [buildingSlot], as handles, in arrival order.
List<int> _residents(CitizenTable t, int buildingSlot) {
  final out = <int>[];
  for (var c = t.firstResident(buildingSlot);
      c != SlotPool.none;
      c = t.nextResident(c)) {
    out.add(c);
  }
  return out;
}

/// Every worker of [buildingSlot], as handles, in the order they were hired.
List<int> _workers(CitizenTable t, int buildingSlot) {
  final out = <int>[];
  for (var c = t.firstWorker(buildingSlot);
      c != SlotPool.none;
      c = t.nextWorker(c)) {
    out.add(c);
  }
  return out;
}
