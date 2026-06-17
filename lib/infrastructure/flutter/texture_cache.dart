import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;

/// Lazily loads and caches body surface maps (decoded [ui.Image]s) from the
/// asset bundle. The painter asks for a texture by key; the first miss kicks off
/// an async decode and returns null (procedural fallback) until it's ready, then
/// [onReady] fires so the view can repaint.
class TextureCache {
  TextureCache({this.onReady});

  /// Called when a previously-missing texture finishes decoding.
  final void Function()? onReady;

  final Map<String, ui.Image> _images = {};
  final Set<String> _loading = {};
  final Set<String> _failed = {};

  /// Diagnostics for the on-screen HUD.
  int get loadedCount => _images.length;
  int get failedCount => _failed.length;
  String? lastError;

  /// Whether [key] is already decoded (does NOT kick off a load).
  bool isLoaded(String key) => _images.containsKey(key);

  /// Inject an already-decoded image (tests / off-bundle sources). Lets a render
  /// harness supply textures without the asset bundle + async decode round-trip.
  void seed(String key, ui.Image image) => _images[key] = image;

  /// The decoded image for [key], or null if not loaded yet (decode is kicked
  /// off on the first miss). Keys map to `assets/textures/<key>.jpg`.
  ui.Image? image(String key) {
    final hit = _images[key];
    if (hit != null) return hit;
    if (_loading.contains(key) || _failed.contains(key)) return null;
    _loading.add(key);
    _load(key);
    return null;
  }

  Future<void> _load(String key) async {
    try {
      final data = await rootBundle.load('assets/textures/$key.jpg');
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      _images[key] = frame.image;
      _loading.remove(key);
      onReady?.call();
    } catch (e) {
      // Missing/corrupt asset: remember the failure so we don't retry forever.
      _loading.remove(key);
      _failed.add(key);
      lastError = '$key: $e';
      onReady?.call(); // repaint so the HUD can surface the error
    }
  }

  void dispose() {
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
  }
}
