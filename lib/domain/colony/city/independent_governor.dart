// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// How an independent colony runs itself (docs/plans/colony-secession.md §4).
///
/// Once a colony has seceded the player's hand is off it (the control gate,
/// `city_control.dart`), and the sim's self-correction — population settling
/// at what it can supply, the tax revolt, laws that vote themselves — keeps
/// it from dying, but nothing BUILDS: a town that outgrows its farm would
/// starve politely to the size the farm feeds, and one with no landfill
/// would drown in its own rubbish. The governor is the colony's own council:
/// every few colony days it
///
///  1. votes its laws (the auto-vote every self-governing colony runs);
///  2. sets the tax to the highest rate that keeps the mood at 0.5;
///  3. if food, water or (where people breathe what is made) oxygen run
///     short, builds the cheapest life-support building it can afford;
///  4. past the waste or corpse lines with no landfill or deathcare, builds
///     one;
///  5. otherwise zones a couple of free lots, the use the RCI demand asks for
///     most.
///
/// Deliberately dumb: one build a sitting, cheapest first, never a road,
/// never a demolition, and never a coin or a lump of ore it does not have.
/// The point is a colony that stays alive and grows slowly — one worth
/// winning back — not a second player.
///
/// Deterministic and stateless: a sitting falls on every [periodDays]
/// boundary since the declaration, read off the saved loyalty clock, so a
/// save and a load sit on the same days, and one warped step that spans a
/// boundary sits once — as many small steps over the same span would — not
/// once per boundary crossed (it is a council, not an integrator: a sitting
/// that saw a shortage would see it again at the next). The log of what it
/// did is display state, kept beside the colony and not saved.
library;

import 'dart:math' as math;

import 'city_building_spec.dart';
import 'city_loyalty.dart';
import 'city_sim.dart';
import 'commodity.dart';
import 'parcel.dart';

/// The governor's knobs, in loyalty-calendar days (the 120 s Earth day every
/// loyalty readout counts in, [CityLoyaltyTuning.daySec]).
class IndependentGovernorTuning {
  const IndependentGovernorTuning({
    this.periodDays = 3,
    this.oreReserve = 10,
    this.zonePerSitting = 2,
    this.maxPendingZones = 2,
    this.wasteLine = 0.3,
    this.corpseShare = 0.02,
    this.corpseMin = 3,
    this.bearableMood = 0.5,
    this.taxStep = 0.05,
    this.maxTax = 0.4,
    this.maxSiteChecks = 400,
  });

  /// Days between sittings.
  final double periodDays;

  /// Ore a build must leave in the store: the governor never spends its
  /// last lump, so a colony is never left unable to answer the next fire.
  final double oreReserve;

  /// Lots zoned at a sitting, at most.
  final int zonePerSitting;

  /// Zoned lots still waiting to grow past which it zones no more: demand
  /// zones lots faster than settlers fill them, and a governor that zoned on
  /// every sitting regardless would paint the whole plat in a year.
  final int maxPendingZones;

  /// The waste backlog (0..1) past which it wants a landfill.
  final double wasteLine;

  /// Unburied dead, as a share of the living (and at least [corpseMin]),
  /// past which it wants deathcare.
  final double corpseShare;
  final double corpseMin;

  /// The mood the tax is set to hold.
  final double bearableMood;

  /// The most the tax moves at one sitting, either way, and its ceiling —
  /// the slider's.
  final double taxStep;
  final double maxTax;

  /// Candidate sites tried for a building that stakes out its own plot
  /// (a farm, a landfill), at most, per build: a bound on the sitting's cost.
  final int maxSiteChecks;
}

/// What a sitting did.
enum GovernorActKind { laws, tax, lifeSupport, waste, deathcare, zone }

/// One line of the governor's log.
class GovernorAct {
  const GovernorAct(this.kind, this.text, this.atS, {this.oreSpent = 0});
  final GovernorActKind kind;
  final String text;

  /// [CityLoyalty.colonyTimeS] of the sitting.
  final double atS;

  /// Ore the act spent (0 for a vote, a tax or a zoning).
  final double oreSpent;
}

final Expando<IndependentGovernorTuning> _tunings =
    Expando('governorTuning');
