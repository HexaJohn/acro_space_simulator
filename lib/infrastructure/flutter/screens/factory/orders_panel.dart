// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The Orders panel and the dock card (docs/plans/factory-floors.md §10
/// items 4 and 11): where a floor on orders is RUN — suppliers with their
/// stock, price and lead time; placing a one-off or recurring order;
/// active orders and schedules; trucks on the road with their ETA; and the
/// outbound pickups. Modelled on the spaceport's delivery editor (a good,
/// an amount, one-time or recurring), with the floor's own docks as pads.
///
/// Both are shown beside the canvas, never inside its Listener (the same
/// rule as every panel here: a click on a button must not also be a click
/// on the floor). The number fields are ordinary [TextField]s inside the
/// screen's Focus: its `_typing()` guard keeps R, X, Ctrl+Z … from firing
/// editor shortcuts while one has the keyboard.
library;

import 'package:flutter/material.dart';

import '../../../../domain/colony/city/factory/dock_logistics.dart';
import '../../../../domain/colony/city/factory/factory_entities.dart';
import '../../../../domain/colony/city/factory/factory_floor.dart';
import '../../../../domain/colony/city/factory/factory_item.dart';
import '../../../../domain/colony/city/factory/supply_world.dart';
import '../app_theme.dart';
import 'factory_editor_controller.dart';

const double kOrdersPanelWidth = 420;

String _label(String id) => FactoryItems.byId(id)?.label ?? id;

String _eta(double s) {
  if (s <= 0) return 'now';
  if (s < 90) return '${s.toStringAsFixed(0)} s';
  if (s < 5400) return '${(s / 60).toStringAsFixed(0)} min';
  return '${(s / 3600).toStringAsFixed(1)} h';
}

String _money(double v) => v.abs() >= 1000
    ? '${(v / 1000).toStringAsFixed(1)}k'
    : v.toStringAsFixed(0);

/// The logistics of [c]'s floor, when it runs on orders (null: a sim
/// without them, e.g. a colony floor today or a test fake).
FloorLogistics? logisticsOf(FactoryEditorController c) {
  final s = c.sim;
  return s is FactoryFloor ? s.logistics : null;
}

/// The docks of [kind] on the floor, by id.
List<Placement> _docks(FactoryEditorController c, EntityKind kind) => [
      for (final p in c.sim.blueprint.placements)
        if (p.kind == kind) p,
    ]..sort((a, b) => a.id.compareTo(b.id));

String _dockName(Placement p) =>
    '#${p.id}${p.item == null ? '' : ' ${_label(goodOf(p.item!))}'}';

class OrdersPanel extends StatefulWidget {
  const OrdersPanel({super.key, required this.c, required this.onClose});
  final FactoryEditorController c;
  final VoidCallback onClose;

  @override
  State<OrdersPanel> createState() => _OrdersPanelState();
}

enum _Repeat { once, every, weekly }

class _OrdersPanelState extends State<OrdersPanel> {
  String? _supplier;
  String? _good;
  int? _dock;
  bool _inTrucks = true;
  _Repeat _repeat = _Repeat.once;
  final Set<int> _days = {0, 1, 2, 3, 4};
  final TextEditingController _qty = TextEditingController(text: '1');
  final TextEditingController _everyMin = TextEditingController(text: '30');
  final TextEditingController _time = TextEditingController(text: '06:00');
  final TextEditingController _pickupN = TextEditingController(text: '6');
  String? _error;

  @override
  void dispose() {
    _qty.dispose();
    _everyMin.dispose();
    _time.dispose();
    _pickupN.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lg = logisticsOf(widget.c);
    return Container(
      key: const Key('orders-panel'),
      decoration: AppTheme.panelBox(border: AppTheme.accent),
      padding: const EdgeInsets.all(10),
      child: ValueListenableBuilder<int>(
        valueListenable: widget.c.live,
        builder: (context, _, _) => lg == null
            ? _frame(const [
                Text('This floor is not on orders.', style: AppTheme.dim),
              ])
            : _frame(_body(lg)),
      ),
    );
  }

