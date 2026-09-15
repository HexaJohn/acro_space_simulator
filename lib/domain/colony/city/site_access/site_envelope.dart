// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The building envelope rules a site is measured by
/// (docs/plans/site-access.md §2.1, §6.1).
///
/// R0 moved the legacy footprint rule here from the world snapshot, unchanged
/// and pure, so the domain envelope (R2/R4) and the renderer read one rule.
/// `world_snapshot.dart` re-exports these names, so no caller changed.
///
/// R2 adds the shared §6.1 helpers every generator uses ([SiteEnvelope],
/// [largestFreeRect], [fitFootprint], [envelopeDoor], [lampsAlong]): all in
/// site-frame metres, x along the frontage and y into the lot. Determinism
/// (§3.9): no platform hash, draw, clock, map iteration or trigonometry.
library;

import 'dart:math' as math;

import '../city_building_spec.dart';
import '../parcel.dart';
import 'site_access_constants.dart';
import 'site_frame.dart';

/// A plan's building envelope and gate, in site-frame metres (§2.3 `env*`,
/// `envFrontInset`, `gateX`, `gateW`). An EMPTY envelope (zero width or depth)
/// is legal: a degenerate site's kerbside plan has none.
class SiteEnvelope {
  const SiteEnvelope(this.x0, this.y0, this.x1, this.y1,
      {this.frontInset = 0, this.gateX = 0, this.gateW = 0});

  /// No envelope.
  static const SiteEnvelope empty = SiteEnvelope(0, 0, 0, 0);

  final double x0, y0, x1, y1;

  /// The envelope's front edge `y` where it is inset from the frontage by a
  /// forecourt (installations, §3.7 `Df`); 0 otherwise.
  final double frontInset;

  /// Where the primary drive crosses the front edge, and that lane's width
  /// (`segWidth + kGateExtraWidthM`); 0 when no drive does.
  final double gateX, gateW;

  double get width => x1 - x0;
  double get depth => y1 - y0;
  double get area => width > 0 && depth > 0 ? width * depth : 0;
  bool get isEmpty => !(width > 0 && depth > 0);

  SiteRect get rect => SiteRect(x0, y0, x1, y1);

  SiteEnvelope withGate(double x, double w) =>
      SiteEnvelope(x0, y0, x1, y1, frontInset: frontInset, gateX: x, gateW: w);

  @override
  String toString() => 'SiteEnvelope([$x0, $x1] x [$y0, $y1])';
}

/// The largest frame-aligned rectangle (by area) inside [profile], clear of
/// every rectangle of [blocked] grown by [clearanceM], with its front at or
/// behind [yMin] and its sides inside `[xMin, xMax]` (§6.1 step 2).
///
/// A histogram of free depth per 0.5 m profile column, one pass per candidate
/// front (`yMin` and each blocked rectangle's far edge plus the clearance):
/// O(columns × fronts). Ties go to the smaller front, then the smaller x.
/// Null when nothing of positive area is free. The result's corners lie on
/// column edges, so a caller emitting it still runs `containsRect`.
SiteRect? largestFreeRect(
  DepthProfile profile,
  double lotWidthM, {
  List<SiteRect> blocked = const [],
  double clearanceM = 0,
  double yMin = kDepthProfileMarginM,
  double xMin = double.negativeInfinity,
  double xMax = double.infinity,
}) {
  final grown = [
    for (final b in blocked)
      SiteRect(b.x0 - clearanceM, b.y0 - clearanceM, b.x1 + clearanceM,
          b.y1 + clearanceM),
  ];
  final fronts = <double>[yMin];
  for (final b in grown) {
    if (b.y1 > yMin) fronts.add(b.y1);
  }
  fronts.sort();
  // Columns over [0, W] (the frame's lot line to lot line), clipped.
  final lo = math.max(0.0, xMin);
  final hi = math.min(lotWidthM, xMax);
  if (!(hi - lo >= kDepthProfileStepM)) return null;
  final n = ((hi - lo) / kDepthProfileStepM).floor();
  final heights = List<double>.filled(n, 0);
  SiteRect? best;
  var bestArea = 0.0;
  double? lastFront;
  for (final y0 in fronts) {
    if (lastFront != null && (y0 - lastFront).abs() <= kGenEpsM) continue;
    lastFront = y0;
    for (var c = 0; c < n; c++) {
      final xa = lo + c * kDepthProfileStepM, xb = xa + kDepthProfileStepM;
      var far = math.min(profile.depthAt(xa + 1e-9), profile.depthAt(xb - 1e-9));
      for (final b in grown) {
        if (b.x1 <= xa || b.x0 >= xb) continue;
        if (b.y1 <= y0) continue; // wholly in front
        if (b.y0 <= y0) {
          far = y0; // the column is blocked at the front
        } else if (b.y0 < far) {
          far = b.y0;
        }
      }
      heights[c] = math.max(0.0, far - y0);
    }
    // Largest rectangle in the histogram (a stack of rising heights).
    final stack = <int>[];
    for (var c = 0; c <= n; c++) {
      final h = c == n ? -1.0 : heights[c];
      while (stack.isNotEmpty && heights[stack.last] >= h) {
        final top = stack.removeLast();
        final height = heights[top];
        final left = stack.isEmpty ? 0 : stack.last + 1;
        final area = height * (c - left) * kDepthProfileStepM;
        if (area > bestArea + 1e-9 && height > 0) {
          bestArea = area;
          best = SiteRect(lo + left * kDepthProfileStepM, y0,
              lo + c * kDepthProfileStepM, y0 + height);
        }
      }
      if (c < n) stack.add(c);
    }
  }
  return best;
}

