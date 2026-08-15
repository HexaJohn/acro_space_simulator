// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../adapters/presenters/camera_view.dart';
import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/vector3.dart';
import 'body_nodes.dart';
import 'coord_convert.dart';
import 'depth_materials.dart';

/// Dramatic white bloom on the star, as an additive camera-facing sprite drawn
/// IN the scene at the star's position.
///
/// Being real scene geometry is the whole point. flutter_scene has no
/// post-process pass and materials cannot sample scene depth, so a bloom
/// composited over the finished frame (the first cut of this) has no way to
/// know what is in front of the sun: it can only approximate occlusion
/// analytically, which handles body spheres and silently misses terrain relief
/// and vessels. A depth-TESTED sprite gets all of it for free and per-pixel —
/// a ridge, a hill, a landing leg, another craft.
///
/// It degrades the right way, too: as the sun sets behind a ridge the sprite is
/// progressively clipped, so the glow shrinks and stays above the skyline
/// instead of popping out. (A true bloom would also bleed slightly OVER the
/// occluder — a lens/atmospheric effect, not a geometric one. Hard-clipping is
/// the honest trade for correct occlusion.)
class StarBloomNodes {
  StarBloomNodes(this._scene);

  final fs.Scene _scene;

  /// Runtime kill switch (dev ext / debug panel).
  static bool enabled = true;

  /// Bloom radius as a multiple of the star's true radius. 6 (down from 9):
  /// the 9x sprite with the old wide-core gradient read as an opaque white
  /// ball rather than glare.
  static double scale = 6.0;

  /// Floor on the bloom's apparent radius, px. The sun is a ~0.5 deg disc — a
  /// few px from any inner planet — so a pure multiple of [scale] would vanish.
  /// This is what keeps it reading as glare at any distance.
  static double minPx = 48.0;

  /// Ceiling on the apparent radius, px, so a close approach cannot fill the
  /// frame with white.
  static double maxPx = 520.0;

  /// Lens flare: the classic ghost train along the sun -> screen-centre axis.
  /// Ghosts are an artifact of the lens, so they ignore scene depth; whether
  /// the SUN is visible is decided analytically (body-sphere occlusion) and
  /// the whole train fades with it, and with the sun leaving the frame.
  static bool flares = true;

  /// Overall flare intensity, 0..~2. Multiplies every ghost's alpha.
  static double flareStrength = 1.0;

  /// Debug line for the HUD.
  static String debugLine = '';

  // --- procedural sprite (built once) ---------------------------------------

  static Object? _sprite;
  static bool _spriteBuilding = false;

  /// Radial falloff, baked once into a texture. Additive blending means alpha
  /// IS intensity here: the flat core adds a blown-out white, the tail adds a
  /// warm haze, and alpha 0 adds exactly nothing.
  static void _ensureSprite() {
    if (_sprite != null || _spriteBuilding) return;
    _spriteBuilding = true;
    const s = 128;
    const c = ui.Offset(s / 2, s / 2);
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.drawCircle(
      c,
      s / 2,
      ui.Paint()
        // Tight core, fast falloff. The old profile held full white out to
        // 16% and half-strength to 34%, which under additive blending reads
        // as an opaque ball; glare is a small blown core and a LONG dim
        // tail, so most of the sprite now adds only a whisper.
        ..shader = ui.Gradient.radial(c, s / 2, const [
          ui.Color(0xFFFFFFFF), // blown-out core
          ui.Color(0xFFFFFFFF),
          ui.Color(0xA8FFF6DC),
          ui.Color(0x42FFE49B), // warm mid
          ui.Color(0x14FFB347),
          ui.Color(0x00FF8C1A), // transparent
        ], const [
          0.0,
          0.03,
          0.10,
          0.26,
          0.55,
          1.0
        ]),
    );
    rec
        .endRecording()
        .toImage(s, s)
        .then((img) => fs.gpuTextureFromImage(img))
        .then((tex) {
      _sprite = tex as Object;
    }).catchError((Object _) {
      // Let a later frame retry rather than wedging the flag on.
      _spriteBuilding = false;
    });
  }

  // --- ghost sprite (built once) --------------------------------------------

  static Object? _ghost;
  static bool _ghostBuilding = false;

