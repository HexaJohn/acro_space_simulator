// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A [FactorySim] that records what the editor asks of it.
///
/// The editor's contract is "every edit goes through the sim's editor
/// surface"; this fake makes each call observable so a test can assert the
/// exact placement, removal, recipe, mode or hire the UI produced — without
/// depending on any real floor's rules.
library;

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_ledger.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';

class FakeFactorySim implements FactorySim {
  FakeFactorySim(this.bp);

  final FloorBlueprint bp;
  int rev = 0;
  double t = 0;

  final List<Placement> placed = [];
  final List<int> removed = [];
  final List<int> rotated = [];
  final List<(int, String)> recipes = [];
  final List<(int, MachineMode)> modes = [];
  final List<(HandlerKind, int)> hires = [];
  int steps = 0;
  double stepped = 0;
  int ledgersTaken = 0;

  List<BeltItemView> belt = [];
  List<HandlerView> crew = [];

  @override
  FloorBlueprint get blueprint => bp;
  @override
  int get layoutRev => rev;
  @override
  double get simSeconds => t;
  @override
  MachineStatus statusOf(int placementId) => MachineStatus.working;
  @override
  Map<String, int> contentsOf(int placementId) => const {'ore': 3};
  @override
  Iterable<BeltItemView> get beltItems => belt;
  @override
  Iterable<HandlerView> get handlers => crew;
  @override
  int get pendingRequests => 0;
  @override
  FactoryLedger get ledger => FactoryLedger();
  @override
  double get jobDemand => bp.jobDemand;
  @override
  double get powerDemandKw => 0;

  @override
  EditResult place(Placement p) {
    placed.add(p);
    final id = bp.nextId;
    bp.placements.add(p.copyWith(id: id));
    rev++;
    return EditResult.ok(id);
  }

  @override
  EditResult remove(int placementId) {
    removed.add(placementId);
    bp.placements.removeWhere((p) => p.id == placementId);
    rev++;
    return EditResult.ok(placementId);
  }

  @override
  EditResult rotate(int placementId) {
    rotated.add(placementId);
    return EditResult.ok(placementId);
  }

  @override
  EditResult setRecipe(int placementId, String recipeId) {
    recipes.add((placementId, recipeId));
    return EditResult.ok(placementId);
  }

  @override
  EditResult setMode(int placementId, MachineMode mode) {
    modes.add((placementId, mode));
    return EditResult.ok(placementId);
  }

  @override
  EditResult hire(HandlerKind kind, int delta) {
    hires.add((kind, delta));
    bp.roster[kind] = (bp.roster[kind] ?? 0) + delta;
    return const EditResult.ok(null);
  }

  @override
  void step(double dt, FactoryColonyPort port) {
    steps++;
    stepped += dt;
    t += dt;
  }

  @override
  FactoryLedger takeLedger() {
    ledgersTaken++;
    return FactoryLedger()
      ..seconds = 1
      ..addShipped('steel', 2);
  }

  @override
  Map<String, Object?> toJson() => {'bp': bp.toJson()};
}
