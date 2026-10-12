// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Every factory floor in one colony, by site id
/// (docs/plans/factory-floors.md §3 "Off-screen = measured steady state",
/// "Persistence", "Ownership and money"; phase 6).
///
/// The colony aggregate holds one of these at integration (wave 3:
/// `CitySim.factoryFloors`, saved as `'factories'`). It is the reason dozens
/// of plants cost nothing per frame: a floor nobody has open is just a
/// [FloorRecord] — its layout and the [MeasuredRates] last measured for it —
/// and [stepAggregate] turns those rates into stock movements with a few
/// multiplications. Only the floor open in the editor runs at full fidelity
/// ([FloorRecord.live]), and closing it marks the record [FloorRecord.dirty]
/// so the off-thread runner re-measures the edited layout.
///
/// The store never builds a floor itself: [open] takes the builder, so this
/// file doesn't depend on any one [FactorySim] implementation, and tests
/// drive it with a fake whose rates are known exactly.
///
/// Records, the per-colony blueprint library and ownership are saved. Live
/// sims are not (their in-flight items are a few seconds of production);
/// saving a live record saves its current layout and flags it for
/// re-measure. Templates are built-ins and never enter the library.
///
/// Deterministic: records and the library are kept in id order
/// ([SplayTreeMap]), so stepping and saving visit sites in the same order on
/// every machine.
library;

import 'dart:collection';

import '../economy/economy_contracts.dart';
import 'factory_colony_port.dart';
import 'factory_ledger.dart';
import 'factory_sim_api.dart';
import 'floor_blueprint.dart';

/// Builds a running floor from a layout (wave 3: `FactoryFloor.fromBlueprint`).
typedef FloorSimBuilder = FactorySim Function(FloorBlueprint bp);

/// One plant's floor.
class FloorRecord {
  FloorRecord({
    required this.blueprint,
    this.rates = MeasuredRates.none,
    this.designed = false,
    this.owner,
    this.dirty = true,
  });

  /// The layout as last closed or assigned — the store's own copy, never
  /// shared with a caller or a live sim. While [live] is set, the live
  /// sim's own blueprint is the truth and this is stale.
  FloorBlueprint blueprint;

  /// Steady-state rates of [blueprint] ([MeasuredRates.none] = never
  /// measured; such a floor moves nothing in aggregate mode).
  MeasuredRates rates;

  /// False while it is still the plant's template.
  bool designed;

  /// Who runs it (null = the economy's default, decided at integration).
  Ownership? owner;

  /// The full-fidelity sim, only while the editor has it open. Never saved.
  FactorySim? live;

  /// The layout changed since [rates] were measured.
  bool dirty;

  /// Bumps on every layout change, so a measurement that finishes after a
  /// further edit is recognised as stale ([FactoryFloors.applyMeasured]).
  /// Runtime only.
  int rev = 0;

  /// [live]'s `layoutRev` when it was opened, to tell an edit from a look.
  int _openLayoutRev = 0;

  /// Aggregate-mode counters since the last [FactoryFloors.takeLedger].
  final FactoryLedger _ledger = FactoryLedger();

  bool get measured => rates.seconds > 0;

  /// The layout to save or measure: the live one while open.
  FloorBlueprint get currentBlueprint {
    final l = live;
    return l != null ? l.blueprint : blueprint;
  }

  /// Saving with the editor open: an edit made since [FactoryFloors.open]
  /// hasn't reached [designed]/[dirty] yet ([FactoryFloors.close] would set
  /// both), so the save applies it; a floor only looked at keeps its rates.
  Map<String, Object?> toJson() {
    final l = live;
    final edited = l == null ? false : l.layoutRev != _openLayoutRev;
    return {
      'bp': currentBlueprint.toJson(),
      if (measured) 'rates': rates.toJson(),
      if (designed || edited) 'designed': true,
      'owner': ?owner?.toJson(),
      if (dirty || edited) 'dirty': true,
    };
  }

