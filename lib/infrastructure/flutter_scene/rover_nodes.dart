// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// ignore_for_file: implementation_imports

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;
// The particle module is not yet exported from scene.dart — same precedent
// as exhaust_nodes.dart and impact_fx_nodes.dart.
import 'package:flutter_scene/src/components/particle_emitter_component.dart';
import 'package:flutter_scene/src/particles/distribution.dart';
import 'package:flutter_scene/src/particles/emitter_shape.dart';
import 'package:flutter_scene/src/particles/particle_module.dart';
import 'package:flutter_scene/src/particles/particle_storage.dart';
import 'package:flutter_scene/src/particles/particle_system.dart';
import 'package:flutter_scene/src/particles/spawner.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../../adapters/presenters/rover_buggy.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';
import 'terrain/terrain_textures.dart';

/// The dune buggy, for the chase camera: a tube-frame body on four sprung
/// wheels, and a dust plume off each wheel.
///
/// **Programmer art, deliberately** — the same bargain as [WalkerNodes]:
/// there is no vehicle mesh in the repo, so the buggy is engine primitives
/// (a floor pan, a nose, two seats, an engine block, a roll cage of thin
/// cylinders, four treaded wheels on A-arms with coil-over shocks). It exists
/// so the suspension can be SEEN working — the arms swing, the shocks
/// shorten, the body squats and leans — and so the chase camera frames a
/// vehicle rather than a patch of ground. Swap the class for a model when
/// one exists; nothing outside it knows the shape.
///
/// **Frames.** The chassis is authored in METRES in the frame the physics
/// uses: x right, y forward, z up, origin on the suspension mount plane. The
/// studio hands over the mount-plane origin (focus-relative) and the three
/// chassis axes in world space (heading, then pitch and roll applied), so
/// the node transform is a pure rotation + translation + the render scale.
///
/// **Dust stays where it was thrown.** The engine simulates particles in
/// the EMITTER node's local space, so an emitter parented to a wheel would
/// drag its cloud along behind the buggy. Instead the four plumes hang off
/// one node at the scene origin (identity transform — focus-relative scene
/// units) and each plume's spawn point is moved to its wheel's contact patch
/// every frame through a custom [EmitterShape]. The studio's render origin
/// does not move while driving, so this is floating-origin-exact.
class RoverNodes {
  RoverNodes(this.scene, {this.spec = const RoverSpec()}) {
    _ensureSprite();
  }

  final fs.Scene scene;
  final RoverSpec spec;

  fs.Node? _root;
  final List<fs.Node> _wheels = [];
  final List<fs.Node> _arms = [];
  final List<fs.Node> _shocks = [];
  fs.Node? _dustRoot;
  final List<_Plume> _plumes = [];
  (double, double, double)? _tint;

  /// One unit cylinder (radius 1, height 1 along Y) that every bar — cage
  /// tube, A-arm, shock — is a scaled, rotated instance of.
  static fs.Geometry? _unitBar;

  /// Soft radial sprite shared by the four plumes (the exhaust / impact
  /// build; the tint does the differentiating).
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

  /// Ground colour to tint the dust with, 0..1 rgb: the body's baked albedo
  /// sampled under the buggy, else the procedural regolith/sand mix (the
  /// same fallback the impact FX use).
  static (double, double, double) groundTint({
    required String bodyId,
    required Vector3 dirBF,
    required double sand,
  }) {
    final cpu = TerrainTextures.albedoCpu[bodyId];
    if (cpu != null) {
      final s = cpu.sample(dirBF.x, dirBF.y, dirBF.z);
      return (s.r, s.g, s.b);
    }
    final k = sand.clamp(0.0, 1.0);
    double mix(double a, double b) => a + (b - a) * k;
    return (mix(0.45, 0.72), mix(0.42, 0.62), mix(0.40, 0.46));
  }

  /// Take the buggy (and its dust) out of the scene. The nodes are kept for
  /// the next drive; the plumes are cleared so no stale cloud reappears.
  void hide() {
    final r = _root;
    if (r != null && r.parent != null) scene.remove(r);
    final d = _dustRoot;
    if (d != null && d.parent != null) scene.remove(d);
    for (final p in _plumes) {
      p.system.reset();
      p.system.spawner.rate = 0;
    }
  }

