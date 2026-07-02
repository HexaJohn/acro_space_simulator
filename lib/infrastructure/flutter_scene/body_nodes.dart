import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';
import 'scene_textures.dart';

/// Maintains one scene node per celestial body from the frame's
/// [BodySnapshot]s: a shared unit sphere scaled to the body radius, textured
/// with the body's equirect map (key = descriptor albedoKey, falling back to
/// the body id — same convention as the software renderer), spun/tilted by
/// the snapshot orientation quaternion.
///
/// Stars get an unlit (self-luminous) material; everything else is PBR lit
/// by the star's directional light (owned by SceneSync).
class BodyNodes {
  BodyNodes(this._scene, this._textures);

  final fs.Scene _scene;
  final SceneTextures _textures;

  // One shared unit sphere; each body is a node scaling it. Radius 1 scene
  // unit; node scale = radius in km.
  late final fs.SphereGeometry _unitSphere =
      fs.SphereGeometry(radius: 1.0, segments: 96, rings: 48);

  final Map<String, fs.Node> _nodes = {};
  final Map<String, fs.Material> _materials = {};
  // Bodies whose material still shows the flat fallback; retried each frame
  // until the texture upload lands.
  final Set<String> _untextured = {};

  /// Kind cache from the (sticky) descriptors — they may be absent on a
  /// given frame for wire consumers, but our in-process capture always
  /// includes them; keep the join tolerant anyway.
  final Map<String, BodyKind> _kinds = {};

  void update(
    WorldSnapshot snap,
    FloatingOrigin origin,
  ) {
    for (final d in snap.descriptors.values) {
      _kinds[d.id] = d.kind;
    }

    final seen = <String>{};
    for (final b in snap.bodies.values) {
      seen.add(b.id);
      final node = _nodes.putIfAbsent(b.id, () => _createNode(b, snap));
      _retryTexture(b.id, snap);

      // Focus-relative position (doubles) -> scene units; spin/tilt as-is.
      final pos = origin.worldToScene(Vector3(b.px, b.py, b.pz));
      final rot = quatToScene(Quaternion(b.qw, b.qx, b.qy, b.qz));
      final scale = lengthToScene(b.radius);
      node.localTransform = Matrix4Compose.compose(pos, rot, scale);
    }

    // Remove bodies that left the snapshot (never happens today, but keeps
    // the sync honest).
    _nodes.removeWhere((id, node) {
      if (seen.contains(id)) return false;
      _scene.remove(node);
      _materials.remove(id);
      _untextured.remove(id);
      return true;
    });
  }

  /// World position of the star (system light source), if a star body is in
  /// the snapshot. Used by SceneSync to aim the directional light.
  Vector3? starWorld(WorldSnapshot snap) {
    for (final b in snap.bodies.values) {
      if (_kinds[b.id] == BodyKind.star) return Vector3(b.px, b.py, b.pz);
    }
    return null;
  }

  bool isStar(String id) => _kinds[id] == BodyKind.star;

  fs.Node _createNode(BodySnapshot b, WorldSnapshot snap) {
    final material = _createMaterial(b.id, snap);
    _materials[b.id] = material;
    final node = fs.Node(mesh: fs.Mesh(_unitSphere, material));
    _scene.add(node);
    return node;
  }

  /// Texture key: descriptor albedoKey when set, else the body id — matches
  /// the software renderer's `assets/textures/<id>.jpg` convention.
  String _textureKey(String id, WorldSnapshot snap) {
    final key = snap.descriptors[id]?.albedoKey ?? '';
    return key.isNotEmpty ? key : id;
  }

  fs.Material _createMaterial(String id, WorldSnapshot snap) {
    final tex = _textures.texture(_textureKey(id, snap));
    if (tex == null) _untextured.add(id);
    if (isStar(id)) {
      // Self-luminous: unlit so the star never shows a terminator, plus a
      // white-hot tint. (Corona/bloom is WS4 territory.)
      return fs.UnlitMaterial()
        ..baseColorTexture = tex
        ..baseColorFactor = vm.Vector4(1.0, 0.98, 0.9, 1.0);
    }
    return fs.PhysicallyBasedMaterial()
      ..baseColorTexture = tex
      ..baseColorFactor = tex == null
          ? vm.Vector4(0.5, 0.5, 0.55, 1.0) // flat fallback while loading
          : vm.Vector4(1.0, 1.0, 1.0, 1.0)
      ..roughnessFactor = 1.0
      ..metallicFactor = 0.0;
  }

  void _retryTexture(String id, WorldSnapshot snap) {
    if (!_untextured.contains(id)) return;
    final tex = _textures.texture(_textureKey(id, snap));
    if (tex == null) return;
    _untextured.remove(id);
    final m = _materials[id];
    if (m is fs.PhysicallyBasedMaterial) {
      m
        ..baseColorTexture = tex
        ..baseColorFactor = vm.Vector4(1.0, 1.0, 1.0, 1.0);
    } else if (m is fs.UnlitMaterial) {
      m.baseColorTexture = tex;
    }
  }
}

/// Milky Way backdrop: the `starfield` equirect map on a huge sphere around
/// the camera focus, rendered from the INSIDE via `doubleSided` (which
/// disables back-face culling for an opaque material — see Material.bind).
class SkyboxNode {
  SkyboxNode(this._scene, this._textures);

  static const double _radius = 1e9; // km — inside far plane (5e9 km)

  final fs.Scene _scene;
  final SceneTextures _textures;
  fs.Node? _node;

  void update() {
    if (_node != null) return; // static once created
    final tex = _textures.texture('starfield');
    if (tex == null) return; // retry next frame
    final node = fs.Node(
      mesh: fs.Mesh(
        fs.SphereGeometry(radius: 1.0, segments: 48, rings: 24),
        fs.UnlitMaterial()
          ..baseColorTexture = tex
          ..doubleSided = true,
      ),
    )..localTransform = vm.Matrix4.compose(
        vm.Vector3.zero(),
        vm.Quaternion.identity(),
        vm.Vector3.all(_radius),
      );
    _scene.add(node);
    _node = node;
  }
}

/// Compose helpers (translation + rotation + uniform scale) without pulling
/// in Matrix4.compose's Vector3 scale allocation at every call site.
extension Matrix4Compose on vm.Matrix4 {
  static vm.Matrix4 compose(vm.Vector3 t, vm.Quaternion r, double scale) {
    final m = vm.Matrix4.compose(t, r, vm.Vector3.all(scale));
    return m;
  }
}
