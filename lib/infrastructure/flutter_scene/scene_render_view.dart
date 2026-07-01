import 'package:flutter/material.dart';

/// The flutter_scene (Impeller) world viewport — WS0 placeholder.
///
/// Will own a `Scene`, consume the per-frame `WorldSnapshot` (the same 3D
/// world feed the Unreal bridge serializes — NOT the 2D `TopDownSnapshot`),
/// and render focus-relative to keep float32 precision at planetary
/// distances (the floating-origin convention `PerspectiveCamera.projectPx`
/// already uses: every position is `world - focusWorld`).
///
/// Placeholder until the pinned master SDK + flutter_scene dependency land
/// (WS0): renders a labelled void so the backend toggle is wired and
/// testable end-to-end first.
class SceneRenderView extends StatefulWidget {
  const SceneRenderView({super.key});

  @override
  State<SceneRenderView> createState() => _SceneRenderViewState();
}

class _SceneRenderViewState extends State<SceneRenderView> {
  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF000000),
      child: Center(
        child: Text(
          'flutter_scene backend — WS0 scaffold',
          style: TextStyle(color: Color(0xFF44607A), fontSize: 13),
        ),
      ),
    );
  }
}
