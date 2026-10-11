// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:math' as math;

import 'package:acro_space_simulator/domain/combat/base/base_modules.dart';
import 'package:acro_space_simulator/domain/combat/formation.dart';
import 'package:acro_space_simulator/domain/combat/launch/plan_operation.dart';
import 'package:acro_space_simulator/domain/combat/launch/snapshots.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:acro_space_simulator/domain/combat/operation_registry.dart';
import 'package:acro_space_simulator/domain/combat/powers/orbital.dart';
import 'package:acro_space_simulator/domain/combat/powers/overhead.dart';
import 'package:acro_space_simulator/domain/combat/powers/strike_window.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assault_test.dart' as a;

/// Orbital support: combat.md §7E.
void main() {
  const r = 1737e3; // the Moon

  group('overhead', () {
    const ground = Vector3(r, 0, 0);
    test('straight up at 100 km: strike and recon', () {
      final o = overheadOf(const Vector3(r + 100e3, 0, 0), ground);
      expect(o.strike, isTrue);
      expect(o.recon, isTrue);
      expect(o.slantM, closeTo(100e3, 1e-6));
    });
    test('20° up: recon only; below the horizon: nothing', () {
      // A point 300 km away along a line 20° above the local horizon.
      final el = 20 * math.pi / 180;
      final low = ground + Vector3(math.sin(el), math.cos(el), 0) * 300e3;
      final o = overheadOf(low, ground);
      expect(o.strike, isFalse);
      expect(o.recon, isTrue);
      expect(overheadOf(const Vector3(-r - 100e3, 0, 0), ground).recon, isFalse);
    });
    test('straight up past 2,500 km: too far to strike', () {
      final o = overheadOf(const Vector3(r + 3e6, 0, 0), ground);
      expect(o.strike, isFalse);
      expect(o.recon, isTrue);
    });
  });

  test('flight and scatter grow with range (ref §10A.12)', () {
    expect(strikeFlightS(100e3), 43);
    expect(strikeCepM(100e3), closeTo(10, 1e-9));
    expect(strikeCepM(2.5e6), closeTo(130, 1e-9));
    expect(strikeKillChance(13, 10), closeTo(0.8, 1e-9));
    expect(strikeKillChance(13, 130), lessThan(0.01));
  });

  test('the window predictor finds the next pass over the battle', () {
    const ground = Vector3(r, 0, 0);
    const radius = r + 100e3;
    final period = 2 * math.pi * math.sqrt(radius * radius * radius / 4.9028e12);
    final w = 2 * math.pi / period;
    // Starts a quarter orbit before passing straight over the target.
    Vector3 vessel(double t) {
      final a = w * t - math.pi / 2;
      return Vector3(radius * math.cos(a), radius * math.sin(a), 0);
    }

    final win = nextStrikeWindow(vesselAt: vessel, groundAt: (_) => ground, fromS: 0, stepS: 20)!;
    final mid = period / 4;
    expect((win.startS + win.endS) / 2, closeTo(mid, 2));
    expect(win.lengthS, greaterThan(100));
    expect(win.lengthS, lessThan(400));
    expect(overheadOf(vessel(win.startS - 2), ground).strike, isFalse);
    expect(overheadOf(vessel(win.startS + 2), ground).strike, isTrue);
  });

  test('rounds load, are aboard after the loading, and are spent one at a time', () {
    final reg = OperationRegistry();
    reg.loadRounds('v1', 4, 60 * 1000000);
    expect(reg.roundsAboard('v1'), 0);
    expect(reg.roundsLoading('v1'), 4);
    reg.clockUs = 60 * 1000000;
    expect(reg.roundsAboard('v1'), 4);
    reg.spendRound('v1');
    expect(reg.roundsAboard('v1'), 3);
    final back = OperationRegistry()..restore(jsonDecode(jsonEncode(reg.toJson())));
    expect(back.roundsAboard('v1'), 3);
  });

  group('a strike in the pools', () {
    SourceSnapshot source() {
      final s = a.source(troopers: 30);
      return SourceSnapshot(
        colonyId: s.colonyId,
        name: s.name,
        bodyId: s.bodyId,
        sources: s.sources,
        stock: {...s.stock, 'ore': 9999},
        supportAvailable: 20,
        buildings: const ['barracks', 'gunfactory', 'spaceport'],
      );
    }

    Operation assault({Roe roe = Roe.restrained}) {
      final src = source();
      final p = planColonyAssault(
        operationId: 1,
        target: a.independentTown(regulars: 8, emplacements: const [EmplacementSite('gun-1', 280, 30, 4)]),
        sources: [src],
        draws: [for (final s in src.sources) TrooperDraw('src', s.siteId, s.available)],
        garrison: 2,
        kitDays: 6,
        roe: roe,
        base: const BaseManifest(doctrine: Doctrine.manual),
      );
      return p.operation!;
    }

    void until(Operation op, bool Function() done, {int max = 5000}) {
      for (var i = 0; i < max && !done(); i++) {
        op.advance(1);
      }
    }

    Operation armed() {
      final op = assault();
      until(op, () => op.base!.deployed);
      op.orbital.assign('v1', 'Lunar Rod 1');
      op.orbital.byId('v1')!
        ..strike = true
        ..recon = true
        ..slantM = 100e3;
      op.orbital.roundsAboard['v1'] = 3;
      return op;
    }

    test('called on a gun emplacement, it fires at the first chance and lands 43 s later', () {
      final op = assault();
      until(op, () => op.base!.deployed);
      expect(op.strike('port'), contains('No orbital support'));
      op.orbital.assign('v1', 'Lunar Rod 1');
      expect(op.strike('port'), contains('rounds aboard'));
      op.orbital.roundsAboard['v1'] = 3;
      expect(op.strike('seat'), contains('rules of engagement'), reason: 'never the Seat');
      expect(op.strike('power'), contains('rules of engagement'), reason: 'Restrained: guns only');
      expect(op.strike('port'), isNull);
      expect(op.strike('port'), contains('already'));
      // Not overhead yet: it waits.
      op.advance(5);
      expect(op.orbital.inFlight, isEmpty);
      expect(op.orbital.queued, 'port');
      final v = op.orbital.byId('v1')!
        ..strike = true
        ..slantM = 100e3;
      op.advance(1);
      expect(op.orbital.inFlight, hasLength(1));
      expect(op.orbital.fired, ['v1']);
      expect(v.readyStep, op.clock.steps - 1 + kVesselCooldownS);
      final impact = op.orbital.inFlight.single.impactStep;
      expect(impact - (op.clock.steps - 1), 43);
      final gun = op.formations
          .firstWhere((f) => f.side == CombatSide.defender && f.kind == FormationKind.emplacement);
      final m = gun.morale;
      until(op, () => op.orbital.inFlight.isEmpty, max: 60);
      expect(op.orbital.craters, hasLength(1));
      expect(op.orbital.craters.single.diameterM, op.orbital.craterM);
      expect(op.orbital.notices.last, startsWith('Strike on port'));
      expect(gun.count == 0 || gun.morale < m, isTrue, reason: 'destroyed, or shaken');
      expect(op.orbital.pinnedAt('port', op.clock.steps), isTrue);
    });

    test('no uplink, no strike: it waits for the base', () {
      final op = armed();
      op.base!.reserve = 0;
      expect(op.strike('port'), isNull);
      op.advance(5);
      expect(op.orbital.inFlight, isEmpty, reason: 'the uplink needs two support staff');
      op.base!.reserve = 2;
      op.advance(1);
      expect(op.orbital.inFlight, hasLength(1));
    });

    test('Standard ROE may strike the Power plant; the cooldown spaces a vessel\'s rounds', () {
      final op = assault(roe: Roe.standard);
      until(op, () => op.base!.deployed);
      op.orbital.assign('v1', 'Rod');
      op.orbital.byId('v1')!
        ..strike = true
        ..slantM = 100e3;
      op.orbital.roundsAboard['v1'] = 3;
      expect(op.strike('power'), isNull);
      op.advance(1);
      op.orbital.fired.clear();
      expect(op.strike('power'), isNull);
      op.advance(10);
      expect(op.orbital.inFlight, hasLength(1), reason: 'rested 60 s first');
      op.advance(kVesselCooldownS.toDouble());
      expect(op.orbital.nextSeq, 2);
    });

    test('saved mid-flight, it lands the same', () {
      final op = armed();
      op.strike('port');
      op.advance(10);
      final back = Operation.fromJson((jsonDecode(jsonEncode(op.toJson())) as Map).cast<String, dynamic>());
      back.orbital.roundsAboard['v1'] = 2;
      op.orbital.roundsAboard['v1'] = 2;
      for (var i = 0; i < 60; i++) {
        op.advance(1);
        back.advance(1);
      }
      expect(jsonEncode(back.toJson()), jsonEncode(op.toJson()));
      expect(back.orbital.craters, hasLength(1));
    });
  });
}
