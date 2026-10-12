// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Lambert's problem: the conic that carries a body from one point to another
/// in a given time (docs/plans/combat.md §7O — what a silo's salvo flies).
///
/// Universal variables, solved by bisection on ψ (Vallado, *Fundamentals of
/// Astrodynamics*, algorithm 58): the time of flight grows monotonically with
/// ψ over a single revolution, so the bisection always converges where a
/// Newton step can wander off the region where the variables are real. The
/// short way round only — the transfer angle under π — which is every
/// ballistic arc between two points on a body's ground.
library;

import 'dart:math' as math;

import '../shared/vector3.dart';

/// The velocities at either end of a Lambert transfer.
class LambertSolution {
  const LambertSolution(this.departure, this.arrival);
  final Vector3 departure;
  final Vector3 arrival;
}

/// The short-way transfer from [r1] to [r2] (body-centred, metres) taking
/// [timeOfFlightS] about a body of gravitational parameter [mu]; null when
/// there is none (the two points in line with the centre, or no
/// convergence).
LambertSolution? solveLambert(Vector3 r1, Vector3 r2, double timeOfFlightS, double mu) {
  final r1m = r1.length, r2m = r2.length;
  if (r1m <= 0 || r2m <= 0 || timeOfFlightS <= 0 || mu <= 0) return null;
  final cosDnu = (r1.dot(r2) / (r1m * r2m)).clamp(-1.0, 1.0);
  // In line with the centre either way round: no plane to transfer in.
  if (cosDnu > 1 - 1e-12) return null;
  final a = math.sqrt(r1m * r2m * (1 + cosDnu));
  if (a < 1e-9) return null;
  final sqrtMu = math.sqrt(mu);
  var psi = 0.0, c2 = 0.5, c3 = 1 / 6;
  var psiUp = 4 * math.pi * math.pi, psiLow = -4 * math.pi;
  var y = 0.0;
  for (var i = 0; i < 400; i++) {
    y = r1m + r2m + a * (psi * c3 - 1) / math.sqrt(c2);
    double dt;
    if (y < 0) {
      // Too little ψ for a real χ: the time it would take is "too short".
      dt = -1;
    } else {
      final chi = math.sqrt(y / c2);
      dt = (chi * chi * chi * c3 + a * math.sqrt(y)) / sqrtMu;
      if ((dt - timeOfFlightS).abs() <= 1e-7 * timeOfFlightS) break;
    }
    if (dt <= timeOfFlightS) {
      psiLow = psi;
    } else {
      psiUp = psi;
    }
    psi = (psiUp + psiLow) / 2;
    (c2, c3) = _stumpff(psi);
    if (i == 399) return null;
  }
  if (y <= 0) return null;
  final f = 1 - y / r1m;
  final gDot = 1 - y / r2m;
  final g = a * math.sqrt(y / mu);
  if (g.abs() < 1e-12) return null;
  return LambertSolution((r2 - r1 * f) * (1 / g), (r2 * gDot - r1) * (1 / g));
}

/// Stumpff's c2 and c3 at ψ.
(double, double) _stumpff(double psi) {
  if (psi > 1e-6) {
    final s = math.sqrt(psi);
    return ((1 - math.cos(s)) / psi, (s - math.sin(s)) / (s * s * s));
  }
  if (psi < -1e-6) {
    final s = math.sqrt(-psi);
    final sinh = (math.exp(s) - math.exp(-s)) / 2, cosh = (math.exp(s) + math.exp(-s)) / 2;
    return ((1 - cosh) / psi, (sinh - s) / (s * s * s));
  }
  return (0.5, 1 / 6);
}
