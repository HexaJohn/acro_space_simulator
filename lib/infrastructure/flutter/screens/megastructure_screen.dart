import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../domain/megastructure/megastructure.dart';
import '../../../domain/megastructure/megastructure_construction.dart';
import 'app_theme.dart';

/// Megastructure construction director. Pick a project (real [Megastructure]
/// factory with escalating phases), then DELIVER material (cargo runs) and
/// ENERGY (on-site power) into the build site; the [MegastructureConstruction]
/// service pours buffers into the current phase each tick and reports milestones.
class MegastructureScreen extends StatefulWidget {
  const MegastructureScreen({super.key});

  @override
  State<MegastructureScreen> createState() => _MegastructureScreenState();
}

class _MegastructureScreenState extends State<MegastructureScreen>
    with SingleTickerProviderStateMixin {
  static const _builder = MegastructureConstruction();

  late final Ticker _ticker;
  Duration _last = Duration.zero;

  late Megastructure _struct;
  _Project _project = _projects.first;
  final List<String> _log = [];
  // Auto-delivery rates (per second) the player dials in — a logistics throttle.
  double _materialRate = 0;
  double _energyRate = 0;
  bool _autoSupply = false;

  @override
  void initState() {
    super.initState();
    _struct = _project.build();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (_struct.isComplete) return;
    if (_autoSupply) {
      // Scale to phase magnitude so the demo completes in reasonable time.
      final phase = _struct.currentPhase;
      if (phase != null) {
        _struct.deliverMaterial(_materialRate * phase.requiredMass * dt);
        _struct.deliverEnergy(_energyRate * phase.requiredEnergy * dt);
      }
    }
    final events = _builder.advance(_struct, dt: dt);
    if (events.isNotEmpty) {
      setState(() => _log.insertAll(0, events.reversed));
    } else {
      setState(() {});
    }
  }

  void _select(_Project p) => setState(() {
        _project = p;
        _struct = p.build();
        _log.clear();
      });

  void _deliver({double mass = 0, double energy = 0}) {
    final phase = _struct.currentPhase;
    if (phase == null) return;
    if (mass > 0) _struct.deliverMaterial(phase.requiredMass * mass);
    if (energy > 0) _struct.deliverEnergy(phase.requiredEnergy * energy);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return AppTheme.scaffold(
      context: context,
      title: 'MEGASTRUCTURES',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _panel('PROJECT', [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final p in _projects)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(p.label,
                          style: TextStyle(
                              fontSize: 11,
                              color: _project.label == p.label
                                  ? AppTheme.bg
                                  : AppTheme.text)),
                      selected: _project.label == p.label,
                      selectedColor: AppTheme.accent,
                      backgroundColor: AppTheme.panelLight,
                      onSelected: (_) => _select(p),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 10),
            _overallBar(),
          ]),
          _panel('PHASES', [
            for (var i = 0; i < _struct.phases.length; i++)
              _phaseRow(i, _struct.phases[i]),
          ]),
          _panel('LOGISTICS', [
            Text('On-site buffers', style: AppTheme.dim),
            const SizedBox(height: 4),
            _kv('Material', '${_fmt(_struct.siteMaterial)} kg'),
            _kv('Energy', '${_fmt(_struct.siteEnergy)} J'),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _btn('Cargo +10%', Icons.local_shipping,
                  () => _deliver(mass: 0.10)),
              _btn('Cargo +25%', Icons.local_shipping,
                  () => _deliver(mass: 0.25)),
              _btn('Power +10%', Icons.bolt, () => _deliver(energy: 0.10)),
              _btn('Power +25%', Icons.bolt, () => _deliver(energy: 0.25)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                  child: Text('Auto-supply convoy', style: AppTheme.body)),
              Switch(
                value: _autoSupply,
                activeThumbColor: AppTheme.accent2,
                onChanged: (v) => setState(() {
                  _autoSupply = v;
                  if (v && _materialRate == 0) _materialRate = 0.05;
                  if (v && _energyRate == 0) _energyRate = 0.05;
                }),
              ),
            ]),
            if (_autoSupply) ...[
              _slider('Material throughput', _materialRate, 0, 0.3,
                  (v) => setState(() => _materialRate = v)),
              _slider('Energy throughput', _energyRate, 0, 0.3,
                  (v) => setState(() => _energyRate = v)),
            ],
          ]),
          if (_struct.operational)
            _panel('OPERATIONAL OUTPUT', [
              if (_struct.currentPowerOutput > 0)
                _kv('Power output',
                    '${_fmt(_struct.currentPowerOutput)} W'),
              if (_struct.currentHabitableArea > 0) ...[
                _kv('Habitable area',
                    '${_fmt(_struct.currentHabitableArea)} m²'),
                _kv('Population capacity',
                    '${_struct.populationCapacity}'),
              ],
            ]),
          _panel('MILESTONE LOG', [
            if (_log.isEmpty)
              Text('Deliver material + energy to begin.', style: AppTheme.dim),
            for (final l in _log.take(12))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  const Icon(Icons.check, color: AppTheme.accent2, size: 14),
                  const SizedBox(width: 6),
                  Expanded(child: Text(l, style: AppTheme.dim)),
                ]),
              ),
          ]),
        ],
      ),
    );
  }

  Widget _overallBar() {
    final p = _struct.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
              child: Text('Overall progress', style: AppTheme.body)),
          Text('${(p * 100).toStringAsFixed(1)}%',
              style: AppTheme.mono.copyWith(
                  color: _struct.isComplete
                      ? AppTheme.accent2
                      : AppTheme.accent)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: p,
            minHeight: 10,
            backgroundColor: AppTheme.panelLight,
            color: _struct.isComplete ? AppTheme.accent2 : AppTheme.accent,
          ),
        ),
        const SizedBox(height: 4),
        Text(
            _struct.isComplete
                ? 'COMPLETE — operational.'
                : '${_struct.completedPhases}/${_struct.phases.length} phases complete',
            style: AppTheme.dim),
      ],
    );
  }

  Widget _phaseRow(int i, BuildPhase phase) {
    final done = phase.isComplete;
    final current = !done && _struct.currentPhase == phase;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(
                done
                    ? Icons.check_circle
                    : current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                size: 16,
                color: done
                    ? AppTheme.accent2
                    : current
                        ? AppTheme.accent
                        : AppTheme.textDim),
            const SizedBox(width: 8),
            Expanded(child: Text(phase.name, style: AppTheme.body)),
            Text('${(phase.fraction * 100).toStringAsFixed(0)}%',
                style: AppTheme.mono.copyWith(
                    color: done ? AppTheme.accent2 : AppTheme.textDim)),
          ]),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: phase.fraction,
              minHeight: 5,
              backgroundColor: AppTheme.panelLight,
              color: done ? AppTheme.accent2 : AppTheme.accent,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
                'mass ${_fmt(phase.contributedMass)}/${_fmt(phase.requiredMass)} kg  ·  '
                'energy ${_fmt(phase.contributedEnergy)}/${_fmt(phase.requiredEnergy)} J',
                style: AppTheme.dim),
          ),
        ],
      ),
    );
  }

  Widget _btn(String label, IconData icon, VoidCallback onTap) =>
      ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.panelLight,
          foregroundColor: AppTheme.accent,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        onPressed: _struct.isComplete ? null : onTap,
      );

  Widget _panel(String title, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(14),
        decoration: AppTheme.panelBox(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AppTheme.heading),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(k, style: AppTheme.dim)),
          Text(v, style: AppTheme.mono),
        ]),
      );

  Widget _slider(String label, double value, double min, double max,
          ValueChanged<double> onChanged) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(label, style: AppTheme.body)),
              Text('${(value * 100).toStringAsFixed(0)}%/s',
                  style: AppTheme.mono.copyWith(color: AppTheme.accent)),
            ]),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: AppTheme.accent,
                thumbColor: AppTheme.accent,
                inactiveTrackColor: AppTheme.panelLight,
                trackHeight: 3,
              ),
              child: Slider(
                  value: value, min: min, max: max, onChanged: onChanged),
            ),
          ],
        ),
      );

  static String _fmt(double v) {
    if (v >= 1e15) return '${(v / 1e15).toStringAsFixed(2)}P';
    if (v >= 1e12) return '${(v / 1e12).toStringAsFixed(2)}T';
    if (v >= 1e9) return '${(v / 1e9).toStringAsFixed(2)}G';
    if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';
    if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(2)}k';
    return v.toStringAsFixed(0);
  }
}

class _Project {
  final String label;
  final Megastructure Function() build;
  const _Project(this.label, this.build);
}

final _projects = <_Project>[
  _Project('Halo Ring',
      () => Megastructure.haloRing(id: 'halo', radius: 5.0e6)),
  _Project('Orbital Ring',
      () => Megastructure.orbitalRing(id: 'oring', radius: 6.6e6)),
  _Project(
      "O'Neill Cylinder",
      () => Megastructure.oNeillCylinder(
          id: 'oneill', radius: 3.2e3, length: 3.2e4)),
  _Project(
      'Dyson Swarm',
      () => Megastructure.dysonSwarm(
          id: 'swarm', starLuminosity: 3.828e26)),
  _Project(
      'Dyson Sphere',
      () => Megastructure.dysonSphere(
          id: 'sphere', starRadius: 6.96e8, starLuminosity: 3.828e26)),
  _Project('Ringworld',
      () => Megastructure.ringworld(id: 'ring', starLuminosity: 3.828e26)),
];
