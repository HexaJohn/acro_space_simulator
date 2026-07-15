// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;

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

  /// Bloom radius as a multiple of the star's true radius.
  static double scale = 9.0;

  /// Floor on the bloom's apparent radius, px. The sun is a ~0.5 deg disc — a
  /// few px from any inner planet — so a pure multiple of [scale] would vanish.
  /// This is what keeps it reading as glare at any distance.
  static double minPx = 70.0;

  /// Ceiling on the apparent radius, px, so a close approach cannot fill the
  /// frame with white.
  static double maxPx = 900.0;

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
        ..shader = ui.Gradient.radial(c, s / 2, const [
          ui.Color(0xFFFFFFFF), // blown-out core
          ui.Color(0xFFFFFFFF),
          ui.Color(0xF0FFF6DC),
          ui.Color(0x80FFE49B), // warm mid
          ui.Color(0x2EFFB347),
          ui.Color(0x00FF8C1A), // transparent
        ], const [
          0.0,
          0.06,
          0.16,
          0.34,
          0.60,
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

  // --- per-frame ------------------------------------------------------------

  fs.Node? _node;
  fs.BillboardGeometry? _geo;
  DepthSafeSpriteMaterial? _mat;
  bool _spriteApplied = false;

  void update(
    WorldSnapshot snap,
    FloatingOrigin origin,
    BodyNodes bodies, {
    SceneCamera? camera,
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
    debugLine = 'bloom ${wantPx.toStringAsFixed(0)}px';
  }

  void _clear() {
    final n = _node;
    if (n != null) {
      _scene.remove(n);
      _node = null;
    }
    debugLine = '';
  }
}
