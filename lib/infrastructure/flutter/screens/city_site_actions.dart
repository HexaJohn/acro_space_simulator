// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Everything you can DO to a building, addressed by site id.
///
/// This used to live inside the flat builder screen, keyed on grid cells, which
/// meant the actions that matter most — booking a delivery, calling in relief,
/// parking the lander — existed only on the map. Standing in front of a
/// spaceport in the world and tapping it did nothing at all.
///
/// Keyed on a [CitySim] site id, the same sheet serves both hosts: the flat
/// builder passes `cell-<key>`, the in-world editor passes the lot id, and
/// neither knows which model the other is using.
library;

import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_building_spec.dart';
import '../../../domain/colony/city/city_control.dart';
import '../../../domain/colony/city/city_economy.dart';
import '../../../domain/colony/city/economy/firm_policy.dart';
import '../../../domain/colony/city/city_factories.dart';
import '../../../domain/colony/city/city_reclaim.dart';
import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/colony/city/city_site_rules.dart';
import '../../../domain/planetary/terraform_towers.dart';
import 'app_theme.dart';
import 'city_control_ui.dart';
import 'city_model.dart';
import 'craft_assembly_screen.dart';
import 'factory/colony_floor_ui.dart';

/// The actions a HOST supplies, because they need something the sim has no
/// opinion about — a navigator, a camera, a craft in flight.
class CitySiteHooks {
  const CitySiteHooks({
    this.onOpenVab,
    this.onTargetPad,
    this.targetPadHint,
    this.extra,
    this.onOpenFactoryFloor,
  });

  /// Show [site]'s factory floor in the host's own view
  /// ([ColonyFloorOverlay]). Null hides the "Factory floor" action: a host
  /// that cannot keep the colony running under the editor must not open it.
  final void Function(String site)? onOpenFactoryFloor;

  /// Open the VAB to design and launch a craft from this site. Null hides the
  /// action entirely (a host with nowhere to launch from).
  final VoidCallback? onOpenVab;

  /// Aim the craft the player is flying at this port's pads. Null hides it —
  /// the flat builder has no craft in the air to point anywhere.
  final void Function(String site)? onTargetPad;

  /// Why [onTargetPad] is unavailable right now, or null when it is available.
  /// Shown as the action's subtitle so a greyed row still explains itself.
  final String? targetPadHint;

  /// Extra rows only one host offers, built with [citySiteAction].
  final List<Widget> Function(String site, CityBuildingSpec spec)? extra;
}

/// One row of the site menu: icon, label, one line of why.
Widget citySiteAction(
  BuildContext context,
  IconData icon,
  String label,
  String sub,
  Color color,
  VoidCallback onTap,
) =>
    ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(label, style: AppTheme.body.copyWith(color: color)),
      subtitle: Text(sub, style: AppTheme.dim),
      onTap: () {
        Navigator.of(context).pop();
        onTap();
      },
    );

/// [citySiteAction] behind the control gate (docs/plans/colony-secession.md
/// §5): on a colony that takes no orders the row stays — the player sees
/// what the building could do — greyed, its subtitle the reason, and a tap
/// says it instead of acting. [termRefusal] is a binding term's refusal
/// (secession §6.1) on a colony that does take orders — the demolition
/// ban on Demolish — shown and said the same way.
Widget gatedSiteAction(
  BuildContext context,
  CitySim sim,
  IconData icon,
  String label,
  String sub,
  Color color,
  VoidCallback onTap, {
  String? termRefusal,
}) {
  final why = sim.playerControl.reason ?? termRefusal;
  if (why == null) {
    return citySiteAction(context, icon, label, sub, color, onTap);
  }
  return citySiteAction(context, icon, label, why, AppTheme.textDim,
      () => sayRefused(context, why));
}

