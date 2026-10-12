// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Re-measuring edited floors off the UI thread
/// (docs/plans/factory-floors.md §3 "Off-screen = measured steady state",
/// phase 6).
///
/// Closing the floor editor marks the plant dirty; its new steady-state
/// rates come from ~5 minutes of headless sim (`measureFloor`), which is
/// tens of milliseconds to seconds of work — too much for a frame. So the
/// measurement runs on ONE long-lived worker isolate with a request queue,
/// the persistent-worker pattern of `ground_sample_pool.dart` (never
/// `Isolate.run` per job). The payload each way is small: a blueprint's
/// JSON out, a [MeasuredRates] JSON back.
///
/// Closures can't build a floor on the far side, so the caller hands the
/// runner a TOP-LEVEL (or static) [FloorSimBuilder] — wave 3 passes
/// `FactoryFloor.fromBlueprint` — and optionally a top-level
/// [FloorWorkerSetup] run once inside the worker. Statics are per isolate:
/// anything the builder needs registered at runtime (extra recipes in
/// `FactoryRecipes.table`, say) must be registered by the setup or by the
/// builder itself, not inherited from the UI isolate.
///
/// Requests may carry a [key] (the site id): a request still waiting in the
/// queue is superseded by a newer one with the same key, and both callers get
/// the newer layout's rates — an editor closed three times in a row costs
/// one measurement, not three.
///
/// The web has no isolates, so there the runner measures inline
/// ([SyncFloorMeasureRunner]); tests use that too. Both give identical
/// rates: the sim is deterministic and the blueprint crosses as JSON either
/// way. Callers use [FloorMeasureRunner.platform] and never import an
/// implementation directly.
library;

import '../../domain/colony/city/factory/factory_floors.dart';
import '../../domain/colony/city/factory/factory_measure.dart';
import '../../domain/colony/city/factory/factory_sim_api.dart';
import '../../domain/colony/city/factory/floor_blueprint.dart';
import 'floor_measure_runner_sync.dart'
    if (dart.library.isolate) 'floor_measure_runner_isolate.dart'
    as platform;

export '../../domain/colony/city/factory/factory_floors.dart'
    show FloorSimBuilder;
export '../../domain/colony/city/factory/factory_measure.dart'
    show MeasureSettings;

/// Run once inside a worker before its first build (register recipes …).
typedef FloorWorkerSetup = void Function();

abstract interface class FloorMeasureRunner {
  /// [build] and [setup] must be top-level or static functions.
  factory FloorMeasureRunner.platform(
    FloorSimBuilder build, {
    FloorWorkerSetup? setup,
  }) = platform.PlatformFloorMeasureRunner;

  /// Steady-state rates of [bp] (see `measureFloor`). With a [key], a
  /// queued request for the same key is superseded by this one.
  Future<MeasuredRates> measure(
    FloorBlueprint bp, {
    MeasureSettings settings = MeasureSettings.standard,
    String? key,
  });

  /// Requests not yet answered.
  int get pending;

  /// Stops the worker; unanswered requests fail with a [StateError].
  void dispose();
}

/// The measurement exactly as a worker runs it: blueprint JSON in, rates
/// JSON out, so the inline and isolate runners can't drift apart.
Map<String, Object?> measureBlueprintJson(
  FloorSimBuilder build,
  Map<String, Object?> blueprintJson,
  Map<String, Object?> settingsJson,
) => measureBlueprint(
  FloorBlueprint.fromJson(blueprintJson),
  build,
  settings: MeasureSettings.fromJson(settingsJson),
).toJson();

/// Measures inline on the calling thread: the web's, and the tests'.
class SyncFloorMeasureRunner implements FloorMeasureRunner {
  SyncFloorMeasureRunner(this.build, {FloorWorkerSetup? setup})
    : _setup = setup;

  final FloorSimBuilder build;
  FloorWorkerSetup? _setup;
  var _disposed = false;

  @override
  Future<MeasuredRates> measure(
    FloorBlueprint bp, {
    MeasureSettings settings = MeasureSettings.standard,
    String? key,
  }) {
    if (_disposed) {
      return Future.error(StateError('floor measure runner disposed'));
    }
    final setup = _setup;
    if (setup != null) {
      _setup = null;
      setup();
    }
    try {
      return Future.value(
        MeasuredRates.fromJson(
          measureBlueprintJson(build, bp.toJson(), settings.toJson()),
        ),
      );
    } catch (e, st) {
      return Future.error(e, st);
    }
  }

  @override
  int get pending => 0;

  @override
  void dispose() => _disposed = true;
}
