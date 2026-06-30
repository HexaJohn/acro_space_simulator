import 'package:acro_space_simulator/domain/contracts/contract.dart';
import 'package:acro_space_simulator/domain/contracts/contract_tracker.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const tracker = ContractTracker();

  Contract reachMoon() => Contract(
        id: 'explore-moon',
        title: 'Reach the Moon',
        rewardFunds: 10000,
        rewardScience: 25,
        objectives: [
          ReachSituationObjective(situation: 'lowOrbit:moon'),
        ],
      );

  test('an objective completes when a matching event arrives', () {
    final c = reachMoon();
    expect(c.isComplete, isFalse);

    tracker.handleEvent(
      c,
      SituationEntered(const VesselId('v'), 'lowOrbit:moon'),
    );
    expect(c.objectives.first.done, isTrue);
    expect(c.isComplete, isTrue);
  });

  test('a non-matching event does not complete the objective', () {
    final c = reachMoon();
    tracker.handleEvent(
      c,
      SituationEntered(const VesselId('v'), 'lowOrbit:earth'),
    );
    expect(c.isComplete, isFalse);
  });

  test('multi-objective contract completes only when all are met', () {
    final c = Contract(
      id: 'multi',
      title: 'Mine and deliver',
      rewardFunds: 5000,
      rewardScience: 0,
      objectives: [
        MineResourceObjective(resource: 'ore'),
        ReachSituationObjective(situation: 'surface:moon'),
      ],
    );
    tracker.handleEvent(c, ResourceMined(const VesselId('v'), 'd1', 50));
    expect(c.isComplete, isFalse); // still need the situation

    tracker.handleEvent(c, SituationEntered(const VesselId('v'), 'surface:moon'));
    expect(c.isComplete, isTrue);
  });

  test('the board awards rewards once when a contract completes', () {
    final board = ContractBoard(contracts: [reachMoon()]);
    final reward = board.process(
      SituationEntered(const VesselId('v'), 'lowOrbit:moon'),
    );
    expect(reward.funds, 10000);
    expect(reward.science, 25);

    // Same event again -> no double reward (already completed).
    final again = board.process(
      SituationEntered(const VesselId('v'), 'lowOrbit:moon'),
    );
    expect(again.funds, 0);
    expect(again.science, 0);
  });
}
