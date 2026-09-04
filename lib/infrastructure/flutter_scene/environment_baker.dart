// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/vector3.dart';
import 'graphics_quality.dart';
import 'scene_textures.dart';

/// Bakes the focus body into the scene's image-based-lighting environment so
/// the planet shows up in the craft's reflections (and contributes diffuse
/// bounce — earthshine on the night-facing hull).
///
/// flutter_scene's PBR samples one global [fs.EnvironmentMap]; the default is
/// a neutral "studio" that reads as a photo booth in space. This baker paints
/// a tiny equirectangular radiance image — black space, a sun glint, and the
/// focus body's lit disc (average albedo colour, phase-weighted) — and swaps
/// it in via [fs.EnvironmentMap.fromUIImages], which GPU-prefilters the
/// roughness bands and projects the diffuse spherical harmonics.
///
/// Rebakes are throttled: only when the focus body changes, or the
/// body-to-eye geometry moves materially (direction, apparent size, phase),
/// and never more than once every few seconds — a bake costs an upload +
/// prefilter chain, and each one allocates a fresh radiance atlas (the old
/// one is reclaimed by the GPU texture finalizer).
///
/// The equirect convention matches flutter_scene's sampler
/// (`EquirectangularToSpherical` in texture.glsl): u encodes
/// `atan2(dir.z, dir.x)`, v encodes `asin(dir.y)` with +y at the image
/// bottom. Directions are scene-frame (= domain frame, Z-up); no remap, the
/// formula is just applied verbatim.
class PlanetEnvironmentBaker {
  PlanetEnvironmentBaker(this._scene, this._textures);

  final fs.Scene _scene;
  final SceneTextures _textures;

  /// Kill switch (dev panel / ext.acro.camera?planetEnv=). Turning it off
  /// restores the neutral studio environment at the original intensity.
  static bool enabled = true;

  /// Dev hook: receives every baked radiance image (main_scene_dev wires it
  /// to a PNG dump so the equirect can be eyeballed). Null in production.
  static void Function(ui.Image img)? debugDump;

  /// Dev diagnostic: 'white' bakes a solid-white radiance map instead of
  /// the planet composite — an absurd-value probe that separates "the IBL
  /// pipeline is broken" from "the planet disc is just dim".
  static String testPattern = '';

  /// On-screen debug view of the reflection capture: the latest baked
  /// equirect, published for an overlay painter. Toggle the overlay with
  /// `ext.acro.camera?envDebug=true` (drives [showDebug]); the image
  /// updates on every rebake.
  static final ValueNotifier<ui.Image?> latestBake =
      ValueNotifier<ui.Image?>(null);
  static bool showDebug = false;

  /// IBL intensity while a baked environment is active. The studio default
  /// runs at 0.05 to keep space from looking like a photo booth; the baked
  /// map is black everywhere except the sun + planet, so full strength is
  /// what makes the hull actually mirror the planet. 1.5 leans slightly
  /// hot because the canvas radiance is LDR-clamped at 1.0 while the
  /// analytic sun runs at 2.2 — verified against a solid-white probe
  /// (envTest=white) that the pipeline itself is sound.
  static double bakedIntensity = 1.5;

  /// Equirect size of the capture CURRENTLY being laid out.
  ///
  /// Snapped once at the top of [_bake] rather than read live from the preset:
  /// the layout maths (`_uv`, `_wrapped`, the disc radii) and the final
  /// `toImage` all consult these, and a slider moved mid-bake would otherwise
  /// lay the picture out at one size and rasterise it at another — a stretched
  /// reflection until something happened to trigger the next bake.
  int _bakeW = LightingQuality.high.envBakeWidth;
  int _bakeH = LightingQuality.high.envBakeHeight;
  int get _w => _bakeW;
  int get _h => _bakeH;

  /// Re-bake floor. Safe to read live — it only gates the throttle.
  static Duration get _minInterval => GraphicsQuality.lighting.envBakeInterval;

  String? _bakedBody;
  Vector3 _bakedDir = Vector3.zero;
  double _bakedAngular = 0;
  double _bakedPhase = -9;
  DateTime _lastBake = DateTime.fromMillisecondsSinceEpoch(0);
  bool _baking = false;
  bool _applied = false;
  double _appliedIntensity = -1;
  String _appliedPattern = '';

  /// The preset the resident capture was baked at, so moving the quality
  /// slider re-bakes at once instead of leaving the old resolution on screen
  /// for up to a whole throttle interval.
  QualityLevel? _appliedLighting;
  bool _bakedHadTexture = false;

  // Average albedo colour per texture key, computed once by downscaling the
  // planet map to a single pixel. Grey until the image decodes.
  final Map<String, ui.Color> _avgColor = {};
  final Set<String> _avgPending = {};

