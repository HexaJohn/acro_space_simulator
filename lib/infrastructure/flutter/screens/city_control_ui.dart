// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The control gate's look (docs/plans/colony-secession.md §5) and the
/// independent colony's panel (§4), shared by every host that governs a
/// colony — the in-world editor, the city game HUD, the flat builder and the
/// politics panel — so a colony that has left reads the same in all of them.
///
/// The gate itself is `CityControl.playerControl` in the domain; this only
/// draws its answer. A refused control is greyed and SAYS why (a tooltip, a
/// snack bar, the editor's blocked line): a button that silently does
/// nothing reads as a bug, not as a colony that has stopped listening.
library;

import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_control.dart';
import '../../../domain/colony/city/city_loyalty.dart';
import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/colony/city/independent_governor.dart';
import 'app_theme.dart';

/// Tell the player why a control refused, as a snack bar.
void sayRefused(BuildContext context, String reason) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(reason),
      backgroundColor: const Color(0xFF6B1414),
      duration: const Duration(seconds: 3),
    ));
}

/// [child] as the gate leaves it: itself while the player may act, greyed
/// and carrying the refusal as its tooltip when not. The child's own handler
/// must be disabled by its builder too ([CityControl.mayAct] or a null
/// callback) — this is the look, not the lock.
Widget gatedControl(CitySim sim, Widget child) {
  final c = sim.playerControl;
  if (c.allowed) return child;
  return Tooltip(
    message: c.reason!,
    child: Opacity(opacity: 0.45, child: child),
  );
}

/// The colony that has left (§4): since when, why, what its own council is
/// doing, and where the way back will be. Empty for a colony still the
/// player's.
class IndependencePanel extends StatelessWidget {
  const IndependencePanel({super.key, required this.city, this.compact = false});

  final CitySim city;

  /// The HUD's card: the headline, the causes and the latest act only.
  final bool compact;

  /// The text the panel's headline carries, for a test to find.
  static String headline(CitySim city) {
    final day = city.independentSinceDay;
    return day == null ? 'Independent' : 'Independent since day $day';
  }

  @override
  Widget build(BuildContext context) {
    final l = city.loyalty;
    if (l.allegiance != Allegiance.independent) return const SizedBox.shrink();
    final causes = l.independenceCauses;
    final log = city.governorLog;
    final recent = log.reversed.take(compact ? 1 : 5).toList();
    return Container(
      key: const ValueKey('independence-panel'),
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.danger),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            const Icon(Icons.flag, size: 16, color: AppTheme.danger),
            const SizedBox(width: 6),
            Flexible(
              child: Text(headline(city),
                  style: AppTheme.heading.copyWith(color: AppTheme.danger)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
              'It governs itself and takes no orders: its readouts are '
              'yours to watch, its tools are not yours to use, and your '
              'deliveries to it are suspended.',
              style: AppTheme.dim),
          if (causes != null) ...[
            const SizedBox(height: 4),
            Text('Why it left: $causes.',
                style: AppTheme.dim.copyWith(color: AppTheme.warn)),
          ],
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('ITS COUNCIL', style: AppTheme.dim.copyWith(fontSize: 10)),
            for (final a in recent)
              Text(
                  'Day ${(a.atS / l.tuning.daySec).floor() + 1}: ${a.text}',
                  style: AppTheme.dim),
          ],
          if (!compact) ...[
            const SizedBox(height: 8),
            Text('RECLAIM', style: AppTheme.dim.copyWith(fontSize: 10)),
            // Player-facing: in-world words, not the plan's phase numbers.
            Text(
                'Ways to win it back (negotiation, goodwill, force) are not '
                'available yet.',
                key: const ValueKey('independence-reclaim'),
                style: AppTheme.dim),
          ],
        ],
      ),
    );
  }
}

/// The independence panel as a dialog — what the HUD's loyalty chip opens
/// on a colony that has left.
void showIndependence(BuildContext context, CitySim city) {
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: AppTheme.panel,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          IndependencePanel(city: city),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.of(ctx).maybePop(),
              child:
                  const Text('CLOSE', style: TextStyle(color: AppTheme.accent)),
            ),
          ),
        ]),
      ),
    ),
  );
}