  Widget _frame(List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const Expanded(child: Text('ORDERS', style: AppTheme.heading)),
            IconButton(
              key: const Key('orders-close'),
              tooltip: 'Close',
              onPressed: widget.onClose,
              icon: const Icon(Icons.close, color: AppTheme.text, size: 18),
            ),
          ]),
          Expanded(
            child: ListView(children: children),
          ),
        ],
      );

  List<Widget> _body(FloorLogistics lg) {
    final w = lg.world;
    return [
      _Toggle(
        key: const Key('unlimited-supply'),
        title: 'Unlimited supply (sandbox)',
        subtitle: w.usedUnlimited
            ? 'Docks pull goods instantly. This run is marked as using it.'
            : 'Off: goods come only by truck, from finite suppliers.',
        value: w.unlimited,
        onChanged: (v) => setState(() => w.setUnlimited(v)),
      ),
      if (!w.colony)
        Text('Spent ${_money(w.spent)} · earned ${_money(w.earned)} credits'
            '${lg.upgradeCapexOre > 0 ? ' · dock upgrades ${lg.upgradeCapexOre.toStringAsFixed(1)} ore' : ''}',
            key: const Key('orders-money'), style: AppTheme.dim),
      const SizedBox(height: 8),
      const Text('NEW ORDER', style: AppTheme.heading),
      ..._newOrder(lg),
      const Divider(),
      Row(children: [
        const Expanded(child: Text('ACTIVE ORDERS', style: AppTheme.heading)),
        TextButton(
          key: const Key('orders-stock-all'),
          onPressed: () => setState(() => standingOrdersForAllDocks(widget.c)),
          child: const Text('Stock every dock'),
        ),
      ]),
      ..._activeOrders(lg),
      const Divider(),
      const Text('TRUCKS', style: AppTheme.heading),
      ..._trucks(lg),
      const Divider(),
      const Text('OUTBOUND', style: AppTheme.heading),
      ..._outbound(lg),
      const Divider(),
      const Text('SUPPLIERS', style: AppTheme.heading),
      for (final s in w.suppliers.values) _supplierRow(lg, s),
      if (w.contracts.isNotEmpty) ...[
        const Divider(),
        const Text('CONTRACTS', style: AppTheme.heading),
        for (final k in w.contracts.values)
          Text(
              '${k.customer}: ${_label(k.good)} '
              '${k.deliveredThisWeek.toStringAsFixed(0)} / '
              '${k.unitsPerWeek.toStringAsFixed(0)} this week · '
              '${k.payPerUnit.toStringAsFixed(1)} each · met ${k.weeksMet}, '
              'missed ${k.weeksMissed}',
              style: AppTheme.dim),
        const Text('Anything else sells on the spot market.',
            style: AppTheme.dim),
      ],
      if (lg.recent.isNotEmpty) ...[
        const Divider(),
        const Text('RECENT', style: AppTheme.heading),
        for (final e in lg.recent.reversed.take(6))
          Text('dock #${e.dock}: ${e.text}', style: AppTheme.dim),
      ],
    ];
  }

  Widget _supplierRow(FloorLogistics lg, Supplier s) {
    final w = lg.world;
    final lines = s.colonyStock
        ? 'whatever the colony stores hold'
        : [
            for (final l in s.lines.values)
              '${_label(l.good)} ${(l.stock / packUnitsOf(l.good)).floor()} '
                  'plt @ ${w.priceAt(s, l.good) * packUnitsOf(l.good) >= 100 ? (w.priceAt(s, l.good) * packUnitsOf(l.good)).toStringAsFixed(0) : (w.priceAt(s, l.good) * packUnitsOf(l.good)).toStringAsFixed(1)}',
          ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: s.name, style: AppTheme.body),
          TextSpan(
              text: '  lead ${_eta(s.leadTimeS)} · ${s.truckPallets} plt/truck\n'
                  '$lines',
              style: AppTheme.dim),
        ]),
        key: Key('supplier-${s.id}'),
      ),
    );
  }

  List<Widget> _newOrder(FloorLogistics lg) {
    final w = lg.world;
    final sups = w.suppliers.values.toList();
    final sup = w.suppliers[_supplier] ?? (sups.isEmpty ? null : sups.first);
    final goods = sup == null
        ? <String>[]
        : sup.colonyStock
            ? <String>{
                for (final d in _docks(widget.c, EntityKind.receivingDock))
                  if (d.item != null) goodOf(d.item!),
              }.toList()
            : sup.lines.keys.toList();
    goods.sort();
    final good = goods.contains(_good) ? _good : (goods.isEmpty ? null : goods.first);
    final docks = _docks(widget.c, EntityKind.receivingDock);
    final matching = [
      for (final d in docks)
        if (good != null && d.item != null && goodOf(d.item!) == good) d,
    ];
    final targets = matching.isEmpty ? docks : matching;
    final dock = targets.any((d) => d.id == _dock)
        ? _dock
        : (targets.isEmpty ? null : targets.first.id);
    return [
      DropdownButton<String>(
        key: const Key('order-supplier'),
        isExpanded: true,
        value: sup?.id,
        items: [
          for (final s in sups)
            DropdownMenuItem(value: s.id, child: Text(s.name)),
        ],
        onChanged: (v) => setState(() => _supplier = v),
      ),
      DropdownButton<String>(
        key: const Key('order-good'),
        isExpanded: true,
        value: good,
        hint: const Text('No goods'),
        items: [
          for (final g in goods)
            DropdownMenuItem(
                value: g,
                child: Text('${_label(g)} (${naturalPackOf(g)?.pickerLabel ?? g})',
                    overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (v) => setState(() => _good = v),
      ),
      DropdownButton<int>(
        key: const Key('order-dock'),
        isExpanded: true,
        value: dock,
        hint: const Text('Place a receiving dock first'),
        items: [
          for (final d in targets)
            DropdownMenuItem(value: d.id, child: Text('Dock ${_dockName(d)}')),
        ],
        onChanged: (v) => setState(() => _dock = v),
      ),
      if (matching.isEmpty && docks.isNotEmpty && good != null)
        Text('No dock is set to ${_label(good)}: its goods would sit in the '
            'loading area.', style: AppTheme.dim.copyWith(color: AppTheme.warn)),
      Row(children: [
        SizedBox(
          width: 60,
          child: TextField(
            key: const Key('order-qty'),
            controller: _qty,
            keyboardType: TextInputType.number,
            style: AppTheme.body,
            decoration: const InputDecoration(isDense: true),
          ),
        ),
        const SizedBox(width: 8),
        ChoiceChip(
            label: const Text('trucks'),
            selected: _inTrucks,
            onSelected: (_) => setState(() => _inTrucks = true)),
        const SizedBox(width: 4),
        ChoiceChip(
            label: const Text('pallets'),
            selected: !_inTrucks,
            onSelected: (_) => setState(() => _inTrucks = false)),
      ]),
      Wrap(spacing: 4, children: [
        for (final (r, t) in const [
          (_Repeat.once, 'One-off'),
          (_Repeat.every, 'Every N min'),
          (_Repeat.weekly, 'Weekly'),
        ])
          ChoiceChip(
              key: Key('order-repeat-${r.name}'),
              label: Text(t),
              selected: _repeat == r,
              onSelected: (_) => setState(() => _repeat = r)),
      ]),
      if (_repeat == _Repeat.every)
        Row(children: [
          const Text('every ', style: AppTheme.body),
          SizedBox(
            width: 60,
            child: TextField(
              key: const Key('order-every'),
              controller: _everyMin,
              keyboardType: TextInputType.number,
              style: AppTheme.body,
              decoration: const InputDecoration(isDense: true),
            ),
          ),
          const Text(' min of floor time', style: AppTheme.body),
        ]),
      if (_repeat == _Repeat.weekly) ...[
        Wrap(spacing: 2, children: [
          for (var d = 0; d < 7; d++)
            FilterChip(
              visualDensity: VisualDensity.compact,
              label: Text(const ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'][d]),
              selected: _days.contains(d),
              onSelected: (on) =>
                  setState(() => on ? _days.add(d) : _days.remove(d)),
            ),
        ]),
        Row(children: [
          const Text('at ', style: AppTheme.body),
          SizedBox(
            width: 70,
            child: TextField(
              key: const Key('order-time'),
              controller: _time,
              style: AppTheme.body,
              decoration: const InputDecoration(isDense: true),
            ),
          ),
          const Text(' (floor clock: day 1 starts Mon 06:00)',
              style: AppTheme.dim),
        ]),
      ],
      if (_error != null)
        Text(_error!, style: AppTheme.dim.copyWith(color: AppTheme.warn)),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton(
          key: const Key('order-place'),
          onPressed: sup == null || good == null || dock == null
              ? null
              : () => _place(lg, sup, good, dock),
          child: const Text('Place order'),
        ),
      ),
    ];
  }

  void _place(FloorLogistics lg, Supplier sup, String good, int dock) {
    final q = int.tryParse(_qty.text.trim());
    if (q == null || q <= 0) {
      setState(() => _error = 'Quantity must be a whole number above 0');
      return;
    }
    OrderSchedule? sch;
    switch (_repeat) {
      case _Repeat.once:
        sch = null;
      case _Repeat.every:
        final m = double.tryParse(_everyMin.text.trim());
        if (m == null || m <= 0) {
          setState(() => _error = 'Interval must be above 0 minutes');
          return;
        }
        sch = OrderSchedule.every(m * 60);
      case _Repeat.weekly:
        final parts = _time.text.trim().split(':');
        final h = int.tryParse(parts.first);
        final mi = parts.length > 1 ? int.tryParse(parts[1]) : 0;
        if (h == null || mi == null || h < 0 || h > 23 || mi < 0 || mi > 59 ||
            _days.isEmpty) {
          setState(() => _error = 'Pick days and a time like 06:00');
          return;
        }
        sch = OrderSchedule.weekly({..._days}, h * 3600.0 + mi * 60);
    }
    final packs = _inTrucks ? q * sup.truckPallets : q;
    lg.placeOrder(
        supplier: sup.id, good: good, packs: packs, dock: dock, schedule: sch);
    setState(() => _error = null);
  }

  List<Widget> _activeOrders(FloorLogistics lg) {
    final act = [for (final o in lg.orders.values) if (o.active) o];
    if (act.isEmpty) {
      return const [Text('No orders. Docks get nothing.', style: AppTheme.dim)];
    }
    return [
      for (final o in act)
        Row(key: Key('order-row-${o.id}'), children: [
          Expanded(
            child: Text(
                '${o.packs} plt ${_label(o.good)} → dock #${o.dock} · '
                '${o.schedule?.describe() ?? 'one-off'}'
                '${o.recurring ? ' · next in ${_eta(o.nextAt - lg.now)}' : ''}'
                '${o.lastShort > 0 ? ' · ${o.lastShort} short last time' : ''}',
                style: AppTheme.body),
          ),
          IconButton(
            key: Key('order-cancel-${o.id}'),
            tooltip: 'Cancel',
            onPressed: () => setState(() => lg.cancelOrder(o.id)),
            icon: const Icon(Icons.cancel_outlined,
                color: AppTheme.danger, size: 16),
          ),
        ]),
    ];
  }

  List<Widget> _trucks(FloorLogistics lg) {
    final ts = lg.trucks.values.toList();
    if (ts.isEmpty) return const [Text('No trucks.', style: AppTheme.dim)];
    return [
      for (final t in ts)
        Text(
            '${t.inbound ? 'In' : 'Pickup'} → dock #${t.dock}: '
            '${switch (t.state) {
              TruckState.enRoute => 'ETA ${_eta(t.eta - lg.now)}',
              TruckState.waiting => 'waiting for the dock',
              TruckState.docked => t.inbound
                  ? 'at the door, unloading'
                  : 'loading',
            }}'
            '${t.inbound ? ' · ${t.cargo.toMap().entries.map((e) => '${e.value} ${_label(e.key)}').join(', ')}' : ''}',
            key: Key('truck-${t.id}'),
            style: AppTheme.body),
    ];
  }

  List<Widget> _outbound(FloorLogistics lg) {
    final ships = _docks(widget.c, EntityKind.shippingDock);
    if (ships.isEmpty) {
      return const [Text('No shipping dock.', style: AppTheme.dim)];
    }
    return [
      for (final d in ships) ...[
        Text(
            'Dock #${d.id}: ${slotsIn(lg.bay(d.id).area)} / '
            '$kLoadingAreaSlots pallets ready'
            '${[for (final r in lg.pickups.values) if (r.active && r.dock == d.id) r.describe()].map((s) => ' · $s').join()}',
            style: AppTheme.body),
        Wrap(spacing: 4, children: [
          TextButton(
            key: Key('pickup-now-${d.id}'),
            onPressed: () => setState(() => lg.callPickup(d.id)),
            child: const Text('Call a truck now'),
          ),
          TextButton(
            key: Key('pickup-rule-${d.id}'),
            onPressed: () {
              final n = int.tryParse(_pickupN.text.trim());
              if (n == null || n <= 0) return;
              setState(() {
                for (final r in lg.pickups.values) {
                  if (r.dock == d.id) r.active = false;
                }
                lg.addPickup(dock: d.id, whenPallets: n);
              });
            },
            child: const Text('Auto: when N ready'),
          ),
        ]),
      ],
      Row(children: [
        const Text('N = ', style: AppTheme.body),
        SizedBox(
          width: 50,
          child: TextField(
            key: const Key('pickup-n'),
            controller: _pickupN,
            keyboardType: TextInputType.number,
            style: AppTheme.body,
            decoration: const InputDecoration(isDense: true),
          ),
        ),
        const Text(' pallets', style: AppTheme.body),
      ]),
    ];
  }
}

