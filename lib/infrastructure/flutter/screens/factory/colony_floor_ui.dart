// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The colony's factory-floor UI (docs/plans/factory-floors.md §4, wave 3):
/// the pieces every colony host shares — the in-world flight view, its flat
/// map and the flat builder — so the three can't drift apart.
///
/// * [ColonyFloorOverlay]: a placed plant's live floor, shown INSIDE the
///   host's own view. Not a pushed route: an opaque route offstages the
///   view under it, which stops its ticker, and the colony — which is what
///   steps the floor (`drivesSim: false`) — would freeze while the player
///   watched its plant.
/// * [openFloorSandbox]: "Design floor" from the build menu, before the
///   plant exists: a sandbox floor the editor drives itself, fed by an
///   infinite dock, whose "Save as blueprint" goes into the colony's library.
/// * [FloorBlueprintPicker]: which design a new plant of a type is stamped
///   with ("Template" or a saved blueprint).
/// * [confirmFloorLoss]: the one question asked before a designed floor is
///   demolished (§3 "Persistence").
/// * [FirmOfferCard] and [floorSiteLines]: a failed firm's offer, and a
///   floor plant's owner, books and real rates for its detail sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../../domain/colony/city/city_building_spec.dart';
import '../../../../domain/colony/city/city_economy.dart';
import '../../../../domain/colony/city/city_factories.dart';
import '../../../../domain/colony/city/city_sim.dart';
import '../../../../domain/colony/city/commodity.dart';
import '../../../../domain/colony/city/economy/economy_contracts.dart';
import '../../../../domain/colony/city/economy/firm_policy.dart';
import '../../../../domain/colony/city/factory/factory_floor.dart';
import '../../../../domain/colony/city/factory/factory_sim_api.dart';
import '../../../../domain/colony/city/factory/factory_templates.dart';
import '../../../../domain/colony/city/factory/floor_blueprint.dart';
import '../../../../domain/colony/city/economy/local_prices.dart'
    show kKjPerPowerUnitS;
import '../app_theme.dart';
import 'factory_floor_screen.dart';

// ---- the live floor, inside the host -------------------------------------

/// [site]'s live floor over the host's view, until its back arrow closes it.
///
/// Opens the floor through `CityFactories.openFloor` (built with the
/// colony's unlocks) and closes it through `closeFloor`, whose capex delta
/// the economy settles once the new layout is measured. The colony keeps
/// stepping the floor while it is open, so the screen only watches.
///
/// Input: the overlay must sit LAST in the host's stack (over the world's
/// pick layer, toolbar and HUD) and is opaque, so no world layer under it is
/// hit. Keys the editor doesn't use stop at [_swallowKeys] rather than
/// bubbling on to an ancestor's handler — the colony view's own key node is
/// an ancestor, and its R reloads a rifle and its WASD fly the camera.
class ColonyFloorOverlay extends StatefulWidget {
  const ColonyFloorOverlay({
    super.key,
    required this.city,
    required this.site,
    required this.onClosed,
  });

  final CitySim city;
  final String site;

  /// The overlay is done: the player closed it (with what the edit cost),
  /// or the plant went (demolished, burnt, a war) and the outcome is null.
  /// The host removes the overlay.
  final void Function(FloorEditOutcome? outcome) onClosed;

  @override
  State<ColonyFloorOverlay> createState() => ColonyFloorOverlayState();
}