final Expando<List<GovernorAct>> _logs = Expando('governorLog');

/// The governor on the colony.
extension IndependentGovernorSim on CitySim {
  /// Configuration, not state (like [CityLoyalty.tuning]): not saved.
  IndependentGovernorTuning get governorTuning =>
      _tunings[this] ?? const IndependentGovernorTuning();
  set governorTuning(IndependentGovernorTuning t) => _tunings[this] = t;

  /// What the governor has done, newest last (bounded; not saved).
  List<GovernorAct> get governorLog => _logs[this] ??= <GovernorAct>[];

  static const int _maxLog = 24;

  /// The governor's part of a tick: a sitting when the tick crosses a
  /// [IndependentGovernorTuning.periodDays] boundary since the declaration
  /// (the tick of the declaration itself is one: the council sits the day
  /// it takes over). Nothing at all for a colony that is not independent.
  /// [localNet] is the tick's own-production balance (`CitySim.advance`).
  void independentGovernorTick(double dt,
      {required Map<String, double> localNet}) {
    final l = loyalty;
    if (l.allegiance != Allegiance.independent) return;
    final at = l.independentAtS;
    if (at == null || dt <= 0) return;
    final period = governorTuning.periodDays * l.tuning.daySec;
    if (period <= 0) return;
    final now = l.colonyTimeS;
    final was = ((now - dt - at) / period).floor();
    final isNow = ((now - at) / period).floor();
    if (isNow <= was) return;
    governIndependent(localNet: localNet);
  }

  /// One sitting (§4), whatever the calendar: what [independentGovernorTick]
  /// runs on its days, public so a test can convene one. Returns what it
  /// did. Refuses (does nothing) for a colony that is not independent: the
  /// player's colonies are the player's to run.
  List<GovernorAct> governIndependent({required Map<String, double> localNet}) {
    if (loyalty.allegiance != Allegiance.independent) return const [];
    final t = governorTuning;
    final acts = <GovernorAct>[];
    void did(GovernorActKind k, String text, {double ore = 0}) =>
        acts.add(GovernorAct(k, text, loyalty.colonyTimeS, oreSpent: ore));

    // 1. Laws.
    final lawsBefore = {...laws};
    autoVote();
    if (lawsBefore.length != laws.length || !lawsBefore.containsAll(laws)) {
      did(GovernorActKind.laws,
          'voted its laws: ${laws.isEmpty ? 'none' : laws.map((l) => l.label).join(', ')}');
    }

    // 2. Tax: the rate at which the tax's own mood cost leaves the colony at
    // the bearable mood, a step at a time — the mood lags the rate, and a
    // council that jumped to the computed rate would chase its own wake.
    if (economy.taxControllable) {
      final penalty = economy.taxHappinessPenalty;
      if (penalty > 1e-6) {
        final ideal = (taxRate + (happiness - t.bearableMood) / penalty)
            .clamp(0.0, t.maxTax);
        final next = (taxRate + (ideal - taxRate).clamp(-t.taxStep, t.taxStep))
            .clamp(0.0, t.maxTax);
        if ((next - taxRate).abs() > 0.005) {
          did(GovernorActKind.tax,
              'set the tax to ${(next * 100).round()}%');
          taxRate = next;
        }
      }
    }

    // 3–4. One build a sitting, the most urgent first.
    final built = _governorBuild(localNet, t);
    if (built != null) {
      did(built.$1, built.$2, ore: built.$3);
    } else {
      // 5. Zoning.
      final z = _governorZone(t);
      if (z != null) did(GovernorActKind.zone, z);
    }

    final log = governorLog..addAll(acts);
    if (log.length > _maxLog) log.removeRange(0, log.length - _maxLog);
    return acts;
  }

  // ---- Building --------------------------------------------------------------

