import 'package:acro_space_simulator/domain/colony/colony.dart';
import 'package:acro_space_simulator/domain/colony/flight_demand_service.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = FlightDemandService();

  Colony city() => Colony(
        id: 'c',
        name: 'C',
        body: const BodyId('earth'),
        latitude: 0,
        longitude: 0,
      );

  test('a cargo flight arrival raises industrial and commercial demand', () {
    final c = city();
    service.onCargoArrival(c, cargoUnits: 500);
    expect(c.demand.industrial, greaterThan(0));
    expect(c.demand.commercial, greaterThan(0));
    expect(c.demand.residential, 0);
  });

  test('a passenger flight raises residential and leisure (relaxation) demand', () {
    final c = city();
    service.onPassengerArrival(c, passengers: 50);
    expect(c.demand.residential, greaterThan(0));
    // Relaxation/leisure maps to commercial demand (shops/entertainment).
    expect(c.demand.commercial, greaterThan(0));
  });

  test('demand accumulates across multiple flights but stays capped at 1', () {
    final c = city();
    for (var i = 0; i < 100; i++) {
      service.onCargoArrival(c, cargoUnits: 1000);
    }
    expect(c.demand.industrial, lessThanOrEqualTo(1.0));
    expect(c.demand.industrial, greaterThan(0.5));
  });

  test('bigger cargo loads create proportionally more demand (until capped)', () {
    final small = city();
    final big = city();
    service.onCargoArrival(small, cargoUnits: 10);
    service.onCargoArrival(big, cargoUnits: 200);
    expect(big.demand.industrial, greaterThan(small.demand.industrial));
  });
}
