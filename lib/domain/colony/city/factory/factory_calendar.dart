// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The floor's clock: weekdays, hours, shifts, holidays and who is on
/// leave (docs/plans/factory-floors.md §10 items 5 and 20).
///
/// **Why a calendar at all.** A plant is staffed by people who work shifts,
/// take weekends and go on holiday, and the case for automation is exactly
/// that a lights-out cell keeps running when they don't. So the floor needs
/// a wall clock, not just a sim-seconds counter: "Mon 06:42 · 1st shift".
///
/// **Real time.** The floor runs in REAL time: one floor second is one
/// second, a day is 86,400 s and a shift is 8 h ([kShiftS]). The player
/// gets through the dull parts with the speed buttons (1/4/16/60×),
/// "Skip to next shift" and "Auto-skip off-hours", not by compressing the
/// clock (a compressed clock would make a 6 s weld look like a 2 h job).
///
/// **In a colony** the colony's own day is 120 s (`CitySim`), far too short
/// for walking crews but the only clock the colony has. [FactoryCalendar
/// .colony] maps the shift calendar onto it: each colony day is one floor
/// day, so each THIRD of it (40 s) is a shift. Only the calendar is
/// rescaled ([dayLengthS]); the floor's physics still steps one floor
/// second per colony second. That is the plan's stated default "until the
/// colony clock is revisited".
///
/// **Days and the year.** Calendar day 0 is a Monday. The floor year is 52
/// weeks (364 days) so a weekday and a holiday fall on the same day every
/// year. Shifts start at 06:00 ([kFirstShiftStartS]): the 1st shift runs
/// 06–14, the 2nd 14–22, the 3rd 22–06. A 3rd shift belongs to the day it
/// STARTS on (Monday's 3rd shift ends Tuesday 06:00), its "shift day".
///
/// **No RNG.** Leave ([onLeave]) is a hash of a person id and the week, so
/// the same person is away the same weeks on every run, save and load.
library;

/// Seconds in a calendar day.
const double kCalendarDayS = 86400;

/// Seconds in a shift (three a day).
const double kShiftS = 8 * 3600;

/// Calendar seconds after midnight at which the 1st shift starts.
const double kFirstShiftStartS = 6 * 3600;

/// Days in a floor year: 52 whole weeks, so weekdays repeat every year.
const int kFloorYearDays = 364;

/// The colony's day, colony seconds (`CitySim`'s 120 s day). A colony floor
/// maps one colony day onto one calendar day.
const double kColonyDayS = 120;

/// Default start: Monday 06:00, the 1st shift's first minute.
const double kDefaultCalendarStartS = kFirstShiftStartS;

/// Short weekday names, Monday first.
const List<String> kWeekdayNames = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

/// Shift names, 1st first.
const List<String> kShiftNames = ['1st shift', '2nd shift', '3rd shift'];

/// Pay multiplier per shift (1st, 2nd, 3rd): a 10% evening and a 15% night
/// differential, the usual industrial premiums. The ledger books the extra
/// as [FactoryLedger.premiumSeconds] (factor − 1 per worker-second), so a
/// cost model multiplies (workerSeconds + premiumSeconds) by the wage.
const List<double> kShiftPremium = [1.0, 1.10, 1.15];

/// Plant holidays, by day of the floor year (day 0 = the year's first
/// Monday). No shift is scheduled on a holiday; automation still runs.
///
/// The first week is deliberately clear (and is a no-leave week, see
/// [onLeave]): a fresh floor starts on day 0, and its first shifts are
/// what a template's spec rate is measured over.
///
/// | day | when                       |
/// |-----|----------------------------|
/// | 32  | Founders' Day (Wed, wk 5)  |
/// | 88  | Spring holiday (Fri, wk13) |
/// | 91  | Spring holiday (Mon, wk14) |
/// | 147 | Late-spring Monday (wk 21) |
/// | 186 | Midsummer (Fri, wk 26)     |
/// | 245 | Labour Day (Mon, wk 35)    |
/// | 324 | Harvest (Thu, wk 46)       |
/// | 325 | Harvest (Fri, wk 46)       |
/// | 358 | Year-end (Tue, wk 51)      |
/// | 359 | Year-end (Wed, wk 51)      |
const Set<int> kFactoryHolidays = {32, 88, 91, 147, 186, 245, 324, 325, 358, 359};

/// Per-mille chance-equivalent that a person is on leave in a given week
/// (weeks 1..51): 51 × 52/1000 ≈ 2.65 weeks a year, the plan's "2–3 weeks
/// of leave a year". Staggered because each person's weeks come from their
/// own hash, so on any day a few percent of the crew are away.
const int kLeavePerMilleWeekly = 52;

