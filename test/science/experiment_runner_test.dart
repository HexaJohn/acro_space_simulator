import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/science/experiment.dart';
import 'package:acro_space_simulator/domain/science/experiment_runner.dart';
import 'package:acro_space_simulator/domain/science/research_ledger.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const runner = ExperimentRunner();
  final body = SampleWorld.realSystem().require(SampleWorld.earth);

  Vessel sat(double altitude) {
    final v = Vessel(
      id: const VesselId('sci'),
      name: 'Sci',
      ownerId: 'p',
      state: StateVector(
        position: Vector3(body.radius + altitude, 0, 0),
        velocity: Vector3.zero,
      ),
      dominantBody: SampleWorld.earth,
      stages: const [],
    );
    v.experiments.add(const Experiment(id: 'thermometer', baseValue: 8));
    return v;
  }

  test('collects science on entering a new situation', () {
    final v = sat(200000); // lowOrbit:earth (above the ~140 km atmosphere)
    final ledger = ResearchLedger();
    final gained = runner.collect(v, body, ledger);
    expect(gained, greaterThan(0));
    expect(ledger.science, greaterThan(0));
    expect(v.lastScienceSituation, 'lowOrbit:earth');
  });

  test('does not re-collect in the same situation', () {
    final v = sat(200000);
    final ledger = ResearchLedger();
    runner.collect(v, body, ledger);
    final before = ledger.science;
    final second = runner.collect(v, body, ledger); // same situation
    expect(second, 0);
    expect(ledger.science, before);
  });

  test('collects again after moving to a different situation', () {
    final v = sat(200000); // lowOrbit
    final ledger = ResearchLedger();
    runner.collect(v, body, ledger);
    final afterFirst = ledger.science;

    // Move to a high orbit -> new situation -> more science.
    v.updateState(v.state.copyWith(position: Vector3(body.radius + 5000000, 0, 0)));
    final gained = runner.collect(v, body, ledger);
    expect(gained, greaterThan(0));
    expect(ledger.science, greaterThan(afterFirst));
    expect(v.lastScienceSituation, 'highOrbit:earth');
  });

  test('a vessel with no experiments collects nothing', () {
    final v = Vessel(
      id: const VesselId('none'),
      name: 'None',
      ownerId: 'p',
      state: StateVector(
        position: Vector3(body.radius + 200000, 0, 0),
        velocity: Vector3.zero,
      ),
      dominantBody: SampleWorld.earth,
      stages: const [],
    );
    final ledger = ResearchLedger();
    expect(runner.collect(v, body, ledger), 0);
  });
}