/// A "why did this happen / how to fix" modal for a warning or status.
void showExplain(
    BuildContext context, String title, String why, String fix, Color color) {
  showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: AppTheme.panel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: AppTheme.title.copyWith(color: color, fontSize: 18)),
                const SizedBox(height: 14),
                Text('WHY',
                    style: AppTheme.dim.copyWith(
                        color: AppTheme.warn,
                        fontSize: 10,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(why, style: AppTheme.body),
                const SizedBox(height: 14),
                Text('HOW TO FIX',
                    style: AppTheme.dim.copyWith(
                        color: AppTheme.accent2,
                        fontSize: 10,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(fix, style: AppTheme.body),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('GOT IT',
                        style: TextStyle(color: AppTheme.accent)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// This site's worst current problem, so the details readout explains WHY it is
/// flagged instead of always claiming "Operating". Checked worst-first; the
/// first hit wins.
({String label, String why, String fix, Color color}) citySiteStatus(
    CitySim sim, String site, CityBuildingSpec spec) {
  final cell = CitySim.cellOfSiteId(site);
  final powerRatio =
      sim.powerDraw <= 0 ? 1.0 : (sim.powerOut / sim.powerDraw).clamp(0.0, 1.0);
  final needsPower = spec.powerDraw > 0;
  final needsStaff = spec.jobs > 0;

  // Abandonment is a GRID state — a lot decays by losing its building outright,
  // so a parcel site is never "abandoned" while it still stands.
  if (cell != null && sim.abandoned.contains(cell)) {
    return (
      label: 'Abandoned',
      why: 'Its people walked out after this building lost road or power for '
          'too long. An abandoned building produces nothing and decays into '
          'rubble if the failure isn\'t fixed.',
      fix: 'Reconnect it to the road network and restore power. Once '
          'infrastructure is back it can be reoccupied.',
      color: AppTheme.danger,
    );
  }
  if (!sim.siteConnected(site)) {
    return (
      label: 'Cut off',
      why: 'This building has no road path back to the colony hub, so no '
          'workers, goods, or services reach it. It produces nothing while '
          'disconnected.',
      fix: 'Lay a road connecting it to the hub network. Watch for gaps, '
          'water, or demolished tiles breaking the path.',
      color: AppTheme.danger,
    );
  }
  // Worse than any shortfall of hands or power: with them all it still
  // makes nothing. Without this a harvester under a sky its intakes have
  // thinned (or one that never had oxygen) reported whatever colony mood
  // came next — "Unhappy" — and its sheet the nameplate yield.
  if (sim.idleForSky(spec)) {
    return (
      label: 'Idle — no oxygen to draw',
      why: 'The air here holds too little oxygen (under 2%), or too little '
          'air, for its intakes to draw any. It makes nothing until the sky '
          'has oxygen in it again.',
      fix: 'Split water in Electrolysis Plants instead, or vent oxygen into '
          'the sky with Terraforming Towers. Harvesters on one world share '
          'its air: every one draws the same sky down.',
      color: AppTheme.danger,
    );
  }
  // A terraforming tower at its planet's limit runs, by the colony's books,
  // at full throttle — and moves no gas. Said here, or its sheet read
  // "Operating — running at full output" over a building doing nothing.
  if (sim.towerIdleReason(spec) case final why?) {
    return (
      label: 'Idle — planet at its limit',
      why: '$why It still draws its power and jobs while it stands idle.',
      fix: 'Demolish it to free the power and the workers, or keep it as a '
          'reserve: it starts again by itself if the planet drifts back '
          'past its limit.',
      color: AppTheme.warn,
    );
  }
  if (needsPower && powerRatio < 0.95) {
    return (
      label: 'Unpowered',
      why: 'The grid is supplying only ${(powerRatio * 100).toStringAsFixed(0)}% '
          'of demand (${sim.powerOut.toStringAsFixed(0)}/${sim.powerDraw.toStringAsFixed(0)} '
          'power). Under-powered buildings run throttled and risk abandonment.',
      fix: 'Build more generators (solar / reactor / fusion) or demolish '
          'non-essential draws until supply exceeds demand.',
      color: AppTheme.warn,
    );
  }
  if (needsStaff && sim.staffing < 0.95) {
    return (
      label: 'Understaffed',
      why: 'The city can only fill ${(sim.staffing * 100).toStringAsFixed(0)}% of '
          'its jobs, so this building runs short-handed and below full output. '
          'Too few workers, or congestion stretching their commute.',
      fix: 'Grow population (housing + a connected spaceport for immigrants), '
          'or cut road congestion + excess jobs so workers go round.',
      color: AppTheme.warn,
    );
  }
  if (sim.corpses > 1) {
    return (
      label: 'Bodies unprocessed',
      why: 'There are ${sim.corpses.toStringAsFixed(0)} unprocessed corpses in '
          'the colony. The backlog breeds disease and litters the streets, '
          'dragging happiness across every building.',
      fix: 'Build / connect deathcare (cemetery, crematorium) and keep it '
          'powered + staffed so bodies are processed faster than they pile up.',
      color: AppTheme.warn,
    );
  }
  if (sim.happiness < 0.5) {
    return (
      label: 'Unhappy',
      why: 'Colony happiness is ${(sim.happiness * 100).toStringAsFixed(0)}%. '
          'Low happiness slows growth and, if it keeps falling, risks unrest '
          'and citizens fleeing.',
      fix: 'Balance R/C/I demand, fund services (health, parks, transit), and '
          'cut crime, pollution, and inequality. Some laws lift happiness.',
      color: AppTheme.warn,
    );
  }
  return (
    label: 'Operating',
    why: 'Connected, powered, and staffed — running at full output.',
    fix: 'Keep it road-connected, powered, and the city well-staffed.',
    color: AppTheme.accent2,
  );
}

/// The status diagnosis plus this building's throughput, as a modal.
void showCitySiteDetail(
    BuildContext context, CitySim sim, String site, CityBuildingSpec spec) {
  final status = citySiteStatus(sim, site, spec);
  final io = <String>[
    // A tower's planetary effect, which no output line below says.
    ?TerraformTowers.effectOf(spec.type),
  ];
  // An idle building's throughput is what it makes NOW, not its nameplate.
  final idle = sim.idleForSky(spec);
  // A floor plant runs on its floor's rates, not the nameplate: a designed
  // floor makes what it was measured to make, and a firm's idled stations
  // make less. Its owner and books lead (docs/plans/factory-floors.md §4).
  final floor = sim.floorRatesAt(site, spec) == null
      ? const <String>[]
      : floorSiteLines(sim, site);
  if (floor.isNotEmpty) {
    io.addAll(floor);
  } else {
    spec.inputs.forEach(
        (k, v) => io.add('−${v.toStringAsFixed(1)} ${Commodity.name(k)}/s'));
    spec.outputs.forEach((k, v) => io
        .add('+${(idle ? 0.0 : v).toStringAsFixed(1)} ${Commodity.name(k)}/s'));
  }
  if (spec.powerOutput > 0) {
    io.add('+${spec.powerOutput.toStringAsFixed(0)} power');
  }
  if (floor.isEmpty) {
    if (spec.powerDraw > 0) {
      io.add('−${spec.powerDraw.toStringAsFixed(0)} power');
    }
    if (spec.jobs > 0) io.add('${spec.jobs} jobs');
  }
  if (spec.housing > 0) io.add('${spec.housing} housing');
  // Lead the WHY with the status diagnosis, then the IO stats so the modal
  // explains the flagged problem instead of just listing throughput.
  final stats = io.isEmpty ? 'A passive structure.' : io.join('\n');
  showExplain(context, '${spec.label} — ${status.label}',
      '${status.why}\n\n$stats', status.fix, status.color);
}

/// Tear down whatever stands on [site], whichever model placed it.
void demolishSite(CitySim sim, String site) {
  final cell = CitySim.cellOfSiteId(site);
  if (cell != null) {
    sim.clearCell(cell);
  } else {
    sim.clearParcel(site);
  }
  sim.recompute();
}

/// The action sheet for the building on [site]. [onChanged] rebuilds the host
/// after anything here mutates the colony.
void showCitySiteMenu({
  required BuildContext context,
  required CitySim sim,
  required String site,
  required CityBuildingSpec spec,
  required VoidCallback onChanged,
  CitySiteHooks hooks = const CitySiteHooks(),
}) {
  final status = citySiteStatus(sim, site, spec);
  final connected = sim.siteConnected(site);
  final actions = <Widget>[
    citySiteAction(
        context,
        Icons.info_outline,
        'Details',
        '${status.label} · ${connected ? "connected" : "cut off"}',
        status.color,
        () => showCitySiteDetail(context, sim, site, spec)),
  ];
  // Reactor easter egg: SCRAM the safeties for a meltdown.
  if (spec.type == 'reactor' || spec.type == 'fusion') {
    actions.add(gatedSiteAction(
        context,
        sim,
        Icons.warning_amber,
        'Disable safety systems',
        'Override the SCRAM interlocks. What could go wrong?',
        AppTheme.danger, () async {
      // Never a floor plant today, but the rule is the demolition's.
      if (!await confirmFloorLoss(context, sim, site)) return;
      sim.disaster = Disaster.nuke;
      sim.disasterTime = Disaster.nuke.duration;
      sim.radiation = (sim.radiation + 0.3).clamp(0.0, 1.0);
      demolishSite(sim, site); // the reactor is gone
      sim.attend(); // an act of governance (secession §3.3), if a rash one
      onChanged();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('☢ MELTDOWN — safety interlocks disabled. Oops.'),
          backgroundColor: Color(0xFF6B1414),
          duration: Duration(seconds: 4)));
      // It tears the reactor down (and the blast more), so a term that
      // forbids demolition forbids it as it does Demolish (secession §6.1).
    }, termRefusal: sim.demolitionRefusal));
  }
  // Spaceports + airfields are launch sites: enter the VAB to design a craft
  // and launch it (rockets from spaceports, spaceplanes from airfields).
  if ((spec.type == 'spaceport' || spec.type == 'airfield') &&
      hooks.onOpenVab != null) {
    final plane = spec.type == 'airfield';
    actions.add(gatedSiteAction(
        context,
        sim,
        Icons.precision_manufacturing,
        'Design & launch craft',
        connected
            ? 'Open the VAB; launch a ${plane ? "spaceplane" : "rocket"} from here.'
            : 'Connect this ${spec.label} to the road network first.',
        connected ? AppTheme.accent2 : AppTheme.textDim,
        connected ? hooks.onOpenVab! : () {}));
  }
  if (spec.type == 'spaceport') {
    // Spaceports double as landing pads: park the lander here (occupied state).
    final parked = sim.landerPad == site;
    actions.add(gatedSiteAction(
        context,
        sim,
        parked ? Icons.flight_takeoff : Icons.flight_land,
        parked ? 'Lander is parked here' : 'Land lander on this pad',
        parked
            ? 'Clear the pad for incoming shuttles.'
            : 'Move the landing site onto this spaceport (marks it occupied).',
        AppTheme.accent2, () {
      sim.landerPad = parked ? null : site;
      sim.attend();
      onChanged();
    }));
    // Point the craft the player is actually flying at this port's pads. This
    // is what "interact with the spaceport" means once you are already in the
    // world — the flat map's answer was to spawn a whole second scene.
    //
    // Deliberately live on a port that refuses the player (secession §5:
    // the player's own craft is not gated, and nothing holds it at a seized
    // pad yet), but it says the port is closed: the loyalty explainer tells
    // the player so, and an accent row with no word of it contradicted it.
    if (hooks.onTargetPad != null) {
      final why = hooks.targetPadHint;
      final closed = sim.loyalty.portHoldReason;
      actions.add(citySiteAction(
          context,
          Icons.my_location,
          'Target this pad',
          why ??
              (closed != null
                  ? 'Unwelcome — $closed. Your craft can still land here.'
                  : 'Aim your landing guidance at this spaceport and fly it '
                      'down.'),
          why != null
              ? AppTheme.textDim
              : (closed != null ? AppTheme.warn : AppTheme.accent2),
          why == null ? () => hooks.onTargetPad!(site) : () {}));
    }
    // Anti-soft-lock lifeline: call in a relief mission that lands on a free
    // pad, dwells 30 s + drops supplies + settlers, then leaves. Cooldown +
    // needs a free pad (a spaceport has one pad per footprint tile).
    final cd = sim.reliefCooldown.ceil();
    final hasPad = sim.freePad(site) != null;
    // A port the rebels hold, or an independent colony's, takes no relief
    // (secession §4.1): say so, rather than offer a button that refuses.
    final shut = sim.loyalty.portHoldReason;
    final canRelief = sim.reliefCooldown <= 0 && hasPad && shut == null;
    actions.add(gatedSiteAction(
        context,
        sim,
        Icons.volunteer_activism,
        canRelief
            ? 'Request assistance'
            : (shut != null
                ? 'Relief refused'
                : (!hasPad ? 'All pads busy' : 'Assistance on cooldown')),
        canRelief
            ? 'A relief craft lands here with food, water, ore, fuel, funds + 8 settlers.'
            : (shut != null
                ? 'No relief can land: $shut.'
                : (!hasPad
                    ? 'Every pad on this spaceport is occupied — wait for one to clear.'
                    : 'Recovering — available again in ${cd}s.')),
        canRelief ? AppTheme.accent2 : AppTheme.textDim, () {
      if (!canRelief) return;
      // Only a relief that flies is an act of governance (§3.3): a refused
      // request stamping attention would keep a standoff "attended" — the
      // condition for its recovery — by a button that does nothing.
      if (sim.requestRelief(site)) sim.attend();
      onChanged();
    }));
    // Recurring resource deliveries (a list — a starport runs several).
    final n = sim.deliveries[site]?.length ?? 0;
    // Suspended while the port is not the player's (secession §4.1) — said
    // here, in the logistics, and not only on the colony's HUD.
    final held = sim.loyalty.portHoldReason;
    actions.add(citySiteAction(
        context,
        Icons.local_shipping,
        n == 0 ? 'Schedule deliveries' : 'Deliveries ($n booked)',
        held != null
            ? 'Suspended — $held.'
            : (n == 0
                ? 'Book recurring resource deliveries to this spaceport.'
                : 'Manage, reorder + assign deliveries to pads.'),
        held != null ? AppTheme.danger : AppTheme.accent2,
        () => showDeliveryConfig(
            context: context, sim: sim, site: site, onChanged: onChanged)));
  }
  // A placed plant's factory floor (docs/plans/factory-floors.md §4): only
  // where a floor record exists, which only a placed floor plant has — a
  // zoned lot never qualifies.
  final rec = sim.factoryFloors[site];
  if (rec != null && hooks.onOpenFactoryFloor != null) {
    actions.add(gatedSiteAction(
        context,
        sim,
        Icons.precision_manufacturing,
        'Factory floor',
        rec.designed
            ? 'Open its floor: your design, live.'
            : 'Open its floor: the template layout, live. Design a better one.',
        AppTheme.accent,
        () => hooks.onOpenFactoryFloor!(site)));
  }
  // Who runs it (§7 Q9-Q11): nationalise a firm's plant, or privatise a
  // state one where the economy allows a buyer.
  // A CLOSED plant's offer comes first: its own options (nationalise, or
  // sell to a new firm where the economy has buyers), reachable from the
  // plant itself in every host, HUD or none.
  final offer =
      sim.pendingFirmOffers.where((o) => o.site == site).firstOrNull;
  if (rec != null && offer != null) {
    for (final o in offer.options) {
      actions.add(gatedSiteAction(
          context,
          sim,
          o == ClosureOption.nationalise
              ? Icons.account_balance
              : Icons.storefront,
          FirmOfferCard.label(o),
          o == ClosureOption.nationalise
              ? 'Its firm closed: run it as a state plant (its losses are '
                  'the industry deficit).'
              : 'Its firm closed: sell it to a new firm, which reopens it.',
          AppTheme.warn, () {
        if (sim.resolveFirmOffer(site, o)) sim.attend();
        onChanged();
      }));
    }
  } else if (rec != null) {
    final state = sim.ownerOf(site).isState;
    final communist = sim.economy == Economy.communism;
    if (!state || !communist) {
      actions.add(gatedSiteAction(
          context,
          sim,
          state ? Icons.storefront : Icons.account_balance,
          state ? 'Privatise' : 'Nationalise',
          state
              ? 'Sell it to a new firm: it pays corporate tax and runs to a '
                  'profit.'
              : 'Take it into state hands: its losses become the industry '
                  'deficit.',
          AppTheme.accent2, () {
        if (state ? sim.privatise(site) : sim.nationalise(site)) sim.attend();
        onChanged();
      }));
    }
  }
  if (hooks.extra != null) actions.addAll(hooks.extra!(site, spec));
  actions.add(gatedSiteAction(
      context, sim, Icons.delete, 'Demolish',
      sim.floorIsDesigned(site)
          ? 'Tear it down — its custom floor design is lost.'
          : 'Tear it down (partial ore refund).',
      AppTheme.danger, () async {
    // A designed floor is the player's work: asked first (§3 Persistence).
    if (!await confirmFloorLoss(context, sim, site)) return;
    demolishSite(sim, site);
    sim.attend();
    onChanged();
  }, termRefusal: sim.demolitionRefusal));

  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.panel,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Icon(spec.icon, color: spec.color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(spec.label,
                    style: AppTheme.heading.copyWith(color: spec.color)),
              ),
            ]),
            const SizedBox(height: 12),
            ...actions,
          ]),
        ),
      ),
    ),
  );
}

