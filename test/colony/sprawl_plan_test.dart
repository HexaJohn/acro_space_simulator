// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/sprawl_plan.dart';
import 'package:flutter_test/flutter_test.dart';

double _distanceToPolyline(List<Vec2> pts, Vec2 p) {
  var best = double.infinity;
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final ab = b - a;
    final len2 = ab.dot(ab);
    final t = len2 < 1e-12 ? 0.0 : ((p - a).dot(ab) / len2).clamp(0.0, 1.0);
    best = math.min(best, (a + ab * t).distanceTo(p));
  }
  return best;
}

void main() {
  const spec = SprawlSpec(seed: 3, coreRadiusM: 1100);
  final plan = SprawlPlan.generate(spec);

  test('the same spec grows the same sprawl', () {
    final again = SprawlPlan.generate(spec);
    expect(again.sections.length, plan.sections.length);
    expect(again.roads.length, plan.roads.length);
    for (var i = 0; i < plan.sections.length; i++) {
      expect(again.sections[i].use, plan.sections[i].use);
      expect(again.sections[i].centre.e, plan.sections[i].centre.e);
    }
    expect(again.roads.first.points.first.e, plan.roads.first.points.first.e);
    // A different seed is a different city.
    final other = SprawlPlan.generate(const SprawlSpec(seed: 4, coreRadiusM: 1100));
    expect(
        other.sections.map((s) => s.use.index).join(),
        isNot(plan.sections.map((s) => s.use.index).join()));
  });

  test('twenty miles across: sections fill the outline past the core', () {
    expect(spec.milesAcross, closeTo(20, 1e-9));
    expect(plan.sections.length, greaterThan(250));
    for (final s in plan.sections) {
      expect(plan.outline.fractionOf(s.centre), lessThanOrEqualTo(1.1));
      expect(s.centre.length, greaterThan(spec.coreRadiusM));
    }
  });

  test('the outline is organic: lobed along the interstates, never a disc', () {
    final o = plan.outline;
    var lo = double.infinity, hi = 0.0;
    for (var i = 0; i < 64; i++) {
      final r = o.radiusAt(i / 64 * 2 * math.pi);
      lo = math.min(lo, r);
      hi = math.max(hi, r);
    }
    expect(hi / lo, greaterThan(1.25), reason: 'a disc has one radius');
    expect(lo, greaterThan(spec.radiusM * 0.55));
    expect(hi, lessThan(spec.radiusM * 1.55));
    // Along the interstates the metro reaches further than just off them —
    // on average over the lobes, since the noise on any one bearing can
    // pull the other way.
    var bulge = 0.0;
    for (final lobe in o.lobes) {
      bulge += o.radiusAt(lobe) -
          (o.radiusAt(lobe - 0.5) + o.radiusAt(lobe + 0.5)) / 2;
    }
    expect(bulge / o.lobes.length, greaterThan(spec.radiusM * 0.05));
  });

  test('farms at the edge, subdivisions in the middle, industry by the line',
      () {
    final outer = plan.sections.where((s) => plan.outline.fractionOf(s.centre) > 0.9);
    final farmsOut = outer.where((s) => s.use == SprawlUse.farmland).length;
    expect(farmsOut / outer.length, greaterThan(0.6));
    final inner = plan.sections.where((s) => plan.outline.fractionOf(s.centre) < 0.45);
    final homesIn = inner.where((s) => s.use == SprawlUse.residential).length;
    expect(homesIn / inner.length, greaterThan(0.4));
    final railSide = plan.sections.where((s) {
      final b = math.atan2(s.centre.n, s.centre.e);
      final d = (b - spec.railBearing).abs();
      return math.min(d, 2 * math.pi - d) < 0.5 && plan.outline.fractionOf(s.centre) < 0.8;
    });
    final industry = railSide.where((s) => s.use == SprawlUse.industrial).length;
    expect(industry / railSide.length, greaterThan(0.3));
  });

  /// The pieces of every road, joined back into the line they were laid as.
  Map<String, List<SprawlRoad>> byBase(Iterable<SprawlRoad> roads) {
    final out = <String, List<SprawlRoad>>{};
    for (final r in roads) {
      (out[r.baseId] ??= []).add(r);
    }
    return out;
  }

  test('interstates run from the core to the county line, plus a beltway', () {
    final lines = byBase(
        plan.roads.where((r) => r.kind == SprawlRoadKind.interstate));
    expect(lines.length, spec.interstates + spec.diagonals + 1);
    var beltways = 0;
    for (final pieces in lines.values) {
      // Pieces run nose to tail: each begins where the last ended.
      for (var i = 1; i < pieces.length; i++) {
        expect(pieces[i].points.first.distanceTo(pieces[i - 1].points.last),
            lessThan(1e-6));
      }
      final first = pieces.first.points.first.length;
      final last = pieces.last.points.last.length;
      final count = pieces.fold(0, (n, r) => n + r.points.length);
      if ((first - last).abs() < 50 && count > 40) {
        beltways++;
        continue;
      }
      // An axial radial starts at the core; a diagonal on the first
      // county-grid crossing clear of it.
      final startBearing = math.atan2(pieces.first.points.first.n, pieces.first.points.first.e);
      final diagonal = ((startBearing / (math.pi / 2)) - (startBearing / (math.pi / 2)).round()).abs() > 0.25;
      expect(first, lessThan(diagonal ? spec.sectionM * math.sqrt2 * 2.01 : spec.coreRadiusM * 1.05));
      final end = pieces.last.points.last;
      final bearing = math.atan2(end.n, end.e);
      expect(last, greaterThan(plan.outline.radiusAt(bearing) * 0.98));
    }
    expect(beltways, 1);
  });

  test('radials carry six lanes to the outline and four beyond, tapering '
      'at the drop; the beltway is eight', () {
    final radials = plan.roads.where((r) =>
        r.kind == SprawlRoadKind.interstate &&
        (r.baseId == 'I-1' || r.baseId == 'I-2'));
    RoadClass classAt(double frac, String base) {
      for (final r in radials) {
        if (r.baseId != base) continue;
        for (final p in r.points) {
          if ((plan.outline.fractionOf(p) - frac).abs() < 0.04) return r.roadClass;
        }
      }
      fail('no piece of $base at $frac');
    }

    expect(classAt(0.3, 'I-1'), RoadClass.expressway6);
    expect(classAt(0.75, 'I-1'), RoadClass.expressway6);
    expect(classAt(1.3, 'I-1'), RoadClass.expressway4);
    expect(classAt(0.3, 'I-2'), RoadClass.expressway6);
    final beltway = plan.roads.where((r) =>
        r.kind == SprawlRoadKind.interstate && r.baseId == 'I-7');
    expect(beltway, isNotEmpty);
    for (final r in beltway) {
      expect(r.roadClass, RoadClass.expressway8);
    }
    // The last six-lane piece tapers to the four-lane width; the first
    // four-lane piece starts at its own.
    for (final base in ['I-1', 'I-2']) {
      final pieces = plan.roads.where((r) => r.baseId == base).toList();
      final drop = pieces.indexWhere((r) => r.roadClass == RoadClass.expressway4);
      expect(drop, greaterThan(0));
      expect(pieces[drop - 1].endHalfWidthM, RoadClass.expressway4.halfWidth);
      expect(pieces[drop].startHalfWidthM, isNull);
      expect(pieces[drop - 1].startHalfWidthM, isNull);
    }
    // Every county highway is the plat's four-lane avenue; every ramp a ramp.
    for (final r in plan.roads) {
      if (r.kind == SprawlRoadKind.countyHighway) {
        expect(r.roadClass, RoadClass.avenue);
      }
      if (r.kind == SprawlRoadKind.ramp) expect(r.roadClass, RoadClass.ramp);
    }
  });

  test('a diagonal begins on a county-grid crossing outside the core, at a '
      'signal with the two highways', () {
    final diagonals = plan.roads.where((r) =>
        r.kind == SprawlRoadKind.interstate &&
        (r.baseId == 'I-5' || r.baseId == 'I-6'));
    expect(diagonals, isNotEmpty);
    for (final base in ['I-5', 'I-6']) {
      final first = plan.roads
          .where((r) => r.baseId == base)
          .reduce((a, b) => a.points.first.length < b.points.first.length ? a : b);
      final p = first.points.first;
      // On the grid, clear of the core.
      expect(((p.e / spec.sectionM) - (p.e / spec.sectionM).round()).abs(), lessThan(1e-6));
      expect(((p.n / spec.sectionM) - (p.n / spec.sectionM).round()).abs(), lessThan(1e-6));
      expect(p.length, greaterThan(spec.coreRadiusM));
      // And a signalised node with the expressway among the highways' legs.
      final node = plan.nodes.where((n) => n.at.distanceTo(p) < 2).toList();
      expect(node, hasLength(1), reason: '$base starts at a junction');
      expect(node.single.control, JunctionControl.signals);
      expect(node.single.legs.where((l) => l.roadClass.isExpressway).length, 1);
      expect(node.single.legs.where((l) => l.roadClass == RoadClass.avenue).length, 4);
    }
  });

  test('the network is a graph: highways split where they cross, and the '
      'crossing is a signalised node with four legs', () {
    final highways =
        plan.roads.where((r) => r.kind == SprawlRoadKind.countyHighway).toList();
    // Split at the mile grid: no piece is longer than a mile and a bit,
    // except at the outer end where the grid has run out.
    final long = highways.where((r) => r.lengthM > spec.sectionM * 1.5).length;
    expect(long, lessThan(highways.length / 3));
    final grid = plan.nodes.where((n) =>
        n.legs.length == 4 &&
        n.legs.every((l) => l.roadClass == RoadClass.avenue));
    expect(grid.length, greaterThan(30));
    for (final n in grid) {
      expect(n.control, JunctionControl.signals);
      // On the mile grid.
      expect((n.at.e / spec.sectionM - (n.at.e / spec.sectionM).round()).abs(),
          lessThan(0.01));
      expect((n.at.n / spec.sectionM - (n.at.n / spec.sectionM).round()).abs(),
          lessThan(0.01));
      // Where highway pieces END.
      final ends = highways.where((r) =>
          r.points.first.distanceTo(n.at) < 1 ||
          r.points.last.distanceTo(n.at) < 1);
      expect(ends.length, 4, reason: 'four pieces meet at ${n.at}');
    }
  });

  test('a diamond: two on-ramps, two off, signalised terminals on the '
      'highway, merges on the expressway', () {
    final highways =
        plan.roads.where((r) => r.kind == SprawlRoadKind.countyHighway).toList();
    final interstates =
        plan.roads.where((r) => r.kind == SprawlRoadKind.interstate).toList();
    final ramps = plan.roads.where((r) => r.kind == SprawlRoadKind.ramp);
    double toHighway(Vec2 p) =>
        highways.map((r) => _distanceToPolyline(r.points, p)).reduce(math.min);
    double toInterstate(Vec2 p) =>
        interstates.map((r) => _distanceToPolyline(r.points, p)).reduce(math.min);
    var on = 0, off = 0;
    for (final r in ramps) {
      final a = r.points.first, b = r.points.last;
      // A diamond ramp has one end ON the highway's centreline.
      final startsOnHighway = toHighway(a) < 0.5;
      final endsOnHighway = toHighway(b) < 0.5;
      if (!startsOnHighway && !endsOnHighway) continue; // a cloverleaf's
      if (startsOnHighway) {
        on++;
        expect(toInterstate(b), lessThan(RoadClass.expressway8.halfWidth + 1),
            reason: '${r.id} ends on the expressway edge');
      } else {
        off++;
        expect(toInterstate(a), lessThan(RoadClass.expressway8.halfWidth + 1),
            reason: '${r.id} starts on the expressway edge');
      }
    }
    expect(on, greaterThan(0));
    expect(on, off, reason: 'as many on-ramps as off');
    // The terminals: on each side of the crossing the on-ramp and the
    // off-ramp meet the highway at ONE signalised junction — two ramp
    // legs between two avenue legs, as a real diamond has.
    final terminals = plan.nodes.where((n) =>
        n.legs.any((l) => l.roadClass == RoadClass.ramp) &&
        n.legs.where((l) => l.roadClass == RoadClass.avenue).length == 2);
    expect(terminals.length, (on + off) ~/ 2);
    for (final n in terminals) {
      expect(n.control, JunctionControl.signals);
      expect(n.legs.where((l) => l.roadClass == RoadClass.ramp).length, 2);
      expect(n.legs.length, 4);
    }
    // The merges: a ramp meeting the expressway, nothing to stop for.
    final merges = plan.nodes.where((n) =>
        n.legs.any((l) => l.roadClass == RoadClass.ramp) &&
        n.legs.any((l) => l.roadClass.isExpressway));
    expect(merges, isNotEmpty);
    for (final n in merges) {
      expect(n.control, JunctionControl.merge);
    }
  });

  test('every subdivision runs its collectors out to the county highway, '
      'and meets it at a signal', () {
    final collectors = plan.nodes.where(
        (n) => n.legs.any((l) => l.roadClass == RoadClass.street));
    expect(collectors.length, greaterThan(100));
    for (final n in collectors) {
      expect(n.legs.length, greaterThanOrEqualTo(3));
      expect(n.legs.where((l) => l.roadClass == RoadClass.avenue).length, 2,
          reason: 'the highway runs through');
      expect(n.control, JunctionControl.signals);
      // A quarter of a mile from a section corner, on a section line.
      final e = n.at.e / spec.sectionM, nn = n.at.n / spec.sectionM;
      final onLineE = (e - e.round()).abs() < 0.01;
      final onLineN = (nn - nn.round()).abs() < 0.01;
      expect(onLineE != onLineN, isTrue, reason: 'on exactly one section line');
      final off = onLineE ? nn : e;
      expect(((off - off.floor()) - 0.25).abs() < 0.01 ||
          ((off - off.floor()) - 0.75).abs() < 0.01, isTrue,
          reason: 'a quarter in from the corner');
    }
    // A built section knows where its own collectors are.
    final built = plan.sections.firstWhere((s) => s.use == SprawlUse.residential);
    expect(built.streetsAcross, 12);
    expect(built.collectorOffsetsE, [-spec.sectionM / 4, spec.sectionM / 4]);
    expect(built.collectorOffsetsN, [-spec.sectionM / 4, spec.sectionM / 4]);
    expect(SprawlSection.collectorIndices(12), {3, 9});
    expect(SprawlSection.collectorIndices(8), {2, 6});
    expect(plan.sections.firstWhere((s) => s.use == SprawlUse.farmland).streetsAcross, 0);
  });

  test('county highways follow the mile grid and stop at the core', () {
    final highways =
        plan.roads.where((r) => r.kind == SprawlRoadKind.countyHighway).toList();
    expect(highways.length, greaterThan(30));
    for (final r in highways) {
      final es = r.points.map((p) => p.e).toSet();
      final ns = r.points.map((p) => p.n).toSet();
      expect(es.length == 1 || ns.length == 1, isTrue, reason: 'straight');
      for (final p in r.points) {
        expect(p.length, greaterThanOrEqualTo(spec.coreRadiusM - 1));
      }
    }
  });

  test('every crossing gets a bridge, and interchanges get ramps that join',
      () {
    final interstates =
        plan.roads.where((r) => r.kind == SprawlRoadKind.interstate).toList();
    final highways =
        plan.roads.where((r) => r.kind == SprawlRoadKind.countyHighway).toList();
    final ramps = plan.roads.where((r) => r.kind == SprawlRoadKind.ramp).toList();
    expect(plan.interchanges.where((x) => x.kind == SprawlInterchangeKind.diamond),
        isNotEmpty);
    expect(
        plan.interchanges.where((x) => x.kind == SprawlInterchangeKind.cloverleaf),
        isNotEmpty);
    expect(ramps.length, greaterThan(plan.interchanges.length * 3));
    // Every interstate carries at least one overpass, and each range is a
    // real span.
    for (final pieces in byBase(interstates).values) {
      expect(pieces.any((r) => r.overpasses.isNotEmpty), isTrue,
          reason: pieces.first.baseId);
      for (final r in pieces) {
        for (final (a, b) in r.overpasses) {
          expect(b - a, greaterThan(100));
        }
      }
    }
    // A ramp's ends land on the roads it joins.
    final all = [...interstates, ...highways];
    for (final ramp in ramps) {
      final startD = all.map((r) => _distanceToPolyline(r.points, ramp.points.first)).reduce(math.min);
      final endD = all.map((r) => _distanceToPolyline(r.points, ramp.points.last)).reduce(math.min);
      // A loop sits about thirty metres off each carriageway, a little more
      // where two roads cross obliquely or bend within the interchange.
      expect(startD, lessThan(60), reason: '${ramp.id} start');
      expect(endD, lessThan(60), reason: '${ramp.id} end');
    }
  });

  test('the core outline is honoured: sections meet it, highways stop at it',
      () {
    // A ragged core: further east than north.
    final radii = [for (var i = 0; i < 16; i++) 900.0 + 300 * math.cos(i / 16 * 2 * math.pi)];
    final ragged = SprawlSpec(seed: 3, coreRadiusM: 1000, coreRadii: radii);
    expect(ragged.coreRadiusAt(0), closeTo(1200, 1e-9));
    expect(ragged.coreRadiusAt(math.pi), closeTo(600, 1e-9));
    // Interpolated between samples, not stepped.
    final between = ragged.coreRadiusAt(math.pi / 16);
    expect(between, lessThan(1200));
    expect(between, greaterThan(radii[1]));
    final p = SprawlPlan.generate(ragged);
    // The four sections round downtown are grown.
    final central = p.sections.where((s) => s.centre.length < ragged.sectionM);
    expect(central.length, 4);
    // No county highway point lies on the plat.
    for (final r in p.roads.where((r) => r.kind == SprawlRoadKind.countyHighway)) {
      for (final q in r.points) {
        expect(ragged.coreContains(q, marginM: 30), isFalse, reason: r.id);
      }
    }
    // And it survives a save.
    expect(SprawlSpec.fromJson(ragged.toJson()), ragged);
  });

  test('the railway carries on from the plat, and the interstates bridge it',
      () {
    final withRail = SprawlSpec(
        seed: 3, coreRadiusM: 1100, railOffsetN: 1300, railInnerReachM: 6000);
    final p = SprawlPlan.generate(withRail);
    final rails = p.roads.where((r) => r.kind == SprawlRoadKind.rail).toList();
    expect(rails, hasLength(2));
    for (final r in rails) {
      // Starts exactly where the plat's line ends, on its offset.
      expect(r.points.first.e.abs(), closeTo(6000, 1e-6));
      expect(r.points.first.n, closeTo(1300, 1e-6));
      // And runs well past the outline.
      final bearing = math.atan2(r.points.last.n, r.points.last.e);
      expect(r.points.last.length,
          greaterThan(p.outline.radiusAt(bearing) + 8000));
      for (final q in r.points) {
        expect((q.n - 1300).abs(), lessThan(400), reason: 'a gentle wander');
      }
    }
    // The beltway crosses the line, and bridges it: more bridged length
    // than the plan without a railway. (Length, not count — a bridge over
    // the railway merges with one over a highway beside it.)
    final without = SprawlPlan.generate(spec);
    double bridged(SprawlPlan plan) => plan.roads
        .where((r) => r.kind == SprawlRoadKind.interstate)
        .fold(0.0, (n, r) => n + r.overpasses.fold(0.0, (m, o) => m + o.$2 - o.$1));
    expect(bridged(p), greaterThan(bridged(without)));
    // No interchange on the railway: nothing ramps onto a track.
    expect(p.interchanges.length, without.interchanges.length);
    expect(SprawlSpec.fromJson(withRail.toJson()), withRail);
  });

  test('the expressway: east and west share a line, start at deck height, '
      'and the core gets its own interchanges', () {
    const withCore = SprawlSpec(
      seed: 3,
      coreRadiusM: 1100,
      axisOffsetN: 90,
      axisOffsetE: -60,
      expressway: true,
      coreAvenuesE: [-880, -660, -440, -220, 0, 220, 440, 660, 880],
      coreAvenuesN: [-330, 0, 330],
    );
    final p = SprawlPlan.generate(withCore);
    // The first piece of each: the one that starts at the core.
    SprawlRoad firstPiece(String base) => p.roads
        .where((r) => r.baseId == base)
        .reduce((a, b) => a.points.first.length < b.points.first.length ? a : b);
    for (final r in [firstPiece('I-1'), firstPiece('I-3')]) {
      // Both on y = axisOffsetN at the core, whichever way they run.
      expect(r.points.first.n, closeTo(90, 1e-6));
      // Descending from the deck: a range that starts before the road does.
      expect(r.overpasses.first.$1, lessThan(0));
      expect(r.overpasses.first.$2, greaterThan(0));
    }
    // North and south stay on x = axisOffsetE and start at grade.
    for (final r in [firstPiece('I-2'), firstPiece('I-4')]) {
      expect(r.points.first.e, closeTo(-60, 1e-6));
      expect(r.overpasses.isEmpty || r.overpasses.first.$1 >= 0, isTrue);
    }
    // The corridor through the core, and diamonds on it at the avenues.
    final corridor = p.roads.firstWhere((r) => r.kind == SprawlRoadKind.corridor);
    expect(corridor.points.first.e, lessThan(-1000));
    expect(corridor.points.last.e, greaterThan(1000));
    final inCore = p.interchanges.where((x) => x.at.length < 1100).toList();
    expect(inCore, isNotEmpty);
    for (final x in inCore) {
      expect(x.kind, SprawlInterchangeKind.diamond);
      expect(x.at.n, closeTo(90, 1e-6));
      expect(withCore.coreAvenuesE, contains(x.at.e));
    }
    // Their ramps climb to the deck over their last stretch — or, running
    // the other way, come down off it over their first. And the terminals
    // on the plat's avenues are signalised nodes of the plan.
    final coreRamps = p.roads.where((r) =>
        r.kind == SprawlRoadKind.ramp &&
        r.points.first.length < 1100 &&
        r.points.last.length < 1100);
    expect(coreRamps, isNotEmpty);
    for (final r in coreRamps) {
      expect(r.overpasses, hasLength(1));
      final (a, b) = r.overpasses.first;
      expect(b > r.lengthM || a < 0, isTrue, reason: r.id);
    }
    final terminals = p.nodes.where((n) =>
        n.at.length < 1100 && n.legs.any((l) => l.roadClass == RoadClass.ramp));
    expect(terminals, isNotEmpty);
    for (final n in terminals) {
      expect(n.control, JunctionControl.signals);
      expect(withCore.coreAvenuesE.any((x) => (x - n.at.e).abs() < 1), isTrue);
    }
    // Without the expressway there is no corridor and nothing descends.
    final plain = SprawlPlan.generate(spec);
    expect(plain.roads.any((r) => r.kind == SprawlRoadKind.corridor), isFalse);
    expect(SprawlSpec.fromJson(withCore.toJson()), withCore);
  });

  test('the county highways break at a staked plot', () {
    // A square that straddles both a north-south and an east-west section
    // line: the highways on those lines must stop at its edge.
    const box = [-2000.0, -2000.0, -1200.0, -2000.0, -1200.0, -1200.0, -2000.0, -1200.0];
    const staked = SprawlSpec(seed: 3, coreRadiusM: 1100, clearings: [box]);
    final p = SprawlPlan.generate(staked);
    final highways = p.roads.where((r) => r.kind == SprawlRoadKind.countyHighway);
    var crossing = 0;
    for (final r in highways) {
      for (final q in r.points) {
        expect(SprawlSpec.inFlatPolygonBox(box, q.e, q.n, 0), isFalse,
            reason: '${r.id} runs through the plot');
      }
      if (r.points.any((q) => (q.n + 1609).abs() < 1 && q.e < -2000)) crossing++;
    }
    expect(crossing, greaterThan(0), reason: 'the line still exists either side');
    expect(staked.inClearing(const Vec2(-1600, -1600)), isTrue);
    expect(staked.inClearing(const Vec2(-1600, -2100)), isFalse);
    expect(staked.inClearing(const Vec2(-1600, -2100), marginM: 150), isTrue);
    expect(SprawlSpec.fromJson(staked.toJson()), staked);
  });

  test('off the deck: the radial starts at the viaduct\'s width, and the '
      'frontage roads carry on as slip ramps', () {
    const withCore = SprawlSpec(
      seed: 3,
      coreRadiusM: 1100,
      axisOffsetN: 90,
      axisOffsetE: -60,
      expressway: true,
      coreAvenuesE: [-880, -440, 0, 440, 880],
      coreAvenuesN: [-330, 90, 330],
      frontageRoads: [
        [56, -1040, 1040],
        [124, -1040, 1040],
      ],
    );
    final p = SprawlPlan.generate(withCore);
    SprawlRoad firstPiece(String base) => p.roads
        .where((r) => r.baseId == base)
        .reduce((a, b) => a.points.first.length < b.points.first.length ? a : b);
    for (final r in [firstPiece('I-1'), firstPiece('I-3')]) {
      expect(r.startHalfWidthM, RoadClass.elevated.halfWidth);
      expect(r.roadClass, RoadClass.expressway6);
    }
    // North and south carry on as the plat's avenue: they start at its
    // width and widen out.
    for (final r in [firstPiece('I-2'), firstPiece('I-4')]) {
      expect(r.startHalfWidthM, RoadClass.avenue.halfWidth);
    }
    // Four slip ramps: one ON and one OFF at each end, each with one end
    // exactly on a frontage road's end.
    final slips = p.roads.where((r) => r.id.startsWith('R-F')).toList();
    expect(slips, hasLength(4));
    var on = 0, off = 0;
    for (final r in slips) {
      final ends = [r.points.first, r.points.last];
      final onRoad = ends.where((e) =>
          withCore.frontageRoads.any((f) =>
              (e.n - f[0]).abs() < 1e-6 &&
              ((e.e - f[1]).abs() < 1e-6 || (e.e - f[2]).abs() < 1e-6)));
      expect(onRoad.length, 1, reason: '${r.id} starts or ends on a frontage road');
      if (r.points.first == onRoad.single) {
        on++;
      } else {
        off++;
      }
      // The other end is on the expressway's outer edge: within its half
      // width of the line through the core, past the corridor's end.
      final far = r.points.first == onRoad.single ? r.points.last : r.points.first;
      expect(far.e.abs(), greaterThan(1100 * 0.98));
      expect((far.n - 90).abs(), lessThan(RoadClass.expressway6.halfWidth + 1));
      // Traffic keeps right: the south road is eastbound, the north westbound.
      final south = onRoad.single.n < 90;
      final eastEnd = onRoad.single.e > 0;
      expect(r.points.first == onRoad.single, south == eastEnd,
          reason: '${r.id}: an on-ramp at the end the road drives toward');
    }
    expect(on, 2);
    expect(off, 2);
    // Their merges are merge nodes on the radials.
    final merges = p.nodes.where((n) =>
        n.legs.any((l) => l.roadClass == RoadClass.ramp) &&
        n.legs.any((l) => l.roadClass.isExpressway) &&
        (n.at.n - 90).abs() < 250 &&
        n.at.e.abs() > 1000 &&
        n.at.e.abs() < 1600);
    expect(merges.length, greaterThanOrEqualTo(4));
    expect(SprawlSpec.fromJson(withCore.toJson()), withCore);
  });

  test('the inner suburbs carry the plat\'s grid on: their streets are its '
      'lines, and their collectors are the lines nearest the quarter points',
      () {
    const withGrid = SprawlSpec(
      seed: 3,
      coreRadiusM: 1100,
      gridOriginE: -880,
      gridOriginN: -416,
      gridStepE: 220,
      gridStepN: 104,
      coreAvenuesE: [-880, -220, 440],
      coreAvenuesN: [-416, 0, 416],
      arteries: true,
    );
    final p = SprawlPlan.generate(withGrid);
    final inner = p.sections.where((s) => s.continuesCoreGrid).toList();
    final outer = p.sections.where((s) => !s.continuesCoreGrid && s.streetsAcross > 0);
    expect(inner, isNotEmpty);
    expect(outer, isNotEmpty);
    for (final s in inner) {
      // Touching the core.
      final bearing = math.atan2(s.centre.n, s.centre.e);
      expect(s.centre.length - s.sizeM * math.sqrt2 / 2,
          lessThanOrEqualTo(withGrid.coreRadiusAt(bearing) + 300));
      // Every line is on the plat's grid, no avenue among them.
      for (final e in s.streetLinesE) {
        final abs = e + s.centre.e;
        final k = (abs - withGrid.gridOriginE) / withGrid.gridStepE;
        expect((k - k.round()).abs(), lessThan(1e-6));
        expect(withGrid.coreAvenuesE.any((a) => (a - abs).abs() < 1), isFalse);
      }
      for (final n in s.streetLinesN) {
        final abs = n + s.centre.n;
        final k = (abs - withGrid.gridOriginN) / withGrid.gridStepN;
        expect((k - k.round()).abs(), lessThan(1e-6));
      }
      // Collectors are lines, near the quarter points.
      for (final c in s.collectorOffsetsE) {
        expect(s.streetLinesE.contains(c), isTrue);
        expect((c.abs() - s.sizeM / 4).abs(), lessThan(withGrid.gridStepE));
      }
      for (final c in s.collectorOffsetsN) {
        expect(s.streetLinesN.contains(c), isTrue);
        expect((c.abs() - s.sizeM / 4).abs(), lessThan(withGrid.gridStepN));
      }
    }
    // Farther out, the survey grid.
    for (final s in outer) {
      expect(s.streetLinesE, isEmpty);
      expect(s.collectorOffsetsE, [-s.sizeM / 4, s.sizeM / 4]);
    }
    // And the collectors' junctions sit on those lines.
    final nodes = p.nodes.where((n) => n.legs.any((l) => l.roadClass == RoadClass.street));
    expect(nodes, isNotEmpty);
    expect(SprawlSpec.fromJson(withGrid.toJson()), withGrid);
  });

  test('the plat\'s arteries meet the county grid at signalised T nodes', () {
    const withArteries = SprawlSpec(
      seed: 3,
      coreRadiusM: 1100,
      axisOffsetE: 220,
      axisOffsetN: 0,
      coreAvenuesE: [-440, 220, 880],
      coreAvenuesN: [-416, 0, 416],
      arteries: true,
    );
    final p = SprawlPlan.generate(withArteries);
    final tees = p.nodes.where(
        (n) => n.legs.any((l) => l.roadClass == RoadClass.trunk));
    // Two avenues each way, less the axis ones, two ends each.
    expect(tees.length, greaterThanOrEqualTo(4));
    for (final n in tees) {
      expect(n.control, JunctionControl.signals);
      expect(n.legs.where((l) => l.roadClass == RoadClass.avenue).length, 2);
      // On an avenue's line, at least forty metres past the core.
      final onE = withArteries.coreAvenuesE.any((x) => (x - n.at.e).abs() < 1);
      final onN = withArteries.coreAvenuesN.any((y) => (y - n.at.n).abs() < 1);
      expect(onE || onN, isTrue);
      expect(withArteries.coreContains(n.at, marginM: 39), isFalse);
    }
    expect(SprawlSpec.fromJson(withArteries.toJson()), withArteries);
    // Without the flag, nothing meets the grid there.
    expect(plan.nodes.any((n) => n.legs.any((l) => l.roadClass == RoadClass.trunk)),
        isFalse);
  });

  test('the spec survives a save', () {
    final back = SprawlSpec.fromJson(spec.toJson());
    expect(back, spec);
    expect(back.hashCode, spec.hashCode);
  });
}
