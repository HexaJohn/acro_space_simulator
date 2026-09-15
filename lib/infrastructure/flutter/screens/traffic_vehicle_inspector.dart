// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The route inspector (docs/plans/agent-traffic.md §13.9): the sheet a
/// click on a car opens — what it is, where it drives from and to, what it
/// is doing, how its trip is going and the roads it has still to take.
///
/// Every word is [VehicleInspection]'s, a reading of `CityAgents.describe`,
/// which is what the `vehicle=` dev hook dumps: the player and a driver
/// script see one account of a car. The sheet re-reads it while it is open,
/// because the car keeps driving, and says so when the car has arrived.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/colony/city/traffic/vehicle_inspection.dart';
import 'app_theme.dart';

/// What a Look click opens, in the order it is asked: a vehicle under the
/// pointer first, and only then the site — a car driving past a building is
/// what the player clicked, not the building behind it (§18 slice 2).
abstract final class InspectOrder {
  /// The vehicle [vehicle] finds (a handle, or null), else the site [site]
  /// finds, else null. [site] is not asked when a vehicle answers.
  static ({int? vehicle, S? site})? pick<S extends Object>(
      int? Function() vehicle, S? Function() site) {
    final v = vehicle();
    if (v != null) return (vehicle: v, site: null);
    final s = site();
    return s == null ? null : (vehicle: null, site: s);
  }
}

/// Opens the route inspector on [handle] of [city]'s agents. Completes when
/// the sheet is closed.
Future<void> showVehicleInspector({
  required BuildContext context,
  required CitySim city,
  required int handle,
}) =>
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.panel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: VehicleInspectorSheet(city: city, handle: handle),
      ),
    );

/// The inspector's body, re-read [refresh] while it is shown.
class VehicleInspectorSheet extends StatefulWidget {
  const VehicleInspectorSheet({
    super.key,
    required this.city,
    required this.handle,
    this.refresh = const Duration(seconds: 1),
  });

  final CitySim city;
  final int handle;
  final Duration refresh;

  @override
  State<VehicleInspectorSheet> createState() => _VehicleInspectorSheetState();
}

class _VehicleInspectorSheetState extends State<VehicleInspectorSheet> {
  Timer? _timer;
  VehicleInspection? _seen;

  VehicleInspection? _read() => VehicleInspection.of(
      widget.city.agents, widget.handle,
      roadName: widget.city.roadNameOf);

  @override
  void initState() {
    super.initState();
    _seen = _read();
    _timer = Timer.periodic(widget.refresh, (_) {
      if (!mounted) return;
      final now = _read();
      setState(() {
        if (now == null) {
          _gone = true;
        } else {
          _seen = now;
        }
      });
      if (now == null) _timer?.cancel();
    });
  }

  /// The car has left the road since the sheet opened: its last reading
  /// stays up, marked.
  bool _gone = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _seen;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: SingleChildScrollView(
        child: v == null
            ? Text('That vehicle has left the road.', style: AppTheme.dim)
            : _body(v),
      ),
    );
  }

  Widget _body(VehicleInspection v) {
    final lines = v.lines;
    final gone = _gone;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Icon(Icons.directions_car, color: AppTheme.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(lines[0],
                style: AppTheme.heading.copyWith(color: AppTheme.accent)),
          ),
          if (gone)
            Text('arrived', style: AppTheme.dim.copyWith(fontSize: 11)),
        ]),
        const SizedBox(height: 8),
        for (final line in lines.skip(1))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(line, style: AppTheme.body),
          ),
      ],
    );
  }
}
