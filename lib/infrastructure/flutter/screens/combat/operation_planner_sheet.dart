// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The planner for retaking a seized spaceport (docs/plans/combat.md §7.9).
///
/// It shows what the player can send and from where, and what it will likely
/// cost — a spread of outcomes from the same resolver the battle runs, never
/// one promised answer — and says plainly what force does not do. Launch only
/// enqueues a command: the world applies it at the next tick.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../domain/colony/city/city_loyalty.dart';
import '../../../../domain/colony/city/city_sim.dart';
import '../../../../domain/colony/city/city_war.dart';
import '../../../../domain/combat/launch/plan_operation.dart';
import '../../../../domain/combat/launch/snapshots.dart';
import '../../../../domain/combat/operation.dart';
import '../../../../domain/combat/operation_registry.dart';
import '../../../../domain/combat/preview.dart';
import '../../../../domain/multiplayer/command.dart';
import '../../../../domain/multiplayer/player.dart';
import '../app_theme.dart';

/// Opens the planner over [target] as a bottom sheet.
Future<void> showOperationPlanner(
  BuildContext context, {
  required CitySim target,
  required List<CitySim> sources,
  required OperationRegistry registry,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.panel,
      builder: (_) => OperationPlannerSheet(
        target: target,
        sources: sources,
        registry: registry,
        onLaunch: registry.inbox.enqueue,
      ),
    );

class OperationPlannerSheet extends StatefulWidget {
  const OperationPlannerSheet({
    super.key,
    required this.target,
    required this.sources,
    required this.registry,
    required this.onLaunch,
  });

  final CitySim target;
  final List<CitySim> sources;
  final OperationRegistry registry;
  final void Function(LaunchOperationCommand) onLaunch;

  @override
  State<OperationPlannerSheet> createState() => _OperationPlannerSheetState();
}

class _OperationPlannerSheetState extends State<OperationPlannerSheet> {
  late final LaunchSnapshot _target = widget.target.launchSnapshot();
  late final List<SourceSnapshot> _sources = [
    for (final s in widget.sources) s.sourceSnapshot(),
  ];

  /// Troopers chosen per (colony, building).
  final Map<String, int> _counts = {};
  double _kitDays = 3;
  int _garrison = 2;

  OperationPreview? _preview;
  String? _refusal;
  Timer? _ticker;

  static String _key(String colony, String site) => '$colony|$site';

  @override
  void initState() {
    super.initState();
    for (final s in _sources) {
      for (final t in s.sources) {
        if (t.ready) _counts[_key(s.colonyId, t.siteId)] = t.available;
      }
    }
    _garrison = _defaultGarrison();
    _replan();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  int get _total {
    var n = 0;
    for (final v in _counts.values) {
      n += v;
    }
    return n;
  }

  int _defaultGarrison() {
    final want = (_target.population * 0.01).ceil().clamp(2, 1 << 20);
    return want > _total ? _total : want;
  }

  List<TrooperDraw> get _draws => [
        for (final s in _sources)
          for (final t in s.sources)
            if ((_counts[_key(s.colonyId, t.siteId)] ?? 0) > 0)
              TrooperDraw(s.colonyId, t.siteId, _counts[_key(s.colonyId, t.siteId)]!),
      ];

  /// Plans the operation as chosen and restarts the preview on it. The id is
  /// the one the launch would take, so the preview is of this decision.
  void _replan() {
    _ticker?.cancel();
    final planned = planPortRetake(
      operationId: widget.registry.nextOperationId,
      target: _target,
      sources: _sources,
      draws: _draws,
      kitDays: _kitDays,
      garrison: _garrison,
    );
    _refusal = planned.refusal;
    final op = planned.operation;
    _preview = op == null ? null : OperationPreview(op);
    if (_preview != null) {
      // Counted steps, spread over frames: done in about a second.
      _ticker = Timer.periodic(const Duration(milliseconds: 16), (_) {
        final p = _preview;
        if (p == null || p.advance(2000)) _ticker?.cancel();
        if (mounted) setState(() {});
      });
    }
  }

  void _launch() {
    widget.onLaunch(LaunchOperationCommand(
      const PlayerId('player'),
      0,
      targetColonyId: _target.colonyId,
      draws: [for (final d in _draws) (colonyId: d.colonyId, siteId: d.siteId, count: d.count)],
      kitDays: _kitDays,
      garrison: _garrison,
    ));
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final readyAnywhere = _sources.any((s) => s.sources.any((t) => t.ready));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Retake the spaceport by force', style: AppTheme.heading),
              const SizedBox(height: 4),
              Text(
                  'Rebels hold ${widget.target.name}\'s spaceport. Troopers from your '
                  'other colonies can take it back.',
                  style: AppTheme.dim),
              const SizedBox(height: 12),
              if (_sources.isEmpty || !readyAnywhere) _noSources(),
              for (final s in _sources) ..._sourceRows(s),
              if (_total > 0) ...[
                _sliderRow('Days of supplies', '${_kitDays.round()}', _kitDays, 1, 6, 5,
                    (v) => setState(() {
                          _kitDays = v.roundToDouble();
                          _replan();
                        })),
                _sliderRow(
                    'Garrison to hold the port', '$_garrison', _garrison.toDouble(), 0,
                    _total.toDouble(), _total, (v) {
                  setState(() {
                    _garrison = v.round();
                    _replan();
                  });
                }),
              ],
              const SizedBox(height: 8),
              _previewBox(),
              const SizedBox(height: 12),
              ..._costs(),
              const SizedBox(height: 12),
              Row(children: [
                const Spacer(),
                TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('planner-launch'),
                  onPressed: _refusal == null && _total > 0 ? _launch : null,
                  child: Text(_total > 0 ? 'Launch ($_total troopers)' : 'Launch'),
                ),
              ]),
              if (_refusal != null && _total > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_refusal!, style: AppTheme.dim.copyWith(color: AppTheme.warn)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _noSources() => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          _sources.isEmpty
              ? 'No other colony of yours can send troopers. Troopers come from a '
                  'Barracks or Military Base in another colony, supplied with '
                  'rations, guns and ammo — which cannot be shipped in, so that '
                  'colony needs its own Arms Factory and Rations Plant.'
              : 'None of your barracks can send troopers right now (see each one '
                  'below).',
          style: AppTheme.dim.copyWith(color: AppTheme.warn),
        ),
      );

  List<Widget> _sourceRows(SourceSnapshot s) => [
        Text(s.name, style: AppTheme.body.copyWith(fontWeight: FontWeight.w600)),
        if (s.sources.isEmpty)
          Text('No barracks or military base.', style: AppTheme.dim),
        for (final t in s.sources)
          if (!t.ready)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                  '${t.type == 'base' ? 'Military Base' : 'Barracks'}: '
                  '${t.notReadyWhy ?? 'not ready'}',
                  style: AppTheme.dim),
            )
          else
            _sliderRow(
              t.type == 'base' ? 'Military Base' : 'Barracks',
              '${_counts[_key(s.colonyId, t.siteId)] ?? 0} of ${t.available}',
              (_counts[_key(s.colonyId, t.siteId)] ?? 0).toDouble(),
              0,
              t.available.toDouble(),
              t.available,
              (v) => setState(() {
                _counts[_key(s.colonyId, t.siteId)] = v.round();
                if (_garrison > _total) _garrison = _total;
                _replan();
              }),
            ),
        const SizedBox(height: 6),
      ];

  Widget _sliderRow(String label, String value, double v, double min, double max,
          int divisions, ValueChanged<double> onChanged) =>
      Row(children: [
        SizedBox(width: 170, child: Text(label, style: AppTheme.body)),
        Expanded(
          child: max <= min
              ? const SizedBox.shrink()
              : Slider(
                  value: v.clamp(min, max),
                  min: min,
                  max: max,
                  divisions: divisions < 1 ? 1 : divisions,
                  onChanged: onChanged,
                ),
        ),
        SizedBox(width: 64, child: Text(value, style: AppTheme.mono, textAlign: TextAlign.right)),
      ]);

  Widget _previewBox() {
    final p = _preview;
    if (p == null) {
      return Text('Choose troopers to see the likely outcome.', style: AppTheme.dim);
    }
    final n = p.results.length;
    const shown = [
      (OutcomeBand.decisiveVictory, 'Decisive victory'),
      (OutcomeBand.closeVictory, 'Close victory'),
      (OutcomeBand.pyrrhicVictory, 'Pyrrhic victory'),
      (OutcomeBand.valiantDefeat, 'Valiant defeat'),
      (OutcomeBand.closeDefeat, 'Close defeat'),
      (OutcomeBand.decisiveDefeat, 'Decisive defeat'),
      (OutcomeBand.none, 'No decision'),
    ];
    return Container(
      key: const Key('planner-preview'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppTheme.panelLight, borderRadius: BorderRadius.circular(6)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(n < p.runs ? 'Likely outcomes (${n * 100 ~/ p.runs}% worked out)' : 'Likely outcomes',
            style: AppTheme.body),
        const SizedBox(height: 6),
        for (final (band, label) in shown)
          if (p.countOf(band) > 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(children: [
                SizedBox(width: 130, child: Text(label, style: AppTheme.dim)),
                Expanded(
                  child: LinearProgressIndicator(
                    value: n == 0 ? 0 : p.countOf(band) / n,
                    minHeight: 6,
                    color: band.index <= OutcomeBand.pyrrhicVictory.index
                        ? AppTheme.accent2
                        : (band == OutcomeBand.none ? AppTheme.textDim : AppTheme.warn),
                    backgroundColor: AppTheme.panel,
                  ),
                ),
              ]),
            ),
        if (n > 0) ...[
          const SizedBox(height: 6),
          Text(
              'You lose ${p.quantile((r) => r.attackerLost, 0.1)}–'
              '${p.quantile((r) => r.attackerLost, 0.9)} troopers, killed or wounded; '
              'the rebels ${p.quantile((r) => r.defenderLost, 0.1)}–'
              '${p.quantile((r) => r.defenderLost, 0.9)}. Usually decided in about '
              '${(p.quantile((r) => r.seconds, 0.5) / 120).toStringAsFixed(1)} days.',
              style: AppTheme.dim),
        ],
      ]),
    );
  }

  List<Widget> _costs() => [
        for (final line in const [
          'Troopers are your colonists: the dead are lost to their home colony.',
          'Force wins no loyalty. Retaking the port costs some.',
          'Retaking the port reopens it: settlers who cannot be fed will leave. '
              'Only governing the colony ends the standoff.',
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('•  ', style: AppTheme.dim),
              Expanded(child: Text(line, style: AppTheme.dim)),
            ]),
          ),
      ];
}

/// Colonies that can send troopers against [target]: every other colony that
/// takes the player's orders (an independent one does not), in id order. One
/// without a barracks is still listed, so the planner can say what it lacks.
List<CitySim> forceSourcesFor(CitySim target, Iterable<CitySim> all) => [
      for (final c in all)
        if (c.id != target.id && c.loyalty.allegiance != Allegiance.independent) c,
    ]..sort((a, b) => a.id.compareTo(b.id));