  /// Place the buggy for this frame.
  ///
  /// [originRel] is the mount-plane centre, focus-relative metres; [right],
  /// [forward], [up] the chassis axes in world space (unit, orthonormal).
  /// [timeS] is any monotonic clock (landing puffs are timed against it);
  /// [tint] the ground colour under the buggy; [gravity] the surface
  /// gravity, which settles the dust.
  void update({
    required RoverState state,
    required Vector3 originRel,
    required Vector3 right,
    required Vector3 forward,
    required Vector3 up,
    required double timeS,
    required (double, double, double) tint,
    required double gravity,
  }) {
    final root = _root ??= _build();
    if (root.parent == null) scene.add(root);

    // Chassis: the frame's columns are the chassis axes; the primitives are
    // in metres, the scene in render units.
    final m = vm.Matrix4.identity()
      ..setColumn(0, vm.Vector4(right.x, right.y, right.z, 0))
      ..setColumn(1, vm.Vector4(forward.x, forward.y, forward.z, 0))
      ..setColumn(2, vm.Vector4(up.x, up.y, up.z, 0));
    final o = relToScene(originRel);
    m.setColumn(3, vm.Vector4(o.x, o.y, o.z, 1));
    final k = lengthToScene(1);
    root.localTransform = m * vm.Matrix4.diagonal3Values(k, k, k);

    // Wheels: hang from the mount by the uncompressed travel, steer at the
    // front, and spin about their axle. Arms and shocks follow the hub.
    for (var i = 0; i < RoverSpec.wheelCount; i++) {
      final (x, y, z) = state.wheelCentre(i, spec);
      final steer = i < 2 ? state.steer : 0.0;
      _wheels[i].localTransform = vm.Matrix4.translationValues(x, y, z) *
          vm.Matrix4.rotationZ(-steer) *
          vm.Matrix4.rotationX(-state.wheelSpin[i]);
      final side = x.sign;
      _arms[i].localTransform = _bar(
        vm.Vector3(side * 0.30, y, -0.02),
        vm.Vector3(side * 0.82, y, z),
        0.035,
      );
      _shocks[i].localTransform = _bar(
        vm.Vector3(side * 0.42, y * 0.96, 0.58),
        vm.Vector3(side * 0.80, y, z + 0.06),
        0.055,
      );
    }

    _syncDust(state, originRel, right, forward, up, timeS, tint, gravity);
  }

  void _syncDust(
    RoverState state,
    Vector3 originRel,
    Vector3 right,
    Vector3 forward,
    Vector3 up,
    double timeS,
    (double, double, double) tint,
    double gravity,
  ) {
    _ensureSprite();
    if (_sprite == null) return; // texture still building: dust waits
    final dust = _dustRoot ??= fs.Node();
    if (_plumes.isEmpty) {
      for (var i = 0; i < RoverSpec.wheelCount; i++) {
        final p = _Plume(i, tint);
        _plumes.add(p);
        dust.add(p.node);
      }
      _tint = tint;
    }
    if (dust.parent == null) scene.add(dust);

    // Re-tint when the ground under the buggy changes colour (sand to
    // rock): a new start colour, no rebuild.
    final t0 = _tint;
    if (t0 == null ||
        (t0.$1 - tint.$1).abs() + (t0.$2 - tint.$2).abs() +
                (t0.$3 - tint.$3).abs() >
            0.06) {
      for (final p in _plumes) {
        p.system.startColor = _Plume.colourFor(tint);
      }
      _tint = tint;
    }

    final gS = lengthToScene(gravity * 0.06);
    final back = forward * (state.speed >= 0 ? -1.0 : 1.0);
    final axis = (up * 0.8 + back * 0.6).normalized;
    for (var i = 0; i < RoverSpec.wheelCount; i++) {
      final p = _plumes[i];
      final (x, y, z) = state.wheelCentre(i, spec);
      // The contact patch, a hand above the ground so the sprite's centre
      // is not half buried.
      final contact = originRel +
          right * x +
          forward * y +
          up * (z - spec.wheelRadiusM + 0.10);
      final c = relToScene(contact);
      p.cone.origin.setValues(c.x, c.y, c.z);
      p.cone.axis.setValues(axis.x, axis.y, axis.z);
      p.system.gravity.setValues(-up.x * gS, -up.y * gS, -up.z * gS);

      final d = state.dust[i];
      if (state.landing[i] > 0) p.puffUntil = timeS + 0.25;
      var rate = d * 110.0;
      if (timeS < p.puffUntil) rate += 320.0;
      p.system.spawner.rate = rate;
      // A slow roll kicks up small, lazy puffs; a skid or a launch throws
      // bigger, faster ones.
      if ((d - p.lastDust).abs() > 0.05) {
        p.system.startSpeed = UniformFloat(
            lengthToScene(0.6 + 2.5 * d), lengthToScene(1.2 + 4.0 * d));
        p.system.startSize = UniformFloat(
            lengthToScene(0.18 + 0.3 * d), lengthToScene(0.35 + 0.5 * d));
        p.lastDust = d;
      }
    }
  }

