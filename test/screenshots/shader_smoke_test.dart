// Smoke test: does the atmosphere fragment shader compile + load + draw under
// `flutter test`? If this passes, the screenshot harness can verify the shader;
// if it throws, shaders aren't available in the test engine and we fall back.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('atmosphere shader loads and draws', (t) async {
    const size = Size(400, 300);
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    late ui.FragmentProgram program;
    await t.runAsync(() async {
      program = await ui.FragmentProgram.fromAsset('shaders/atmosphere.frag');
    });
    final shader = program.fragmentShader();
    // uSize(2), uCenter(3), uRa(1), uFocal(1), uTint(3), uWarm(3), uSun(3),
    // uStrength(1) = 17 floats.
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, 0.0); // centre x (radii)
    shader.setFloat(3, 0.0); // centre y
    shader.setFloat(4, 3.0); // centre z (3 radii in front)
    shader.setFloat(5, 1.05); // uRa
    shader.setFloat(6, 260.0); // focal
    shader.setFloat(7, 0.44); shader.setFloat(8, 0.71); shader.setFloat(9, 1.0); // tint
    shader.setFloat(10, 1.0); shader.setFloat(11, 0.62); shader.setFloat(12, 0.36); // warm
    shader.setFloat(13, 0.0); shader.setFloat(14, 0.0); shader.setFloat(15, 1.0); // sun
    shader.setFloat(16, 1.0); // strength

    final key = GlobalKey();
    await t.pumpWidget(MaterialApp(
      home: RepaintBoundary(
        key: key,
        child: CustomPaint(
          size: size,
          painter: _ShaderPainter(shader),
        ),
      ),
    ));
    await t.pump();

    await t.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.0);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('test_out/shader_smoke.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png!.buffer.asUint8List());
    });
  });
}

class _ShaderPainter extends CustomPainter {
  final ui.FragmentShader shader;
  _ShaderPainter(this.shader);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF000000));
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
