// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The floor's people and clock at run time (docs/plans/factory-floors.md
/// §10 items 5 and 20). A part of `factory_floor.dart` so it can walk
/// people with the floor's own flow fields; the plan it runs is
/// `factory_staffing.dart`, the clock `factory_calendar.dart`.
///
/// **Each sub-step** ([_crewStep], in place of the old share allocation):
///
/// 1. The calendar says which shift it is and whether it is scheduled
///    (weekday mask, holidays).
/// 2. Who turns up: the shift's hired count of each role, scaled down by the
///    colony's staffing share, less anyone on leave today.
/// 3. Posts ([_assignPosts]): pinned people go to their station; everyone
///    else keeps the post they had, then fills the stations NEAREST the
///    muster spot first (walking distance, ties by id), whole crews only.
///    Technicians stand at the automated stations they look after.
/// 4. People walk: in from the muster spot (the floor's entrance) to their
///    post, out to it at shift end, where they leave the floor.
/// 5. A station is staffed only while its full crew STANDS at it; an
///    automated one needs nobody. It is maintained while the technicians
///    hired across all shifts cover its share (on call, see
///    `factory_staffing.dart`).
/// 6. Handlers: AGVs always run; the 1st shift drives the whole fleet, the
///    2nd and 3rd the first [ShiftCrew.handlers]. Off shift, a loaded hand
///    finishes the trip in hand, then walkers walk out and vehicles park.
///
/// **Determinism.** Everything is ordered by id; posts and people are
/// saved, so save → load → step equals an unbroken run.
///
/// **Skip** ([_skipToward]): steps in sub-steps, but where the floor is
/// provably idle — nobody on shift, no handler on a job or charging, no
/// station working, and a cheap state signature unchanged over the last
/// [_kSettleSubSteps] sub-steps (so in-flight belt items have settled) —
/// it jumps the clock straight to the next shift boundary (or the target),
/// booking the floor's constant draw for the gap. The signature is checked
/// at ABSOLUTE sub-step indices, so how a caller chunks a skip (its frame
/// budget) never changes where the jump happens.
part of 'factory_floor.dart';

/// Seconds an operator takes to reach a post with no walking route from
/// the entrance (a station boxed in by belts): the plant's back corridors.
/// Real crews step over or under conveyors; the floor's walkers can't, so
/// rather than leave a belt-locked cell unmanned forever the operator gets
/// there by a fixed detour and stands at the post.
const double kBackCorridorS = 20;

/// Sub-steps the floor must sit unchanged before an idle jump (10 s).
const int _kSettleSubSteps = 40;

class _CrewRuntime {
  /// People on the floor, by person id. Walkers that aren't handlers.
  final SplayTreeMap<int, FloorHandler> people = SplayTreeMap();

  /// Person id → the placement they man (or look after). Saved: posts are
  /// sticky, so the next sub-step's assignment depends on this one's.
  final SplayTreeMap<int, int> post = SplayTreeMap();

  /// Transient per sub-step.
  final Map<int, StaffState> state = {};

  /// Walker handlers that have walked out off shift (hidden; saved).
  final SplayTreeSet<int> away = SplayTreeSet();

  /// Handlers walking out this sub-step (transient, set by [_crewStep]).
  final Set<int> goingHome = {};

  /// A scheduled shift is on (set by [_crewStep], transient).
  bool onShift = true;

  /// Manned stations nearest the muster spot first, per layout revision.
  int orderRev = -1;
  List<Placement> order = const [];

  int techRev = -1;
  double techShare = 0;

  /// Skip bookkeeping (transient).
  int sigIndex = -1;
  double sig = double.nan;
  int sigStable = 0;
}

extension _FloorCrew on FactoryFloor {
  FloorStaffPlan get _plan => _bp.staff;

  /// The layout's technician share, cached per layout revision.
  double get _techShare {
    final rt = _crew;
    if (rt.techRev != _layoutRev) {
      rt.techRev = _layoutRev;
      rt.techShare = technicianShareNeeded(_bp.placements);
    }
    return rt.techShare;
  }

  /// Hired [n] scaled by the colony's share, rounded down per role.
  static int _capped(int n, double share) =>
      share >= 1 ? n : (n * share + 1e-9).floor();

