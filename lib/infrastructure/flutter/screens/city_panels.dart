// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The colony's READOUTS and levers — status, politics, stockpile, world — as a
/// mixin two different hosts can wear.
///
/// These panels used to be tabs inside the flat builder screen, which made that
/// screen the only place a colony could be governed: from the world you could
/// place a building but not tax it, read its power balance, or see why it was
/// starving. Anything real meant leaving the world through a "City panels"
/// button, and a button out of the world is an admission the world is not the
/// game.
///
/// As a mixin the same code serves the flat builder and the in-world editor.
/// Nothing here knows which one it is in: it reads [sim], and calls
/// [panelChanged] when the player moves a lever.
library;

import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/planetary/planet_surface.dart';
import '../../../domain/universe/celestial_body.dart';
import 'app_theme.dart';
import 'city_model.dart';
import 'city_site_actions.dart';

/// Panels over a colony. Mix into a [State]; supply the colony and a rebuild.
mixin CityPanels<T extends StatefulWidget> on State<T> {
  /// The colony these panels read and write.
  CitySim get sim;

  /// Called after a panel mutates the colony, so a host that is not driving the
  /// sim itself can still refresh. Implementations usually just `setState`.
  void panelChanged();

  /// Whether this host may re-site the colony — change the world it stands on,
  /// or the biome under it.
  ///
  /// True only where the colony is still being DESIGNED. In the world it is a
  /// live object standing at a real lat/lon on a real planet, drawn by the
  /// scene and ticked by the authoritative sim: swapping its body from a
  /// dropdown would teleport a town between planets mid-flight, and everything
  /// holding a reference to it would disagree about where it went. The rest of
  /// the world panel — warp, difficulty, the readouts — is safe either way.
  bool get panelCanResite => false;

  Widget _diffSlider(
          String label, double value, String hint, ValueChanged<double> onCh) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(label, style: AppTheme.body)),
            Text(
                value < 0.34 ? 'Low' : (value < 0.67 ? 'Medium' : 'High'),
                style: AppTheme.mono.copyWith(color: AppTheme.accent)),
          ]),
          SliderTheme(
            data: SliderThemeData(
                activeTrackColor: AppTheme.accent2,
                thumbColor: AppTheme.accent2,
                inactiveTrackColor: AppTheme.panelLight,
                trackHeight: 3),
            child: Slider(value: value, onChanged: onCh),
          ),
          Text(hint, style: AppTheme.dim.copyWith(fontSize: 11)),
        ]),
      );
  /// WORLD tab: time warp, host planet + biome, disasters, environment meters.
  List<Widget> cityWorldPanel() => [
        const Text('TIME WARP', style: AppTheme.heading),
        const SizedBox(height: 6),
        Row(children: [
          Text('${sim.timeWarp.toStringAsFixed(0)}×',
              style: AppTheme.mono.copyWith(color: AppTheme.accent)),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                  activeTrackColor: AppTheme.accent,
                  thumbColor: AppTheme.accent,
                  inactiveTrackColor: AppTheme.panelLight,
                  trackHeight: 3),
              child: Slider(
                  value: sim.timeWarp,
                  min: 1,
                  max: 20,
                  onChanged: (v) => setState(() => sim.timeWarp = v)),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        const Text('DIFFICULTY', style: AppTheme.heading),
        const SizedBox(height: 6),
        _diffSlider('Complexity', sim.complexity,
            'How many systems to manage (waste, oxygen, …)',
            (v) => setState(() => sim.complexity = v)),
        _diffSlider('Hostility', sim.hostility,
            'Frequency + severity of random disasters',
            (v) => setState(() => sim.hostility = v)),
        _diffSlider('Forgiveness', sim.forgiveness,
            'How much slack before citizens die / leave',
            (v) => setState(() => sim.forgiveness = v)),
        _diffSlider('Bounty', sim.bounty,
            'Resource production rate (higher = more abundant)',
            (v) => setState(() => sim.bounty = v)),
        const SizedBox(height: 6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: sim.infiniteRes,
          activeThumbColor: AppTheme.accent2,
          title: const Text('Infinite resources (debug)', style: AppTheme.body),
          subtitle: Text('Stockpiles never deplete — shows ∞, keeps live rates.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          onChanged: (v) => setState(() => sim.infiniteRes = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: sim.infiniteDemand,
          activeThumbColor: AppTheme.accent2,
          title: const Text('Infinite demand (debug)', style: AppTheme.body),
          subtitle: Text('RCI demand pinned to max — zones keep growing.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          onChanged: (v) => setState(() => sim.infiniteDemand = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: sim.infiniteRobotics,
          activeThumbColor: AppTheme.accent2,
          title: const Text('Infinite Robotics', style: AppTheme.body),
          subtitle: Text('Automated labour — buildings need no workers (full staffing).',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          onChanged: (v) => setState(() => sim.infiniteRobotics = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: sim.ignoreUnlocks,
          activeThumbColor: AppTheme.accent2,
          title: const Text('Ignore unlocks (debug)', style: AppTheme.body),
          subtitle: Text('Build anything regardless of the population requirement.',
              style: AppTheme.dim.copyWith(fontSize: 11)),
          onChanged: (v) => setState(() => sim.ignoreUnlocks = v),
        ),
        const SizedBox(height: 12),
        const Text('PLANET & BIOME', style: AppTheme.heading),
        const SizedBox(height: 6),
        _planetPanel(),
        const SizedBox(height: 12),
        const Text('WEATHER & DISASTERS', style: AppTheme.heading),
        const SizedBox(height: 6),
        _disasterControls(),
        const SizedBox(height: 12),
        const Text('ENVIRONMENT', style: AppTheme.heading),
        const SizedBox(height: 6),
        _pollutionRow(),
        _radiationRow(),
        if (sim.nuclearWinter > 0.02)
          _meterRow('Nuclear Winter',
              '${(sim.nuclearWinter * 100).toStringAsFixed(0)}%', sim.nuclearWinter,
              AppTheme.danger,
              warn: 'Sun blotted out — solar + crops failing.',
              onExplain: () => showExplain(context, 
                  'Nuclear Winter',
                  'Soot from a nuclear strike blots out the sun, crippling solar '
                      'power and freezing crops.',
                  'It clears over time. Build Terraforming Towers to clear it faster, '
                      'and lean on gas/nuclear power + stored food until it lifts.',
                  AppTheme.danger)),
        if (sim.terraform > 0.01 || sim.terraformers > 0)
          _meterRow('Terraforming', '${(sim.terraform * 100).toStringAsFixed(0)}%',
              sim.terraform, AppTheme.accent2),
      ];
  List<Widget> cityStatusPanel() => [
        const Text('COLONY STATUS', style: AppTheme.heading),
        const SizedBox(height: 8),
        _statRow('Population', '${sim.population.round()}'),
        _statRow('Housing', '${sim.housing}'),
        _statRow('Jobs', '${sim.jobs}'),
        _statRow('Homeless', '${sim.homeless}'),
        ..._mortalityStats(), // corpses + deaths = vital stats, not politics
        if (sim.grown.isNotEmpty) _utilisationRow(),
        _powerRow(),
        _computeRow(),
        _happinessRow(),
        if (sim.congestion > 0.02)
          _meterRow('Traffic congestion',
              '${(sim.congestion * 100).toStringAsFixed(0)}%', sim.congestion,
              sim.congestion > 0.6
                  ? AppTheme.danger
                  : (sim.congestion > 0.35 ? AppTheme.warn : AppTheme.accent2),
              warn: sim.congestion > 0.5
                  ? 'Gridlock — workers stuck commuting, staffing down ${((1 - (1 - sim.congestion * 0.4)) * 100).toStringAsFixed(0)}%.'
                  : null,
              onExplain: () => showExplain(context, 
                  'Traffic Congestion',
                  'Every connected building routes its workers to the hub along '
                      'the road network. The busiest tiles (the arteries near the '
                      'hub) carry the most trips. Heavy congestion means workers '
                      'spend longer travelling, so fewer effective worker-hours '
                      'reach the jobs — up to a 40% staffing penalty at full '
                      'gridlock.',
                  'Add more roads so traffic spreads over parallel routes instead '
                      'of funnelling through one street. Build transit stops to '
                      'take trips off the roads. Keep workplaces near housing.',
                  AppTheme.warn)),
        if (sim.wasteBacklog > 0.02)
          _meterRow('Waste backlog', '${(sim.wasteBacklog * 100).toStringAsFixed(0)}%',
              sim.wasteBacklog,
              sim.wasteBacklog > 0.5 ? AppTheme.danger : AppTheme.warn,
              warn: sim.wasteBacklog > 0.4
                  ? 'Garbage + sewage piling up — pollution + disease.'
                  : null,
              onExplain: () => showExplain(context, 
                  'Waste Backlog',
                  'Your population generates garbage + sewage every tick. When it '
                      'piles up faster than you process it, it pollutes the air and '
                      'spreads disease, dragging happiness.',
                  'Build Landfills (cheap), Recycling Centers (recover ore/steel), '
                      'and Sewage Treatment plants (recover water). Tap the Garbage / '
                      'Sewage chips for the exact balance.',
                  AppTheme.warn)),
        _pollutionRow(),
        _radiationRow(),
        const SizedBox(height: 12),
        const Text('ECONOMY', style: AppTheme.heading),
        const SizedBox(height: 6),
        _economyPicker(),
        const SizedBox(height: 6),
        _taxControl(),
        _statRow('Funds', '§${sim.funds.toStringAsFixed(0)}'),
        _statRow('Research', '${sim.research.toStringAsFixed(0)} pts'),
        const SizedBox(height: 12),
        const Text('RCI DEMAND', style: AppTheme.heading),
        const SizedBox(height: 6),
        _rciBar('Residential', sim.resTarget, const Color(0xFF7FE0A0)),
        _rciBar('Commercial', sim.comTarget, const Color(0xFF4FC3F7)),
        _rciBar('Industrial', sim.indTarget, const Color(0xFFE3A857)),
      ];
  List<Widget> cityPoliticsPanel() => [
        const Text('GOVERNMENT', style: AppTheme.heading),
        const SizedBox(height: 6),
        _govtPicker(),
        const SizedBox(height: 8),
        ..._lawRows(),
        const SizedBox(height: 12),
        const Text('SOCIETY', style: AppTheme.heading),
        const SizedBox(height: 6),
        if (sim.revoltMsg != null) _revoltBanner(),
        _socialBar('Crime', sim.crime, AppTheme.danger),
        _socialBar('Corruption', sim.corruption, const Color(0xFFB388FF)),
        _socialBar('Inequality', sim.inequality, const Color(0xFFE3A857)),
        _socialBar('Rebellion', sim.rebellion, AppTheme.danger),
        _socialBar('Disease', sim.disease, const Color(0xFF9CCC65)),
      ];
  /// Corpses + death-rate readout — a CITY metric (vital stats), not politics.
  ///
  /// Rows render whenever the colony is populated (not gated on the live value)
  /// so the panel doesn't THRASH as the death rate / corpse count crosses a
  /// threshold frame-to-frame — at zero they just sit dimmed.
  List<Widget> _mortalityStats() {
    if (sim.population < 1) return const [];
    final corpseAlarm = sim.corpses > sim.population * 0.05;
    final corpseColor =
        sim.corpses < 0.5 ? AppTheme.textDim : (corpseAlarm ? AppTheme.danger : AppTheme.warn);
    return [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Icon(Icons.dangerous, size: 14, color: corpseColor),
          const SizedBox(width: 6),
          const Expanded(
              child: Text('Corpses (unprocessed)', style: AppTheme.body)),
          Text(sim.corpses.toStringAsFixed(0),
              style: AppTheme.mono.copyWith(color: corpseColor)),
        ]),
      ),
      _statRow('Deaths', '${sim.deathRate.toStringAsFixed(2)}/s'),
      // Disease warning still appears only when the backlog is dangerous, but
      // it's the last line so toggling it can't shove the rows above it.
      if (sim.corpses > sim.population * 0.03 && sim.population > 10)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
              'Corpse backlog spreading disease — build morgues / crematoria.',
              style: AppTheme.dim.copyWith(color: AppTheme.danger)),
        ),
    ];
  }
  List<Widget> cityStockPanel() => [
        const Text('STOCKPILE', style: AppTheme.heading),
        const SizedBox(height: 2),
        Text('Rate is throttled output; (…) = full potential if fully staffed/'
            'powered.', style: AppTheme.dim),
        const SizedBox(height: 8),
        ..._stockRows(),
      ];
  String _biomeName(Biome b) => cityBiomeName(b);
  /// Short buff/debuff summary for the selected biome.
  String _biomeSummary() {
    final fx = sim.biomeFx;
    final bits = <String>[];
    void m(String label, double v) {
      if ((v - 1.0).abs() > 0.05) {
        bits.add('${v > 1 ? "+" : ""}${((v - 1) * 100).toStringAsFixed(0)}% $label');
      }
    }
    m('food', fx.food);
    m('water', fx.water);
    m('ore', fx.ore);
    m('solar', fx.solar);
    if (fx.happy.abs() > 0.005) {
      bits.add('${fx.happy > 0 ? "+" : ""}${(fx.happy * 100).toStringAsFixed(0)}% happy');
    }
    if (fx.scrub > 0.5) bits.add('cleans air');
    if (fx.scrub < -0.5) bits.add('dirties air');
    return bits.isEmpty ? 'Neutral terrain.' : bits.join(' · ');
  }
  void _triggerDisaster(Disaster d) => setState(() {
        sim.disaster = d;
        sim.disasterTime = d.duration;
      });
  Widget _disasterControls() {
    // Only offer disasters that make physical sense on this planet + biome
    // (airless worlds get no wind/rain; deserts don't snow; oceans don't burn).
    final all =
        Disaster.values.where((d) => d != Disaster.none && sim.disasterPossible(d));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(sim.hasWarning ? Icons.sensors : Icons.sensors_off,
            size: 14,
            color: sim.hasWarning ? AppTheme.accent2 : AppTheme.textDim),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            sim.hasWarning
                ? 'Early-warning online — disasters are forecast, prep your bunkers.'
                : 'No early-warning station — build one to forecast disasters.'
                    ' Bunkers + Emergency Services reduce harm.',
            style: AppTheme.dim.copyWith(
                color: sim.hasWarning ? AppTheme.accent2 : AppTheme.textDim),
          ),
        ),
      ]),
      const SizedBox(height: 6),
      if (sim.disaster != Disaster.none)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            Icon(sim.disaster.icon, size: 16, color: AppTheme.warn),
            const SizedBox(width: 6),
            Text('${sim.disaster.label} active (${sim.disasterTime.toStringAsFixed(0)}s)',
                style: AppTheme.dim.copyWith(color: AppTheme.warn)),
          ]),
        ),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final d in all)
          GestureDetector(
            onTap: () => _triggerDisaster(d),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: sim.disaster == d
                    ? AppTheme.warn
                    : (d == Disaster.nuke
                        ? AppTheme.danger.withValues(alpha: 0.2)
                        : AppTheme.panelLight),
                borderRadius: BorderRadius.circular(6),
                border: d == Disaster.nuke
                    ? Border.all(color: AppTheme.danger)
                    : null,
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(d.icon,
                    size: 13,
                    color: d == Disaster.nuke
                        ? AppTheme.danger
                        : (sim.disaster == d ? AppTheme.bg : AppTheme.text)),
                const SizedBox(width: 4),
                Text(d.label,
                    style: TextStyle(
                        fontSize: 11,
                        color: d == Disaster.nuke
                            ? AppTheme.danger
                            : (sim.disaster == d ? AppTheme.bg : AppTheme.text))),
              ]),
            ),
          ),
      ]),
    ]);
  }
  Widget _planetPanel() => Container(
        padding: const EdgeInsets.all(10),
        decoration: AppTheme.panelBox(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.public, size: 16, color: AppTheme.accent),
            const SizedBox(width: 6),
            const Text('Planet', style: AppTheme.body),
            const SizedBox(width: 8),
            if (!panelCanResite)
              Expanded(
                child: Text(sim.body.name,
                    style: AppTheme.body.copyWith(color: AppTheme.accent2)),
              ),
            if (panelCanResite)
              Expanded(
                child: DropdownButton<CelestialBody>(
                value: sim.body,
                isExpanded: true,
                dropdownColor: AppTheme.panelLight,
                underline: const SizedBox.shrink(),
                isDense: true,
                items: [
                  for (final b in sim.bodies)
                    DropdownMenuItem(
                        value: b, child: Text(b.name, style: AppTheme.body)),
                ],
                onChanged: (b) => setState(() => sim.body = b!),
                ),
              ),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            const Icon(Icons.terrain, size: 16, color: AppTheme.accent2),
            const SizedBox(width: 6),
            const Text('Biome', style: AppTheme.body),
            const SizedBox(width: 8),
            if (!panelCanResite)
              Expanded(
                child: Text(_biomeName(sim.biome),
                    style: AppTheme.body.copyWith(color: AppTheme.accent2)),
              ),
            if (panelCanResite)
              Expanded(
                child: DropdownButton<Biome>(
                  value: sim.biome,
                  isExpanded: true,
                  dropdownColor: AppTheme.panelLight,
                  underline: const SizedBox.shrink(),
                  isDense: true,
                  items: [
                    for (final b in Biome.values)
                      DropdownMenuItem(
                          value: b,
                          child: Text(_biomeName(b), style: AppTheme.body)),
                  ],
                  onChanged: (b) => setState(() => sim.biome = b!),
                ),
              ),
          ]),
          Text(_biomeSummary(), style: AppTheme.dim.copyWith(fontSize: 11)),
          const SizedBox(height: 4),
          Wrap(spacing: 14, runSpacing: 4, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.solar_power, size: 14, color: Color(0xFFFFD23F)),
              const SizedBox(width: 4),
              Text('Solar ×${sim.solarFactor.toStringAsFixed(2)}',
                  style: AppTheme.mono.copyWith(
                      color: sim.solarFactor >= 1 ? AppTheme.accent2 : AppTheme.warn,
                      fontSize: 12)),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.wind_power, size: 14, color: Color(0xFFB2DFDB)),
              const SizedBox(width: 4),
              Text('Wind ×${sim.windFactor.toStringAsFixed(2)}',
                  style: AppTheme.mono.copyWith(
                      color:
                          sim.windFactor >= 0.5 ? AppTheme.accent2 : AppTheme.warn,
                      fontSize: 12)),
            ]),
          ]),
          if (sim.windFactor < 0.05)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('Airless world — wind turbines are useless here.',
                  style: AppTheme.dim.copyWith(color: AppTheme.warn)),
            ),
          const SizedBox(height: 2),
          Row(children: [
            Icon(sim.breathable ? Icons.air : Icons.masks,
                size: 14,
                color: sim.breathable ? AppTheme.accent2 : AppTheme.warn),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                sim.breathable
                    ? 'Breathable air (O₂ ${(sim.o2Fraction * 100).toStringAsFixed(0)}%) — oxygen free.'
                    : sim.o2Harvestable
                        ? 'Thin O₂ (${(sim.o2Fraction * 100).toStringAsFixed(0)}%) — harvest or split water.'
                        : 'No breathable O₂ — split water (electrolysis) or shuttle in.',
                style: AppTheme.dim.copyWith(
                    color: sim.breathable ? AppTheme.accent2 : AppTheme.warn,
                    fontSize: 11),
              ),
            ),
          ]),
          const Divider(height: 14, color: Color(0xFF223247)),
          _surfaceReadout(),
        ]),
      );
  /// Live physical surface-conditions readout (temp / pressure / water /
  /// habitability) — the scalars that drive flora + colony style.
  Widget _surfaceReadout() {
    final s = sim.surface;
    final hab = s.habitability;
    final habCol = hab > 0.6
        ? AppTheme.accent2
        : (hab > 0.3 ? AppTheme.warn : AppTheme.danger);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.thermostat, size: 14, color: AppTheme.textDim),
        const SizedBox(width: 4),
        Text('SURFACE — ${s.summary}',
            style: AppTheme.dim.copyWith(
                color: habCol, fontWeight: FontWeight.bold, fontSize: 11)),
      ]),
      const SizedBox(height: 4),
      Wrap(spacing: 12, runSpacing: 2, children: [
        _condChip('Temp', '${s.temperatureC.toStringAsFixed(0)}°C'),
        _condChip('Press', '${(s.pressureAtm).toStringAsFixed(2)} atm'),
        _condChip('Water', '${(s.waterActivity * 100).toStringAsFixed(0)}%'),
        _condChip('Aquifer', '${(sim.waterTable * 100).toStringAsFixed(0)}%'),
        _condChip('Grav', '${s.gravityG.toStringAsFixed(2)}g'),
      ]),
      if (sim.waterTable < 0.4)
        Text('Water table low — pumping is drying the surface; plants dying back.',
            style: AppTheme.dim.copyWith(
                color: sim.waterTable < 0.2 ? AppTheme.danger : AppTheme.warn,
                fontSize: 11)),
      const SizedBox(height: 4),
      ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
            value: hab,
            minHeight: 6,
            backgroundColor: AppTheme.panelLight,
            color: habCol),
      ),
      const SizedBox(height: 2),
      Text('Habitability ${(hab * 100).toStringAsFixed(0)}% — '
          '${hab > 0.5 ? "plants thrive" : hab > 0.15 ? "sparse life" : "barren; terraform to grow life"}',
          style: AppTheme.dim.copyWith(fontSize: 11, color: habCol)),
      const SizedBox(height: 4),
      Builder(builder: (_) {
        final l = sim.liquid;
        return Row(children: [
          Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                  color: Color(l.colorArgb),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: const Color(0x33FFFFFF)))),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                'Surface liquid: ${l.label}'
                '${l.isMolten ? " (molten — lethal)" : l.combustible ? " (fuel)" : l.potable ? " (drinkable)" : ""}'
                '${sim.oceanPollution > 0.05 ? " · polluted" : ""}',
                style: AppTheme.dim.copyWith(fontSize: 11)),
          ),
        ]);
      }),
    ]);
  }
  Widget _condChip(String label, String value) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label ', style: AppTheme.dim.copyWith(fontSize: 11)),
          Text(value,
              style: AppTheme.mono.copyWith(fontSize: 11, color: AppTheme.text)),
        ],
      );
  List<Widget> _stockRows() {
    final cap = sim.stockCap;
    final rates = netRates();
    final raw = netRates(throttled: false);
    bool show(String c) =>
        sim.stockOf(c) > 0.05 ||
        (rates[c]?.abs() ?? 0) > 0.05 ||
        c == Commodity.ore ||
        c == Commodity.food ||
        c == Commodity.water;
    final out = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          const Expanded(child: Text('Capacity / resource', style: AppTheme.dim)),
          Text(cap.toStringAsFixed(0),
              style: AppTheme.mono.copyWith(color: AppTheme.accent)),
        ]),
      ),
    ];
    // Group by section: Raw Resources / Components / Finished Goods.
    for (final section in Commodity.sections) {
      final inSection = Commodity.ordered
          .where((c) => Commodity.section(c) == section && show(c))
          .toList();
      if (inSection.isEmpty) continue;
      out.add(Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Text(section,
            style: AppTheme.dim.copyWith(
                color: AppTheme.accent,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.6)),
      ));
      for (final c in inSection) {
        out.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(Commodity.name(c), style: AppTheme.body)),
            Text('${sim.stockOf(c).toStringAsFixed(0)}/${cap.toStringAsFixed(0)}',
                style: AppTheme.mono.copyWith(
                    color: sim.stockOf(c) >= cap - 0.5
                        ? AppTheme.warn
                        : sim.stockOf(c) > 0
                            ? AppTheme.text
                            : AppTheme.textDim)),
            SizedBox(
              width: 96,
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: fmtRate(rates[c] ?? 0),
                      style: AppTheme.mono.copyWith(
                          fontSize: 11,
                          color: (rates[c] ?? 0) >= 0
                              ? AppTheme.accent2
                              : AppTheme.warn)),
                  if (((raw[c] ?? 0) - (rates[c] ?? 0)).abs() > 0.05)
                    TextSpan(
                        text: ' (${fmtRate(raw[c] ?? 0)})',
                        style: AppTheme.mono.copyWith(
                            fontSize: 10, color: AppTheme.textDim)),
                ]),
                textAlign: TextAlign.right,
              ),
            ),
          ]),
        ));
      }
    }
    return out;
  }
  /// Net rates. [throttled] true applies the live production throttle (power /
  /// compute / staffing); false gives the full nameplate potential. Life-support
  /// consumption is the same in both.
  Map<String, double> netRates({bool throttled = true}) {
    final t = throttled ? sim.throttle : 1.0;
    final r = <String, double>{};
    for (final e in sim.activeSpecs) {
      e.value.outputs.forEach((k, v) => r[k] = (r[k] ?? 0) + v * t);
      e.value.inputs.forEach((k, v) => r[k] = (r[k] ?? 0) - v * t);
    }
    r[Commodity.food] = (r[Commodity.food] ?? 0) - sim.population * CitySim.foodPerPersonPerSec;
    r[Commodity.water] = (r[Commodity.water] ?? 0) - sim.population * CitySim.waterPerPersonPerSec;
    if (!sim.breathable) {
      r[Commodity.oxygen] =
          (r[Commodity.oxygen] ?? 0) - sim.population * CitySim.waterPerPersonPerSec;
    }
    // Population GENERATES waste (positive net = it's piling up).
    r[Commodity.garbage] =
        (r[Commodity.garbage] ?? 0) + sim.population * CitySim.garbagePerPersonPerSec;
    r[Commodity.sewage] =
        (r[Commodity.sewage] ?? 0) + sim.population * CitySim.sewagePerPersonPerSec;
    return r;
  }
  String fmtRate(double r) =>
      r.abs() < 0.05 ? '±0/s' : '${r >= 0 ? "+" : ""}${r.toStringAsFixed(1)}/s';
  /// Per-building producer/consumer breakdown for a commodity (counts + total
  /// throttled rate per building type).
  ({List<({String label, double rate, int count})> producers,
    List<({String label, double rate, int count})> consumers,
    double lifeSupport}) _commodityBreakdown(String c) {
    final prod = <String, ({double rate, int count})>{};
    final cons = <String, ({double rate, int count})>{};
    for (final e in sim.activeSpecs) {
      final s = e.value;
      final out = (s.outputs[c] ?? 0) * sim.biomeMult(c) * sim.throttle;
      final inp = (s.inputs[c] ?? 0) * sim.throttle;
      if (out > 0) {
        final cur = prod[s.label];
        prod[s.label] =
            (rate: (cur?.rate ?? 0) + out, count: (cur?.count ?? 0) + 1);
      }
      if (inp > 0) {
        final cur = cons[s.label];
        cons[s.label] =
            (rate: (cur?.rate ?? 0) + inp, count: (cur?.count ?? 0) + 1);
      }
    }
    var life = 0.0;
    if (c == Commodity.food) life = sim.population * CitySim.foodPerPersonPerSec;
    if (c == Commodity.water) life = sim.population * CitySim.waterPerPersonPerSec;
    if (c == Commodity.oxygen && !sim.breathable) {
      life = sim.population * CitySim.waterPerPersonPerSec;
    }
    List<({String label, double rate, int count})> rows(
            Map<String, ({double rate, int count})> m) =>
        [for (final e in m.entries) (label: e.key, rate: e.value.rate, count: e.value.count)]
          ..sort((a, b) => b.rate.compareTo(a.rate));
    return (producers: rows(prod), consumers: rows(cons), lifeSupport: life);
  }
  /// Full producer/consumer breakdown for one commodity.
  void showResourceDetail(String c) {
    final bd = _commodityBreakdown(c);
    final net = netRates()[c] ?? 0;
    final raw = netRates(throttled: false)[c] ?? 0;
    final cap = sim.stockCap;
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: AppTheme.panel,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(Commodity.name(c),
                    style: AppTheme.title.copyWith(
                        color: AppTheme.accent, fontSize: 18)),
                const SizedBox(height: 2),
                Text('Section: ${Commodity.section(c)}', style: AppTheme.dim),
                const SizedBox(height: 12),
                _kvLine('In stock', '${sim.stockOf(c).toStringAsFixed(0)} / ${cap.toStringAsFixed(0)}'),
                _kvLine('Net rate',
                    fmtRate(net) + (((raw - net).abs() > 0.05) ? '  (potential ${fmtRate(raw)})' : ''),
                    net >= 0 ? AppTheme.accent2 : AppTheme.warn),
                if (raw - net > 0.05)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                        'Production throttled to ${(sim.throttle * 100).toStringAsFixed(0)}% — '
                        '${_bottleneckName()} is the limiter.',
                        style: AppTheme.dim.copyWith(color: AppTheme.warn)),
                  ),
                const SizedBox(height: 14),
                _detailSection('PRODUCED BY', bd.producers, AppTheme.accent2),
                _detailSection('CONSUMED BY', bd.consumers, AppTheme.warn),
                if (bd.lifeSupport > 0.001)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      const Expanded(
                          child: Text('Population life support', style: AppTheme.body)),
                      Text('-${bd.lifeSupport.toStringAsFixed(1)}/s',
                          style: AppTheme.mono.copyWith(color: AppTheme.warn)),
                    ]),
                  ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: AppTheme.bg,
                      borderRadius: BorderRadius.circular(6)),
                  child: Text(_howToGrow(c), style: AppTheme.dim),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('CLOSE'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  Widget _detailSection(
      String title, List<({String label, double rate, int count})> rows,
      Color color) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style: AppTheme.dim.copyWith(
              color: color, fontSize: 10, fontWeight: FontWeight.bold)),
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text('${r.label} ×${r.count}', style: AppTheme.body)),
            Text('${r.rate >= 0 ? "+" : ""}${r.rate.toStringAsFixed(1)}/s',
                style: AppTheme.mono.copyWith(color: color)),
          ]),
        ),
      const SizedBox(height: 8),
    ]);
  }
  Widget _kvLine(String k, String v, [Color? c]) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(k, style: AppTheme.body)),
          Text(v, style: AppTheme.mono.copyWith(color: c ?? AppTheme.text)),
        ]),
      );
  Widget _powerRow() {
    final ratio = sim.powerDraw <= 0 ? 1.0 : (sim.powerOut / sim.powerDraw).clamp(0.0, 1.0);
    final ok = ratio >= 1.0;
    return _meterRow('Power', '${sim.powerOut.toStringAsFixed(0)} / ${sim.powerDraw.toStringAsFixed(0)}',
        ratio, ok ? AppTheme.accent2 : AppTheme.danger,
        warn: ok ? null : 'Brownout — production throttled.',
        onExplain: () => showExplain(context, 
            'Power Grid',
            ok
                ? 'Generation (${sim.powerOut.toStringAsFixed(0)}) meets demand '
                    '(${sim.powerDraw.toStringAsFixed(0)}).'
                : 'Demand (${sim.powerDraw.toStringAsFixed(0)}) exceeds generation '
                    '(${sim.powerOut.toStringAsFixed(0)}). Every building throttles to the '
                    'grid ratio, cutting all production.',
            'Build more power: Solar (sun-dependent), Wind (air-dependent), Gas '
                '(burns fuel), Reactor or Fusion (unlock with population). On dark/'
                'airless worlds favour gas + nuclear.',
            ok ? AppTheme.accent2 : AppTheme.danger));
  }
  /// Average grown-zone utilisation + a count of buildings still under
  /// construction. Tappable for a breakdown of the small/med/large/max stages.
  Widget _utilisationRow() {
    var sum = 0.0, building = 0;
    final stages = <String, int>{};
    for (final k in sim.grown) {
      if (sim.zones[k] == null) continue;
      sum += sim.utilFactor(k);
      if (sim.underConstruction(k)) building++;
      stages.update(sim.utilStage(k), (v) => v + 1, ifAbsent: () => 1);
    }
    final avg = sim.grown.isEmpty ? 0.0 : sum / sim.grown.length;
    final label = building > 0 ? '$building building' : '${(avg * 100).round()}% avg';
    return _meterRow('Utilisation', label, avg, AppTheme.accent2,
        onExplain: () => showExplain(context, 
            'Building Utilisation',
            'Zoned buildings rise through a construction phase, then fill up in '
                'stages — Small → Medium → Large → Max — as demand sustains them, '
                'and shrink back when demand fades. A building only contributes '
                'its housing / jobs / services in proportion to how occupied it '
                'is.\n\nCurrent mix: '
                '${stages.entries.map((e) => '${e.value} ${e.key}').join(', ')}.',
            'Keep demand high (balance R/C/I), power on, and roads connected so '
                'buildings finish construction and climb to Max occupancy.',
            AppTheme.accent2));
  }
  Widget _computeRow() {
    if (sim.computeDemand <= 0 && sim.computeSupply <= 0) return const SizedBox.shrink();
    final ratio = sim.computeDemand <= 0 ? 1.0 : (sim.computeSupply / sim.computeDemand).clamp(0.0, 1.0);
    final ok = ratio >= 1.0;
    return _meterRow('Compute', '${sim.computeSupply.toStringAsFixed(0)} / ${sim.computeDemand.toStringAsFixed(0)}',
        ratio, ok ? AppTheme.accent : AppTheme.danger,
        warn: ok ? null : 'Compute shortfall — advanced buildings throttled.');
  }
  Widget _pollutionRow() {
    final level = (sim.pollution / 200).clamp(0.0, 1.0);
    final c = level > 0.6 ? AppTheme.danger : (level > 0.3 ? AppTheme.warn : AppTheme.accent2);
    return _meterRow('Pollution', sim.pollution.toStringAsFixed(0), level, c,
        warn: level > 0.5 ? 'Atmosphere degrading — happiness + health hit.' : null,
        onExplain: () => showExplain(context, 
            'Pollution',
            'Industry, power plants and dense zones emit pollution into the '
                'atmosphere. High pollution drags happiness and breeds disease.',
            'Add Parks and Forest biome (scrub the air), pass the Emissions Cap '
                'ordinance, build Terraforming Towers (negative pollution), or replace '
                'dirty industry/gas with clean power (solar/wind/fusion).',
            c));
  }
  Widget _radiationRow() {
    if (sim.radiation <= 0.02) return const SizedBox.shrink();
    return _meterRow('Radiation', '${(sim.radiation * 100).toStringAsFixed(0)}%',
        sim.radiation, sim.radiation > 0.4 ? AppTheme.danger : AppTheme.warn,
        warn: sim.radiation > 0.4 ? 'Radiation sickness killing citizens.' : null,
        onExplain: () => showExplain(context, 
            'Radiation',
            'Comes from thin-atmosphere worlds (less air = more space '
                'radiation), solar storms, and nuclear fallout. It causes '
                'radiation sickness (disease + deaths).',
            'It decays on its own. Thicken the atmosphere (terraforming) for '
                'less background radiation, and shelter the population in '
                'Bunkers / Fallout Shelters during events.',
            AppTheme.danger));
  }
  Widget _meterRow(String label, String value, double ratio, Color color,
          {String? warn, VoidCallback? onExplain}) =>
      GestureDetector(
        onTap: onExplain,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(label, style: AppTheme.body)),
              if (onExplain != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(Icons.info_outline,
                      size: 13, color: color.withValues(alpha: 0.7)),
                ),
              Text(value, style: AppTheme.mono.copyWith(color: color)),
            ]),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                  value: ratio.clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: AppTheme.panelLight,
                  color: color),
            ),
            if (warn != null)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(warn, style: AppTheme.dim.copyWith(color: color)),
              ),
          ]),
        ),
      );
  Widget _happinessRow() {
    final h = sim.happiness;
    final col = h >= 0.66 ? AppTheme.accent2 : (h >= 0.33 ? AppTheme.warn : AppTheme.danger);
    final face = h >= 0.66
        ? Icons.sentiment_very_satisfied
        : (h >= 0.33 ? Icons.sentiment_neutral : Icons.sentiment_very_dissatisfied);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(face, size: 16, color: col),
          const SizedBox(width: 6),
          const Expanded(child: Text('Happiness', style: AppTheme.body)),
          Text('${(h * 100).toStringAsFixed(0)}%',
              style: AppTheme.mono.copyWith(color: col)),
        ]),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
              value: h, minHeight: 6,
              backgroundColor: AppTheme.panelLight, color: col),
        ),
      ]),
    );
  }
  Widget _economyPicker() => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final e in Economy.values)
            _pill(e.label, sim.economy == e, AppTheme.accent,
                () => setState(() => sim.economy = e)),
        ],
      );
  Widget _govtPicker() => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final g in Govt.values)
            _pill(g.label, sim.govt == g, AppTheme.accent2, () => setState(() {
                  sim.govt = g;
                  if (g.lawsAutoVoted) sim.autoVote();
                })),
        ],
      );
  Widget _pill(String label, bool sel, Color color, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
              color: sel ? color : AppTheme.panelLight,
              borderRadius: BorderRadius.circular(6)),
          child: Text(label,
              style: TextStyle(fontSize: 12, color: sel ? AppTheme.bg : AppTheme.text)),
        ),
      );
  Widget _taxControl() {
    final controllable = sim.economy.taxControllable;
    final tax = sim.effectiveTax();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
              onChanged: controllable ? (v) => setState(() => sim.taxRate = v) : null),
        ),
      ]),
    );
  }
  List<Widget> _lawRows() {
    final auto = sim.govt.lawsAutoVoted;
    return [
      Text(
          auto
              ? '${sim.govt.label}: laws are auto-voted to address the worst problems.'
              : 'Enact ordinances directly:',
          style: AppTheme.dim),
      const SizedBox(height: 4),
      for (final l in Law.values)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(children: [
            Icon(sim.laws.contains(l) ? Icons.check_box : Icons.check_box_outline_blank,
                size: 17,
                color: sim.laws.contains(l) ? AppTheme.accent2 : AppTheme.textDim),
            const SizedBox(width: 6),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.label, style: AppTheme.body),
                Text(l.effect, style: AppTheme.dim),
              ]),
            ),
            if (!auto)
              Switch(
                  value: sim.laws.contains(l),
                  activeThumbColor: AppTheme.accent2,
                  onChanged: (v) =>
                      setState(() => v ? sim.laws.add(l) : sim.laws.remove(l))),
          ]),
        ),
    ];
  }
  Widget _revoltBanner() => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            color: AppTheme.danger.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.danger)),
        child: Row(children: [
          const Icon(Icons.local_fire_department, color: AppTheme.danger, size: 18),
          const SizedBox(width: 8),
          Expanded(
              child: Text(sim.revoltMsg!,
                  style: AppTheme.dim.copyWith(color: AppTheme.danger))),
          GestureDetector(
            onTap: () => setState(() => sim.revoltMsg = null),
            child: const Icon(Icons.close, color: AppTheme.danger, size: 16),
          ),
        ]),
      );
  Widget _socialBar(String label, double value, Color color) {
    final alarm = value > 0.5;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(width: 84, child: Text(label, style: AppTheme.body)),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
                value: value, minHeight: 8,
                backgroundColor: AppTheme.panelLight,
                color: alarm ? AppTheme.danger : color),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 34,
          child: Text('${(value * 100).toStringAsFixed(0)}%',
              textAlign: TextAlign.right,
              style: AppTheme.mono.copyWith(
                  fontSize: 11, color: alarm ? AppTheme.danger : color)),
        ),
      ]),
    );
  }
  Widget _rciBar(String label, double value, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(width: 84, child: Text(label, style: AppTheme.body)),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                  value: value, minHeight: 9,
                  backgroundColor: AppTheme.panelLight, color: color),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 36,
            child: Text('${(value * 100).toStringAsFixed(0)}%',
                textAlign: TextAlign.right,
                style: AppTheme.mono.copyWith(color: color)),
          ),
        ]),
      );
  Widget _statRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(k, style: AppTheme.body)),
          Text(v, style: AppTheme.mono),
        ]),
      );

  String _bottleneckName() {
    final power = sim.powerDraw <= 0 ? 1.0 : (sim.powerOut / sim.powerDraw).clamp(0.0, 1.0);
    final compute = sim.computeDemand <= 0 ? 1.0 : (sim.computeSupply / sim.computeDemand).clamp(0.0, 1.0);
    if (sim.staffing <= power && sim.staffing <= compute) return 'staffing (not enough workers)';
    if (power <= compute) return 'power (brownout)';
    return 'compute (data shortfall)';
  }
  String _howToGrow(String c) => switch (c) {
        Commodity.ore => 'Build more Mines. Heavy Industry zones also refine ore→steel.',
        Commodity.steel => 'Build Steel Mills (need ore) or zone Industrial.',
        Commodity.water => 'Build Water Plants; biome + rain boost it.',
        Commodity.food => 'Build Farms (need water). Avoid nuclear winter.',
        Commodity.oxygen => sim.breathable
            ? 'Breathable world — oxygen is free here.'
            : 'Build Electrolysis Plants (split water) or an O₂ Harvester.',
        Commodity.electronics => 'Build Electronics Plants (need steel + compute).',
        Commodity.compute => 'Build Data Centers (need electronics + lots of power).',
        Commodity.tubes => 'Steel Mills produce tubes as a byproduct.',
        Commodity.rocketParts => 'Build a Rocket Parts Factory (tubes + electronics).',
        Commodity.fuel || Commodity.oxidizer => 'Build Refineries (need ore).',
        Commodity.guns || Commodity.ammo => 'Build an Arms Factory (steel + electronics).',
        Commodity.missiles => 'Build a Missile Plant (tubes + rocket parts).',
        Commodity.rations => 'Build a Rations Plant (need food).',
        Commodity.medicine =>
          'Build Chemists (small) or a Pharma Plant (big). Hospitals + Clinics '
              'consume it; without medicine their health coverage drops.',
        Commodity.garbage =>
          'This is WASTE — keep it near zero. Build Landfills (cheap) or Recycling '
              'Centers (recover ore + steel) to consume it faster than the population '
              'produces it.',
        Commodity.sewage =>
          'This is WASTE — build Sewage Treatment plants to process it (they also '
              'recover clean water). A backlog pollutes + spreads disease.',
        _ => 'Build the matching factory; ensure power, compute + staffing are met.',
      };
}
