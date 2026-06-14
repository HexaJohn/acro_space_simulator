import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, KeyEvent, KeyDownEvent, KeyUpEvent;

import '../../domain/autonomy/pilot_input.dart';

import '../../adapters/events/in_memory_event_bus.dart';
import '../../adapters/presenters/top_down_snapshot.dart';
import '../../adapters/repositories/in_memory_repositories.dart';
import '../../adapters/repositories/in_memory_world_repositories.dart';
import '../../application/persistence/game_state_codec.dart';
import '../../application/ports/compute_port.dart';
import '../../application/usecases/advance_simulation_tick.dart';
import '../../domain/orbits/soi_transition_service.dart';
import '../../domain/science/experiment.dart';
import '../../domain/science/research_ledger.dart';
import '../../domain/science/tech_tree.dart';
import '../../domain/simulation/simulation_clock.dart';
import '../../domain/vessel/vessel.dart';
import '../sample_world.dart';
import 'top_down_painter.dart';

/// Infrastructure widget: owns the game loop (a Flutter [Ticker]), drives the
/// [AdvanceSimulationTick] use case, and repaints the [TopDownPainter] from a
/// fresh snapshot each frame. This is the ONLY place Flutter touches the sim;
/// everything it calls is a port/use case.
class SimulationView extends StatefulWidget {
  const SimulationView({super.key});

  @override
  State<SimulationView> createState() => _SimulationViewState();
}

