// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A second pair of eyes for any scene.
///
/// Every streamer in the scene budgets against ONE lens — the LOD probe —
/// and renders through another, which are normally the same camera. That
/// makes culling and selection impossible to see: whatever the camera looks
/// at is by definition what got selected. The rig splits them. [DebugCameraRig]
/// freezes the probe where the camera stands, the camera flies on, and
/// [DebugCameraGizmo] draws the frozen probe as a wireframe frustum so the
/// horizon cull, the LOD rings and the resident set can be read from outside.
///
/// Plugging a scene in is three calls:
///
///  * on freeze: [DebugCameraRig.freeze] with the live probe's world pose;
///  * every frame: [DebugCameraRig.probe] in place of constructing the
///    [LodProbeCamera] directly — it hands back the live lens until frozen;
///  * every frame: [DebugCameraGizmo.sync] with the RENDER camera.
///
/// The frozen pose is kept in the body's frame, so it stays put over the
/// ground as the body turns and the floating origin walks.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import '../../domain/terrain/terrain_lod.dart';
import 'coord_convert.dart';
import 'depth_materials.dart';
import 'lod_probe_camera.dart';

/// Where the probe was frozen, in the frame of the body it was frozen over.
class FrozenPose {
  const FrozenPose({
    required this.eyeBF,
    required this.forwardBF,
    required this.upBF,
    required this.focalPx,
    required this.fovRadiansY,
    required this.aspect,
  });

  /// The eye, body-centred metres in the body's frame.
  final Vector3 eyeBF;

  /// Unit view direction and screen up, in the body's frame.
  final Vector3 forwardBF;
  final Vector3 upBF;

  /// The probe's pixel budget at the moment of freezing (viewport + fov).
  final double focalPx;

  /// For drawing the frustum: the render camera's field of view and aspect.
  final double fovRadiansY;
  final double aspect;
}

/// Freezes the LOD probe and re-seats it on the body's current pose.
class DebugCameraRig {
  FrozenPose? _pose;

  /// Whether the probe is frozen; while true, [probe] ignores the live lens.
  bool get frozen => _pose != null;

  /// The frozen pose, or null when live.
  FrozenPose? get pose => _pose;

  /// Freeze the probe at this world pose. [bodyCentreWorld] and [bodyQuat]
  /// name the frame the pose is kept in — pass the body the probe is over so
  /// it co-rotates; leave them out for a scene without one.
  void freeze({
    required Vector3 eyeWorld,
    required Vector3 forwardWorld,
    required Vector3 upWorld,
    required double focalPx,
    required double fovRadiansY,
    required double aspect,
    Vector3 bodyCentreWorld = Vector3.zero,
    Quaternion bodyQuat = Quaternion.identity,
  }) {
    final inv = bodyQuat.conjugate;
    _pose = FrozenPose(
      eyeBF: inv.rotate(eyeWorld - bodyCentreWorld),
      forwardBF: inv.rotate(forwardWorld).normalized,
      upBF: inv.rotate(upWorld).normalized,
      focalPx: focalPx,
      fovRadiansY: fovRadiansY,
      aspect: aspect,
    );
  }

  /// Back to the live lens.
  void release() => _pose = null;

  /// The frozen eye in world metres for this frame's body pose.
  Vector3 frozenEyeWorld({
    Vector3 bodyCentreWorld = Vector3.zero,
    Quaternion bodyQuat = Quaternion.identity,
  }) =>
      bodyCentreWorld + bodyQuat.rotate(_pose!.eyeBF);

  /// The frozen view direction in world axes for this frame's body pose.
  Vector3 frozenForwardWorld({Quaternion bodyQuat = Quaternion.identity}) =>
      bodyQuat.rotate(_pose!.forwardBF);

  /// The frozen screen up in world axes for this frame's body pose.
  Vector3 frozenUpWorld({Quaternion bodyQuat = Quaternion.identity}) =>
      bodyQuat.rotate(_pose!.upBF);

