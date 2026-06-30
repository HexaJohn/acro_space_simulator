import 'celestial_body.dart' show BodyId;

/// Terrain elevations reported by the renderer (e.g. Unreal ray-casts its
/// landscape and tells the sim the ground height at a surface point). This is a
/// RENDER-RECONCILIATION cache only:
///   * it is NOT read by the deterministic physics tick,
///   * it is NOT part of the determinism fingerprint,
/// so a client feeding terrain heights can never desync the authoritative
/// simulation. Only surface PLACEMENT (buildings, landed craft) consults it, so
/// the sim and the engine agree on where surface objects sit. Default 0 = a
/// smooth sphere of the body's radius.
class TerrainHeights {
  /// Lat/lon quantization for keying (radians). ~0.0001 rad ≈ 60 m on Kerbin.
  final double cellRadians;
  final Map<String, double> _heights = {};

  TerrainHeights({this.cellRadians = 0.0001});

  String _key(BodyId body, double lat, double lon) {
    int q(double a) => (a / cellRadians).round();
    return '${body.value}:${q(lat)}:${q(lon)}';
  }

  void report(BodyId body, double lat, double lon, double height) =>
      _heights[_key(body, lat, lon)] = height;

  double heightAt(BodyId body, double lat, double lon) =>
      _heights[_key(body, lat, lon)] ?? 0;

  bool get isEmpty => _heights.isEmpty;
}