  static FloorRecord fromJson(Map<String, Object?> j) {
    final r = j['rates'] as Map?;
    final o = j['owner'] as Map?;
    return FloorRecord(
      blueprint: FloorBlueprint.fromJson(
        (j['bp'] as Map).cast<String, Object?>(),
      ),
      rates: r == null
          ? MeasuredRates.none
          : MeasuredRates.fromJson(r.cast<String, Object?>()),
      designed: j['designed'] == true,
      owner: o == null ? null : Ownership.fromJson(o.cast<String, Object?>()),
      dirty: j['dirty'] == true,
    );
  }
}

/// What one aggregate (or live) step moved through the colony port.
class FloorStepReport {
  const FloorStepReport({
    required this.taken,
    required this.given,
    required this.share,
    required this.live,
  });

  static const FloorStepReport idle = FloorStepReport(
    taken: {},
    given: {},
    share: 0,
    live: false,
  );

  /// Net units withdrawn from / landed in the colony, by commodity.
  final Map<String, double> taken;
  final Map<String, double> given;

  /// Aggregate mode: the fraction of measured output the step achieved
  /// (throttle × scarcest input). Live: 1 (the sim decides for itself).
  final double share;

  /// True when a live sim ran instead of the measured rates.
  final bool live;
}

class FactoryFloors {
  final SplayTreeMap<String, FloorRecord> _sites = SplayTreeMap();
  final SplayTreeMap<String, FloorBlueprint> _library = SplayTreeMap();

  bool get isEmpty => _sites.isEmpty && _library.isEmpty;

  /// Site ids with a floor, sorted.
  List<String> get siteIds => _sites.keys.toList();

  FloorRecord? operator [](String siteId) => _sites[siteId];

  // ---- records ------------------------------------------------------------

  /// Gives [siteId] the floor [bp] (a template when [designed] is false).
  /// Replaces any floor already there, closing a live one unsaved. Owner
  /// carries over unless [owner] is given. Without [rates] the record is
  /// dirty and moves nothing until measured.
  FloorRecord assign(
    String siteId,
    FloorBlueprint bp, {
    bool designed = false,
    Ownership? owner,
    MeasuredRates? rates,
  }) {
    final old = _sites[siteId];
    final rec = FloorRecord(
      // Copied at the boundary: the caller (a template, a library entry, an
      // editor buffer) may keep mutating its own object.
      blueprint: bp.copy(),
      rates: rates ?? MeasuredRates.none,
      designed: designed,
      owner: owner ?? old?.owner,
      dirty: rates == null,
    )..rev = (old?.rev ?? 0) + 1;
    _sites[siteId] = rec;
    return rec;
  }

  /// Drops [siteId]'s floor (demolition). Returns what was there.
  FloorRecord? remove(String siteId) => _sites.remove(siteId);

  /// Carries a floor across a lot rename. A floor already at [newId] is
  /// replaced (the renamed lot is the one the player sees). False if
  /// [oldId] had none.
  bool rename(String oldId, String newId) {
    if (oldId == newId) return _sites.containsKey(oldId);
    final rec = _sites.remove(oldId);
    if (rec == null) return false;
    _sites[newId] = rec;
    return true;
  }

  /// Drops every floor whose site no longer exists. Returns the dropped
  /// ids, sorted.
  List<String> dropMissing(Set<String> liveSiteIds) {
    final gone = [
      for (final id in _sites.keys)
        if (!liveSiteIds.contains(id)) id,
    ];
    for (final id in gone) {
      _sites.remove(id);
    }
    return gone;
  }

  void setOwner(String siteId, Ownership? owner) {
    final rec = _sites[siteId];
    if (rec != null) rec.owner = owner;
  }

  // ---- editor -------------------------------------------------------------

  /// Starts (or returns) the full-fidelity sim for [siteId]. Null when the
  /// site has no floor.
  FactorySim? open(String siteId, FloorSimBuilder build) {
    final rec = _sites[siteId];
    if (rec == null) return null;
    final have = rec.live;
    if (have != null) return have;
    // A builder may keep the blueprint it is given and edit it in place;
    // hand it a copy so the record's layout only changes on close.
    final sim = build(rec.blueprint.copy());
    rec.live = sim;
    rec._openLayoutRev = sim.layoutRev;
    return sim;
  }