  // ---- Build ---------------------------------------------------------------

  static fs.Geometry get _bar1 =>
      _unitBar ??= fs.CylinderGeometry(bottomRadius: 1, topRadius: 1, height: 1);

  /// Transform placing the unit cylinder as a bar of [radius] from [a] to
  /// [b] (chassis metres).
  static vm.Matrix4 _bar(vm.Vector3 a, vm.Vector3 b, double radius) {
    final d = b - a;
    final len = d.length;
    if (len < 1e-6) return vm.Matrix4.translation(a);
    final y = d / len;
    final seed = y.z.abs() < 0.9 ? vm.Vector3(0, 0, 1) : vm.Vector3(1, 0, 0);
    final x = y.cross(seed)..normalize();
    final z = x.cross(y);
    final mid = (a + b) * 0.5;
    return vm.Matrix4.identity()
      ..setColumn(0, vm.Vector4(x.x * radius, x.y * radius, x.z * radius, 0))
      ..setColumn(1, vm.Vector4(y.x * len, y.y * len, y.z * len, 0))
      ..setColumn(2, vm.Vector4(z.x * radius, z.y * radius, z.z * radius, 0))
      ..setColumn(3, vm.Vector4(mid.x, mid.y, mid.z, 1));
  }

  fs.Node _build() {
    final root = fs.Node();

    final body = fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.92, 0.42, 0.08, 1.0)
      ..roughnessFactor = 0.5
      ..metallicFactor = 0.1;
    final steel = fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.55, 0.57, 0.60, 1.0)
      ..roughnessFactor = 0.35
      ..metallicFactor = 0.85;
    final dark = fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.15, 0.15, 0.17, 1.0)
      ..roughnessFactor = 0.8
      ..metallicFactor = 0.05;
    final rubber = fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.07, 0.07, 0.08, 1.0)
      ..roughnessFactor = 0.95
      ..metallicFactor = 0.0;
    final shock = fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.95, 0.80, 0.10, 1.0)
      ..roughnessFactor = 0.4
      ..metallicFactor = 0.3;
    final lamp = fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.97, 0.97, 0.92, 1.0)
      ..roughnessFactor = 0.2
      ..metallicFactor = 0.0;
    final suit = fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.88, 0.88, 0.90, 1.0)
      ..roughnessFactor = 0.75
      ..metallicFactor = 0.05;

    fs.Node part(fs.Geometry g, fs.Material mat, vm.Vector3 at,
        {vm.Matrix4? rotation}) {
      final n = fs.Node(mesh: fs.Mesh(g, mat));
      n.localTransform =
          vm.Matrix4.translation(at) * (rotation ?? vm.Matrix4.identity());
      return n;
    }

    fs.Node bar(vm.Vector3 a, vm.Vector3 b, double r, fs.Material mat) {
      final n = fs.Node(mesh: fs.Mesh(_bar1, mat));
      n.localTransform = _bar(a, b, r);
      return n;
    }

    // Body: floor pan, nose, dash cowl, rear deck, engine.
    root.add(part(fs.CuboidGeometry(vm.Vector3(1.5, 2.5, 0.10)), dark,
        vm.Vector3(0, 0.05, 0.0)));
    root.add(part(fs.CuboidGeometry(vm.Vector3(1.15, 0.75, 0.32)), body,
        vm.Vector3(0, 1.15, 0.20)));
    root.add(part(fs.CuboidGeometry(vm.Vector3(1.2, 0.30, 0.45)), body,
        vm.Vector3(0, 0.55, 0.28)));
    root.add(part(fs.CuboidGeometry(vm.Vector3(1.3, 0.50, 0.08)), body,
        vm.Vector3(0, -1.15, 0.60)));
    root.add(part(fs.CuboidGeometry(vm.Vector3(0.85, 0.60, 0.50)), steel,
        vm.Vector3(0, -1.0, 0.32)));
    // Seats and a driver in the left one.
    for (final side in [-1.0, 1.0]) {
      root.add(part(fs.CuboidGeometry(vm.Vector3(0.48, 0.55, 0.42)), dark,
          vm.Vector3(0.36 * side, -0.15, 0.30)));
      root.add(part(fs.CuboidGeometry(vm.Vector3(0.48, 0.12, 0.70)), dark,
          vm.Vector3(0.36 * side, -0.47, 0.75)));
    }
    root.add(part(fs.CapsuleGeometry(radius: 0.17, height: 0.40), suit,
        vm.Vector3(-0.36, -0.22, 0.72),
        rotation: vm.Matrix4.rotationX(math.pi / 2)));
    root.add(part(fs.SphereGeometry(radius: 0.15), suit,
        vm.Vector3(-0.36, -0.20, 1.05)));
    root.add(part(
        fs.CylinderGeometry(bottomRadius: 0.17, topRadius: 0.17, height: 0.03),
        dark,
        vm.Vector3(-0.36, 0.28, 0.72),
        rotation: vm.Matrix4.rotationX(2.2)));
    // Headlights.
    for (final side in [-1.0, 1.0]) {
      root.add(part(fs.SphereGeometry(radius: 0.09), lamp,
          vm.Vector3(0.35 * side, 1.53, 0.42)));
    }
    // Roll cage and frame tubes.
    const r = 0.035;
    for (final s in [-1.0, 1.0]) {
      root.add(bar(vm.Vector3(0.62 * s, -0.60, 0.05),
          vm.Vector3(0.58 * s, -0.55, 1.60), r, steel));
      root.add(bar(vm.Vector3(0.62 * s, 0.65, 0.45),
          vm.Vector3(0.58 * s, -0.05, 1.60), r, steel));
      root.add(bar(vm.Vector3(0.58 * s, -0.55, 1.60),
          vm.Vector3(0.58 * s, -0.05, 1.60), r, steel));
      root.add(bar(vm.Vector3(0.58 * s, -0.55, 1.60),
          vm.Vector3(0.55 * s, -1.25, 0.65), r, steel));
      root.add(bar(vm.Vector3(0.76 * s, -1.25, 0.15),
          vm.Vector3(0.76 * s, 1.35, 0.15), r, steel));
      root.add(bar(vm.Vector3(0.70 * s, 1.50, 0.15),
          vm.Vector3(0.66 * s, 1.50, 0.55), r, steel));
    }
    root.add(bar(vm.Vector3(-0.58, -0.55, 1.60), vm.Vector3(0.58, -0.55, 1.60),
        r, steel));
    root.add(bar(vm.Vector3(-0.58, -0.05, 1.60), vm.Vector3(0.58, -0.05, 1.60),
        r, steel));
    root.add(bar(vm.Vector3(-0.70, 1.50, 0.15), vm.Vector3(0.70, 1.50, 0.15),
        r, steel));
    root.add(bar(vm.Vector3(-0.66, 1.50, 0.55), vm.Vector3(0.66, 1.50, 0.55),
        r, steel));

    // Wheels, arms, shocks: placed per frame.
    _wheels.clear();
    _arms.clear();
    _shocks.clear();
    for (var i = 0; i < RoverSpec.wheelCount; i++) {
      final w = _buildWheel(rubber, steel);
      final a = fs.Node(mesh: fs.Mesh(_bar1, steel));
      final s = fs.Node(mesh: fs.Mesh(_bar1, shock));
      _wheels.add(w);
      _arms.add(a);
      _shocks.add(s);
      root.add(w);
      root.add(a);
      root.add(s);
    }
    return root;
  }

  /// One wheel about the X axis: tyre, hub, and a ring of tread blocks so
  /// the spin reads.
  fs.Node _buildWheel(fs.Material rubber, fs.Material steel) {
    final rw = spec.wheelRadiusM;
    final wheel = fs.Node();
    final toX = vm.Matrix4.rotationZ(math.pi / 2);
    final tyre = fs.Node(
        mesh: fs.Mesh(
            fs.CylinderGeometry(bottomRadius: rw, topRadius: rw, height: 0.32),
            rubber));
    tyre.localTransform = toX;
    wheel.add(tyre);
    final hub = fs.Node(
        mesh: fs.Mesh(
            fs.CylinderGeometry(
                bottomRadius: 0.17, topRadius: 0.17, height: 0.34),
            steel));
    hub.localTransform = toX;
    wheel.add(hub);
    const blocks = 10;
    final block = fs.CuboidGeometry(vm.Vector3(0.34, 0.05, 0.11));
    for (var k = 0; k < blocks; k++) {
      final th = 2 * math.pi * k / blocks;
      final n = fs.Node(mesh: fs.Mesh(block, rubber));
      n.localTransform = vm.Matrix4.translationValues(
              0, math.cos(th) * (rw - 0.01), math.sin(th) * (rw - 0.01)) *
          vm.Matrix4.rotationX(th);
      wheel.add(n);
    }
    return wheel;
  }
}

