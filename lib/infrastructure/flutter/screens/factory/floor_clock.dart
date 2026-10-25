// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The floor's clock controls and crew panel (docs/plans/factory-floors.md
/// §10 items 5 and 20): the header's "Mon 06:42 · 1st shift", the speed
/// buttons, "Skip to next shift", "Auto-skip off-hours", the per-shift crew
/// roster with its weekday chips, and the inspector's pin control.
///
/// **Skip** ([FloorClock]). The floor runs in real time, so a night is
/// 57,600 s. A skip hands the floor's own `skipToward` small chunks of
/// sub-steps until a WALL-clock frame budget ([kSkipFrameBudgetMs]) is
/// spent, then yields the frame, so the window keeps painting and the
/// header shows a progress bar. The floor itself jumps provably idle
/// stretches (nobody on shift, nothing working, belts settled) in one go,
/// and a lights-out line's night is plain fast sub-steps; together a 16 h
/// night with an automated line takes well under the 2 s budget
/// (shifts_test.dart measures it). The budget only decides how much runs
/// per frame, never what happens: the floor's jumps are placed at absolute
/// sub-step indices, so a skip ends in the same state however it was
/// chunked.
///
/// **Auto-skip off-hours**: whenever the floor is `idleOffShift` (no shift
/// on, nothing automated working, no handler on a job) it skips to the
/// next scheduled shift start by itself. A working lights-out cell is
/// never auto-skipped: watching it run is the point.
///
/// Every widget here reads the sim through [FactoryStaffedSim]; for a sim
/// without it (the editor tests' fake) they render nothing.
library;

import 'package:flutter/material.dart';

import '../../../../domain/colony/city/factory/factory_calendar.dart';
import '../../../../domain/colony/city/factory/factory_colony_port.dart';
import '../../../../domain/colony/city/factory/factory_sim_api.dart';
import '../../../../domain/colony/city/factory/factory_staffing.dart';
import '../app_theme.dart';
import 'factory_editor_controller.dart';

/// Wall milliseconds a skip may spend per frame.
const int kSkipFrameBudgetMs = 12;

/// Sub-steps per `skipToward` call inside a frame (between budget checks).
const int kSkipChunk = 2000;

/// The speed buttons (0 = pause).
const List<double> kFloorSpeeds = [0, 1, 4, 16, 60];

/// The skip state machine the editor's tick consults.
class FloorClock {
  /// Sim second the running skip is heading for (null: none).
  double? skipTarget;
  double _skipFrom = 0;

  /// "Auto-skip off-hours".
  bool autoSkip = false;

  bool get skipping => skipTarget != null;

  /// 0..1 of the running skip.
  double progress(FactorySim sim) {
    final t = skipTarget;
    if (t == null) return 0;
    final span = t - _skipFrom;
    return span <= 0 ? 1 : ((sim.simSeconds - _skipFrom) / span).clamp(0, 1);
  }

  /// Starts a skip to the next scheduled shift start.
  void skipToNextShift(FactorySim sim) {
    if (sim is! FactoryStaffedSim) return;
    final s = sim as FactoryStaffedSim;
    _skipFrom = sim.simSeconds;
    skipTarget = s.calendar.nextScheduledStart(s.schedule, sim.simSeconds);
  }

  void cancel() => skipTarget = null;

  /// One frame: runs a skip (or starts an auto-skip) within the frame
  /// budget. True when it drove the sim this frame (the caller then
  /// doesn't step it at speed).
  bool tick(FactorySim sim, FactoryColonyPort port) {
    if (sim is! FactoryStaffedSim) return false;
    final s = sim as FactoryStaffedSim;
    if (skipTarget == null && autoSkip && s.idleOffShift) {
      skipToNextShift(sim);
    }
    final t = skipTarget;
    if (t == null) return false;
    final sw = Stopwatch()..start();
    var done = false;
    while (!done && sw.elapsedMilliseconds < kSkipFrameBudgetMs) {
      done = s.skipToward(t, port, kSkipChunk);
    }
    if (done) skipTarget = null;
    return true;
  }
}

/// The header's clock and speed buttons.
class FloorClockBar extends StatelessWidget {
  const FloorClockBar({super.key, required this.c});
  final FactoryEditorController c;

