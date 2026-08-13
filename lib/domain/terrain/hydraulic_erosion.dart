// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Droplet-based hydraulic erosion — Stage 5, and the one part of the terrain
/// stack that is deliberately NOT a pure point function.
///
/// Every other generator here answers "what is the height at this direction"
/// independently at each sample. Erosion cannot: the height at a point depends
/// on everything upstream of it, so it is an iterative simulation over a whole
/// grid. That is precisely why it runs OFFLINE, in the bake, and ships as data.
///
/// ## What it produces beyond height
///
/// [ErosionResult.flow] is as valuable as the eroded heights. Flow accumulation
/// records where water concentrated, which is what tells the shader where
/// riverbeds, wet rock, sediment and valley vegetation belong. Terrain that
/// looks eroded but is shaded uniformly still reads as procedural; matching the
/// materials to the water is half of what sells it.
///
/// ## What this model does, and what it does not
///
/// This is a HILLSLOPE TRANSPORT model. Carrying capacity scales with local
/// slope, so material is lifted from steep ground and released where the
/// gradient slackens. The result is scoured, smoothed hillsides and valleys
/// filling with sediment — which is most of what makes terrain read as eroded.
///
/// It does NOT incise valleys into bedrock. Real rivers cut down because stream
/// power rises with accumulated discharge, so a channel carrying a whole
/// catchment erodes faster than the slopes feeding it. Reproducing that needs
/// an incision term keyed on [ErosionResult.flow] rather than on local slope.
/// Worth knowing before expecting canyons: the honest summary is that this
/// rounds and fills, and the flow channel is what carries the drainage
/// information onward to shading.
///
/// ## Determinism
///
/// Seeded and sequential. The same grid and seed always produce the same
/// result, so a bake is reproducible and two machines agree.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Eroded terrain plus the water record that produced it.
class ErosionResult {
  const ErosionResult(this.height, this.flow, this.width, this.height_);

  /// Eroded heights, row-major, same layout as the input.
  final Float64List height;

  /// Flow accumulation per cell — how much water passed through. Normalised to
  /// `0..1` against the busiest cell.
  final Float64List flow;

  final int width;
  final int height_;
}

/// Tunables for [erode]. Defaults are a mild, general-purpose pass; the values
/// that matter most for character are [inertia] (how straight water runs) and
/// [erodeRate] against [depositRate] (whether the result is incised or filled).
class ErosionParams {
  const ErosionParams({
    this.droplets = 60000,
    this.lifetime = 48,
    this.inertia = 0.05,
    this.capacityFactor = 4.0,
    this.minSlope = 0.01,
    this.erodeRate = 0.3,
    this.depositRate = 0.3,
    this.evaporation = 0.02,
    this.gravity = 4.0,
    this.startSpeed = 1.0,
    this.startWater = 1.0,
    this.radius = 2,
  });

  /// How many droplets to run. The single biggest cost knob.
  final int droplets;

  /// Maximum steps a droplet takes before it is abandoned.
  final int lifetime;

  /// How much of its previous direction a droplet keeps. Near 0 follows the
  /// gradient exactly and carves straight chutes; near 1 ignores terrain and
  /// wanders. Low values look like real drainage.
  final double inertia;

  /// Scales how much sediment moving water can hold.
  final double capacityFactor;

  /// Floor on slope in the capacity term, so water on flat ground still
  /// carries something instead of dumping its whole load in one cell.
  final double minSlope;

  final double erodeRate;
  final double depositRate;
  final double evaporation;
  final double gravity;
  final double startSpeed;
  final double startWater;

  /// Radius (cells) over which erosion is spread. 0 erodes a single cell and
  /// leaves single-pixel pits; a few cells gives a real channel cross-section.
  final int radius;
}

