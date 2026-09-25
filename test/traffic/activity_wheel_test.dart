// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/traffic/citizen_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:flutter_test/flutter_test.dart';

/// The activity wheel (docs/plans/agent-traffic.md §2.5, §6.4;
/// docs/plans/slice3-implementation.md §1.1): 512 buckets of half a second,
/// an overflow list for a wake past the 256 s horizon, and one promise —
/// waking the due citizens costs O(due).
///
/// Everything §6.4 does hangs off that promise. A town of five thousand
/// wakes a handful of people a sub-step; if the wheel cost a sweep of its
/// buckets, or of its citizens, the activity loop would price a whole town's
/// day into every 0.2 s step. So the tests below assert on the WORK the wheel
/// reports doing, never on wall time, which on a test machine measures the
/// machine.
///
/// The other half is that nothing is lost: a citizen handed to [takeDue] is
/// handed over once, in bucket order and then slot order, and a wake beyond
/// the horizon comes back when the wheel has wrapped round to it.
void main() {
  test('the due come out in bucket order, then slot order', () {
    final t = CitizenTable(capacity: 16);
    // Three buckets, filled in an order that is neither: the wheel has to
    // put them back in time order, and each bucket in slot order.
    final b = _at(t, 2);
    final a = _at(t, 1);
    final e = _at(t, 2);
    final c = _at(t, 1);
    final d = _at(t, 0);
    expect(_drain(t, _us(3)), [d, a, c, b, e]);
    expect(t.liveCount, 5, reason: 'a wake is not a removal');
    for (final h in [a, b, c, d, e]) {
      expect(t.isScheduled(h), isFalse, reason: 'and it is off the wheel');
    }
    expect(_drain(t, _us(3)), isEmpty, reason: 'nobody comes twice');
  });

  test('exactly the due, and only when they are due', () {
    final t = CitizenTable(capacity: 16);
    final now = _at(t, 0);
    final soon = _at(t, 1);
    final later = _at(t, 40);
    // Halfway through bucket 0: the wake is the time, the bucket only the
    // index of it.
    expect(_drain(t, 250000), [now]);
    expect(_drain(t, 250000), isEmpty);
    expect(_drain(t, _us(1) - 1), isEmpty, reason: 'a µs before bucket 1');
    expect(_drain(t, _us(1)), [soon]);
    expect(_drain(t, _us(39)), isEmpty);
    expect(_drain(t, _us(40)), [later]);
    expect(t.liveCount, 3);
  });

  test('waking the due costs the due, not the wheel', () {
    final t = CitizenTable(capacity: 4096);
    // A town's worth of wakes spread over the whole horizon, as §6.4's
    // dwells spread them.
    for (var i = 0; i < 2048; i++) {
      _at(t, i % CitizenTable.wheelBuckets);
    }
    final out = Int32List(64);
    // Sweep the wheel a tick at a time. Each tick holds four wakes, and the
    // work is those four and the bucket they sat in — never the 512.
    var woken = 0;
    for (var tick = 0; tick < CitizenTable.wheelBuckets; tick++) {
      final n = t.takeDue(_us(tick), out, out.length);
      expect(n, 4, reason: 'tick $tick');
      expect(t.wheelWork, lessThanOrEqualTo(n + 2),
          reason: 'tick $tick read one bucket and its four rows');
      woken += n;
    }
    expect(woken, 2048);
    expect(t.wheelWork, lessThan(CitizenTable.wheelBuckets ~/ 8),
        reason: 'the cost never has the wheel\'s size in it');

    // And an idle wheel costs nothing at all.
    for (var tick = CitizenTable.wheelBuckets;
        tick < CitizenTable.wheelBuckets + 8;
        tick++) {
      expect(t.takeDue(_us(tick), out, out.length), 0);
      expect(t.wheelWork, lessThanOrEqualTo(2));
    }
  });

  test('over the cap the rest keep their order and their place', () {
    final t = CitizenTable(capacity: 32);
    final made = [for (var i = 0; i < 12; i++) _at(t, i % 3)];
    final due = [
      ...made.where((h) => made.indexOf(h) % 3 == 0),
      ...made.where((h) => made.indexOf(h) % 3 == 1),
      ...made.where((h) => made.indexOf(h) % 3 == 2),
    ];
    final out = Int32List(12);
    // Five at a time, as §6.5's spawn cap takes them: three calls, the same
    // twelve people, in the same order, none of them twice.
    final got = <int>[];
    for (var call = 0; call < 3; call++) {
      final n = t.takeDue(_us(2), out, 5);
      expect(n, call < 2 ? 5 : 2);
      got.addAll(out.take(n));
    }
    expect(got, due);
    expect(t.takeDue(_us(2), out, 5), 0);
  });

  test('a wake past the horizon waits on the overflow and comes back', () {
    final t = CitizenTable(capacity: 16);
    const beyond = CitizenTable.wheelBuckets; // 256 s: one tick past the end
    final far = _at(t, beyond + 7);
    final veryFar = _at(t, 4 * beyond + 3);
    final near = _at(t, 5);
    expect(_drain(t, _us(5)), [near]);
    // Nothing comes early, through the whole revolution it is waiting out.
    for (var tick = 6; tick < beyond; tick++) {
      expect(_drain(t, _us(tick)), isEmpty, reason: 'tick $tick');
    }
    // The wheel wraps: the overflow is re-read, and the wake lands in the
    // bucket it is actually due in — not at the wrap, seven ticks after it.
    expect(_drain(t, _us(beyond)), isEmpty);
    expect(_drain(t, _us(beyond + 6)), isEmpty);
    expect(_drain(t, _us(beyond + 7)), [far]);
    expect(t.isScheduled(veryFar), isTrue, reason: 'still waiting it out');

    // And the one four revolutions out survives every wrap between.
    for (var tick = beyond + 8; tick < 4 * beyond + 3; tick++) {
      expect(_drain(t, _us(tick)), isEmpty, reason: 'tick $tick');
    }
    expect(_drain(t, _us(4 * beyond + 3)), [veryFar]);
    expect(_drain(t, _us(9 * beyond)), isEmpty, reason: 'and never twice');
  });

  test('a jump of more than a revolution wakes everyone once', () {
    final t = CitizenTable(capacity: 64);
    const beyond = CitizenTable.wheelBuckets;
    // On the wheel, on the overflow, and past the far end of the jump.
    final onWheel = [for (var i = 0; i < 8; i++) _at(t, 3 + i * 60)];
    final overflow = [for (var i = 0; i < 4; i++) _at(t, beyond + i * 300)];
    final after = _at(t, 20 * beyond);
    final got = _drain(t, _us(10 * beyond));
    expect(got.length, 12, reason: 'the whole wheel and the overflow with it');
    expect(got.toSet(), {...onWheel, ...overflow});
    expect(t.isScheduled(after), isTrue);
    expect(_drain(t, _us(10 * beyond)), isEmpty);
    expect(_drain(t, _us(20 * beyond)), [after],
        reason: 'the jump did not lose the one past it');
  });

  test('a wake in the past is due at once, not half a horizon later', () {
    final t = CitizenTable(capacity: 16);
    final out = Int32List(8);
    expect(t.takeDue(_us(100), out, 8), 0);
    // Scheduled behind the cursor — a dwell that ended while the citizen was
    // waiting for a path, a load at an older clock.
    final late = _at(t, 4);
    final now = _at(t, 100);
    expect(_drain(t, _us(100)), [late, now]);
  });

  test('unschedule then schedule moves a citizen between buckets', () {
    final t = CitizenTable(capacity: 16);
    final a = _at(t, 3);
    final b = _at(t, 3);
    final c = _at(t, 3);
    t.unschedule(b);
    expect(t.isScheduled(b), isFalse);
    expect(_drain(t, _us(3)), [a, c], reason: 'the bucket closed over them');
    t.schedule(b, _us(9).toDouble());
    expect(t.isScheduled(b), isTrue);
    expect(_drain(t, _us(8)), isEmpty);
    expect(_drain(t, _us(9)), [b]);

    // And scheduling a citizen who is already on the wheel MOVES them: an
    // activity cut short must not leave a second wake behind (§6.4).
    final d = _at(t, 20);
    t.schedule(d, _us(11).toDouble());
    expect(_drain(t, _us(11)), [d]);
    expect(_drain(t, _us(30)), isEmpty, reason: 'no second wake was left');

    // Off the wheel entirely: removed, and the bucket still whole.
    final e = _at(t, 40);
    final f = _at(t, 40);
    t.remove(e);
    expect(_drain(t, _us(40)), [f]);
  });

  test('the overflow keeps its own: unschedule, move, and removal', () {
    final t = CitizenTable(capacity: 16);
    const beyond = CitizenTable.wheelBuckets;
    final dropped = _at(t, beyond + 2);
    final moved = _at(t, beyond + 2);
    final gone = _at(t, beyond + 2);
    final stays = _at(t, beyond + 2);
    t.unschedule(dropped);
    t.schedule(moved, _us(7).toDouble());
    t.remove(gone);
    expect(_drain(t, _us(7)), [moved], reason: 'out of the overflow, early');
    expect(_drain(t, _us(beyond + 2)), [stays]);
    expect(t.isScheduled(dropped), isFalse);
    expect(_drain(t, _us(4 * beyond)), isEmpty);
  });

  test('a wake that is no time at all is due now, not never', () {
    final t = CitizenTable(capacity: 16);
    final nan = _add(t, double.nan);
    final past = _add(t, -5000000);
    final infinite = _add(t, double.infinity);
    expect(_drain(t, 0), [nan, past],
        reason: 'a NaN wake is read as now, never kept in the column');
    expect(t.wakeUs[CitizenTable.slotOf(nan)], 0);
    // Infinity saturates: it waits, for ever, rather than wrapping into the
    // past (traffic_time.dart's rule for clocks).
    expect(t.wakeUs[CitizenTable.slotOf(infinite)].isFinite, isTrue);
    expect(t.isScheduled(infinite), isTrue);
    expect(_drain(t, _us(100000)), isEmpty);
  });

  test('a doubling carries the wheel with it', () {
    final t = CitizenTable(capacity: 4);
    final early = [for (var i = 0; i < 4; i++) _at(t, 2)];
    t.grow(8);
    final late = [for (var i = 0; i < 4; i++) _at(t, 2)];
    expect(_drain(t, _us(2)), [...early, ...late],
        reason: 'the links copied, and the new rows sort in after them');
  });

  test('a thousand schedule and wake cycles allocate no new buffer', () {
    final t = CitizenTable(capacity: 1024);
    t.ensureBuildings(32);
    for (var i = 0; i < 256; i++) {
      t.spawn(
          home: i % 32,
          work: (i + 7) % 32,
          car: CitizenTable.carNone,
          state: CitizenState.atHome,
          wakeUs: _us(i % 64).toDouble());
    }
    final out = Int32List(64);
    var nowUs = 0;
    // Warm up, and then a thousand sub-steps of the §6.4 loop: everyone
    // woken is scheduled again a dwell later, and the table is asked what it
    // is holding before and after.
    void step() {
      nowUs += kStepUs;
      final n = t.takeDue(nowUs, out, out.length);
      for (var k = 0; k < n; k++) {
        final c = out[k];
        t.setHome(c, (t.home[CitizenTable.slotOf(c)] + 1) % 32);
        t.setWork(c, (t.work[CitizenTable.slotOf(c)] + 3) % 32);
        t.schedule(c, nowUs + _us(30 + k % 90).toDouble());
      }
    }

    for (var i = 0; i < 400; i++) {
      step();
    }
    final before = <String, Object>{};
    t.collectBuffers(before, 'citizens');
    expect(before, isNotEmpty);
    final liveCount = t.liveCount;
    for (var i = 0; i < 1000; i++) {
      step();
    }
    final after = <String, Object>{};
    t.collectBuffers(after, 'citizens');
    expect(after.keys.toList(), before.keys.toList());
    final warm = Set<Object>.identity()..addAll(before.values);
    for (final name in after.keys) {
      expect(warm.contains(after[name]), isTrue, reason: '$name was replaced');
    }
    expect(t.liveCount, liveCount, reason: 'the window did its work');
    expect(t.capacity, 1024, reason: 'and never grew to do it');
  });
}

/// A citizen due at tick [tick] of the wheel, with no home and no job: what
/// this file is about is when they wake, not where they live.
int _at(CitizenTable t, int tick) => _add(t, _us(tick).toDouble());

int _add(CitizenTable t, double wakeUs) => t.spawn(
    home: -1,
    work: -1,
    car: CitizenTable.carNone,
    state: CitizenState.atHome,
    wakeUs: wakeUs);

/// Whole ticks of the wheel in µs: `tick` half-seconds.
int _us(int tick) => (tick * CitizenTable.wheelTickS * kUsPerSecond).round();

/// Everyone due at or before [nowUs], in the order the wheel hands them over.
List<int> _drain(CitizenTable t, int nowUs) {
  final out = Int32List(256);
  final got = <int>[];
  while (true) {
    final n = t.takeDue(nowUs, out, out.length);
    for (var i = 0; i < n; i++) {
      got.add(out[i]);
    }
    if (n < out.length) break;
  }
  expect(got.toSet(), hasLength(got.length), reason: 'nobody came twice');
  expect(got.every((h) => h != SlotPool.none), isTrue);
  return got;
}
