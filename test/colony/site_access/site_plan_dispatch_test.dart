// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_envelope.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_program.dart';
import 'package:flutter_test/flutter_test.dart';

/// §3.3's fall-through rules in `planSite`, pinned with fake generators so no
/// test depends on a track's generator (docs/plans/site-access.md §3.3 as
/// built): which program is written, which flags it carries, which demotions
/// are counted, and which generators are asked.
void main() {
  final layout = CityLayout()
    ..addRoad(const RoadSpline(id: 'r0', controls: [Vec2(0, 0), Vec2(400, 0)]));
  final g = RoadGraph.of(layout);
  final parcel = layout.parcelById('lot-r0-l3')!;
  final lot = g.lotNoOf(parcel.id)!;
  final slot = g.joinOfRef(g.joinRefOf(lot, 0))!;

  final ind = kZoneSpecs['industrial']![Density.low]!;
  final com = kZoneSpecs['commercial']![Density.low]!;
  final solar =
      kUtilCatalog.firstWhere((s) => s.siteKind == SiteKind.field);

  /// An [w] × [d] lot centred on slot 0's join, 3 m behind its kerb.
  Parcel big(double w, double d) {
    final sn = slot.normN.sign;
    final yF = slot.kerbN + 3 * sn;
    Vec2 at(double s, double depth) => Vec2(s, yF + depth * sn);
    final x0 = slot.s - w / 2, x1 = slot.s + w / 2;
    return Parcel(
      id: parcel.id,
      polygon: [at(x0, 0), at(x1, 0), at(x1, d), at(x0, d)],
      roadId: 'r0',
      frontage: (at(x0, 0), at(x1, 0)),
    );
  }

  test('fixture: the lot is offered what each case needs', () {
    ProgramOffer offer(SiteContext c) => classifyProgram(
        spec: c.spec!,
        slot0: c.slot0,
        widthM: c.widthM,
        depthM: c.depthM,
        hasFrame: c.frame != null,
        lotBuilt: c.lotBuilt);
    expect(offer(SiteContext.ofLot(g, parcel, ind)).program, SiteProgram.yard);
    expect(offer(SiteContext.ofLot(g, parcel, com)).program,
        SiteProgram.carPark);
    final small = offer(SiteContext.ofLot(g, parcel, solar));
    expect(small.program, SiteProgram.yard);
    expect(small.demotion, SiteDemotion.installationTooSmall);
    final inst = SiteContext.debug(g, big(80, 150), solar,
        slots: [slot], graphLot: lot);
    expect(offer(inst).program, SiteProgram.installation);
  });

  /// Plans [ctx] with [gens]; the plan written, the stats and the calls.
  (SiteAccessPlan?, SiteProgramStats) run(SiteContext ctx, _Fakes fakes) {
    final stats = SiteProgramStats();
    final b = PlanBuilder(graph: g);
    final got = planSite(b, ctx, stats: stats, generators: fakes.generators);
    if (got == null) return (null, stats);
    final p = b.build(validate: false).plan(0);
    expect(p.program, got);
    return (p, stats);
  }

  group('yard (§3.6 rule, frozen)', () {
    test('a yard plan is written as offered, no fallback', () {
      final f = _Fakes(yard: SiteProgram.yard);
      final (p, stats) = run(SiteContext.ofLot(g, parcel, ind), f);
      expect(p!.program, SiteProgram.yard);
      expect(p.flags & kPlanFallback, 0);
      expect(stats.demotionCount(SiteDemotion.yardNoFit), 0);
      expect(f.calls, ['yard']);
    });

    test('the car park alone (apron did not fit) is a fallback, counted '
        'yardNoFit', () {
      final f = _Fakes(yard: SiteProgram.carPark, carPark: SiteProgram.carPark);
      final (p, stats) = run(SiteContext.ofLot(g, parcel, ind), f);
      expect(p!.program, SiteProgram.carPark);
      expect(p.flags & kPlanFallback, kPlanFallback);
      expect(stats.demotionCount(SiteDemotion.yardNoFit), 1);
      expect(stats.demotionCount(SiteDemotion.carParkNoFit), 0);
      expect(stats.programCount(SiteProgram.carPark), 1);
      expect(f.calls, ['yard'], reason: 'the car park generator is not asked');
    });

    test('null (neither fits) is kerbOnly with kPlanFallback; the car park '
        'generator is not asked again', () {
      final f = _Fakes(carPark: SiteProgram.carPark);
      final (p, stats) = run(SiteContext.ofLot(g, parcel, ind), f);
      expect(p!.program, SiteProgram.kerbOnly);
      expect(p.flags & kPlanFallback, kPlanFallback);
      expect(stats.demotionCount(SiteDemotion.yardNoFit), 1);
      expect(stats.demotionCount(SiteDemotion.carParkNoFit), 0);
      expect(f.calls, ['yard']);
    });

    test('a small installation site offered a yard carries kPlanFallback '
        'even when the yard fits', () {
      final f = _Fakes(yard: SiteProgram.yard);
      final (p, stats) = run(SiteContext.ofLot(g, parcel, solar), f);
      expect(p!.program, SiteProgram.yard);
      expect(p.flags & kPlanFallback, kPlanFallback);
      expect(stats.demotionCount(SiteDemotion.installationTooSmall), 1);
      expect(stats.demotionCount(SiteDemotion.yardNoFit), 0);
    });
  });

  test('car park: written as offered, or kerbOnly counted carParkNoFit', () {
    final ctx = SiteContext.ofLot(g, parcel, com);
    final hit = _Fakes(carPark: SiteProgram.carPark);
    final (p, s1) = run(ctx, hit);
    expect(p!.program, SiteProgram.carPark);
    expect(p.flags & kPlanFallback, 0);
    expect(s1.demotionCount(SiteDemotion.carParkNoFit), 0);
    expect(hit.calls, ['carPark']);
    final (q, s2) = run(SiteContext.ofLot(g, parcel, com), _Fakes());
    expect(q!.program, SiteProgram.kerbOnly);
    expect(q.flags & kPlanFallback, kPlanFallback);
    expect(s2.demotionCount(SiteDemotion.carParkNoFit), 1);
  });

  test('installation: written as offered, or kerbOnly counted '
      'installationNoFit; never a yard or car park', () {
    SiteContext ctx() =>
        SiteContext.debug(g, big(80, 150), solar, slots: [slot], graphLot: lot);
    final hit = _Fakes(installation: SiteProgram.installation);
    final (p, _) = run(ctx(), hit);
    expect(p!.program, SiteProgram.installation);
    expect(p.flags & kPlanFallback, 0);
    final miss = _Fakes(yard: SiteProgram.yard, carPark: SiteProgram.carPark);
    final (q, stats) = run(ctx(), miss);
    expect(q!.program, SiteProgram.kerbOnly);
    expect(q.flags & kPlanFallback, kPlanFallback);
    expect(stats.demotionCount(SiteDemotion.installationNoFit), 1);
    expect(miss.calls, ['installation']);
  });
}

