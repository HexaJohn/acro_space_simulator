// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// §17.3 #14, `economy_follows_agents`, end to end (docs/plans/
/// agent-traffic.md §12.3, D33, E4): the commutes the agents measure move
/// what the economy runs on. A town whose commuters queue at its crossroads
/// measures its trips slower than free flow, so its trip ratio rises. It
/// then publishes a lower commute efficiency, and the next tick's staffing
/// takes that as it is.
///
/// Two copies of one City Builder town, each ticked by its own
/// `CitySim.advance` with its own agents on: one at a tenth of the design's
/// commute rate, whose crossroads stay clear, and one at five times it. The
/// starter crossroads are an all-way stop, and a fully built starter town
/// commuting at the design rate already queues there. Nothing is set by
/// hand but the population at the very end, so that the two have the same
/// workforce; their staffing then differs by exactly what their agents
/// measured.
void main() {
  tearDown(AgentTuning.reset);

  test('a congested commute raises the trip ratio, lowers commute '
      'efficiency, and lowers staffing', () {
    final design = AgentTuning.commuteRatePerResident;
    final free = _town(design / 10);
    final jammed = _town(5 * design);
    final fs = free.agents.stats, js = jammed.agents.stats;
    // ignore: avoid_print
    print('economy follows agents: free town ${fs.tripsDone} commutes, trip '
        'ratio ${fs.tripRatio.toStringAsFixed(3)}, failed '
        '${fs.failedShare.toStringAsFixed(3)}, commuteEff '
        '${fs.commuteEff.toStringAsFixed(3)}; congested town '
        '${js.tripsDone} commutes, trip ratio '
        '${js.tripRatio.toStringAsFixed(3)}, failed '
        '${js.failedShare.toStringAsFixed(3)}, commuteEff '
        '${js.commuteEff.toStringAsFixed(3)}');
    expect(fs.tripsDone, greaterThan(10));
    expect(js.tripsDone, greaterThan(10));
    expect(js.tripRatio, greaterThan(fs.tripRatio + 0.2),
        reason: 'queued commutes take longer against free flow');
    expect(js.commuteEff, lessThan(fs.commuteEff));

    // The same workforce for both, every job filled: staffing is then the
    // commute efficiency the agents published at the end of the previous
    // tick (the one-tick contract, §6.2).
    final eff = {free: fs.commuteEff, jammed: js.commuteEff};
    for (final city in [free, jammed]) {
      city.population = 2.0 * city.jobs;
      city.advance(0.02);
      expect(city.staffing, closeTo(eff[city]!, 1e-12));
    }
    expect(jammed.staffing, lessThan(free.staffing));
  });
}

/// The City Builder town, its own agents on and commuting at [rate] per
/// resident per second, after fifteen colony minutes.
CitySim _town(double rate) {
  AgentTuning.commuteRatePerResident = rate;
  final city = town(agentTraffic: true);
  run(city, 900);
  return city;
}
