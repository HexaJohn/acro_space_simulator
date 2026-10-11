// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// An occupied colony on screen (docs/plans/combat.md §7A): who holds it,
/// what the garrison does to it, how far it is from its charter, and the two
/// orders the player has — restore the charter, or bring the garrison home.
library;

import 'package:flutter/material.dart';

import '../../../../domain/colony/city/city_occupation.dart';
import '../../../../domain/colony/city/city_sim.dart';
import '../app_theme.dart';
import 'combat_hooks.dart';

String _pct(double v) => '${(v * 100).round()}%';

/// The occupation's state, in words: the headline and the lines under it.
({String headline, List<String> lines}) occupationText(CitySim city) {
  final l = city.loyalty;
  final g = city.war.garrison;
  final n = city.occupationTroopers;
  final t = l.tuning;
  final lines = <String>[
    'It takes your orders under guard. The garrison holds rebellion and '
        'misrule down (${_pct(city.suppression)} suppression), at a cost to '
        'its mood; neglect it and it still slips away.',
  ];
  if (l.charterReady) {
    lines.add('It has earned its charter back: restore it, and your troopers '
        'come home.');
  } else if (l.level >= t.charterLevel) {
    lines.add('Loyalty ${_pct(l.level)}: on the charter line for '
        '${l.charterDaysHeld.floor()} of ${t.charterDays.round()} days.');
  } else {
    lines.add('Loyalty ${_pct(l.level)}: its charter comes back once loyalty '
        'has held ${_pct(t.charterLevel)} for ${t.charterDays.round()} days.');
  }
  if (g != null) {
    var days = double.infinity;
    for (final e in g.perTrooperDay.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key))) {
      if (e.value <= 0 || n <= 0) continue;
      final d = (g.stock[e.key] ?? 0) / (e.value * n);
      if (d < days) days = d;
    }
    if (city.war.requisitioning) {
      lines.add('Its kit has run out: it is eating the colony\'s own stores, '
          'and the colony resents it.');
    } else if (days.isFinite) {
      lines.add('Kit for ${days.toStringAsFixed(1)} days; supply runs bring '
          'more every three.');
    }
  }
  return (headline: 'Occupied — held by $n trooper${n == 1 ? '' : 's'}', lines: lines);
}

class OccupationPanel extends StatelessWidget {
  const OccupationPanel({super.key, required this.city, this.compact = false, this.onOrder});

  final CitySim city;

  /// The HUD's card: the headline and the charter line only, no orders.
  final bool compact;

  /// Runs after an order was given, for the host to close or rebuild.
  final VoidCallback? onOrder;

  @override
  Widget build(BuildContext context) {
    if (!city.loyalty.occupied) return const SizedBox.shrink();
    final text = occupationText(city);
    final restore = CombatHooks.restoreCharter;
    final withdraw = CombatHooks.withdrawGarrison;
    final ready = city.loyalty.charterReady;
    return Container(
      key: const ValueKey('occupation-panel'),
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.warn),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            const Icon(Icons.shield, size: 16, color: AppTheme.warn),
            const SizedBox(width: 6),
            Flexible(
              child: Text(text.headline,
                  style: AppTheme.heading.copyWith(color: AppTheme.warn)),
            ),
          ]),
          const SizedBox(height: 4),
          for (final line in compact ? text.lines.skip(1).take(1) : text.lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(line, style: AppTheme.dim),
            ),
          if (!compact && (restore != null || withdraw != null))
            Wrap(alignment: WrapAlignment.end, children: [
              if (withdraw != null)
                Tooltip(
                  message: 'Loyalty −${_pct(city.loyalty.tuning.withdrawCost)}, and it '
                      'takes the ordinary rules again: it secedes if it can feed '
                      'itself.',
                  child: TextButton(
                    key: const ValueKey('occupation-withdraw'),
                    onPressed: () {
                      withdraw(city);
                      onOrder?.call();
                    },
                    child: const Text('WITHDRAW GARRISON',
                        style: TextStyle(color: AppTheme.textDim)),
                  ),
                ),
              if (restore != null)
                TextButton(
                  key: const ValueKey('occupation-restore'),
                  onPressed: ready
                      ? () {
                          restore(city);
                          onOrder?.call();
                        }
                      : null,
                  child: Text('RESTORE CHARTER',
                      style: TextStyle(color: ready ? AppTheme.accent2 : AppTheme.textDim)),
                ),
            ]),
        ],
      ),
    );
  }
}

/// The occupation panel as a dialog — what the HUD's loyalty chip opens on
/// an occupied colony.
void showOccupation(BuildContext context, CitySim city) {
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: AppTheme.panel,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          OccupationPanel(city: city, onOrder: () => Navigator.of(ctx).maybePop()),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.of(ctx).maybePop(),
              child: const Text('CLOSE', style: TextStyle(color: AppTheme.accent)),
            ),
          ),
        ]),
      ),
    ),
  );
}