  /// The lens the streamers look through this frame: the live one, or the
  /// frozen one re-seated on the body's pose and rebased to [focusWorld]
  /// (the floating origin — `eyeRel` is what `cameraEye:` arguments want).
  LodProbeCamera probe({
    required Vector3 liveEyeRel,
    required Vector3 liveForward,
    required double liveFocalPx,
    required Vector3 focusWorld,
    Vector3 bodyCentreWorld = Vector3.zero,
    Quaternion bodyQuat = Quaternion.identity,
  }) {
    final p = _pose;
    if (p == null) return LodProbeCamera(liveEyeRel, liveFocalPx, liveForward);
    final eyeWorld = bodyCentreWorld + bodyQuat.rotate(p.eyeBF);
    return LodProbeCamera(
        eyeWorld - focusWorld, p.focalPx, bodyQuat.rotate(p.forwardBF));
  }

  /// The view cone the streamers cull against this frame, in world axes:
  /// the live lens's, or the frozen one's turned to the body's current pose.
  ViewCone viewCone({
    required Vector3 liveForward,
    required double liveFovRadiansY,
    required double liveAspect,
    double marginRad = 0,
    Quaternion bodyQuat = Quaternion.identity,
  }) {
    final p = _pose;
    if (p == null) {
      return ViewCone.circumscribing(
          forward: liveForward,
          fovRadiansY: liveFovRadiansY,
          aspect: liveAspect,
          marginRad: marginRad);
    }
    return ViewCone.circumscribing(
        forward: bodyQuat.rotate(p.forwardBF),
        fovRadiansY: p.fovRadiansY,
        aspect: p.aspect,
        marginRad: marginRad);
  }

  /// The four corners of the view rectangle at distance [d] along
  /// [forward], as offsets from the eye: top-left, top-right, bottom-right,
  /// bottom-left. [up] need not be orthogonal to [forward]; it is
  /// re-orthogonalised (screen up is forward-orthogonalised too).
  static List<Vector3> frustumCorners(
    Vector3 forward,
    Vector3 up,
    double fovRadiansY,
    double aspect,
    double d,
  ) {
    final f = forward.normalized;
    var u = up - f * up.dot(f);
    if (u.length < 1e-9) {
      final seed = f.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
      u = seed - f * seed.dot(f);
    }
    u = u.normalized;
    final r = f.cross(u);
    final halfH = d * math.tan(fovRadiansY / 2);
    final halfW = halfH * aspect;
    final centre = f * d;
    return [
      centre + u * halfH - r * halfW,
      centre + u * halfH + r * halfW,
      centre - u * halfH + r * halfW,
      centre - u * halfH - r * halfW,
    ];
  }
}

/// Draws a [DebugCameraRig]'s frozen probe: the frustum out to [farM], a
/// near rectangle, the view axis, and a cross at the eye.
///
/// Lines are `PolylineGeometry` strips rebuilt copy-on-write whenever the
/// pose, the origin, the body pose, the render camera or the viewport moves
/// — the same discipline as LineNodes, because in-place buffer updates race
/// frames in flight on the Windows GLES backend.
class DebugCameraGizmo {
  DebugCameraGizmo(this.scene);

  final fs.Scene scene;
  final Map<String, fs.Node> _nodes = {};
  final List<(int, fs.Mesh)> _retired = [];
  static const int _retireAfterMs = 400;

  Object? _lastPose;
  Vector3? _lastFocus;
  Vector3? _lastBodyCentre;
  Quaternion? _lastBodyQuat;
  double _lastFar = -1;
  vm.Vector3? _lastEye;
  vm.Vector3? _lastUp;
  ui.Size? _lastViewport;

  /// Remove the drawing.
  void clear() {
    for (final n in _nodes.values) {
      scene.remove(n);
    }
    _nodes.clear();
    _lastPose = null;
  }