  /// Where people come in and leave: the walkers' home tile (the muster
  /// spot), re-derived with the layout, so a hire never spawns on a tile an
  /// edit has since built over.
  TilePos get _entrance => _layerHome[kWalkLayer] ?? _idleTile;

  int get _fleetDrivers {
    var n = 0;
    for (final h in _handlers) {
      n += h.spec.operators;
    }
    return n;
  }

  /// Manned stations, nearest the muster spot first (walk distance, then
  /// id); unreachable ones last by id.
  List<Placement> get _postOrder {
    final rt = _crew;
    if (rt.orderRev == _layoutRev && rt.order.isNotEmpty) return rt.order;
    final idle = _idleTile;
    final scored = <(int, int, Placement)>[];
    for (final p in _machineList) {
      if (p.crew.workers <= 0) continue;
      final f = _fieldOn(kWalkLayer, p.id);
      final d = f == null ? -1 : _paths.distance(f, idle);
      scored.add((d < 0 ? 1 << 30 : d, p.id, p));
    }
    scored.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    rt.orderRev = _layoutRev;
    return rt.order = [for (final s in scored) s.$3];
  }

  /// Gives each present operator a station (see the library notes) and
  /// each technician an automated station to stand by.
  void _assignPosts(List<int> ops, List<int> techs) {
    final rt = _crew;
    final order = _postOrder;
    final need = <int, int>{for (final p in order) p.id: p.crew.workers};
    final filled = <int, int>{};
    final next = SplayTreeMap<int, int>();
    final opSet = ops.toSet();
    bool take(int person, int station) {
      final n = need[station];
      if (n == null || (filled[station] ?? 0) >= n) return false;
      filled[station] = (filled[station] ?? 0) + 1;
      next[person] = station;
      return true;
    }

    // Pins first, then sticky posts, then nearest-first.
    for (final e in _plan.pins.entries) {
      if (opSet.contains(e.key)) take(e.key, e.value);
    }
    for (final id in ops) {
      if (next.containsKey(id)) continue;
      final had = rt.post[id];
      if (had != null && !_plan.pins.containsKey(id)) take(id, had);
    }
    var si = 0;
    for (final id in ops) {
      if (next.containsKey(id) || _plan.pins.containsKey(id)) continue;
      while (si < order.length &&
          (filled[order[si].id] ?? 0) >= order[si].crew.workers) {
        si++;
      }
      if (si >= order.length) break;
      take(id, order[si].id);
    }
    // Technicians: one per four automated stations, in id order.
    final autos = [
      for (final p in _machineList)
        if (p.crew.maintenance > 0) p,
    ];
    for (var i = 0; i < techs.length && autos.isNotEmpty; i++) {
      final k = i * 4;
      if (k < autos.length) next[techs[i]] = autos[k].id;
    }
    rt.post
      ..clear()
      ..addAll(next);
  }

