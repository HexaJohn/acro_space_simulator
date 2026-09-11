// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/traffic/agents_codec.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// The agents' save block and switch (docs/plans/agent-traffic.md §14.1,
/// §14.4; §17.4 save_resume, slice 1's part): the block is the enabled
/// flag, so a save and a load keep agents on; an absent or foreign block
/// leaves them off; and switching them off drops everything they held.
void main() {
  tearDown(AgentTuning.reset);

  test('the save block is the flag, and a round trip keeps agents on', () {
    expect(AgentsCodec.encode(enabled: true), {'v': 1, 'enabled': true});
    expect(AgentsCodec.enabledOf({'v': 1, 'enabled': true}), isTrue);
    expect(AgentsCodec.enabledOf({'v': 1, 'enabled': false}), isFalse);
    expect(AgentsCodec.enabledOf(null), isNull, reason: 'no block: off');
    expect(AgentsCodec.enabledOf({'v': 2, 'enabled': true}), isNull,
        reason: 'a block this build cannot read is dropped');
    expect(AgentsCodec.enabledOf({'v': 1}), isNull);
    expect(AgentsCodec.enabledOf('agents'), isNull);

    final city = starterKit();
    final a = agentsOn(city);
    expect(a.hasState, isTrue);
    final json = jsonDecode(jsonEncode(a.toJson()));
    expect((CityAgents(city)..restore(json)).enabled, isTrue);
    expect((CityAgents(city)..restore(null)).enabled, isFalse);
    expect(CityAgents(city).hasState, isFalse,
        reason: 'a colony without agents writes no block');
  });

  test('switched off, the agents drop everything; the A/B knob pauses them',
      () {
    final idle = CityAgents(town());
    expect(idle.vehicles, isNull, reason: 'the constructor builds nothing');
    idle.advance(0.5);
    expect(idle.vehicles, isNull, reason: 'nor does a disabled advance');
    expect(idle.stats.commuteEff, 1.0);

    AgentTuning.commuteRatePerResident = 0.004;
    final a = agentsOn(town());
    runAgents(a, 60);
    expect(a.liveVehicles, greaterThan(0));
    AgentTuning.agentsOn = false;
    expect(a.enabled, isFalse);
    final t = a.timeUs;
    a.advance(0.5);
    expect(a.timeUs, t, reason: 'paused, not dropped');
    expect(a.liveVehicles, greaterThan(0));
    AgentTuning.agentsOn = true;
    final passes = a.readout.passes;
    expect(passes, greaterThan(0));
    a.enabled = false;
    expect(a.vehicles, isNull);
    expect(a.frame.count, 0);
    a.enabled = true;
    expect(a.readout.passes, passes,
        reason: 'the readout\'s count never goes back, even across a restart');
    runAgents(a, 30);
    expect(a.readout.passes, greaterThan(passes));
  });
}