  /// Soft disc with a faint cool rim — one texture for every ghost; the
  /// per-instance colour supplies the classic warm-to-cool train.
  static void _ensureGhost() {
    if (_ghost != null || _ghostBuilding) return;
    _ghostBuilding = true;
    const s = 64;
    const c = ui.Offset(s / 2, s / 2);
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.drawCircle(
      c,
      s / 2,
      ui.Paint()
        ..shader = ui.Gradient.radial(c, s / 2, const [
          ui.Color(0xB4FFFFFF),
          ui.Color(0x78EFF6FF),
          ui.Color(0x2E9FC8FF), // cool rim
          ui.Color(0x009FC8FF),
        ], const [
          0.0,
          0.45,
          0.78,
          1.0
        ]),
    );
    rec
        .endRecording()
        .toImage(s, s)
        .then((img) => fs.gpuTextureFromImage(img))
        .then((tex) {
      _ghost = tex as Object;
    }).catchError((Object _) {
      _ghostBuilding = false;
    });
  }

  // --- per-frame ------------------------------------------------------------

  fs.Node? _node;
  fs.BillboardGeometry? _geo;
  DepthSafeSpriteMaterial? _mat;
  bool _spriteApplied = false;

  fs.Node? _flareNode;
  fs.BillboardGeometry? _flareGeo;
  OverlaySpriteMaterial? _flareMat;
  bool _ghostApplied = false;

  /// The ghost train: screen-position factor from the sun toward (and past)
  /// the frame centre, apparent diameter in px, and tint (a = intensity).
  static const _ghosts = <(double, double, double, double, double, double)>[
    (0.65, 46, 1.00, 0.95, 0.85, 0.16),
    (0.42, 26, 0.60, 0.95, 1.00, 0.14),
    (0.18, 64, 0.55, 1.00, 0.90, 0.07),
    (-0.10, 36, 1.00, 0.75, 0.45, 0.12),
    (-0.35, 96, 1.00, 0.55, 0.80, 0.05),
    (-0.62, 50, 0.55, 0.70, 1.00, 0.10),
    (-0.95, 150, 0.50, 0.65, 1.00, 0.045),
  ];

  void update(
    WorldSnapshot snap,
    FloatingOrigin origin,
    BodyNodes bodies, {
    SceneCamera? camera,
    ui.Size? viewport,
  }) {
    _ensureSprite();
    if (!enabled || camera == null) {
      _clear();
      return;
    }

    // The star body itself — starWorld() gives the position, but the bloom is
    // sized off the true radius.
    BodySnapshot? star;
    for (final b in snap.bodies.values) {
      if (bodies.isStar(b.id)) {
        star = b;
        break;
      }
    }
    if (star == null || star.radius <= 0) {
      _clear();
      return;
    }

    // Focus-relative metres — the frame projectPx/radiusPx expect (see
    // PerspectiveCamera's doc: inputs are `world - focusWorld`).
    final rel = Vector3(star.px, star.py, star.pz) - origin.focusWorld;

    // radiusPx is ~linear in the radius while R/d is small (it is asin-based,
    // and the sun subtends <0.1 rad from anywhere we render), so one probe at
    // 1 m converts px <-> metres both ways.
    final pxPerM = camera.radiusPx(rel, 1.0);
    if (pxPerM <= 0 || !pxPerM.isFinite) {
      _clear();
      return;
    }
    final wantPx =
        (star.radius * pxPerM * scale).clamp(minPx, math.max(minPx, maxPx));
    final radiusM = wantPx / pxPerM;

    final geo = _geo ??= fs.BillboardGeometry(capacity: 1);
    final mat = _mat ??= DepthSafeSpriteMaterial()
      // Order-independent and never darkens what it covers — the mode the
      // engine documents for glows.
      ..blendMode = fs.SpriteBlendMode.additive;

    // Texture getters hand back a white placeholder rather than null, so track
    // application with a flag and retry every frame until the upload lands
    // (a parked camera never rebuilds).
    if (!_spriteApplied && _sprite != null) {
      mat.colorTexture = _sprite;
      _spriteApplied = true;
    }

    final d = lengthToScene(radiusM * 2); // width/height are diameters
    geo.setInstance(0, center: relToScene(rel), width: d, height: d);
    geo.commit(1);

    if (_node == null) {
      final n = fs.Node(mesh: fs.Mesh(geo, mat));
      _scene.add(n);
      _node = n;
    }
    final flarePx =
        _updateFlares(snap, origin, star, rel, camera, viewport);
    debugLine = 'bloom ${wantPx.toStringAsFixed(0)}px$flarePx';
  }

