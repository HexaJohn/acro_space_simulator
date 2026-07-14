// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter_gpu_shaders/build.dart';
import 'package:hooks/hooks.dart';

/// Native-assets build hook: compiles the app's custom GPU shaders
/// (shaders/*.frag, manifest shaders/acro.shaderbundle.json) into
/// `build/shaderbundles/acro.shaderbundle`, loaded at runtime with
/// `gpu.loadShaderLibraryAsync`. Mirrors the flutter_scene example app.
void main(List<String> args) {
  build(args, (config, output) async {
    await buildShaderBundleJson(
      buildInput: config,
      buildOutput: output,
      manifestFileName: 'shaders/acro.shaderbundle.json',
      // Match the engine bundle's GLES dialect (the flutter_scene web/GLES
      // backends consume ES 3.00 output).
      glesLanguageVersion: 300,
    );
  });
}