  @override
  Widget build(BuildContext context) {
    final sim = c.sim;
    final staffed = sim is FactoryStaffedSim ? sim as FactoryStaffedSim : null;
    return ListenableBuilder(
      listenable: c.live,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (staffed != null) ...[
              Text(
                staffed.calendar.label(sim.simSeconds) +
                    (staffed.onShift ? '' : ' · off'),
                key: const Key('floor-clock'),
                style: AppTheme.mono.copyWith(
                  fontSize: 11,
                  color: staffed.onShift ? AppTheme.text : AppTheme.textDim,
                ),
              ),
              const SizedBox(width: 6),
            ],
            if (c.drivesSim) ...[
              // Compact text buttons: the header is shared with the overlay
              // chips and the panels' toggles.
              for (final s in kFloorSpeeds)
                Tooltip(
                  message: s == 0 ? 'Pause' : '${s.round()}x speed',
                  child: InkWell(
                    key: Key('speed-${s.round()}'),
                    onTap: () => c.setSpeed(s),
                    child: Container(
                      width: s >= 10 ? 30 : 24,
                      height: 26,
                      alignment: Alignment.center,
                      color: c.speed == s
                          ? AppTheme.accent.withValues(alpha: 0.25)
                          : null,
                      child: s == 0
                          ? Icon(
                              Icons.pause,
                              size: 16,
                              color: c.speed == s
                                  ? AppTheme.accent
                                  : AppTheme.textDim,
                            )
                          : Text(
                              '${s.round()}x',
                              style: AppTheme.mono.copyWith(
                                fontSize: 11,
                                color: c.speed == s
                                    ? AppTheme.accent
                                    : AppTheme.textDim,
                              ),
                            ),
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// "Skip to next shift" and "Auto-skip off-hours" (top of the side panel:
/// the header row is shared with the overlay chips and has no room).
class FloorSkipControls extends StatelessWidget {
  const FloorSkipControls({super.key, required this.c});
  final FactoryEditorController c;

  @override
  Widget build(BuildContext context) {
    final sim = c.sim;
    if (!c.drivesSim || sim is! FactoryStaffedSim) {
      return const SizedBox.shrink();
    }
    final clock = c.clock;
    return Wrap(
      key: const Key('skip-controls'),
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (clock.skipping)
          SizedBox(
            width: 120,
            height: 32,
            child: Center(
              child: LinearProgressIndicator(
                key: const Key('skip-progress'),
                value: clock.progress(sim),
              ),
            ),
          )
        else
          TextButton.icon(
            key: const Key('skip-shift'),
            onPressed: () {
              clock.skipToNextShift(sim);
              c.live.value++;
            },
            icon: const Icon(Icons.skip_next, size: 16, color: AppTheme.text),
            label: const Text('Next shift', style: AppTheme.body),
          ),
        Tooltip(
          message:
              'Auto-skip off-hours: jump over nights and weekends '
              'when nothing automated is running',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                key: const Key('auto-skip'),
                visualDensity: VisualDensity.compact,
                value: clock.autoSkip,
                onChanged: (v) {
                  clock.autoSkip = v ?? false;
                  c.live.value++;
                },
              ),
              const Text('Auto-skip', style: AppTheme.dim),
            ],
          ),
        ),
      ],
    );
  }
}

/// The per-shift crew: hired counts with + / −, and which weekdays each
/// shift runs.
class FloorCrewPanel extends StatelessWidget {
  const FloorCrewPanel({super.key, required this.c});
  final FactoryEditorController c;

  @override
  Widget build(BuildContext context) {
    final sim = c.sim;
    if (sim is! FactoryStaffedSim) return const SizedBox.shrink();
    final s = sim as FactoryStaffedSim;
    final here = <int, int>{};
    for (final v in s.staff) {
      here[v.shift] = (here[v.shift] ?? 0) + 1;
    }
    return Column(
      key: const Key('crew-panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Text('CREW', style: AppTheme.heading)),
            if (s.autoCrew)
              const Tooltip(
                message:
                    'Auto crew: the 1st shift hires what the layout needs. '
                    'Hiring by hand turns it off.',
                child: Text('auto', style: AppTheme.dim),
              ),
          ],
        ),
        Text(
          'Layout needs ${s.operatorsNeeded} operators and '
          '${s.techniciansNeeded} technicians per shift',
          style: AppTheme.dim.copyWith(fontSize: 11),
        ),
        for (var shift = 0; shift < 3; shift++) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${kShiftNames[shift]} · ×${kShiftPremium[shift].toStringAsFixed(2)} pay'
                  ' · ${here[shift] ?? 0} in',
                  style: AppTheme.body,
                ),
              ),
            ],
          ),
          _days(s, shift),
          for (final role in [StaffRole.operator, StaffRole.technician, null])
            if (role != null || shift > 0) _row(s, shift, role),
        ],
      ],
    );
  }

  Widget _days(FactoryStaffedSim s, int shift) => Wrap(
    spacing: 2,
    children: [
      for (var d = 0; d < 7; d++)
        InkWell(
          key: Key('shift-$shift-day-$d'),
          onTap: () {
            s.setShiftDay(shift, d, !s.schedule.runs(shift, d));
            c.live.value++;
          },
          child: Container(
            width: 22,
            height: 18,
            alignment: Alignment.center,
            color: s.schedule.runs(shift, d)
                ? AppTheme.accent.withValues(alpha: 0.35)
                : AppTheme.panelLight,
            child: Text(
              kWeekdayNames[d].substring(0, 2),
              style: AppTheme.dim.copyWith(fontSize: 10),
            ),
          ),
        ),
    ],
  );

  Widget _row(FactoryStaffedSim s, int shift, StaffRole? role) {
    final crew = s.crewOn(shift);
    final n = role == null ? crew.handlers : crew.count(role);
    final tag = role?.name ?? 'handlers';
    void hire(int d) {
      s.hireStaff(shift, role, d);
      c.live.value++;
    }

    return Row(
      key: Key('crew-$shift-$tag'),
      children: [
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            staffRoleLabel(role),
            style: AppTheme.dim.copyWith(fontSize: 12),
          ),
        ),
        IconButton(
          key: Key('crew-$shift-$tag-minus'),
          visualDensity: VisualDensity.compact,
          onPressed: n > 0 ? () => hire(-1) : null,
          icon: const Icon(Icons.remove, size: 14),
        ),
        SizedBox(
          width: 24,
          child: Text(
            '$n',
            key: Key('crew-$shift-$tag-count'),
            textAlign: TextAlign.center,
            style: AppTheme.mono,
          ),
        ),
        IconButton(
          key: Key('crew-$shift-$tag-plus'),
          visualDensity: VisualDensity.compact,
          onPressed: () => hire(1),
          icon: const Icon(Icons.add, size: 14),
        ),
      ],
    );
  }
}