/// Which shifts run on which weekdays: one 7-bit mask per shift, bit d =
/// weekday d (0 = Monday).
class ShiftSchedule {
  ShiftSchedule([List<int>? masks])
      : masks = [
          for (var s = 0; s < 3; s++)
            (masks != null && s < masks.length ? masks[s] : 0) & 0x7F,
        ];

  /// The default: 1st shift, Monday to Friday.
  factory ShiftSchedule.standard() => ShiftSchedule(const [0x1F, 0, 0]);

  /// Every shift every day (a plant that never stops).
  factory ShiftSchedule.roundTheClock() =>
      ShiftSchedule(const [0x7F, 0x7F, 0x7F]);

  /// Weekday bits per shift (1st, 2nd, 3rd).
  final List<int> masks;

  bool runs(int shift, int weekday) => (masks[shift] >> weekday) & 1 == 1;

  /// Whether [shift] runs on any day at all.
  bool usesShift(int shift) => masks[shift] != 0;

  void set(int shift, int weekday, bool on) {
    final bit = 1 << weekday;
    masks[shift] = on ? (masks[shift] | bit) : (masks[shift] & ~bit) & 0x7F;
  }

  ShiftSchedule copy() => ShiftSchedule([...masks]);

  bool get isStandard => masks[0] == 0x1F && masks[1] == 0 && masks[2] == 0;

  List<int> toJson() => [...masks];

  static ShiftSchedule fromJson(Object? j) => j is List
      ? ShiftSchedule([for (final v in j) (v as num).toInt()])
      : ShiftSchedule.standard();

  @override
  bool operator ==(Object other) =>
      other is ShiftSchedule &&
      other.masks[0] == masks[0] &&
      other.masks[1] == masks[1] &&
      other.masks[2] == masks[2];

  @override
  int get hashCode => Object.hash(masks[0], masks[1], masks[2]);
}

/// Sim seconds to wall-clock time. Immutable; a floor holds one.
///
/// This is the small schedule-time interface the docks-and-ordering work
/// adopts: a recurring order "weekdays 06:00" is [nextAt] with a weekday
/// mask and an hour, and "is it a working day" is [weekday] / [isHoliday].
class FactoryCalendar {
  const FactoryCalendar({
    this.startS = kDefaultCalendarStartS,
    this.dayLengthS = kCalendarDayS,
  });

  /// A colony floor: one colony day (120 s) is one calendar day, so each
  /// third of it is a shift (see the library notes).
  const FactoryCalendar.colony({this.startS = kDefaultCalendarStartS})
      : dayLengthS = kColonyDayS;

  /// Calendar seconds (since Monday 00:00 of day 0) at sim second 0.
  final double startS;

  /// Sim seconds per calendar day: 86,400 (real time) or a colony's 120.
  final double dayLengthS;

  /// Calendar seconds per sim second (1 in real time, 720 in a colony).
  double get scale => kCalendarDayS / dayLengthS;

  bool get isRealTime => dayLengthS == kCalendarDayS;

  /// Calendar seconds since Monday 00:00 of day 0 at sim second [simS].
  double calendarS(double simS) => startS + simS * scale;

  /// The sim second at calendar second [calS] (inverse of [calendarS]).
  double simAt(double calS) => (calS - startS) / scale;

  /// Whole calendar days since day 0.
  int day(double simS) => (calendarS(simS) / kCalendarDayS).floor();

  /// 0 = Monday … 6 = Sunday.
  int weekday(double simS) => day(simS) % 7;

  /// Hours since midnight, 0..24.
  double hourOfDay(double simS) {
    final c = calendarS(simS);
    return (c - (c / kCalendarDayS).floor() * kCalendarDayS) / 3600;
  }

  /// Shifts since day 0's 1st shift (the 3rd shift before it is −1).
  int shiftOrdinal(double simS) =>
      ((calendarS(simS) - kFirstShiftStartS) / kShiftS).floor();

  /// 0 = 1st (06–14), 1 = 2nd (14–22), 2 = 3rd (22–06).
  int shiftAt(double simS) => shiftOrdinal(simS) % 3;

  /// The day the current shift STARTED on (a 3rd shift after midnight
  /// belongs to the day before).
  int shiftDay(double simS) {
    final o = shiftOrdinal(simS);
    return (o / 3).floor();
  }

  /// Sim second at which shift ordinal [o] starts.
  double shiftStartSim(int o) => simAt(kFirstShiftStartS + o * kShiftS);

  /// Sim second of the next shift boundary strictly after [simS].
  double nextShiftBoundary(double simS) {
    var t = shiftStartSim(shiftOrdinal(simS) + 1);
    // Float guard: a boundary that lands on simS itself moves one on.
    if (t <= simS) t = shiftStartSim(shiftOrdinal(simS) + 2);
    return t;
  }