  /// One sub-step of the crew (replaces the old staffing-share allocation).
  void _crewStep(double share, double dt) {
    final rt = _crew;
    final plan = _plan;
    final cal = plan.calendar;
    final t = _simSeconds;
    final on = cal.onShift(plan.schedule, t);
    final shift = cal.shiftAt(t);
    final day = cal.shiftDay(t);
    final premium = kShiftPremium[shift] - 1;
    rt.onShift = on;
    // Off shift with the hall empty (the lights-out night) there is no one
    // to place or walk: skip straight to the stations and handlers, which
    // keeps a skip over a night of automation cheap.
    final empty = !on && rt.people.isEmpty;
    final crew = on ? plan.crewFor(shift, _bp.placements) : ShiftCrew();

    // Who turns up: the colony's share of the shift's whole crew, pooled
    // and handed out operators first, then technicians, then handler
    // drivers (the old allocation's priority), so a 97% colony idles a
    // forklift before a station.
    final drivers = shift == 0 ? _fleetDrivers : crew.handlers;
    var pool = on
        ? _capped(crew.operators + crew.technicians + drivers, share)
        : 0;
    final ops = <int>[], techs = <int>[];
    if (on) {
      for (final r in StaffRole.values) {
        final want = crew.count(r);
        final n = want < pool ? want : pool;
        pool -= n;
        for (var i = 0; i < n; i++) {
          final id = staffPersonId(shift, r, i);
          if (onLeave(id, day)) continue;
          (r == StaffRole.operator ? ops : techs).add(id);
        }
      }
    }
    if (empty) {
      rt.post.clear();
    } else {
      _assignPosts(ops, techs);
    }

    // People walk in, to their posts, and out.
    final present = <int>{...ops, ...techs};
    for (final id in present) {
      rt.people.putIfAbsent(
          id, () => FloorHandler(id: id, kind: HandlerKind.onFoot, at: _entrance));
    }
    rt.state.clear();
    final standing = <int, int>{};
    for (final id in empty ? const <int>[] : rt.people.keys.toList()) {
      final h = rt.people[id]!;
      if (!present.contains(id)) {
        final w = _walk(h, _kIdleKey, dt);
        if (w != 0) {
          rt.people.remove(id); // out of the door (or no way out: gone)
        } else {
          rt.state[id] = StaffState.leaving;
        }
        continue;
      }
      final st = rt.post[id];
      final w = _walk(h, st ?? _kIdleKey, dt);
      if (w == 1) {
        rt.state[id] = StaffState.atPost;
        if (st != null) standing[st] = (standing[st] ?? 0) + 1;
      } else if (w < 0 && st != null) {
        // No walking route to the post (boxed in by belts): the back
        // corridor, a fixed walk, then they appear at the post.
        h.timer += dt;
        if (h.timer + _eps >= kBackCorridorS) {
          final g = _goalsFor(kWalkLayer, st);
          final at = g.isNotEmpty ? g.first : _byId[st]?.pos;
          if (at != null && h.at != at) {
            h
              ..at = at
              ..next = null
              ..prog = 0;
          }
          rt.state[id] = StaffState.atPost;
          standing[st] = (standing[st] ?? 0) + 1;
        } else {
          rt.state[id] = StaffState.arriving;
        }
      } else {
        h.timer = 0;
        rt.state[id] = StaffState.arriving;
      }
    }

    // Stations: a full crew standing at it, or none needed.
    for (final p in _machineList) {
      final need = p.crew.workers;
      _staffed[p.id] = need <= 0 || (standing[p.id] ?? 0) >= need;
    }
    if (ops.isNotEmpty) {
      _ledger.addWork(WorkRole.station, ops.length * dt);
      if (premium > 0) _ledger.addPremium(WorkRole.station, ops.length * dt * premium);
    }

    // Maintenance: on-call cover from every shift's technicians.
    var avail = 0.0;
    for (var s = 0; s < 3; s++) {
      avail += (s == 0 && plan.auto
              ? _techShare
              : plan.crews[s].technicians) *
          share;
    }
    var autoBooked = 0.0;
    for (final p in _machineList) {
      final need = p.crew.maintenance;
      if (need <= 0) {
        _maintained[p.id] = _staffed[p.id] == true;
        continue;
      }
      final ok = avail + _eps >= need;
      _maintained[p.id] = ok;
      if (!ok) continue;
      avail -= need;
      autoBooked += need;
    }
    if (plan.auto) {
      // The legacy fractional share, booked around the clock.
      if (autoBooked > 0) _ledger.addWork(WorkRole.maintenance, autoBooked * dt);
    } else if (techs.isNotEmpty) {
      _ledger.addWork(WorkRole.maintenance, techs.length * dt);
      if (premium > 0) {
        _ledger.addPremium(WorkRole.maintenance, techs.length * dt * premium);
      }
    }

    // Handlers.
    rt.goingHome.clear();
    var left = on ? pool : 0;
    for (final h in _handlers) {
      final opsN = h.spec.operators;
      var manned = opsN == 0;
      var absent = false;
      if (!manned && on && left >= opsN) {
        if (onLeave(handlerDriverId(shift, h.id), day)) {
          absent = true;
        } else {
          manned = true;
          left -= opsN;
        }
      }
      // Off shift a loaded hand finishes the trip in hand (overtime).
      final finishing = !manned && !on && h.job != null;
      h.active = manned || finishing;
      if (h.active) {
        rt.away.remove(h.id);
        if (opsN > 0) {
          _ledger.addWork(WorkRole.handler, opsN * dt);
          if (premium > 0 && on) {
            _ledger.addPremium(WorkRole.handler, opsN * dt * premium);
          }
        }
        continue;
      }
      if ((!on || absent) && h.kind == HandlerKind.onFoot && !rt.away.contains(h.id)) {
        rt.goingHome.add(h.id);
      }
    }
  }

