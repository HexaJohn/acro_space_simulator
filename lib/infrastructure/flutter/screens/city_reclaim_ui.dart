// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The ways back on screen (docs/plans/colony-secession.md §6): the
/// independence panel's Reclaim section — negotiate, the petitions, the
/// player's standing, and force's empty slot — and the card that shows the
/// terms a colony rejoined under while they run.
///
/// A thin read over `CityReclaimSim` in the domain: the colony states its
/// terms and raises its petitions there; this draws them and hands back the
/// player's answer. The answers are the one set of controls the control
/// gate does NOT grey on an independent colony — they are how it stops
/// being one.
library;

import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_loyalty.dart';
import '../../../domain/colony/city/city_reclaim.dart';
import '../../../domain/colony/city/city_sim.dart';
import 'app_theme.dart';

String _pct(double v) => '${(v * 100).round()}%';

String _days(num n) => '${n.round()} day${n.round() == 1 ? '' : 's'}';

/// Terms as lines, or a dash for none.
Widget _termLines(BindingTerms terms, {Key? key}) {
  final lines = terms.describe();
  return Column(
    key: key,
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (lines.isEmpty || terms.days <= 0)
        Text('No terms.', style: AppTheme.dim)
      else ...[
        for (final l in lines) Text('•  $l', style: AppTheme.body),
        Text('for ${_days(terms.days)}', style: AppTheme.dim),
      ],
    ],
  );
}

/// The Reclaim section of the independence panel: every way back the colony
/// offers now. [onRejoined] runs once the player has won it back, for the
/// host to close or rebuild.
class ReclaimSection extends StatefulWidget {
  const ReclaimSection({super.key, required this.city, this.onRejoined});

  final CitySim city;
  final VoidCallback? onRejoined;

  @override
  State<ReclaimSection> createState() => _ReclaimSectionState();
}

class _ReclaimSectionState extends State<ReclaimSection> {
  CitySim get city => widget.city;

  void _rejoined() {
    if (mounted) setState(() {});
    widget.onRejoined?.call();
  }

  @override
  Widget build(BuildContext context) {
    final r = city.reclaim;
    final petition = r.petition;
    final rep = r.reputation;
    return Column(
      key: const ValueKey('independence-reclaim'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (petition != null) ...[
          _petitionCard(petition),
          const SizedBox(height: 6),
        ],
        // Negotiate (§6.1).
        _row(
          Icons.handshake,
          'Negotiate',
          'Hear the terms it would rejoin on.',
          AppTheme.accent,
          () async {
            final done = await showNegotiation(context, city);
            if (done) _rejoined();
          },
          key: const ValueKey('reclaim-negotiate'),
        ),
        // Win hearts (§6.2).
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            key: const ValueKey('reclaim-reputation'),
            rep == null
                ? 'Goodwill: none to measure. With no other colony of yours '
                    'to compare itself with, it will not ask to come back '
                    'for how you rule.'
                : 'Your colonies\' standing ${_pct(rep)} against its own '
                    'mood ${_pct(city.happiness)}. '
                    '${rep > city.happiness ? 'It envies them: the wish to rejoin is at ${_pct(r.pressure)}.' : 'It sees nothing to envy.'}',
            style: AppTheme.dim,
          ),
        ),
        // Force (§6.3) — its place kept, and honest that it is empty.
        _row(Icons.shield, 'Force', 'Not available yet.', AppTheme.textDim,
            null,
            key: const ValueKey('reclaim-force')),
      ],
    );
  }

  Widget _petitionCard(Petition p) {
    final hearts = p.kind == PetitionKind.hearts;
    return Container(
      key: const ValueKey('reclaim-petition'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppTheme.accent2.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.accent2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
              hearts
                  ? 'IT ASKS TO REJOIN — your other colonies are run better'
                  : 'IT ASKS TO REJOIN — it cannot keep itself alive',
              style: AppTheme.dim.copyWith(color: AppTheme.accent2)),
          const SizedBox(height: 4),
          if (hearts) ...[
            Text('On its own light terms:', style: AppTheme.dim),
            _termLines(p.terms ?? BindingTerms.none),
          ] else
            Text(
                'On whatever terms you set — or none. Each term you grant '
                'is goodwill it will remember.',
                style: AppTheme.dim),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
              key: const ValueKey('reclaim-petition-decline'),
              onPressed: () => setState(city.declinePetition),
              child: const Text('DECLINE',
                  style: TextStyle(color: AppTheme.textDim)),
            ),
            TextButton(
              key: const ValueKey('reclaim-petition-accept'),
              onPressed: () async {
                if (hearts) {
                  if (city.acceptPetition()) _rejoined();
                  return;
                }
                final terms = await showTermPicker(context, city);
                if (terms != null && city.acceptPetition(terms)) _rejoined();
              },
              child: Text(hearts ? 'ACCEPT' : 'SET TERMS…',
                  style: const TextStyle(color: AppTheme.accent2)),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String label, String sub, Color color,
          VoidCallback? onTap,
          {Key? key}) =>
      InkWell(
        key: key,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Icon(icon, size: 16, color: onTap == null ? AppTheme.textDim : color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: AppTheme.body.copyWith(
                            color: onTap == null ? AppTheme.textDim : color)),
                    Text(sub, style: AppTheme.dim),
                  ]),
            ),
          ]),
        ),
      );
}

