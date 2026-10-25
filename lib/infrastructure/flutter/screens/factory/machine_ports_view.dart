// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What the editor shows of a machine's PORTS (docs/plans/factory-floors.md
/// §10 item 19, `station_ports.dart`).
///
/// Ports are the floor's puzzle: a belt feeds a station only at an input
/// notch, pointing in, and takes its goods only at an output notch. A rule
/// that strict is fair only if the player can SEE it, so every placed
/// machine and every machine ghost carries its notches — green inputs,
/// orange outputs, a white hand port — a connected notch lights up, and
/// hovering one names its slot ("Input 1: Tubes", "Output 2: Slag
/// (byproduct)").
///
/// The geometry lives here, as plain rects in tile units, so the painter
/// only fills them (filled geometry through its `_T` helper: Windows GLES
/// smears strokes) and tests can read the marks without a golden image.
/// "Connected" is read off the layout index alone (belt facings and dock
/// open ends), the same test the sim's `_rebuild` applies, so the light
/// and the engine agree without asking the sim.
library;

import 'package:flutter/material.dart';

import '../../../../domain/colony/city/factory/factory_entities.dart';
import '../../../../domain/colony/city/factory/factory_grid.dart';
import '../../../../domain/colony/city/factory/factory_recipe.dart';
import '../../../../domain/colony/city/factory/station_ports.dart';
import '../app_theme.dart';
import 'factory_editor_controller.dart';
import 'floor_layout_index.dart';

/// Notch colours: inputs green, outputs orange, the hand port white. A
/// connected port draws in its bright tone, an open one dimmed.
const Color kPortInput = Color(0xFF66BB6A);
const Color kPortOutput = Color(0xFFFFA726);
const Color kPortHand = Color(0xFFE8EEF4);

/// Alpha of an UNconnected input or output notch (the hand port is always
/// drawn full: it is where handlers go, belt or no belt).
const double kPortOpenAlpha = 0.45;

/// One port as drawn.
class PortMark {
  const PortMark(this.port, this.rect, this.connected, this.label);
  final MachinePort port;

  /// The notch: a strip along the port tile's outer edge, in tile units.
  final Rect rect;

  /// A belt (or dock) meets it the way the sim needs.
  final bool connected;

  /// The hover text ([portLabel]).
  final String label;

  Color get color {
    final base = switch (port.role) {
      PortRole.input => kPortInput,
      PortRole.output => kPortOutput,
      PortRole.hand => kPortHand,
    };
    if (port.role == PortRole.hand || connected) return base;
    return base.withValues(alpha: kPortOpenAlpha);
  }
}

/// The notch rect on [port]'s tile: a 0.26-tile strip along the edge it
/// faces out through, inset so neighbouring notches read apart.
Rect portNotch(MachinePort port) {
  final x = port.tile.x.toDouble(), y = port.tile.y.toDouble();
  const d = 0.26, i = 0.18;
  return switch (port.out) {
    Dir4.east => Rect.fromLTRB(x + 1 - d, y + i, x + 1, y + 1 - i),
    Dir4.west => Rect.fromLTRB(x, y + i, x + d, y + 1 - i),
    Dir4.north => Rect.fromLTRB(x + i, y + 1 - d, x + 1 - i, y + 1),
    Dir4.south => Rect.fromLTRB(x + i, y, x + 1 - i, y + d),
  };
}

/// Whether [port] is connected in the layout [ix]: an input with a belt on
/// its outside tile pointing in (or a receiving dock whose open end is the
/// port tile), an output with a belt there not pointing back in.
bool portConnected(MachinePort port, FloorLayoutIndex ix) {
  if (port.role == PortRole.hand) return false;
  final d = ix.beltDirAt(port.outside);
  if (d != null) return port.connectsBelt(d);
  if (port.role != PortRole.input) return false;
  final dock = ix.solidAt(port.outside);
  if (dock == null || dock.kind != EntityKind.receivingDock) return false;
  return port.outside.step(dock.dir) == port.tile;
}

/// Every port mark of [p] (none for anything but a machine with a known
/// recipe); [ix] decides which are connected (null: none are, as for a
/// ghost not yet laid).
List<PortMark> portMarksOf(Placement p, FloorLayoutIndex? ix) {
  final rid = p.recipe;
  final r = rid == null ? null : FactoryRecipes.byId(rid);
  if (r == null) return const [];
  return [
    for (final port in portsOf(p))
      PortMark(port, portNotch(port),
          ix != null && portConnected(port, ix), portLabel(r, port)),
  ];
}

/// The hover text for tile [t]: the port on that tile of the machine
/// there, if any.
String? portTipAt(FloorLayoutIndex ix, TilePos t) {
  final m = ix.solidAt(t);
  if (m == null || m.kind != EntityKind.machine) return null;
  for (final mark in portMarksOf(m, ix)) {
    if (mark.port.tile == t) {
      return mark.port.role == PortRole.hand || mark.connected
          ? mark.label
          : '${mark.label} — not connected';
    }
  }
  return null;
}

/// The floating "Input 1: Tubes" tip by the cursor. A sibling ABOVE the
/// canvas listener and wrapped in [IgnorePointer], so it never takes a
/// click (gesture rule: panels stay out of the canvas layer).
class PortHoverTip extends StatelessWidget {
  const PortHoverTip({super.key, required this.c});
  final FactoryEditorController c;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ValueListenableBuilder<int>(
          valueListenable: c.frame,
          builder: (context, _, _) {
            final h = c.hover;
            final tip = h == null ? null : portTipAt(c.index, h);
            if (h == null || tip == null) return const SizedBox.shrink();
            final at = c.tileToLocal(h.x + 1.0, h.y + 1.0);
            return Stack(children: [
              Positioned(
                left: at.dx + 6,
                top: at.dy - 30,
                child: Container(
                  key: const Key('port-tip'),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: AppTheme.panelBox(),
                  child: Text(tip, style: AppTheme.body),
                ),
              ),
            ]);
          },
        ),
      );
}
