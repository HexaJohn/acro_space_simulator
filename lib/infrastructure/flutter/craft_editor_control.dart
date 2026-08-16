// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Programmatic control of a live craft editor, for the dev harness.
///
/// Same shape and purpose as `ScatterLabControl` and `SimViewControl`: the host
/// registers its setters while mounted, and `main_craft_dev.dart` exposes them
/// over the VM service so a script can pose the camera, hold a part, assemble a
/// reference craft and photograph the result without a human driving the mouse.
///
/// ## Why the editor needs one at all
///
/// Three claims in this feature can only be settled by a REAL rendered frame,
/// and every one of them is invisible to the headless suite:
///
///   * that each `.fsceneb` bake lands at the size `PartDef.modelScale` claims.
///     The catalog and the render-side registry disagreed once already (2.40 m
///     per model unit against 1.70), and a wrong scale does not fail anything —
///     the craft still flies, because physics never reads the art. It shows up
///     as legs that miss their outriggers by exactly the ratio of the error.
///   * that a ghost lands where its 2D marker said it would. The overlay and
///     the scene graph are two independent transform chains fed by one camera;
///     they agree by construction or they do not agree at all.
///   * that the `Transform.flip` and the overlay describe the same world. A
///     mirrored image is almost invisible on a rocket, because everything on
///     one is symmetric about its axis.
///
/// This project's recorded practice for all three is to LOOK at the output
/// rather than reason about it, which needs a live view that a script can put
/// into a known state and then screenshot.
///
/// ## Contract
///
/// [apply] takes only the knobs the caller names; anything left null keeps
/// whatever is in force, so a sweep can move one axis at a time and accumulate.
/// It returns a future because opening and saving a craft go through
/// `SharedPreferences` — the one place this differs from `ScatterLabControl`,
/// whose knobs are all synchronous. Await it before reading [status] or the
/// reply describes the state before the change.
///
/// [status] is the whole editor as plain JSON-able values, so a capture script
/// can assert what it just photographed instead of trusting that its request
/// landed.
class CraftEditorControl {
  CraftEditorControl._();

  static final CraftEditorControl instance = CraftEditorControl._();

  /// Set by the live harness while mounted; null when no editor is on screen.
  ///
  /// * [azimuth], [elevation], [distanceM] — turntable pose, radians and metres
  ///   in the craft body frame. Clamped by `CraftEditorCamera`.
  /// * [frame] — fit the whole craft, as the `F` key does. Applied AFTER any
  ///   pose above, so `frame=true` with an azimuth reframes at that spin.
  /// * [holdPartId] — put a catalog part on the cursor. Matched leniently (see
  ///   `main_craft_dev.dart`) because these ids are typed by hand into a URL.
  /// * [drop] — clear the held part, as `Esc` does.
  /// * [symmetryCount] / [mirror] — the `1`/`2`/`4` and `M` chips.
  /// * [showNodes] / [showBalance] — the `G` and `C` overlays. Turn both off to
  ///   photograph the ART alone, which is what a scale check wants.
  /// * [build] — assemble a named reference craft from scratch, replacing
  ///   whatever is there. `lem` is the flown Apollo Lunar Module.
  /// * [clear], [undo], [redo] — the editing verbs a sweep needs to get back to
  ///   a known state without restarting the app.
  /// * [loadSlot] / [saveSlot] — named craft slots, through the same store the
  ///   shipping screen uses.
  Future<void> Function({
    double? azimuth,
    double? elevation,
    double? distanceM,
    bool? frame,
    String? holdPartId,
    bool? drop,
    int? symmetryCount,
    bool? mirror,
    bool? showNodes,
    bool? showBalance,
    String? build,
    bool? clear,
    bool? undo,
    bool? redo,
    String? loadSlot,
    String? saveSlot,
  })? apply;

  /// Current state, for assertions and for reading back what a capture shows.
  Map<String, Object?> Function()? status;
}
