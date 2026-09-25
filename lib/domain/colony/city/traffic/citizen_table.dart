// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The citizens: where each one lives, works, keeps their car, and what they
/// are doing until when (docs/plans/agent-traffic.md §2.5, §6.2, §6.4;
/// docs/plans/slice3-implementation.md §1.1).
///
/// A citizen is a SLOT with typed columns, as a vehicle and a parked car are
/// (§2.1): one Dart object per citizen would be one live object per citizen
/// for the collector to mark, and a town holds far more citizens than cars.
/// Whatever remembers a citizen holds a HANDLE, so a handle kept past a death
/// or an emigration reads stale instead of naming the next person to take the
/// slot.
///
/// Three structures hang off the columns, and each is what makes one question
/// cheap enough to ask in the tick:
///
/// - **The activity wheel** ([schedule], [takeDue]): [wheelBuckets] buckets of
///   [wheelTickS] seconds — a 256 s horizon — threaded with intrusive links,
///   plus an overflow list for a citizen due beyond it, rescanned whenever the
///   wheel wraps. Waking the due costs O(due), not O(citizens): §2.5.
/// - **The per-building lists** ([homeNext], [workNext] and their prevs):
///   every resident of a home and every worker of a job, in ARRIVAL order, so
///   an eviction can take the newest resident and a lay-off the last hired
///   (§6.2's invariants, §6.3's job loss) without a scan of the town.
/// - **The itinerary columns** ([itS1] … [itS2]): slice 9's locked transit
///   trip, −1 throughout until then (§4.9).
///
/// The table never grows by itself (§2.1): [spawn] on a full table answers
/// [SlotPool.none] and its owner decides whether this is a moment it may
/// [grow] — doubling past 16,384, keeping every handle live.
///
/// **Package A owns the bodies.** P0 fixes this surface so that B (matching),
/// C (the activity loop), D (population and persistence) and E (the wiring)
/// can be written against it at the same time; everything but the constructor,
/// the cheap getters and [collectBuffers] throws `UnimplementedError` until A
/// lands.
library;

import 'dart:typed_data';

import 'slot_pool.dart';

/// What a citizen is doing. The SAVE INDEX: append-only (§14.1).
enum CitizenState {
  atHome,
  travelling,
  atWork,
  atErrand,
  outOfTown,
  movingIn,
  leaving,
  riding,
}

/// The bits of [CitizenTable.flags] (§2.5).
abstract final class CitizenFlags {
  /// Waiting for an ambulance (§9.2), late for work today, and holds a
  /// driving licence at all — the last is drawn once, at arrival (§6.6).
  static const int sick = 1, lateToday = 2, hasLicence = 4;
}

/// The citizens, in typed columns. See the library comment.
class CitizenTable {
  CitizenTable({int capacity = 16384}) : pool = SlotPool(capacity) {
    _allocColumns(capacity);
  }

  /// [car] while the citizen is driving it: the row left the parked table
  /// and the vehicle IS the car (§2.5).
  static const int carDriving = -1;

  /// [car] of a citizen who owns none.
  static const int carNone = -2;

  /// The activity wheel's shape (§2.5): 512 buckets of half a second, a
  /// horizon of 256 agent seconds.
  static const int wheelBuckets = 512;
  static const double wheelTickS = 0.5;

  /// Slots and their generations: a citizen is a handle, like a vehicle.
  final SlotPool pool;

  /// Per citizen: the building slot they live at and work at (−1 for
  /// homeless or unemployed); their parked car's handle, [carDriving] or
  /// [carNone]; the vehicle or pedestrian handle they travel as (−1); and,
  /// for the homeless, the building they sleep nearest (§9.2).
  late Int32List home, work, car, agent, sleepsNear;

  /// Per citizen: the [CitizenState] index, and the [CitizenFlags] bits.
  late Uint8List state, flags;

  /// Per citizen: the absolute agent µs their current activity ends at.
  ///
  /// A double, not an int: agent time saturates rather than wraps
  /// (`addClock`), and a µs clock past 2^53 is a colony nobody will run —
  /// but a 32-bit column would wrap inside a long session, which is the
  /// lesson the vehicle table's `waitUs` taught.
  late Float64List wakeUs;

  /// Per citizen: slice 9's locked itinerary (§4.9) — boarding stop, first
  /// line, the two transfer stops (−1 when direct), second line, alighting
  /// stop. All −1 until transit ships.
  late Int32List itS1, itL1, itX1, itX2, itL2, itS2;

  /// Per citizen: the intrusive per-building lists, in arrival order — the
  /// next and previous resident of [home], and worker of [work] (−1 at the
  /// ends).
  late Int32List homeNext, homePrev, workNext, workPrev;

  /// Slots in the table.
  int get capacity => pool.capacity;

  /// Citizens alive: what §6.2's write-back adds the pending fraction to.
  int get liveCount => pool.liveCount;

  /// One past the highest slot handed out: iteration in slot order runs
  /// `0 <= slot < highWater` and skips what is not `isSlotLive`.
  int get highWater => pool.highWater;

  /// Whether [citizen] names a live row.
  bool isLive(int citizen) => pool.isLive(citizen);

  /// Room for [capacity] building slots in the per-building list heads, so a
  /// sync that grew the building table can be followed. Every new head is
  /// empty.
  void ensureBuildings(int capacity) =>
      throw UnimplementedError('slice 3 A: citizen_table.ensureBuildings');

