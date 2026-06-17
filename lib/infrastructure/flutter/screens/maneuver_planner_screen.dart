import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/autonomy/flight_plan.dart';
import '../../../domain/autonomy/maneuver_planner.dart';
import '../../../domain/simulation/epoch.dart';
import '../../../domain/universe/celestial_body.dart';
import '../../../domain/universe/real_solar_system.dart';
import 'app_theme.dart';

/// Interactive maneuver planning. Pick a body, set the start + target orbit
/// altitudes and an optional plane change, and the [ManeuverPlanner] computes
/// the real delta-v budget (Hohmann + circularize + plane change). Bound to the
/// same domain service the autopilot executes.
class ManeuverPlannerScreen extends StatefulWidget {
  const ManeuverPlannerScreen({super.key});

  @override
  State<ManeuverPlannerScreen> createState() => _ManeuverPlannerScreenState();
}

class _ManeuverPlannerScreenState extends State<ManeuverPlannerScreen> {
  static const _planner = ManeuverPlanner();
  late final List<CelestialBody> _bodies;
  late CelestialBody _body;

  double _fromAltKm = 300;
  double _toAltKm = 35786; // GEO-ish for Earth
  double _planeDeg = 0;
  // A nominal delta-v budget the craft "has", for the feasibility readout.
  double _availableDv = 4000;

  @override
  void initState() {
    super.initState();
    final system = RealSolarSystem.build();
    _bodies = system.all.where((b) => !b.isStar).toList()
      ..sort((a, b) => a.radius.compareTo(b.radius));
    _body = _bodies.firstWhere((b) => b.id.value == 'earth',
        orElse: () => _bodies.first);
  }

  List<ManeuverNode> get _nodes {
    final r1 = _body.radius + _fromAltKm * 1000;
    final r2 = _body.radius + _toAltKm * 1000;
    final incl = _planeDeg * math.pi / 180;
    if (incl.abs() < 1e-6) {
      return _planner.hohmann(
          mu: _body.mu, fromRadius: r1, toRadius: r2, startEpoch: Epoch.zero);
    }
    return _planner.hohmannWithPlaneChange(
      mu: _body.mu,
      fromRadius: r1,
      toRadius: r2,
      inclinationChange: incl,
      startEpoch: Epoch.zero,
    );
  }

  @override
  Widget build(BuildContext context) {
    final nodes = _nodes;
    final totalDv = nodes.fold(0.0, (s, n) => s + n.magnitude);
    final feasible = totalDv <= _availableDv;
    return AppTheme.scaffold(
      context: context,
      title: 'MANEUVER PLANNER',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _panel('TRANSFER', [
            _bodyPicker(),
            const SizedBox(height: 8),
            _slider('Start orbit altitude', _fromAltKm, 100, 40000,
                (v) => setState(() => _fromAltKm = v), suffix: 'km'),
            _slider('Target orbit altitude', _toAltKm, 100, 400000,
                (v) => setState(() => _toAltKm = v), suffix: 'km'),
            _slider('Plane change', _planeDeg, 0, 90,
                (v) => setState(() => _planeDeg = v), suffix: '°'),
            _slider('Available Δv', _availableDv, 0, 12000,
                (v) => setState(() => _availableDv = v), suffix: 'm/s'),
          ]),
          _panel('BURN SCHEDULE', [
            for (var i = 0; i < nodes.length; i++) _burnRow(i, nodes[i]),
            const Divider(color: Color(0xFF223247)),
            Row(
              children: [
                const Text('TOTAL Δv', style: AppTheme.heading),
                const Spacer(),
                Text('${totalDv.toStringAsFixed(1)} m/s',
                    style: AppTheme.mono.copyWith(
                        color: AppTheme.accent2,
                        fontSize: 15,
                        fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: (feasible ? AppTheme.accent2 : AppTheme.danger)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(feasible ? Icons.check_circle : Icons.error,
                      color: feasible ? AppTheme.accent2 : AppTheme.danger,
                      size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      feasible
                          ? 'Within Δv budget — margin ${(_availableDv - totalDv).toStringAsFixed(0)} m/s.'
                          : 'Insufficient Δv — short ${(totalDv - _availableDv).toStringAsFixed(0)} m/s.',
                      style: AppTheme.body.copyWith(
                          color: feasible ? AppTheme.accent2 : AppTheme.danger),
                    ),
                  ),
                ],
              ),
            ),
          ]),
          _panel('ORBIT GEOMETRY', [
            _kv('Body μ', '${_body.mu.toStringAsExponential(3)} m³/s²'),
            _kv('Periapsis radius',
                '${((_body.radius + _fromAltKm * 1000) / 1000).toStringAsFixed(0)} km'),
            _kv('Apoapsis radius',
                '${((_body.radius + _toAltKm * 1000) / 1000).toStringAsFixed(0)} km'),
            _kv('Transfer time',
                _fmtDuration(nodes.length >= 2
                    ? nodes[1].executeAt.seconds - nodes[0].executeAt.seconds
                    : 0)),
          ]),
        ],
      ),
    );
  }

  Widget _burnRow(int i, ManeuverNode n) {
    final dir = n.deltaV.x.abs() > n.deltaV.y.abs()
        ? (n.deltaV.x >= 0 ? 'prograde' : 'retrograde')
        : (n.deltaV.y >= 0 ? 'normal +' : 'normal −');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text('${i + 1}',
                style: AppTheme.mono.copyWith(color: AppTheme.accent)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Burn ${i + 1} — $dir', style: AppTheme.body),
                Text('t+${_fmtDuration(n.executeAt.seconds)}',
                    style: AppTheme.dim),
              ],
            ),
          ),
          Text('${n.magnitude.toStringAsFixed(1)} m/s',
              style: AppTheme.mono.copyWith(color: AppTheme.accent)),
        ],
      ),
    );
  }

  Widget _bodyPicker() => Row(
        children: [
          const SizedBox(width: 90, child: Text('Body', style: AppTheme.body)),
          Expanded(
            child: DropdownButton<CelestialBody>(
              value: _body,
              isExpanded: true,
              dropdownColor: AppTheme.panelLight,
              underline: Container(height: 1, color: AppTheme.accent),
              items: [
                for (final b in _bodies)
                  DropdownMenuItem(
                      value: b,
                      child: Text(b.name, style: AppTheme.body)),
              ],
              onChanged: (b) => setState(() => _body = b!),
            ),
          ),
        ],
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
        child: Row(
          children: [
            Expanded(child: Text(k, style: AppTheme.dim)),
            Text(v, style: AppTheme.mono),
          ],
        ),
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
              Text('${value.toStringAsFixed(0)} $suffix',
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

  String _fmtDuration(double s) {
    if (s <= 0) return '0s';
    final d = s ~/ 86400;
    final h = (s % 86400) ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = (s % 60).floor();
    if (d > 0) return '${d}d ${h}h ${m}m';
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${sec}s';
    return '${sec}s';
  }
}
