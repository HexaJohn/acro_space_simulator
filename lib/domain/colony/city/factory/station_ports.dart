// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Explicit machine PORTS (docs/plans/factory-floors.md §10 item 19).
///
/// The playtest's complaint: "machine inputs & outputs need to be a little
/// more explicit — maybe instead of 'arms' for inserting and unloading
/// machines, just require belts to connect a certain way — including
/// multiple input & output connection points to make it kind of like a
/// puzzle". Before this, a belt pointing at ANY tile of a machine fed it any
/// input, and an arm on any side fed or cleared it, so a layout was a matter
/// of "touching", not of design. Now every station has fixed connection
/// points, and the user's answers fix the rules:
///
/// 1. **Arms are for chests and docks only.** They no longer feed or clear
///    machines ([armMachineNote] is the inspector's explanation).
/// 2. **Each station has one HAND port**: the marked loading point where
///    handlers (walkers, jacks, forklifts, cranes, AGVs) drop inputs and
///    pick outputs. They work there and nowhere else on the footprint.
/// 3. **Port items are fixed per recipe slot**: input port 1 takes the
///    recipe's first input, output port 1 gives its main product, output
///    port 2 its first byproduct, and so on ([recipeSlotItem]).
/// 4. **The layout is per station KIND** ([kStationPorts]), so a press is a
///    press whatever it presses, and the player learns each shape once.
///
/// **A port** is one EDGE tile of the footprint plus the direction pointing
/// out of the machine through that edge ([MachinePort.out]). The tile just
/// outside ([MachinePort.outside]) is where the connecting belt sits:
///
/// * an INPUT port is fed by a belt (or a receiving dock's open end) on
///   [MachinePort.outside] pointing INTO the machine ([MachinePort.feedDir]);
/// * an OUTPUT port pushes onto a belt on [MachinePort.outside] that does
///   not point back into the machine (straight away, or sideways as a
///   collector running past the face);
/// * the HAND port's outside tile is where a walker stands (a vehicle's
///   square covers it, a crane's hook hangs over it or the port itself).
///
/// **Frames.** Layouts are written in the station's EAST-facing local frame:
/// `lx` in `0 .. footW-1` along the facing, `ly` in `0 .. footH-1`, +y north
/// (the hall's +y), so inputs sit on the west (back) edge and the main
/// product leaves the east (front) face — the facing arrow still means
/// "flow goes this way". [portsOf] rotates them by `Placement.dir` exactly as
/// `Placement.footprint` swaps w and h. Pure integers: deterministic.
library;

import 'factory_entities.dart';
import 'factory_grid.dart';
import 'factory_item.dart';
import 'factory_recipe.dart';

/// What a port is for.
enum PortRole { input, output, hand }

/// A port in a station's east-facing local frame.
class PortSpec {
  const PortSpec(this.lx, this.ly, this.out);

  /// The footprint EDGE tile, local (see the library doc's frame).
  final int lx, ly;

  /// Out of the machine through that tile's edge (east frame).
  final Dir4 out;
}

/// A station kind's ports: [inputs] by recipe input slot, [outputs] by
/// recipe output slot (main product first, then byproducts), one [hand].
class StationPortLayout {
  const StationPortLayout(
      {required this.inputs, required this.outputs, required this.hand});
  final List<PortSpec> inputs;
  final List<PortSpec> outputs;
  final PortSpec hand;
}

// Diagrams: east-facing, north up, one character per tile. `#` body,
// `1 2 3` input ports (the arrow outside shows the feeding belt's travel),
// `a b` output ports (main, byproduct; arrow = the belt leading away),
// `H` the hand port (`v`/`^` marks where the handler stands).

/// Smelter 4×4 — ore in at the back, pig iron out the front, slag out the
/// top: the byproduct leaves on its own belt, the classic puzzle.
///
///         ^
///     # # b #
///     # # # #
///  →  1 # # a  →
///     # H # #
///       v
const _smelter = StationPortLayout(
  inputs: [PortSpec(0, 1, Dir4.west)],
  outputs: [PortSpec(3, 1, Dir4.east), PortSpec(2, 3, Dir4.north)],
  hand: PortSpec(1, 0, Dir4.south),
);

/// Furnace 4×3 — one input, a main product and a byproduct (the roaster's
/// clinker) out the top.
///
///         ^
///     # # b #
///  →  1 # # a  →
///     # H # #
///       v
const _furnace = StationPortLayout(
  inputs: [PortSpec(0, 1, Dir4.west)],
  outputs: [PortSpec(3, 1, Dir4.east), PortSpec(2, 2, Dir4.north)],
  hand: PortSpec(1, 0, Dir4.south),
);

