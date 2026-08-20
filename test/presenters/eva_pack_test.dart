// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The EVA pack. The one thing that separates it from walking is that it is
// VELOCITY-controlled: releasing the stick coasts instead of stopping. Pinned
// here along with what makes it a pack and not a cheat — finite propellant, a
// thrust that loses to Earth and beats the Moon, and a landing that hands the
// walker back a surface to stand on.
import 'package:acro_space_simulator/adapters/presenters/eva_pack.dart';
import 'package:acro_space_simulator/adapters/presenters/first_person_walker.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const groundR = 1.0e6;
  double flat(Vector3 _) => groundR;
  final fwdNorth = Vector3(0, 1, 0);
  final rightEast = Vector3(1, 0, 0);
  Vector3 hovering({double lift = 20}) =>
      Vector3(0, 0, groundR + walkEyeHeight + lift);

  EvaStep fly({
    required Vector3 pos,
    Vector3? vel,
    double f = 0,
    double r = 0,
    double up = 0,
    double gravity = 1.62,
    double fuel = evaPropellantKg,
    double dt = 1 / 60,
    double Function(Vector3)? ground,
  }) =>
      stepEvaPack(
        posLocal: pos,
        velLocal: vel ?? Vector3.zero,
        forwardLocal: fwdNorth,
        rightLocal: rightEast,
        throttleForward: f,
        throttleRight: r,
        throttleUp: up,
        dt: dt,
        gravity: gravity,
        propellantKg: fuel,
        groundRadiusAt: ground ?? flat,
      );

  test('releasing the stick coasts — this is not walking', () {
    // One second of forward burn, then two seconds of nothing.
    var s = fly(pos: hovering(), f: 1);
    for (var i = 1; i < 60; i++) {
      s = fly(pos: s.posLocal, vel: s.velLocal, f: 1, fuel: s.propellantKg);
    }
    final cruising = s.velLocal.dot(fwdNorth);
    expect(cruising, greaterThan(1.0));
    for (var i = 0; i < 120; i++) {
      s = fly(pos: s.posLocal, vel: s.velLocal, fuel: s.propellantKg);
    }
    // Not exact: the frame is a SPHERE, so travelling north tilts the local
    // vertical under you and gravity's pull rotates a hair out of the fixed
    // +Y axis this measures against. Micrometres per second of it.
    expect(s.velLocal.dot(fwdNorth), closeTo(cruising, 1e-3),
        reason: 'nothing is holding you; forward speed must survive');
  });

  test('in near-weightlessness a nudge drifts forever', () {
    // Ryugu-ish: surface gravity ~1e-4 m/s^2.
    var s = fly(pos: hovering(lift: 500), f: 1, gravity: 1e-4);
    for (var i = 1; i < 30; i++) {
      s = fly(
          pos: s.posLocal, vel: s.velLocal, f: 1, gravity: 1e-4, fuel: s.propellantKg);
    }
    final v0 = s.velLocal.length;
    for (var i = 0; i < 600; i++) {
      s = fly(pos: s.posLocal, vel: s.velLocal, gravity: 1e-4, fuel: s.propellantKg);
    }
    expect(s.grounded, isFalse);
    expect(s.velLocal.length, closeTo(v0, v0 * 0.01));
  });

  test('the pack beats lunar gravity but loses to Earth', () {
    final moon = fly(pos: hovering(), up: 1, gravity: 1.62);
    expect(moon.velLocal.dot(Vector3(0, 0, 1)), greaterThan(0),
        reason: 'it can lift off the Moon');
    final earth = fly(pos: hovering(), up: 1, gravity: 9.80665);
    expect(earth.velLocal.dot(Vector3(0, 0, 1)), lessThan(0),
        reason: 'a pack this size cannot lift a suit on Earth');
  });

  test('propellant drains only while thrusting, and a dry pack just falls', () {
    var s = fly(pos: hovering(), up: 1);
    expect(s.propellantKg, lessThan(evaPropellantKg));
    expect(s.thrusting, isTrue);
    final coasting = fly(pos: hovering(), vel: s.velLocal, fuel: s.propellantKg);
    expect(coasting.propellantKg, s.propellantKg);
    expect(coasting.thrusting, isFalse);

    final dry = fly(pos: hovering(), up: 1, fuel: 0);
    expect(dry.thrusting, isFalse);
    expect(dry.velLocal.dot(Vector3(0, 0, 1)), lessThan(0),
        reason: 'no propellant, no thrust — only gravity');
  });

  test('a descent lands, keeps the tangential slide, and reports how hard', () {
    // Falling fast, moving sideways: contact must stop the fall, not the skid.
    final fast = fly(
      pos: Vector3(0, 0, groundR + walkEyeHeight + 0.01),
      vel: Vector3(3, 0, -10),
    );
    expect(fast.grounded, isTrue);
    expect(fast.hardContact, isTrue);
    expect(fast.posLocal.length, closeTo(groundR + walkEyeHeight, 1e-6));
    // The killed component is the radial AT CONTACT, which the sideways drift
    // has tilted a fraction of a microradian off +Z.
    expect(fast.velLocal.dot(Vector3(0, 0, 1)), closeTo(0, 1e-6));
    expect(fast.velLocal.x, closeTo(3, 1e-6), reason: 'the skid survives');

    // Close enough that half a metre per second crosses the floor inside one
    // frame — the fast case above starts higher because 10 m/s covers it.
    final gentle = fly(
      pos: Vector3(0, 0, groundR + walkEyeHeight + 0.004),
      vel: Vector3(0, 0, -0.5),
    );
    expect(gentle.grounded, isTrue);
    expect(gentle.hardContact, isFalse);
  });

  test('degenerate inputs are no-ops', () {
    final zero = fly(pos: Vector3.zero, f: 1);
    expect(zero.posLocal.length, 0);
    final noTime = fly(pos: hovering(), f: 1, dt: 0);
    expect(noTime.velLocal.length, 0);
  });
}
