// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// ignore_for_file: implementation_imports

/// The battle in the scene (docs/plans/combat.md §7B): smoke hanging over
/// every objective being fought over, and the muzzle flashes and blasts
/// inside it.
///
/// Persistent, unlike the impact FX: one smoke and one flash emitter per
/// fought-over objective, made the first time it is fought over and kept,
/// their rates following the fight's heat — so a battle costs two
/// translucent draws an objective and allocates nothing per shot. The host
/// says where the fighting is through [CombatFxState] (its own state: the
/// road overlay's is wiped by every tool change); an objective no longer
/// fought over stops emitting, its smoke thins out, and its emitters go
/// once the last of it has.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_scene/src/components/particle_emitter_component.dart';
import 'package:flutter_scene/src/particles/distribution.dart';
import 'package:flutter_scene/src/particles/emitter_shape.dart';
import 'package:flutter_scene/src/particles/particle_module.dart';
import 'package:flutter_scene/src/particles/particle_system.dart';
import 'package:flutter_scene/src/particles/spawner.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';
import 'depth_materials.dart';

/// One place a battle is being fought: an objective, body-fixed.
class CombatFxSite {
  const CombatFxSite(this.key, this.bodyId, this.bf, this.heat);

  /// Stable across frames: `<operation>:<objective>`.
  final String key;
  final String bodyId;

  /// The objective's ground point, body-fixed metres.
  final Vector3 bf;

  /// 0..1, how hot the fight is.
  final double heat;
}

/// Where the battles are, written by the host each frame.
abstract final class CombatFxState {
  static List<CombatFxSite> sites = const [];
}

class CombatFxNodes {
  CombatFxNodes(this._scene) {
    _ensureSprite();
  }

  final fs.Scene _scene;
  final Map<String, _Fx> _live = {};
  final List<String> _order = [];

  /// Smoke outlives its source by this long before the emitters are dropped.
  static const double lingerS = 12;

  static Object? _sprite;
  static bool _spriteBuilding = false;

  static void _ensureSprite() {
    if (_sprite != null || _spriteBuilding) return;
    _spriteBuilding = true;
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(
      const ui.Rect.fromLTWH(0, 0, 64, 64),
      ui.Paint()
        ..shader = ui.Gradient.radial(
          const ui.Offset(32, 32),
          32,
          const [
            ui.Color(0xFFFFFFFF),
            ui.Color(0xBFFFFFFF),
            ui.Color(0x33FFFFFF),
            ui.Color(0x00FFFFFF),
          ],
          const [0.0, 0.3, 0.7, 1.0],
        ),
    );
    rec.endRecording().toImage(64, 64).then((img) => fs.gpuTextureFromImage(img)).then((tex) {
      _sprite = tex as Object;
    }).catchError((Object _) {
      _spriteBuilding = false;
    });
  }

  double _lastEpoch = double.nan;

  /// What the last update did, for a driver's status: sites asked for, live
  /// emitters, live particles, whether the sprite is ready.
  static String debugLine = '';

  void update(WorldSnapshot snap, FloatingOrigin origin) {
    _ensureSprite();
    final frozen = snap.epoch == _lastEpoch;
    _lastEpoch = snap.epoch;
    final seen = <String>[];
    if (_sprite != null) {
      for (final s in CombatFxState.sites) {
        if (snap.bodies[s.bodyId] == null) continue;
        seen.add(s.key);
        var fx = _live[s.key];
        if (fx == null) {
          fx = _make(s);
          _live[s.key] = fx;
          _order.add(s.key);
        }
        fx.lastHotEpoch = snap.epoch;
        fx.smoke.system.spawner.rate = 3 + 10 * s.heat;
        fx.flash.system.spawner.rate = 10 + 40 * s.heat;
      }
    }
    final gone = <String>[];
    for (final key in _order) {
      final fx = _live[key]!;
      final body = snap.bodies[fx.bodyId];
      if (!seen.contains(key)) {
        fx.smoke.system.spawner.rate = 0;
        fx.flash.system.spawner.rate = 0;
        if (body == null || snap.epoch - fx.lastHotEpoch > lingerS || snap.epoch < fx.lastHotEpoch) {
          _scene.remove(fx.node);
          gone.add(key);
          continue;
        }
      }
      if (body == null) continue;
      final q = Quaternion(body.qw, body.qx, body.qy, body.qz);
      final world = Vector3(body.px, body.py, body.pz) + q.rotate(fx.bf);
      fx.node.localTransform = vm.Matrix4.compose(
        origin.worldToScene(world),
        quatToScene(q * fx.alignBF),
        vm.Vector3.all(1.0),
      );
      fx.smoke.paused = frozen;
      fx.flash.paused = frozen;
    }
    for (final key in gone) {
      _live.remove(key);
      _order.remove(key);
    }
    var alive = 0;
    for (final fx in _live.values) {
      alive += fx.smoke.system.storage.aliveCount + fx.flash.system.storage.aliveCount;
    }
    debugLine = 'sites ${CombatFxState.sites.length} live ${_live.length} '
        'particles $alive sprite ${_sprite != null} frozen $frozen';
  }

