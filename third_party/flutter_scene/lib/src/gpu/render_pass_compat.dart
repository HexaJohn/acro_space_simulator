import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;

// PATCHED (acro_space_simulator): these helpers used to reach the render pass
// through `(pass as dynamic)` inside try/catch, probing for older flutter_gpu
// signatures (`bindVertexBuffer(view, vertexCount)`, `draw()` with no count).
// A dynamic invocation is a runtime member lookup plus argument boxing on
// every call, and the colour pass makes several per draw. The pinned
// flutter_gpu (render_pass.dart: `bindVertexBuffer(BufferView, {int slot})`,
// `bindIndexBuffer(BufferView, IndexType)`, `draw(int, {int instanceCount})`,
// `drawIndexed(int, {int instanceCount})`) and the vendored web and stub
// backends all share these exact signatures, so the calls are made directly.
// The helper names and parameters are unchanged so callers need no edits; the
// count parameters that only the legacy signatures consumed are kept for that
// reason and are otherwise unused.

void bindVertexBufferCompat(
  gpu.RenderPass pass,
  gpu.BufferView bufferView,
  int vertexCount, {
  int slot = 0,
}) {
  pass.bindVertexBuffer(bufferView, slot: slot);
}

void bindIndexBufferCompat(
  gpu.RenderPass pass,
  gpu.BufferView bufferView,
  gpu.IndexType indexType,
  int indexCount,
) {
  pass.bindIndexBuffer(bufferView, indexType);
}

void drawCompat(gpu.RenderPass pass, int vertexCount, {int instanceCount = 1}) {
  pass.draw(vertexCount, instanceCount: instanceCount);
}

void drawIndexedCompat(
  gpu.RenderPass pass,
  int indexCount, {
  int instanceCount = 1,
}) {
  pass.drawIndexed(indexCount, instanceCount: instanceCount);
}