  /// The sitting's build, or null: what it built, why, and the ore it cost.
  (GovernorActKind, String, double)? _governorBuild(
      Map<String, double> localNet, IndependentGovernorTuning t) {
    final pop = population;
    // Life support: a commodity the colony's own buildings (and its sky, for
    // oxygen) make less of than its people use. Oxygen counts only where the
    // sim makes people breathe what is made — the life-support step's own
    // rule; read here, never changed.
    if (pop > 1e-9) {
      final needs = <(String, double)>[
        (Commodity.food, pop * CitySim.foodPerPersonPerSec),
        (Commodity.water, pop * CitySim.waterPerPersonPerSec),
        if (systemOn(0.3) && !breathable)
          (
            Commodity.oxygen,
            pop * CitySim.waterPerPersonPerSec * (1 - airO2.clamp(0.0, 1.0))
          ),
      ];
      for (final (c, need) in needs) {
        final short = (c == Commodity.food && starved) ||
            (localNet[c] ?? 0) < need - 1e-9;
        if (!short) continue;
        final options = [
          for (final s in kUtilCatalog)
            if (CitySim.isLifeSupport(s) && (s.outputs[c] ?? 0) > 0) s,
        ];
        final b = _buildCheapest(options, t);
        if (b != null) {
          return (
            GovernorActKind.lifeSupport,
            'built ${_a(b.label)}: short of '
                '${Commodity.name(c).toLowerCase()}',
            b.buildCost
          );
        }
      }
    }
    // Waste: past the line with nothing that takes garbage.
    if (systemOn(0.5) &&
        wasteBacklog > t.wasteLine &&
        !_hasBuilding((s) => s.inputs.containsKey(Commodity.garbage))) {
      final b = _buildCheapest(
          [
            for (final s in kUtilCatalog)
              if (s.inputs.containsKey(Commodity.garbage)) s,
          ],
          t);
      if (b != null) {
        return (
          GovernorActKind.waste,
          'built ${_a(b.label)}: the rubbish is piling up',
          b.buildCost
        );
      }
    }
    // The dead: past the line with no deathcare at all.
    if (corpses > math.max(t.corpseMin, t.corpseShare * pop) &&
        !_hasBuilding((s) => s.deathcareRate > 0)) {
      final b = _buildCheapest(
          [
            for (final s in kUtilCatalog)
              if (s.deathcareRate > 0) s,
          ],
          t);
      if (b != null) {
        return (
          GovernorActKind.deathcare,
          'built ${_a(b.label)}: the dead lie unburied',
          b.buildCost
        );
      }
    }
    return null;
  }

  static String _a(String label) =>
      '${'AEIOU'.contains(label[0]) ? 'an' : 'a'} $label';

  bool _hasBuilding(bool Function(CityBuildingSpec) test) {
    for (final (_, s) in buildingParcels()) {
      if (test(s)) return true;
    }
    return false;
  }