/// Press 3×3 — straight through, offcuts out the top.
///
///       ^
///     # b #
///  →  1 # a  →
///     # H #
///       v
const _press = StationPortLayout(
  inputs: [PortSpec(0, 1, Dir4.west)],
  outputs: [PortSpec(2, 1, Dir4.east), PortSpec(1, 2, Dir4.north)],
  hand: PortSpec(1, 0, Dir4.south),
);

/// Rolling mill 5×3 — straight through, swarf out the top middle.
///
///         ^
///     # # b # #
///  →  1 # # # a  →
///     # # H # #
///         v
const _mill = StationPortLayout(
  inputs: [PortSpec(0, 1, Dir4.west)],
  outputs: [PortSpec(4, 1, Dir4.east), PortSpec(2, 2, Dir4.north)],
  hand: PortSpec(2, 0, Dir4.south),
);

/// Assembler 3×3 — three inputs from three sides (back, top, bottom), the
/// product out the front, hand port at the bottom-front corner. Feeding a
/// two-part recipe means bringing two belts in from two directions.
///
///       v
///     # 2 #
///  →  1 # a  →
///     # 3 H
///       ^ v
const _assembler = StationPortLayout(
  inputs: [
    PortSpec(0, 1, Dir4.west),
    PortSpec(1, 2, Dir4.north),
    PortSpec(1, 0, Dir4.south),
  ],
  outputs: [PortSpec(2, 1, Dir4.east)],
  hand: PortSpec(2, 0, Dir4.south),
);

/// Chemical plant 4×4 — two inputs side by side at the back, two products
/// side by side at the front.
///
///     # # # #
///  →  2 # # b  →
///  →  1 # # a  →
///     # H # #
///       v
const _chem = StationPortLayout(
  inputs: [PortSpec(0, 1, Dir4.west), PortSpec(0, 2, Dir4.west)],
  outputs: [PortSpec(3, 1, Dir4.east), PortSpec(3, 2, Dir4.east)],
  hand: PortSpec(1, 0, Dir4.south),
);

/// Packer and unpacker 3×2 — one in, one out, top row; hand port below.
///
///  →  1 # a  →
///     # H #
///       v
const _packer = StationPortLayout(
  inputs: [PortSpec(0, 1, Dir4.west)],
  outputs: [PortSpec(2, 1, Dir4.east)],
  hand: PortSpec(1, 0, Dir4.south),
);

/// Every station kind's port layout. Each gives at least as many input and
/// output ports as any registered recipe on that station needs (pinned by
/// `station_ports_test.dart` against `FactoryRecipes.forStation`).
const Map<StationKind, StationPortLayout> kStationPorts = {
  StationKind.smelter: _smelter,
  StationKind.furnace: _furnace,
  StationKind.press: _press,
  StationKind.mill: _mill,
  StationKind.assembler: _assembler,
  StationKind.chem: _chem,
  StationKind.packer: _packer,
  StationKind.unpacker: _packer,
};

/// One port of a PLACED machine, in hall tiles.
class MachinePort {
  const MachinePort(this.role, this.slot, this.tile, this.out);
  final PortRole role;

  /// Recipe slot: input index for inputs, output index for outputs (0 = the
  /// main product), 0 for the hand port.
  final int slot;

  /// The footprint edge tile.
  final TilePos tile;

  /// Out of the machine through [tile]'s edge.
  final Dir4 out;

  /// The tile just outside: where the connecting belt (or the handler)
  /// stands.
  TilePos get outside => tile.step(out);

  /// The way a belt on [outside] must point to FEED an input port.
  Dir4 get feedDir => out.opposite;

  /// Whether a belt on [outside] facing [beltDir] connects to this port: an
  /// input needs it pointing in, an output anything BUT in (a belt pointing
  /// into an output port would be pushing back against the flow).
  bool connectsBelt(Dir4 beltDir) => switch (role) {
        PortRole.input => beltDir == feedDir,
        PortRole.output => beltDir != feedDir,
        PortRole.hand => false,
      };

  @override
  String toString() => '${role.name}$slot@$tile→${out.name}';
}

/// Rotates an east-frame direction to a machine facing [dir].
Dir4 _turn(Dir4 d, Dir4 dir) => switch (dir) {
      Dir4.east => d,
      Dir4.north => d.turnCcw,
      Dir4.west => d.opposite,
      Dir4.south => d.turnCw,
    };

