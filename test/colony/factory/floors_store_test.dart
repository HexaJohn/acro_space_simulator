// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floors.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_ledger.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:flutter_test/flutter_test.dart';

import 'measure_fake_sim.dart';

FloorBlueprint _bp([String name = 'fake']) =>
    FloorBlueprint(name: name, hall: const HallSize(10, 10));

/// The mill's measured rates: 2 ore → 1.5 steel + 0.4 tubes, 100 kW, 12 jobs.
const MeasuredRates _mill = MeasuredRates(
  inPerS: {'ore': 2.0},
  outPerS: {'steel': 1.5, 'tubes': 0.4},
  powerKw: 100,
  jobs: 12,
  seconds: 300,
);

/// A two-input plant: 1 steel + 0.5 electronics → 0.4 rocket parts.
const MeasuredRates _rockets = MeasuredRates(
  inPerS: {'steel': 1.0, 'electronics': 0.5},
  outPerS: {'rocketParts': 0.4},
  powerKw: 50,
  jobs: 20,
  seconds: 300,
);

/// The colony's floor store (docs/plans/factory-floors.md §3, phase 6): the
/// record CitySim holds at integration. These pin the bookkeeping (lots get
/// renamed and dropped), the aggregate step every off-screen plant runs on,
/// and the save format.
void main() {
  group('records', () {
    test('assign, rename, dropMissing and remove keep ids in step', () {
      // Why: lot renames and lost lots go through the aggregate's existing
      // hooks; a floor must follow its plant or vanish with it.
      final f = FactoryFloors()
        ..assign('lot-b', _bp(), owner: const Ownership.state())
        ..assign('lot-a', _bp());
      expect(f.siteIds, ['lot-a', 'lot-b'], reason: 'sorted');
      expect(f.rename('lot-b', 'lot-c'), isTrue);
      expect(f['lot-b'], isNull);
      expect(f['lot-c']!.owner!.isState, isTrue);
      expect(f.rename('nope', 'x'), isFalse);
      expect(f.dropMissing({'lot-c', 'cell-9'}), ['lot-a']);
      expect(f.siteIds, ['lot-c']);
      expect(f.remove('lot-c'), isNotNull);
      expect(f.isEmpty, isTrue);
    });

    test('re-assigning keeps the owner and resets the rates', () {
      // Why: "reset to template" or a new blueprint must not keep the old
      // layout's numbers, but nationalisation shouldn't be undone by it.
      final f = FactoryFloors()
        ..assign(
          's',
          _bp(),
          owner: const Ownership.private('acme'),
          rates: _mill,
        );
      expect(f['s']!.dirty, isFalse);
      final rec = f.assign('s', _bp('v2'), designed: true);
      expect(rec.owner!.firmId, 'acme');
      expect(rec.measured, isFalse);
      expect(f.needsMeasure, ['s']);
    });

    test('open/close: an edit dirties and designs; a look does not', () {
      // Why: closing the editor is what queues a re-measure; looking at a
      // template must not throw its rates away.
      final f = FactoryFloors()..assign('s', _bp(), rates: _mill);
      final sim = f.open('s', (bp) => FakeSim(bp.copy()))!;
      expect(identical(f.open('s', buildFakeSim), sim), isTrue);
      expect(f.needsMeasure, isEmpty);
      f.close('s');
      expect(f['s']!.dirty, isFalse);
      expect(f['s']!.designed, isFalse);

      final sim2 = f.open('s', (bp) => FakeSim(bp.copy()))!;
      sim2.place(
        const Placement(id: 0, kind: EntityKind.belt, pos: TilePos(1, 1)),
      );
      expect(f.needsMeasure, isEmpty, reason: 'open floors are not measured');
      final rev = f['s']!.rev;
      f.close('s');
      final rec = f['s']!;
      expect(rec.live, isNull);
      expect(rec.dirty, isTrue);
      expect(rec.designed, isTrue);
      expect(rec.blueprint.placements, hasLength(1));
      expect(rec.rev, rev + 1);
      expect(f.needsMeasure, ['s']);
    });

    test('a stale measurement is dropped', () {
      // Why: the runner is async; a result for an older layout must not
      // overwrite the newer layout's pending re-measure.
      final f = FactoryFloors()..assign('s', _bp());
      final rev = f['s']!.rev;
      f.assign('s', _bp('v2'));
      expect(f.applyMeasured('s', _mill, rev: rev), isFalse);
      expect(f['s']!.dirty, isTrue);
      expect(f.applyMeasured('s', _mill, rev: f['s']!.rev), isTrue);
      expect(f['s']!.dirty, isFalse);
      expect(f.needsMeasure, isEmpty);
    });

    test('blueprints are copied at the store boundary', () {
      // Why: a builder that keeps (and edits) the blueprint it is handed —
      // as a real floor may — must not change the record's layout before
      // close, the caller's template, or a saved library design.
      FactorySim keep(FloorBlueprint bp) => FakeSim(bp); // no copy
      const belt = Placement(
        id: 0,
        kind: EntityKind.belt,
        pos: TilePos(3, 3),
      );

      final template = _bp('tpl');
      final f = FactoryFloors()..assign('s', template, rates: _mill);
      template.placements.add(belt);
      expect(f['s']!.blueprint.placements, isEmpty, reason: 'assign copies');

      final sim = f.open('s', keep)!;
      sim.place(belt);
      expect(f['s']!.blueprint.placements, isEmpty, reason: 'open copies');
      f.close('s');
      expect(f['s']!.blueprint.placements, hasLength(1));

      f.saveBlueprint('Mine', _bp('mine'));
      f.library['Mine']!.placements.add(belt);
      f.blueprintNamed('Mine')!.placements.add(belt);
      expect(f.blueprintNamed('Mine')!.placements, isEmpty);
      f.assign('t', f.library['Mine']!);
      f.open('t', keep)!.place(belt);
      expect(f.library['Mine']!.placements, isEmpty);
      expect(f.blueprintNamed('nope'), isNull);
    });

    test('blueprint library saves copies by name', () {
      // Why: "Save as blueprint" must snapshot, not alias, the live layout.
      final f = FactoryFloors();
      final bp = _bp('mine');
      f.saveBlueprint('Fast mill', bp);
      bp.placements.add(
        const Placement(id: 1, kind: EntityKind.belt, pos: TilePos(0, 0)),
      );
      expect(f.library['Fast mill']!.placements, isEmpty);
      expect(f.library['Fast mill']!.name, 'Fast mill');
      expect(f.deleteBlueprint('Fast mill'), isNotNull);
      expect(f.library, isEmpty);
    });
  });

  group('stepAggregate', () {
    test('pulls inputs and pushes outputs at the measured rates', () {
      // Why: this IS an off-screen plant: 10 s of a mill is 20 ore → 15
      // steel + 4 tubes, and the books show it.
      final f = FactoryFloors()..assign('s', _bp(), rates: _mill);
      final port = StockColonyPort(stock: {'ore': 100});
      final rep = f.stepAggregate(10, 's', port);
      expect(rep.live, isFalse);
      expect(rep.share, closeTo(1, 1e-12));
      expect(port.stock['ore'], closeTo(80, 1e-9));
      expect(port.stock['steel'], closeTo(15, 1e-9));
      expect(port.stock['tubes'], closeTo(4, 1e-9));
      expect(rep.taken['ore'], closeTo(20, 1e-9));
      final l = f.takeLedger('s');
      expect(l.seconds, 10);
      expect(l.energyKJ, closeTo(1000, 1e-9));
      expect(l.workerSeconds[WorkRole.station], closeTo(120, 1e-9));
      expect(f.takeLedger('s').seconds, 0, reason: 'a fresh period');
    });

    test('the scarcest input governs and the surplus goes back', () {
      // Why: a rocket plant short of electronics must not eat all its steel
      // for nothing; output follows the scarcest input.
      final f = FactoryFloors()..assign('r', _bp(), rates: _rockets);
      final port = StockColonyPort(stock: {'steel': 100, 'electronics': 1});
      final rep = f.stepAggregate(10, 'r', port); // wants 10 steel, 5 elec
      expect(rep.share, closeTo(0.2, 1e-12));
      expect(port.stock['electronics'], closeTo(0, 1e-12));
      expect(port.stock['steel'], closeTo(98, 1e-9), reason: '2 used, 8 back');
      expect(port.stock['rocketParts'], closeTo(0.8, 1e-9));
      expect(rep.taken['steel'], closeTo(2, 1e-9));
      expect(
        rep.given.containsKey('steel'),
        isFalse,
        reason: 'a refund is not output',
      );
    });

    test('power and staffing shares throttle, each only if needed', () {
      // Why: a brownout is a slow factory (§3); a plant with no power draw
      // must not be stopped by a colony with no spare power.
      final f = FactoryFloors()..assign('s', _bp(), rates: _mill);
      final port = StockColonyPort(
        stock: {'ore': 100},
        powerShare: 0.5,
        staffingShare: 0.8,
      );
      expect(f.stepAggregate(10, 's', port).share, closeTo(0.5, 1e-12));
      expect(port.stock['steel'], closeTo(7.5, 1e-9));

      port.staffingShare = 0.25;
      expect(f.stepAggregate(10, 's', port).share, closeTo(0.25, 1e-12));

      f.assign(
        'free',
        _bp(),
        rates: const MeasuredRates(
          inPerS: {'ore': 1},
          outPerS: {'gravel': 1},
          powerKw: 0,
          jobs: 0,
          seconds: 60,
        ),
      );
      final dark = StockColonyPort(
        stock: {'ore': 100},
        powerShare: 0,
        staffingShare: 0,
      );
      expect(f.stepAggregate(1, 'free', dark).share, closeTo(1, 1e-12));
    });

    test('storage refusals are reported, not counted as landed', () {
      // Why: the ore-cap invariant — a full colony doesn't get phantom
      // stock, and the P&L only sells what landed.
      final f = FactoryFloors()..assign('s', _bp(), rates: _mill);
      final port = StockColonyPort(stock: {'ore': 100, 'steel': 95}, cap: 100);
      final rep = f.stepAggregate(10, 's', port);
      expect(rep.given['steel'], closeTo(5, 1e-9));
      expect(rep.given['tubes'], closeTo(4, 1e-9));
      expect(port.stock['steel'], 100);
      expect(f.takeLedger('s').shipped['steel'], closeTo(5, 1e-9));
    });

    test('unmeasured floors move nothing; live floors step themselves', () {
      // Why: an unmeasured floor's rates are unknown (wave 3 decides the
      // fallback); an open floor is the truth and runs at full fidelity.
      final f = FactoryFloors()
        ..assign('new', _bp())
        ..assign('open', _bp(), rates: _mill);
      final port = StockColonyPort(stock: {'ore': 1000});
      expect(f.stepAggregate(10, 'new', port).taken, isEmpty);
      final sim = f.open('open', (bp) => FakeSim(bp, startupS: 0))!;
      final rep = f.stepAggregate(10, 'open', port);
      expect(rep.live, isTrue);
      expect(rep.taken['ore'], closeTo(20, 1e-9));
      expect(rep.given['steel'], closeTo(15, 1e-9));
      expect(sim.simSeconds, 10);
      expect(f.takeLedger('open').received['ore'], closeTo(20, 1e-9));
    });

    test('stepAll runs every floor in site-id order', () {
      // Why: two plants competing for the same scarce ore must split it the
      // same way on every machine — sorted ids, not insertion order.
      List<String> run(List<String> order) {
        final f = FactoryFloors();
        for (final id in order) {
          f.assign(id, _bp(), rates: _mill);
        }
        final port = StockColonyPort(stock: {'ore': 25});
        final reps = f.stepAll(10, port);
        return [
          for (final e in reps.entries)
            '${e.key}:${e.value.taken['ore']!.toStringAsFixed(3)}',
        ];
      }

      expect(run(['b', 'a']), ['a:20.000', 'b:5.000']);
      expect(run(['a', 'b']), run(['b', 'a']));
    });
  });

  group('save', () {
    test('round-trips records, ownership, rates and the library', () {
      // Why: the save is the only memory of a player's designs; JSON through
      // a real encode/decode is what the save file does.
      final f = FactoryFloors()
        ..assign(
          'lot-1',
          _bp('mill'),
          designed: true,
          owner: const Ownership.private('acme'),
          rates: _mill,
        )
        ..assign('cell-4', _bp(), owner: const Ownership.state())
        ..saveBlueprint(
          'Lean',
          FloorBlueprint(
            name: 'x',
            hall: const HallSize(30, 20),
            plantType: 'steelmill',
            roster: {HandlerKind.onFoot: 3},
          ),
        );
      final json = jsonDecode(jsonEncode(f.toJson())) as Map<String, Object?>;
      final back = FactoryFloors.fromJson(json);
      expect(back.toJson(), f.toJson());
      expect(back['lot-1']!.owner!.firmId, 'acme');
      expect(back['lot-1']!.designed, isTrue);
      expect(back['lot-1']!.rates.outPerS['steel'], 1.5);
      expect(back['lot-1']!.dirty, isFalse);
      expect(back['cell-4']!.dirty, isTrue);
      expect(back.library['Lean']!.roster[HandlerKind.onFoot], 3);
    });

    test('empty fields are omitted; a live floor saves its layout dirty', () {
      // Why: old saves (no factories) and an empty store must cost nothing
      // in the file; a floor open at save time is re-measured after load.
      expect(FactoryFloors().toJson(), isEmpty);
      expect(FactoryFloors.fromJson(null).isEmpty, isTrue);

      final f = FactoryFloors()..assign('s', _bp(), rates: _mill);
      final rec = f['s']!.toJson();
      expect(rec.keys, unorderedEquals(['bp', 'rates']));

      f
          .open('s', (bp) => FakeSim(bp.copy()))!
          .place(
            const Placement(id: 0, kind: EntityKind.chest, pos: TilePos(2, 2)),
          );
      final saved = FactoryFloors.fromJson(
        jsonDecode(jsonEncode(f.toJson())) as Map<String, Object?>,
      );
      expect(saved['s']!.dirty, isTrue);
      expect(saved['s']!.live, isNull);
      expect(saved['s']!.blueprint.placements, hasLength(1));
    });

    test('saving mid-edit keeps the edit designed; a look stays clean', () {
      // Why: close() is what marks an edit designed, so a save with the
      // editor open used to write the edited layout as a template, and a
      // later "reset templates" would throw the player's design away. A
      // floor only being looked at must keep its rates (not dirty).
      final f = FactoryFloors()..assign('s', _bp(), rates: _mill);
      f.open('s', (bp) => FakeSim(bp));
      var j = f['s']!.toJson();
      expect(j.containsKey('designed'), isFalse);
      expect(j.containsKey('dirty'), isFalse, reason: 'looked at, not edited');

      f['s']!.live!.place(
        const Placement(id: 0, kind: EntityKind.belt, pos: TilePos(1, 1)),
      );
      j = f['s']!.toJson();
      expect(j['designed'], isTrue);
      expect(j['dirty'], isTrue);
      final back = FloorRecord.fromJson(
        jsonDecode(jsonEncode(j)) as Map<String, Object?>,
      );
      expect(back.designed, isTrue);
      expect(back.dirty, isTrue);
      expect(back.blueprint.placements, hasLength(1));
    });
  });
}
