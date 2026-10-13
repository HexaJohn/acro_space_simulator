// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Keeps colonies' factory floors measured (docs/plans/factory-floors.md §3
/// "Off-screen = measured steady state", phase 6).
///
/// A floor goes stale when its editor closes on a changed layout, or when a
/// failing firm lays off a handler (`city_economy.dart`). Until it is
/// re-measured it runs on its old rates, so the colony host calls [pump]
/// once a frame: every stale floor not already being measured is handed to
/// ONE [FloorMeasureRunner] (the persistent worker isolate; inline on the
/// web and in tests), and each result goes back through
/// `CityFactories.applyFloorMeasure` with the layout revision the job
/// started from — a result for a layout edited again meanwhile is dropped
/// there, and the newer layout is queued by the next pump.
///
/// [pump] is cheap: a walk over the colony's few floor records and a map
/// lookup each. The measuring itself never runs on the frame.
library;

import 'dart:collection';

import '../../domain/colony/city/city_factories.dart';
import '../../domain/colony/city/city_sim.dart';
import '../../domain/colony/city/factory/factory_catalog.dart';
import '../../domain/colony/city/factory/factory_floor.dart';
import '../../domain/colony/city/factory/factory_sim_api.dart';
import '../../domain/colony/city/factory/factory_templates.dart';
import '../../domain/colony/city/factory/floor_blueprint.dart';
import 'floor_measure_runner.dart';

/// Builds a floor to measure. TOP-LEVEL on purpose: the isolate runner
/// sends it to the worker, and a closure cannot cross. The catalogue is
/// registered here because statics are per isolate — the worker inherits
/// none of the UI isolate's registrations. Measured with every unlock: the
/// sim never refuses a blueprint's own roster, and unlocks only gate what
/// the editor may add.
FactorySim buildFloorForMeasure(FloorBlueprint bp) {
  ensureFactoryCatalog();
  return FactoryFloor.fromBlueprint(bp);
}

class ColonyFloorMeasurer {
  /// [runner] defaults to the platform's ([FloorMeasureRunner.platform]);
  /// tests pass a `SyncFloorMeasureRunner`.
  ColonyFloorMeasurer({FloorMeasureRunner? runner})
      : runner = runner ?? FloorMeasureRunner.platform(buildFloorForMeasure);

  final FloorMeasureRunner runner;

  /// Per colony (by identity), the layout revision each site's job was
  /// started for. A site whose record has moved past it is queued again;
  /// the runner's per-key supersede then drops the stale job if it is still
  /// waiting.
  final Map<CitySim, Map<String, int>> _inFlight = HashMap.identity();

  /// Per colony, the revision whose measurement FAILED: not retried until
  /// the layout changes, or a broken blueprint would be re-sent every frame.
  final Map<CitySim, Map<String, int>> _failed = HashMap.identity();

  var _disposed = false;

  /// Results applied so far (the dev hook and tests read it).
  int applied = 0;

  /// Jobs started and not yet answered, over every colony.
  int get inFlight {
    var n = 0;
    for (final m in _inFlight.values) {
      n += m.length;
    }
    return n;
  }

  /// Whether [site] of [city] is being measured.
  bool measuring(CitySim city, String site) =>
      _inFlight[city]?.containsKey(site) ?? false;

  /// Starts a measurement for every stale floor of [city] not already
  /// being measured at its current revision.
  void pump(CitySim city) {
    if (_disposed) return;
    final stale = city.floorsNeedingMeasure;
    if (stale.isEmpty) return;
    final flying = _inFlight.putIfAbsent(city, () => {});
    final failed = _failed[city];
    for (final site in stale) {
      final rec = city.factoryFloors[site];
      if (rec == null) continue;
      final rev = rec.rev;
      if (flying[site] == rev) continue;
      if (failed != null && failed[site] == rev) continue;
      flying[site] = rev;
      final bp = rec.blueprint;
      final type = bp.plantType ?? city.siteSpec(site)?.type ?? '';
      runner
          .measure(bp,
              settings: measureSettingsFor(type),
              // Per colony AND site: two colonies may both have a `lot-12`.
              key: '${identityHashCode(city)}/$site')
          .then((rates) => _done(city, site, rev, rates),
              onError: (Object _) => _fail(city, site, rev));
    }
  }

  void _done(CitySim city, String site, int rev, MeasuredRates rates) {
    _clear(city, site, rev);
    if (_disposed) return;
    if (city.applyFloorMeasure(site, rates, rev: rev)) applied++;
  }

  void _fail(CitySim city, String site, int rev) {
    _clear(city, site, rev);
    if (_disposed) return;
    _failed.putIfAbsent(city, () => {})[site] = rev;
  }

  /// Forgets [site]'s job when it is still the one recorded (a newer one
  /// for a later revision keeps its slot).
  void _clear(CitySim city, String site, int rev) {
    final m = _inFlight[city];
    if (m == null || m[site] != rev) return;
    m.remove(site);
    if (m.isEmpty) _inFlight.remove(city);
  }

  /// Stops the worker. Unanswered jobs fail quietly; their floors stay
  /// dirty and are measured by whichever host pumps next.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    runner.dispose();
    _inFlight.clear();
    _failed.clear();
  }
}
