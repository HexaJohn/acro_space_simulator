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
/// **Handles or slots?** Every citizen this class is GIVEN or HANDS BACK is a
/// handle: [spawn]'s answer, [remove]'s and [schedule]'s argument, what
/// [newestResident] names and what [takeDue] writes. Every COLUMN is indexed
/// by the slot, `SlotPool.slotOf(citizen)` or [slotOf], and the intrusive link
/// columns hold slots, as the vehicle table's and the parked table's do. The
/// walk helpers ([firstResident], [nextResident] and their work twins) hand
/// back handles, so a caller who never wants to think about it need not.
library;

import 'dart:typed_data';

import 'slot_pool.dart';
import 'traffic_rng.dart';
import 'traffic_time.dart';

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
  ///
  /// [schedule] writes it, so the wheel and the column never disagree: the
  /// bucket is where a wake is looked for, this is when it is actually due.
  late Float64List wakeUs;

  /// Per citizen: slice 9's locked itinerary (§4.9) — boarding stop, first
  /// line, the two transfer stops (−1 when direct), second line, alighting
  /// stop. All −1 until transit ships.
  late Int32List itS1, itL1, itX1, itX2, itL2, itS2;

  /// Per citizen: the intrusive per-building lists, in arrival order — the
  /// next and previous resident of [home], and worker of [work] (−1 at the
  /// ends). SLOTS, not handles: [firstResident] and [nextResident] walk them
  /// as handles.
  late Int32List homeNext, homePrev, workNext, workPrev;

  /// Units of work the last [takeDue] did: one per bucket it stepped over,
  /// one per link it walked, one per overflow row it re-placed.
  ///
  /// The wheel's whole claim is that waking the due costs O(due) and not
  /// O([wheelBuckets]) (§2.5), and that is a claim about work done, not about
  /// wall time, which on a test machine measures the machine. So the work is
  /// counted, and `activity_wheel_test` reads it.
  int wheelWork = 0;

  /// Slots in the table.
  int get capacity => pool.capacity;

  /// Citizens alive: what §6.2's write-back adds the pending fraction to.
  int get liveCount => pool.liveCount;

  /// One past the highest slot handed out: iteration in slot order runs
  /// `0 <= slot < highWater` and skips what is not [isSlotLive].
  int get highWater => pool.highWater;

  /// Whether [citizen] names a live row.
  bool isLive(int citizen) => pool.isLive(citizen);

  /// Whether [slot] holds a live citizen — for iteration in slot order.
  bool isSlotLive(int slot) => pool.isSlotLive(slot);

  /// The handle of the live [slot].
  int handleOf(int slot) => pool.handleOf(slot);

  /// The column index of [citizen].
  static int slotOf(int citizen) => SlotPool.slotOf(citizen);

  /// Room for [capacity] building slots in the per-building list heads, so a
  /// sync that grew the building table can be followed. Every new head is
  /// empty.
  ///
  /// Called after each building sync, when a sync may allocate (§15.2). It
  /// keeps a little slack, so the steady state — the same building count
  /// every sync — never touches a buffer at all.
  void ensureBuildings(int capacity) => _ensureBuildings(capacity);

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
      int flags = 0}) {
    final citizen = pool.alloc();
    if (citizen == SlotPool.none) return citizen;
    final i = SlotPool.slotOf(citizen);
    // A slot is handed out again after a death or an emigration, and the row
    // still holds whatever that person left in it. Clear it here rather than
    // in [remove]: this is the one place a row becomes somebody's.
    this.home[i] = -1;
    this.work[i] = -1;
    homeNext[i] = -1;
    homePrev[i] = -1;
    workNext[i] = -1;
    workPrev[i] = -1;
    this.car[i] = car;
    agent[i] = -1;
    sleepsNear[i] = -1;
    this.state[i] = state.index;
    this.flags[i] = flags;
    itS1[i] = -1;
    itL1[i] = -1;
    itX1[i] = -1;
    itX2[i] = -1;
    itL2[i] = -1;
    itS2[i] = -1;
    setHome(citizen, home);
    setWork(citizen, work);
    schedule(citizen, wakeUs);
    return citizen;
  }

  /// Takes [citizen] out of the world: off the wheel, out of both building
  /// lists, and their slot freed. A stale handle removes nothing.
  void remove(int citizen) {
    if (!pool.isLive(citizen)) return;
    final i = SlotPool.slotOf(citizen);
    _unlinkWheel(i);
    _unlinkHome(i);
    _unlinkWork(i);
    home[i] = -1;
    work[i] = -1;
    // The rest of the row is left as it stands. Nothing reads a dead slot —
    // [digest], the codec and every walk skip what is not live — and [spawn]
    // clears it before handing it to the next person.
    pool.free(citizen);
  }

  /// Grows the table to [newCapacity] rows. Every column is copied and live
  /// handles stay live (§2.5's doubling).
  void grow(int newCapacity) {
    final old = capacity;
    pool.grow(newCapacity);
    Int32List i32(Int32List a, int fill) => Int32List(newCapacity)
      ..setRange(0, old, a)
      ..fillRange(old, newCapacity, fill);
    home = i32(home, -1);
    work = i32(work, -1);
    car = i32(car, carNone);
    agent = i32(agent, -1);
    sleepsNear = i32(sleepsNear, -1);
    state = Uint8List(newCapacity)..setRange(0, old, state);
    flags = Uint8List(newCapacity)..setRange(0, old, flags);
    wakeUs = Float64List(newCapacity)..setRange(0, old, wakeUs);
    itS1 = i32(itS1, -1);
    itL1 = i32(itL1, -1);
    itX1 = i32(itX1, -1);
    itX2 = i32(itX2, -1);
    itL2 = i32(itL2, -1);
    itS2 = i32(itS2, -1);
    homeNext = i32(homeNext, -1);
    homePrev = i32(homePrev, -1);
    workNext = i32(workNext, -1);
    workPrev = i32(workPrev, -1);
    // The wheel's links are per citizen too, and they are the reason a
    // doubling copies rather than rebuilds: every row keeps the bucket it
    // was in, so nobody's wake is lost to the growth.
    _wheelNext = i32(_wheelNext, -1);
    _wheelPrev = i32(_wheelPrev, -1);
    _wheelAt = i32(_wheelAt, -1);
  }

  /// Moves [citizen] into building slot [buildingSlot] (−1: homeless),
  /// newest resident last. Moving them where they already live changes
  /// nothing — their place in the arrival order is not a new arrival.
  void setHome(int citizen, int buildingSlot) {
    if (!pool.isLive(citizen)) return;
    final i = SlotPool.slotOf(citizen);
    if (home[i] == buildingSlot) return;
    _unlinkHome(i);
    home[i] = buildingSlot;
    if (buildingSlot < 0) return;
    _ensureBuildings(buildingSlot + 1);
    final tail = _homeTail[buildingSlot];
    homePrev[i] = tail;
    homeNext[i] = -1;
    if (tail < 0) {
      _homeHead[buildingSlot] = i;
    } else {
      homeNext[tail] = i;
    }
    _homeTail[buildingSlot] = i;
    _residents[buildingSlot]++;
  }

  /// Moves [citizen] into job [buildingSlot] (−1: unemployed), last hired
  /// last. Re-hiring them where they already work changes nothing.
  void setWork(int citizen, int buildingSlot) {
    if (!pool.isLive(citizen)) return;
    final i = SlotPool.slotOf(citizen);
    if (work[i] == buildingSlot) return;
    _unlinkWork(i);
    work[i] = buildingSlot;
    if (buildingSlot < 0) return;
    _ensureBuildings(buildingSlot + 1);
    final tail = _workTail[buildingSlot];
    workPrev[i] = tail;
    workNext[i] = -1;
    if (tail < 0) {
      _workHead[buildingSlot] = i;
    } else {
      workNext[tail] = i;
    }
    _workTail[buildingSlot] = i;
    _workers[buildingSlot]++;
  }

  /// Citizens living at building slot [buildingSlot]: `Σ residents ≤ Σ
  /// housing` is checked against this (§6.2).
  int residentsOf(int buildingSlot) =>
      buildingSlot >= 0 && buildingSlot < _residents.length
          ? _residents[buildingSlot]
          : 0;

  /// Citizens working at building slot [buildingSlot].
  int workersOf(int buildingSlot) =>
      buildingSlot >= 0 && buildingSlot < _workers.length
          ? _workers[buildingSlot]
          : 0;

  /// The last citizen to move into [buildingSlot], or −1: an eviction takes
  /// residents in REVERSE arrival order (§6.2).
  int newestResident(int buildingSlot) => _handleAt(_homeTail, buildingSlot);

  /// The last citizen hired at [buildingSlot], or −1: a lay-off is last
  /// hired, first out (§6.3).
  int newestWorker(int buildingSlot) => _handleAt(_workTail, buildingSlot);

  /// The first citizen to move into [buildingSlot], or −1: where a walk of
  /// the residents in arrival order starts.
  int firstResident(int buildingSlot) => _handleAt(_homeHead, buildingSlot);

  /// The first citizen hired at [buildingSlot], or −1.
  int firstWorker(int buildingSlot) => _handleAt(_workHead, buildingSlot);

  /// The resident of the same home who arrived after [citizen], or −1.
  int nextResident(int citizen) => pool.isLive(citizen)
      ? _handleOrNone(homeNext[SlotPool.slotOf(citizen)])
      : SlotPool.none;

  /// The worker of the same job hired after [citizen], or −1.
  int nextWorker(int citizen) => pool.isLive(citizen)
      ? _handleOrNone(workNext[SlotPool.slotOf(citizen)])
      : SlotPool.none;

  // ---- The activity wheel -----------------------------------------------------
  //
  // 512 buckets of half a second (§2.5). A wake lands in the bucket of its
  // TICK, `floor(atUs / 500000)`, and the cursor [_tick] walks the ticks as
  // agent time passes, so [takeDue] reads one bucket per tick that has gone
  // by and touches nothing else: O(due), never O(citizens) and never O(512).
  //
  // The horizon is what the cursor can see: ticks [_tick, _tick + 512). A
  // wake past it cannot go in a bucket, because that bucket already belongs
  // to a nearer tick, so it waits on the OVERFLOW list. The overflow is
  // re-placed every 512 ticks ([_rescan], "whenever the wheel wraps"), which
  // is always before the soonest wake on it can come due: a row went on the
  // list because it was at least 512 ticks out, and the rescan is at most 512
  // ticks away. Each rescan re-asks the same question against the new
  // horizon, so a wake an hour out simply waits through several of them.
  //
  // Within one bucket the rows are kept in SLOT order, so [takeDue] hands a
  // bucket over in slot order without sorting anything: two runs that reach
  // the same state wake the same people in the same order however they got
  // there.

  /// The bucket a citizen beyond the horizon waits in: one past the wheel.
  static const int _overflow = wheelBuckets;

  /// The furthest tick a wake can be scheduled at, so a wake handed in as
  /// something absurd saturates instead of wrapping (traffic_time.dart's
  /// rule for clocks). 2^30 ticks is seventeen years of agent time.
  static const int _maxTick = 1 << 30;

  /// One bucket, in whole µs.
  static final int _tickUs = usOf(wheelTickS);

  /// The wake [_maxTick] stands for.
  static final double _wakeMax = _maxTick.toDouble() * _tickUs;

  /// Per bucket, and then the overflow: the first and last row on it (−1
  /// when it is empty).
  final Int32List _bucketHead = Int32List(wheelBuckets + 1)
    ..fillRange(0, wheelBuckets + 1, -1);
  final Int32List _bucketTail = Int32List(wheelBuckets + 1)
    ..fillRange(0, wheelBuckets + 1, -1);

  /// Per citizen: the intrusive wheel links, and the bucket the row is on
  /// ([_overflow] on the overflow list, −1 off the wheel).
  late Int32List _wheelNext, _wheelPrev, _wheelAt;

  /// The tick the wheel has been walked to: everything before it is drained.
  int _tick = 0;

  /// The tick the overflow is re-placed at — one horizon past the last
  /// rescan.
  int _rescanAt = wheelBuckets;

  /// Puts [citizen] on the wheel, due at absolute agent µs [atUs]: its
  /// bucket while that is within the horizon, the overflow list beyond it.
  ///
  /// It also writes [wakeUs], which is the time the wheel is only a coarse
  /// index of. A citizen already on the wheel is MOVED, so calling it again
  /// is how an activity is cut short or put off; a wake in the past is due at
  /// once, and one that is not a finite time at all is read as now rather
  /// than kept, since every reader of the column would poison differently on
  /// a NaN.
  void schedule(int citizen, double atUs) {
    if (!pool.isLive(citizen)) return;
    final i = SlotPool.slotOf(citizen);
    var w = atUs;
    if (!(w > 0)) {
      w = 0;
    } else if (!(w < _wakeMax)) {
      w = _wakeMax;
    }
    wakeUs[i] = w;
    _unlinkWheel(i);
    _linkWheel(i, _bucketFor(_tickOf(w), _tick));
  }

  /// Takes [citizen] off the wheel, wherever they sit on it.
  void unschedule(int citizen) {
    if (!pool.isLive(citizen)) return;
    _unlinkWheel(SlotPool.slotOf(citizen));
  }

  /// Whether [citizen] has a wake waiting on the wheel.
  bool isScheduled(int citizen) =>
      pool.isLive(citizen) && _wheelAt[SlotPool.slotOf(citizen)] >= 0;

  /// Up to [cap] citizens due at or before [nowUs] into [out], off the
  /// wheel: bucket order, then slot order, so two runs wake the same people
  /// in the same order. Returns how many were written.
  ///
  /// Over [cap] the rest stay where they are, in order, for the next call —
  /// §6.5's deferral, never a wake dropped. The cursor stops at the tick it
  /// stopped in, so nothing is walked twice either.
  int takeDue(int nowUs, Int32List out, int cap) {
    wheelWork = 0;
    final limit = cap < out.length ? cap : out.length;
    if (limit <= 0 || nowUs < 0) return 0;
    final nowTick = nowUs ~/ _tickUs;
    if (nowTick < _tick) return 0;
    var t = _tick;
    // More than a whole revolution has gone by — a resumed save, a test that
    // moved the clock — so every wake ON the wheel is already due whatever
    // bucket it sits in, and stepping tick by tick would walk an empty gap
    // as long as the jump. One revolution back from now covers all 512
    // buckets, and the rescan below brings the overflow with it.
    if (nowTick - t >= wheelBuckets) t = nowTick - wheelBuckets + 1;
    var n = 0;
    while (true) {
      // Full: stop where the sweep stands, so the ticks not yet read are
      // read next time and none of them twice.
      if (n >= limit) {
        _tick = t;
        return n;
      }
      if (t >= _rescanAt) _rescan(t);
      final b = t % wheelBuckets;
      var c = _bucketHead[b];
      wheelWork++;
      while (c >= 0) {
        wheelWork++;
        final next = _wheelNext[c];
        // The bucket is a coarse index; the wake is the time. A row is read
        // against [nowUs] itself, in every bucket and not only the last: the
        // cursor's own bucket runs half a second past now, and a rescan that
        // lands a row one revolution ahead lands it in a bucket this sweep
        // may still be about to read.
        if (wakeUs[c] <= nowUs) {
          if (n >= limit) {
            _tick = t;
            return n;
          }
          _unlinkWheel(c);
          out[n++] = pool.handleOf(c);
        }
        c = next;
      }
      if (t == nowTick) break;
      t++;
    }
    _tick = nowTick;
    return n;
  }

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
    into['$name.wheelNext'] = _wheelNext;
    into['$name.wheelPrev'] = _wheelPrev;
    into['$name.wheelAt'] = _wheelAt;
    into['$name.bucketHead'] = _bucketHead;
    into['$name.bucketTail'] = _bucketTail;
    into['$name.homeHead'] = _homeHead;
    into['$name.homeTail'] = _homeTail;
    into['$name.workHead'] = _workHead;
    into['$name.workTail'] = _workTail;
    into['$name.residents'] = _residents;
    into['$name.workers'] = _workers;
  }

  /// [hash] with every live citizen folded in, in slot order — and so
  /// independent of the order they were spawned in (§17.4).
  ///
  /// The columns only: not the generation of a slot, and not the per-building
  /// or wheel links. A save writes the citizens dense, in slot order, with no
  /// arrival order and no bucket (§14.1), so a colony resumed from one has
  /// the same PEOPLE with a different history behind its lists — the digest
  /// is the state a save carries, as the parked table's is.
  int digest(int hash) {
    var h = fnv1aU32(hash, pool.liveCount);
    for (var i = 0; i < pool.highWater; i++) {
      if (!pool.isSlotLive(i)) continue;
      h = fnv1aU32(h, i);
      h = fnv1aU32(h, home[i]);
      h = fnv1aU32(h, work[i]);
      h = fnv1aU32(h, car[i]);
      h = fnv1aU32(h, agent[i]);
      h = fnv1aU32(h, sleepsNear[i]);
      h = fnv1aByte(h, state[i]);
      h = fnv1aByte(h, flags[i]);
      h = _foldTime(h, wakeUs[i]);
      h = fnv1aU32(h, itS1[i]);
      h = fnv1aU32(h, itL1[i]);
      h = fnv1aU32(h, itX1[i]);
      h = fnv1aU32(h, itX2[i]);
      h = fnv1aU32(h, itL2[i]);
      h = fnv1aU32(h, itS2[i]);
    }
    return h;
  }

  // ---- Rows -------------------------------------------------------------------

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
    _wheelNext = Int32List(n)..fillRange(0, n, -1);
    _wheelPrev = Int32List(n)..fillRange(0, n, -1);
    _wheelAt = Int32List(n)..fillRange(0, n, -1);
  }

  /// [us], an absolute agent time, folded in as TWO 32-bit words.
  ///
  /// Microseconds pass 2^32 after 71 minutes of agent time, and a digest that
  /// folded only the low word would read two wakes an hour apart as one. The
  /// split is done in doubles, so no integer here is wider than the 32 bits
  /// the web has. A time that is not a finite positive number folds as zero,
  /// the same as no wake at all.
  static int _foldTime(int hash, double us) {
    if (!(us > 0) || !us.isFinite) return fnv1aU32(fnv1aU32(hash, 0), 0);
    final hi = (us / _twoPow32).floorToDouble();
    return fnv1aU32(fnv1aU32(hash, (us - hi * _twoPow32).round()), hi.toInt());
  }

  /// 2^32, as the exact double the split above divides by.
  static const double _twoPow32 = 4294967296.0;

  // ---- The per-building lists -------------------------------------------------

  /// Per building slot: the first and last resident and worker (−1 when
  /// nobody), and how many of each.
  Int32List _homeHead = Int32List(0);
  Int32List _homeTail = Int32List(0);
  Int32List _workHead = Int32List(0);
  Int32List _workTail = Int32List(0);
  Int32List _residents = Int32List(0);
  Int32List _workers = Int32List(0);

  void _ensureBuildings(int slots) {
    final old = _homeHead.length;
    if (slots <= old) return;
    // Doubling with a floor: [setHome] grows on its own when a citizen is
    // housed in a building past the last sync's count, and a colony adding
    // one lot at a time must not copy six arrays for each of them.
    var n = old < 16 ? 16 : old;
    while (n < slots) {
      n *= 2;
    }
    Int32List heads(Int32List a) => Int32List(n)
      ..setRange(0, old, a)
      ..fillRange(old, n, -1);
    _homeHead = heads(_homeHead);
    _homeTail = heads(_homeTail);
    _workHead = heads(_workHead);
    _workTail = heads(_workTail);
    _residents = Int32List(n)..setRange(0, old, _residents);
    _workers = Int32List(n)..setRange(0, old, _workers);
  }

  void _unlinkHome(int i) {
    final b = home[i];
    if (b < 0 || b >= _homeHead.length) return;
    final p = homePrev[i], nx = homeNext[i];
    if (p < 0) {
      _homeHead[b] = nx;
    } else {
      homeNext[p] = nx;
    }
    if (nx < 0) {
      _homeTail[b] = p;
    } else {
      homePrev[nx] = p;
    }
    homePrev[i] = -1;
    homeNext[i] = -1;
    _residents[b]--;
  }

  void _unlinkWork(int i) {
    final b = work[i];
    if (b < 0 || b >= _workHead.length) return;
    final p = workPrev[i], nx = workNext[i];
    if (p < 0) {
      _workHead[b] = nx;
    } else {
      workNext[p] = nx;
    }
    if (nx < 0) {
      _workTail[b] = p;
    } else {
      workPrev[nx] = p;
    }
    workPrev[i] = -1;
    workNext[i] = -1;
    _workers[b]--;
  }

  int _handleAt(Int32List ends, int buildingSlot) {
    if (buildingSlot < 0 || buildingSlot >= ends.length) return SlotPool.none;
    return _handleOrNone(ends[buildingSlot]);
  }

  int _handleOrNone(int slot) =>
      slot < 0 ? SlotPool.none : pool.handleOf(slot);

  // ---- The wheel's links ------------------------------------------------------

  /// The tick of [atUs], saturating: a wake that is not a finite positive
  /// time is due now, and one past [_maxTick] waits there for ever rather
  /// than wrapping into the past.
  static int _tickOf(double atUs) {
    if (!(atUs > 0)) return 0;
    final t = atUs / _tickUs;
    if (!(t < _maxTick)) return _maxTick;
    return t.floor();
  }

  /// Where tick [at] belongs while the cursor stands at [cursor]: its own
  /// bucket inside the horizon, the cursor's bucket when it is already due,
  /// and the overflow beyond.
  static int _bucketFor(int at, int cursor) {
    if (at >= cursor + wheelBuckets) return _overflow;
    if (at <= cursor) return cursor % wheelBuckets;
    return at % wheelBuckets;
  }

  /// Re-places the overflow against the horizon [base] opens, and sets the
  /// next rescan a whole revolution on.
  ///
  /// The list is detached first and each row re-asked, so a row still beyond
  /// the new horizon goes back on it and the walk never re-reads a link it
  /// has just rewritten. A row that has fallen DUE while it waited (the
  /// cursor jumped) goes into the bucket about to be read, which is why this
  /// runs before [takeDue] reads it.
  void _rescan(int base) {
    _rescanAt = base + wheelBuckets;
    var c = _bucketHead[_overflow];
    _bucketHead[_overflow] = -1;
    _bucketTail[_overflow] = -1;
    while (c >= 0) {
      wheelWork++;
      final next = _wheelNext[c];
      _wheelNext[c] = -1;
      _wheelPrev[c] = -1;
      _wheelAt[c] = -1;
      _linkWheel(c, _bucketFor(_tickOf(wakeUs[c]), base));
      c = next;
    }
  }

  void _linkWheel(int i, int b) {
    _wheelAt[i] = b;
    final tail = _bucketTail[b];
    if (tail < 0) {
      _bucketHead[b] = i;
      _bucketTail[b] = i;
      _wheelPrev[i] = -1;
      _wheelNext[i] = -1;
      return;
    }
    // Buckets are kept in slot order, and the pool hands slots up in order,
    // so the tail is where a run of spawns and a load both belong: the walk
    // below is for the rows that come back out of turn. The overflow is not
    // sorted — every row on it is re-placed by the next [_rescan], which
    // sorts it into its bucket then — so it appends, and a colony whose
    // wakes are all a day out still costs O(1) to schedule.
    if (b == _overflow || i > tail) {
      _wheelPrev[i] = tail;
      _wheelNext[i] = -1;
      _wheelNext[tail] = i;
      _bucketTail[b] = i;
      return;
    }
    // `i < tail` and slots are unique, so the walk stops at a row above [i]
    // before it runs off the end.
    var c = _bucketHead[b];
    while (c < i) {
      c = _wheelNext[c];
    }
    final p = _wheelPrev[c];
    _wheelPrev[i] = p;
    _wheelNext[i] = c;
    _wheelPrev[c] = i;
    if (p < 0) {
      _bucketHead[b] = i;
    } else {
      _wheelNext[p] = i;
    }
  }

  void _unlinkWheel(int i) {
    final b = _wheelAt[i];
    if (b < 0) return;
    final p = _wheelPrev[i], nx = _wheelNext[i];
    if (p < 0) {
      _bucketHead[b] = nx;
    } else {
      _wheelNext[p] = nx;
    }
    if (nx < 0) {
      _bucketTail[b] = p;
    } else {
      _wheelPrev[nx] = p;
    }
    _wheelPrev[i] = -1;
    _wheelNext[i] = -1;
    _wheelAt[i] = -1;
  }
}
