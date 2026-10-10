// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The loyalty warnings' look, shared by every screen that shows them —
/// the flat builder's status stack, the city game HUD and the politics
/// panel — so a colony that is Restless in one is Restless in all three.
///
/// A thin read over `CityLoyaltySim.loyaltyWarnings`: the domain decides
/// what is wrong and words it; this only picks the icon and the colour and
/// explains it in a dialog (docs/plans/colony-secession.md §3.5).
library;

import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_loyalty.dart';
import '../../../domain/colony/city/city_sim.dart';
import 'app_theme.dart';
import 'city_site_actions.dart' show showExplain;

/// The icon for a [LoyaltyWarning.key].
IconData loyaltyIcon(String key) => switch (key) {
      'independent' => Icons.flag,
      'portSeized' => Icons.no_transfer,
      'standoff' => Icons.front_hand,
      'defiant' => Icons.do_not_disturb_on,
      'revolt' => Icons.local_fire_department,
      'petition' => Icons.handshake,
      'terms' => Icons.gavel,
      _ => Icons.sentiment_dissatisfied,
    };

Color loyaltyColor(LoyaltySeverity s) =>
    s == LoyaltySeverity.danger ? AppTheme.danger : AppTheme.warn;

/// What a loyalty warning means, why, and what the player can do.
void explainLoyalty(BuildContext context, CitySim sim) {
  final l = sim.loyalty;
  final t = l.tuning;
  String pct(double v) => '${(v * 100).round()}%';
  final causes = sim.loyaltyCauses().join('; ');
  final drift = 'Per day: −${l.lastErosion.toStringAsFixed(3)} neglect, '
      '−${l.lastMisrule.toStringAsFixed(3)} misrule, '
      '+${l.lastRecovery.toStringAsFixed(3)} good rule.';
  final effects = switch (l.stage) {
    LoyaltyStage.loyal => 'No effect yet.',
    LoyaltyStage.restless =>
      'It governs itself: laws are voted whatever the government, and an '
          'over-high tax is pulled down toward what the mood bears.',
    LoyaltyStage.defiant =>
      'It strikes: everything but life support runs at '
          '${pct(t.defiantThrottle)}, and only ${pct(t.defiantTax)} of the '
          'tax is paid.',
    LoyaltyStage.standoff =>
      'It would secede, but cannot keep itself alive, so it cannot leave. '
          'Production runs at ${pct(t.standoffThrottle)}, no tax is paid, '
          'and settlers who live on imports leave'
          '${l.portSeized ? ' — or would, but the rebels hold the port and '
              'nobody can leave or land.' : '. Past ${pct(t.seizeDesperation)} '
              'desperation the rebels seize the spaceport.'}',
    LoyaltyStage.seceded =>
      'It is an independent faction and takes no orders: your tools on it '
          'are greyed, its own council sets its tax and laws and builds what '
          'it must, its port takes no relief and your deliveries to it are '
          'suspended. A craft you fly yourself can still land there, '
          'unwelcome. Its panel holds the ways back: the terms it would '
          'rejoin on, and any petition it sends.',
  };
  final why = 'Loyalty ${pct(l.level)} — ${l.stage.label}. $causes.\n\n'
      '$drift\n\n'
      'Self-sufficiency ${pct(l.selfSufficiency)} of the '
      '${pct(l.independenceBar)} a secession needs '
      '(desperation ${pct(l.desperation)}).\n\n'
      '$effects';
  const fix = 'Govern it: any act — zoning, building, roads, tax, laws, '
      'government — counts as attention, and attended, content rule (happy '
      'and served) wins loyalty back. Cut rebellion: crime, inequality, '
      'corruption and unhappiness drive it. Three revolts close together, '
      'or loyalty run out, and a colony that can feed itself breaks away.';
  showExplain(
      context,
      'Colony loyalty',
      why,
      fix,
      l.stage == LoyaltyStage.loyal || l.stage == LoyaltyStage.restless
          ? AppTheme.warn
          : AppTheme.danger);
}
