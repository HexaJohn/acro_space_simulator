// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// MOVED: the canonical definition now lives in the shared engine package
// (flintlock_engine, src/sim/). This shim re-exports it so acro's existing
// imports of 'domain/shared/vector3.dart' keep working unchanged. See
// docs/plans/engine-extraction.md.
export 'package:flintlock_engine/flintlock_engine.dart' show Vector3;
