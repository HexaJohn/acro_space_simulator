// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The calendar the colony economy keeps (docs/plans/factory-floors.md §3).
///
/// Prices, wages and P&L are all per COLONY second — the time
/// `CitySim.advance` integrates and a factory floor's ledger counts. The
/// colony compresses a reference Earth day into 120 s of play
/// (`CitySim.dayLengthSec`'s `refDaySeconds`), so anything quoted per real
/// day (what a person breathes, what housing rents for) is divided by
/// [kColonyDaySec] to become a per-colony-second rate, and a game-year — the
/// unit a firm's payback horizon is stated in — is 365.25 of those days.
///
/// The economy uses the EARTH reference day everywhere, not the host body's
/// own day length: a firm's patience and a colonist's appetite are human
/// clocks, and a Martian sol should not make bread dearer than a lunar
/// fortnight makes it cheap.
library;

/// Colony seconds in one reference (Earth) day — `CitySim.dayLengthSec`'s
/// `refDaySeconds`.
const double kColonyDaySec = 120;

/// Colony seconds in one game-year: 365.25 reference days.
const double kGameYearSec = 365.25 * kColonyDaySec;
