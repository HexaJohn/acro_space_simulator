// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// ignore_for_file: implementation_imports

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;
// Same implementation-import precedent as exhaust_nodes.dart: the particle
// module is not yet exported from scene.dart upstream.
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
import 'terrain/terrain_textures.dart';

/// Terrain-impact FX: a debris burst plus a lingering dust cloud at the spot a
/// hard impact hit the ground. PURE ground effect — the craft's own demise
/// gets no fireball; what you see is the surface answering the hit.
///
/// Spawned off the snapshot's transient 'Impact' events (which carry the
/// BODY-FIXED contact point), anchored in the body frame per frame so the
/// cloud co-rotates with the planet, and TINTED FROM THE IMPACT SITE: the
/// body's baked albedo map is point-sampled at the contact ([CpuAlbedo]),
/// falling back to the body's procedural regolith/sand mix where no bake
/// exists — Moon dust comes up grey, Mars dust rust, an ocean strike a
/// blue-white spray.
///
/// Rendering rides the engine's CPU particle system exactly like
/// [ExhaustNodes]: particles simulate in the impact-site local frame (+Y =
/// surface normal), so the whole effect is floating-origin-safe by
/// construction.
class ImpactFxNodes {
  // Sprite build kicks off at construction (not first update) so it is
  // near-certainly ready before the first crash can happen.
  ImpactFxNodes(this._scene) {
    _ensureSprite();
  }

  final fs.Scene _scene;

  /// Soft radial sprite shared by dust and debris (same build as the exhaust
  /// glow; the per-system color does the differentiating).
  static Object? _sprite;
  static bool _spriteBuilding = false;

