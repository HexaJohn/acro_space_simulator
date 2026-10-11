// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The force planner (docs/plans/combat.md §7.9, §7A): retaking a seized
/// spaceport, or taking an independent colony and holding it.
///
/// It shows what the player can send and from where, and what it will likely
/// cost — a spread of outcomes from the same resolver the battle runs, never
/// one promised answer — and says plainly what force does not do. Launch only
/// enqueues a command: the world applies it at the next tick.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../domain/colony/city/city_loyalty.dart';
import '../../../../domain/colony/city/city_sim.dart';
import '../../../../domain/colony/city/city_war.dart';
import '../../../../domain/combat/base/base_modules.dart';
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
  Roe _roe = Roe.restrained;

  /// The forward base (combat.md §7C): on by default where a source can
  /// ship one; off is a light operation.
  bool _base = true;
  int _baseMateriel = 300;
  int _baseSupport = 10;
  int _baseFuel = 24, _baseMedicine = 10, _baseSteel = 0, _baseElectronics = 0;
  bool _spareCore = false;
  Doctrine _doctrine = Doctrine.balanced;

  BaseManifest? get _manifest => _base
      ? BaseManifest(
          materiel: _baseMateriel,
          support: _baseSupport,
          fuel: _baseFuel,
          medicine: _baseMedicine,
          steel: _baseSteel,
          electronics: _baseElectronics,
          spareCore: _spareCore,
          doctrine: _doctrine,
        )
      : null;

  /// The most of [good] any source has, whole units.
  int _richest(String good) {
    var v = 0.0;
    for (final s in _sources) {
      v = math.max(v, s.stock[good] ?? 0);
    }
    return v.floor();
  }

  /// An independent colony: taken and occupied, not a port retaken.
  bool get _assault => _target.independent;

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
    // An assault fights over two objectives or more: three days of kit is
    // one port's worth.
    if (_assault) _kitDays = 6;
    _garrison = _defaultGarrison();
    // Size the base to what the richest source can give.
    var ore = 0.0, support = 0;
    for (final s in _sources) {
      ore = math.max(ore, s.stock['ore'] ?? 0);
      support = math.max(support, s.supportAvailable);
    }
    _baseMateriel = math.min(300, (ore ~/ 50) * 50);
    _baseSupport = math.min(10, support);
    _base = _baseMateriel >= 50 && _baseSupport >= 2;
    _baseFuel = math.min(24, _richest('fuel'));
    _baseMedicine = math.min(10, _richest('medicine'));
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
    // A port: a few to hold the pads. A colony: enough to sit on all of it,
    // full suppression at 4% of its people (city_occupation.dart).
    final share = _assault ? 0.04 : 0.01;
    final want = (_target.population * share).ceil().clamp(2, 1 << 20);
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
    final planned = _assault
        ? planColonyAssault(
            operationId: widget.registry.nextOperationId,
            target: _target,
            sources: _sources,
            draws: _draws,
            kitDays: _kitDays,
            garrison: _garrison,
            roe: _roe,
            base: _manifest,
          )
        : planPortRetake(
            operationId: widget.registry.nextOperationId,
            target: _target,
            sources: _sources,
            draws: _draws,
            kitDays: _kitDays,
            garrison: _garrison,
            base: _manifest,
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
      roe: _roe.name,
      baseMateriel: _base ? _baseMateriel : 0,
      baseSupport: _base ? _baseSupport : 0,
      baseFuel: _base ? _baseFuel : null,
      baseMedicine: _base ? _baseMedicine : null,
      baseSteel: _base ? _baseSteel : null,
      baseElectronics: _base ? _baseElectronics : null,
      baseSpareCore: _base && _spareCore,
      baseDoctrine: _base ? _doctrine.name : null,
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
              Text(_assault ? 'Take ${widget.target.name} by force' : 'Retake the spaceport by force',
                  style: AppTheme.heading),
              const SizedBox(height: 4),
              Text(
                  _assault
                      ? '${widget.target.name} is independent and takes no orders. '
                          'Troopers from your other colonies can take its seat, and '
                          'whatever stands in the way.'
                      : 'Rebels hold ${widget.target.name}\'s spaceport. Troopers from your '
                          'other colonies can take it back.',
                  style: AppTheme.dim),
              const SizedBox(height: 12),
              if (_sources.isEmpty || !readyAnywhere) _noSources(),
              for (final s in _sources) ..._sourceRows(s),
              if (_total > 0) ...[
                _sliderRow('Days of supplies', '${_kitDays.round()}', _kitDays, 1, 10, 9,
                    (v) => setState(() {
                          _kitDays = v.roundToDouble();
                          _replan();
                        })),
                _sliderRow(
                    _assault ? 'Garrison to hold the colony' : 'Garrison to hold the port',
                    '$_garrison',
                    _garrison.toDouble(),
                    _assault ? 1 : 0,
                    _total.toDouble(),
                    _assault ? _total - 1 : _total, (v) {
                  setState(() {
                    _garrison = v.round();
                    _replan();
                  });
                }),
                if (_assault) _roeRow(),
                const SizedBox(height: 4),
                _baseSection(),
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

  Widget _baseSection() {
    var ore = 0.0, support = 0;
    for (final s in _sources) {
      ore = math.max(ore, s.stock['ore'] ?? 0);
      support = math.max(support, s.supportAvailable);
    }
    final maxM = math.max(50, math.min(800, (ore ~/ 50) * 50));
    final maxS = math.max(2, math.min(24, support));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const SizedBox(width: 170, child: Text('Forward base', style: AppTheme.body)),
        Switch(
          key: const Key('planner-base'),
          value: _base,
          onChanged: (v) => setState(() {
            _base = v;
            _replan();
          }),
        ),
        Expanded(
          child: Text(
              _base
                  ? 'A core, a landing turret and Materiel to build with.'
                  : 'A light operation: no base, nothing to build.',
              style: AppTheme.dim),
        ),
      ]),
      if (_base) ...[
        _sliderRow('Materiel (ore)', '$_baseMateriel', _baseMateriel.toDouble(), 50,
            maxM.toDouble(), (maxM - 50) ~/ 50, (v) {
          setState(() {
            _baseMateriel = (v / 50).round() * 50;
            _replan();
          });
        }),
        _sliderRow('Support staff', '$_baseSupport', _baseSupport.toDouble(), 2, maxS.toDouble(),
            maxS - 2, (v) {
          setState(() {
            _baseSupport = v.round();
            _replan();
          });
        }),
        for (final (label, good, max, get, set) in <(String, String, int, int, void Function(int))>[
          ('Fuel', 'fuel', 60, _baseFuel, (v) => _baseFuel = v),
          ('Medicine', 'medicine', 40, _baseMedicine, (v) => _baseMedicine = v),
          ('Steel', 'steel', 80, _baseSteel, (v) => _baseSteel = v),
          ('Electronics', 'electronics', 30, _baseElectronics, (v) => _baseElectronics = v),
        ])
          if (math.min(max, _richest(good)) > 0)
            _sliderRow(label, '$get', get.toDouble(), 0, math.min(max, _richest(good)).toDouble(),
                math.min(max, _richest(good)), (v) {
              setState(() {
                set(v.round());
                _replan();
              });
            }),
        Row(children: [
          const SizedBox(width: 170, child: Text('Spare core', style: AppTheme.body)),
          Switch(
            key: const Key('planner-spare-core'),
            value: _spareCore,
            onChanged: (v) => setState(() {
              _spareCore = v;
              _replan();
            }),
          ),
          Expanded(
            child: Text('$kSpareCoreMateriel ore more: a second core to land if the first is lost.',
                style: AppTheme.dim),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            const SizedBox(width: 170, child: Text('Builds', style: AppTheme.body)),
            Expanded(
              child: Wrap(spacing: 6, children: [
                for (final d in Doctrine.values)
                  ChoiceChip(
                    key: Key('planner-doctrine-${d.name}'),
                    label: Text(doctrineLabel(d)),
                    selected: _doctrine == d,
                    onSelected: (_) => setState(() {
                      _doctrine = d;
                      _replan();
                    }),
                  ),
              ]),
            ),
          ]),
        ),
      ],
    ]);
  }

  Widget _roeRow() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          const SizedBox(width: 170, child: Text('Rules of engagement', style: AppTheme.body)),
          Expanded(
            child: Wrap(spacing: 6, children: [
              for (final (roe, label) in const [
                (Roe.restrained, 'Restrained'),
                (Roe.standard, 'Standard'),
              ])
                ChoiceChip(
                  key: Key('planner-roe-${roe.name}'),
                  label: Text(label),
                  selected: _roe == roe,
                  onSelected: (_) => setState(() {
                    _roe = roe;
                    _replan();
                  }),
                ),
            ]),
          ),
        ]),
      );

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
              'You lose ${_span(p, (r) => r.attackerLost, 'no')} troopers, killed or wounded; '
              '${_assault ? 'its defenders' : 'the rebels'} ${_span(p, (r) => r.defenderLost, 'none')}. Usually decided in about '
              '${(p.quantile((r) => r.seconds, 0.5) / 120).toStringAsFixed(1)} days.',
              style: AppTheme.dim),
        ],
      ]),
    );
  }

  List<String> get _costLines => [
        ..._costLinesCore,
        if (_base)
          'The base ships $_baseMateriel ore and $_baseSupport support staff from your '
              'lead colony; what is left comes home with them. Overrun, half of it is '
              "the rebels'.",
      ];

  List<String> get _costLinesCore => _assault
      ? [
          'Troopers are your colonists: the dead are lost to their home colony.',
          'Its defenders are its colonists too: every one killed is a grievance it '
              'keeps.',
          'A win occupies it: it takes your orders under guard and must still be '
              'governed. Its charter comes back only when its loyalty does.',
          if (_roe == Roe.standard)
            'Standard rules of engagement hit harder, and kill townsfolk alongside '
                'its defenders — fewer where shelters hold them.',
        ]
      : const [
          'Troopers are your colonists: the dead are lost to their home colony.',
          'Force wins no loyalty. Retaking the port costs some.',
          'Retaking the port reopens it: settlers who cannot be fed will leave. '
              'Only governing the colony ends the standoff.',
        ];

  List<Widget> _costs() => [
        for (final line in _costLines)
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

/// "3–5", or "3" when the likely range is one number, or [none] when it is 0.
String _span(OperationPreview p, int Function(PreviewRun) of, String none) {
  final lo = p.quantile(of, 0.1), hi = p.quantile(of, 0.9);
  if (hi == 0) return none;
  return lo == hi ? '$lo' : '$lo–$hi';
}