  /// Whether anyone could take a move request this sub-step: a shift is
  /// on, or some handler (an AGV, a hand finishing a trip) is active.
  bool get _crewHandsAtWork {
    if (_crew.onShift) return true;
    for (final h in _handlers) {
      if (h.active) return true;
    }
    return false;
  }

  /// [_moveHandlers]' hook for an unmanned handler: a walker off shift
  /// walks out to the muster spot and leaves. True when handled.
  bool _walkOffShift(FloorHandler h, double dt) {
    final rt = _crew;
    if (rt.away.contains(h.id)) return true;
    if (!rt.goingHome.contains(h.id)) return false;
    if (h.state != HandlerState.idle) h.goIdle();
    final w = _walk(h, _kIdleKey, dt);
    if (w != 0) {
      h.settle();
      rt.away.add(h.id);
    }
    return true;
  }

  /// Puts the current shift's crew straight at their posts (a fresh floor
  /// opens mid-shift, its crew already at work; hires made later walk in).
  void _crewAtPosts() {
    _crewStep(1, 0);
    final rt = _crew;
    for (final e in rt.post.entries) {
      final h = rt.people[e.key];
      if (h == null) continue;
      final g = _goalsFor(kWalkLayer, e.value);
      final at = g.isNotEmpty ? g.first : _byId[e.value]?.pos;
      if (at == null) continue;
      h
        ..at = at
        ..next = null
        ..prog = 0;
      // A post nobody can stand beside (its hand port faces the wall or a
      // belt) is reached by the back corridor; the opening crew has
      // already come that way, so it counts as walked.
      if (g.isEmpty) h.timer = kBackCorridorS;
    }
    // The dry run booked nothing (dt 0) and derived only transient state.
  }

  // ---- views -------------------------------------------------------------

  Iterable<StaffView> get _staffViews sync* {
    final rt = _crew;
    for (final e in rt.people.entries) {
      final v = e.value.view;
      final (shift, role, _) = staffPersonOf(e.key);
      yield StaffView(
        id: e.key,
        role: role,
        shift: shift,
        x: v.x,
        y: v.y,
        state: rt.state[e.key] ?? StaffState.arriving,
        stationId: rt.post[e.key],
        pinned: _plan.pins.containsKey(e.key),
      );
    }
  }

  void _hireStaff(int shift, StaffRole? role, int delta) {
    if (shift < 0 || shift > 2 || delta == 0) return;
    final plan = _plan;
    if (role == null && shift == 0) return; // the 1st drives the fleet
    plan.makeExplicit(_bp.placements);
    final c = plan.crews[shift];
    if (role == null) {
      c.handlers = (c.handlers + delta).clamp(0, kMaxStaffPerRole);
    } else {
      final n = (c.count(role) + delta).clamp(0, kMaxStaffPerRole);
      c.setCount(role, n);
      // A fired person's pin goes with them.
      plan.pins.removeWhere((id, _) {
        final (s, r, i) = staffPersonOf(id);
        return s == shift && r == role && i >= n;
      });
    }
  }

  // ---- json --------------------------------------------------------------

  Map<String, Object?> _crewJson() {
    final rt = _crew;
    return {
      if (rt.people.isNotEmpty)
        'pp': [
          for (final h in rt.people.values)
            [h.id, h.at.x, h.at.y, h.next?.x, h.next?.y, h.prog, h.timer],
        ],
      if (rt.post.isNotEmpty) 'po': {for (final e in rt.post.entries) '${e.key}': e.value},
      if (rt.away.isNotEmpty) 'aw': [...rt.away],
    };
  }

