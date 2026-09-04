// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_scene/scene.dart' show AntiAliasingMode;

import 'domain/shared/quaternion.dart';
import 'domain/shared/vector3.dart';
import 'infrastructure/baked_terrain_data.dart';
import 'infrastructure/flutter/sim_view_control.dart';
import 'infrastructure/flutter/windows_key_event_workaround.dart';
import 'infrastructure/sample_world.dart';
import 'infrastructure/flutter/simulation_view.dart';
import 'infrastructure/flutter_scene/atmosphere_nodes.dart';
import 'infrastructure/flutter_scene/cloud_nodes.dart';
import 'infrastructure/flutter_scene/body_nodes.dart';
import 'infrastructure/flutter_scene/environment_baker.dart';
import 'infrastructure/flutter_scene/gravity_grid_nodes.dart';
import 'infrastructure/flutter_scene/halo_ring_nodes.dart';
import 'infrastructure/flutter_scene/part_model_library.dart';
import 'infrastructure/flutter_scene/render_backend.dart';
import 'infrastructure/flutter_scene/scene_camera_adapter.dart';
import 'infrastructure/flutter_scene/scene_sync.dart';
import 'infrastructure/flutter_scene/star_bloom_nodes.dart';
import 'infrastructure/flutter_scene/terrain/terrain_nodes.dart';
import 'infrastructure/flutter_scene/terrain/terrain_textures.dart';
import 'infrastructure/flutter_scene/vessel_nodes.dart';

/// Dev entrypoint: boots STRAIGHT into [SimulationView] with the
/// flutter_scene backend active — no menu, no clicking. For iterating on the
/// 3D backend:
///
///   .fvm\flutter_sdk\bin\flutter.bat run -d windows --enable-impeller \
///       --enable-flutter-gpu -t lib/main_scene_dev.dart
///
/// Not wired into any release build; the shipping entrypoint stays main.dart.
///
/// `--dart-define=BACKEND=software` boots the software renderer instead —
/// used for side-by-side parity captures of the SAME scene.
final GlobalKey _shotKey = GlobalKey();

/// A `x,y,z` service-extension parameter as a vector, or null when it is absent
/// or malformed. Null means "leave this alone", so a typo can never quietly
/// zero a knob it failed to parse.
Vector3? _triple(String? raw) {
  if (raw == null) return null;
  final p = raw.split(',').map(double.tryParse).toList();
  if (p.length != 3 || p.contains(null)) return null;
  return Vector3(p[0]!, p[1]!, p[2]!);
}

