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
/// `CitySim.advance` with its own agents on and each settling its own
/// citizens as it grows (§6.2): one where a fifth of them own a car, whose
/// crossroads stay clear, and one where all of them do. The starter
/// crossroads are an all-way stop, and a fully built starter town where
/// everybody drives already queues there.
///
/// **Car ownership is the contrast, not the demand rate** (slice 3). While
/// `CommuteSynth` stood in, `commuteRatePerResident` WAS the number of trips
/// a town made. It is now the demand SCALE (§0 Q1): below the design rate it
/// turns commutes into errands rather than into fewer trips, so two towns at
/// different rates put much the same number of cars on the road. What makes
/// one town's roads busier than another's is how many of its people drive —
/// which is §6.6's own knob, and the one thing the two copies differ by here.
///
/// Nothing else is set by hand but the population at the very end, so that
/// the two have the same workforce; their staffing then differs by exactly
/// what their agents measured.
void main() {
  tearDown(AgentTuning.reset);

  test('a congested commute raises the trip ratio, lowers commute '
      'efficiency, and lowers staffing', () {
    final free = _town(0.2);
    final jammed = _town(1.0);
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

/// The City Builder town, its own agents on, where [ownership] of the people
/// who move in own a car (§6.6), after two and a half colony minutes.
///
/// Five times the design rate, in both: the demand scale sets how often a
/// citizen who HAS a car uses it, and the same figure in both towns is what
/// makes the drivers the only difference between them.
///
/// The window is 150 s because that is a living town: the starter kit feeds
/// about two hundred people, and a fully built one grows past that and then
/// starves, which is the colony economy's own behaviour and no business of
/// this test.
CitySim _town(double ownership) {
  AgentTuning.commuteRatePerResident = 5 * 0.00042;
  AgentTuning.carOwnership = ownership;
  final city = town(agentTraffic: true);
  run(city, 150);
  return city;
}
