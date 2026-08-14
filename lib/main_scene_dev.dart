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
import 'infrastructure/flutter_scene/render_backend.dart';
import 'infrastructure/flutter_scene/scene_camera_adapter.dart';
import 'infrastructure/flutter_scene/scene_sync.dart';
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
      Vector3? pos;
      final raw = params['freePos'];
      if (raw != null) {
        final p = raw.split(',').map(double.tryParse).toList();
        if (p.length == 3 && !p.contains(null)) {
          pos = Vector3(p[0]!, p[1]!, p[2]!);
        }
      }
      c.setFreecam?.call(
          params['freecam'] == null ? true : params['freecam'] == 'true', pos);
    }
    // Craft glb unit calibration: glbScale=<model units to metres>.
    final glbScale = params['glbScale'];
    if (glbScale != null) {
      final v = double.tryParse(glbScale);
      if (v != null && v > 0) VesselNodes.glbUnitScale = v;
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
    // Terrain material tuning: tileM=<metres>, sandW/grassW=0..1.
    final tileM = deg('tileM');
    if (tileM != null && tileM > 0) TerrainNodes.tileMeters = tileM;
    final sandW = deg('sandW');
    if (sandW != null) TerrainNodes.sandWeight = sandW.clamp(0.0, 1.0);
    final grassW = deg('grassW');
    if (grassW != null) TerrainNodes.grassWeight = grassW.clamp(0.0, 1.0);
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
    return developer.ServiceExtensionResponse.result(
        jsonEncode(c.status?.call() ?? {'error': 'no live view'}));
  });
  developer.registerExtension('ext.acro.status', (method, params) async {
    return developer.ServiceExtensionResponse.result(jsonEncode(
        SimViewControl.instance.status?.call() ?? {'error': 'no live view'}));
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
      if (num('detail') != null) s.detail = num('detail')!;
      if (num('ambient') != null) s.ambient = num('ambient')!;
      if (num('intensity') != null) s.intensity = num('intensity')!;
      if (num('freq') != null) s.freq = num('freq')!;
      if (params['tint'] != null) {
        s.tintArgb = 0xFF000000 | int.parse(params['tint']!, radix: 16);
      }
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