/// Run droplet erosion over a height grid.
///
/// [heights] is row-major `width * height` in metres and is NOT modified. The
/// grid is treated as having hard edges: droplets that run off are retired,
/// which is correct for a bake over a padded region and is why the caller
/// should erode with overlap and crop afterwards.
ErosionResult erode(
  Float64List heights,
  int width,
  int height, {
  ErosionParams params = const ErosionParams(),
  int seed = 1,
}) {
  final h = Float64List.fromList(heights);
  final flow = Float64List(width * height);
  final rng = math.Random(seed);

  // Precomputed weights for spreading erosion over a disc, so a droplet does
  // not cut a one-cell-wide slot.
  final r = params.radius;
  final offsets = <int>[];
  final weights = <double>[];
  var weightSum = 0.0;
  for (var dy = -r; dy <= r; dy++) {
    for (var dx = -r; dx <= r; dx++) {
      final d = math.sqrt((dx * dx + dy * dy).toDouble());
      if (d > r) continue;
      final w = 1.0 - d / (r + 1);
      offsets.add(dy * width + dx);
      weights.add(w);
      weightSum += w;
    }
  }
  for (var i = 0; i < weights.length; i++) {
    weights[i] /= weightSum;
  }

  /// Bilinear height and gradient at a continuous cell coordinate.
  (double, double, double) sample(double px, double py) {
    final x0 = px.floor().clamp(0, width - 2);
    final y0 = py.floor().clamp(0, height - 2);
    final fx = px - x0, fy = py - y0;
    final i = y0 * width + x0;
    final nw = h[i], ne = h[i + 1], sw = h[i + width], se = h[i + width + 1];
    final gx = (ne - nw) * (1 - fy) + (se - sw) * fy;
    final gy = (sw - nw) * (1 - fx) + (se - ne) * fx;
    final hh = nw * (1 - fx) * (1 - fy) +
        ne * fx * (1 - fy) +
        sw * (1 - fx) * fy +
        se * fx * fy;
    return (hh, gx, gy);
  }

  for (var d = 0; d < params.droplets; d++) {
    var px = rng.nextDouble() * (width - 1);
    var py = rng.nextDouble() * (height - 1);
    var dx = 0.0, dy = 0.0;
    var speed = params.startSpeed;
    var water = params.startWater;
    var sediment = 0.0;
    // Where to put whatever the droplet is still carrying when it stops. A
    // droplet that simply vanished with its load would DELETE material rather
    // than move it, and with tens of thousands of droplets that silently sinks
    // the whole terrain while still looking plausible in isolation.
    var lastCell = -1;

    for (var life = 0; life < params.lifetime; life++) {
      final cx = px.floor(), cy = py.floor();
      if (cx < r + 1 || cy < r + 1 || cx >= width - r - 2 ||
          cy >= height - r - 2) {
        break; // ran off the padded edge
      }
      final cellIndex = cy * width + cx;
      lastCell = cellIndex;
      // Count PASSES, not remaining water. Flow accumulation is meant to stand
      // in for drainage area — how much upstream terrain funnels through this
      // cell — and with droplets seeded uniformly, visit count estimates that
      // directly.
      //
      // Weighting by `water` instead measures how FRESH the droplet is, which
      // peaks at its randomly-chosen start and decays as it descends. That puts
      // the highest values on ridges and slopes near seed points and the lowest
      // in the valleys everything drains into — anti-correlated with erosion,
      // which happens late in a droplet's life once it has picked up speed.
      flow[cellIndex] += 1.0;

      final (hOld, gx, gy) = sample(px, py);
      // Momentum blended with the downhill gradient.
      dx = dx * params.inertia - gx * (1 - params.inertia);
      dy = dy * params.inertia - gy * (1 - params.inertia);
      final len = math.sqrt(dx * dx + dy * dy);
      if (len < 1e-9) break; // sitting in a pit with nowhere to go
      dx /= len;
      dy /= len;
      px += dx;
      py += dy;
      if (px < 0 || py < 0 || px >= width - 1 || py >= height - 1) break;

      final (hNew, _, _) = sample(px, py);
      final drop = hNew - hOld; // negative going downhill

      // How much this droplet can carry right now.
      final capacity = math.max(-drop, params.minSlope) *
          speed *
          water *
          params.capacityFactor;

      if (sediment > capacity || drop > 0) {
        // Deposit: either overloaded, or moving uphill into a hollow, in which
        // case fill it no deeper than the step just climbed (otherwise the
        // droplet builds a tower).
        final amount = drop > 0
            ? math.min(drop, sediment)
            : (sediment - capacity) * params.depositRate;
        sediment -= amount;
        // Deposition lands on the cell just left, bilinearly, so sediment
        // settles smoothly rather than in single-cell spikes.
        final fx = px - dx - (px - dx).floor();
        final fy = py - dy - (py - dy).floor();
        h[cellIndex] += amount * (1 - fx) * (1 - fy);
        h[cellIndex + 1] += amount * fx * (1 - fy);
        h[cellIndex + width] += amount * (1 - fx) * fy;
        h[cellIndex + width + 1] += amount * fx * fy;
      } else {
        // Erode, but never more than the step down — a droplet cannot dig a
        // hole deeper than the slope it is descending, and letting it would
        // punch pits through ridge lines.
        final amount =
            math.min((capacity - sediment) * params.erodeRate, -drop);
        for (var k = 0; k < offsets.length; k++) {
          final idx = cellIndex + offsets[k];
          if (idx < 0 || idx >= h.length) continue;
          final take = amount * weights[k];
          h[idx] -= take;
          sediment += take;
        }
      }

      speed = math.sqrt(math.max(0.0, speed * speed - drop * params.gravity));
      water *= (1 - params.evaporation);
      if (water < 1e-4) break;
    }

    // Settle the remaining load where the droplet came to rest. This is what
    // makes the pass conservative: every gram lifted is put back down
    // somewhere, so erosion TRANSPORTS material instead of removing it.
    //
    // Spread over the same disc erosion uses. Dropping a whole load onto one
    // cell builds a one-cell tower, and with tens of thousands of droplets the
    // result is a field of spikes that is rougher than the terrain it started
    // from — technically conservative, visually ruined.
    if (sediment > 0 && lastCell >= 0) {
      for (var k = 0; k < offsets.length; k++) {
        final idx = lastCell + offsets[k];
        if (idx < 0 || idx >= h.length) continue;
        h[idx] += sediment * weights[k];
      }
    }
  }

  // Normalise flow so it is a usable 0..1 shading channel regardless of how
  // many droplets were run.
  var maxFlow = 0.0;
  for (final v in flow) {
    if (v > maxFlow) maxFlow = v;
  }
  if (maxFlow > 0) {
    for (var i = 0; i < flow.length; i++) {
      // Log-ish compression: raw accumulation is dominated by a few trunk
      // channels, and a linear map would leave every tributary invisible.
      flow[i] = math.log(1 + 9 * flow[i] / maxFlow) / math.ln10;
    }
  }

  return ErosionResult(h, flow, width, height);
}