  void update(
    WorldSnapshot snap, {
    required Vector3 eyeWorld,
    String? focusBodyId,
    String? focusVesselId,
    Vector3? starWorld,
  }) {
    if (!enabled) {
      if (_applied) {
        _scene.environment = fs.EnvironmentMap.studio();
        _scene.environmentIntensity = 0.05;
        _applied = false;
        _bakedBody = null;
      }
      return;
    }
    final bodyId = focusBodyId ?? (focusVesselId == null ? null : snap.vessels[focusVesselId]?.body);
    final b = bodyId == null ? null : snap.bodies[bodyId];
    if (b == null || _baking) return;

    // Reflection origin = the CRAFT, not the camera. The reflection lives on
    // the hull; the body's apparent direction and size must be computed from
    // where the craft is, or orbiting the CAMERA around a stationary craft
    // would wrongly swing the reflected body across the hull. Critically,
    // the body is near and huge (a 100 km lunar orbit puts the moon at ~71
    // deg angular RADIUS — 142 deg of sky), so eye-vs-craft parallax is
    // enormous; only the craft origin tracks the orbit correctly. The sun
    // is at infinity, so its glint is unaffected by this choice. Falls back
    // to the eye when there's no focused vessel (e.g. a body-locked camera).
    var reflectorWorld = eyeWorld;
    final fv = focusVesselId == null ? null : snap.vessels[focusVesselId];
    if (fv != null) {
      final vb = snap.bodies[fv.body];
      if (vb != null) {
        reflectorWorld =
            Vector3(vb.px + fv.px, vb.py + fv.py, vb.pz + fv.pz);
      }
    }

    final bodyWorld = Vector3(b.px, b.py, b.pz);
    final toBody = bodyWorld - reflectorWorld;
    final dist = toBody.length;
    if (dist <= b.radius) return; // inside the body: degenerate
    final dir = toBody / dist;
    final angular = math.asin((b.radius / dist).clamp(0.0, 1.0));
    final sunDir = starWorld == null ? null : (starWorld - bodyWorld).normalized;
    // Phase: how much of the visible face is lit (1 full, 0 new).
    final phase = sunDir == null ? 1.0 : 0.5 - 0.5 * sunDir.dot(dir);

    final key0 = snap.descriptors[b.id]?.albedoKey ?? '';
    final texKey = key0.isNotEmpty ? key0 : b.id;
    final albedo = _textures.image(texKey); // kicks the decode on first miss

    final now = DateTime.now();
    final since = now.difference(_lastBake);
    final knobTurned =
        !_applied ||
        bakedIntensity != _appliedIntensity ||
        testPattern != _appliedPattern ||
        GraphicsQuality.lightingLevel != _appliedLighting ||
        (albedo != null) != _bakedHadTexture;
    final moved =
        knobTurned ||
        _bakedBody != bodyId ||
        _bakedDir.dot(dir) < math.cos(0.05) || // ~3 degrees
        (angular - _bakedAngular).abs() > 0.10 * math.max(_bakedAngular, 0.01) ||
        (phase - _bakedPhase).abs() > 0.08;
    if (!moved) return;
    // Geometry drift is throttled; a knob change (re-enable, intensity
    // tuning, the body map finishing its decode) applies immediately so
    // live A/B comparisons work.
    if (!knobTurned && since < _minInterval) return;

    final tint = _averageAlbedo(b.id, snap);
    _baking = true;
    _bakedHadTexture = albedo != null;
    _bake(
          bodyId: bodyId!,
          dir: dir,
          angular: angular,
          phase: phase,
          tint: tint,
          albedo: albedo,
          sunFromEye: starWorld == null ? null : (starWorld - reflectorWorld).normalized,
        )
        .then((_) {
          // ignore: avoid_print
          print(
            'planetEnv: baked $bodyId ang=${(angular * 180 / math.pi).toStringAsFixed(1)}deg '
            'phase=${phase.toStringAsFixed(2)} intensity=$bakedIntensity',
          );
        })
        .catchError((Object e, StackTrace st) {
          // ignore: avoid_print
          print('planetEnv: bake FAILED: $e\n$st');
        })
        .whenComplete(() => _baking = false);
  }

