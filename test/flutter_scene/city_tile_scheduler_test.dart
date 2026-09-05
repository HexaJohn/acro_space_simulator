// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_scheduler.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_scheduler_isolate.dart';
import 'package:flutter_test/flutter_test.dart';

/// The scheduler seam: whichever binding meshes a tile, the answer is the
/// one the mesher gives inline — and a tile that has moved on drops the
/// answer to the build it abandoned.
void main() {
  const r = 1.7374e6;
  const body = 'moon';
  const anchor = Vector3(0, 0, r);

  BuildingSnapshot bldg(String id, String type, double x, double y,
          {double w = 24, double d = 24}) =>
      BuildingSnapshot(
        id: id,
        type: type,
        colonyId: 'c',
        body: body,
        px: x,
        py: y,
        pz: r,
        qw: 1,
        qx: 0,
        qy: 0,
        qz: 0,
        lat: 0,
        lon: 0,
        siteWidthM: w,
        siteDepthM: d,
        siteKindIndex: 0,
        colorArgb: 0xFF808080,
      );

  RoadSnapshot road(List<(double, double)> xy) => RoadSnapshot(
        colonyId: 'c',
        body: body,
        points: [for (final (x, y) in xy) ...[x, y, r]],
        halfWidthM: RoadClass.street.width / 2,
        roadClassIndex: RoadClass.street.index,
      );

  const knobs = CityMeshKnobs(
    styleId: 'masonry-street',
    bucketM: 6,
    variants: 4,
    perBuildingLod: true,
    blockRangeM: 300,
    interiorRangeM: 50,
    lodDebug: false,
    onStreetParking: true,
    sealedWorld: false,
    maxParkedCars: 400,
  );

  CityTileRequest request(String tileKey, String key,
          {CityTier tier = CityTier.near, double x = 0}) =>
      CityTileRequest(
        tileKey: tileKey,
        key: key,
        tier: tier,
        canDetail: tier == CityTier.near,
        anchorBF: anchor,
        buildings: [
          bldg('a', 'r-med', x - 40, 40),
          bldg('b', 'c-high', x + 40, -40, w: 36, d: 30),
        ],
        roads: [
          road([(x - 100, 0), (x + 100, 0)]),
        ],
        patches: const [],
        ends: const [],
        roadEnds: const [null, null],
        transitEnds: const [],
        focusBF: Vector3(x, 0, r + 30),
        colonyTier: BuildingDetail.full,
        epoch: 10,
        knobs: knobs,
      );

  void expectSame(CityTileResult got, CityTileResult want) {
    expect(got.tileKey, want.tileKey);
    expect(got.key, want.key);
    expect(got.groups.length, want.groups.length);
    for (var i = 0; i < want.groups.length; i++) {
      expect(got.groups[i].material, want.groups[i].material);
      expect(got.groups[i].castsShadow, want.groups[i].castsShadow);
      expect(got.groups[i].positions, want.groups[i].positions);
      expect(got.groups[i].normals, want.groups[i].normals);
      expect(got.groups[i].texCoords, want.groups[i].texCoords);
      expect(got.groups[i].indices, want.groups[i].indices);
    }
    expect(got.instances.map((g) => g.archetype).toList(),
        want.instances.map((g) => g.archetype).toList());
    for (var i = 0; i < want.instances.length; i++) {
      expect(got.instances[i].transforms, want.instances[i].transforms);
    }
    expect(got.treePits, want.treePits);
    expect(got.shrubPits, want.shrubPits);
    expect(got.lodCounts, want.lodCounts);
    expect(got.skylineTris, want.skylineTris);
  }

  group('the inline scheduler', () {
    test('queues on mesh and runs only when pumped', () async {
      final s = SyncCityTileScheduler();
      var done = false;
      final future = s.mesh(request('t', 'k')).then((r) {
        done = true;
        return r;
      });
      expect(s.inFlight, 1);
      // Nothing runs before a pump, however long the loop spins.
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      // A tiny budget runs one step and stops; no budget runs none, as
      // the build loop it serves has always done once its frame is spent.
      expect(s.pump(0), 0);
      final kinds = <CityMeshStepKind>[];
      expect(s.pump(1, onStep: (k, _) => kinds.add(k)), 1);
      expect(kinds, [CityMeshStepKind.roads]);
      expect(s.inFlight, 1);
      s.pumpAll();
      expect(s.inFlight, 0);
      final got = await future;
      expect(done, isTrue);
      expectSame(got,
          CityTileMesher.mesh(request('t', 'k'), CityBuildingLibraries()));
      s.dispose();
    });

    test('the budget loop books a kind and will not start one past it', () {
      final s = SyncCityTileScheduler();
      s.mesh(request('t', 'k'));
      // The first step always runs; after it, a step whose kind last cost
      // more than the budget has left waits.
      final costs = <CityMeshStepKind, int>{};
      final ran = s.pump(1, onStep: (k, us) => costs[k] = us);
      expect(ran, 1);
      expect(costs.keys, [CityMeshStepKind.roads]);
      // With that cost on the book and no room for it, the next pump of
      // the same budget still runs its one step — the rule is "one step
      // always runs" — and not the second.
      expect(s.pump(1), 1);
      s.pumpAll();
      s.dispose();
    });

    test('a disposed scheduler fails what it still held', () async {
      final s = SyncCityTileScheduler();
      final f = s.mesh(request('t', 'k'));
      s.dispose();
      expect(f, throwsStateError);
      expect(() => s.mesh(request('t', 'k')), throwsStateError);
    });
  });

  group('the isolate scheduler', () {
    test('answers with the bytes the inline mesher gives', () async {
      final s = PlatformCityTileScheduler(workers: 2);
      try {
        final want = [
          for (final tier in CityTier.values)
            CityTileMesher.mesh(
                request('t-${tier.name}', 'k', tier: tier),
                CityBuildingLibraries()),
        ];
        final got = await Future.wait([
          for (final tier in CityTier.values)
            s.mesh(request('t-${tier.name}', 'k', tier: tier)),
        ]);
        expect(s.inFlight, 0);
        for (var i = 0; i < want.length; i++) {
          expectSame(got[i], want[i]);
        }
        // The pump has nothing to run here.
        expect(s.pump(1000000), 0);
      } finally {
        s.dispose();
      }
    });

    test('spreads jobs over the pool and counts them until answered',
        () async {
      final s = PlatformCityTileScheduler(workers: 2);
      try {
        final futures = [
          for (var i = 0; i < 4; i++) s.mesh(request('t$i', 'k', x: i * 500.0)),
        ];
        expect(s.inFlight, 4);
        final results = await Future.wait(futures);
        expect(s.inFlight, 0);
        for (var i = 0; i < 4; i++) {
          expect(results[i].tileKey, 't$i');
          expect(results[i].groups, isNotEmpty);
        }
      } finally {
        s.dispose();
      }
    });
  });

  group('pending jobs', () {
    CityTileResult answer(String tileKey, String key) => CityTileResult(
          tileKey: tileKey,
          key: key,
          tier: CityTier.far,
          groups: const [],
          instances: const [],
          treePits: Float64List(0),
          shrubPits: Float64List(0),
          lodCounts: const {},
          skylineTris: 0,
        );

    test('a result for the build a tile waits on is taken once', () {
      final p = PendingTileJobs();
      p.start('t', 'k1');
      expect(p.count, 1);
      expect(p.accept(answer('t', 'k1')), isTrue);
      expect(p.count, 0);
      // The same answer again — a second job for one key — is dropped.
      expect(p.accept(answer('t', 'k1')), isFalse);
    });

    test('a stale result is dropped when the tile moved on', () {
      final p = PendingTileJobs();
      p.start('t', 'k1');
      // The tile was re-cut and resubmitted with a newer key.
      p.forget('t');
      p.start('t', 'k2');
      expect(p.accept(answer('t', 'k1')), isFalse);
      expect(p.isPending('t'), isTrue);
      expect(p.accept(answer('t', 'k2')), isTrue);
      expect(p.isPending('t'), isFalse);
    });

    test('a result for a tile nothing waits on is dropped', () {
      final p = PendingTileJobs();
      p.start('t', 'k1');
      p.forget('t');
      expect(p.accept(answer('t', 'k1')), isFalse);
      expect(p.accept(answer('other', 'k1')), isFalse);
      p.start('a', 'k');
      p.start('b', 'k');
      p.clear();
      expect(p.count, 0);
    });
  });
}
