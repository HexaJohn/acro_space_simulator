import 'package:acro_space_simulator/domain/parts/jet_engine.dart';
import 'package:acro_space_simulator/domain/universe/atmosphere_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const jet = JetEngine(
    name: 'J-X4 Whiplash',
    maxStaticThrust: 130000, // N at sea level, static
    optimalMach: 3.0,
    machThrustMultiplier: 2.5, // ram boost at high mach
    intakeAreaRequired: 0.5,
  );

  const seaLevel = AtmosphereSample(
    pressure: 101325,
    density: 1.225,
    temperature: 288,
    speedOfSound: 340,
  );

  test('produces thrust when fed enough intake air in atmosphere', () {
    final t = jet.thrust(
      ambient: seaLevel,
      machNumber: 0.0,
      throttle: 1.0,
      intakeAirAvailable: 1.0,
    );
    expect(t, greaterThan(0));
  });

  test('flames out in vacuum (no air to breathe)', () {
    final t = jet.thrust(
      ambient: AtmosphereSample.vacuum,
      machNumber: 5.0,
      throttle: 1.0,
      intakeAirAvailable: 1.0,
    );
    expect(t, 0);
  });

  test('flames out without enough intake air', () {
    final t = jet.thrust(
      ambient: seaLevel,
      machNumber: 0.0,
      throttle: 1.0,
      intakeAirAvailable: 0.1, // below required 0.5
    );
    expect(t, 0);
  });

  test('ram effect boosts thrust toward the optimal mach then falls off', () {
    final atStatic = jet.thrust(
        ambient: seaLevel, machNumber: 0.0, throttle: 1.0, intakeAirAvailable: 1.0);
    final atOptimal = jet.thrust(
        ambient: seaLevel, machNumber: 3.0, throttle: 1.0, intakeAirAvailable: 1.0);
    final wayPast = jet.thrust(
        ambient: seaLevel, machNumber: 6.0, throttle: 1.0, intakeAirAvailable: 1.0);
    expect(atOptimal, greaterThan(atStatic)); // ram boost
    expect(wayPast, lessThan(atOptimal)); // falls off past optimal
  });

  test('thinner air reduces thrust', () {
    const thin = AtmosphereSample(
        pressure: 20000, density: 0.2, temperature: 250, speedOfSound: 300);
    final dense = jet.thrust(
        ambient: seaLevel, machNumber: 1.0, throttle: 1.0, intakeAirAvailable: 1.0);
    final thinT = jet.thrust(
        ambient: thin, machNumber: 1.0, throttle: 1.0, intakeAirAvailable: 1.0);
    expect(thinT, lessThan(dense));
  });
}