/// Gives every receiving dock with no active order a standing one: one
/// truck every 30 minutes of floor time from the first supplier stocking
/// its good, and every shipping dock without a rule an automatic pickup at
/// 6 pallets. The quick way to get a template floor running on orders.
void standingOrdersForAllDocks(FactoryEditorController c) {
  final lg = logisticsOf(c);
  if (lg == null) return;
  for (final d in _docks(c, EntityKind.receivingDock)) {
    final item = d.item;
    if (item == null) continue;
    if (lg.orders.values.any((o) => o.active && o.dock == d.id)) continue;
    final good = goodOf(item);
    Supplier? sup;
    for (final s in lg.world.suppliers.values) {
      if (s.colonyStock || s.lines.containsKey(good)) {
        sup = s;
        break;
      }
    }
    if (sup == null) continue;
    lg.placeOrder(
        supplier: sup.id,
        good: good,
        packs: sup.truckPallets,
        dock: d.id,
        schedule: const OrderSchedule.every(1800));
  }
  for (final d in _docks(c, EntityKind.shippingDock)) {
    if (lg.pickups.values.any((r) => r.active && r.dock == d.id)) continue;
    lg.addPickup(dock: d.id, whenPallets: 6);
  }
}

/// The inspector's dock card: its upgrades, its truck, what is coming,
/// its orders or pickups, and its loading area.
class DockLogisticsCard extends StatelessWidget {
  const DockLogisticsCard({super.key, required this.c, required this.dock});
  final FactoryEditorController c;
  final Placement dock;