class ColonyFloorOverlayState extends State<ColonyFloorOverlay>
    with SingleTickerProviderStateMixin {
  FactorySim? _sim;
  var _closed = false;
  late final Ticker _watch;

  /// The live floor being shown (null when the site had none).
  FactorySim? get sim => _sim;

  @override
  void initState() {
    super.initState();
    _sim = widget.city.openFloor(widget.site);
    // Watch for the floor being taken away under the editor: the plant
    // demolished by a war or a fire, or closed by another path (the dev
    // hook). An editor left over a dead floor would edit nothing, and its
    // close would settle nothing.
    _watch = createTicker((_) => _checkGone())..start();
    if (_sim == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkGone());
    }
  }

  void _checkGone() {
    if (_closed || !mounted) return;
    final live = widget.city.factoryFloors[widget.site]?.live;
    if (_sim != null && identical(live, _sim)) return;
    _closed = true;
    widget.onClosed(null);
  }

  /// The back arrow: settle the edit with the colony, then hand back.
  void close() {
    if (_closed) return;
    _closed = true;
    widget.onClosed(widget.city.closeFloor(widget.site));
  }

  @override
  void dispose() {
    _watch.dispose();
    // The host went with the editor open (the view closed): close the
    // floor so the colony doesn't keep a live sim nobody watches, and its
    // edit still reaches the books.
    if (!_closed) {
      _closed = true;
      widget.city.closeFloor(widget.site);
    }
    super.dispose();
  }

  static KeyEventResult _swallowKeys(FocusNode _, KeyEvent _) =>
      KeyEventResult.skipRemainingHandlers;

  @override
  Widget build(BuildContext context) {
    final sim = _sim;
    if (sim == null) return const SizedBox.shrink();
    final spec = widget.city.siteSpec(widget.site);
    final type = spec?.type ?? sim.blueprint.plantType ?? '';
    return Listener(
      // Opaque: a press on a gap between the editor's panels is the
      // editor's, never the world's beneath.
      behavior: HitTestBehavior.opaque,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _swallowKeys,
        child: FactoryFloorScreen(
          key: ValueKey('colony-floor-${widget.site}'),
          sim: sim,
          drivesSim: false,
          unlocks: widget.city.factoryUnlocks,
          title: '${spec?.label ?? 'Plant'} — factory floor',
          onClose: close,
          onSaveBlueprint: (bp) =>
              saveFloorBlueprint(context, widget.city, bp, type),
        ),
      ),
    );
  }
}

// ---- demolition ----------------------------------------------------------

/// The question before demolishing [site] loses a designed floor. True
/// straight away when the site has no designed floor (a template is rebuilt
/// for free, so nothing is lost and nothing is asked).
Future<bool> confirmFloorLoss(
    BuildContext context, CitySim city, String site) async {
  if (!city.floorIsDesigned(site)) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.panel,
      title: Text('Demolish ${city.siteSpec(site)?.label ?? 'this plant'}?',
          style: AppTheme.heading),
      content: const Text(
          "This plant's custom floor design will be lost. Save it as a "
          'blueprint from its floor first if you want to build it again.',
          style: AppTheme.body),
      actions: [
        TextButton(
            key: const Key('floor-loss-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it')),
        TextButton(
            key: const Key('floor-loss-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Demolish',
                style: TextStyle(color: AppTheme.danger))),
      ],
    ),
  );
  return ok ?? false;
}

// ---- blueprints ----------------------------------------------------------

/// Asks for a blueprint name; null when cancelled or left empty.
Future<String?> promptBlueprintName(
    BuildContext context, String initial) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _BlueprintNameDialog(initial: initial),
  );
  final trimmed = name?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// The name prompt. Stateful so the text controller lives exactly as long
/// as the dialog: disposed by the caller after `showDialog` returned, it
/// was still listened to by the dialog's exit animation.
class _BlueprintNameDialog extends StatefulWidget {
  const _BlueprintNameDialog({required this.initial});
  final String initial;

  @override
  State<_BlueprintNameDialog> createState() => _BlueprintNameDialogState();
}

class _BlueprintNameDialogState extends State<_BlueprintNameDialog> {
  late final TextEditingController _text =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppTheme.panel,
        title: const Text('Save as blueprint', style: AppTheme.heading),
        content: TextField(
          key: const Key('blueprint-name'),
          controller: _text,
          autofocus: true,
          style: AppTheme.body,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          TextButton(
              key: const Key('blueprint-name-save'),
              onPressed: () => Navigator.of(context).pop(_text.text),
              child: const Text('Save')),
        ],
      );
}

/// A first name for a new design of [plantType] that the library doesn't
/// hold yet ("Steel Mill design 2").
String nextBlueprintName(CitySim city, String plantType) {
  final label = kUtilCatalog
          .where((s) => s.type == plantType)
          .map((s) => s.label)
          .firstOrNull ??
      'Floor';
  final taken = city.factoryFloors.library.keys.toSet();
  for (var n = 1;; n++) {
    final name = '$label design $n';
    if (!taken.contains(name)) return name;
  }
}

