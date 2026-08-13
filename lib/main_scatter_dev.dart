// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'domain/scatter/prop_catalog.dart';
import 'domain/scatter/prop_model.dart';
import 'infrastructure/flutter/scatter_lab_control.dart';
import 'infrastructure/flutter/screens/scatter_lab_screen.dart';
import 'infrastructure/flutter/windows_key_event_workaround.dart';

/// Dev entrypoint: boots STRAIGHT into the [ScatterLabScreen] — no menu, no
/// clicking. Tuning a generator means changing a constant and looking at the
/// result, over and over; going through the main menu every hot restart makes
/// that loop several times slower.
///
///   .fvm/flutter_sdk/bin/flutter run -d macos --enable-impeller \
///       --enable-flutter-gpu -t lib/main_scatter_dev.dart
///
/// Not wired into any release build; the shipping entrypoint stays main.dart,
/// which reaches the same screen through its SCATTER LAB menu item.
///
/// Also registers `ext.acro.screenshot` (same contract as main_scene_dev.dart)
/// so a prop can be captured headlessly for comparison:
///   `callServiceExtension?...&method=ext.acro.screenshot&path=<out.png>`
final GlobalKey _shotKey = GlobalKey();

void main() {
  installWindowsAltKeyAssertFilter();

  developer.registerExtension('ext.acro.screenshot', (method, params) async {
    try {
      final path = params['path'] ?? 'scatter_shot.png';
      final boundary =
          _shotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          'no RepaintBoundary yet',
        );
      }
      final ui.Image image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File(path).writeAsBytes(data!.buffer.asUint8List());
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'saved': path}));
    } catch (e) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        '$e',
      );
    }
  });

  // Drive the live lab over the VM service, e.g.
  //   ext.acro.scatter?kind=coniferTree&lod=lod2&grid=4&az=1.2&dist=40
  //   ext.acro.scatter                       -> current state, no change
  // Every call returns the lab's full status, so a capture script can assert
  // what it just photographed.
  developer.registerExtension('ext.acro.scatter', (method, params) async {
    final control = ScatterLabControl.instance;
    final apply = control.apply;
    if (apply == null) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        'no live scatter lab',
      );
    }
    double? num(String k) =>
        params[k] == null ? null : double.tryParse(params[k]!);
    bool? flag(String k) => params[k] == null ? null : params[k] == 'true';
    PropKind? kindArg() {
      final raw = params['kind'];
      if (raw == null) return null;
      for (final v in PropKind.values) {
        if (v.name == raw) return v;
      }
      return null;
    }

    PropLod? lodArg() {
      final raw = params['lod'];
      if (raw == null) return null;
      for (final v in PropLod.values) {
        if (v.name == raw) return v;
      }
      return null;
    }

    apply(
      kind: kindArg(),
      seed: params['seed'] == null ? null : int.tryParse(params['seed']!),
      gridSide: params['grid'] == null ? null : int.tryParse(params['grid']!),
      lod: lodArg(),
      autoLod: flag('autoLod'),
      varySeeds: flag('varySeeds'),
      azimuth: num('az'),
      elevation: num('el'),
      distanceM: num('dist'),
      sunAzimuth: num('sun'),
      frame: flag('frame'),
    );
    // apply() only schedules a rebuild, so reading the stats straight back
    // reports the PREVIOUS state — which made every scripted capture's JSON
    // describe the frame before the one it photographed. Wait for the frame to
    // actually paint first.
    await SchedulerBinding.instance.endOfFrame;
    return developer.ServiceExtensionResponse.result(
        jsonEncode(control.status?.call() ?? const {}));
  });

  runApp(
    // ExcludeSemantics for the same reason main_scene_dev.dart does it: the
    // Windows accessibility bridge faults when the semantics tree mutates on a
    // focus switch. Harmless on macOS, kept so the two dev harnesses behave
    // identically wherever they are run.
    ExcludeSemantics(
      child: MaterialApp(
        title: 'Acro — scatter lab',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: RepaintBoundary(key: _shotKey, child: const ScatterLabScreen()),
      ),
    ),
  );
}