  void _crewFromJson(Object? j) {
    final m = ((j as Map?) ?? const {}).cast<String, Object?>();
    final rt = _crew;
    for (final e in (m['pp'] as List? ?? const [])) {
      final l = e as List;
      final h = FloorHandler(
          id: (l[0] as num).toInt(),
          kind: HandlerKind.onFoot,
          at: TilePos((l[1] as num).toInt(), (l[2] as num).toInt()));
      final nx = l[3], ny = l[4];
      if (nx is num && ny is num) h.next = TilePos(nx.toInt(), ny.toInt());
      h.prog = (l[5] as num).toDouble();
      if (l.length > 6) h.timer = (l[6] as num).toDouble();
      rt.people[h.id] = h;
    }
    ((m['po'] as Map?) ?? const {}).cast<String, Object?>().forEach(
        (k, v) => rt.post[int.parse(k)] = (v as num).toInt());
    for (final v in (m['aw'] as List? ?? const [])) {
      rt.away.add((v as num).toInt());
    }
  }

  // ---- skip --------------------------------------------------------------

  /// Nobody on shift, no handler working or charging, no station working.
  bool get _idleOffShift {
    if (_plan.calendar.onShift(_plan.schedule, _simSeconds)) return false;
    if (_crew.people.isNotEmpty) return false;
    for (final h in _handlers) {
      if (h.job != null || h.state != HandlerState.idle) return false;
      if (h.next != null) return false;
    }
    for (final p in _machineList) {
      if (_machines[p.id]?.status == MachineStatus.working) return false;
    }
    return true;
  }

  /// A cheap fingerprint of everything that moves (belts, arms, machines,
  /// docks, handlers, piles, the books' goods counters).
  double _signature() {
    var s = 0.0, k = 1.0;
    void add(double v) {
      k = k * 1.000003 + 0.618;
      s += v * k;
    }

    for (final e in _belts.values) {
      for (final i in e.items) {
        add(i.p + i.item.length);
      }
      add(e.items.length.toDouble());
    }
    for (final a in _arms.values) {
      add(a.t);
      add(a.held == null ? 0 : 1);
    }
    for (final m in _machines.values) {
      add(m.progress);
      add(m.wear);
      add(m.repair);
      add(m.inBuf.total.toDouble());
      add(m.outBuf.total.toDouble());
      add(m.status.index.toDouble());
    }
    for (final r in _recv.values) {
      add(r.credit);
      add(r.paid);
    }
    for (final st in _stores.values) {
      add(st.total.toDouble());
    }
    for (final h in _handlers) {
      add(h.at.x + h.at.y * 1000.0 + h.prog);
      add(h.battery);
      add(h.carryingCount.toDouble());
    }
    add(_piles.length.toDouble());
    add(_queue.length.toDouble());
    for (final v in _ledger.received.values) {
      add(v);
    }
    for (final v in _ledger.shipped.values) {
      add(v);
    }
    return s;
  }

  bool _skipToward(double targetS, FactoryColonyPort port, int maxSubSteps) {
    final rt = _crew;
    var budget = maxSubSteps;
    while (budget > 0) {
      final left = targetS - _simSeconds;
      if (left < kFactoryStepS - _eps) return true;
      final idx = (_simSeconds / kFactoryStepS).round();
      if (idx % _kSettleSubSteps == 0 && idx != rt.sigIndex) {
        final idle = _idleOffShift;
        final sig = _signature();
        rt.sigStable = idle && sig == rt.sig ? rt.sigStable + 1 : 0;
        rt.sig = sig;
        rt.sigIndex = idx;
        if (rt.sigStable >= 1) {
          // Provably idle for a whole settle window: jump to the next shift
          // boundary (a crew may arrive there) or the target.
          final cal = _plan.calendar;
          var to = cal.nextShiftBoundary(_simSeconds);
          if (to > targetS) to = targetS;
          final n = ((to - _simSeconds + _eps) / kFactoryStepS).floor();
          if (n > 1) {
            _idleJump(n, port);
            budget--;
            continue;
          }
        }
      }
      step(kFactoryStepS, port);
      budget--;
    }
    return targetS - _simSeconds < kFactoryStepS - _eps;
  }

  /// Advances [n] idle sub-steps at once: the clock, the books' seconds and
  /// the constant draw of arms and belts (nothing else moves).
  void _idleJump(int n, FactoryColonyPort port) {
    final dt = n * kFactoryStepS;
    final power = FactoryFloor._unit(port.powerShare);
    _ledger.energyKJ += powerDemandKw * power * dt;
    _ledger.seconds += dt;
    _simSeconds = ((_simSeconds / kFactoryStepS).round() + n) * kFactoryStepS;
    _crew.sigStable = 0;
  }
}
