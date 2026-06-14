import 'package:acro_space_simulator/domain/planetary/planet_surface.dart';
import 'package:acro_space_simulator/domain/planetary/splashdown_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = SplashdownService(landSafeSpeed: 12, waterSafeSpeed: 30);

  test('water raises the safe touchdown speed above land', () {
    expect(service.safeSpeedFor(Biome.ocean), greaterThan(service.safeSpeedFor(Biome.desert)));
  });

  test('a moderate-speed water landing survives where a land landing would not', () {
    // 20 m/s: lethal on land (>12), survivable on water (<30).
    expect(service.survives(biome: Biome.desert, speed: 20), isFalse);
    expect(service.survives(biome: Biome.ocean, speed: 20), isTrue);
  });

  test('a very fast impact is lethal even on water', () {
    expect(service.survives(biome: Biome.ocean, speed: 100), isFalse);
  });

  test('water contact quenches part heat; land does not', () {
    expect(service.heatQuenchFraction(Biome.ocean), greaterThan(0));
    expect(service.heatQuenchFraction(Biome.desert), 0);
  });

  test('ice caps behave like a firm but slightly forgiving surface', () {
    final ice = service.safeSpeedFor(Biome.iceCap);
    expect(ice, greaterThanOrEqualTo(service.safeSpeedFor(Biome.desert)));
    expect(ice, lessThanOrEqualTo(service.safeSpeedFor(Biome.ocean)));
  });
}