  /// Ends the live sim for [siteId], keeping its layout. An edited layout
  /// becomes [FloorRecord.designed] and [FloorRecord.dirty]; a floor that
  /// was only looked at keeps its rates. Returns the record.
  FloorRecord? close(String siteId) {
    final rec = _sites[siteId];
    if (rec == null) return null;
    final sim = rec.live;
    if (sim == null) return rec;
    // Counters run up while open still belong to the plant's books.
    rec._ledger.absorb(sim.takeLedger());
    if (sim.layoutRev != rec._openLayoutRev) {
      rec.blueprint = sim.blueprint.copy();
      rec.designed = true;
      rec.dirty = true;
      rec.rev++;
    }
    rec.live = null;
    return rec;
  }

  /// Sites whose rates are stale and that aren't open, sorted. The runner
  /// measures `this[id]!.blueprint` and hands back `rev` with the result.
  List<String> get needsMeasure => [
    for (final e in _sites.entries)
      if (e.value.dirty && e.value.live == null) e.key,
  ];

  /// Stores freshly measured [rates]. When [rev] is given and the layout has
  /// changed since the measurement started, the result is stale and is
  /// dropped (false).
  bool applyMeasured(String siteId, MeasuredRates rates, {int? rev}) {
    final rec = _sites[siteId];
    if (rec == null) return false;
    if (rev != null && rev != rec.rev) return false;
    rec.rates = rates;
    rec.dirty = false;
    return true;
  }

  // ---- blueprint library --------------------------------------------------

  /// The colony's saved designs, by name, sorted. Copies: editing one (or
  /// assigning it to a site whose builder edits in place) can't change the
  /// saved design.
  Map<String, FloorBlueprint> get library => UnmodifiableMapView(
    SplayTreeMap.of({for (final e in _library.entries) e.key: e.value.copy()}),
  );

  /// One saved design by [name] (a copy), or null.
  FloorBlueprint? blueprintNamed(String name) => _library[name]?.copy();

  /// "Save as blueprint". A name already taken is overwritten.
  void saveBlueprint(String name, FloorBlueprint bp) =>
      _library[name] = bp.copy(name: name);

  FloorBlueprint? deleteBlueprint(String name) => _library.remove(name);

  // ---- colony tick --------------------------------------------------------

  /// Runs [siteId]'s floor for [dt] colony seconds against [port].
  ///
  /// Live: the sim steps itself. Otherwise the measured rates apply: each
  /// input is asked for `rate × dt × throttle` (throttle = the lower of the
  /// power and staffing shares, each ignored when the floor needs none of
  /// it); the scarcest grant sets the share of output made, inputs taken
  /// beyond that share go back to stock, and outputs are offered at
  /// `rate × dt × share`. Storage refusals are lost, as an over-full
  /// colony's flat-rate plants lose theirs.
  FloorStepReport stepAggregate(
    double dt,
    String siteId,
    FactoryColonyPort port,
  ) {
    final rec = _sites[siteId];
    if (rec == null || dt <= 0) return FloorStepReport.idle;
    final tally = _TallyPort(port);
    final sim = rec.live;
    if (sim != null) {
      sim.step(dt, tally);
      return FloorStepReport(
        taken: tally.taken,
        given: tally.given,
        share: 1,
        live: true,
      );
    }
    final r = rec.rates;
    if (!(r.seconds > 0)) return FloorStepReport.idle;

    var throttle = 1.0;
    if (r.powerKw > 0) throttle = _min(throttle, _unit(port.powerShare));
    if (r.jobs > 0) throttle = _min(throttle, _unit(port.staffingShare));

    // Inputs in key order; each later ask already shrunk to the share the
    // earlier ones allow, so at most the earlier ones are over-taken.
    var share = throttle;
    final got = <String, double>{};
    for (final c in _sortedKeys(r.inPerS)) {
      final perShare = r.inPerS[c]! * dt;
      if (!(perShare > 0) || !(share > 0)) continue;
      final g = tally.take(c, perShare * share);
      got[c] = g;
      final s = g / perShare;
      if (s < share) share = s;
    }
    // Hand back what the scarcest input made useless.
    for (final c in _sortedKeys(got)) {
      final keep = r.inPerS[c]! * dt * share;
      final extra = got[c]! - keep;
      if (extra > 1e-12) tally.refund(c, extra);
    }
    if (share > 0) {
      for (final c in _sortedKeys(r.outPerS)) {
        final u = r.outPerS[c]! * dt * share;
        if (u > 0) tally.give(c, u);
      }
    }

    final l = rec._ledger
      ..seconds += dt
      ..energyKJ += r.powerKw * dt * share;
    // Aggregate mode knows the layout's job demand, not its role split.
    if (r.jobs > 0) {
      l.addWork(WorkRole.station, r.jobs * dt * _unit(port.staffingShare));
    }
    tally.taken.forEach(l.addReceived);
    tally.given.forEach(l.addShipped);

    return FloorStepReport(
      taken: tally.taken,
      given: tally.given,
      share: share,
      live: false,
    );
  }

