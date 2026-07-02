import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;

import '../flutter/texture_cache.dart';

/// Bridges the app's [TextureCache] (decoded `ui.Image`s from
/// `assets/textures/<key>.jpg`) into flutter_scene GPU textures.
///
/// Same lazy contract as the source cache: ask by key, get null until the
/// decode + GPU upload complete, then [onReady] fires so the scene can
/// swap the material texture in. GPU textures are cached forever (planet
/// maps are small and few).
///
/// Textures are held as `Object`: flutter_scene master routes GPU types
/// through an internal backend shim (native flutter_gpu vs WebGL2), so the
/// concrete texture type is not ours to name — material texture setters
/// accept the shim object directly.
class SceneTextures {
  SceneTextures(this._images, {this.onReady});

  final TextureCache _images;
  final void Function()? onReady;

  final Map<String, Object> _textures = {};
  final Set<String> _uploading = {};

  /// The GPU texture for [key], or null while it loads. Kicks off the image
  /// decode (via the shared [TextureCache]) and GPU upload on first miss.
  Object? texture(String key) {
    final hit = _textures[key];
    if (hit != null) return hit;
    final ui.Image? img = _images.image(key); // starts decode on first miss
    if (img == null || _uploading.contains(key)) return null;
    _uploading.add(key);
    fs.gpuTextureFromImage(img).then((tex) {
      _textures[key] = tex as Object;
      _uploading.remove(key);
      onReady?.call();
    }).catchError((Object e) {
      _uploading.remove(key);
    });
    return null;
  }
}