  /// Place the ghost train for this frame; returns a debug suffix.
  String _updateFlares(
    WorldSnapshot snap,
    FloatingOrigin origin,
    BodySnapshot star,
    Vector3 rel,
    SceneCamera camera,
    ui.Size? viewport,
  ) {
    _ensureGhost();
    if (!flares || viewport == null || flareStrength <= 0) {
      _clearFlares();
      return '';
    }
    final eye = camera.eyeOffset;
    final toSun = rel - eye;
    final dist = toSun.length;
    final screen = camera.projectPx(rel);
    if (dist <= 0 || screen == null) {
      _clearFlares();
      return '';
    }
    final dir = toSun / dist;
    final fwd = camera.forward;
    final cosA = dir.dot(fwd);
    if (cosA <= 0.05) {
      _clearFlares();
      return '';
    }

    // Fade the whole train as the sun leaves the frame; a sun slightly
    // off-screen still throws ghosts across it, like a real lens.
    final cx = viewport.width / 2, cy = viewport.height / 2;
    final offN = math.sqrt(math.pow(screen.x - cx, 2).toDouble() +
            math.pow(screen.y - cy, 2).toDouble()) /
        math.max(1.0, math.min(cx, cy));
    final edge = 1.0 - _smooth01((offN - 1.15) / 0.45);

    // And fade with the sun's actual visibility: flares are lens artifacts,
    // drawn over everything, so occlusion has to be decided here. Body
    // SPHERES only — a ridge hiding the sun still flares briefly, which is
    // the honest cost of a lens effect with no depth readback.
    var vis = 1.0;
    for (final b in snap.bodies.values) {
      if (b.id == star.id || b.radius <= 0) continue;
      final bRel = Vector3(b.px, b.py, b.pz) - origin.focusWorld - eye;
      final along = bRel.dot(dir);
      if (along <= 0 || along >= dist) continue;
      final dmin =
          math.sqrt(math.max(bRel.lengthSquared - along * along, 0.0));
      vis = math.min(
          vis, _smooth01((dmin - b.radius) / math.max(b.radius * 0.08, 1.0)));
    }

    final k = flareStrength * edge * vis;
    if (k <= 0.01) {
      _clearFlares();
      return '';
    }

    // Ghosts sit on the line from the sun through the frame centre. Build
    // each ghost's world direction from the sun's off-axis decomposition:
    // screen offset is ~linear in tan(angle), so scaling the tangent by the
    // ghost's position factor lands it at that fraction of the sun's offset.
    var pHat = dir - fwd * cosA;
    final pLen = pHat.length;
    final tanA = pLen / cosA;
    pHat = pLen > 1e-9 ? pHat / pLen : Vector3(0, 0, 1);

    final geo = _flareGeo ??= fs.BillboardGeometry(capacity: _ghosts.length);
    final mat = _flareMat ??= OverlaySpriteMaterial()
      ..blendMode = fs.SpriteBlendMode.additive;
    if (!_ghostApplied && _ghost != null) {
      mat.colorTexture = _ghost;
      _ghostApplied = true;
    }

    // A fixed stand-off keeps the ghosts comfortably inside the frustum;
    // depth is ignored (OverlaySpriteMaterial), so the distance only feeds
    // the px -> world size conversion.
    const standOffM = 5000.0;
    for (var i = 0; i < _ghosts.length; i++) {
      final (f, sizePx, r, g, b, a) = _ghosts[i];
      final gDir = (fwd + pHat * (tanA * f)).normalized;
      final gRel = eye + gDir * standOffM;
      final pxPerM = camera.radiusPx(gRel, 1.0);
      final dScene = pxPerM > 0
          ? lengthToScene(sizePx / pxPerM)
          : 0.0;
      geo.setInstance(
        i,
        center: relToScene(gRel),
        width: dScene,
        height: dScene,
        color: vm.Vector4(r, g, b, a * k),
      );
    }
    geo.commit(_ghosts.length);

    if (_flareNode == null) {
      final n = fs.Node(mesh: fs.Mesh(geo, mat));
      _scene.add(n);
      _flareNode = n;
    }
    return '  flare ${(k * 100).round()}%';
  }

  static double _smooth01(double x) {
    final t = x.clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  }

  void _clearFlares() {
    final n = _flareNode;
    if (n != null) {
      _scene.remove(n);
      _flareNode = null;
    }
  }

  void _clear() {
    final n = _node;
    if (n != null) {
      _scene.remove(n);
      _node = null;
    }
    _clearFlares();
    debugLine = '';
  }
}
