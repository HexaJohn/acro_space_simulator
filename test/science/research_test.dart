import 'package:acro_space_simulator/domain/science/experiment.dart';
import 'package:acro_space_simulator/domain/science/research_ledger.dart';
import 'package:acro_space_simulator/domain/science/tech_tree.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('running an experiment in a fresh situation yields science', () {
    final ledger = ResearchLedger();
    final exp = Experiment(
      id: 'crew-report',
      baseValue: 5,
    );
    final gained = ledger.runExperiment(exp, situation: 'lowOrbit:kerbin');
    expect(gained, closeTo(5, 1e-9));
    expect(ledger.science, closeTo(5, 1e-9));
  });

  test('repeating the same experiment+situation has diminishing returns', () {
    final ledger = ResearchLedger();
    final exp = Experiment(id: 'crew-report', baseValue: 10, diminishing: 0.5);

    final first = ledger.runExperiment(exp, situation: 'surface:mun');
    final second = ledger.runExperiment(exp, situation: 'surface:mun');
    expect(second, lessThan(first));
    // Different situation resets the diminishing return.
    final other = ledger.runExperiment(exp, situation: 'lowOrbit:mun');
    expect(other, closeTo(first, 1e-9));
  });

  test('a tech node unlocks only when affordable and prerequisites are met', () {
    final tree = TechTree(nodes: [
      const TechNode(id: 'basicRocketry', cost: 0),
      const TechNode(id: 'advRocketry', cost: 45, requires: ['basicRocketry']),
    ]);
    final ledger = ResearchLedger(tree: tree);

    // basicRocketry is free and root -> unlockable immediately.
    expect(ledger.unlock('basicRocketry'), isTrue);
    expect(ledger.isUnlocked('basicRocketry'), isTrue);

    // advRocketry needs 45 science; ledger has 0 -> rejected.
    expect(ledger.unlock('advRocketry'), isFalse);

    ledger.addScience(50);
    expect(ledger.unlock('advRocketry'), isTrue);
    expect(ledger.science, closeTo(5, 1e-9)); // 50 - 45 spent
  });

  test('a node with unmet prerequisites cannot be unlocked even if affordable', () {
    final tree = TechTree(nodes: [
      const TechNode(id: 'basicRocketry', cost: 10),
      const TechNode(id: 'advRocketry', cost: 10, requires: ['basicRocketry']),
    ]);
    final ledger = ResearchLedger(tree: tree)..addScience(100);
    // Skip basicRocketry -> advRocketry blocked by prerequisite.
    expect(ledger.unlock('advRocketry'), isFalse);
  });
}