  @override
  Widget build(BuildContext context) {
    final lg = logisticsOf(c);
    if (lg == null) return const SizedBox.shrink();
    final recv = dock.kind == EntityKind.receivingDock;
    final b = lg.bay(dock.id);
    final at = lg.dockedAt(dock.id);
    final coming = lg.incomingTo(dock.id);
    final area = b.area.toMap();
    final rules = recv
        ? [
            for (final o in lg.orders.values)
              if (o.active && o.dock == dock.id)
                '${o.packs} plt ${_label(o.good)} · ${o.schedule?.describe() ?? 'one-off'}',
          ]
        : [
            for (final r in lg.pickups.values)
              if (r.active && r.dock == dock.id) r.describe(),
          ];
    return Padding(
      key: const Key('dock-card'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(lg.world.unlimited ? 'UNLIMITED SUPPLY' : 'TRUCKS',
              style: AppTheme.heading),
          if (recv) ...[
            _Toggle(
              key: const Key('dock-conveyor'),
              title: 'Dock conveyor',
              subtitle: 'Unloads trucks without handlers · '
                  '${kDockConveyorCapexOre.toStringAsFixed(1)} ore',
              value: b.conveyor,
              onChanged: (v) => lg.setConveyor(dock.id, v),
            ),
            _Toggle(
              key: const Key('dock-unpacker'),
              title: 'Unpacker',
              subtitle:
                  'Breaks pallets down in ${kUnpackerBreakdownS}s, not '
                  '${kHandBreakdownS.toStringAsFixed(0)}s by hand · '
                  '${kDockUnpackerCapexOre.toStringAsFixed(1)} ore',
              value: b.unpacker,
              onChanged: (v) => lg.setUnpacker(dock.id, v),
            ),
          ],
          Text(
              at == null
                  ? 'No truck at the door'
                  : at.inbound
                      ? 'Truck at the door: '
                          '${at.cargo.toMap().entries.map((e) => '${e.value} ${_label(e.key)}').join(', ')}'
                          '${b.conveyor ? '' : ' (handlers unload it)'}'
                      : 'Pickup truck loading',
              key: const Key('dock-truck'),
              style: AppTheme.body),
          for (final t in coming.take(3))
            Text(
                '${t.inbound ? 'Truck' : 'Pickup'} '
                '${t.state == TruckState.waiting ? 'waiting outside' : 'in ${_eta(t.eta - lg.now)}'}',
                style: AppTheme.dim),
          for (final r in rules) Text(r, style: AppTheme.dim),
          if (rules.isEmpty && !lg.world.unlimited)
            Text(recv ? 'No orders: open Orders to buy goods for this dock.'
                : 'No pickup: open Orders to schedule one.',
                style: AppTheme.dim.copyWith(color: AppTheme.warn)),
          Text('Loading area: ${slotsIn(b.area)} / $kLoadingAreaSlots pallets',
              style: AppTheme.body),
          for (final e in area.entries)
            Text('  ${_label(e.key)}: ${e.value}', style: AppTheme.mono),
        ],
      ),
    );
  }
}

/// A switch with a title and a note. Not a ListTile: the side panel's
/// coloured box would hide a ListTile's ink (and Flutter asserts on it).
class _Toggle extends StatelessWidget {
  const _Toggle(
      {super.key,
      required this.title,
      required this.subtitle,
      required this.value,
      required this.onChanged});
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Row(children: [
        Switch(value: value, onChanged: onChanged),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTheme.body),
              Text(subtitle, style: AppTheme.dim),
            ],
          ),
        ),
      ]));
}