/// One wheel's dust: a cone emitter whose spawn point follows the contact
/// patch while its particles stay in the scene frame.
class _Plume {
  _Plume(int wheel, (double, double, double) tint)
      : cone = _MovingCone(),
        system = ParticleSystem(
          maxParticles: 180,
          shape: _MovingCone(),
          spawner: Spawner(rate: 0),
          looping: true,
          lifetime: UniformFloat(0.9, 1.8),
          startSpeed: UniformFloat(lengthToScene(0.8), lengthToScene(1.5)),
          startSize: UniformFloat(lengthToScene(0.35), lengthToScene(0.7)),
          startColor: colourFor(tint),
          modules: [
            LinearDragModule(1.6),
            SizeOverLifeModule(
                CurveFloat(ParticleCurve.linear(from: 1.0, to: 3.2))),
            const _FadeModule(),
          ],
          seed: 0x2d5 + wheel,
        ) {
    // The system was handed a throwaway cone (the field initialiser order
    // does not let it take ours); swap in the one this plume moves.
    system.shape = cone;
    emitter = ParticleEmitterComponent(
      system: system,
      material: fs.SpriteMaterial()
        ..colorTexture = RoverNodes._sprite
        ..blendMode = fs.SpriteBlendMode.alpha,
    );
    node = fs.Node()..addComponent(emitter);
  }

