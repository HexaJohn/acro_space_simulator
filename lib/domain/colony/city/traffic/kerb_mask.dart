// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What masks kerb parking away from a kerb cut
/// (docs/plans/t4a-implementation.md §0 Q1, §1.7; site-access.md §7.5).
///
/// INTERFACE ONLY, on purpose. The one real implementation wraps the road
/// side's `KerbCuts.parkingBlocked(entries, side, s)` — landed at cfdc998,
/// `site_access/kerb_cuts.dart`, which reaches this branch with the next
/// merge from dev. Its asymmetric form is `(12, 3)` metres for a
/// `homeDriveway` join on each served side (a kerb car in the swing path
/// would block every departure) and `(3.25, 3.25)` for every other program,
/// and A12 checks both halves against that one function. There is NO local
/// copy of it here: until the merge, package D's kerb slots are masked by a
/// test double.
///
/// Entries and the arc must be in the SAME frame (§0 Q1): traffic works in
/// the canonical arc, so the wrapper converts a slot's travel arc and
/// right-of-travel side to the canonical index arc and side before asking.
library;

/// Whether kerb parking is blocked at a point on the road. Implemented
/// against `KerbCuts` (package F) and by test doubles until then.
abstract interface class KerbMask {
  /// Whether a kerb slot at travel arc [travelT] of road [edge], on the
  /// kerb [rightOfTravel] of that edge's travel, falls inside a live
  /// network plan's cut mask. The caller converts the slot's travel arc and
  /// side to the canonical index arc and side (§5.5).
  bool parkingBlocked(int edge, double travelT, bool rightOfTravel);
}