/// [spec]'s hall tile on a [w] × [h] (east-frame) station at [pos] facing
/// [dir]: the same rotation `Placement.footprint` applies (north = a quarter
/// turn counter-clockwise, its footprint h wide and w tall).
TilePos _place(PortSpec spec, int w, int h, TilePos pos, Dir4 dir) {
  final (ox, oy) = switch (dir) {
    Dir4.east => (spec.lx, spec.ly),
    Dir4.north => (h - 1 - spec.ly, spec.lx),
    Dir4.west => (w - 1 - spec.lx, h - 1 - spec.ly),
    Dir4.south => (spec.ly, w - 1 - spec.lx),
  };
  return TilePos(pos.x + ox, pos.y + oy);
}

/// Every port of a [station] at [pos] facing [dir]: inputs in slot order,
/// then outputs in slot order, then the hand port.
List<MachinePort> stationPorts(StationKind station, TilePos pos, Dir4 dir) {
  final l = kStationPorts[station]!;
  final w = station.footW, h = station.footH;
  MachinePort mk(PortRole role, int slot, PortSpec s) =>
      MachinePort(role, slot, _place(s, w, h, pos, dir), _turn(s.out, dir));
  return [
    for (var i = 0; i < l.inputs.length; i++)
      mk(PortRole.input, i, l.inputs[i]),
    for (var i = 0; i < l.outputs.length; i++)
      mk(PortRole.output, i, l.outputs[i]),
    mk(PortRole.hand, 0, l.hand),
  ];
}

/// The station a placement runs, or null (not a machine, or its recipe is
/// unknown — such a machine covers 1×1 and has no ports).
StationKind? _stationOf(Placement p) {
  if (p.kind != EntityKind.machine) return null;
  final rid = p.recipe;
  return rid == null ? null : FactoryRecipes.byId(rid)?.station;
}

/// The absolute ports of a placed machine (empty for anything else).
List<MachinePort> portsOf(Placement p) {
  final st = _stationOf(p);
  return st == null ? const [] : stationPorts(st, p.pos, p.dir);
}

/// [p]'s hand port, or null when it has none (not a machine).
MachinePort? handPortOf(Placement p) {
  for (final port in portsOf(p)) {
    if (port.role == PortRole.hand) return port;
  }
  return null;
}

/// What [recipe] puts through [port]: its input at the port's slot for an
/// input port, its output at the slot for an output port; null for the
/// hand port (which takes every input and gives every output) and for a
/// slot this recipe doesn't use (an unused port is inert).
ItemQty? recipeSlotItem(FactoryRecipe recipe, MachinePort port) {
  final list = switch (port.role) {
    PortRole.input => recipe.inputs,
    PortRole.output => recipe.outputs,
    PortRole.hand => const <ItemQty>[],
  };
  return port.slot < list.length ? list[port.slot] : null;
}

/// The hover text for [port] on a machine running [recipe]: "Input 1:
/// Tubes", "Output 2: Slag (byproduct)", "Hand port: workers load and
/// unload here", or "Input 3: unused".
String portLabel(FactoryRecipe? recipe, MachinePort port) {
  if (port.role == PortRole.hand) {
    return 'Hand port: handlers load and unload here';
  }
  final n = port.slot + 1;
  final head = port.role == PortRole.input ? 'Input $n' : 'Output $n';
  final q = recipe == null ? null : recipeSlotItem(recipe, port);
  if (q == null) return '$head: unused';
  final name = FactoryItems.byId(q.item)?.label ?? q.item;
  final by = port.role == PortRole.output && port.slot > 0 ? ' (byproduct)' : '';
  return '$head: $name$by';
}

/// The inspector's word on an arm whose pick or drop tile is a machine
/// (null when it touches none): arms work chests, docks, belts, staging and
/// floor piles only, so such an arm does nothing.
String? armMachineNote(Placement arm, Placement? Function(TilePos) solidAt) {
  if (arm.kind != EntityKind.arm) return null;
  final behind = arm.pos.step(arm.dir.opposite), front = arm.pos.step(arm.dir);
  final a = solidAt(behind), b = solidAt(front);
  if ((a != null && a.kind == EntityKind.machine) ||
      (b != null && b.kind == EntityKind.machine)) {
    return kArmMachineNote;
  }
  return null;
}

/// See [armMachineNote].
const String kArmMachineNote = "Arms can't feed machines — use a port";