class _SimulationViewState extends State<SimulationView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final SimulationClock _clock;
  late final AdvanceSimulationTick _advance;
  late final TopDownSnapshotPresenter _presenter;
  late final InMemoryVesselRepository _vessels;
  late final InMemoryColonyRepository _colonies;
  late final InMemoryDepositRepository _deposits;
  late final ResearchLedger _research;
  late final VesselId _focus;

  final GameStateCodec _codec = const GameStateCodec();
  String? _savedGame; // in-memory save slot (file IO is a separate concern)

  // ---- Manual 3D piloting + camera ----
  static const PilotController _pilot = PilotController();
  final FocusNode _keyFocus = FocusNode();
  final Set<LogicalKeyboardKey> _keysDown = {};
  // ignore: prefer_final_fields
  bool _manualControl = false; // when true, autopilot for the focus vessel is off

  /// Build a PilotInput from the currently-held keys.
  PilotInput _readPilotInput() {
    double axis(LogicalKeyboardKey neg, LogicalKeyboardKey pos) =>
        (_keysDown.contains(pos) ? 1.0 : 0.0) - (_keysDown.contains(neg) ? 1.0 : 0.0);
    return PilotInput(
      pitch: axis(LogicalKeyboardKey.keyS, LogicalKeyboardKey.keyW),
      yaw: axis(LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyD),
      roll: axis(LogicalKeyboardKey.keyQ, LogicalKeyboardKey.keyE),
      throttle: _keysDown.contains(LogicalKeyboardKey.shiftLeft) ? 1.0 : 0.0,
    );
  }

  void _onKey(KeyEvent e) {
    if (e is KeyDownEvent) {
      // Toggle manual control with M.
      if (e.logicalKey == LogicalKeyboardKey.keyM) {
        setState(() => _manualControl = !_manualControl);
        return;
      }
      _keysDown.add(e.logicalKey);
      // Camera zoom with [ and ].
      if (e.logicalKey == LogicalKeyboardKey.bracketLeft) {
        setState(() => _metresPerPixel = (_metresPerPixel * 1.25).clamp(50.0, 2e8));
      } else if (e.logicalKey == LogicalKeyboardKey.bracketRight) {
        setState(() => _metresPerPixel = (_metresPerPixel / 1.25).clamp(50.0, 2e8));
      }
    } else if (e is KeyUpEvent) {
      _keysDown.remove(e.logicalKey);
    }
  }

  TopDownSnapshot? _snapshot;
  double _metresPerPixel = 4000; // ~600km planet fits a phone screen
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();

    final system = SampleWorld.buildSystem();
    final vessel = SampleWorld.buildVessel(altitude: 120000);
    // Carry experiments so the demo accrues science as it orbits/transitions.
    vessel.experiments.addAll(const [
      Experiment(id: 'thermometer', baseValue: 8),
      Experiment(id: 'goo-canister', baseValue: 15),
    ]);
    final miner = SampleWorld.buildMiner();
    final freighter = SampleWorld.buildFreighter();
    _focus = vessel.id;

    _vessels = InMemoryVesselRepository([vessel, miner, freighter]);
    final universe = StaticUniverseRepository(system);
    final events = InMemoryEventBus();
    _colonies = InMemoryColonyRepository([SampleWorld.buildColony()]);
    _deposits = InMemoryDepositRepository([SampleWorld.buildDeposit()]);
    final weather = InMemoryWeatherRepository([SampleWorld.buildWeather()]);
    _research = ResearchLedger(
      tree: TechTree(nodes: const [
        TechNode(id: 'start', cost: 0),
        TechNode(id: 'generalRocketry', cost: 20, requires: ['start']),
      ]),
    );

    _clock = SimulationClock(warpFactor: 50, fixedStep: 0.02);
    _advance = AdvanceSimulationTick(
      vessels: _vessels,
      universe: universe,
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: events,
      colonies: _colonies,
      deposits: _deposits,
      weather: weather,
      research: _research,
    );
    _presenter = TopDownSnapshotPresenter(
      vessels: _vessels,
      universe: universe,
      colonies: _colonies,
    );

    _ticker = createTicker(_onFrame)..start();
  }

  void _onFrame(Duration elapsed) {
    final frameDt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;

    // Manual flight: apply pilot input to the focus vessel each frame.
    if (_manualControl) {
      final vessel = _vessels.byId(_focus);
      if (vessel != null) {
        vessel.flightPlan = null; // manual overrides autopilot (exclusive)
        _pilot.apply(vessel, _readPilotInput(), dt: frameDt.clamp(0.0, 0.1));
      }
    }

    // Run as many fixed steps as real time accrued (capped to avoid spirals).
    var budget = frameDt;
    var steps = 0;
    while (budget >= _clock.fixedStep && steps < 200) {
      _advance.execute(_clock);
      budget -= _clock.fixedStep;
      steps++;
    }

    setState(() {
      _snapshot = _presenter.present(
        focus: _focus,
        metresPerPixel: _metresPerPixel,
        epoch: _clock.epoch,
        science: _research.science,
      );
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _keyFocus.dispose();
    super.dispose();
  }

  /// Serialize the whole world into the in-memory save slot.
  void _save() {
    _savedGame = jsonEncode(_codec.encode(
      vessels: _vessels,
      colonies: _colonies,
      deposits: _deposits,
      clock: _clock,
    ));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved at tick ${_clock.tick}'), duration: const Duration(seconds: 1)),
    );
  }

  /// Restore the world from the in-memory save slot.
  void _load() {
    final save = _savedGame;
    if (save == null) return;
    // Wipe live vessels so the restore replaces them.
    for (final v in _vessels.all().toList()) {
      _vessels.remove(v.id);
    }
    _codec.decode(
      jsonDecode(save) as Map<String, dynamic>,
      vessels: _vessels,
      colonies: _colonies,
      deposits: _deposits,
      clock: _clock,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Loaded tick ${_clock.tick}'), duration: const Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snap = _snapshot;
    return Scaffold(
      backgroundColor: const Color(0xFF05070D),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'save',
            onPressed: _save,
            child: const Icon(Icons.save),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            heroTag: 'load',
            onPressed: _savedGame == null ? null : _load,
            backgroundColor: _savedGame == null ? Colors.grey : null,
            child: const Icon(Icons.folder_open),
          ),
        ],
      ),
      body: KeyboardListener(
        focusNode: _keyFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
          onScaleUpdate: (d) => setState(() {
            if (d.scale != 1.0) {
              _metresPerPixel = (_metresPerPixel / d.scale).clamp(50.0, 2e8);
            }
          }),
          child: Stack(
            children: [
              Positioned.fill(
                child: snap == null
                    ? const Center(child: CircularProgressIndicator())
                    : CustomPaint(
                        size: Size.infinite,
                        painter: TopDownPainter(snap),
                      ),
              ),
              Positioned(
                left: 8,
                bottom: 8,
                child: Text(
                  _manualControl
                      ? 'MANUAL  W/S pitch  A/D yaw  Q/E roll  Shift throttle  M auto  [ ] zoom'
                      : 'AUTO  (press M for manual flight)  [ ] zoom',
                  style: TextStyle(
                    color: _manualControl
                        ? const Color(0xFFFF8C66)
                        : const Color(0xFF6E8299),
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