  /// [stepAggregate] for every floor, in site-id order.
  Map<String, FloorStepReport> stepAll(double dt, FactoryColonyPort port) => {
    for (final id in _sites.keys.toList()) id: stepAggregate(dt, id, port),
  };

  /// [siteId]'s counters since the last call (aggregate steps, plus a live
  /// sim's own ledger), for the plant's P&L. Starts a fresh period.
  FactoryLedger takeLedger(String siteId) {
    final rec = _sites[siteId];
    final out = FactoryLedger();
    if (rec == null) return out;
    out.absorb(rec._ledger);
    rec._ledger.reset();
    final sim = rec.live;
    if (sim != null) out.absorb(sim.takeLedger());
    return out;
  }

  // ---- save ---------------------------------------------------------------

  Map<String, Object?> toJson() => {
    if (_sites.isNotEmpty)
      'sites': {for (final e in _sites.entries) e.key: e.value.toJson()},
    if (_library.isNotEmpty)
      'lib': {for (final e in _library.entries) e.key: e.value.toJson()},
  };

  static FactoryFloors fromJson(Map<String, Object?>? j) {
    final f = FactoryFloors();
    if (j == null) return f;
    final sites = ((j['sites'] as Map?) ?? const {}).cast<String, Object?>();
    sites.forEach((id, v) {
      f._sites[id] = FloorRecord.fromJson((v as Map).cast<String, Object?>());
    });
    final lib = ((j['lib'] as Map?) ?? const {}).cast<String, Object?>();
    lib.forEach((name, v) {
      f._library[name] = FloorBlueprint.fromJson(
        (v as Map).cast<String, Object?>(),
      );
    });
    return f;
  }
}

List<String> _sortedKeys(Map<String, double> m) => m.keys.toList()..sort();

double _min(double a, double b) => a < b ? a : b;

/// Clamps a port share into 0..1 (NaN = nothing).
double _unit(double v) => v > 1 ? 1 : (v > 0 ? v : 0);

/// Passes every call through to the colony and tallies what crossed;
/// [refund] nets returned input off `taken` rather than counting it as
/// output (a plant that ships an item it also receives keeps both lines).
class _TallyPort implements FactoryColonyPort {
  _TallyPort(this.inner);
  final FactoryColonyPort inner;
  final Map<String, double> taken = SplayTreeMap();
  final Map<String, double> given = SplayTreeMap();

  @override
  double take(String commodity, double units) {
    final g = inner.take(commodity, units);
    if (g > 0) taken[commodity] = (taken[commodity] ?? 0) + g;
    return g;
  }

  @override
  double give(String commodity, double units) {
    final a = inner.give(commodity, units);
    if (a > 0) given[commodity] = (given[commodity] ?? 0) + a;
    return a;
  }

  /// Puts back input drawn this step and not used; nets it off [taken].
  void refund(String commodity, double units) {
    final a = inner.give(commodity, units);
    if (a > 0) taken[commodity] = (taken[commodity] ?? 0) - a;
  }

  @override
  double get powerShare => inner.powerShare;
  @override
  double get staffingShare => inner.staffingShare;
}