/// Delivery MANAGER for [site]: list every scheduled delivery, reorder
/// (priority), assign each to a pad, add new ones, remove. Lets a starport run
/// several deliveries in parallel across its pads.
void showDeliveryConfig({
  required BuildContext context,
  required CitySim sim,
  required String site,
  required VoidCallback onChanged,
}) {
  final padCount = sim.padCountOf(site);
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.panel,
    isScrollControlled: true,
    builder: (_) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final list = sim.deliveries[site] ?? const <DeliverySchedule>[];
        String padLabel(int? p) => p == null ? 'any pad' : 'pad ${p + 1}';
        // The schedule is the player's logistics, and stays readable; on a
        // colony that takes no orders (secession §5) it cannot be edited —
        // not least so a suspended run cannot be "re-enabled" by booking it
        // again — and says why.
        final control = sim.playerControl;
        final may = control.allowed;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Expanded(
                      child:
                          Text('DELIVERY SCHEDULE', style: AppTheme.heading)),
                  Text('$padCount pad${padCount == 1 ? "" : "s"}',
                      style: AppTheme.dim),
                ]),
                const SizedBox(height: 6),
                if (sim.loyalty.portHoldReason case final held?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                        'Suspended — $held. '
                        '${sim.loyalty.impounded.isEmpty ? '' : 'Impounded: ${sim.loyalty.impounded.map((c) => '${c.amount.toStringAsFixed(0)} ${c.resource}').join(', ')}.'}',
                        style: AppTheme.dim.copyWith(color: AppTheme.danger)),
                  ),
                if (!may)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(control.reason!,
                        style: AppTheme.dim.copyWith(color: AppTheme.danger)),
                  ),
                // Before the player cuts a standoff colony's runs: what
                // starving it costs (secession §6.3).
                if (sim.blockadeNote() case final b?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(b,
                        key: const ValueKey('delivery-blockade-note'),
                        style: AppTheme.dim.copyWith(color: AppTheme.warn)),
                  ),
                if (list.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('No deliveries booked.', style: AppTheme.dim),
                  ),
                // Reorderable list = dispatch priority.
                if (list.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: ReorderableListView(
                      shrinkWrap: true,
                      buildDefaultDragHandles: may,
                      // The index handed back already allows for the
                      // item taken out.
                      onReorderItem: (a, b) => setSheet(() {
                        if (!sim.mayAct()) return;
                        final s = list.removeAt(a);
                        list.insert(b, s);
                        sim.attend();
                        onChanged();
                      }),
                      children: [
                        for (var i = 0; i < list.length; i++)
                          ListTile(
                            key: ValueKey(list[i]),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Text('${i + 1}',
                                style: AppTheme.mono
                                    .copyWith(color: AppTheme.warn)),
                            title: Text(
                                '${list[i].resource} · ${list[i].amount.toStringAsFixed(0)}${list[i].resource == kDeliveryPeople ? " pax" : "u"}',
                                style: AppTheme.body),
                            subtitle: Text(
                                '${list[i].recurring ? "every ${list[i].intervalSec.toStringAsFixed(0)}s" : "one-time"} · ${padLabel(list[i].padIndex)}'
                                '${list[i].spareFuel ? " · self-fuel" : " · colony-fuel"}',
                                style: AppTheme.dim),
                            trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit,
                                        size: 18, color: AppTheme.accent2),
                                    tooltip: may ? 'Edit' : control.reason,
                                    onPressed: !may ? null : () => editDelivery(
                                        context: ctx,
                                        sim: sim,
                                        site: site,
                                        padCount: padCount,
                                        sched: list[i],
                                        onDone: () {
                                          setSheet(() {});
                                          onChanged();
                                        }),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete,
                                        size: 18, color: AppTheme.danger),
                                    tooltip: may ? 'Remove' : control.reason,
                                    onPressed: !may ? null : () => setSheet(() {
                                      list.removeAt(i);
                                      if (list.isEmpty) {
                                        sim.deliveries.remove(site);
                                      }
                                      sim.attend();
                                      onChanged();
                                    }),
                                  ),
                                ]),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add delivery'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accent2,
                      foregroundColor: AppTheme.bg),
                  onPressed: !may ? null : () => editDelivery(
                    context: ctx,
                    sim: sim,
                    site: site,
                    padCount: padCount,
                    isNew: true,
                    sched: DeliverySchedule(
                      resource: Commodity.food,
                      intervalSec: 30,
                      amount: 200,
                      spareFuel: true,
                      padIndex: null,
                      timer: 30,
                    ),
                    onDone: () {
                      setSheet(() {});
                      onChanged();
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// Editor for ONE delivery [sched] (resource / interval / amount-implied /
/// spare-fuel / pad). [isNew] appends it to [site]'s list on save.
void editDelivery({
  required BuildContext context,
  required CitySim sim,
  required String site,
  required int padCount,
  required DeliverySchedule sched,
  required VoidCallback onDone,
  bool isNew = false,
}) {
  var resource = sched.resource;
  var interval = sched.intervalSec;
  var spareFuel = sched.spareFuel;
  var recurring = sched.recurring;
  var padIndex = sched.padIndex;
  final amount = sched.amount;
  final returnFuel = sim.returnFuelFor(amount);
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.panel,
    isScrollControlled: true,
    builder: (_) => StatefulBuilder(
      builder: (ctx, setSheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isNew ? 'NEW DELIVERY' : 'EDIT DELIVERY',
                    style: AppTheme.heading),
                const SizedBox(height: 8),
                const Text('Resource', style: AppTheme.dim),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final r in CitySim.deliverable)
                    ChoiceChip(
                      label: Text(r, style: const TextStyle(fontSize: 11)),
                      selected: resource == r,
                      selectedColor: AppTheme.accent2,
                      backgroundColor: AppTheme.panelLight,
                      onSelected: (_) => setSheet(() => resource = r),
                    ),
                ]),
                const SizedBox(height: 10),
                // Recurring toggle: off (default) = a single one-time run; on =
                // repeats on the interval below.
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: AppTheme.accent2,
                  value: recurring,
                  onChanged: (v) => setSheet(() => recurring = v ?? false),
                  title: const Text('Recurring', style: AppTheme.body),
                  subtitle: Text(
                      recurring
                          ? 'Repeats automatically on the interval below.'
                          : 'One-time delivery — flies once, then clears.',
                      style: AppTheme.dim),
                ),
                if (recurring) ...[
                  Text('Every ${interval.toStringAsFixed(0)} s',
                      style: AppTheme.dim),
                  Slider(
                    value: interval,
                    min: 15,
                    max: 120,
                    divisions: 7,
                    onChanged: (v) => setSheet(() => interval = v),
                  ),
                ],
                const Text('Pad', style: AppTheme.dim),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  ChoiceChip(
                    label: const Text('Any', style: TextStyle(fontSize: 11)),
                    selected: padIndex == null,
                    selectedColor: AppTheme.accent2,
                    backgroundColor: AppTheme.panelLight,
                    onSelected: (_) => setSheet(() => padIndex = null),
                  ),
                  for (var p = 0; p < padCount; p++)
                    ChoiceChip(
                      label: Text('Pad ${p + 1}',
                          style: const TextStyle(fontSize: 11)),
                      selected: padIndex == p,
                      selectedColor: AppTheme.accent2,
                      backgroundColor: AppTheme.panelLight,
                      onSelected: (_) => setSheet(() => padIndex = p),
                    ),
                ]),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: AppTheme.accent2,
                  value: spareFuel,
                  onChanged: (v) => setSheet(() => spareFuel = v ?? true),
                  title: const Text('Craft carries spare fuel',
                      style: AppTheme.body),
                  subtitle: Text(
                      resource == kDeliveryPeople
                          ? (spareFuel
                              ? 'Brings ${amount.toStringAsFixed(0)} settlers; carries its own return fuel.'
                              : 'Brings ${amount.toStringAsFixed(0)} settlers; colony burns ${returnFuel.toStringAsFixed(0)} fuel+oxidizer for the return.')
                          : (spareFuel
                              ? 'Delivers ${(amount - returnFuel).clamp(0, amount).toStringAsFixed(0)}u (return fuel cut from cargo).'
                              : 'Delivers ${amount.toStringAsFixed(0)}u; colony burns ${returnFuel.toStringAsFixed(0)} fuel+oxidizer.'),
                      style: AppTheme.dim),
                ),
                const SizedBox(height: 6),
                ElevatedButton.icon(
                  icon: const Icon(Icons.check, size: 18),
                  label: Text(isNew ? 'Add' : 'Save'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accent2,
                      foregroundColor: AppTheme.bg),
                  onPressed: () {
                    // Asked again at the save: the colony may have left
                    // while the sheet was open.
                    if (!sim.mayAct((why) => sayRefused(context, why))) {
                      Navigator.of(ctx).pop();
                      return;
                    }
                    sched
                      ..resource = resource
                      ..intervalSec = interval
                      ..spareFuel = spareFuel
                      ..recurring = recurring
                      ..padIndex = padIndex;
                    if (isNew) {
                      // One-time runs dispatch promptly (short delay so the
                      // craft animation reads); recurring waits a full cycle.
                      sched.timer = recurring ? interval : 2.0;
                      (sim.deliveries[site] ??= []).add(sched);
                    }
                    sim.attend();
                    Navigator.of(ctx).pop();
                    onDone();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The colony's connected launch sites, as the VAB wants them.
///
/// Both hosts open the same VAB, so the mapping from "a spaceport that is
/// road-connected" to "a place a rocket can leave from" lives once.
List<LaunchSite> cityLaunchSites(CitySim sim) => [
      for (final (_, spec) in sim.launchSites())
        LaunchSite(
          name: spec.label,
          acceptsPlane: spec.type == 'airfield',
          pads: spec.cellCount, // one launch tower per footprint tile
        ),
    ];
