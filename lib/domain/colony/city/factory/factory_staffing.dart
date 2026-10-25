// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Who works on a floor, and when (docs/plans/factory-floors.md §10 items
/// 5 and 20).
///
/// **Operators are people.** A manual station needs two operators, an
/// assisted one one ([MachineMode.workers]); the player HIRES them, per
/// shift, and each one walks in at shift start, stands at a station and
/// walks out at shift end. A station whose operators aren't standing at it
/// is unstaffed and idle. An automated station needs no operator, only a
/// share of a hired TECHNICIAN ([MachineMode.maintenance]: one technician
/// keeps four lights-out cells healthy).
///
/// **Per shift.** Each of the three shifts has its own [ShiftCrew]:
/// operators, technicians and handler drivers. The 1st shift drives the
/// whole handler fleet (the blueprint's `roster` IS its handler crew, which
/// is how old saves migrate); the 2nd and 3rd shifts drive the first
/// [ShiftCrew.handlers] handlers that need a driver. AGVs need none.
///
/// **Technicians are on call.** Preventive maintenance done on a shift
/// keeps a cell healthy through the night: a station counts as maintained
/// when the technicians hired across ALL shifts cover its share, whether or
/// not one is on the floor right now. (Otherwise lights-out automation,
/// whose whole point is running off-shift, would wear out every night.)
///
/// **Auto crew (migration).** A plan with [FloorStaffPlan.auto] hires its
/// 1st shift exactly what the layout needs, recomputed as the layout
/// changes, and keeps the old fractional technician share. Every blueprint
/// saved before this change (and every test layout) loads as auto, so it
/// runs as it always did. The first hand-made hire switches a plan to
/// explicit, starting from what auto had hired. Templates ship explicit,
/// with their crew already hired.
///
/// **The colony** caps who turns up: the floor's `staffingShare` (the
/// colony's labour supply for this site) scales each shift's hired count,
/// rounded down per role, before leave is taken out.
library;

import 'dart:collection';

import 'factory_calendar.dart';
import 'factory_colony_port.dart';
import 'factory_entities.dart';
import 'factory_handling.dart';

/// A hired person's job.
enum StaffRole { operator, technician }

/// Most of one role on one shift (person ids are packed per role).
const int kMaxStaffPerRole = 4999;

/// The stable id of the [index]th [role] on [shift] (0-based).
int staffPersonId(int shift, StaffRole role, int index) =>
    1 + shift * 10000 + role.index * 5000 + index;

/// The (shift, role, index) of a [staffPersonId].
(int, StaffRole, int) staffPersonOf(int id) {
  final v = id - 1;
  final shift = v ~/ 10000;
  final r = (v % 10000) ~/ 5000;
  return (shift, StaffRole.values[r], v % 5000);
}

/// The leave-hash id of whoever drives handler [handlerId] on [shift].
int handlerDriverId(int shift, int handlerId) =>
    100000 + shift * 100000 + handlerId;

/// One shift's hired crew.
class ShiftCrew {
  ShiftCrew({this.operators = 0, this.technicians = 0, this.handlers = 0});

  int operators;
  int technicians;

  /// Handler drivers (2nd and 3rd shifts only; the 1st drives the fleet).
  int handlers;

  int count(StaffRole r) =>
      r == StaffRole.operator ? operators : technicians;

  void setCount(StaffRole r, int n) {
    if (r == StaffRole.operator) {
      operators = n;
    } else {
      technicians = n;
    }
  }

  bool get isEmpty => operators == 0 && technicians == 0 && handlers == 0;

  ShiftCrew copy() => ShiftCrew(
      operators: operators, technicians: technicians, handlers: handlers);

  List<int> toJson() => [operators, technicians, handlers];

  static ShiftCrew fromJson(Object? j) {
    final l = (j as List?) ?? const [];
    int at(int i) => i < l.length ? (l[i] as num).toInt() : 0;
    return ShiftCrew(operators: at(0), technicians: at(1), handlers: at(2));
  }
}

/// Operators a layout needs per shift: every manned station's crew.
int operatorsNeededFor(Iterable<Placement> placements) {
  var n = 0;
  for (final p in placements) {
    if (p.kind == EntityKind.machine) n += p.crew.workers;
  }
  return n;
}

/// Technician share a layout needs (fractional jobs).
double technicianShareNeeded(Iterable<Placement> placements) {
  var n = 0.0;
  for (final p in placements) {
    if (p.kind == EntityKind.machine) n += p.crew.maintenance;
  }
  return n;
}

/// Whole technicians covering [share] (a quarter-technician station still
/// needs one person).
int techniciansFor(double share) => share <= 1e-9 ? 0 : (share - 1e-9).ceil();

/// A floor's staffing plan, saved with its blueprint.
class FloorStaffPlan {
  FloorStaffPlan({
    this.auto = true,
    List<ShiftCrew>? crews,
    ShiftSchedule? schedule,
    Map<int, int>? pins,
    this.calendar = const FactoryCalendar(),
  })  : crews = [
          for (var s = 0; s < 3; s++)
            crews != null && s < crews.length ? crews[s] : ShiftCrew(),
        ],
        schedule = schedule ?? ShiftSchedule.standard(),
        pins = SplayTreeMap.of(pins ?? const {});

  /// Auto crew (see the library notes): the 1st shift hires what the
  /// layout needs. Crews [1] and [2] are always explicit.
  bool auto;

  /// Hired crew per shift (1st, 2nd, 3rd). With [auto], [0] is ignored and
  /// derived from the layout ([crewFor]).
  final List<ShiftCrew> crews;

  final ShiftSchedule schedule;

  /// Person id → the placement they are pinned to.
  final SplayTreeMap<int, int> pins;

