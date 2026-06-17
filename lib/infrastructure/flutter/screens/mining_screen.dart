import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../domain/mining/mining_rig.dart';
import '../../../domain/mining/resource_deposit.dart';
import '../../../domain/universe/celestial_body.dart';
import '../../../domain/vessel/resource_container.dart';
import 'app_theme.dart';

/// Mining operations: survey deposits, bind a [MiningRig] to one, and run the
/// real extraction tick — power drawn, ore extracted scaled by concentration,
/// reserves depleting, the target tank filling and overflowing. Live sim.
class MiningScreen extends StatefulWidget {
  const MiningScreen({super.key});

  @override
  State<MiningScreen> createState() => _MiningScreenState();
}

class _MiningScreenState extends State<MiningScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  final _deposits = <ResourceDeposit>[
    ResourceDeposit(
        id: 'ore-rich',
        body: const BodyId('moon'),
        latitude: 0.3,
        longitude: -0.8,
        resource: ResourceType.ore,
        concentration: 0.9,
        reserves: 5000),
    ResourceDeposit(
        id: 'ore-lean',
        body: const BodyId('moon'),
        latitude: -0.1,
        longitude: 1.2,
        resource: ResourceType.ore,
        concentration: 0.35,
        reserves: 12000),
    ResourceDeposit(
        id: 'water-ice',
        body: const BodyId('moon'),
        latitude: 1.4,
        longitude: 0.2,
        resource: ResourceType.water,
        concentration: 0.6,
        reserves: 8000),
  ];

  late ResourceDeposit _active = _deposits.first;
  final _rig = MiningRig(id: 'drill-1', baseRate: 3, powerDraw: 4);
  final _power = ResourceContainer(
      type: ResourceType.electricCharge,
      capacity: 1000,
      amount: 1000,
      unitMass: 0);
  late ResourceContainer _target = _tankFor(_active.resource);
  double _totalMined = 0;
  double _timeWarp = 5;

  ResourceContainer _tankFor(ResourceType t) =>
      ResourceContainer(type: t, capacity: 2000, amount: 0, unitMass: 1);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6) * _timeWarp;
    _last = elapsed;
    if (!_rig.active) return;
    // Trickle power back so it doesn't instantly brown out (a generator).
    _power.fill(2.0 * dt);
    final mined = _rig.mine(
      deposit: _active,
      target: _target,
      powerSource: _power,
      dt: dt,
    );
    if (mined > 0 || _rig.active) setState(() => _totalMined += mined);
  }

  void _select(ResourceDeposit d) => setState(() {
        _active = d;
        _target = _tankFor(d.resource);
        _totalMined = 0;
      });

  @override
  Widget build(BuildContext context) {
    return AppTheme.scaffold(
      context: context,
      title: 'MINING',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _panel('DEPOSITS (survey)', [
            for (final d in _deposits) _depositRow(d),
          ]),
          _panel('EXTRACTION', [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _rig.active ? 'Drill RUNNING' : 'Drill idle',
                    style: AppTheme.body.copyWith(
                        color:
                            _rig.active ? AppTheme.accent2 : AppTheme.textDim),
                  ),
                ),
                Switch(
                  value: _rig.active,
                  activeThumbColor: AppTheme.accent2,
                  onChanged: (v) => setState(() => _rig.active = v),
                ),
              ],
            ),
            _slider('Time warp', _timeWarp, 1, 50,
                (v) => setState(() => _timeWarp = v), suffix: '×'),
            const SizedBox(height: 8),
            _bar('Target tank (${_active.resource.name})', _target.fraction,
                '${_target.amount.toStringAsFixed(0)} / ${_target.capacity.toStringAsFixed(0)}',
                AppTheme.accent2),
            _bar('Power', _power.fraction,
                '${_power.amount.toStringAsFixed(0)} / ${_power.capacity.toStringAsFixed(0)}',
                _power.fraction > 0.1 ? AppTheme.accent : AppTheme.danger),
            const SizedBox(height: 6),
            _kv('Extracted this run', '${_totalMined.toStringAsFixed(1)} units'),
            _kv('Active concentration',
                '${(_active.concentration * 100).toStringAsFixed(0)}%'),
            _kv('Effective rate',
                '${(_rig.baseRate * _active.concentration).toStringAsFixed(2)} u/s'),
            _kv('Reserves left',
                _active.reserves == null
                    ? '∞'
                    : '${_active.reserves!.toStringAsFixed(0)} units'),
            if (_active.isDepleted)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Deposit depleted.',
                    style: AppTheme.body.copyWith(color: AppTheme.danger)),
              ),
          ]),
        ],
      ),
    );
  }

  Widget _depositRow(ResourceDeposit d) {
    final sel = identical(d, _active);
    final pct = d.concentration;
    return Card(
      color: sel ? AppTheme.accent.withValues(alpha: 0.14) : AppTheme.panel,
      margin: const EdgeInsets.symmetric(vertical: 3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
            color: sel ? AppTheme.accent : const Color(0xFF223247)),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(
            d.resource == ResourceType.water ? Icons.water_drop : Icons.diamond,
            color: d.resource == ResourceType.water
                ? AppTheme.accent
                : AppTheme.warn),
        title: Text('${d.id}  ·  ${d.resource.name}', style: AppTheme.body),
        subtitle: Text(
            'conc ${(pct * 100).toStringAsFixed(0)}%  ·  '
            'reserves ${d.reserves?.toStringAsFixed(0) ?? "∞"}  ·  '
            'lat ${(d.latitude * 57.3).toStringAsFixed(0)}° lon ${(d.longitude * 57.3).toStringAsFixed(0)}°',
            style: AppTheme.dim),
        trailing: sel
            ? const Icon(Icons.check_circle, color: AppTheme.accent, size: 18)
            : null,
        onTap: () => _select(d),
      ),
    );
  }

  Widget _bar(String label, double value, String text, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(label, style: AppTheme.body)),
              Text(text, style: AppTheme.mono.copyWith(color: color)),
            ]),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: value.clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: AppTheme.panelLight,
                color: color,
              ),
            ),
          ],
        ),
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
          ValueChanged<double> onChanged,
          {String suffix = ''}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(label, style: AppTheme.body)),
              Text('${value.toStringAsFixed(1)} $suffix',
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
                  value: value.clamp(min, max),
                  min: min,
                  max: max,
                  onChanged: onChanged),
            ),
          ],
        ),
      );
}