  /// Kick (or read) the 1-px downscale of the body's albedo map.
  ui.Color _averageAlbedo(String bodyId, WorldSnapshot snap) {
    final key0 = snap.descriptors[bodyId]?.albedoKey ?? '';
    final key = key0.isNotEmpty ? key0 : bodyId;
    final hit = _avgColor[key];
    if (hit != null) return hit;
    final img = _textures.image(key); // starts the decode on first miss
    if (img != null && !_avgPending.contains(key)) {
      _avgPending.add(key);
      () async {
        final rec = ui.PictureRecorder();
        final canvas = ui.Canvas(rec);
        canvas.drawImageRect(
          img,
          ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          const ui.Rect.fromLTWH(0, 0, 1, 1),
          ui.Paint()..filterQuality = ui.FilterQuality.low,
        );
        final one = await rec.endRecording().toImage(1, 1);
        final data = await one.toByteData(format: ui.ImageByteFormat.rawRgba);
        one.dispose();
        if (data != null && data.lengthInBytes >= 4) {
          _avgColor[key] = ui.Color.fromARGB(255, data.getUint8(0), data.getUint8(1), data.getUint8(2));
        }
        _avgPending.remove(key);
      }();
    }
    return _avgColor[key] ?? const ui.Color(0xFF9A9A9A);
  }