  final _MovingCone cone;
  final ParticleSystem system;
  late final ParticleEmitterComponent emitter;
  late final fs.Node node;
  double puffUntil = -1;
  double lastDust = -1;

  /// Dust is the ground's own colour, a shade lighter, and thin — a haze
  /// behind the wheels, not smoke.
  static ColorDistribution colourFor((double, double, double) t) =>
      ConstantColor(vm.Vector4(
        (t.$1 * 1.05).clamp(0.0, 1.0),
        (t.$2 * 1.05).clamp(0.0, 1.0),
        (t.$3 * 1.05).clamp(0.0, 1.0),
        _FadeModule.peakAlpha,
      ));
}

/// A cone emitter with a MOVABLE origin and axis (the engine's [ConeShape]
/// is fixed at the node origin about +Y). Particles start on a disc of
/// [radius] about [origin], perpendicular to [axis], heading within [angle]
/// of it.
class _MovingCone extends EmitterShape {
  final vm.Vector3 origin = vm.Vector3.zero();
  final vm.Vector3 axis = vm.Vector3(0, 0, 1);
  double angle = 0.6;
  double radius = lengthToScene(0.25);

  // Salts disjoint from the engine shapes' 20..23.
  static const _saltA = 30, _saltB = 31, _saltC = 32, _saltD = 33;

  @override
  void sample(ParticleStorage storage, int index) {
    final a = axis.normalized();
    final seed = a.z.abs() < 0.9 ? vm.Vector3(0, 0, 1) : vm.Vector3(1, 0, 0);
    final u = a.cross(seed)..normalize();
    final v = u.cross(a);

    final rr = radius * math.sqrt(storage.randomFor(index, _saltA));
    final th = 2.0 * math.pi * storage.randomFor(index, _saltB);
    final px = origin.x + u.x * rr * math.cos(th) + v.x * rr * math.sin(th);
    final py = origin.y + u.y * rr * math.cos(th) + v.y * rr * math.sin(th);
    final pz = origin.z + u.z * rr * math.cos(th) + v.z * rr * math.sin(th);
    storage.posX[index] = px;
    storage.posY[index] = py;
    storage.posZ[index] = pz;

    final cosT =
        1.0 - storage.randomFor(index, _saltC) * (1.0 - math.cos(angle));
    final sinT = math.sqrt(math.max(0.0, 1.0 - cosT * cosT));
    final phi = 2.0 * math.pi * storage.randomFor(index, _saltD);
    final cu = sinT * math.cos(phi), cv = sinT * math.sin(phi);
    storage.velX[index] = a.x * cosT + u.x * cu + v.x * cv;
    storage.velY[index] = a.y * cosT + u.y * cu + v.y * cv;
    storage.velZ[index] = a.z * cosT + u.z * cu + v.z * cv;
  }
}

/// Alpha that holds early and collapses late — the start colour's own alpha
/// is the ceiling — so a cloud thins rather than blinks out.
class _FadeModule extends ParticleModule {
  const _FadeModule();

  static const double peakAlpha = 0.42;

  @override
  void update(ParticleStorage storage, double dt) {
    final n = storage.aliveCount;
    for (var i = 0; i < n; i++) {
      final t = (storage.age[i] / storage.lifetime[i]).clamp(0.0, 1.0);
      final k = 1.0 - t;
      storage.colorA[i] = peakAlpha * k * k * (3 - 2 * k);
    }
  }
}