  /// The floor's clock (start time; real time or a colony day).
  FactoryCalendar calendar;

  /// The crew actually hired on [shift] for [placements].
  ShiftCrew crewFor(int shift, Iterable<Placement> placements) {
    if (!auto || shift != 0) return crews[shift];
    return ShiftCrew(
      operators: operatorsNeededFor(placements),
      technicians: techniciansFor(technicianShareNeeded(placements)),
    );
  }

  /// Turns an auto plan explicit, keeping what auto had hired.
  void makeExplicit(Iterable<Placement> placements) {
    if (!auto) return;
    final c = crewFor(0, placements);
    crews[0]
      ..operators = c.operators
      ..technicians = c.technicians;
    auto = false;
  }

  /// A plan with [placements]'s needs hired on the 1st shift, explicit (a
  /// template's "ships with its crew").
  factory FloorStaffPlan.hiredFor(Iterable<Placement> placements) =>
      FloorStaffPlan(auto: true)..makeExplicit(placements);

  FloorStaffPlan copy() => FloorStaffPlan(
        auto: auto,
        crews: [for (final c in crews) c.copy()],
        schedule: schedule.copy(),
        pins: {...pins},
        calendar: calendar,
      );

  /// An auto plan with nothing else set: what a blueprint without a plan
  /// loads as, so it is left out of the save (old and new saves match).
  bool get isDefault =>
      auto &&
      crews.every((c) => c.isEmpty) &&
      schedule.isStandard &&
      pins.isEmpty &&
      calendar == const FactoryCalendar();

  Map<String, Object?> toJson() => {
        if (!auto) 'auto': false,
        'crew': [for (final c in crews) c.toJson()],
        if (!schedule.isStandard) 'days': schedule.toJson(),
        if (pins.isNotEmpty) 'pin': {for (final e in pins.entries) '${e.key}': e.value},
        if (calendar.toJson().isNotEmpty) 'cal': calendar.toJson(),
      };

  static FloorStaffPlan fromJson(Object? j) {
    final m = ((j as Map?) ?? const {}).cast<String, Object?>();
    final crew = (m['crew'] as List?) ?? const [];
    return FloorStaffPlan(
      auto: m['auto'] != false,
      crews: [for (final c in crew) ShiftCrew.fromJson(c)],
      schedule: m.containsKey('days')
          ? ShiftSchedule.fromJson(m['days'])
          : ShiftSchedule.standard(),
      pins: {
        for (final e
            in ((m['pin'] as Map?) ?? const {}).cast<String, Object?>().entries)
          int.parse(e.key): (e.value as num).toInt(),
      },
      calendar: FactoryCalendar.fromJson(m['cal']),
    );
  }
}

/// Where a hired person is.
enum StaffState {
  /// Walking in to their post.
  arriving,

  /// Standing at their station (or spare, at the muster spot).
  atPost,

  /// Walking out at shift end.
  leaving,
}

/// One person on the floor, for drawing. [x], [y] in tiles (fractional
/// while walking), anchored like a walker's [HandlerView].
class StaffView {
  const StaffView({
    required this.id,
    required this.role,
    required this.shift,
    required this.x,
    required this.y,
    required this.state,
    this.stationId,
    this.pinned = false,
  });
  final int id;
  final StaffRole role;
  final int shift;
  final double x, y;
  final StaffState state;

  /// The station they man (operators) or look after (technicians).
  final int? stationId;
  final bool pinned;
}

/// The staffing and clock surface of a floor (implemented by
/// `FactoryFloor`; the editor's fake sim doesn't, and the screen hides the
/// crew panel and the clock for it).
abstract interface class FactoryStaffedSim {
  FactoryCalendar get calendar;
  ShiftSchedule get schedule;

  /// Whether a scheduled shift is on now.
  bool get onShift;

  /// The crew hired on [shift].
  ShiftCrew crewOn(int shift);

  /// Operators the layout needs on a shift (to staff every station).
  int get operatorsNeeded;

  /// Technicians the layout's automated stations need.
  int get techniciansNeeded;

  /// Auto crew (legacy layouts): hiring anything by hand turns it off.
  bool get autoCrew;

  /// People on the floor now, by id.
  Iterable<StaffView> get staff;

  /// The people manning [placementId] now.
  List<StaffView> staffAt(int placementId);

  /// Hires ([delta] > 0) or lets go of [role] on [shift]; [role] null means
  /// handler drivers (2nd and 3rd shifts only).
  void hireStaff(int shift, StaffRole? role, int delta);

  /// Turns [shift] on or off for [weekday].
  void setShiftDay(int shift, int weekday, bool on);

  /// Pins person [personId] to [placementId] (null: unpin).
  void pinStaff(int personId, int? placementId);

  /// Moves the clock's start ([FactoryCalendar.startS]) — only before the
  /// floor has run, or the floor would jump in time.
  set calendar(FactoryCalendar c);

  /// Nothing automated is working, nobody is on shift, no handler is on a
  /// job: the floor would sit still until the next shift (auto-skip's test).
  bool get idleOffShift;

  /// Steps toward sim second [targetS] for at most [maxSubSteps] sub-steps,
  /// jumping the clock over provably idle stretches. True once there.
  bool skipToward(double targetS, FactoryColonyPort port, int maxSubSteps);
}

/// Re-exported for the UI's per-role labels.
String staffRoleLabel(StaffRole? r) => switch (r) {
      StaffRole.operator => 'Operators',
      StaffRole.technician => 'Technicians',
      null => 'Handler drivers',
    };

/// Handler drivers a fleet needs (every handler but AGVs).
int fleetDrivers(Map<HandlerKind, int> roster) {
  var n = 0;
  roster.forEach((k, v) => n += kHandlerSpecs[k]!.operators * v);
  return n;
}
