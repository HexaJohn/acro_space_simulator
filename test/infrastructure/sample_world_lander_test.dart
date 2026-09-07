// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/orbits/body_ephemeris.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// FLIGHT opens on the Lunar Module landed on the Moon: on the real ground,
/// on the sunlit side, nose up, with the CSM's orbit passing over the site.
void main() {
  final system = SampleWorld.realSystem();
  final moon = system.require(SampleWorld.moon);
  final lm = SampleWorld.buildLunarLander(id: 'moon-lander', name: 'Lunar Module');

  test('landed on the Moon, at rest', () {
    expect(lm.landed, isTrue);
    expect(lm.dominantBody, SampleWorld.moon);
    expect(lm.state.velocity.length, 0);
    expect(lm.id.value, 'moon-lander',
        reason: "the renderer picks the LM model by 'lander' in the id");
  });

  test('on the sunlit side: the site is the subsolar point', () {
    const ephemeris = BodyEphemeris();
    final moonRoot =
        ephemeris.positionRelativeToRoot(moon, system, Epoch.zero);
    final sunward = (-moonRoot).normalized;
    expect(lm.state.position.normalized.dot(sunward), greaterThan(0.9999));
  });

  test('standing on the terrain, not the datum sphere', () {
    final ground = moon.terrainGroundRadius(lm.state.position, Epoch.zero);
    expect((lm.state.position.length - ground).abs(), lessThan(0.01));
    expect(ground, isNot(closeTo(moon.radius, 1.0)),
        reason: 'the ground at a lunar site is off the datum; if it were '
            'not, seating on the datum would have been indistinguishable');
  });

  test('nose straight up', () {
    final nose = lm.state.attitude.rotate(Vector3.unitZ);
    expect(nose.dot(lm.state.position.normalized), greaterThan(0.9999));
  });

  test('the CSM starts directly over the landing site', () {
    final csm = SampleWorld.buildLunarOrbiter(id: 'csm', name: 'Service Module');
    expect(csm.state.position.normalized.dot(lm.state.position.normalized),
        greaterThan(0.9999));
    expect(csm.landed, isFalse);
  });
}
