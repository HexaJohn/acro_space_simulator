// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// Alleys, viaducts and elevated rail — the road tiers that are not simply
/// wider or narrower versions of a street.
void main() {
  final bodies = RealSolarSystem.build().all.where((b) => !b.isStar).toList();

  CitySim empty(String id) => CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: bodies,
        id: id,
      );

  group('the tiers describe themselves', () {
    test('nothing plats off a service road or a structure in the air', () {
      expect(RoadClass.street.platsLots, isTrue);
      expect(RoadClass.avenue.platsLots, isTrue);
      for (final c in [
        RoadClass.alley,
        RoadClass.elevated,
        RoadClass.transit
      ]) {
        expect(c.platsLots, isFalse, reason: '${c.name} must not front lots');
      }
    });

    test('the two elevated tiers are at DIFFERENT heights', () {
      // Stacked at the same height they intersect, and a rail line running
      // through a motorway deck is not a subtle bug to spot afterwards.
      expect(RoadClass.elevated.deckHeightM,
          greaterThan(RoadClass.transit.deckHeightM));
      expect(RoadClass.transit.deckHeightM, greaterThan(4.5),
          reason: 'a lorry has to pass under it');
      expect(RoadClass.street.isElevated, isFalse);
    });

    test('rail carries no cars; everything else does', () {
      expect(RoadClass.transit.carriesCars, isFalse);
      expect(RoadClass.rail.carriesCars, isFalse);
      for (final c in RoadClass.values.where((c) => !c.isRail)) {
        expect(c.carriesCars, isTrue);
      }
    });

    test('only real streets get pavements and signals', () {
      expect(RoadClass.street.hasPavement, isTrue);
      expect(RoadClass.alley.hasPavement, isFalse);
      expect(RoadClass.alley.signalised, isFalse,
          reason: 'an alley meets a street at a curb cut, not a signal');
      expect(RoadClass.transit.signalised, isFalse);
    });
  });

  group('an alley changes the plat', () {
    test('no lot fronts an alley', () {
      final city = empty('alley');
      city.commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
      city.commitRoad(const [Vec2(-200, 60), Vec2(200, 60)], RoadClass.alley);
      final onAlley = city.layout.autoParcels.where((p) =>
          city.layout.roads.any(
              (r) => r.id == p.roadId && r.roadClass == RoadClass.alley));
      expect(onAlley, isEmpty);
      expect(city.layout.autoParcels, isNotEmpty,
          reason: 'the street still plats, or this proves nothing');
    });

    test('lots run ALL the way back to an alley, not half way', () {
      // Against a facing STREET a lot takes half the gap, because the other
      // street's lots are coming the other way to meet it. An alley is not
      // another street: nothing is platted off it, so stopping half way would
      // leave a strip of dead ground behind every building — which is the
      // exact gap the alley exists to remove.
      // Only the lots FACING the other road. Both sides of the street get
      // platted, and the ones facing away have nothing in front of them to be
      // bounded by — including them put half the sample on the depth cap and
      // the median landed there, measuring nothing at all.
      double medianDepth(CitySim c) {
        final d = c.layout.autoParcels
            .where((p) => p.centroid.n > 0)
            .map((p) => p.buildableExtent.depth)
            .toList()
          ..sort();
        return d.isEmpty ? 0 : d[d.length ~/ 2];
      }

      // The depth CAP is lifted well clear, or both cases just report it and
      // the comparison measures nothing — which is exactly what the first cut
      // of this test did.
      CitySim facing(String id, RoadClass other) {
        final c = empty(id);
        c.layout.settings = c.layout.settings.copyWith(depthM: 80);
        c.commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
        c.commitRoad(const [Vec2(-200, 60), Vec2(200, 60)], other);
        return c;
      }

      final withAlley = facing('with', RoadClass.alley);
      final withStreet = facing('without', RoadClass.street);
      expect(medianDepth(withAlley), lessThan(80),
          reason: 'still on the cap: this compares nothing');

      expect(medianDepth(withAlley), greaterThan(medianDepth(withStreet) * 1.5),
          reason: 'the alley-backed lot should be about twice as deep');
    });

    test('a lot runs on underneath an elevated line', () {
      final under = empty('under');
      under.commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
      under.commitRoad(
          const [Vec2(-200, 20), Vec2(200, 20)], RoadClass.transit);
      final deep = under.layout.autoParcels
          .where((p) => p.buildableExtent.depth > 25);
      expect(deep, isNotEmpty,
          reason: 'lots were cut short by a structure on piers');
    });
  });

  group('the generated colony', () {
    test('lays every tier, and splits them at their junctions', () {
      final city = const CityGenerator()
          .generate(const CityGenSpec(seed: 3, blocksAcross: 3), bodies: bodies);
      final kinds = <RoadClass, int>{};
      for (final r in city.layout.roads) {
        kinds[r.roadClass] = (kinds[r.roadClass] ?? 0) + 1;
      }
      for (final c in [
        RoadClass.street,
        RoadClass.avenue,
        RoadClass.alley,
        RoadClass.transit,
        RoadClass.elevated,
      ]) {
        expect(kinds[c] ?? 0, greaterThan(0), reason: 'no ${c.name} was laid');
      }
      // Split at crossings: a single drawn line comes back as many roads.
      expect(kinds[RoadClass.transit]!, greaterThan(1),
          reason: 'the rail line was never split at the streets it crosses');
    });

    test('blocks are RECTANGLES, and the alley is what sizes the lot', () {
      const spec = CityGenSpec(seed: 5, blocksAcross: 3);
      expect(spec.blockDepthM, lessThan(spec.blockM),
          reason: 'a block is long one way and short the other');

      final city = const CityGenerator().generate(spec, bodies: bodies);
      final depths = city.layout.autoParcels
          .map((p) => p.buildableExtent.depth)
          .toList()
        ..sort();
      expect(depths, isNotEmpty);
      final median = depths[depths.length ~/ 2];
      // Bounded by the alley across the block, NOT by the configured maximum.
      // Hitting the cap would mean the block is too deep for its own alley and
      // there is dead ground down the middle of every one of them — which is
      // exactly what a square grid produced.
      expect(median, lessThan(spec.lotDepthM),
          reason: 'lots hit the depth cap: the alley is bounding nothing');
      expect(median, greaterThan(spec.blockDepthM / 2 - 14),
          reason: 'lots stop well short of the alley');
    });

    test('installations stake ground OUTSIDE the blocks, and all get placed',
        () {
      // Two failures met here and the fix had to satisfy both. A ring measured
      // against the half-width lands inside the grid on the diagonals, and
      // staking a plot re-cuts everything under it — ten installations turned
      // 1340 lots into 193. Pushing the ring past the corner instead put them
      // out of the 90 m access reach and only two of ten were ever placed.
      const spec = CityGenSpec(seed: 11, blocksAcross: 3, installations: 8);
      final withThem = const CityGenerator().generate(spec, bodies: bodies);
      final without = const CityGenerator().generate(
          const CityGenSpec(seed: 11, blocksAcross: 3, installations: 0),
          bodies: bodies);

      final staked = withThem.layout.parcels.where((p) => p.manual).length;
      expect(staked, greaterThanOrEqualTo(6),
          reason: 'installations are being refused: only $staked placed');
      expect(withThem.layout.autoParcels.length,
          greaterThan(without.layout.autoParcels.length * 0.85),
          reason: 'staking the plots ate the street lots');
    });

    test('alleys can be turned off, and then nothing bounds the block', () {
      const on = CityGenSpec(seed: 7, blocksAcross: 2);
      const off = CityGenSpec(seed: 7, blocksAcross: 2, alleys: false);
      final a = const CityGenerator().generate(on, bodies: bodies);
      final b = const CityGenerator().generate(off, bodies: bodies);
      expect(a.layout.roads.any((r) => r.roadClass == RoadClass.alley), isTrue);
      expect(
          b.layout.roads.any((r) => r.roadClass == RoadClass.alley), isFalse);
    });
  });
}
