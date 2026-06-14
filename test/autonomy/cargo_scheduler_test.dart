import 'package:acro_space_simulator/domain/autonomy/cargo_schedule.dart';
import 'package:acro_space_simulator/domain/autonomy/cargo_scheduler.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const scheduler = CargoScheduler();

  CargoSchedule schedule({required Epoch next}) => CargoSchedule(
        id: 'sch',
        carrier: const VesselId('freighter'),
        origin: const BodyId('kerbin'),
        destination: const BodyId('mun'),
        resource: ResourceType.ore,
        quantity: 100,
        period: 1000,
        nextDeparture: next,
      );

  test('dispatches a run whose departure time has arrived', () {
    final s = schedule(next: const Epoch(50));
    final dispatched = scheduler.process([s], now: const Epoch(60));
    expect(dispatched, contains('sch'));
    expect(s.status, CargoRunStatus.enRoute);
    // Next departure rolled forward by the period.
    expect(s.nextDeparture.seconds, closeTo(1050, 1e-9));
  });

  test('does not dispatch before the departure time', () {
    final s = schedule(next: const Epoch(500));
    final dispatched = scheduler.process([s], now: const Epoch(100));
    expect(dispatched, isEmpty);
    expect(s.status, CargoRunStatus.idle);
  });

  test('does not re-dispatch a run already en route', () {
    final s = schedule(next: const Epoch(0))..status = CargoRunStatus.enRoute;
    final dispatched = scheduler.process([s], now: const Epoch(100));
    expect(dispatched, isEmpty);
  });
}
