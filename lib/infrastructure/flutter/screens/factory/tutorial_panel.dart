// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The tutorial card over a scenario floor
/// (lib/domain/colony/city/factory/factory_scenario.dart).
///
/// A compact card in the canvas area's top-left corner: the current step's
/// title, what to do and why, where the tool is, and Back / Next / Skip /
/// Minimise. A step that is DONE by doing something completes on its own
/// (the runner reads the floor) and the card flashes a ✓; a reading step
/// waits for Next. After the last step the card becomes the free-play goal
/// checklist: live progress bars, the shipped count, the rolling rate, the
/// jobs, and the supply switch for the deep-chain challenge.
///
/// **Where it sits.** The screen stacks it as a SIBLING above the canvas's
/// pointer [Listener], never inside it (memory: flutter-gesture-button-
/// filter): an ancestor recognizer would steal the card's clicks, and the
/// card must not take the floor's clicks either. A sibling on top wins the
/// hit test only inside its own box, so a click anywhere else on the floor
/// still reaches the canvas.
///
/// **Cadence.** The runner reads the floor on the editor's [live] tick (a
/// few times a second), not every frame: a step's check walks the layout,
/// and a person can't tell 250 ms from 16.
///
/// Plain widgets only: no custom painting, so none of the Windows GLES
/// thin-stroke trouble the floor painter works around.
library;

import 'package:flutter/material.dart';

import '../../../../domain/colony/city/factory/factory_item.dart';
import '../../../../domain/colony/city/factory/factory_scenario.dart';
import '../app_theme.dart';
import 'factory_editor_controller.dart';

/// Card width, logical px: room for a three-line step body at the 13 px
/// body size without hiding much of a 1280 px window's canvas.
const double kTutorialCardWidth = 340;

/// The card's text buttons: compact, so Back, Skip and Next share one row
/// of the narrow card.
final ButtonStyle _compact = TextButton.styleFrom(
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.symmetric(horizontal: 8));

/// Live ticks the "✓ step done" flash stays up: the editor's live tick is
/// 0.25 s, so six is 1.5 s — long enough to read four words.
const int kTutorialFlashTicks = 6;

class TutorialPanel extends StatefulWidget {
  const TutorialPanel(
      {super.key, required this.runner, required this.c, this.maxHeight});

  final ScenarioRunner runner;
  final FactoryEditorController c;

  /// The tallest the card may grow (the canvas height less a margin); its
  /// contents scroll past it.
  final double? maxHeight;

  @override
  State<TutorialPanel> createState() => TutorialPanelState();
}

class TutorialPanelState extends State<TutorialPanel> {
  bool minimised = false;

  /// Title of the step just completed, while its flash is up.
  String? flash;
  int _flashLeft = 0;

  ScenarioRunner get _run => widget.runner;
  FactoryEditorController get _c => widget.c;