/// Degrees about a part's own X, Y and Z axes as one orientation, applied X
/// first, then Y, then Z about the FIXED (unrotated) axes — so `90,0,0` and
/// `0,90,0` each name one of the axis-aligned quarter turns that a mis-authored
/// export needs, and the pair composes without the reader having to know an
/// intrinsic-rotation convention.
Quaternion _eulerDeg(Vector3 deg) {
  const k = math.pi / 180;
  return Quaternion.axisAngle(Vector3.unitZ, deg.z * k) *
      Quaternion.axisAngle(Vector3.unitY, deg.y * k) *
      Quaternion.axisAngle(Vector3.unitX, deg.x * k);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installWindowsAltKeyAssertFilter();
  // Jank watchdog: prints any frame over 100 ms with its build/raster split,
  // so a load-time hang is attributable from the console without DevTools.
  WidgetsBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      final total = t.totalSpan.inMilliseconds;
      if (total > 100) {
        debugPrint('JANK: frame ${total}ms '
            '(build ${t.buildDuration.inMilliseconds}ms, '
            'raster ${t.rasterDuration.inMilliseconds}ms)');
      }
    }
  });
  final swDem = Stopwatch()..start();
  await loadBakedTerrainData();
  debugPrint('boot: loadBakedTerrainData ${swDem.elapsedMilliseconds}ms');
  const backend =
      String.fromEnvironment('BACKEND', defaultValue: 'flutterScene');

  // Dump every baked IBL equirect for eyeballing (dev only).
  PlanetEnvironmentBaker.debugDump = (img) async {
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (data != null) {
      await File('test_out/scene_samples/env_bake_latest.png')
          .writeAsBytes(data.buffer.asUint8List());
    }
  };

  // Headless-friendly screenshot: `ext.acro.screenshot` captures the app's
  // RepaintBoundary and writes a PNG — reliable even when the OS window is
  // occluded or the desktop is locked (window-level capture goes white).
  // Invoke over the VM service:
  //   callServiceExtension?...&method=ext.acro.screenshot&path=<out.png>
  developer.registerExtension('ext.acro.screenshot', (method, params) async {
    try {
      final path = params['path'] ?? 'scene_shot.png';
      final boundary = _shotKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.extensionError,
            'no RepaintBoundary yet');
      }
      final ui.Image image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File(path).writeAsBytes(data!.buffer.asUint8List());
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'saved': path}));
    } catch (e) {
      return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError, '$e');
    }
  });

  // Programmatic camera/renderer control over the VM service, e.g.
  //   ext.acro.camera?azimuthDeg=90&elevationDeg=20&rangeM=2e7
  //   ext.acro.camera?backend=software        (or flutterScene)
  //   ext.acro.status                          -> current camera/backend
  // Drives the live view through SimViewControl exactly like user input.
  developer.registerExtension('ext.acro.camera', (method, params) async {
    final c = SimViewControl.instance;
    double? deg(String k) =>
        params[k] == null ? null : double.tryParse(params[k]!);
    final az = deg('azimuthDeg'), el = deg('elevationDeg'), ro = deg('rollDeg');
    if (az != null || el != null || ro != null) {
      c.orbit?.call(
        azimuth: az == null ? null : az * math.pi / 180,
        elevation: el == null ? null : el * math.pi / 180,
        roll: ro == null ? null : ro * math.pi / 180,
      );
    }
    final range = deg('rangeM'), mpp = deg('metresPerPixel');
    if (range != null || mpp != null) {
      c.zoom?.call(rangeM: range, metresPerPixel: mpp);
    }
    if (params['perspective'] != null) {
      c.setPerspective?.call(params['perspective'] == 'true');
    }
    if (params['backend'] != null) {
      c.setBackend?.call(params['backend'] == 'software'
          ? RenderBackend.software
          : RenderBackend.flutterScene);
    }
    // Live tuning knob: planet texture longitude alignment (degrees).
    final texYaw = deg('textureYawDeg');
    if (texYaw != null) {
      BodyNodes.textureYawRad = texYaw * math.pi / 180;
    }
    if (params['focusBody'] != null) {
      c.focusBody?.call(params['focusBody']!);
    }
    // Auto-warp to the focused vessel's next apsis: warpApsis=ap|pe.
    if (params['warpApsis'] != null) {
      c.warpToApsis?.call(params['warpApsis'] == 'pe');
    }
    // Camera up alignment: alignUp=free|axis|gravity.
    if (params['alignUp'] != null) {
      c.setUpMode?.call(params['alignUp']!);
    }
    // Freecam: freecam=true|false, optional freePos=x,y,z (world metres).
    if (params['freecam'] != null || params['freePos'] != null) {
      c.setFreecam?.call(
          params['freecam'] == null ? true : params['freecam'] == 'true',
          _triple(params['freePos']));
    }
    // First-person walk: walk=true|false. Standing up implies the freecam and
    // drops the anchor onto the terrain under the current view, so a surface
    // capture at eye height is one call (optionally after focusBody=).
    if (params['walk'] != null) {
      c.setWalk?.call(params['walk'] == 'true');
    }
    // Third person: thirdPerson=true|false. EVA pack: eva=true|false.
    if (params['thirdPerson'] != null) {
      c.setThirdPerson?.call(params['thirdPerson'] == 'true');
    }
    if (params['eva'] != null) {
      c.setEvaPack?.call(params['eva'] == 'true');
    }
    // Head lamp: lamp=true|false.
    if (params['lamp'] != null) {
      c.setLamp?.call(params['lamp'] == 'true');
    }
    // Walker drill trigger: drill=true|false (held until released).
    if (params['drill'] != null) {
      c.setDrill?.call(params['drill'] == 'true');
    }
    // Craft glb unit calibration: glbScale=<model units to metres>. WHOLE-CRAFT
    // path only (the apollo/lander bakes). A craft drawn from its PART LIST is
    // calibrated per part — see `part=` below.
    final glbScale = params['glbScale'];
    if (glbScale != null) {
      final v = double.tryParse(glbScale);
      if (v != null && v > 0) VesselNodes.glbUnitScale = v;
    }
    // Per-PART art calibration, for settling a new export against the axis
    // ruler (axes=true) by screenshot:
    //   ext.acro.camera?part=eagle-legs&partRotDeg=90,0,0
    //   ext.acro.camera?part=eagle-legs&partScale=2.4&partOffsetM=0,0,0.4
    //   ext.acro.camera?partScaleAll=1.1   (every part at once, on top of each
    //                                       part's own scale)
    //   ext.acro.camera?partReset=true     (drop every override)
    // `part=` names the part in any spelling of its catalog id; the three
    // part* values replace that part's PartDef render fields for the rest of
    // the session, and unnamed ones keep whatever is already in force. The
    // kitbash renderer re-resolves the binding every frame, so each call lands
    // on the next one. EVERY reply carries `partCalibration`: the settled
    // values as Dart literals, to paste into the catalog (`lem_parts.dart`) —
    // the sweep is finished when that map is empty again.
    final partScaleAll = deg('partScaleAll');
    if (partScaleAll != null && partScaleAll > 0) {
      PartModelLibrary.scaleMultiplier = partScaleAll;
    }
    if (params['partReset'] == 'true') PartModelLibrary.resetCalibration();
    final partKey = params['part'];
    if (partKey != null) {
      final partScale = deg('partScale');
      final rotDeg = _triple(params['partRotDeg']);
      PartModelLibrary.calibrate(
        partKey,
        scale: partScale != null && partScale > 0 ? partScale : null,
        rotation: rotDeg == null ? null : _eulerDeg(rotDeg),
        offset: _triple(params['partOffsetM']),
      );
    }
    // Per-craft origin + 1-metre axis ruler: axes=true|false.
    if (params['axes'] != null) {
      VesselNodes.showAxes = params['axes'] == 'true';
    }
    // Anti-aliasing: aa=msaa|fxaa|auto (auto restores the engine default).
    final aa = params['aa'];
    if (aa != null) {
      SceneSync.aaRequest = switch (aa) {
        'msaa' => AntiAliasingMode.msaa,
        'fxaa' => AntiAliasingMode.fxaa,
        _ => AntiAliasingMode.auto,
      };
    }
    // Adaptive exposure toggle: autoExposure=true|false. exposure=<x> sets a
    // manual value AND switches auto off (that is what setting it means);
    // expMin/expMax clamp the auto target, expUp/expDown are the ease time
    // constants in seconds. Same knobs as the debug panel's EXPOSURE section.
    if (params['autoExposure'] != null) {
      SceneSync.autoExposure = params['autoExposure'] == 'true';
    }
    final exposure = deg('exposure');
    if (exposure != null && exposure > 0) {
      SceneSync.manualExposure = exposure;
      SceneSync.autoExposure = false;
    }
    final expMin = deg('expMin');
    if (expMin != null && expMin > 0) {
      SceneSync.minExposure = math.min(expMin, SceneSync.maxExposure);
    }
    final expMax = deg('expMax');
    if (expMax != null && expMax > 0) {
      SceneSync.maxExposure = math.max(expMax, SceneSync.minExposure);
    }
    final expUp = deg('expUp');
    if (expUp != null && expUp > 0) SceneSync.adaptUpS = expUp;
    final expDown = deg('expDown');
    if (expDown != null && expDown > 0) SceneSync.adaptDownS = expDown;
    // Cast-shadow pass toggle (A/B): shadows=true|false.
    if (params['shadows'] != null) {
      SceneSync.shadowsEnabled = params['shadows'] == 'true';
    }
    // Spacetime-grid floor toggle (A/B): gravityGrid=true|false.
    if (params['gravityGrid'] != null) {
      GravityGridNodes.enabled = params['gravityGrid'] == 'true';
    }
    // Halo-ring toggle (A/B): haloRing=true|false.
    if (params['haloRing'] != null) {
      HaloRingNodes.enabled = params['haloRing'] == 'true';
    }
    // Terrain material tuning: tileM=<metres>, sandW/grassW=0..1, plus the
    // macro texture octave: macroTileM=<metres> (0 disables), macroW=0..1.
    final tileM = deg('tileM');
    if (tileM != null && tileM > 0) TerrainNodes.tileMeters = tileM;
    final sandW = deg('sandW');
    if (sandW != null) TerrainNodes.sandWeight = sandW.clamp(0.0, 1.0);
    final grassW = deg('grassW');
    if (grassW != null) TerrainNodes.grassWeight = grassW.clamp(0.0, 1.0);
    final macroTileM = deg('macroTileM');
    if (macroTileM != null && macroTileM >= 0) {
      TerrainNodes.macroTileMeters = macroTileM;
    }
    final macroW = deg('macroW');
    if (macroW != null) TerrainNodes.macroWeight = macroW.clamp(0.0, 1.0);
    final macroBump = deg('macroBump');
    if (macroBump != null && macroBump >= 0) {
      TerrainNodes.macroBumpStrength = macroBump;
    }
    final macroFadeNear = deg('macroFadeNear');
    if (macroFadeNear != null && macroFadeNear >= 0) {
      TerrainNodes.macroFadeNearKm = macroFadeNear;
    }
    final macroFadeFar = deg('macroFadeFar');
    if (macroFadeFar != null && macroFadeFar > 0) {
      TerrainNodes.macroFadeFarKm =
          math.max(macroFadeFar, TerrainNodes.macroFadeNearKm + 1.0);
    }
    // Star bloom + lens flare: bloomScale=<x star radius>, flares=true|false,
    // flareW=0..2 (overall ghost intensity).
    final bloomScale = deg('bloomScale');
    if (bloomScale != null && bloomScale > 0) StarBloomNodes.scale = bloomScale;
    if (params['flares'] != null) {
      StarBloomNodes.flares = params['flares'] == 'true';
    }
    final flareW = deg('flareW');
    if (flareW != null && flareW >= 0) StarBloomNodes.flareStrength = flareW;
    // Shadow contact hardening: shHard=<hardness>, shPen=<max penumbra factor>.
    final shHard = deg('shHard');
    if (shHard != null && shHard >= 0) TerrainNodes.shadowHardness = shHard;
    final shPen = deg('shPen');
    if (shPen != null && shPen >= 0) TerrainNodes.maxPenumbraFactor = shPen;
    // Planet-in-reflections IBL baker: planetEnv=true|false,
    // envIntensity=<double> (baked-map IBL strength, default 1.0).
    if (params['planetEnv'] != null) {
      PlanetEnvironmentBaker.enabled = params['planetEnv'] == 'true';
    }
    final envInt = deg('envIntensity');
    if (envInt != null && envInt >= 0) {
      PlanetEnvironmentBaker.bakedIntensity = envInt;
    }
    // envTest=white bakes a solid-white map (IBL pipeline probe); envTest=
    // (empty) restores the planet composite.
    if (params['envTest'] != null) {
      PlanetEnvironmentBaker.testPattern =
          params['envTest'] == 'white' ? 'white' : '';
    }
    // On-screen reflection-capture overlay: envDebug=true|false.
    if (params['envDebug'] != null) {
      PlanetEnvironmentBaker.showDebug = params['envDebug'] == 'true';
    }
    // Depth-plane overrides (metres): near=5&far=1e12; <=0 restores the
    // adaptive formula.
    final nearOv = params['near'], farOv = params['far'];
    if (nearOv != null) {
      final v = double.tryParse(nearOv);
      SceneCameraDebug.nearOverrideM = (v == null || v <= 0) ? null : v;
    }
    if (farOv != null) {
      final v = double.tryParse(farOv);
      SceneCameraDebug.farOverrideM = (v == null || v <= 0) ? null : v;
    }
    // Exact ring-plane teleport: freeRing=bodyId,radialMult,zMetres.
    if (params['freeRing'] != null) {
      final p = params['freeRing']!.split(',');
      if (p.length == 3) {
        final mult = double.tryParse(p[1]), z = double.tryParse(p[2]);
        if (mult != null && z != null) {
          c.freecamToRing?.call(p[0], mult, z);
        }
      }
    }
    return developer.ServiceExtensionResponse.result(jsonEncode({
      ...(c.status?.call() ?? const {'error': 'no live view'}),
      // Always reported, empty or not: a calibration sweep is only over once
      // these literals are in the catalog and this map is empty again.
      'partCalibration': PartModelLibrary.calibrationSource(),
      'partScaleAll': PartModelLibrary.scaleMultiplier,
    }));
  });
  developer.registerExtension('ext.acro.status', (method, params) async {
    return developer.ServiceExtensionResponse.result(jsonEncode(
        SimViewControl.instance.status?.call() ?? {'error': 'no live view'}));
  });

  // Drop a test impactor beside the focused craft (the debug panel's button,
  // remotely): ext.acro.impact?massKg=9000&speedMs=300
  // Drives the terrain-impact FX path headlessly for captures.
  developer.registerExtension('ext.acro.impact', (method, params) async {
    final drop = SimViewControl.instance.dropImpactor;
    if (drop == null) {
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'error': 'no live view'}));
    }
    drop(
      massKg: double.tryParse(params['massKg'] ?? '') ?? 9000,
      speedMs: double.tryParse(params['speedMs'] ?? '') ?? 300,
      destroy: params['destroy'] != 'false',
    );
    return developer.ServiceExtensionResponse.result(jsonEncode({'ok': true}));
  });

  // Teleport the focused craft to a landing site: ext.acro.spawn?body=moon
  developer.registerExtension('ext.acro.spawn', (method, params) async {
    final spawn = SimViewControl.instance.spawnLanded;
    final body = params['body'];
    if (spawn == null || body == null) {
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'error': spawn == null ? 'no live view' : 'body required'}));
    }
    spawn(body);
    return developer.ServiceExtensionResponse.result(jsonEncode({'ok': true}));
  });

  // Live atmosphere art-pass knobs (applied next frame; render-side only):
  //   ext.acro.atmo?body=earth&falloff=8&height=6&intensity=25
  //     &density=1.2&tint=cc7a33&mix=0.6&twilightKm=800&shellKm=2000
  //     &enabled=true
  // Any call (also with no params) returns the FULL current style table —
  // tune live, then bake the numbers into AtmosphereNodes.styles.
  developer.registerExtension('ext.acro.atmo', (method, params) async {
    final id = params['body'];
    if (id != null) {
      final s = AtmosphereNodes.styles.putIfAbsent(id, AtmoStyle.new);
      double? num(String k) =>
          params[k] == null ? null : double.tryParse(params[k]!);
      if (num('height') != null) s.heightScale = num('height')!;
      if (num('falloff') != null) s.falloff = num('falloff')!;
      if (num('intensity') != null) s.intensity = num('intensity')!;
      if (num('density') != null) s.density = num('density')!;
      if (num('mix') != null) s.tintMix = num('mix')!;
      if (num('shellKm') != null) s.shellHeightM = num('shellKm')! * 1000;
      if (num('twilightKm') != null) s.twilightM = num('twilightKm')! * 1000;
      if (params['tint'] != null) {
        s.tintArgb = 0xFF000000 | int.parse(params['tint']!, radix: 16);
      }
      if (params['enabled'] != null) s.enabled = params['enabled'] == 'true';
    }
    return developer.ServiceExtensionResponse.result(jsonEncode({
      for (final e in AtmosphereNodes.styles.entries) e.key: e.value.toJson(),
    }));
  });

  // Live terrain-gate probe:
  //   callServiceExtension?...&method=ext.acro.terrain
  // Reports the chunk state (debugLine) and every gate that can silently
  // suppress the chunk, so "no terrain on <body>" is diagnosable without a
  // rebuild-per-guess loop.
  developer.registerExtension('ext.acro.terrain', (method, params) async {
    // Settable knobs, e.g.
    //   ext.acro.terrain?splitPx=180&maxResidentChunks=256
    // Terrain is always on for the focused body (no apparent-size gate any
    // more — at a few pixels it collapses to the six face roots). Note the
    // camera's near plane is (range + bodyRadius)/20, so a BODY focus still
    // clips everything within ~87 km on the Moon.
    double? num(String k) =>
        params[k] == null ? null : double.tryParse(params[k]!);
    final sp = num('splitPx');
    if (sp != null && sp > 0) TerrainNodes.splitPx = sp;
    final cap = num('maxResidentChunks');
    if (cap != null && cap >= 6) TerrainNodes.maxResidentChunks = cap.round();
    final res = num('resolution');
    if (res != null && res >= 2) TerrainNodes.resolution = res.round();
    final budget = num('meshBudgetPerFrame');
    if (budget != null && budget >= 1) {
      TerrainNodes.meshBudgetPerFrame = budget.round();
    }
    final uploads = num('uploadBudgetPerFrame');
    if (uploads != null && uploads >= 1) {
      TerrainNodes.uploadBudgetPerFrame = uploads.round();
    }
    // skirtVoxels=0 shows the LOD cracks the apron hides — the 4b A/B.
    final skirt = num('skirtVoxels');
    if (skirt != null && skirt >= 0) TerrainNodes.skirtVoxels = skirt;
    if (params['enabled'] != null) {
      TerrainNodes.enabled = params['enabled'] == 'true';
    }
    // asyncMeshing=false is the 4c A/B: meshing back on the render thread.
    if (params['asyncMeshing'] != null) {
      TerrainNodes.asyncMeshing = params['asyncMeshing'] == 'true';
    }
    // debugView=0..3 cycles the shader debug view (normal/height/albedo/align)
    // for headless alignment captures.
    final view = num('debugView');
    if (view != null) {
      TerrainNodes.debugView =
          view.round().clamp(0, TerrainNodes.debugViewCount - 1);
    }
    return developer.ServiceExtensionResponse.result(jsonEncode({
      'debug': TerrainNodes.debugLine,
      'lastReject': TerrainNodes.lastRejectLine,
      'gate': TerrainNodes.gateReason,
      'enabled': TerrainNodes.enabled,
      'debugView': TerrainNodes.debugView,
      'texturesReady': TerrainTextures.ready,
      'splitPx': TerrainNodes.splitPx,
      'maxResidentChunks': TerrainNodes.maxResidentChunks,
      'resolution': TerrainNodes.resolution,
      'skirtVoxels': TerrainNodes.skirtVoxels,
      'meshBudgetPerFrame': TerrainNodes.meshBudgetPerFrame,
      'uploadBudgetPerFrame': TerrainNodes.uploadBudgetPerFrame,
      'asyncMeshing': TerrainNodes.asyncMeshing,
    }));
  });

  // Live cloud art-pass knobs (applied next frame; render-side only):
  //   ext.acro.clouds?body=earth&coverage=0.5&density=16&baseKm=2&topKm=15
  //     &wind=0.004&windGlobal=0.02&swirlStrength=5&swirlFreq=0.28
  //     &swirlSpeed=0.005&bandShear=2&bandWidthDeg=20&detail=0.4
  //     &ambient=0.25&intensity=1.4&freq=14&tint=f2f5ff&enabled=true
  // Any call (also with no params) returns the FULL current style table —
  // tune live, then bake the numbers into CloudNodes.styles.
  developer.registerExtension('ext.acro.clouds', (method, params) async {
    final id = params['body'];
    if (id != null) {
      final s = CloudNodes.styles.putIfAbsent(id, CloudStyle.new);
      double? num(String k) =>
          params[k] == null ? null : double.tryParse(params[k]!);
      if (num('baseKm') != null) s.baseM = num('baseKm')! * 1000;
      if (num('topKm') != null) s.topM = num('topKm')! * 1000;
      if (num('coverage') != null) s.coverage = num('coverage')!;
      if (num('density') != null) s.density = num('density')!;
      if (num('wind') != null) s.wind = num('wind')!;
      if (num('windGlobal') != null) s.windGlobal = num('windGlobal')!;
      if (num('swirlStrength') != null) s.swirlStrength = num('swirlStrength')!;
      if (num('swirlFreq') != null) s.swirlFreq = num('swirlFreq')!;
      if (num('swirlSpeed') != null) s.swirlSpeed = num('swirlSpeed')!;
      if (num('bandShear') != null) s.bandShear = num('bandShear')!;
      if (num('bandWidthDeg') != null) {
        s.bandWidth = num('bandWidthDeg')! * math.pi / 180;
      }
      if (num('bandMaxShearDeg') != null) {
        s.bandMaxShear = num('bandMaxShearDeg')! * math.pi / 180;
      }
      if (num('coverageVar') != null) s.coverageVar = num('coverageVar')!;
      if (num('coverageFreq') != null) s.coverageFreq = num('coverageFreq')!;
      if (num('coverageSpeed') != null) {
        s.coverageSpeed = num('coverageSpeed')!;
      }
      if (num('detail') != null) s.detail = num('detail')!;
      if (num('ambient') != null) s.ambient = num('ambient')!;
      if (num('intensity') != null) s.intensity = num('intensity')!;
      if (num('freq') != null) s.freq = num('freq')!;
      if (params['tint'] != null) {
        s.tintArgb = 0xFF000000 | int.parse(params['tint']!, radix: 16);
      }
      if (params['tint2'] != null) {
        s.tint2Argb = 0xFF000000 | int.parse(params['tint2']!, radix: 16);
      }
      if (num('tintMix') != null) s.tintMix = num('tintMix')!;
      if (params['enabled'] != null) s.enabled = params['enabled'] == 'true';
    }
    return developer.ServiceExtensionResponse.result(jsonEncode({
      for (final e in CloudNodes.styles.entries) e.key: e.value.toJson(),
    }));
  });

  // ExcludeSemantics wraps the ENTIRE app (above MaterialApp): the Windows
  // accessibility bridge AVs in flutter_windows.dll (+0x3bc6a) when the
  // semantics tree mutates on a focus switch, and every crash is preceded
  // by a stream of 'Failed to update ui::AXTree ... will not be in the tree'
  // errors. Excluding only home (below MaterialApp) left MaterialApp's OWN
  // navigator/overlay/focus semantics mutating every frame — still spammed.
  // Excluding the whole app yields an empty, static semantics tree: the
  // bridge has nothing to reconcile. Pointer input, gestures, and the
  // RepaintBoundary screenshot path don't depend on semantics. Dev harness
  // only; revisit for prod builds.
  runApp(
    ExcludeSemantics(
      child: MaterialApp(
        title: 'Acro — flutter_scene dev',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: RepaintBoundary(
          key: _shotKey,
          child: SimulationView(
            initialBackend: backend == 'software'
                ? RenderBackend.software
                : RenderBackend.flutterScene,
            // Dev scene: the Apollo CSM (service module) + the Lunar Module in
            // a low lunar orbit on the Moon's DAYLIGHT side, in loose formation
            // (the CSM a touch higher and ahead). The built-in demo orbiter is
            // suppressed so the scene is exactly these two craft. Model wiring
            // (VesselNodes._assetFor): the 'lander' id renders lander.fsceneb,
            // the CSM renders apollo.fsceneb.
            spawnDemoOrbiter: false,
            injectedVessel: SampleWorld.buildLunarOrbiter(
              id: 'moon-lander',
              name: 'Lunar Module',
            ),
            trafficVessels: [
              // Same orbit, ~14 m ahead — almost touching, no drift.
              SampleWorld.buildLunarOrbiter(
                id: 'csm',
                name: 'Service Module',
                alongTrackM: 14,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
