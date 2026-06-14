import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/lifesupport/crew.dart';
import 'package:acro_space_simulator/domain/radiation/radiation_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = RadiationService();

  Vessel crewed({double dose = 0, int count = 3}) {
    final v = Vessel(
      id: const VesselId('ship'),
      name: 'Ship',
      ownerId: 'p',
      state: const StateVector(position: Vector3(7e6, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
      stages: const [],
    );
    v.crew = CrewModule(
      count: count,
      accumulatedDose: dose,
      sicknessThresholdSv: 1.0,
      lethalDoseSv: 8.0,
    );
    return v;
  }

  test('crew accumulate dose over time at a given rate', () {
    final v = crewed();
    service.apply(v, doseRateSv: 0.01, dt: 10); // 0.1 Sv
    expect(v.crew!.accumulatedDose, closeTo(0.1, 1e-9));
  });

  test('crossing the sickness threshold raises CrewIrradiated once', () {
    final v = crewed(dose: 0.99);
    service.apply(v, doseRateSv: 0.01, dt: 10); // -> 1.09 Sv, sick
    final events = v.drainEvents();
    expect(events.whereType<CrewIrradiated>().length, 1);
    expect(v.crew!.sick, isTrue);

    // Further exposure (still below lethal) does not re-fire sickness.
    service.apply(v, doseRateSv: 0.01, dt: 10);
    expect(v.drainEvents().whereType<CrewIrradiated>(), isEmpty);
  });

  test('a lethal dose kills the crew and raises CrewLost(radiation)', () {
    final v = crewed(dose: 7.9);
    service.apply(v, doseRateSv: 0.05, dt: 10); // -> 8.4 Sv, lethal
    expect(v.crew!.count, 0);
    final events = v.drainEvents();
    expect(events.whereType<CrewLost>().any((e) => e.cause == 'radiation'), isTrue);
  });

  test('no crew -> nothing happens', () {
    final v = crewed();
    v.crew = null;
    service.apply(v, doseRateSv: 1.0, dt: 100);
    expect(v.drainEvents(), isEmpty);
  });

  test('zero dose rate accumulates nothing', () {
    final v = crewed();
    service.apply(v, doseRateSv: 0, dt: 100);
    expect(v.crew!.accumulatedDose, 0);
  });
}
