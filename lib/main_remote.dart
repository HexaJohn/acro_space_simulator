// Standalone DESKTOP entry point for the Unreal-bridge remote control.
//
//   flutter run -t lib/main_remote.dart -d windows
//
// Connects to the same `bin/sim_server.dart` Unreal renders, so commands sent
// here drive the shared authoritative sim and show up in both. Kept separate
// from main.dart because it uses dart:io sockets (not available on web).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'application/snapshot/world_snapshot.dart';
import 'infrastructure/bridge/sim_remote_client.dart';

void main() => runApp(const SimRemoteApp());

class SimRemoteApp extends StatelessWidget {
  const SimRemoteApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Acro Sim — Remote',
        theme: ThemeData.dark(useMaterial3: true),
        home: const SimRemoteScreen(),
      );
}

class SimRemoteScreen extends StatefulWidget {
  const SimRemoteScreen({super.key});
  @override
  State<SimRemoteScreen> createState() => _SimRemoteScreenState();
}

class _SimRemoteScreenState extends State<SimRemoteScreen> {
  final _client = SimRemoteClient();
  final _host = TextEditingController(text: '127.0.0.1');
  final _port = TextEditingController(text: '5800');

  WorldSnapshot? _frame;
  String _vesselId = 'demo-1';
  double _throttle = 0;
  String _status = 'disconnected';

  @override
  void initState() {
    super.initState();
    _client.frames.listen((w) {
      if (mounted) setState(() => _frame = w);
    });
  }

  @override
  void dispose() {
    _client.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    try {
      setState(() => _status = 'connecting…');
      await _client.connect(_host.text.trim(), int.parse(_port.text.trim()));
      setState(() => _status = 'connected');
    } catch (e) {
      setState(() => _status = 'error: $e');
    }
  }

  Future<void> _disconnect() async {
    await _client.disconnect();
    setState(() {
      _status = 'disconnected';
      _frame = null;
    });
  }

  VesselSnapshot? get _vessel {
    final f = _frame;
    if (f == null || f.vessels.isEmpty) return null;
    return f.vessels[_vesselId] ?? f.vessels.values.first;
  }

  @override
  Widget build(BuildContext context) {
    final f = _frame;
    final v = _vessel;
    return Scaffold(
      appBar: AppBar(title: const Text('Acro Sim — Remote control')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _connectionRow(),
            const SizedBox(height: 8),
            Text(_status),
            const Divider(height: 24),
            if (f == null || v == null)
              const Expanded(child: Center(child: Text('No frames yet — connect to the server.')))
            else
              Expanded(child: _control(f, v)),
          ],
        ),
      ),
    );
  }

  Widget _connectionRow() => Row(children: [
        SizedBox(width: 160, child: TextField(controller: _host, decoration: const InputDecoration(labelText: 'Host'))),
        const SizedBox(width: 8),
        SizedBox(width: 90, child: TextField(controller: _port, decoration: const InputDecoration(labelText: 'Port'))),
        const SizedBox(width: 12),
        if (_client.isConnected)
          FilledButton.tonal(onPressed: _disconnect, child: const Text('Disconnect'))
        else
          FilledButton(onPressed: _connect, child: const Text('Connect')),
      ]);

  Widget _control(WorldSnapshot f, VesselSnapshot v) {
    final bodyRadius = f.bodies[v.body]?.radius ?? 0;
    String alt(double radius) =>
        radius < 0 ? 'escape' : '${((radius - bodyRadius) / 1000).toStringAsFixed(1)} km';
    final fuel = v.resources.where((r) => r.type == 'liquidFuel').fold<double>(0, (s, r) => s + r.amount);

    return ListView(children: [
      Row(children: [
        const Text('Vessel: '),
        DropdownButton<String>(
          value: f.vessels.containsKey(_vesselId) ? _vesselId : f.vessels.keys.first,
          items: [for (final id in f.vessels.keys) DropdownMenuItem(value: id, child: Text(id))],
          onChanged: (id) => setState(() => _vesselId = id ?? _vesselId),
        ),
        const Spacer(),
        Text('tick ${f.tick}   t=${f.epoch.toStringAsFixed(0)}s'),
      ]),
      const SizedBox(height: 8),
      _readout('Body', v.body),
      _readout('Apoapsis', alt(v.apoapsis)),
      _readout('Periapsis', alt(v.periapsis)),
      _readout('Period', v.period < 0 ? 'escape' : '${v.period.toStringAsFixed(0)} s'),
      _readout('Eccentricity', v.eccentricity.toStringAsFixed(4)),
      _readout('Mass', '${(v.mass / 1000).toStringAsFixed(1)} t'),
      _readout('Fuel', fuel.toStringAsFixed(0)),
      _readout('Comms', v.connected ? 'LINK (${(v.commDelay * 1000).toStringAsFixed(0)} ms)' : 'NO SIGNAL'),
      const Divider(height: 24),
      Text('Throttle: ${(_throttle * 100).toStringAsFixed(0)}%'),
      Slider(
        value: _throttle,
        onChanged: (x) {
          setState(() => _throttle = x);
          _client.setThrottle(v.id, x);
        },
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(onPressed: () => _client.separateStage(v.id), child: const Text('Separate stage')),
        OutlinedButton(onPressed: () => _client.setAttitude(v.id, v.vx, v.vy, v.vz), child: const Text('Prograde')),
        OutlinedButton(onPressed: () => _client.setAttitude(v.id, -v.vx, -v.vy, -v.vz), child: const Text('Retrograde')),
        OutlinedButton(onPressed: () => _client.setAttitude(v.id, v.px, v.py, v.pz), child: const Text('Radial out')),
      ]),
      const SizedBox(height: 16),
      Text('Speed: ${math.sqrt(v.vx * v.vx + v.vy * v.vy + v.vz * v.vz).toStringAsFixed(0)} m/s',
          style: Theme.of(context).textTheme.bodySmall),
    ]);
  }

  Widget _readout(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(width: 120, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
          Text(value),
        ]),
      );
}