  _Fx _make(CombatFxSite s) {
    final up = s.bf.normalized;
    final smoke = ParticleSystem(
      maxParticles: 200,
      shape: SphereShape(radius: lengthToScene(20), hemisphere: true),
      spawner: Spawner(rate: 0),
      looping: true,
      duration: 1.0,
      lifetime: UniformFloat(6, 11),
      startSpeed: UniformFloat(lengthToScene(0.6), lengthToScene(2.2)),
      // Dark and dense: grey smoke over grey regolith reads as nothing.
      startSize: UniformFloat(lengthToScene(16), lengthToScene(28)),
      startColor: ConstantColor(vm.Vector4(0.20, 0.19, 0.18, 1.0)),
      // Smoke climbs a little and spreads: a column, not a carpet.
      gravity: vm.Vector3(0, lengthToScene(0.25), 0),
      modules: [
        LinearDragModule(0.6),
        SizeOverLifeModule(CurveFloat(ParticleCurve.linear(from: 1.0, to: 3.5))),
        ColorOverLifeModule(GradientColor(ColorGradient([
          ColorStop(0.0, vm.Vector4(0.22, 0.20, 0.18, 0.0)),
          ColorStop(0.1, vm.Vector4(0.20, 0.19, 0.17, 0.78)),
          ColorStop(0.7, vm.Vector4(0.18, 0.17, 0.16, 0.5)),
          ColorStop(1.0, vm.Vector4(0.16, 0.15, 0.15, 0.0)),
        ]))),
      ],
      seed: s.key.hashCode,
    );
    final flash = ParticleSystem(
      maxParticles: 96,
      shape: SphereShape(radius: lengthToScene(30), hemisphere: true),
      spawner: Spawner(rate: 0),
      looping: true,
      duration: 1.0,
      lifetime: UniformFloat(0.06, 0.2),
      startSpeed: UniformFloat(0, lengthToScene(0.5)),
      startSize: UniformFloat(lengthToScene(2.5), lengthToScene(7)),
      startColor: ConstantColor(vm.Vector4(1.0, 0.85, 0.5, 1.0)),
      gravity: vm.Vector3.zero(),
      modules: [
        ColorOverLifeModule(GradientColor(ColorGradient([
          ColorStop(0.0, vm.Vector4(1.0, 0.95, 0.75, 1.0)),
          ColorStop(1.0, vm.Vector4(1.0, 0.5, 0.15, 0.0)),
        ]))),
      ],
      seed: s.key.hashCode ^ 0x2f2f,
    );
    final smokeEmitter = ParticleEmitterComponent(
      system: smoke,
      material: DepthSafeSpriteMaterial()
        ..colorTexture = _sprite
        ..blendMode = fs.SpriteBlendMode.alpha,
    );
    final flashEmitter = ParticleEmitterComponent(
      system: flash,
      material: DepthSafeSpriteMaterial()
        ..colorTexture = _sprite
        ..blendMode = fs.SpriteBlendMode.additive,
    );
    final node = fs.Node()
      ..add(fs.Node()..addComponent(smokeEmitter))
      ..add(fs.Node()..addComponent(flashEmitter));
    _scene.add(node);
    return _Fx(node, smokeEmitter, flashEmitter, s.bodyId, s.bf, _yOnto(up));
  }

  static Quaternion _yOnto(Vector3 to) {
    const from = Vector3(0, 1, 0);
    final d = from.dot(to).clamp(-1.0, 1.0);
    if (d > 0.9999) return Quaternion.identity;
    if (d < -0.9999) return Quaternion.axisAngle(const Vector3(1, 0, 0), math.pi);
    return Quaternion.axisAngle(from.cross(to).normalized, math.acos(d));
  }
}

class _Fx {
  _Fx(this.node, this.smoke, this.flash, this.bodyId, this.bf, this.alignBF);
  final fs.Node node;
  final ParticleEmitterComponent smoke;
  final ParticleEmitterComponent flash;
  final String bodyId;
  final Vector3 bf;
  final Quaternion alignBF;
  double lastHotEpoch = 0;
}