  /// A citizen living at building slot [home], working at [work] (−1 for
  /// neither), owning [car], in [state] until [wakeUs] — which also
  /// [schedule]s them. Returns the handle, or [SlotPool.none] when the table
  /// is full.
  int spawn(
          {required int home,
          required int work,
          required int car,
          required CitizenState state,
          required double wakeUs,
          int flags = 0}) =>
      throw UnimplementedError('slice 3 A: citizen_table.spawn');

  /// Takes [citizen] out of the world: off the wheel, out of both building
  /// lists, and their slot freed. A stale handle removes nothing.
  void remove(int citizen) =>
      throw UnimplementedError('slice 3 A: citizen_table.remove');

  /// Grows the table to [newCapacity] rows. Every column is copied and live
  /// handles stay live (§2.5's doubling).
  void grow(int newCapacity) =>
      throw UnimplementedError('slice 3 A: citizen_table.grow');

  /// Moves [citizen] into building slot [buildingSlot] (−1: homeless),
  /// newest resident last.
  void setHome(int citizen, int buildingSlot) =>
      throw UnimplementedError('slice 3 A: citizen_table.setHome');

  /// Moves [citizen] into job [buildingSlot] (−1: unemployed), last hired
  /// last.
  void setWork(int citizen, int buildingSlot) =>
      throw UnimplementedError('slice 3 A: citizen_table.setWork');

  /// Citizens living at building slot [buildingSlot]: `Σ residents ≤ Σ
  /// housing` is checked against this (§6.2).
  int residentsOf(int buildingSlot) =>
      throw UnimplementedError('slice 3 A: citizen_table.residentsOf');

  /// Citizens working at building slot [buildingSlot].
  int workersOf(int buildingSlot) =>
      throw UnimplementedError('slice 3 A: citizen_table.workersOf');

  /// The last citizen to move into [buildingSlot], or −1: an eviction takes
  /// residents in REVERSE arrival order (§6.2).
  int newestResident(int buildingSlot) =>
      throw UnimplementedError('slice 3 A: citizen_table.newestResident');

  /// The last citizen hired at [buildingSlot], or −1: a lay-off is last
  /// hired, first out (§6.3).
  int newestWorker(int buildingSlot) =>
      throw UnimplementedError('slice 3 A: citizen_table.newestWorker');

  /// Puts [citizen] on the wheel, due at absolute agent µs [atUs]: its
  /// bucket while that is within the horizon, the overflow list beyond it.
  void schedule(int citizen, double atUs) =>
      throw UnimplementedError('slice 3 A: citizen_table.schedule');

  /// Takes [citizen] off the wheel, wherever they sit on it.
  void unschedule(int citizen) =>
      throw UnimplementedError('slice 3 A: citizen_table.unschedule');

  /// Up to [cap] citizens due at or before [nowUs] into [out], off the
  /// wheel: bucket order, then slot order, so two runs wake the same people
  /// in the same order. Returns how many were written.
  int takeDue(int nowUs, Int32List out, int cap) =>
      throw UnimplementedError('slice 3 A: citizen_table.takeDue');

  /// Every buffer the table keeps from one sub-step to the next, by name
  /// into [into], for the allocation gate (§15.2): once warm, none of them
  /// is replaced. A's wheel and list heads add themselves here.
  void collectBuffers(Map<String, Object> into, String name) {
    into['$name.home'] = home;
    into['$name.work'] = work;
    into['$name.car'] = car;
    into['$name.agent'] = agent;
    into['$name.sleepsNear'] = sleepsNear;
    into['$name.state'] = state;
    into['$name.flags'] = flags;
    into['$name.wakeUs'] = wakeUs;
    into['$name.itS1'] = itS1;
    into['$name.itL1'] = itL1;
    into['$name.itX1'] = itX1;
    into['$name.itX2'] = itX2;
    into['$name.itL2'] = itL2;
    into['$name.itS2'] = itS2;
    into['$name.homeNext'] = homeNext;
    into['$name.homePrev'] = homePrev;
    into['$name.workNext'] = workNext;
    into['$name.workPrev'] = workPrev;
  }

  /// [hash] with every live citizen folded in, in slot order — and so
  /// independent of the order they were spawned in (§17.4).
  int digest(int hash) =>
      throw UnimplementedError('slice 3 A: citizen_table.digest');

  void _allocColumns(int n) {
    home = Int32List(n)..fillRange(0, n, -1);
    work = Int32List(n)..fillRange(0, n, -1);
    car = Int32List(n)..fillRange(0, n, carNone);
    agent = Int32List(n)..fillRange(0, n, -1);
    sleepsNear = Int32List(n)..fillRange(0, n, -1);
    state = Uint8List(n);
    flags = Uint8List(n);
    wakeUs = Float64List(n);
    itS1 = Int32List(n)..fillRange(0, n, -1);
    itL1 = Int32List(n)..fillRange(0, n, -1);
    itX1 = Int32List(n)..fillRange(0, n, -1);
    itX2 = Int32List(n)..fillRange(0, n, -1);
    itL2 = Int32List(n)..fillRange(0, n, -1);
    itS2 = Int32List(n)..fillRange(0, n, -1);
    homeNext = Int32List(n)..fillRange(0, n, -1);
    homePrev = Int32List(n)..fillRange(0, n, -1);
    workNext = Int32List(n)..fillRange(0, n, -1);
    workPrev = Int32List(n)..fillRange(0, n, -1);
  }
}
