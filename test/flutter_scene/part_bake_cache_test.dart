// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/part_bake_cache.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/part_primitives_category.dart';
import 'package:flutter_test/flutter_test.dart';

/// What can be checked about the shared bake cache and the primitive fallback
/// WITHOUT a GPU: which asset is asked for once, which failures are remembered,
/// and which tier answers for each catalog part.
///
/// Nothing here loads a real bake. The shipped `.fsceneb` files are 36-91 MB
/// each and their parse plus KTX2 transcode is tens of seconds of CPU, so a
/// test that touched one would not be a test. Every asset named below is
/// deliberately absent from the bundle, which exercises exactly the path a
/// fresh clone takes (the source models are licensed for use but not
/// redistribution and are never committed).
///
/// Building an `fs.Mesh` needs an Impeller context and cannot run headless, so
/// the fallback is tested at its DECISION — which tier answers — rather than at
/// its geometry.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// [PartBakeCache.bake]'s error, or null if it somehow succeeded. Awaiting
  /// through a try/catch rather than `throwsA` so a future that resolves is a
  /// clear failure rather than a timeout.
  Future<Object?> failureOf(Future<Object?> f) async {
    try {
      await f;
      return null;
    } catch (e) {
      return e;
    }
  }

  group('one parse per asset for the whole process', () {
    test('the same asset is loaded once, however many callers ask', () async {
      // The memoisation IS the feature: seven parts sharing one export must
      // queue one parse between them, not seven.
      const asset = 'assets/mesh/absent-alpha.fsceneb';
      final first = PartBakeCache.bake(asset);
      final second = PartBakeCache.bake(asset);
      expect(identical(first, second), isTrue,
          reason: 'a repeat caller gets the SAME future, not a second load');
      expect(await failureOf(first), isNotNull,
          reason: 'the asset is absent, so the shared load fails');
    });

    test('two assets get two loads', () async {
      final a = PartBakeCache.bake('assets/mesh/absent-beta.fsceneb');
      final b = PartBakeCache.bake('assets/mesh/absent-gamma.fsceneb');
      expect(identical(a, b), isFalse);
      expect(await failureOf(a), isNotNull);
      expect(await failureOf(b), isNotNull);
    });

    test('a failed load does not stall the assets queued behind it', () async {
      // The load chain is serialised, so a rejection that escaped the chain
      // would leave every later bake waiting on a future that never completes
      // — a craft that silently never gets its art.
      final broken = PartBakeCache.bake('assets/mesh/absent-delta.fsceneb');
      expect(await failureOf(broken), isNotNull);
      final next = PartBakeCache.bake('assets/mesh/absent-epsilon.fsceneb');
      expect(await failureOf(next), isNotNull,
          reason: 'it settled at all, rather than hanging behind the failure');
    });
  });

  group('a broken bake is attempted once per process', () {
    test('an unknown asset has not failed yet', () {
      expect(PartBakeCache.hasFailed('assets/mesh/absent-zeta.fsceneb'),
          isFalse);
    });

    test('the record is per asset, so one bad bake disables only itself', () {
      PartBakeCache.markFailed('assets/mesh/absent-eta.fsceneb');
      expect(PartBakeCache.hasFailed('assets/mesh/absent-eta.fsceneb'), isTrue);
      expect(PartBakeCache.hasFailed('assets/mesh/absent-theta.fsceneb'),
          isFalse,
          reason: 'a missing LM export must not disable the CSM');
    });

    test('prewarm records the failure rather than throwing at the caller',
        () async {
      // Prewarm is fire-and-forget from a screen's initState; an unhandled
      // rejection there would take down the zone the UI runs in.
      const asset = 'assets/mesh/absent-iota.fsceneb';
      PartBakeCache.prewarm(const [asset]);
      expect(await failureOf(PartBakeCache.bake(asset)), isNotNull);
      await pumpEventQueue();
      expect(PartBakeCache.hasFailed(asset), isTrue);
    });

    test('an empty queue is a no-op', () {
      PartBakeCache.prewarm(const []);
    });
  });

  group('every catalog part has a silhouette', () {
    final catalog = PartCatalog.standard();

    test('the LEM roster is already shaped by the id registry', () {
      // The registry keys are the English words a part id happens to contain.
      // All seven eagle-* ids contain one, which is why the category tier below
      // exists for the STOCK roster and not for these.
      for (final def in catalog.lem) {
        expect(PartPrimitivesByCategory.hasIdShape(def.id), isTrue,
            reason: '${def.id} should hit the shared id registry');
      }
    });

    test('the stock parts the id registry misses fall to their category', () {
      // Named individually rather than derived, so this test says which parts
      // were grey boxes before the category tier existed.
      const fellThrough = [
        'cockpit-mk1',
        'fl-t400',
        'merlin-1d',
        'rl10',
        'turbojet-j85',
        'ramjet-sr71',
        'ram-intake',
        'elevon',
        'tr-18a-decoupler',
        'landing-gear',
        'mk16-chute',
        'heat-shield-1',
        'thermometer',
        'docking-port-std',
      ];
      for (final id in fellThrough) {
        final def = catalog.byId(id);
        expect(def, isNotNull, reason: '$id left the catalog');
        expect(PartPrimitivesByCategory.hasIdShape(id), isFalse, reason: id);
        expect(PartPrimitivesByCategory.hasCategoryShape(def!.category), isTrue,
            reason: '$id draws by category or it draws as a grey box');
      }
    });

    test('no catalog part reaches the cuboid tier', () {
      // The cuboid is the honest answer for a category nobody has an opinion
      // about, not an answer any SHIPPED part should be getting: a roster where
      // several parts look identical is one a player cannot build from.
      final shapeless = <String>[];
      for (final def in catalog.all) {
        if (PartPrimitivesByCategory.hasIdShape(def.id)) continue;
        if (PartPrimitivesByCategory.hasCategoryShape(def.category)) continue;
        shapeless.add('${def.id} (${def.category.name})');
      }
      expect(shapeless, isEmpty);
    });

    test('every category the catalog uses is shaped', () {
      for (final c in PartCategory.values) {
        expect(PartPrimitivesByCategory.hasCategoryShape(c), isTrue,
            reason: '${c.name} is a category a part can be filed under');
      }
    });

    test('the id tier is asked before the category tier', () {
      // An id the registry knows must keep its registry shape even though its
      // category also has one, or adding a category shape would silently
      // restyle a part that already looked right.
      final tank = catalog.byId('eagle-fuel-tank')!;
      expect(PartPrimitivesByCategory.hasIdShape(tank.id), isTrue);
      expect(PartPrimitivesByCategory.hasCategoryShape(tank.category), isTrue,
          reason: 'both tiers can answer, so the order is what decides');
    });

    test('matching is case-insensitive, like every other part key lookup', () {
      expect(PartPrimitivesByCategory.hasIdShape('Eagle-Fuel-Tank'), isTrue);
    });
  });
}
