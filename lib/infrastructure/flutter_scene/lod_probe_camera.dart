// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../../adapters/presenters/camera_view.dart';
import '../../domain/shared/vector3.dart';

/// The one lens terrain LOD looks through in the studios.
///
/// Only [radiusPx] and [forward] are real: apparent size is the single
/// budget the terrain streamer consults (chunk splits and the zoom probe),
/// and the view direction aims its head-lamp. Every other [SceneCamera]
/// member throws — if the streamer ever grows another dependency, the
/// studios should hear about it loudly rather than silently reading a
/// half-implemented camera.
///
/// Born in the terrain studio (where `camera: null` meant the screen-space
/// budget returned zero pixels for everything, so nothing ever split except
/// forced-refinement islands — detail was a cliff at the edit-refine range
/// and root-coarse beyond it); shared so the city studio streams through the
/// same lens instead of reproducing that cliff around every colony.
class LodProbeCamera implements SceneCamera {
  LodProbeCamera(this.eyeRel, this.focalPx, this._forward);

  /// The eye, relative to the floating origin's focus — the same frame the
  /// streamer's `rel` arguments arrive in.
  final Vector3 eyeRel;

  /// The view direction — the streamer's second dependency, found the loud
  /// way: it aims the head-lamp down the view axis.
  final Vector3 _forward;

  @override
  Vector3 get forward => _forward;

  /// Pixels per radian-ish: (viewport height / 2) / tan(fov / 2). Happens
  /// to be the meaning [SceneCamera.focalPx] already carries, so the field
  /// doubles as that member's implementation.
  @override
  final double focalPx;

  @override
  double radiusPx(Vector3 rel, double radiusM) {
    final d = (rel - eyeRel).length;
    return d < 1 ? 1e9 : radiusM * focalPx / d;
  }

  /// The focal length for a viewport [heightPx] tall seen through
  /// [fovRadiansY] — kept here so every probe user derives it the same way.
  static double focalPxFor(double heightPx, double fovRadiansY) =>
      heightPx * 0.5 / math.tan(fovRadiansY / 2);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('LOD probe camera: only radiusPx is real');
}
