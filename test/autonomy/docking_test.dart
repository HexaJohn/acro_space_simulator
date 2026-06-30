import 'package:acro_space_simulator/domain/autonomy/docking_approach.dart';
import 'package:acro_space_simulator/domain/autonomy/docking_updater.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/docking_port.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/stage.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

Vessel _withPort(String id, String portId, Vector3 pos, Vector3 vel) {
  final part = Part(
    id: PartId('p-$id'),
    name: 'core',
    dryMass: 1000,
    dockingPort: DockingPort(
      id: portId,
      position: Vector3.zero,
      facing: Vector3.unitZ,
    ),
  );
  return Vessel(
    id: VesselId(id),
    name: id,
    ownerId: 'ai',
    state: StateVector(position: pos, velocity: vel),
    dominantBody: const BodyId('earth'),
    stages: [Stage(index: 0, parts: [part])],
  );
}

void main() {
  const updater = DockingUpdater();

  test('chaser closes distance to the target over successive ticks', () {
    final target = _withPort('target', 'tp', const Vector3(0, 0, 0), Vector3.zero);
    final chaser = _withPort('chaser', 'cp', const Vector3(100, 0, 0), Vector3.zero)
      ..docking = DockingApproach(
        target: const VesselId('target'),
        chaserPortId: 'cp',
        targetPortId: 'tp',
      );

    final d0 = (chaser.state.position - target.state.position).length;
    for (var i = 0; i < 50; i++) {
      updater.update(chaser, target, dt: 1.0);
      // integrate the commanded velocity
      chaser.updateState(chaser.state
          .copyWith(position: chaser.state.position + chaser.state.velocity * 1.0));
    }
    final d1 = (chaser.state.position - target.state.position).length;
    expect(d1, lessThan(d0));
  });

  test('latches and emits DockingCompleted when within capture distance', () {
    final target = _withPort('target', 'tp', const Vector3(0, 0, 0), Vector3.zero);
    final chaser = _withPort('chaser', 'cp', const Vector3(0.3, 0, 0), Vector3.zero)
      ..docking = DockingApproach(
        target: const VesselId('target'),
        chaserPortId: 'cp',
        targetPortId: 'tp',
      );

    updater.update(chaser, target, dt: 1.0);

    expect(chaser.docking!.docked, isTrue);
    expect(chaser.drainEvents().whereType<DockingCompleted>().isNotEmpty, isTrue);
    // Both ports record the latch.
    final cp = chaser.allParts.first.dockingPort!;
    final tp = target.allParts.first.dockingPort!;
    expect(cp.latchedTo, 'tp');
    expect(tp.latchedTo, 'cp');
  });

  test('does nothing once already docked', () {
    final target = _withPort('target', 'tp', const Vector3(0, 0, 0), Vector3.zero);
    final chaser = _withPort('chaser', 'cp', const Vector3(0.3, 0, 0), Vector3.zero)
      ..docking = DockingApproach(
        target: const VesselId('target'),
        chaserPortId: 'cp',
        targetPortId: 'tp',
        docked: true,
      );
    updater.update(chaser, target, dt: 1.0);
    expect(chaser.drainEvents().whereType<DockingCompleted>().isEmpty, isTrue);
  });
}