  static void _ensureSprite() {
    if (_sprite != null || _spriteBuilding) return;
    _spriteBuilding = true;
    const s = 64;
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.drawRect(
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
    rec
        .endRecording()
        .toImage(s, s)
        .then((img) => fs.gpuTextureFromImage(img))
        .then((tex) {
      _sprite = tex as Object;
    }).catchError((Object _) {
      _spriteBuilding = false; // retry on a later frame
    });
  }

  final List<_ImpactFx> _live = [];
  // Impacts already spawned, keyed vessel:tick — SceneSync can be driven more
  // than once with the same snapshot (paint vs tick cadence), and one crash
  // must not stack N clouds.
  final Set<String> _spawned = {};
  // Impacts that arrived while the sprite texture was still building. The
  // event is TRANSIENT (one snapshot only) but the anchor is body-fixed, so
  // holding the flattened event and spawning a few frames late is exact —
  // dropping it would silently eat the FIRST crash after app start.
  final List<(EventSnapshot, double)> _pendingSprite = [];
  double _lastEpoch = double.nan;

  void update(WorldSnapshot snap, FloatingOrigin origin) {
    _ensureSprite();
    noteDescriptors(snap);
    final frozen = snap.epoch == _lastEpoch;
    _lastEpoch = snap.epoch;

    if (_sprite != null && _pendingSprite.isNotEmpty) {
      for (final (e, epoch) in _pendingSprite) {
        _live.add(_spawn(e, snap, startEpoch: epoch));
      }
      _pendingSprite.clear();
    }

    for (final e in snap.events) {
      if (e.kind != 'Impact') continue;
      final body = snap.bodies[e.target];
      if (body == null) continue;
      // No contact point resolved (older publisher) — nowhere to stand the FX.
      if (e.px == 0 && e.py == 0 && e.pz == 0) continue;
      final key = '${e.subject}:${snap.tick}';
      if (!_spawned.add(key)) continue;
      if (_spawned.length > 256) _spawned.clear(); // bounded scratch memory
      if (_sprite == null) {
        if (_pendingSprite.length < 8) _pendingSprite.add((e, snap.epoch));
        continue;
      }
      _live.add(_spawn(e, snap));
    }

    _live.removeWhere((fx) {
      final body = snap.bodies[fx.bodyId];
      // Body gone from the feed (focus switched star systems) or effect aged
      // out on the SIM clock — warp skips ahead, the dust is long settled.
      if (body == null || (snap.epoch - fx.startEpoch) > fx.ttlS) {
        _scene.remove(fx.node);
        return true;
      }
      final q = Quaternion(body.qw, body.qx, body.qy, body.qz);
      final world = Vector3(body.px, body.py, body.pz) + q.rotate(fx.contactBF);
      fx.node.localTransform = vm.Matrix4.compose(
        origin.worldToScene(world),
        quatToScene(q * fx.alignBF),
        vm.Vector3.all(1.0),
      );
      for (final em in fx.emitters) {
        em.paused = frozen;
      }
      return false;
    });
  }

  _ImpactFx _spawn(EventSnapshot e, WorldSnapshot snap, {double? startEpoch}) {
    final contactBF = Vector3(e.px, e.py, e.pz);
    final normalBF = contactBF.normalized;
    final (r, g, b) = _groundColor(e.target, normalBF);

    // Effective disturbance radius R (m): the crater rim radius when the
    // event sized one, else a modest speed-based stand-in (water strikes,
    // sub-crater taps). EVERY length below derives from R, tuned so the
    // finished cloud reads about DOUBLE the crater's size: spawn shell R,
    // sprite growth to ~2R across, drift ~0.5R — together ~4R across vs the
    // crater's 2R. Clamped: below ~1.5 m nothing is legible, above ~500 m a
    // few dozen billboards cannot fill the volume anyway.
    final speedT = ((e.magnitude - 40.0) / 560.0).clamp(0.1, 1.0);
    final R = (e.size > 0 ? e.size : 2.0 + 8.0 * speedT).clamp(1.5, 500.0);
    // Cosmetic surface gravity from the body's size (the snapshot carries no
    // mu): Earth-radius → ~9.8, Moon-radius → ~2.7. Close enough for arcs.
    final radius = snap.bodies[e.target]?.radius ?? 6.371e6;
    final gMs2 = (9.81 * radius / 6.371e6).clamp(1.0, 15.0);

    // DEBRIS: a hard, fast fan of dark chunks kicked up the surface normal,
    // pulled back down by local gravity. Alpha-blended — rocks, not sparks.
    // Launch speed sized so the arcs top out around 3R and land inside the
    // cloud's footprint; lifetime covers the ballistic flight and no more.
    final debrisV = math.sqrt(6.0 * gMs2 * R).clamp(8.0, 90.0);
    final flightS = (2.2 * debrisV / gMs2).clamp(1.0, 4.5);
    final debris = ParticleSystem(
      maxParticles: 160,
      shape: ConeShape(angle: 0.55, radius: lengthToScene(R * 0.35)),
      spawner: Spawner(rate: 0, bursts: [
        ParticleBurst(time: 0, count: (24 + R * 5).clamp(24, 120).round()),
      ]),
      looping: false,
      duration: 1.0,
      lifetime: UniformFloat(flightS * 0.6, flightS),
      startSpeed:
          UniformFloat(lengthToScene(debrisV * 0.4), lengthToScene(debrisV)),
      startSize: UniformFloat(lengthToScene((R * 0.06).clamp(0.25, 4.0)),
          lengthToScene((R * 0.16).clamp(0.7, 10.0))),
      startColor: ConstantColor(vm.Vector4(r * 0.55, g * 0.55, b * 0.55, 1.0)),
      gravity: vm.Vector3(0, -lengthToScene(gMs2), 0),
      modules: [
        ColorOverLifeModule(GradientColor(ColorGradient([
          ColorStop(0.0, vm.Vector4(r * 0.6, g * 0.6, b * 0.6, 1.0)),
          ColorStop(0.8, vm.Vector4(r * 0.5, g * 0.5, b * 0.5, 0.9)),
          ColorStop(1.0, vm.Vector4(r * 0.45, g * 0.45, b * 0.45, 0.0)),
        ]))),
      ],
      seed: e.subject.hashCode,
    );

    // DUST: a slow hemispherical billow that hangs, swells, and thins out.
    // Premultiplied alpha so the cloud occludes the ground it came from.
    // Bigger holes breathe longer.
    final dustTtl = (5.0 + R * 0.35).clamp(6.0, 18.0);
    final dust = ParticleSystem(
      maxParticles: 224,
      shape: SphereShape(radius: lengthToScene(R), hemisphere: true),
      spawner: Spawner(rate: 0, bursts: [
        ParticleBurst(time: 0, count: (18 + R * 4).clamp(24, 120).round()),
        // A softer second breath as the first wave clears the crater lip.
        ParticleBurst(time: 0.25, count: (9 + R * 2).clamp(12, 60).round()),
      ]),
      looping: false,
      duration: 1.0,
      // Narrow spread biased long: an early die-off thins the cloud to a
      // whisper halfway through its nominal hang time.
      lifetime: UniformFloat(dustTtl * 0.65, dustTtl),
      startSpeed:
          UniformFloat(lengthToScene(R * 0.35), lengthToScene(R * 0.8)),
      startSize:
          UniformFloat(lengthToScene(R * 0.35), lengthToScene(R * 0.6)),
      // Dust reads lighter than the ground it rose from.
      startColor: ConstantColor(vm.Vector4(
          (r * 1.15).clamp(0.0, 1.0),
          (g * 1.15).clamp(0.0, 1.0),
          (b * 1.15).clamp(0.0, 1.0),
          1.0)),
      // A whisper of settle, not ballistics — fine dust falls slow.
      gravity: vm.Vector3(0, -lengthToScene(gMs2 * 0.04), 0),
      modules: [
        LinearDragModule(1.4),
        // Growth to ~3.5x: a startSize around R*0.5 swells to ~1.8R across,
        // the last piece of the ~2x-crater cloud footprint.
        SizeOverLifeModule(CurveFloat(ParticleCurve.linear(from: 1.0, to: 3.5))),
        // Alpha HOLDS through most of the life and collapses near the end —
        // an early linear fade read as the whole cloud vanishing within a
        // couple of seconds while its particles were still alive.
        ColorOverLifeModule(GradientColor(ColorGradient([
          ColorStop(
              0.0,
              vm.Vector4((r * 1.2).clamp(0.0, 1.0), (g * 1.2).clamp(0.0, 1.0),
                  (b * 1.2).clamp(0.0, 1.0), 0.65)),
          ColorStop(0.6, vm.Vector4(r, g, b, 0.5)),
          ColorStop(1.0, vm.Vector4(r * 0.9, g * 0.9, b * 0.9, 0.0)),
        ]))),
      ],
      seed: e.subject.hashCode ^ 0x5f5f,
    );

    final debrisEmitter = ParticleEmitterComponent(
      system: debris,
      material: fs.SpriteMaterial()
        ..colorTexture = _sprite
        ..blendMode = fs.SpriteBlendMode.alpha,
    );
    final dustEmitter = ParticleEmitterComponent(
      system: dust,
      material: fs.SpriteMaterial()
        ..colorTexture = _sprite
        ..blendMode = fs.SpriteBlendMode.alpha,
    );

    final node = fs.Node()
      ..add(fs.Node()..addComponent(debrisEmitter))
      ..add(fs.Node()..addComponent(dustEmitter));
    _scene.add(node);
    return _ImpactFx(
      node: node,
      emitters: [debrisEmitter, dustEmitter],
      bodyId: e.target,
      contactBF: contactBF,
      alignBF: _yOnto(normalBF),
      startEpoch: startEpoch ?? snap.epoch,
      ttlS: dustTtl + 1.0,
    );
  }

  /// Ground colour at the impact site, 0..1 rgb: the baked albedo map sampled
  /// at the body-fixed contact, else the body's procedural regolith/sand mix.
  (double, double, double) _groundColor(String bodyId, Vector3 dirBF) {
    final cpu = TerrainTextures.albedoCpu[bodyId];
    if (cpu != null) {
      final s = cpu.sample(dirBF.x, dirBF.y, dirBF.z);
      return (s.r, s.g, s.b);
    }
    // No bake: neutral regolith pulled toward desert tan by the body's own
    // sand fraction (the same knob the terrain shader blends materials with).
    final sand =
        (_descriptorSand[bodyId] ?? 0.0).clamp(0.0, 1.0);
    double mix(double a, double b) => a + (b - a) * sand;
    return (mix(0.45, 0.72), mix(0.42, 0.62), mix(0.40, 0.46));
  }

  /// Sand fractions remembered from descriptor frames (descriptors ride along
  /// every flutter_scene frame, so this is just a null-safe convenience).
  final Map<String, double> _descriptorSand = {};

  /// Note descriptor-derived fallbacks for [_groundColor]. Called by update()
  /// implicitly via spawn-time lookups when descriptors are present.
  void noteDescriptors(WorldSnapshot snap) {
    for (final d in snap.descriptors.values) {
      _descriptorSand[d.id] = d.terrainSandAmount;
    }
  }

  /// Rotation taking local +Y onto [to] (unit). Degenerate cases (parallel /
  /// anti-parallel) handled explicitly.
  static Quaternion _yOnto(Vector3 to) {
    const from = Vector3(0, 1, 0);
    final d = from.dot(to).clamp(-1.0, 1.0);
    if (d > 0.9999) return Quaternion.identity;
    if (d < -0.9999) return Quaternion.axisAngle(const Vector3(1, 0, 0), math.pi);
    final axis = from.cross(to).normalized;
    return Quaternion.axisAngle(axis, math.acos(d));
  }
}

class _ImpactFx {
  _ImpactFx({
    required this.node,
    required this.emitters,
    required this.bodyId,
    required this.contactBF,
    required this.alignBF,
    required this.startEpoch,
    required this.ttlS,
  });

  final fs.Node node;
  final List<ParticleEmitterComponent> emitters;
  final String bodyId;

  /// Contact point in the body-fixed frame, metres — re-rotated through the
  /// body's live orientation every frame so the FX rides the spinning planet.
  final Vector3 contactBF;

  /// Local +Y → surface normal, in the body-fixed frame.
  final Quaternion alignBF;

  final double startEpoch;
  final double ttlS;
}
