import '../shared/vector3.dart';

/// A docking port on a part. Two compatible, aligned, slow-closing ports latch
/// to merge vessels — the autonomy context's docking solver drives a ship onto
/// one of these. Entity within the Vessel aggregate.
class DockingPort {
  final String id;

  /// Mount position and facing in the vessel body frame.
  final Vector3 position;
  final Vector3 facing; // unit normal the port points along

  /// Ports only latch to the same size class.
  final String sizeClass;

  /// Id of the port this one is currently latched to, if docked.
  String? latchedTo;

  DockingPort({
    required this.id,
    required this.position,
    required this.facing,
    this.sizeClass = 'standard',
    this.latchedTo,
  });

  bool get isDocked => latchedTo != null;

  /// Capture tolerances for an automated approach.
  static const double captureDistance = 0.5; // m
  static const double captureSpeed = 0.2; // m/s closing
  static const double captureAlignmentDot = 0.97; // facings anti-parallel

  bool compatibleWith(DockingPort other) =>
      sizeClass == other.sizeClass && !isDocked && !other.isDocked;
}