  Future<void> _bake({
    required String bodyId,
    required Vector3 dir,
    required double angular,
    required double phase,
    required ui.Color tint,
    ui.Image? albedo,
    Vector3? sunFromEye,
  }) async {
    // One size for the whole capture — see [_bakeW].
    _bakeW = GraphicsQuality.lighting.envBakeWidth;
    _bakeH = GraphicsQuality.lighting.envBakeHeight;
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    final full = ui.Rect.fromLTWH(0, 0, _w.toDouble(), _h.toDouble());
    canvas.drawRect(
      full,
      ui.Paint()
        ..color = testPattern == 'white'
            ? const ui.Color(0xFFFFFFFF)
            : const ui.Color(0xFF000000),
    );
    // Starfield backdrop: the same equirect the skybox uses, dimmed to a
    // faint reflection (stars are dim; they must not compete with the body
    // or sun). Drawn as a direct equirect copy — infinitely-distant stars
    // are fixed in world directions, so a static fill sampled by the
    // reflection vector is correct as the craft moves. NOTE: this maps 1:1
    // to flutter_scene's equirect convention (u=atan2 z,x, v=asin y); the
    // visible skybox sphere uses a different (Z-up) UV layout, so reflected
    // stars won't line up 1:1 with the background sky yet.
    if (testPattern != 'white') {
      final stars = _textures.image('starfield');
      if (stars != null) {
        canvas.drawImageRect(
          stars,
          ui.Rect.fromLTWH(
              0, 0, stars.width.toDouble(), stars.height.toDouble()),
          full,
          ui.Paint()
            ..filterQuality = ui.FilterQuality.low
            ..colorFilter = const ui.ColorFilter.matrix([
              0.35, 0, 0, 0, 0, //
              0, 0.35, 0, 0, 0, //
              0, 0, 0.35, 0, 0, //
              0, 0, 0, 1, 0,
            ]),
        );
      }
    }

    // Sun: a small hot disc with a glow skirt, so smooth hulls carry a glint.
    // Occluded when the BODY eclipses it as seen from the craft: the body is
    // near and huge (71 deg radius in low lunar orbit) and the sun is at
    // infinity, so whenever the sun direction falls inside the body's disc
    // the craft is in the body's shadow and no glint should reach the hull.
    // Fade over the last ~3 deg to the limb so it doesn't pop.
    if (sunFromEye != null) {
      final sunAng = math.acos(sunFromEye.dot(dir).clamp(-1.0, 1.0));
      final vis = ((sunAng - angular) / 0.05).clamp(0.0, 1.0);
      if (vis > 0.0) {
        int s(int c) => (c * vis).round().clamp(0, 255);
        final uv = _uv(sunFromEye);
        _wrapped(uv.dx, (x) {
          canvas.drawCircle(
            ui.Offset(x, uv.dy),
            6,
            ui.Paint()
              ..shader = ui.Gradient.radial(
                ui.Offset(x, uv.dy),
                6,
                [
                  ui.Color.fromARGB(255, s(255), s(255), s(255)),
                  ui.Color.fromARGB(255, s(255), s(242), s(204)),
                  const ui.Color(0x00FFF2CC),
                ],
                const [0.0, 0.35, 1.0],
              ),
          );
        });
      }
    }

    // Planet disc at its real angular size, phase-dimmed. Equirect
    // stretches horizontally by 1/cos(latitude); the vertical radius maps
    // angular size directly (v spans pi).
    final uv = _uv(dir);
    final lat = math.asin(dir.y.clamp(-1.0, 1.0));
    final rV = (angular / math.pi) * _h;
    final rH = math.min(_w.toDouble(), rV / math.max(0.15, math.cos(lat)));
    final lit = 0.15 + 0.85 * phase; // never fully black: sky bounce reads odd
    ui.Color scale(ui.Color c, double f) => ui.Color.fromARGB(
      255,
      (c.r * 255.0 * f).round().clamp(0, 255),
      (c.g * 255.0 * f).round().clamp(0, 255),
      (c.b * 255.0 * f).round().clamp(0, 255),
    );
    // A flat average-albedo disc reads as an invisible grey wash in a
    // reflection (a full moon fills 90 degrees but averages ~0.35 sRGB on
    // a dark hull). Draw the body's actual map into the disc instead, and
    // gently normalise its brightness so a dark map (the moon's ~0.35
    // albedo) still reads without blowing the day side to pure white.
    // Target ~0.55 of full scale at full phase (was 0.95, which clipped
    // the sunlit moon to white through the metallic hull); the envIntensity
    // knob does the final loudness.
    final maxAlbedo = [tint.r, tint.g, tint.b].reduce(math.max).clamp(0.15, 1.0);
    final boost = (lit * 0.55 / maxAlbedo).clamp(0.0, 2.0);
    final centre = scale(tint, lit);
    final edge = scale(tint, lit * 0.55);
    _wrapped(uv.dx, (x) {
      final rect = ui.Rect.fromCenter(center: ui.Offset(x, uv.dy), width: rH * 2, height: rV * 2);
      if (albedo != null) {
        canvas.save();
        canvas.clipPath(ui.Path()..addOval(rect));
        canvas.drawImageRect(
          albedo,
          ui.Rect.fromLTWH(0, 0, albedo.width.toDouble(), albedo.height.toDouble()),
          rect,
          ui.Paint()
            ..filterQuality = ui.FilterQuality.low
            ..colorFilter = ui.ColorFilter.matrix([
              boost, 0, 0, 0, 0, //
              0, boost, 0, 0, 0, //
              0, 0, boost, 0, 0, //
              0, 0, 0, 1, 0,
            ]),
        );
        // Limb darkening so the disc edge doesn't cut off hard.
        canvas.drawOval(
          rect,
          ui.Paint()
            ..shader = ui.Gradient.radial(
              ui.Offset(x, uv.dy),
              math.max(rH, rV),
              const [ui.Color(0x00000000), ui.Color(0x00000000), ui.Color(0xB3000000)],
              const [0.0, 0.75, 1.0],
            ),
        );
        canvas.restore();
        return;
      }
      canvas.drawOval(
        rect,
        ui.Paint()..shader = ui.Gradient.radial(ui.Offset(x, uv.dy), math.max(rH, rV), [centre, edge]),
      );
    });

    final img = await rec.endRecording().toImage(_w, _h);
    debugDump?.call(img);
    latestBake.value = img; // feeds the on-screen debug overlay
    // Diffuse SH KILLED (except a flat DC ambient): fromUIImages otherwise
    // projects the map onto 9 diffuse spherical-harmonic coefficients, and a
    // large dim body disc dumps almost all its energy into the L1
    // (directional) terms — which light the body-FACING hull faces by their
    // NORMAL (Lambert), reading as a soft "backwards" glow (bright facing
    // the body, dark facing away) instead of a mirror image. The sun, a
    // tiny bright point, survives into the sharp SPECULAR band and reflects
    // correctly regardless. Forcing L1..L8 to zero leaves only the
    // reflection-vector specular path, so the body appears as an actual
    // reflection; the DC term keeps a little uniform ambient fill (no
    // direction, so no backwards glow) on night hulls.
    final env = await fs.EnvironmentMap.fromUIImages(
      radianceImage: img,
      diffuseSphericalHarmonics: [
        vm.Vector3.all(0.03),
        for (var i = 1; i < 9; i++) vm.Vector3.zero(),
      ],
    );
    _scene.environment = env;
    _scene.environmentIntensity = bakedIntensity;
    _applied = true;
    _appliedIntensity = bakedIntensity;
    _appliedPattern = testPattern;
    _appliedLighting = GraphicsQuality.lightingLevel;
    _bakedBody = bodyId;
    _bakedDir = dir;
    _bakedAngular = angular;
    _bakedPhase = phase;
    _lastBake = DateTime.now();
  }

  /// Direction (unit, scene frame) -> equirect pixel position, matching
  /// texture.glsl: u = 0.5 + atan2(d.z, d.x) / 2pi, v = 0.5 + asin(d.y) / pi.
  ui.Offset _uv(Vector3 d) {
    final u = 0.5 + math.atan2(d.z, d.x) / (2 * math.pi);
    final v = 0.5 + math.asin(d.y.clamp(-1.0, 1.0)) / math.pi;
    return ui.Offset(u * _w, v * _h);
  }

  /// Draw at x and its seam-wrapped copies so discs crossing u = 0/1 stay
  /// whole.
  void _wrapped(double x, void Function(double x) draw) {
    draw(x);
    draw(x - _w);
    draw(x + _w);
  }
}
