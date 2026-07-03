// ignore_for_file: implementation_imports

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;
// The particle module is not yet exported from scene.dart (upstream marks it
// for export once the authoring API settles) — implementation imports, same
// precedent as flutter_scene/src/gpu/gpu.dart.
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

/// Engine-exhaust plumes: one throttle-driven particle emitter per vessel,
/// streaming out of the tail (-Z in the body frame, nose is +Z).
///
/// Rendering rides the engine's own CPU particle system
/// ([ParticleEmitterComponent]): one instanced billboard batch per vessel,
/// additive soft-glow sprites, simulated in the emitter node's local space so
/// the plume moves and rotates with the craft (and is floating-origin-safe by
/// construction — particle coordinates never leave the vessel's frame).
///
/// The emitter node is kept SEPARATE from [VesselNodes]' per-vessel node (its
/// world transform is recomputed here the same way) so this layer can be
/// added/removed without touching the vessel sync.
class ExhaustNodes {
  ExhaustNodes(this._scene);

  final fs.Scene _scene;

  /// Peak emission at full throttle, particles/second.
  static double maxRate = 260;

  /// Nozzle position on the body Z axis when the part list names no engine.
  static double defaultNozzleZM = -2.75;

  final Map<String, _Plume> _plumes = {};
  double _lastEpoch = double.nan;

  /// Soft radial glow sprite, built once (additive: white core fading to
  /// transparent; the color-over-life gradient supplies the flame hues).
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

  void update(WorldSnapshot snap, FloatingOrigin origin) {
    _ensureSprite();
    // Sim time frozen (pause / warp-0): hold the simulation so the plume
    // doesn't keep streaming through a paused world.
    final frozen = snap.epoch == _lastEpoch;
    _lastEpoch = snap.epoch;

    final seen = <String>{};
    for (final v in snap.vessels.values) {
      final body = snap.bodies[v.body];
      if (body == null) continue;
      final throttle = v.throttle.clamp(0.0, 1.0);
      var plume = _plumes[v.id];
      // Spawn the emitter lazily on first burn (sprite must be ready first —
      // an untextured sprite draws as a hard-edged quad).
      if (plume == null) {
        if (throttle <= 0 || _sprite == null) continue;
        plume = _spawn(v);
        _plumes[v.id] = plume;
      }
      seen.add(v.id);

      plume.spawner.rate = throttle * maxRate;
      plume.emitter.paused = frozen;
      final world = Vector3(body.px + v.px, body.py + v.py, body.pz + v.pz);
      plume.node.localTransform = vm.Matrix4.compose(
        origin.worldToScene(world),
        quatToScene(Quaternion(v.qw, v.qx, v.qy, v.qz)),
        vm.Vector3.all(1.0),
      );
    }

    _plumes.removeWhere((id, plume) {
      // Vessels that vanished; idle plumes stay parked (zero rate, zero
      // live particles) so re-throttling doesn't rebuild the batch.
      if (seen.contains(id) || snap.vessels.containsKey(id)) return false;
      _scene.remove(plume.node);
      return true;
    });
  }

  _Plume _spawn(VesselSnapshot v) {
    // All lengths/speeds are metres converted to scene km. The plume is a
    // game-feel visual (tens of metres), not the physical exhaust jet.
    final system = ParticleSystem(
      maxParticles: 192,
      shape: ConeShape(angle: 0.14, radius: lengthToScene(0.6)),
      spawner: Spawner(rate: 0),
      lifetime: const UniformFloat(0.25, 0.5),
      startSpeed: UniformFloat(lengthToScene(45), lengthToScene(90)),
      startSize: UniformFloat(lengthToScene(1.4), lengthToScene(2.4)),
      modules: [
        SizeOverLifeModule(CurveFloat(ParticleCurve.linear(from: 1.0, to: 3.0))),
        ColorOverLifeModule(GradientColor(ColorGradient([
          ColorStop(0.0, vm.Vector4(1.0, 0.98, 0.9, 1.0)), // white-hot core
          ColorStop(0.25, vm.Vector4(1.0, 0.6, 0.25, 0.85)), // orange
          ColorStop(0.7, vm.Vector4(0.55, 0.2, 0.08, 0.4)), // ember
          ColorStop(1.0, vm.Vector4(0.1, 0.03, 0.01, 0.0)), // fade out
        ]))),
      ],
      seed: v.id.hashCode,
    );
    final emitter = ParticleEmitterComponent(
      system: system,
      material: fs.SpriteMaterial()
        ..colorTexture = _sprite
        ..blendMode = fs.SpriteBlendMode.additive,
    );

    // The engine's part offset locates the nozzle; fall back to a fixed tail
    // offset when the craft has no named engine (or the glb replaced parts).
    var nozzleZ = defaultNozzleZM;
    for (final p in v.parts) {
      if (p.type.toLowerCase().contains('engine')) {
        nozzleZ = math.min(p.oz, 0.0) - 1.25;
        break;
      }
    }
    // ConeShape emits about local +Y; rotate +Y onto body -Z (exhaust
    // streams out of the tail).
    final emitterNode = fs.Node()
      ..localTransform = vm.Matrix4.compose(
        vm.Vector3(0, 0, lengthToScene(nozzleZ)),
        vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), -math.pi / 2),
        vm.Vector3.all(1.0),
      )
      ..addComponent(emitter);
    final node = fs.Node()..add(emitterNode);
    _scene.add(node);
    return _Plume(node, emitter, system.spawner);
  }
}

class _Plume {
  _Plume(this.node, this.emitter, this.spawner);

  final fs.Node node;
  final ParticleEmitterComponent emitter;
  final Spawner spawner;
}