  /// Whether [day] (whole calendar days) is a plant holiday.
  static bool isHoliday(int day) =>
      kFactoryHolidays.contains(day % kFloorYearDays);

  /// Whether [schedule] has a crew on the floor at [simS]: its shift runs on
  /// its shift day's weekday and that day is not a holiday.
  bool onShift(ShiftSchedule schedule, double simS) {
    final d = shiftDay(simS);
    return !isHoliday(d) && schedule.runs(shiftAt(simS), d % 7);
  }

  /// Sim second the next SCHEDULED shift starts strictly after [simS], or
  /// the next boundary when nothing is scheduled in the coming four weeks.
  double nextScheduledStart(ShiftSchedule schedule, double simS) {
    var o = shiftOrdinal(simS) + 1;
    for (var i = 0; i < 3 * 28; i++, o++) {
      final d = (o / 3).floor();
      if (!isHoliday(d) && schedule.runs(o % 3, d % 7)) {
        final t = shiftStartSim(o);
        if (t > simS) return t;
      }
    }
    return nextShiftBoundary(simS);
  }

  /// The next sim second strictly after [simS] at which the clock reads
  /// [hour] (0..24, fractional for minutes) on a weekday in [weekdayMask]
  /// (bit d = weekday d), skipping holidays when [skipHolidays]. The
  /// ordering work's "weekdays 06:00" is `nextAt(t, 0x1F, 6)`. Null when
  /// the mask is empty.
  double? nextAt(double simS, int weekdayMask, double hour,
      {bool skipHolidays = false}) {
    if (weekdayMask & 0x7F == 0) return null;
    final d0 = day(simS);
    for (var d = d0; d < d0 + 7 * 60; d++) {
      if ((weekdayMask >> (d % 7)) & 1 == 0) continue;
      if (skipHolidays && isHoliday(d)) continue;
      final t = simAt(d * kCalendarDayS + hour * 3600);
      if (t > simS) return t;
    }
    return null;
  }

  /// "Mon 06:42 · 1st shift".
  String label(double simS) {
    final h = hourOfDay(simS);
    final hh = h.floor();
    final mm = ((h - hh) * 60).floor();
    return '${kWeekdayNames[weekday(simS)]} '
        '${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}'
        ' · ${kShiftNames[shiftAt(simS)]}';
  }

  Map<String, Object?> toJson() => {
        if (startS != kDefaultCalendarStartS) 'st': startS,
        if (dayLengthS != kCalendarDayS) 'dl': dayLengthS,
      };

  static FactoryCalendar fromJson(Object? j) {
    final m = ((j as Map?) ?? const {}).cast<String, Object?>();
    return FactoryCalendar(
      startS: (m['st'] as num?)?.toDouble() ?? kDefaultCalendarStartS,
      dayLengthS: (m['dl'] as num?)?.toDouble() ?? kCalendarDayS,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FactoryCalendar &&
      other.startS == startS &&
      other.dayLengthS == dayLengthS;

  @override
  int get hashCode => Object.hash(startS, dayLengthS);
}

/// 32-bit multiply that stays exact on the web (no product over 2^53).
int _mul32(int a, int b) {
  final lo = (a & 0xFFFF) * b;
  final hi = (((a >>> 16) & 0xFFFF) * b) & 0xFFFF;
  return (lo + (hi << 16)) & 0xFFFFFFFF;
}

/// A small integer hash (murmur3 finaliser), the same on every platform.
int staffHash(int a, int b, int c) {
  var h = (a * 31 + b) & 0xFFFFFFFF;
  h = (h * 31 + c) & 0xFFFFFFFF;
  h ^= h >>> 16;
  h = _mul32(h, 0x85EBCA6B);
  h ^= h >>> 13;
  h = _mul32(h, 0xC2B2AE35);
  h ^= h >>> 16;
  return h;
}

/// Whether person [personId] is on leave on calendar day [day].
///
/// Leave is taken in whole weeks: week w of year y is a leave week when
/// `staffHash(id, y, w) % 1000 < kLeavePerMilleWeekly`. Week 0 is a
/// no-leave week (year-start stocktake), which also makes a fresh floor's
/// first week full-strength. Holidays are separate ([FactoryCalendar
/// .isHoliday]): nobody works them.
bool onLeave(int personId, int day) {
  final y = (day / kFloorYearDays).floor();
  final w = (day - y * kFloorYearDays) ~/ 7;
  if (w == 0) return false;
  return staffHash(personId, y, w) % 1000 < kLeavePerMilleWeekly;
}