  /// Draw (or update) the frozen probe; removes it when [rig] is live or
  /// [visible] is false.
  void sync(
    DebugCameraRig rig, {
    required Vector3 focusWorld,
    required fs.PerspectiveCamera renderCamera,
    required ui.Size viewport,
    bool visible = true,
    Vector3 bodyCentreWorld = Vector3.zero,
    Quaternion bodyQuat = Quaternion.identity,
    double farM = 5000,
  }) {
    final pose = rig.pose;
    if (pose == null || !visible) {
      if (_nodes.isNotEmpty) clear();
      return;
    }
    if (viewport.width <= 0 || viewport.height <= 0) return;

    final unchanged = identical(pose, _lastPose) &&
        _lastFocus == focusWorld &&
        _lastBodyCentre == bodyCentreWorld &&
        _sameQuat(_lastBodyQuat, bodyQuat) &&
        _lastFar == farM &&
        _lastViewport == viewport &&
        _lastEye != null &&
        (renderCamera.position - _lastEye!).length2 < 1e-12 &&
        (renderCamera.up - _lastUp!).length2 < 1e-12;
    if (unchanged) return;
    _lastPose = pose;
    _lastFocus = focusWorld;
    _lastBodyCentre = bodyCentreWorld;
    _lastBodyQuat = bodyQuat;
    _lastFar = farM;
    _lastViewport = viewport;
    _lastEye = renderCamera.position.clone();
    _lastUp = renderCamera.up.clone();

    final eye = rig.frozenEyeWorld(
        bodyCentreWorld: bodyCentreWorld, bodyQuat: bodyQuat);
    final fwd = rig.frozenForwardWorld(bodyQuat: bodyQuat);
    final up = rig.frozenUpWorld(bodyQuat: bodyQuat);
    final far = DebugCameraRig.frustumCorners(
        fwd, up, pose.fovRadiansY, pose.aspect, farM);
    final near = DebugCameraRig.frustumCorners(
        fwd, up, pose.fovRadiansY, pose.aspect, farM * 0.05);

    vm.Vector3 at(Vector3 offsetFromEye) =>
        relToScene(eye + offsetFromEye - focusWorld);

    final strips = <String, (List<vm.Vector3>, vm.Vector4, double)>{
      // Frustum edges, eye to the far corners.
      for (var i = 0; i < 4; i++)
        'edge$i': ([at(Vector3.zero), at(far[i])], _cyan, 1.5),
      'far': ([for (final c in far) at(c), at(far[0])], _cyan, 2.0),
      'near': ([for (final c in near) at(c), at(near[0])], _cyan, 1.5),
      // The view axis, a little past the far plane.
      'axis': ([at(Vector3.zero), at(fwd * (farM * 1.1))], _yellow, 2.0),
    };
    // A cross at the eye, sized to the frustum.
    final s = farM * 0.02;
    final r = fwd.cross(up).normalized;
    strips['eyeR'] = ([at(r * -s), at(r * s)], _white, 2.0);
    strips['eyeU'] = ([at(up * -s), at(up * s)], _white, 2.0);
    strips['eyeF'] = ([at(fwd * -s), at(fwd * s)], _white, 2.0);

    final now = DateTime.now().millisecondsSinceEpoch;
    _retired.removeWhere((e) => now - e.$1 > _retireAfterMs);
    for (final entry in strips.entries) {
      final (pts, colour, width) = entry.value;
      final geometry = fs.PolylineGeometry(
        pts,
        width: width,
        widthMode: fs.PolylineWidthMode.screenPixels,
      );
      try {
        geometry.updateForCamera(renderCamera, viewport);
      } on ArgumentError {
        continue; // transient degenerate camera; keep last frame's mesh
      }
      // Blend with PREMULTIPLIED colour: opaque ignores alpha and the
      // translucent pass blends premultiplied.
      final c = colour;
      final mesh = fs.Mesh(
        geometry,
        DepthSafeUnlitMaterial()
          ..baseColorFactor = vm.Vector4(c.x * c.w, c.y * c.w, c.z * c.w, c.w)
          ..alphaMode = fs.AlphaMode.blend,
      );
      final node = _nodes[entry.key];
      if (node == null) {
        final n = fs.Node(mesh: mesh);
        scene.add(n);
        _nodes[entry.key] = n;
      } else {
        final old = node.mesh;
        if (old != null) _retired.add((now, old));
        node.mesh = mesh;
      }
    }
  }

  static bool _sameQuat(Quaternion? a, Quaternion b) =>
      a != null && a.w == b.w && a.x == b.x && a.y == b.y && a.z == b.z;

  static final _cyan = vm.Vector4(0.3, 0.95, 1.0, 0.9);
  static final _yellow = vm.Vector4(1.0, 0.85, 0.2, 0.9);
  static final _white = vm.Vector4(1, 1, 1, 0.95);
}
