import 'dart:math' as math;

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/weather/weather_system.dart';
import 'package:acro_space_simulator/domain/weather/weather_updater.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const updater = WeatherUpdater();

  WeatherSystem system(WeatherCell cell) => WeatherSystem(
        body: const BodyId('kerbin'),
        cells: [cell],
      );

  test('a cell drifts in longitude under an eastward wind', () {
    final cell = const WeatherCell(
      latitude: 0,
      longitude: 0,
      radius: 500000,
      wind: Vector3(20, 0, 0), // 20 m/s east
      precipitation: 0.5,
      turbulence: 0.5,
    );
    final next = updater.advance(system(cell), bodyRadius: 600000, dt: 3600);
    expect(next.cells.first.longitude, greaterThan(0));
  });

  test('precipitation and turbulence decay over time', () {
    final cell = const WeatherCell(
      latitude: 0,
      longitude: 0,
      radius: 500000,
      wind: Vector3.zero,
      precipitation: 0.8,
      turbulence: 0.8,
    );
    final next = updater.advance(system(cell), bodyRadius: 600000, dt: 3600);
    expect(next.cells.first.precipitation, lessThan(0.8));
    expect(next.cells.first.turbulence, lessThan(0.8));
  });

  test('longitude wraps into [-pi, pi)', () {
    final cell = WeatherCell(
      latitude: 0,
      longitude: math.pi - 0.001,
      radius: 500000,
      wind: const Vector3(100000, 0, 0), // absurd wind to force a wrap
      precipitation: 0.5,
      turbulence: 0.5,
    );
    final next = updater.advance(system(cell), bodyRadius: 600000, dt: 3600);
    expect(next.cells.first.longitude, greaterThanOrEqualTo(-math.pi));
    expect(next.cells.first.longitude, lessThan(math.pi));
  });

  test('fully decayed cells are removed', () {
    final cell = const WeatherCell(
      latitude: 0,
      longitude: 0,
      radius: 500000,
      wind: Vector3.zero,
      precipitation: 0.001,
      turbulence: 0.001,
    );
    // Many ticks -> decays below threshold -> dropped.
    var sys = system(cell);
    for (var i = 0; i < 50; i++) {
      sys = updater.advance(sys, bodyRadius: 600000, dt: 3600);
    }
    expect(sys.cells, isEmpty);
  });
}
