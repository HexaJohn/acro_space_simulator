// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Shared helpers for the factory floor tests: a steady-state measurement
/// (warm up, then read the ledger over a window) and small layout builders.
library;

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';

/// Runs [floor] for [warmupS], then measures commodity rates per second
/// over [windowS] from its ledger.
MeasuredRates measure(FactoryFloor floor, FactoryColonyPort port,
    {double warmupS = 300, double windowS = 600}) {
  floor.step(warmupS, port);
  floor.takeLedger();
  floor.step(windowS, port);
  final l = floor.takeLedger();
  Map<String, double> per(Map<String, double> m) =>
      {for (final e in m.entries) e.key: e.value / l.seconds};
  return MeasuredRates(
    inPerS: per(l.received),
    outPerS: per(l.shipped),
    powerKw: l.energyKJ / l.seconds,
    jobs: floor.jobDemand,
    seconds: l.seconds,
  );
}

/// Builds placements with ids 1, 2, 3 … in call order.
class Lay {
  final List<Placement> out = [];
  int _id = 1;

  int add(EntityKind kind, int x, int y,
      {Dir4 dir = Dir4.east,
      String? recipe,
      MachineMode? mode,
      String? item,
      (int, int)? span}) {
    final id = _id++;
    out.add(Placement(
        id: id,
        kind: kind,
        pos: TilePos(x, y),
        dir: dir,
        recipe: recipe,
        mode: mode,
        item: item,
        span: span));
    return id;
  }

  /// Belts from (x0, y) to (x1, y) inclusive, all facing [dir].
  List<int> beltRow(int x0, int x1, int y, {Dir4 dir = Dir4.east}) =>
      [for (var x = x0; x <= x1; x++) add(EntityKind.belt, x, y, dir: dir)];

  FloorBlueprint blueprint(int w, int h, {int walkers = 0}) => FloorBlueprint(
        name: 'test',
        hall: HallSize(w, h),
        placements: out,
        roster: {if (walkers > 0) HandlerKind.onFoot: walkers},
      );
}

/// A colony that supplies anything but accepts at most [cap] units of each
/// commodity — a full warehouse.
class CappedGivePort implements FactoryColonyPort {
  CappedGivePort(this.cap);
  final double cap;
  final Map<String, double> taken = {};
  final Map<String, double> given = {};

  @override
  double take(String commodity, double units) {
    taken[commodity] = (taken[commodity] ?? 0) + units;
    return units;
  }

  @override
  double give(String commodity, double units) {
    final have = given[commodity] ?? 0;
    final room = cap - have;
    final put = units < room ? units : (room > 0 ? room : 0.0);
    given[commodity] = have + put;
    return put;
  }

  @override
  double get powerShare => 1;
  @override
  double get staffingShare => 1;
}