/// The colony's terms (§6.1), Accept or Decline. True when the player
/// accepted and the colony has rejoined.
Future<bool> showNegotiation(BuildContext context, CitySim city) async {
  final terms = city.negotiatedTerms();
  final accepted = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.panel,
      title: Text('Its terms',
          style: AppTheme.heading.copyWith(color: AppTheme.accent)),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
              'It will rejoin at loyalty ${_pct(city.reclaim.tuning.rejoinLoyalty)} '
              'if you bind yourself to these. While they run, the tools that '
              'would break one refuse.',
              style: AppTheme.dim),
          const SizedBox(height: 8),
          _termLines(terms, key: const ValueKey('negotiation-terms')),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('negotiation-decline'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child:
              const Text('DECLINE', style: TextStyle(color: AppTheme.textDim)),
        ),
        TextButton(
          key: const ValueKey('negotiation-accept'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('ACCEPT', style: TextStyle(color: AppTheme.accent)),
        ),
      ],
    ),
  );
  if (accepted != true) return false;
  return city.acceptNegotiation();
}

/// The term menu a dependency petition's player picks from (§6.2): a tax
/// cap, any of the laws the colony holds, the demolition ban, and how long.
/// Null when the player backed out; [BindingTerms.none] when they set none.
Future<BindingTerms?> showTermPicker(BuildContext context, CitySim city) {
  double? cap;
  final kept = <Law>{};
  var noDemolition = false;
  var days = 20.0;
  final held = [for (final l in Law.values) if (city.laws.contains(l)) l];
  return showDialog<BindingTerms>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final terms = BindingTerms(
            taxCap: cap, keptLaws: kept, noDemolition: noDemolition, days: days);
        return AlertDialog(
          backgroundColor: AppTheme.panel,
          title: Text('Your terms',
              style: AppTheme.heading.copyWith(color: AppTheme.accent2)),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                    'It rejoins at loyalty '
                    '${_pct((city.reclaim.tuning.rejoinLoyalty + city.reclaim.tuning.goodwillPerTerm * (terms.isEmpty ? 0 : terms.count)).clamp(0.0, 1.0))}: '
                    'every term you grant binds you, and is remembered.',
                    style: AppTheme.dim),
                const SizedBox(height: 8),
                Text('TAX CAP', style: AppTheme.dim.copyWith(fontSize: 10)),
                Wrap(spacing: 6, children: [
                  ChoiceChip(
                    key: const ValueKey('terms-cap-none'),
                    label: const Text('None'),
                    selected: cap == null,
                    onSelected: (_) => set(() => cap = null),
                  ),
                  for (final c in CityReclaimSim.taxCapChoices)
                    ChoiceChip(
                      key: ValueKey('terms-cap-${(c * 100).round()}'),
                      label: Text(_pct(c)),
                      selected: cap == c,
                      onSelected: (_) => set(() => cap = c),
                    ),
                ]),
                const SizedBox(height: 6),
                Text('LAWS KEPT', style: AppTheme.dim.copyWith(fontSize: 10)),
                if (held.isEmpty)
                  Text('It holds no laws to keep.', style: AppTheme.dim),
                for (final l in held)
                  CheckboxListTile(
                    key: ValueKey('terms-law-${l.name}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l.label, style: AppTheme.body),
                    value: kept.contains(l),
                    onChanged: (v) =>
                        set(() => v == true ? kept.add(l) : kept.remove(l)),
                  ),
                SwitchListTile(
                  key: const ValueKey('terms-no-demolition'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('No demolitions', style: AppTheme.body),
                  value: noDemolition,
                  onChanged: (v) => set(() => noDemolition = v),
                ),
                Text('FOR ${_days(days).toUpperCase()}',
                    style: AppTheme.dim.copyWith(fontSize: 10)),
                Slider(
                  key: const ValueKey('terms-days'),
                  value: days,
                  min: 5,
                  max: 40,
                  divisions: 7,
                  onChanged: (v) => set(() => days = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('BACK',
                  style: TextStyle(color: AppTheme.textDim)),
            ),
            TextButton(
              key: const ValueKey('terms-accept'),
              onPressed: () => Navigator.of(ctx).pop(terms.isEmpty
                  ? BindingTerms.none
                  : BindingTerms(
                      taxCap: cap,
                      keptLaws: {...kept},
                      noDemolition: noDemolition,
                      days: days)),
              child: Text(terms.isEmpty ? 'ACCEPT WITH NO TERMS' : 'ACCEPT',
                  style: const TextStyle(color: AppTheme.accent2)),
            ),
          ],
        );
      },
    ),
  );
}

/// The terms a colony rejoined under, while they run (§6.1): each term and
/// the days left. Empty with none.
class BindingTermsCard extends StatelessWidget {
  const BindingTermsCard({super.key, required this.city, this.compact = false});

  final CitySim city;

  /// The HUD's one-line card.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final b = city.reclaim.terms;
    if (b == null || city.loyalty.allegiance == Allegiance.independent) {
      return const SizedBox.shrink();
    }
    final left = _days(city.termsDaysLeft);
    final lines = b.describe();
    return Container(
      key: const ValueKey('binding-terms'),
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.warn),
      ),
      child: compact
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.gavel, size: 14, color: AppTheme.warn),
              const SizedBox(width: 6),
              Flexible(
                child: Text('Rejoining terms: ${lines.join(', ')} — $left left',
                    style: AppTheme.dim.copyWith(color: AppTheme.warn)),
              ),
            ])
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  const Icon(Icons.gavel, size: 14, color: AppTheme.warn),
                  const SizedBox(width: 6),
                  Text('REJOINING TERMS — $left left',
                      style: AppTheme.dim.copyWith(color: AppTheme.warn)),
                ]),
                for (final l in lines) Text('•  $l', style: AppTheme.body),
                Text(
                    'The colony came back on these. Until they run out, the '
                    'tools that would break one refuse.',
                    style: AppTheme.dim),
              ],
            ),
    );
  }
}