/// "Save as blueprint": names [bp] and files it in [city]'s library, drawn
/// for [plantType], and makes it the design new [plantType] plants are
/// stamped with — saving a design is choosing it.
Future<String?> saveFloorBlueprint(BuildContext context, CitySim city,
    FloorBlueprint bp, String plantType) async {
  final name =
      await promptBlueprintName(context, nextBlueprintName(city, plantType));
  if (name == null) return null;
  // Drawn for this plant even if the layout came from an untagged copy, so
  // the picker lists it under the right plant.
  final tagged = bp.plantType == plantType
      ? bp
      : FloorBlueprint.fromJson({...bp.toJson(), 'plant': plantType});
  city.factoryFloors.saveBlueprint(name, tagged);
  city.selectFloorBlueprint(plantType, name);
  return name;
}

/// The library's designs drawn for [plantType] (or for no plant), by name.
List<String> blueprintsFor(CitySim city, String plantType) => [
      for (final e in city.factoryFloors.library.entries)
        if (e.value.plantType == null || e.value.plantType == plantType) e.key,
    ];

/// "Design floor" from the build menu: [spec]'s floor in a sandbox, before
/// any plant is placed — the chosen blueprint, or the template — driven by
/// the editor itself against an infinite dock, with the colony's unlocks
/// shown. A transparent route over the host, so the host (and the colony
/// under it) keeps running. [onChanged] runs after the editor closes, so
/// the host can show a design saved from it.
Future<void> openFloorSandbox(
    BuildContext context, CitySim city, CityBuildingSpec spec,
    {VoidCallback? onChanged}) async {
  final bp = city.floorBlueprintFor(spec.type) ?? factoryTemplateFor(spec.type);
  if (bp == null) return;
  final unlocks = city.factoryUnlocks;
  final floor = FactoryFloor.fromBlueprint(bp, unlocks: unlocks);
  await Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    pageBuilder: (ctx, _, _) => Listener(
      behavior: HitTestBehavior.opaque,
      child: FactoryFloorScreen(
        key: const Key('floor-sandbox'),
        sim: floor,
        unlocks: unlocks,
        title: '${spec.label} — design floor',
        onSaveBlueprint: (b) => saveFloorBlueprint(ctx, city, b, spec.type),
      ),
    ),
  ));
  onChanged?.call();
}

/// "Floor: [Template ▾]": which design new [spec] plants are stamped with,
/// and the "Design floor" button. Shown in the build palettes for a floor
/// plant only. A misfit pick says why it won't place, here, before the
/// player goes looking for a site.
class FloorBlueprintPicker extends StatelessWidget {
  const FloorBlueprintPicker({
    super.key,
    required this.city,
    required this.spec,
    required this.onChanged,
  });

  final CitySim city;
  final CityBuildingSpec spec;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final names = blueprintsFor(city, spec.type);
    final picked = city.floorBlueprintFor(spec.type) == null
        ? null
        : city.selectedFloorBlueprint[spec.type];
    final misfit = city.floorBlueprintRefusal(spec);
    const small = TextStyle(fontSize: 10, color: Color(0xFF9FB4CC));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('Floor', style: small),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButton<String?>(
            key: Key('floor-pick-${spec.type}'),
            isExpanded: true,
            isDense: true,
            value: picked,
            dropdownColor: AppTheme.panel,
            style: const TextStyle(fontSize: 11, color: Color(0xFFD6E2EE)),
            underline: const SizedBox.shrink(),
            items: [
              const DropdownMenuItem<String?>(
                  value: null, child: Text('Template')),
              for (final n in names)
                DropdownMenuItem<String?>(value: n, child: Text(n)),
            ],
            onChanged: (v) {
              city.selectFloorBlueprint(spec.type, v);
              onChanged();
            },
          ),
        ),
        TextButton(
          key: Key('design-floor-${spec.type}'),
          style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 24),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          onPressed: () =>
              openFloorSandbox(context, city, spec, onChanged: onChanged),
          child: const Text('Design floor',
              style: TextStyle(fontSize: 10, color: AppTheme.accent)),
        ),
      ]),
      if (misfit != null)
        Text(misfit,
            style: const TextStyle(fontSize: 10, color: AppTheme.warn)),
    ]);
  }
}

