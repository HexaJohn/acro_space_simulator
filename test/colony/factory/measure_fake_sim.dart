// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A [FactorySim] whose rates are known exactly, for the measurement
/// harness and the colony floor store (track D builds against the
/// interface, not the real floor, which another track writes in parallel).
///
/// It steps in whole [kFactoryStepS] sub-steps like the real floor, carrying
/// the remainder. For the first [startupS] sim seconds it only fills (draws
/// inputs, ships nothing), which is what warm-up must discard. After that,
/// every sub-step it draws `inPerS × step` and ships `outPerS × step`,
/// scaled by the scarcest input grant and the port's power and staffing
/// shares. With [cycleS] set it ships in lumps once per cycle instead, the
/// shape that keeps two sub-windows from agreeing.
library;

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_ledger.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';

const Map<String, double> kFakeIn = {'ore': 2.0};
const Map<String, double> kFakeOut = {'steel': 1.5, 'tubes': 0.4};
const double kFakeKw = 100;
const double kFakeStartupS = 20;

/// Top-level builder (crosses isolates): base rates × `hall.w / 10`, lumpy
/// output when the blueprint is named 'lumpy'.
FactorySim buildFakeSim(FloorBlueprint bp) =>
    FakeSim(bp, scale: bp.hall.w / 10, cycleS: bp.name == 'lumpy' ? 7 : 0);

class FakeSim implements FactorySim {
  FakeSim(
    this._bp, {
    this.scale = 1,
    this.startupS = kFakeStartupS,
    this.cycleS = 0,
    this.jobs = 12,
  });

  FloorBlueprint _bp;
  final double scale;
  final double startupS;
  final double cycleS;
  final double jobs;

  double _carry = 0;
  double _t = 0;
  double _owed = 0; // output share accrued toward the next lump
  int _rev = 0;
  FactoryLedger _ledger = FactoryLedger();

  @override
  void step(double dt, FactoryColonyPort port) {
    _carry += dt;
    while (_carry >= kFactoryStepS - 1e-9) {
      _carry -= kFactoryStepS;
      _sub(port);
    }
  }

  void _sub(FactoryColonyPort port) {
    const s = kFactoryStepS;
    _t += s;
    _ledger.seconds += s;
    final p = port.powerShare, w = port.staffingShare;
    final thr = p < w ? p : w;
    var share = thr;
    for (final e in kFakeIn.entries) {
      final want = e.value * scale * s * thr;
      final g = port.take(e.key, want);
      _ledger.addReceived(e.key, g);
      final f = want > 0 ? g / want * thr : 0.0;
      if (f < share) share = f;
    }
    _ledger.energyKJ += kFakeKw * scale * s * thr;
    _ledger.addWork(WorkRole.station, jobs * s * w);
    if (_t <= startupS + 1e-9) return;
    _owed += share * s;
    if (cycleS > 0 && _owed < cycleS) return;
    for (final e in kFakeOut.entries) {
      final put = port.give(e.key, e.value * scale * _owed);
      _ledger.addShipped(e.key, put);
    }
    _owed = 0;
  }

  @override
  FactoryLedger takeLedger() {
    final l = _ledger;
    _ledger = FactoryLedger();
    return l;
  }

  @override
  Map<String, Object?> toJson() => {'bp': _bp.toJson(), 't': _t};

  @override
  FloorBlueprint get blueprint => _bp;
  @override
  int get layoutRev => _rev;
  @override
  double get simSeconds => _t;
  @override
  MachineStatus statusOf(int placementId) => MachineStatus.working;
  @override
  Map<String, int> contentsOf(int placementId) => const {};
  @override
  Iterable<BeltItemView> get beltItems => const [];
  @override
  Iterable<HandlerView> get handlers => const [];
  @override
  int get pendingRequests => 0;
  @override
  FactoryLedger get ledger => _ledger;
  @override
  double get jobDemand => jobs;
  @override
  double get powerDemandKw => kFakeKw * scale;

  @override
  EditResult place(Placement p) {
    final id = _bp.nextId;
    _bp.placements.add(p.copyWith(id: id));
    _rev++;
    return EditResult.ok(id);
  }

  @override
  EditResult remove(int placementId) {
    final before = _bp.placements.length;
    _bp.placements.removeWhere((p) => p.id == placementId);
    if (_bp.placements.length == before) {
      return const EditResult.refused(EditRefusal.noSuchPlacement);
    }
    _rev++;
    return EditResult.ok(placementId);
  }

  @override
  EditResult rotate(int placementId) =>
      const EditResult.refused(EditRefusal.notAllowed);
  @override
  EditResult setRecipe(int placementId, String recipeId) =>
      const EditResult.refused(EditRefusal.notAllowed);
  @override
  EditResult setMode(int placementId, MachineMode mode) =>
      const EditResult.refused(EditRefusal.notAllowed);

  @override
  EditResult hire(HandlerKind kind, int delta) {
    _bp = _bp.copy()..roster[kind] = (_bp.roster[kind] ?? 0) + delta;
    _rev++;
    return const EditResult.ok(null);
  }
}