/// [free] shrunk to hold a footprint of [footW] × [footD] where it fits,
/// centred across, FRONT-aligned (§6.1 step 3, §6.2 front alignment); the
/// whole of [free] in a dimension the footprint overfills. Null when the
/// result is under [kEnvelopeMinSideM] a side or [minArea] m².
SiteRect? fitFootprint(SiteRect free, double footW, double footD,
    {double minArea = 0}) {
  final w = math.min(free.width, footW);
  final d = math.min(free.depth, footD);
  if (w < kEnvelopeMinSideM - kGenEpsM || d < kEnvelopeMinSideM - kGenEpsM) {
    return null;
  }
  if (w * d < minArea - kGenEpsM) return null;
  final cx = (free.x0 + free.x1) / 2;
  return SiteRect(cx - w / 2, free.y0, cx + w / 2, free.y0 + d);
}

/// The door (§6.1 step 5): the midpoint of the envelope's front edge,
/// frame metres. Installations use their gate `G` instead.
(double, double) envelopeDoor(SiteEnvelope env) =>
    ((env.x0 + env.x1) / 2, env.y0);

/// Lamp posts along the line `y` from [x0] to [x1] (§3.5): one every
/// [kLampPitchM], the first [kLampStartM] in; frame metres.
List<(double, double)> lampsAlong(double x0, double x1, double y) {
  final out = <(double, double)>[];
  for (var x = x0 + kLampStartM; x <= x1 + kGenEpsM; x += kLampPitchM) {
    out.add((x, y));
  }
  return out;
}

/// The true depth of [profile] over `[x0, x1]` (the shallowest column, its
/// 0.3 m margin given back): the D §3.3 and §3.4 measure. 0 when any column
/// in the range is unreachable.
double depthOver(DepthProfile profile, double x0, double x1) {
  if (!(x1 >= x0)) return 0;
  var d = double.infinity;
  for (var x = x0;; x += kDepthProfileStepM) {
    final at = math.min(x, x1);
    final c = profile.depthAt(at);
    if (c <= 0) return 0;
    if (c < d) d = c;
    if (at >= x1) break;
  }
  return d + kDepthProfileMarginM;
}

/// The footprint a building takes on [parcel], metres.
///
/// One rule, because two things need the same answer: the building itself, and
/// the ring of ZONED GROUND drawn around it. Compute them separately and the
/// yard either overlaps the walls or leaves a gap of bare terrain.
({double width, double depth}) buildingFootprint(
    Parcel parcel, CityBuildingSpec spec) {
  final extent = parcel.inscribedExtent;
  final back = lotSetbackFor(spec);
  final cover = lotCoverageFor(spec);
  final lotW = math.max((extent.width - 2 * back) * cover, extent.width * 0.35);
  final lotD = math.max((extent.depth - 2 * back) * cover, extent.depth * 0.35);
  return (
    width: spec.siteWidthM > 0 ? math.min(lotW, spec.siteWidthM) : lotW,
    depth: spec.siteDepthM > 0 ? math.min(lotD, spec.siteDepthM) : lotD,
  );
}

/// Smallest setback from a lot line, metres.
///
/// Wider than `CityTerrainShaper.padEdgeM`, which is what makes it work: the
/// pad is flat right out to the lot line and eases off over that edge, so a
/// building inset past the ease-off stands wholly on level ground. Nothing may
/// be inset less than this or it starts straddling the step to the terrace
/// next door.
const double kLotSetbackM = 1.2;

/// Setback for [spec], metres.
///
/// Density decides how much of its plot a building takes. A tower downtown
/// meets the pavement and leaves no slack; a low-density house sits back
/// behind a garden. Every building used the SAME setback before, so a dense
/// street had the same gaps as a suburban one and the whole colony read at one
/// density however it was zoned.
///
/// Intensity — residents plus workers per building — is the density signal a
/// spec actually carries; `Density` itself does not survive onto the spec.
double lotSetbackFor(CityBuildingSpec spec) {
  final intensity = spec.housing + spec.jobs;
  if (intensity >= 90) return kLotSetbackM; // towers meet the street
  if (intensity >= 30) return 2.2;
  return 4.0; // detached, with room around it
}

/// Share of its plot [spec] covers, once set back.
///
/// The other half of the same idea: a dense block fills what it is given, a
/// low-density one leaves garden around the footprint.
double lotCoverageFor(CityBuildingSpec spec) {
  final intensity = spec.housing + spec.jobs;
  if (intensity >= 90) return 0.96;
  if (intensity >= 30) return 0.86;
  return 0.72;
}
