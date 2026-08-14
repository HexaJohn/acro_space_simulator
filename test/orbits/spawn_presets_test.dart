// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/orbits/spawn_presets.dart';
import 'package:acro_space_simulator/domain/planetary/planet_surface.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/domain/universe/star_system.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/register_baked_dems.dart';

void main() {
  registerBakedDemsForTest(); // moon terrain now reads the baked DEM
  const presets = SpawnPresets();
  final system = RealSolarSystem.build();
  const epoch = Epoch.zero;

  SpawnPlacement resolve(SpawnPreset p) {
    final r = presets.resolve(p, system: system, epoch: epoch);
    expect(r, isNotNull, reason: '${p.label} should resolve in the real system');
    return r!;
  }

  /// Biome the tick's touchdown check would read at a placement.
  Biome biomeAt(CelestialBody body, Vector3 position) {
    final dir = position.normalized;
    return body.surface!.biomeAt(
      latitude: math.asin(dir.z.clamp(-1.0, 1.0)),
      longitude: math.atan2(dir.y, dir.x),
    );
  }

  group('SpawnPresets — orbits', () {
    test('low Earth orbit is circular at 400 km, inclined ~51.6 deg', () {
      final earth = system.require(const BodyId('earth'));
      final p = resolve(SpawnPreset.lowEarthOrbit);

      expect(p.body, const BodyId('earth'));
      expect(p.landed, isFalse);
      final r = p.state.position.length;
      expect(r, closeTo(earth.radius + SpawnPresets.leoAltitude, 1e-6));
      // Circular: speed == the local circular speed, and velocity is purely
      // horizontal (no radial component).
      expect(p.state.velocity.length, closeTo(math.sqrt(earth.mu / r), 1e-6));
      expect(p.state.velocity.dot(p.state.position.normalized), closeTo(0, 1e-6));
      // Above the modelled 140 km atmosphere, so it won't decay while you look.
      expect(r - earth.radius,
          greaterThan(earth.atmosphere!.atmosphereHeight));

      // Inclination measured off the body's EQUATOR (not the ecliptic).
      final h = p.state.position.cross(p.state.velocity).normalized;
      final inc = math.acos(h.dot(earth.spinAxisInertial).clamp(-1.0, 1.0));
      expect(inc, closeTo(SpawnPresets.leoInclination, 1e-6));
    });

    test('low lunar orbit is circular at 100 km in the Moon\'s equator', () {
      final moon = system.require(const BodyId('moon'));
      final p = resolve(SpawnPreset.lowLunarOrbit);

      expect(p.body, const BodyId('moon'));
      final r = p.state.position.length;
      expect(r, closeTo(moon.radius + SpawnPresets.lloAltitude, 1e-6));
      expect(p.state.velocity.length, closeTo(math.sqrt(moon.mu / r), 1e-6));
      final h = p.state.position.cross(p.state.velocity).normalized;
      expect(h.dot(moon.spinAxisInertial), closeTo(1.0, 1e-9)); // equatorial
    });

    test('the Saturn preset orbits inside the drawn ring band, in-plane', () {
      final saturn = system.require(const BodyId('saturn'));
      final p = resolve(SpawnPreset.saturnRings);

      final radii = p.state.position.length / saturn.radius;
      // The renderer draws Saturn's sheet across 1.2R..2.3R.
      expect(radii, greaterThan(1.2));
      expect(radii, lessThan(2.3));
      // In the ring plane = the tilted equator, so the particle field surrounds
      // the craft instead of sitting above or below it.
      expect(p.state.position.dot(saturn.spinAxisInertial).abs(),
          lessThan(1e-6 * saturn.radius));
      final h = p.state.position.cross(p.state.velocity).normalized;
      expect(h.dot(saturn.spinAxisInertial), closeTo(1.0, 1e-9));
      expect(p.state.velocity.length,
          closeTo(math.sqrt(saturn.mu / p.state.position.length), 1e-6));
    });

    test('orbital spawns point the nose prograde with up radially out', () {
      for (final preset in [
        SpawnPreset.lowEarthOrbit,
        SpawnPreset.lowLunarOrbit,
        SpawnPreset.saturnRings,
      ]) {
        final p = resolve(preset);
        final nose = p.state.attitude.rotate(Vector3.unitZ);
        final up = p.state.attitude.rotate(Vector3.unitY);
        expect(nose.dot(p.state.velocity.normalized), closeTo(1.0, 1e-9),
            reason: preset.label);
        expect(up.dot(p.state.position.normalized), closeTo(1.0, 1e-9),
            reason: preset.label);
      }
    });
  });

  group('SpawnPresets — surface', () {
    test('Earth surface lands on dry land, above sea level', () {
      final earth = system.require(const BodyId('earth'));
      final p = resolve(SpawnPreset.earthSurface);

      expect(p.body, const BodyId('earth'));
      expect(p.landed, isTrue);
      // Sitting exactly on the terrain — the radius the tick's touchdown clamps
      // a lander to, so a spawned craft and a landed one agree.
      final ground = earth.terrainGroundRadius(p.state.position, epoch);
      expect(p.state.position.length, closeTo(ground, 1e-6));
      expect(ground, greaterThan(earth.terrainField!.seaRadius));
      expect(biomeAt(earth, p.state.position), isNot(Biome.ocean));
    });

    test('Earth ocean floats at sea level over an ocean biome', () {
      final earth = system.require(const BodyId('earth'));
      final p = resolve(SpawnPreset.earthOcean);

      expect(p.landed, isTrue);
      final sea = earth.terrainField!.seaRadius;
      expect(p.state.position.length, closeTo(sea, 1e-6));
      // The sea floor is genuinely below the craft (a basin, not a hilltop).
      expect(earth.terrainGroundRadius(p.state.position, epoch), lessThan(sea));
      // And the tick would treat a touchdown here as a splashdown.
      expect(biomeAt(earth, p.state.position), Biome.ocean);
    });

    test('the Moon preset lands on lunar terrain', () {
      final moon = system.require(const BodyId('moon'));
      final p = resolve(SpawnPreset.moonSurface);

      expect(p.body, const BodyId('moon'));
      expect(p.landed, isTrue);
      // Tolerance is a millimetre, not a micron. The spawn samples the ground
      // along a direction and places the craft at `dir * groundR`; this
      // re-samples from that POSITION, which has to be re-normalised, and the
      // round trip is not bit-identical. With craters in the field the local
      // gradient is steep enough that a last-bit direction difference moves the
      // height by ~10 microns. The assertion here is "standing on the ground",
      // which a millimetre states just as well.
      expect(p.state.position.length,
          closeTo(moon.terrainGroundRadius(p.state.position, epoch), 1e-3));
    });

    test('landed spawns stand upright and co-rotate with the ground', () {
      final earth = system.require(const BodyId('earth'));
      final p = resolve(SpawnPreset.earthSurface);

      final nose = p.state.attitude.rotate(Vector3.unitZ);
      expect(nose.dot(p.state.position.normalized), closeTo(1.0, 1e-9));
      // Velocity matches what the landed branch of the tick maintains, so the
      // craft doesn't jolt on its first step.
      final surfaceV = earth.surfaceVelocityAt(p.state.position);
      expect((p.state.velocity - surfaceV).length, lessThan(1e-6));
      expect(surfaceV.length, greaterThan(100)); // really is spinning
    });
  });

  group('SpawnPresets — custom body/altitude', () {
    test('customOrbit is circular + equatorial at the asked altitude', () {
      final moon = system.require(const BodyId('moon'));
      final p = presets.customOrbit(const BodyId('moon'),
          system: system, altitude: 250000)!;

      expect(p.body, const BodyId('moon'));
      expect(p.landed, isFalse);
      final r = p.state.position.length;
      expect(r, closeTo(moon.radius + 250000, 1e-6));
      expect(p.state.velocity.length, closeTo(math.sqrt(moon.mu / r), 1e-6));
      expect(
          p.state.velocity.dot(p.state.position.normalized), closeTo(0, 1e-6));
      // Equatorial: the orbit normal is the body's spin axis.
      final h = p.state.position.cross(p.state.velocity).normalized;
      expect(h.dot(moon.spinAxisInertial), closeTo(1.0, 1e-9));
      // Prograde attitude, same as the fixed orbital presets.
      final nose = p.state.attitude.rotate(Vector3.unitZ);
      expect(nose.dot(p.state.velocity.normalized), closeTo(1.0, 1e-9));
    });

    test('customOrbit floors a too-low altitude just above the relief', () {
      final earth = system.require(const BodyId('earth'));
      final p = presets.customOrbit(const BodyId('earth'),
          system: system, altitude: 0)!;

      // Terrain rides ±amplitude around the datum; "0 km" must come out
      // skimming above the highest possible peak, not inside it.
      final floor = earth.radius + earth.terrainField!.amplitude + 500;
      expect(p.state.position.length, closeTo(floor, 1e-6));
      expect(p.state.position.length,
          greaterThan(earth.terrainGroundRadius(p.state.position, epoch)));
      // And a HIGH altitude passes through untouched.
      final high = presets.customOrbit(const BodyId('earth'),
          system: system, altitude: 1.0e6)!;
      expect(high.state.position.length, closeTo(earth.radius + 1.0e6, 1e-6));
    });

    test('customLanded lands on terrain, upright, co-rotating', () {
      final moon = system.require(const BodyId('moon'));
      final p = presets.customLanded(const BodyId('moon'),
          system: system, epoch: epoch)!;

      expect(p.body, const BodyId('moon'));
      expect(p.landed, isTrue);
      // Millimetre tolerance for the same direction-renormalisation round trip
      // the Moon preset documents above.
      expect(p.state.position.length,
          closeTo(moon.terrainGroundRadius(p.state.position, epoch), 1e-3));
      final nose = p.state.attitude.rotate(Vector3.unitZ);
      expect(nose.dot(p.state.position.normalized), closeTo(1.0, 1e-9));
      expect(
          (p.state.velocity - moon.surfaceVelocityAt(p.state.position)).length,
          lessThan(1e-6));
    });

    test('custom resolvers decline a body that is not in the system', () {
      expect(
          presets.customOrbit(const BodyId('nope'),
              system: system, altitude: 100000),
          isNull);
      expect(
          presets.customLanded(const BodyId('nope'),
              system: system, epoch: epoch),
          isNull);
    });
  });

  test('every preset resolves, and does so deterministically', () {
    for (final preset in SpawnPreset.values) {
      final a = resolve(preset);
      final b = resolve(preset);
      expect((a.state.position - b.state.position).length, 0);
      expect((a.state.velocity - b.state.velocity).length, 0);
      expect(a.body, b.body);
      expect(a.landed, b.landed);
      expect(a.state.position.length.isFinite, isTrue);
      expect(a.state.velocity.length.isFinite, isTrue);
    }
  });

  test('a preset whose body is missing resolves to null', () {
    // A trimmed dev scenario (a system without Saturn) must decline, not crash.
    final trimmed = StarSystem(
      name: system.name,
      rootStar: system.rootStar,
      bodies: system.all.where((b) => b.id != const BodyId('saturn')),
    );
    expect(
      presets.resolve(SpawnPreset.saturnRings, system: trimmed, epoch: epoch),
      isNull,
    );
  });
}
