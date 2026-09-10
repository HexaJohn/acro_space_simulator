// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The city-builder mode's permanent HUD: the numbers a player steers by, and
/// the ladder they are climbing.
///
/// Deliberately a THIN read over [CitySim] — every value here is one the tick
/// already computes. The one thing it consumes rather than reads is
/// [CitySim.milestoneToasts], which it drains to raise a banner; the sim keeps
/// no reference back, so a headless run simply lets the queue grow.
///
/// Sits ABOVE the world and BESIDE the editor toolbar: the toolbar is bottom-
/// docked, this is top-docked, and neither has to know about the other.
library;

import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_building_spec.dart';
import '../../../domain/colony/city/city_progression.dart';
import '../../../domain/colony/city/city_sim.dart';
import 'app_theme.dart';

/// Which drawer is open under the top bar.
enum CityGamePanel { none, milestones, budget }

class CityGameHud extends StatefulWidget {
  const CityGameHud({
    super.key,
    required this.city,
    this.onExit,
    this.zonesOn = false,
    this.onToggleZones,
  });

  final CitySim city;

  /// Leave the mode (back to the menu). Null hides the button.
  final VoidCallback? onExit;

  /// Whether the zoning view is up, and how to flip it.
  ///
  /// Passed in rather than read from the renderer: the HUD is a screen, and a
  /// screen that reaches into the scene graph for a boolean is a screen that
  /// cannot be built in a test without one.
  final bool zonesOn;
  final VoidCallback? onToggleZones;

  @override
  State<CityGameHud> createState() => _CityGameHudState();
}

class _CityGameHudState extends State<CityGameHud> {
  CityGamePanel _panel = CityGamePanel.none;

  /// The milestone being celebrated, and when it was raised. One at a time — a
  /// colony that jumps two tiers shows them in turn rather than stacking
  /// banners over the view they are meant to be decorating.
  CityMilestoneAward? _banner;
  DateTime _bannerAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _bannerHold = Duration(seconds: 7);

  CitySim get city => widget.city;

