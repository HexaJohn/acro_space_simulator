// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A measured floor draws in the COLONY's power units
/// (docs/plans/factory-floors.md §3 "Coupling to the colony", "Templates":
/// the template runs at the spec's rate, ±5%). The floor model's stations
/// draw real per-machine kilowatts, 8-100x below a spec's power units; a
/// measured template must still draw its spec's power, or moving one belt
/// (or a firm's layoff) would cut a plant's grid draw a hundredfold.
library;

import 'package:acro_space_simulator/application/factory/colony_floor_measurer.dart';
import 'package:acro_space_simulator/domain/colony/city/city_factories.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_measure.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_colony_fixture.dart';

/// Templates still drawn for arms, skipped like their own tests until their
/// port redraw (#19); their measured draw means nothing until then.
const Set<String> _awaitingPortRedraw = {
  'refinery', 'electronics', 'rocketfactory', 'gunfactory',
  'missilefactory', 'rationsfactory',
};

void main() {
  final ready = [
    for (final t in kFactoryPlantTypes)
      if (!_awaitingPortRedraw.contains(t)) t,
  ];
  final measured = <String, MeasuredRates>{};
  setUpAll(() {
    for (final t in ready) {
      measured[t] = measureBlueprint(factoryTemplateFor(t)!,
          buildFloorForMeasure, settings: measureSettingsFor(t));
    }
  });

  // The pins are what the calibration divides by: a template edit that
  // changes its stations' draw must re-pin, or every measured floor of
  // that plant draws the wrong power.
  test('the pinned template draws are what the measurer reads', () {
    for (final t in ready) {
      expect(measured[t]!.powerKw,
          closeTo(kTemplateMeasuredKw[t]!, kTemplateMeasuredKw[t]! * 0.01),
          reason: t);
    }
  });

  test('every measured template draws its spec power, calibrated', () {
    for (final t in ready) {
      final spec = specOf(t);
      final flat = flatRatesOf(spec).powerKw;
      expect(calibratedFloorRates(measured[t]!, spec).powerKw,
          closeTo(flat, flat * 0.05), reason: t);
    }
  });

  // Through the colony: a measurement stored for a placed plant keeps its
  // grid draw, and a design that halves its stations' kW halves it.
  test('applyFloorMeasure stores colony power', () {
    final sim = foundedColony();
    // The Steel Mill until Electronics gets its port redraw (#19).
    final lot = placeOnFreeLot(sim, specOf('steelmill'));
    final m = measured['steelmill']!;
    final rec = sim.factoryFloors[lot]!;
    expect(sim.applyFloorMeasure(lot, m, rev: rec.rev), isTrue);
    final flat = flatRatesOf(specOf('steelmill')).powerKw;
    expect(rec.rates.powerKw, closeTo(flat, flat * 0.05));
    final half = MeasuredRates(
        inPerS: m.inPerS,
        outPerS: m.outPerS,
        powerKw: m.powerKw / 2,
        jobs: m.jobs,
        seconds: m.seconds);
    expect(sim.applyFloorMeasure(lot, half, rev: rec.rev), isTrue);
    expect(rec.rates.powerKw, closeTo(flat / 2, flat * 0.03));
  });

  // The same plant over the same period books the same power bill with its
  // editor open as closed. The live floor counts its stations' real kW;
  // uncalibrated, opening the editor cut the firm's power cost 8-100x.
  test('a live floor books the energy its aggregate would', () {
    // The Steel Mill until Electronics gets its port redraw (#19).
    const type = 'steelmill';
    final settings = measureSettingsFor(type);
    final sim = foundedColony();
    final lot = placeOnFreeLot(sim, specOf(type));
    final floors = sim.factoryFloors;
    final port = InfiniteColonyPort();

    final window = settings.windowS;
    floors.takeLedger(lot);
    floors.stepAggregate(window, lot, port);
    final aggregate = floors.takeLedger(lot).energyKJ;
    expect(aggregate, greaterThan(0));

    expect(sim.openFloor(lot), isNotNull);
    for (var t = 0.0; t < settings.warmupS; t += 10) {
      floors.stepAggregate(10, lot, port);
    }
    floors.takeLedger(lot); // discard the start-up
    for (var t = 0.0; t < window; t += 10) {
      floors.stepAggregate(10, lot, port);
    }
    final live = floors.takeLedger(lot).energyKJ;
    expect(live, closeTo(aggregate, aggregate * 0.05),
        reason: 'live ${live.toStringAsFixed(0)} kJ vs '
            'aggregate ${aggregate.toStringAsFixed(0)} kJ');
    sim.closeFloor(lot);
  });
}