  /// Build the cheapest of [options] the colony can afford and place, or
  /// null. Cheapest first, catalogue order breaking a tie, so the same
  /// colony picks the same building every time.
  CityBuildingSpec? _buildCheapest(
      List<CityBuildingSpec> options, IndependentGovernorTuning t) {
    final order = [
      for (var i = 0; i < options.length; i++) (i, options[i]),
    ]..sort((a, b) {
        final c = a.$2.buildCost.compareTo(b.$2.buildCost);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    for (final (_, s) in order) {
      if (!unlocked(s)) continue;
      if (!_placeable(s)) continue;
      // Never the last of the ore: the reserve stays in the store.
      if (stockOf(Commodity.ore) - s.buildCost < t.oreReserve) continue;
      if (_place(s, t)) return s;
    }
    return null;
  }

  /// The flat builder's own refusals, which the domain does not make: a
  /// harvester where the air holds no oxygen, a mine with no ground.
  bool _placeable(CityBuildingSpec s) {
    if (s.type == 'o2harvester' && !o2Harvestable) return false;
    if (s.type == 'mine' && colonyMode != ColonyStyle.open) return false;
    return true;
  }

  /// Put [s] down somewhere it works, paying for it. The plat when the
  /// colony has one (every colony founded in the world), else the legacy
  /// cell grid (the flat sandbox).
  bool _place(CityBuildingSpec s, IndependentGovernorTuning t) {
    if (layout.roads.isNotEmpty) {
      if (s.claimsOwnSite) {
        // A plot already staked and standing empty — the field a burned
        // farm stood on — before staking a new one.
        final plot = _freePlot(s);
        if (plot != null && placeOnParcel(plot.id, s)) {
          stock[Commodity.ore] = stockOf(Commodity.ore) - s.buildCost;
          return true;
        }
        final centre = _findSite(s, t);
        // claimSite charges the ore itself.
        return centre != null && claimSite(s, centre) != null;
      }
      final lot = _freeLots().firstOrNull;
      if (lot == null || !placeOnParcel(lot.id, s)) return false;
      stock[Commodity.ore] = stockOf(Commodity.ore) - s.buildCost;
      return true;
    }
    final cell = _freeCell(s);
    if (cell == null) return false;
    stock[Commodity.ore] = stockOf(Commodity.ore) - s.buildCost;
    placeUtil(cell, s);
    recompute();
    return true;
  }

  /// A centre a plot for [s] can be staked at: beside a road — off each
  /// side, past each end, at every corner of a sample along it — clear of
  /// every road, plot and access corridor ([CitySim.siteBlockedReason], the
  /// editor's own predicate), and covering no lot anyone has zoned or built
  /// on: staking a plot re-cuts the street lots under it, and a council that
  /// put its farm over a street of houses would have demolished them. The
  /// nearest the colony's centre wins, so it grows outward from its heart.
  Vec2? _findSite(CityBuildingSpec s, IndependentGovernorTuning t) {
    final size = s.siteMetres(cellM: CitySim.cellM);
    final hw = size.width / 2, hd = size.depth / 2;
    const gap = 25.0; // clear of the carriageway and its verge
    final step = math.max(40.0, math.min(hw, hd));
    final roads = [...layout.roads]..sort((a, b) => a.id.compareTo(b.id));
    final candidates = <Vec2>[];
    for (final r in roads) {
      final pts = r.controls;
      for (var i = 0; i + 1 < pts.length; i++) {
        final a = pts[i], b = pts[i + 1];
        final len = a.distanceTo(b);
        final n = math.max(1, (len / step).ceil());
        for (var j = 0; j <= n; j++) {
          final q = a + (b - a) * (j / n);
          for (final sx in const [-1.0, 0.0, 1.0]) {
            for (final sy in const [-1.0, 0.0, 1.0]) {
              if (sx == 0 && sy == 0) continue;
              candidates.add(
                  Vec2(q.e + sx * (hw + gap), q.n + sy * (hd + gap)));
            }
          }
        }
      }
    }
    final ranked = [
      for (var i = 0; i < candidates.length; i++) (i, candidates[i]),
    ]..sort((x, y) {
        final c = x.$2.length.compareTo(y.$2.length);
        return c != 0 ? c : x.$1.compareTo(y.$1);
      });
    final taken = [
      for (final p in layout.autoParcels)
        if (p.use != ParcelUse.unzoned ||
            parcelBuildings.containsKey(p.id) ||
            grownParcels.containsKey(p.id))
          p.centroid,
    ];
    var checks = 0;
    Vec2? last;
    for (final (_, c) in ranked) {
      // Two samples a hair apart (a segment's end and the next one's start)
      // make the same candidate: try it once.
      if (last != null && last.distanceTo(c) < 1e-6) continue;
      last = c;
      if (checks++ >= t.maxSiteChecks) break;
      final covers = taken.any((p) =>
          (p.e - c.e).abs() <= hw + 1 && (p.n - c.n).abs() <= hd + 1);
      if (covers) continue;
      if (siteBlockedReason(s, c) == null) return c;
    }
    return null;
  }

  /// A staked plot standing empty that is big enough for [s]'s site, in
  /// layout order, or null.
  Parcel? _freePlot(CityBuildingSpec s) {
    final size = s.siteMetres(cellM: CitySim.cellM);
    final net = parcelNetwork();
    for (final p in layout.manualParcels) {
      if (p.use != ParcelUse.unzoned) continue;
      if (parcelBuildings.containsKey(p.id)) continue;
      if (!net.lotServed(p.id)) continue;
      var minE = double.infinity, maxE = -double.infinity;
      var minN = double.infinity, maxN = -double.infinity;
      for (final v in p.polygon) {
        minE = math.min(minE, v.e);
        maxE = math.max(maxE, v.e);
        minN = math.min(minN, v.n);
        maxN = math.max(maxN, v.n);
      }
      final w = maxE - minE, d = maxN - minN;
      bool fits(double a, double b) =>
          a >= 0.95 * size.width && b >= 0.95 * size.depth;
      if (fits(w, d) || fits(d, w)) return p;
    }
    return null;
  }

  /// Street lots nobody has zoned or built on, that a road serves, in layout
  /// order — the order the plat cut them.
  Iterable<Parcel> _freeLots() sync* {
    final net = parcelNetwork();
    final easementOf = layout.easementOf;
    for (final p in layout.autoParcels) {
      if (p.use != ParcelUse.unzoned) continue;
      if (parcelBuildings.containsKey(p.id)) continue;
      if (grownParcels.containsKey(p.id)) continue;
      if (easementOf != null && easementOf(p.id) != null) continue;
      if (!net.lotServed(p.id)) continue;
      yield p;
    }
  }

  /// The first grid cell [s] fits at beside a road, in key order, or null.
  int? _freeCell(CityBuildingSpec s) {
    for (var k = 0; k < grid * grid; k++) {
      final x = k % grid, y = k ~/ grid;
      if (!footprintFree(x, y, s)) continue;
      if (!footprintSupported(x, y, s.footW, s.footH)) continue;
      if (footCells(x, y, s).any(isLiquidTile)) continue;
      var byRoad = false;
      for (final c in footCells(x, y, s)) {
        if (neighbours8(c).any(roads.contains)) {
          byRoad = true;
          break;
        }
      }
      if (byRoad) return k;
    }
    return null;
  }

  // ---- Zoning ----------------------------------------------------------------

  /// Zone up to [IndependentGovernorTuning.zonePerSitting] free lots, the use
  /// the demand asks for most against what is already zoned for it — so a
  /// town whose shops are always wanted still gets homes once it has a few
  /// shops. Null when it zoned nothing.
  String? _governorZone(IndependentGovernorTuning t) {
    const uses = [
      ParcelUse.residential,
      ParcelUse.commercial,
      ParcelUse.industrial,
    ];
    double demandOf(ParcelUse u) => switch (u) {
          ParcelUse.residential => resTarget,
          ParcelUse.commercial => comTarget,
          _ => indTarget,
        };
    final plat = layout.roads.isNotEmpty;
    final zoned = {for (final u in uses) u: 0};
    var pending = 0;
    if (plat) {
      for (final p in layout.autoParcels) {
        if (!zoned.containsKey(p.use)) continue;
        zoned[p.use] = zoned[p.use]! + 1;
        if (!parcelBuildings.containsKey(p.id) &&
            (grownParcels[p.id] ?? 0) < CitySim.parcelConstructFrac) {
          pending++;
        }
      }
    } else {
      for (final e in zones.entries) {
        final u = switch (e.value.kind) {
          'residential' => ParcelUse.residential,
          'commercial' => ParcelUse.commercial,
          _ => ParcelUse.industrial,
        };
        zoned[u] = zoned[u]! + 1;
        if (!grown.contains(e.key)) pending++;
      }
    }
    if (pending >= t.maxPendingZones) return null;
    ParcelUse? best;
    var bestScore = 0.0;
    for (final u in uses) {
      final d = demandOf(u);
      if (d < CitySim.growThreshold) continue;
      final score = d / (1 + zoned[u]!);
      if (score > bestScore + 1e-12) {
        bestScore = score;
        best = u;
      }
    }
    final use = best;
    if (use == null) return null;
    final want = math.min(t.zonePerSitting, t.maxPendingZones - pending);
    var n = 0;
    if (plat) {
      for (final p in _freeLots().take(want).toList()) {
        if (layout.setUse(p.id, use)) n++;
      }
    } else {
      final kind = CitySim.zoneKindOf(use)!;
      final one = kZoneSpecs[kind]![Density.low]!;
      while (n < want) {
        final k = _freeCell(one);
        if (k == null) break;
        clearCell(k, keepSupport: true);
        zones[k] = CityZoneType(kind, Density.low);
        n++;
      }
      if (n > 0) recompute();
    }
    if (n == 0) return null;
    return 'zoned $n ${CitySim.zoneKindOf(use)} lot${n == 1 ? '' : 's'}';
  }
}