// ---- owners and books ----------------------------------------------------

String _healthLabel(FirmHealth h) => switch (h) {
      FirmHealth.healthy => 'healthy',
      FirmHealth.strained => 'strained',
      FirmHealth.distressed => 'distressed — laying off',
      FirmHealth.closed => 'closed',
    };

String _rate(double v) =>
    v.abs() >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

/// A floor plant's owner, firm health, last day's books and REAL rates —
/// the record's, not the spec's nameplate: a designed floor makes what it
/// was measured to make. Empty when [site] has no floor.
List<String> floorSiteLines(CitySim city, String site) {
  final rec = city.factoryFloors[site];
  if (rec == null) return const [];
  final owner = city.ownerOf(site);
  final book = city.firmBookOf(site);
  final throttle = city.floorThrottleOf(site);
  final lines = <String>[
    owner.isState
        ? 'State plant'
        : 'Private — ${owner.firmId ?? 'a firm'}',
    if (book != null) 'Firm: ${_healthLabel(book.health)}',
    if (throttle < 1 && throttle > 0)
      'Running at ${(throttle * 100).round()}% (stations idled)',
    rec.designed
        ? (rec.dirty ? 'Designed floor — being measured' : 'Designed floor')
        : 'Template floor',
  ];
  final pnl = city.colonyEconomy.lastPnl[site];
  if (pnl != null && pnl.seconds > 0) {
    final s = pnl.seconds;
    lines.add('Last day: revenue ${_rate(pnl.revenue / s)}/s, '
        'costs ${_rate(pnl.costs / s)}/s, tax ${_rate(pnl.tax / s)}/s, '
        'profit ${_rate(pnl.profit / s)}/s (credits)');
  }
  final r = rec.rates;
  // Idled stations and a closed plant scale everything the floor moves.
  for (final e in r.inPerS.entries) {
    lines.add('−${(e.value * throttle).toStringAsFixed(2)} '
        '${Commodity.name(e.key)}/s');
  }
  for (final e in r.outPerS.entries) {
    lines.add('+${(e.value * throttle).toStringAsFixed(2)} '
        '${Commodity.name(e.key)}/s');
  }
  final power = r.powerKw / kKjPerPowerUnitS * throttle;
  if (power > 0) lines.add('−${power.toStringAsFixed(1)} power');
  final jobs = r.jobs * throttle;
  if (jobs > 0) lines.add('${jobs.round()} jobs');
  return lines;
}

/// A closed plant's offer (§7 Q11): nationalise it, or sell it to a new
/// firm — only what the economy allows. One at a time; the count says how
/// many more wait.
class FirmOfferCard extends StatelessWidget {
  const FirmOfferCard({super.key, required this.city, required this.onChanged});

  final CitySim city;
  final VoidCallback onChanged;

  static String label(ClosureOption o) => switch (o) {
        ClosureOption.nationalise => 'Nationalise',
        ClosureOption.sellToNewFirm => 'Sell to new firm',
      };

  @override
  Widget build(BuildContext context) {
    final offers = city.pendingFirmOffers;
    if (offers.isEmpty) return const SizedBox.shrink();
    final offer = offers.first;
    final name = city.siteSpec(offer.site)?.label ?? 'A plant';
    return Container(
      key: const Key('firm-offer'),
      constraints: const BoxConstraints(maxWidth: 360),
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.panelBox(border: AppTheme.warn),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$name has closed',
                style: AppTheme.body.copyWith(color: AppTheme.warn)),
            const SizedBox(height: 2),
            Text(
                'Its firm could not cover its costs. Run it as a state plant '
                '(its losses come out of the treasury) or sell it to a new '
                'firm.${offers.length > 1 ? ' ${offers.length - 1} more '
                    'waiting.' : ''}',
                style: AppTheme.dim.copyWith(fontSize: 11)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, children: [
              for (final o in offer.options)
                OutlinedButton(
                  key: Key('firm-offer-${o.name}'),
                  onPressed: () {
                    city.resolveFirmOffer(offer.site, o);
                    city.attend(); // an act of governance (secession §3.3)
                    onChanged();
                  },
                  child: Text(label(o), style: const TextStyle(fontSize: 11)),
                ),
            ]),
          ]),
    );
  }
}