  /// Take the next queued tier, if the banner is free.
  ///
  /// Called from a post-frame callback rather than from `build`: draining is a
  /// mutation of the sim, and a widget must not change the model it is in the
  /// middle of painting.
  void _drainToasts() {
    if (!mounted) return;
    final expired = DateTime.now().difference(_bannerAt) > _bannerHold;
    if (_banner != null && !expired) return;
    if (city.milestoneToasts.isEmpty) {
      if (_banner != null && expired) setState(() => _banner = null);
      return;
    }
    final award = city.milestoneToasts.removeAt(0);
    setState(() {
      _banner = award;
      _bannerAt = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    // The host rebuilds this every frame, so one callback per frame keeps the
    // banner queue moving without a ticker of its own.
    WidgetsBinding.instance.addPostFrameCallback((_) => _drainToasts());

    final narrow = MediaQuery.sizeOf(context).width < 900;
    return Stack(
      children: [
        Positioned(
          top: 8,
          left: 8,
          right: 8,
          child: Align(
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _topBar(narrow),
                if (_panel != CityGamePanel.none)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _drawer(),
                  ),
              ],
            ),
          ),
        ),
        if (_banner != null)
          Positioned(
            top: 96,
            left: 0,
            right: 0,
            child: IgnorePointer(child: Center(child: _bannerCard(_banner!))),
          ),
      ],
    );
  }

  // ---- Top bar -------------------------------------------------------------

  Widget _topBar(bool narrow) {
    final tier = CityProgression.reached(city.population);
    final next = CityProgression.next(city.population);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xEE0B1017),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF24313F)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _tierChip(tier, next),
          const SizedBox(width: 10),
          _stat(Icons.savings, '§', city.funds, rate: city.netFundsRate),
          _stat(Icons.hexagon_outlined, 'Ore', city.stockOf('ore')),
          _stat(Icons.groups, 'Pop', city.population, note: city.popTrend),
          if (!narrow) ...[
            _meterChip(
                'Mood',
                city.happiness,
                city.happiness > 0.6
                    ? AppTheme.accent2
                    : (city.happiness > 0.35
                        ? AppTheme.warn
                        : AppTheme.danger)),
            _powerChip(),
          ],
          const SizedBox(width: 6),
          _rciCluster(),
          const SizedBox(width: 6),
          if (widget.onToggleZones != null)
            _toggle(Icons.layers, 'Zones', widget.zonesOn,
                widget.onToggleZones!, 'Zoning view (Z)'),
          _panelButton(CityGamePanel.milestones, Icons.emoji_events, 'Goals'),
          _panelButton(CityGamePanel.budget, Icons.account_balance, 'Budget'),
          if (widget.onExit != null)
            IconButton(
              onPressed: widget.onExit,
              icon: const Icon(Icons.logout, size: 16),
              color: AppTheme.textDim,
              tooltip: 'Leave the colony',
            ),
        ]),
      ),
    );
  }

  /// Rank + progress toward the next rank. The one control that says "you are
  /// getting somewhere", so it opens the ladder when tapped.
  Widget _tierChip(CityMilestone tier, CityMilestone? next) {
    final frac = CityProgression.fractionToNext(city.population);
    return InkWell(
      onTap: () => setState(() => _panel = _panel == CityGamePanel.milestones
          ? CityGamePanel.none
          : CityGamePanel.milestones),
      child: SizedBox(
        width: 168,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tier.name.toUpperCase(),
                style: AppTheme.heading.copyWith(fontSize: 12)),
            const SizedBox(height: 3),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 4,
                backgroundColor: AppTheme.panelLight,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(AppTheme.accent2),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              next == null
                  ? 'the ladder is climbed'
                  : '${city.population.round()} / ${next.population} to ${next.name}',
              style: AppTheme.dim.copyWith(fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(IconData icon, String label, double value,
      {double? rate, String? note}) {
    final rateColor = rate == null
        ? AppTheme.textDim
        : (rate >= 0 ? AppTheme.accent2 : AppTheme.warn);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: AppTheme.textDim),
        const SizedBox(width: 4),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$label ${_compact(value)}',
                style: AppTheme.mono.copyWith(fontSize: 12)),
            if (rate != null)
              Text('${rate >= 0 ? '+' : ''}${rate.toStringAsFixed(2)}/s',
                  style: AppTheme.dim.copyWith(fontSize: 9, color: rateColor)),
            if (note != null)
              Text(note, style: AppTheme.dim.copyWith(fontSize: 9)),
          ],
        ),
      ]),
    );
  }

  Widget _meterChip(String label, double value, Color color) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$label ${(value * 100).round()}%',
                style: AppTheme.mono.copyWith(fontSize: 12, color: color)),
            const SizedBox(height: 3),
            SizedBox(
              width: 54,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: value.clamp(0.0, 1.0),
                  minHeight: 3,
                  backgroundColor: AppTheme.panelLight,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
            ),
          ],
        ),
      );

  /// Power as a supply/draw pair — the readout that explains a city which has
  /// stopped producing, and the first thing a new player builds wrong.
  Widget _powerChip() {
    final draw = city.powerDraw;
    final out = city.powerOut;
    final short = draw > out + 0.01;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.bolt,
            size: 14, color: short ? AppTheme.danger : AppTheme.accent2),
        const SizedBox(width: 3),
        Text('${out.round()}/${draw.round()}',
            style: AppTheme.mono.copyWith(
                fontSize: 12,
                color: short ? AppTheme.danger : AppTheme.text)),
      ]),
    );
  }

  /// The demand the zones are actually growing against.
  Widget _rciCluster() => Row(mainAxisSize: MainAxisSize.min, children: [
        _rciBar('R', city.resTarget, AppTheme.accent2),
        _rciBar('C', city.comTarget, AppTheme.accent),
        _rciBar('I', city.indTarget, const Color(0xFFE3A857)),
      ]);

  Widget _rciBar(String label, double value, Color color) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            height: 26,
            width: 10,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                heightFactor: value.clamp(0.05, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
          Text(label, style: AppTheme.dim.copyWith(fontSize: 9, color: color)),
        ]),
      );

  /// A plain on/off chip, styled like the panel buttons beside it.
  Widget _toggle(IconData icon, String label, bool on, VoidCallback onTap,
          String tooltip) =>
      Tooltip(
        message: tooltip,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: on ? AppTheme.accent2.withValues(alpha: 0.18) : null,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                    color: on ? AppTheme.accent2 : const Color(0xFF2A3948)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon,
                    size: 14, color: on ? AppTheme.accent2 : AppTheme.textDim),
                const SizedBox(width: 5),
                Text(label,
                    style: TextStyle(
                        fontSize: 11,
                        color: on ? AppTheme.accent2 : AppTheme.textDim)),
              ]),
            ),
          ),
        ),
      );

  Widget _panelButton(CityGamePanel panel, IconData icon, String label) {
    final on = _panel == panel;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: () => setState(() => _panel = on ? CityGamePanel.none : panel),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: on ? AppTheme.accent.withValues(alpha: 0.18) : null,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
                color: on ? AppTheme.accent : const Color(0xFF2A3948)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                size: 14, color: on ? AppTheme.accent : AppTheme.textDim),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 11,
                    color: on ? AppTheme.accent : AppTheme.textDim)),
          ]),
        ),
      ),
    );
  }

  // ---- Drawers -------------------------------------------------------------

  Widget _drawer() {
    final size = MediaQuery.sizeOf(context);
    return Container(
      width: 360,
      constraints: BoxConstraints(maxHeight: size.height * 0.62),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xF20B1017),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF24313F)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _panel == CityGamePanel.milestones
              ? _milestonePanel()
              : _budgetPanel(),
        ),
      ),
    );
  }

  List<Widget> _milestonePanel() {
    final reached = CityProgression.reached(city.population);
    return [
      const Text('MILESTONES', style: AppTheme.heading),
      const SizedBox(height: 2),
      Text(
          'Population is the ladder. Each rung pays a grant and opens the next '
          'run of the build palette.',
          style: AppTheme.dim.copyWith(fontSize: 11)),
      const SizedBox(height: 10),
      for (final m in CityProgression.all) _milestoneRow(m, reached),
    ];
  }

  Widget _milestoneRow(CityMilestone m, CityMilestone reached) {
    final done = city.milestonesReached.contains(m.tier);
    final current = m.tier == reached.tier;
    final isNext = m.tier == reached.tier + 1;
    final unlocks = CityProgression.unlockedBy(m);
    final color =
        done ? AppTheme.accent2 : (isNext ? AppTheme.accent : AppTheme.textDim);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: current ? AppTheme.panelLight : null,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: current ? AppTheme.accent2 : const Color(0xFF1E2A38)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(done ? Icons.check_circle : Icons.lock_outline,
              size: 15, color: color),
          const SizedBox(width: 6),
          Expanded(
              child: Text(m.name,
                  style: AppTheme.body
                      .copyWith(color: color, fontWeight: FontWeight.bold))),
          Text('${m.population} pop',
              style: AppTheme.mono.copyWith(fontSize: 11)),
        ]),
        const SizedBox(height: 3),
        Text(m.blurb, style: AppTheme.dim.copyWith(fontSize: 11)),
        if (m.fundsGrant > 0 || m.oreGrant > 0)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
                'Grant: §${m.fundsGrant.toStringAsFixed(0)}  +  up to '
                '${m.oreGrant.toStringAsFixed(0)} ore',
                style: AppTheme.mono
                    .copyWith(fontSize: 11, color: AppTheme.accent2)),
          ),
        if (unlocks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [for (final s in unlocks) _unlockChip(s, done)],
            ),
          ),
      ]),
    );
  }

  Widget _unlockChip(CityBuildingSpec s, bool open) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
              color: open ? Color(s.colorArgb) : const Color(0xFF2A3948)),
          color: open ? Color(s.colorArgb).withValues(alpha: 0.14) : null,
        ),
        child: Text(s.label,
            style: TextStyle(
                fontSize: 10, color: open ? AppTheme.text : AppTheme.textDim)),
      );

  List<Widget> _budgetPanel() {
    final controllable = city.economy.taxControllable;
    final tax = city.effectiveTax();
    final net = city.netFundsRate;
    return [
      const Text('BUDGET', style: AppTheme.heading),
      const SizedBox(height: 2),
      Text(
          'The treasury pays for land and policy. CONSTRUCTION is paid in ore — '
          'mine it, ship it in, or earn it at a milestone.',
          style: AppTheme.dim.copyWith(fontSize: 11)),
      const SizedBox(height: 10),
      _kv('Treasury', '§${city.funds.toStringAsFixed(0)}'),
      _kv('Tax income', '+${city.taxIncomeRate.toStringAsFixed(2)} §/s',
          AppTheme.accent2),
      _kv('Ordinances', '${city.lawUpkeepRate.toStringAsFixed(2)} §/s',
          city.lawUpkeepRate < 0 ? AppTheme.warn : AppTheme.accent2),
      const Divider(height: 14, color: Color(0xFF1E2A38)),
      _kv('Net', '${net >= 0 ? '+' : ''}${net.toStringAsFixed(2)} §/s',
          net >= 0 ? AppTheme.accent2 : AppTheme.danger),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
            child: Text(controllable ? 'Tax rate' : 'State levy (fixed)',
                style: AppTheme.body)),
        Text('${(tax * 100).toStringAsFixed(0)}%',
            style: AppTheme.mono.copyWith(color: AppTheme.accent)),
      ]),
      SliderTheme(
        data: SliderThemeData(
            activeTrackColor: controllable ? AppTheme.accent : AppTheme.textDim,
            thumbColor: controllable ? AppTheme.accent : AppTheme.textDim,
            inactiveTrackColor: AppTheme.panelLight,
            trackHeight: 3),
        child: Slider(
          value: tax.clamp(0.0, 0.4),
          max: 0.4,
          onChanged:
              controllable ? (v) => setState(() => city.taxRate = v) : null,
        ),
      ),
      Text(
          'Higher tax fills the treasury and empties the mood. '
          '${city.economy.label} decides how much of it is yours to set.',
          style: AppTheme.dim.copyWith(fontSize: 11)),
      const SizedBox(height: 12),
      const Text('WORKFORCE', style: AppTheme.heading),
      const SizedBox(height: 6),
      _kv('Housing', '${city.housing}'),
      _kv('Jobs', '${city.jobs}'),
      _kv('Staffing', '${(city.staffing * 100).round()}%',
          city.staffing > 0.85 ? AppTheme.accent2 : AppTheme.warn),
      _kv('Homeless', '${city.homeless}',
          city.homeless > 0 ? AppTheme.warn : null),
      _kv('Congestion', '${(city.parcelCongestion * 100).round()}%',
          city.parcelCongestion > 0.6 ? AppTheme.danger : null),
    ];
  }

  Widget _kv(String k, String v, [Color? color]) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(k, style: AppTheme.body)),
          Text(v, style: AppTheme.mono.copyWith(color: color ?? AppTheme.text)),
        ]),
      );

  // ---- Banner --------------------------------------------------------------

  Widget _bannerCard(CityMilestoneAward award) {
    final m = award.milestone;
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xF00B1017),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.accent2, width: 2),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.emoji_events, color: AppTheme.accent2, size: 20),
            const SizedBox(width: 8),
            Text('${m.name.toUpperCase()} REACHED',
                style: AppTheme.title
                    .copyWith(fontSize: 16, color: AppTheme.accent2)),
          ]),
          const SizedBox(height: 4),
          Text(m.blurb, style: AppTheme.dim),
          const SizedBox(height: 6),
          Text(
              '§${award.funds.toStringAsFixed(0)} and '
              '${award.ore.toStringAsFixed(0)} ore released',
              style: AppTheme.mono.copyWith(color: AppTheme.accent2)),
          // A grant bigger than the stockpile can hold does not wait for a
          // silo — it spills. Say so, at the moment it happens.
          if (award.spilled)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  'Storage full — ${(m.oreGrant - award.ore).toStringAsFixed(0)} '
                  'ore of the grant had nowhere to go. Build depots.',
                  style: AppTheme.dim.copyWith(color: AppTheme.warn)),
            ),
        ]),
      );
  }

  /// Big numbers, small space: 12.3k rather than 12,345.
  static String _compact(double v) {
    if (v.abs() >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
    if (v.abs() >= 1e4) return '${(v / 1e3).toStringAsFixed(1)}k';
    return v.round().toString();
  }
}