/// The inspector's crew line for station [placementId]: who mans it, and a
/// pin toggle that keeps them there whatever the nearest-first assignment
/// would do.
class StaffPinRow extends StatelessWidget {
  const StaffPinRow({super.key, required this.c, required this.placementId});
  final FactoryEditorController c;
  final int placementId;

  @override
  Widget build(BuildContext context) {
    final sim = c.sim;
    if (sim is! FactoryStaffedSim) return const SizedBox.shrink();
    final s = sim as FactoryStaffedSim;
    final at = s.staffAt(placementId);
    final pinned = at.isNotEmpty && at.every((v) => v.pinned);
    return Row(
      key: const Key('staff-pin-row'),
      children: [
        Expanded(
          child: Text(
            at.isEmpty
                ? 'Crew: nobody here'
                : 'Crew: ${[for (final v in at) '#${v.id}'].join(', ')}'
                      '${pinned ? ' · pinned' : ''}',
            style: AppTheme.dim,
          ),
        ),
        if (at.isNotEmpty)
          TextButton(
            key: const Key('staff-pin'),
            onPressed: () {
              for (final v in at) {
                s.pinStaff(v.id, pinned ? null : placementId);
              }
              c.live.value++;
            },
            child: Text(pinned ? 'Unpin' : 'Pin here'),
          ),
      ],
    );
  }
}