/// Fake generators: each returns a plan of the program given, or null, and
/// records that it was asked.
class _Fakes {
  _Fakes({this.installation, this.yard, this.carPark});

  final SiteProgram? installation, yard, carPark;
  final List<String> calls = [];

  SiteGenerators get generators => SiteGenerators(
        installation: (_) => _ask('installation', installation),
        yard: (_) => _ask('yard', yard),
        carPark: (_) => _ask('carPark', carPark),
      );

  SiteGeneratedPlan? _ask(String name, SiteProgram? program) {
    calls.add(name);
    return program == null ? null : _FakePlan(program);
  }
}

/// A plan row of [program] with a kerbside join and a door at the pavement
/// point: enough to read back the program and flags (not a valid network).
class _FakePlan implements SiteGeneratedPlan {
  _FakePlan(this.program);

  @override
  final SiteProgram program;

  @override
  void emit(PlanBuilder b, SiteContext ctx, int dispatchFlags) {
    ctx.beginSite(b, program, dispatchFlags, SiteEnvelope.empty);
    ctx.addJoin(b, 0, kind: SiteJoinKind.kerbside);
    final pave = ctx.kerbsidePavementPoint(b);
    final door = ctx.localPoint(b, ctx.widthM / 2, 5);
    ctx.finishPedestrians(b, door, pave);
    b.endSite();
  }
}
