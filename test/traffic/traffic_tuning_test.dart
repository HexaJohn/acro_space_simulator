// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

/// The tunables are statics, and statics outlive the test that turned them:
/// [AgentTuning.reset] is what keeps one test's knob out of the next, so it
/// is checked against every knob there is.
void main() {
  tearDown(AgentTuning.reset);

  test("the defaults are the design's (§15.4)", () {
    expect(AgentTuning.agentsOn, isTrue);
    expect(AgentTuning.pathExpansionsPerStep, 4000);
    expect(AgentTuning.readoutWorkPerStep, 24000);
    expect(AgentTuning.pedExpansionsPerStep, 1500);
    expect(AgentTuning.maxVehicles, 4096);
    expect(AgentTuning.maxPeds, 4096);
    expect(AgentTuning.maxQueuedPaths, 512);
    expect(AgentTuning.maxQueuedServicePaths, 128);
    expect(AgentTuning.maxSpawnsPerStep, 24);
    expect(AgentTuning.stuckDespawnS, 120);
    expect(AgentTuning.impatientGrantS, 25);
    expect(AgentTuning.dontBlockBox, isTrue);
    expect(AgentTuning.dispatchByPathCost, isFalse);
    expect(AgentTuning.activityDwellScale, 1.0);
    expect(AgentTuning.outOfTownShare, 0.08);
    expect(AgentTuning.fleetUpkeep, 0.02);
    expect(AgentTuning.connectionsAllowMigration, isFalse);
    expect(AgentTuning.freightRail, isFalse);
    expect(AgentTuning.maxAgentSubStepsPerFrame, 4);
    expect(AgentTuning.maxHeldCityS, 15);
    expect(AgentTuning.congestionEpochS, 2.0);
    expect(AgentTuning.laneFlowPerMin, 30);
    expect(AgentTuning.buildingSyncS, 2.0);
    expect(AgentTuning.warmupS, 10);
    expect(AgentTuning.graphBuildInlineMaxRoads, 3000);
  });

  test('reset puts back every knob a test turned', () {
    final defaults = AgentTuning.snapshot();

    AgentTuning.agentsOn = false;
    AgentTuning.pathExpansionsPerStep = 1;
    AgentTuning.readoutWorkPerStep = 1;
    AgentTuning.pedExpansionsPerStep = 1;
    AgentTuning.maxVehicles = 1;
    AgentTuning.serviceReserveShare = 0.5;
    AgentTuning.maxPeds = 1;
    AgentTuning.maxQueuedPaths = 1;
    AgentTuning.maxQueuedServicePaths = 1;
    AgentTuning.maxSpawnsPerStep = 1;
    AgentTuning.warmupS = 1;
    AgentTuning.stuckDespawnS = 30;
    AgentTuning.impatientGrantS = 1;
    AgentTuning.dontBlockBox = false;
    AgentTuning.wedgeWaitS = 1;
    AgentTuning.wedgeHeads = 1;
    AgentTuning.allWayStopQueueCap = 1;
    AgentTuning.maxHandOversPerStep = 1;
    AgentTuning.congestionEpochS = 1;
    AgentTuning.congestionWindowS = 1;
    AgentTuning.laneFlowPerMin = 1;
    AgentTuning.buildingSyncS = 1;
    AgentTuning.commuteRatePerResident = 1;
    AgentTuning.commuteReturnMinS = 1;
    AgentTuning.commuteReturnMaxS = 2;
    AgentTuning.activityDwellScale = 2;
    AgentTuning.outOfTownShare = 1;
    AgentTuning.dispatchByPathCost = true;
    AgentTuning.freightEconomy = true;
    AgentTuning.fleetUpkeep = 1;
    AgentTuning.connectionsAllowMigration = true;
    AgentTuning.freightRail = true;
    AgentTuning.graphBuildInlineMaxRoads = 1;
    AgentTuning.maxAgentSubStepsPerFrame = 1;
    AgentTuning.maxHeldCityS = 1;

    final turned = AgentTuning.snapshot();
    expect(turned.keys, defaults.keys);
    for (final name in defaults.keys) {
      expect(turned[name], isNot(defaults[name]),
          reason: '$name is a knob this test does not turn yet: turn it '
              'above, so reset() is checked against it');
    }

    AgentTuning.reset();
    expect(AgentTuning.snapshot(), defaults);
  });
}