  @override
  void initState() {
    super.initState();
    _c.live.addListener(_onLive);
    // Not during this build: the hint pulses widgets that are building too.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncHint();
    });
  }

  @override
  void didUpdateWidget(TutorialPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.c, widget.c)) {
      oldWidget.c.live.removeListener(_onLive);
      widget.c.live.addListener(_onLive);
    }
  }

  @override
  void dispose() {
    _c.live.removeListener(_onLive);
    super.dispose();
  }

  /// Reads the floor: the overlay flag, then the runner.
  void _onLive() {
    if (!mounted) return;
    poll();
  }

  /// One read of the floor (the live tick's work; tests call it directly).
  void poll() {
    _run.noteBottlenecks(_c.overlays.contains(FactoryOverlay.bottleneck));
    final ev = _run.update(_c.sim);
    if (ev.stepsDone.isNotEmpty) {
      final id = ev.stepsDone.last;
      flash = _run.scenario.steps.firstWhere((s) => s.id == id).title;
      _flashLeft = kTutorialFlashTicks;
      _syncHint();
    } else if (_flashLeft > 0 && --_flashLeft == 0) {
      flash = null;
    }
    setState(() {});
  }

  void _syncHint() {
    final s = _run.currentStep;
    _c.setHintTargets(minimised || s == null
        ? const {}
        : (s.hint?.targets ?? const {}));
  }

  void next() {
    if (_run.next(_c.sim)) _after();
  }

  void back() {
    if (_run.back()) _after();
  }

  void skip() {
    _run.skipTutorial(_c.sim);
    _after();
  }

  void toggleMinimised() {
    minimised = !minimised;
    _after();
  }

  void _after() {
    flash = null;
    _flashLeft = 0;
    _syncHint();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (minimised) return _minimisedChip();
    return Material(
      color: Colors.transparent,
      child: Container(
        key: const Key('tutorial-panel'),
        width: kTutorialCardWidth,
        constraints: BoxConstraints(maxHeight: widget.maxHeight ?? 600),
        decoration: AppTheme.panelBox(border: AppTheme.accent),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: _run.inGoals ? _goals() : _step(),
        ),
      ),
    );
  }

  Widget _minimisedChip() {
    final label = _run.inGoals
        ? 'Goals ${_run.progress.goalMetAt.length}/'
            '${_run.scenario.goals.length}'
        : 'Tutorial ${_run.progress.step + 1}/${_run.scenario.steps.length}';
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: AppTheme.panelBox(border: AppTheme.accent),
        child: TextButton.icon(
          key: const Key('tutorial-expand'),
          onPressed: toggleMinimised,
          icon: const Icon(Icons.school, size: 16, color: AppTheme.accent),
          label: Text(label, style: AppTheme.body),
        ),
      ),
    );
  }

  Widget _header(String text) => Row(children: [
        Expanded(
          child: Text(text,
              style: AppTheme.heading.copyWith(color: AppTheme.accent)),
        ),
        IconButton(
          key: const Key('tutorial-minimise'),
          tooltip: 'Minimise',
          visualDensity: VisualDensity.compact,
          onPressed: toggleMinimised,
          icon: const Icon(Icons.remove, size: 18, color: AppTheme.text),
        ),
      ]);

  Widget? _flashRow() {
    final f = flash;
    if (f == null) return null;
    return Container(
      key: const Key('tutorial-flash'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.accent2.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppTheme.accent2),
      ),
      child: Text('✓ $f',
          style: AppTheme.body.copyWith(color: AppTheme.accent2)),
    );
  }

  /// Receiving docks whose item the current supply doesn't include.
  List<Widget> _warnings() {
    final bad = _run.unsuppliedDocks(_c.sim);
    if (bad.isEmpty) return const [];
    return [
      const SizedBox(height: 8),
      for (final p in bad)
        Padding(
          key: Key('tutorial-warning-${p.id}'),
          padding: const EdgeInsets.only(top: 2),
          child: Text(
              '⚠ Receiving dock #${p.id} '
              '(${FactoryItems.byId(p.item ?? '')?.label ?? p.item}): '
              'this item isn\'t supplied in this scenario, so it will never '
              'unload.',
              style: AppTheme.dim.copyWith(color: AppTheme.warn)),
        ),
    ];
  }

  Widget _step() {
    final s = _run.currentStep!;
    final n = _run.scenario.steps.length;
    final done = _run.isDone(s);
    final hint = s.hint;
    final fl = _flashRow();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _header('TUTORIAL · STEP ${_run.progress.step + 1} / $n'),
        ?fl,
        Text(s.title,
            key: const Key('tutorial-step-title'),
            style: AppTheme.title.copyWith(fontSize: 15)),
        const SizedBox(height: 6),
        Text(s.body, key: const Key('tutorial-step-body'), style: AppTheme.body),
        if (hint != null) ...[
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.lightbulb_outline, size: 14,
                color: AppTheme.accent2),
            const SizedBox(width: 6),
            Expanded(
              child: Text(hint.text,
                  key: const Key('tutorial-hint'),
                  style: AppTheme.dim.copyWith(color: AppTheme.accent2)),
            ),
          ]),
        ],
        if (done)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('✓ Done', style: TextStyle(color: AppTheme.accent2)),
          ),
        ..._warnings(),
        const SizedBox(height: 10),
        // A Wrap, not a Row: a wide font (or a long translation) moves Next
        // to a second line instead of pushing it out of the card, where it
        // would sit over the canvas and its clicks would land on the floor.
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          runSpacing: 4,
          children: [
            TextButton(
              key: const Key('tutorial-back'),
              style: _compact,
              onPressed: _run.canBack ? back : null,
              child: const Text('Back'),
            ),
            TextButton(
              key: const Key('tutorial-skip'),
              style: _compact,
              onPressed: skip,
              child: const Text('Skip tutorial',
                  style: TextStyle(color: AppTheme.textDim)),
            ),
            FilledButton(
              key: const Key('tutorial-next'),
              style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 16)),
              onPressed: _run.canNext ? next : null,
              child: const Text('Next'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _goals() {
    final sc = _run.scenario;
    final sim = _c.sim;
    final p = _run.progress;
    final readings = _run.readGoals(sim);
    final shipped = p.shippedSinceGoalStart(sim, sc.product);
    final rate = _run.rate;
    final fl = _flashRow();
    String t(double s) => '${s.toStringAsFixed(0)} s';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _header('FREE PLAY'),
        ?fl,
        Text(sc.freePlayTitle,
            key: const Key('tutorial-goals-title'),
            style: AppTheme.title.copyWith(fontSize: 15)),
        if (sc.freePlayBody.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(sc.freePlayBody, style: AppTheme.body),
        ],
        const SizedBox(height: 8),
        Text(
            'Shipped ${shipped.toStringAsFixed(0)} · '
            'rate ${rate == null ? '—' : rate.toStringAsFixed(2)}/s '
            '(last ${sc.rateWindowS.toStringAsFixed(0)} s) · '
            'jobs ${sim.jobDemand.toStringAsFixed(1)}',
            key: const Key('tutorial-goal-summary'),
            style: AppTheme.mono),
        for (final (g, r) in readings) _goalRow(g, r, p.goalMetAt[g.id], t),
        if (sc.supplyOptions.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('SUPPLY', style: AppTheme.heading),
          const SizedBox(height: 4),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final o in sc.supplyOptions)
              ChoiceChip(
                key: Key('tutorial-supply-${o.id}'),
                label: Text(o.label),
                selected: (p.supplyOptionId ?? sc.supplyOptions.first.id) ==
                    o.id,
                onSelected: (_) {
                  _run.setSupply(o, sim);
                  setState(() {});
                },
              ),
          ]),
          const SizedBox(height: 2),
          Text('Docks receive: ${_run.port.supply.join(', ')}',
              style: AppTheme.dim),
        ],
        ..._warnings(),
        const SizedBox(height: 8),
        Row(children: [
          TextButton(
            key: const Key('tutorial-back'),
            onPressed: _run.canBack ? back : null,
            child: const Text('Back to the tutorial'),
          ),
        ]),
      ],
    );
  }

  Widget _goalRow(ScenarioGoal g, GoalReading r, double? metAt,
      String Function(double) t) {
    final met = metAt != null;
    return Padding(
      key: Key('tutorial-goal-${g.id}'),
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(met ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 14, color: met ? AppTheme.accent2 : AppTheme.textDim),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                  g.optional ? '${g.title} (optional)' : g.title,
                  style: AppTheme.body),
            ),
          ]),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            key: Key('tutorial-goal-${g.id}-bar'),
            value: met ? 1 : r.progress,
            minHeight: 6,
            backgroundColor: AppTheme.panelLight,
            color: met ? AppTheme.accent2 : AppTheme.accent,
          ),
          const SizedBox(height: 2),
          Text(met ? '${r.status} · met at ${t(metAt)}' : r.status,
              key: Key('tutorial-goal-${g.id}-status'),
              style: AppTheme.dim),
          Text(g.detail, style: AppTheme.dim.copyWith(fontSize: 11)),
        ],
      ),
    );
  }
}

/// Pulses a border around [child] while [on]: a tutorial hint pointing at
/// a palette entry, roster row or header button. Off, it is [child] alone
/// (no animation runs, no layout changes).
class HintPulse extends StatefulWidget {
  const HintPulse({super.key, required this.on, required this.child});
  final bool on;
  final Widget child;

  @override
  State<HintPulse> createState() => _HintPulseState();
}

/// One pulse, in and out: slow enough to read as "look here", not as an
/// alarm.
const Duration _kPulse = Duration(milliseconds: 900);

class _HintPulseState extends State<HintPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _a =
      AnimationController(vsync: this, duration: _kPulse);

  @override
  void initState() {
    super.initState();
    if (widget.on) _a.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(HintPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.on && !_a.isAnimating) {
      _a.repeat(reverse: true);
    } else if (!widget.on && _a.isAnimating) {
      _a.stop();
    }
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.on) return widget.child;
    return AnimatedBuilder(
      animation: _a,
      builder: (context, child) => Container(
        key: const Key('hint-pulse'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
              color: AppTheme.accent2.withValues(alpha: 0.35 + 0.65 * _a.value),
              width: 2),
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}
