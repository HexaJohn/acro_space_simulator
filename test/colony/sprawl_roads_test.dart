// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The sprawl's mile-scale network is plat: county highways on the section
/// grid, the railway carried on, the interstates with their bridges and
/// interchanges — every one a road of the layout, split where it crosses,
/// its junctions where its ends meet.
library;

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/sprawl_plan.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

double _toPolyline(List<Vec2> pts, Vec2 p) {
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
  final system = RealSolarSystem.build();
  final bodies = system.all.where((b) => !b.isStar).toList();
  const spec = CityGenSpec(blocksAcross: 2, seed: 9, sprawlMiles: 8);

  late CitySim city;
  late CityLayout layout;
  late SprawlSpec sprawl;
  late SprawlOutline outline;
  late Map<String, List<Vec2>> samples;
  late List<RoadSpline> highways, expressways, ramps;
  List<RoadSpline> ofClass(bool Function(RoadClass) test) =>
      layout.roads.where((r) => test(r.roadClass)).toList();
  setUpAll(() {
    city = const CityGenerator().generate(spec, bodies: bodies);
    layout = city.layout;
    sprawl = city.sprawlSpec!;
    outline = SprawlPlan.outlineOf(sprawl);
    samples = {
      for (final r in layout.roads) r.id: layout.roadIndex.byId(r.id)!.samples,
    };
    highways = ofClass((c) => c == RoadClass.avenue)
        .where((r) => !r.platsLots)
        .toList();
    expressways = ofClass((c) => c.isExpressway);
    ramps = ofClass((c) => c == RoadClass.ramp);
  });

  /// How many road ends lie within 1.5 m of [p].
  int endsAt(Vec2 p) {
    var n = 0;
    for (final r in layout.roads) {
      final s = samples[r.id]!;
      if (s.first.distanceTo(p) < 1.5) n++;
      if (s.last.distanceTo(p) < 1.5) n++;
    }
    return n;
  }

  test('the county highways are avenues on the mile grid: straight, fronting '
      'nothing, following the land, stopping at the core', () {
    expect(highways.length, greaterThan(20));
    var onGrid = 0;
    for (final r in highways) {
      expect(r.graded, isFalse);
      final s = samples[r.id]!;
      final es = s.map((p) => p.e.round()).toSet();
      final ns = s.map((p) => p.n.round()).toSet();
      expect(es.length == 1 || ns.length == 1, isTrue, reason: '${r.id} straight');
      final line = es.length == 1 ? s.first.e : s.first.n;
      if ((line / sprawl.sectionM - (line / sprawl.sectionM).round()).abs() < 1e-3) {
        onGrid++;
      }
      for (final p in s) {
        expect(sprawl.coreContains(p, marginM: 30), isFalse, reason: r.id);
      }
    }
    expect(onGrid, highways.length);
    // Crossings on the grid are junctions of four highway ends.
    var crossings = 0;
    for (final r in highways) {
      final p = samples[r.id]!.first;
      if (endsAt(p) >= 4) crossings++;
    }
    expect(crossings, greaterThan(10));
  });

  test('the interstates run from the core to the county line, six lanes to '
      'the outline and four beyond, tapering at the drop; the beltway eight',
      () {
    final six = expressways.where((r) => r.roadClass == RoadClass.expressway6);
    final four = expressways.where((r) => r.roadClass == RoadClass.expressway4);
    final eight = expressways.where((r) => r.roadClass == RoadClass.expressway8);
    expect(six, isNotEmpty);
    expect(four, isNotEmpty);
    expect(eight, isNotEmpty, reason: 'the beltway');
    expect(six.any((r) => r.endHalfWidthM == RoadClass.expressway4.halfWidth),
        isTrue, reason: 'the last six-lane piece tapers to four');
    // Six lanes end at the first vertex past the outline: within a step.
    for (final r in six) {
      for (final p in samples[r.id]!) {
        expect(outline.fractionOf(p), lessThan(1.2), reason: '${r.id} six inside');
      }
    }
    var farthest = 0.0;
    for (final r in four) {
      for (final p in samples[r.id]!) {
        farthest = math.max(farthest, outline.fractionOf(p));
      }
    }
    expect(farthest, greaterThan(1.3), reason: 'on into the country');
    expect(expressways.every((r) => !r.platsLots && !r.graded), isTrue);
  });

  test('where an interstate crosses a county highway it is bridged over it, '
      'and neither is cut', () {
    var bridged = 0;
    for (final x in expressways) {
      final xs = samples[x.id]!;
      for (final h in highways) {
        final hs = samples[h.id]!;
        // A crossing: where a segment of the highway meets one of the
        // expressway's (a straight highway is two samples).
        Vec2? at;
        for (var i = 1; i < hs.length && at == null; i++) {
          for (var j = 1; j < xs.length; j++) {
            final hit = segmentSegment(hs[i - 1], hs[i], xs[j - 1], xs[j]);
            if (hit == null) continue;
            at = hs[i - 1] + (hs[i] - hs[i - 1]) * hit.$1;
            break;
          }
        }
        if (at == null) continue;
        // Not the highway's own end meeting the expressway's end.
        if (hs.first.distanceTo(at) < 2 || hs.last.distanceTo(at) < 2) continue;
        if (xs.first.distanceTo(at) < 2 || xs.last.distanceTo(at) < 2) continue;
        // The expressway is on a bridge there — unless it is within its
        // last stretch, where there is no room to climb ...
        var s = 0.0;
        for (var i = 1; i < xs.length; i++) {
          if (_toPolyline([xs[i - 1], xs[i]], at) < 1.0) {
            s += xs[i - 1].distanceTo(at);
            break;
          }
          s += xs[i].distanceTo(xs[i - 1]);
        }
        final len = layout.roadIndex.byId(x.id)!.lengthM;
        final freeStart = endsAt(xs.first) <= 1, freeEnd = endsAt(xs.last) <= 1;
        if ((freeStart && s < CityLayout.bridgeEndClearM) ||
            (freeEnd && s > len - CityLayout.bridgeEndClearM)) {
          continue;
        }
        expect(x.bridgedAt(s), isTrue, reason: '${x.id} over ${h.id} at $at');
        // ... and the highway runs on underneath uncut.
        expect(endsAt(at), 0, reason: '${h.id} cut under ${x.id}');
        bridged++;
      }
    }
    expect(bridged, greaterThan(4));
  });

  test('a diamond: ramps with a signalised T on the highway and a merge on '
      'the expressway\'s edge that splits it; on and off in equal number', () {
    expect(ramps.length, greaterThan(8));
    var on = 0, off = 0, merges = 0;
    for (final r in ramps) {
      final s = samples[r.id]!;
      final a = s.first, b = s.last;
      double toHighway(Vec2 p) => highways.isEmpty
          ? double.infinity
          : highways.map((h) => _toPolyline(samples[h.id]!, p)).reduce(math.min);
      double toExpressway(Vec2 p) =>
          expressways.map((x) => _toPolyline(samples[x.id]!, p)).reduce(math.min);
      // A diamond's ramp: one end on a highway well off the expressway,
      // the other at the expressway's edge well off any highway. Anything
      // else is a cloverleaf's, a slip ramp's, or a core diamond's on the
      // plat's own avenue.
      final startsOnHighway = toHighway(a) < 0.5 && toExpressway(a) > 30;
      final endsOnHighway = toHighway(b) < 0.5 && toExpressway(b) > 30;
      if (startsOnHighway == endsOnHighway) continue;
      final terminal = startsOnHighway ? a : b;
      final merge = startsOnHighway ? b : a;
      if (toHighway(merge) < 30) continue;
      if (startsOnHighway) {
        on++;
      } else {
        off++;
      }
      // The terminal is a junction: the highway's pieces end there too.
      expect(endsAt(terminal), greaterThanOrEqualTo(3), reason: '${r.id} terminal');
      // The merge is on the expressway's outer edge, off its centreline.
      final d = toExpressway(merge);
      expect(d, lessThan(RoadClass.expressway8.halfWidth + 1), reason: '${r.id} merge');
      expect(d, greaterThan(4), reason: '${r.id} merges at the edge, not the centre');
      // And the expressway was split there: one of its pieces ends within
      // the edge offset of the merge.
      final split = expressways.any((x) =>
          samples[x.id]!.first.distanceTo(merge) < d + 2 ||
          samples[x.id]!.last.distanceTo(merge) < d + 2);
      if (split) merges++;
    }
    expect(on, greaterThan(0));
    expect(on, off, reason: 'as many on-ramps as off');
    expect(merges, greaterThan((on + off) ~/ 2));
  });

  test('the railway carries on from the plat\'s line into the country', () {
    final rails = ofClass((c) => c == RoadClass.rail);
    expect(rails, isNotEmpty);
    var farthest = 0.0;
    for (final r in rails) {
      for (final p in samples[r.id]!) {
        farthest = math.max(farthest, outline.fractionOf(p));
      }
    }
    expect(farthest, greaterThan(1.3));
    // Continuous: where the plat's line ends the sprawl's begins.
    for (final sign in const [1.0, -1.0]) {
      final joint = Vec2(sign * CityGenerator.railInnerReachM, sprawl.railOffsetN);
      expect(endsAt(joint), greaterThanOrEqualTo(2), reason: 'the line joins at $joint');
    }
  });

  test('off the deck: the east and west radials start at the viaduct\'s '
      'width and descend from it; the frontage roads carry on as slip ramps',
      () {
    final offDeck = expressways
        .where((r) => r.startHalfWidthM == RoadClass.elevated.halfWidth)
        .toList();
    expect(offDeck, hasLength(2));
    for (final r in offDeck) {
      expect(r.roadClass, RoadClass.expressway6);
      expect(r.bridges, isNotEmpty);
      expect(r.bridges.first.$1, lessThan(0));
      expect(r.bridges.first.$2, greaterThan(0));
    }
    // The north and south radials carry on as the plat's avenue.
    expect(
        expressways
            .where((r) => r.startHalfWidthM == RoadClass.avenue.halfWidth)
            .length,
        2);
    // Slip ramps: one end on a frontage road's end.
    var slips = 0;
    for (final r in ramps) {
      final s = samples[r.id]!;
      for (final f in sprawl.frontageRoads) {
        for (final end in [s.first, s.last]) {
          if ((end.n - f[0]).abs() < 1 &&
              ((end.e - f[1]).abs() < 1 || (end.e - f[2]).abs() < 1)) {
            slips++;
          }
        }
      }
    }
    expect(slips, greaterThanOrEqualTo(2));
  });

  test('sound barriers where an expressway runs past housing', () {
    expect(expressways.any((r) => r.soundWalls), isTrue);
    expect(expressways.every((r) => r.soundWalls), isFalse,
        reason: 'open past the fields');
  });

  test('the interchanges are on the spec, and the same seed lays the same '
      'network', () {
    expect(sprawl.interchanges, isNotEmpty);
    final again = const CityGenerator().generate(spec, bodies: bodies);
    expect(again.layout.roads.length, layout.roads.length);
    expect(again.sprawlSpec!.interchanges.length, sprawl.interchanges.length);
  });
}
