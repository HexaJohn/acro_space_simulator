// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

import 'scaled_transform.dart';

/// Identity of a coordinate frame in the nested frame tree.
///
/// Frames form a hierarchy (galactic -> star-system inertial -> body-centred
/// inertial -> body-fixed rotating -> vessel body). Physics for a vessel runs
/// in the inertial frame of its dominant body, where magnitudes are small. A
/// [ReferenceFrame] resolves to a [ScaledTransform] relative to its parent.
enum FrameKind {
  galactic,
  systemInertial,
  bodyInertial, // centred on a celestial body, non-rotating
  bodyFixed, // rotates with the body's surface
  vesselBody, // centred on a vessel, aligned to its attitude
}

class FrameId {
  final String value;
  const FrameId(this.value);

  @override
  bool operator ==(Object other) => other is FrameId && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => 'FrameId($value)';
}

/// A node in the frame tree: its kind, its parent, and the transform that maps
/// points from this frame into the parent frame *at a given epoch*. Rotating
/// frames recompute [parentTransform] each tick from the body's rotation.
class ReferenceFrame {
  final FrameId id;
  final FrameKind kind;
  final FrameId? parent;
  final ScaledTransform parentTransform;

  const ReferenceFrame({
    required this.id,
    required this.kind,
    required this.parent,
    required this.parentTransform,
  });

  bool get isRoot => parent == null;

  @override
  String toString() => 'ReferenceFrame($id, $kind, parent:$parent)';
}
