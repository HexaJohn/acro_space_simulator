// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/factory/factory_calendar.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_ledger.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_staffing.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Calendar, shifts and hired operators (docs/plans/factory-floors.md §10
/// items 5 and 20).
void main() {
  setUpAll(ensureFactoryCatalog);

  const h = 3600.0;

  /// A smelting line at row [y]: dock → belts → smelter ([mode]) → arms →
  /// shipping docks. Returns the smelter's id.
  int line(Lay l, int y, MachineMode mode) {
    l.add(EntityKind.receivingDock, 0, y + 1, item: 'ore');
    l.beltRow(2, 3, y + 1);
    final m = l.add(EntityKind.machine, 4, y,
        recipe: SteelRecipes.smelt.id, mode: mode);
    l.add(EntityKind.arm, 8, y + 1);
    l.add(EntityKind.shippingDock, 9, y + 1);
    l.add(EntityKind.arm, 8, y + 2);
    l.add(EntityKind.shippingDock, 9, y + 2);
    return m;
  }

  FloorBlueprint explicit(FloorBlueprint bp,
      {List<ShiftCrew>? crews, ShiftSchedule? schedule, double? startS}) {
    bp.staff = FloorStaffPlan(
      auto: false,
      crews: crews,
      schedule: schedule,
      calendar: FactoryCalendar(startS: startS ?? kDefaultCalendarStartS),
    );
    return bp;
  }

  final port = InfiniteColonyPort();

  test('the calendar reads weekdays, hours and shifts', () {
    const c = FactoryCalendar();
    expect(c.label(0), 'Mon 06:00 · 1st shift');
    expect(c.label(42 * 60), 'Mon 06:42 · 1st shift');
    expect(c.shiftAt(8 * h), 1);
    expect(c.shiftAt(16 * h), 2);
    expect(c.shiftDay(16 * h + 3 * h), 0, reason: 'Monday night after midnight');
    expect(c.weekday(16 * h + 3 * h), 1, reason: 'but the clock reads Tuesday');
    expect(c.nextShiftBoundary(0), 8 * h);
    final std = ShiftSchedule.standard();
    expect(c.onShift(std, 60), isTrue);
    expect(c.onShift(std, 8 * h + 60), isFalse);
    expect(c.nextScheduledStart(std, 8 * h), 24 * h, reason: 'Tue 06:00');
    expect(c.nextScheduledStart(std, 4 * 24 * h + 60), 7 * 24 * h,
        reason: 'Friday rolls over to Monday');
    expect(c.nextAt(0, 0x1F, 6), 24 * h, reason: 'weekdays 06:00, after now');
    // The colony maps a 120 s day onto the calendar: a shift is 40 s.
    const col = FactoryCalendar.colony();
    expect(col.nextShiftBoundary(0), closeTo(40, 1e-9));
    expect(col.label(40), 'Mon 14:00 · 2nd shift');
  });

  test('an unstaffed station idles until an operator is hired', () {
    final l = Lay();
    final m = line(l, 0, MachineMode.assisted);
    final f = FactoryFloor.fromBlueprint(explicit(l.blueprint(12, 6)));
    f.step(60, port);
    expect(f.statusOf(m), MachineStatus.unstaffed);
    expect(f.craftNet['pigIron'] ?? 0, 0);
    expect(f.jobDemand, 0, reason: 'nobody hired');

    f.hireStaff(0, StaffRole.operator, 1);
    expect(f.jobDemand, 1, reason: 'job demand counts hired people');
    f.step(120, port);
    expect(f.craftNet['pigIron'] ?? 0, greaterThan(0));
    expect(f.staffAt(m), hasLength(1));
    expect(f.ledger.workerSeconds[WorkRole.station], greaterThan(0));
  });

  test('a hired operator walks in to the station', () {
    final l = Lay();
    final m = line(l, 0, MachineMode.assisted);
    // The muster spot (the entrance) across the hall.
    l.add(EntityKind.staging, 22, 4, span: (1, 1));
    final f = FactoryFloor.fromBlueprint(explicit(l.blueprint(24, 6)));
    f.hireStaff(0, StaffRole.operator, 1);
    f.step(kFactoryStepS, port);
    final start = f.staff.single;
    expect(start.state, StaffState.arriving);
    final seen = <(double, double)>{};
    var t = 0.0;
    while (f.staff.single.state != StaffState.atPost) {
      f.step(kFactoryStepS, port);
      final v = f.staff.single;
      seen.add((v.x, v.y));
      t += kFactoryStepS;
      expect(t, lessThan(120), reason: 'must arrive');
    }
    expect(seen.length, greaterThan(3), reason: 'walked, not teleported');
    expect(f.staff.single.stationId, m);
    f.step(30, port);
    expect(f.statusOf(m), isNot(MachineStatus.unstaffed));
  });

  test('nearest stations first; a pinned operator stays put', () {
    final l = Lay();
    final near = line(l, 0, MachineMode.assisted);
    final far = line(l, 6, MachineMode.assisted);
    // Entrance: a staging area by the near line.
    l.add(EntityKind.staging, 10, 4, span: (1, 1));
    final f = FactoryFloor.fromBlueprint(explicit(l.blueprint(12, 12)));
    f.hireStaff(0, StaffRole.operator, 1);
    f.step(60, port);
    final p = f.staff.single;
    expect(p.stationId, near);

    f.pinStaff(p.id, far);
    f.step(90, port);
    expect(f.staff.single.stationId, far);
    expect(f.staff.single.pinned, isTrue);
    expect(f.statusOf(near), MachineStatus.unstaffed);
    expect(f.statusOf(far), isNot(MachineStatus.unstaffed));

    // A second hire takes the free station; the pinned one doesn't move.
    f.hireStaff(0, StaffRole.operator, 1);
    f.step(90, port);
    final byId = {for (final v in f.staff) v.id: v.stationId};
    expect(byId[p.id], far);
    expect(byId.values, containsAll([near, far]));
  });

  test('the shift change swaps crews', () {
    final l = Lay();
    final m = line(l, 0, MachineMode.assisted);
    final f = FactoryFloor.fromBlueprint(explicit(l.blueprint(12, 6),
        crews: [ShiftCrew(operators: 1), ShiftCrew(operators: 1)],
        schedule: ShiftSchedule(const [0x1F, 0x1F, 0]),
        startS: 14 * h - 120));
    f.step(60, port);
    expect([for (final v in f.staff) staffPersonOf(v.id).$1], [0]);
    f.step(240, port); // past 14:00
    final shifts = {for (final v in f.staff) staffPersonOf(v.id).$1};
    expect(shifts, {1}, reason: 'the 1st shift left, the 2nd came in');
    expect(f.statusOf(m), isNot(MachineStatus.unstaffed));
    expect(f.ledger.premiumSeconds[WorkRole.station], greaterThan(0),
        reason: 'the 2nd shift is paid its premium');
  });

  test('off shift only automation and AGVs run', () {
    final l = Lay();
    final manned = line(l, 0, MachineMode.assisted);
    final auto = line(l, 6, MachineMode.automated);
    final bp = explicit(l.blueprint(12, 12, walkers: 1),
        crews: [ShiftCrew(operators: 1, technicians: 1)],
        startS: 14 * h - 60);
    final f = FactoryFloor.fromBlueprint(bp);
    expect(f.staff, hasLength(2));
    f.step(300, port);
    expect(f.onShift, isFalse);
    expect(f.staff, isEmpty, reason: 'everyone walked out');
    expect(f.handlers, isEmpty, reason: 'the walker went home');
    expect(f.statusOf(manned), MachineStatus.unstaffed);
    final made = f.craftNet['pigIron'] ?? 0;
    f.step(600, port);
    expect(f.statusOf(auto), isNot(MachineStatus.unstaffed));
    expect(f.statusOf(auto), isNot(MachineStatus.broken),
        reason: 'technicians are on call');
    expect(f.craftNet['pigIron'] ?? 0, greaterThan(made),
        reason: 'the lights-out cell keeps smelting');
    expect(conservationError(f), isEmpty);
  });

  test('leave is deterministic, staggered and about 2-3 weeks a year', () {
    var weeks = 0;
    const people = 400;
    for (var id = 1; id <= people; id++) {
      for (var w = 0; w < 52; w++) {
        if (onLeave(id, w * 7 + 2)) weeks++;
      }
      expect(onLeave(id, 3), isFalse, reason: 'week 0 is no-leave');
    }
    final perYear = weeks / people;
    expect(perYear, inInclusiveRange(2.0, 3.2));
    // The same answer every call (no RNG), and a few people away any day.
    final a = [for (var id = 1; id <= 50; id++) onLeave(id, 100)];
    final b = [for (var id = 1; id <= 50; id++) onLeave(id, 100)];
    expect(a, b);
    expect(staffHash(1, 2, 3), 3637638493, reason: 'the same on every platform');
  });

  test('skip jumps an idle floor to the next shift start', () {
    final l = Lay();
    line(l, 0, MachineMode.assisted);
    final f = FactoryFloor.fromBlueprint(explicit(l.blueprint(12, 6),
        crews: [ShiftCrew(operators: 1)], startS: 14 * h - 60));
    f.step(240, port);
    final target = f.calendar.nextScheduledStart(f.schedule, f.simSeconds);
    expect(f.calendar.label(target), 'Tue 06:00 · 1st shift');
    final sw = Stopwatch()..start();
    var calls = 0;
    while (!f.skipToward(target, port, 4000)) {
      calls++;
    }
    sw.stop();
    expect(f.simSeconds, closeTo(target, 1e-9));
    expect(f.calendar.label(f.simSeconds), 'Tue 06:00 · 1st shift');
    expect(sw.elapsedMilliseconds, lessThan(2000));
    expect(calls, lessThan(20), reason: 'idle stretches are jumped');
    expect(conservationError(f), isEmpty);
  });

  test('idleOffShift (auto-skip\'s test)', () {
    final l = Lay();
    line(l, 0, MachineMode.assisted);
    final f = FactoryFloor.fromBlueprint(explicit(l.blueprint(12, 6),
        crews: [ShiftCrew(operators: 1)], startS: 14 * h - 120));
    f.step(60, port);
    expect(f.idleOffShift, isFalse, reason: 'on shift');
    f.step(300, port);
    expect(f.idleOffShift, isTrue);

    // A busy lights-out cell is never auto-skipped.
    final l2 = Lay();
    line(l2, 0, MachineMode.automated);
    final g = FactoryFloor.fromBlueprint(explicit(l2.blueprint(12, 6),
        crews: [ShiftCrew(technicians: 1)], startS: 14 * h));
    g.step(60, port);
    expect(g.onShift, isFalse);
    expect(g.idleOffShift, isFalse);
  });

  test('skip over a 16 h night with a lights-out line is fast', () {
    final l = Lay();
    line(l, 0, MachineMode.automated);
    final f = FactoryFloor.fromBlueprint(explicit(l.blueprint(12, 6),
        crews: [ShiftCrew(technicians: 1)], startS: 14 * h));
    final target = f.calendar.nextScheduledStart(f.schedule, 0);
    expect(target, 16 * h);
    final sw = Stopwatch()..start();
    while (!f.skipToward(target, port, 20000)) {}
    sw.stop();
    // ignore: avoid_print
    print('16 h lights-out skip: ${sw.elapsedMilliseconds} ms, '
        '${f.craftNet['pigIron']} pig iron made');
    expect(f.simSeconds, closeTo(target, 1e-9));
    expect(sw.elapsedMilliseconds, lessThan(2000));
    expect(f.craftNet['pigIron'] ?? 0, greaterThan(1000),
        reason: 'it ran all night');
  });

  test('templates ship with their crew hired', () {
    for (final t in kFactoryPlantTypes) {
      final bp = factoryTemplateFor(t)!;
      expect(bp.staff.auto, isFalse, reason: t);
      final f = FactoryFloor.fromBlueprint(bp);
      expect(f.crewOn(0).operators, f.operatorsNeeded, reason: t);
      expect(f.crewOn(0).technicians, f.techniciansNeeded, reason: t);
      f.step(5, port);
      for (final p in f.blueprint.placements) {
        if (p.kind != EntityKind.machine || p.crew.workers == 0) continue;
        expect(f.statusOf(p.id), isNot(MachineStatus.unstaffed),
            reason: '$t #${p.id}: its crew is at work from the first minute');
      }
    }
  });

  test('save mid-shift-change equals an unbroken run; old saves migrate', () {
    FactoryFloor make() {
      final l = Lay();
      line(l, 0, MachineMode.assisted);
      final far = line(l, 6, MachineMode.manual);
      final bp = explicit(l.blueprint(12, 12, walkers: 1),
          crews: [ShiftCrew(operators: 3), ShiftCrew(operators: 2, handlers: 1)],
          schedule: ShiftSchedule(const [0x1F, 0x1F, 0]),
          startS: 14 * h - 30);
      bp.staff.pins[staffPersonId(0, StaffRole.operator, 0)] = far;
      return FactoryFloor.fromBlueprint(bp);
    }

    final a = make(), b = make();
    a.step(40, port);
    b.step(40, port);
    final c = FactoryFloor.fromJson(
        (jsonDecode(jsonEncode(a.toJson())) as Map).cast<String, Object?>());
    for (final f in [a, b, c]) {
      f.step(200, port);
    }
    expect(jsonEncode(c.toJson()), jsonEncode(a.toJson()));
    expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()),
        reason: 'deterministic');

    // The plan round-trips with the blueprint.
    final bp = FloorBlueprint.fromJson(
        (jsonDecode(jsonEncode(a.blueprint.toJson())) as Map)
            .cast<String, Object?>());
    expect(bp.staff.auto, isFalse);
    expect(bp.staff.crews[1].operators, 2);
    expect(bp.staff.crews[1].handlers, 1);
    expect(bp.staff.schedule, ShiftSchedule(const [0x1F, 0x1F, 0]));
    expect(bp.staff.calendar.startS, 14 * h - 30);

    // An old save (no crew plan): auto crew, the old roster on the 1st
    // shift, every station crewed.
    final l = Lay();
    final m = line(l, 0, MachineMode.manual);
    final old = l.blueprint(12, 6, walkers: 2).toJson()..remove('staff');
    final o = FactoryFloor.fromBlueprint(FloorBlueprint.fromJson(old));
    expect(o.autoCrew, isTrue);
    expect(o.crewOn(0).operators, 2);
    expect(o.jobDemand, 4, reason: 'the old formula: 2 operators + 2 walkers');
    o.step(30, port);
    expect(o.statusOf(m), isNot(MachineStatus.unstaffed));
    // Hiring by hand turns it explicit, keeping what auto had.
    o.hireStaff(1, StaffRole.operator, 1);
    expect(o.autoCrew, isFalse);
    expect(o.crewOn(0).operators, 2);
    expect(o.handlers, hasLength(2));
  });
}
