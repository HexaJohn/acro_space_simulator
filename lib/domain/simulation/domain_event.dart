import '../universe/celestial_body.dart';
import '../vessel/part.dart';
import '../vessel/vessel.dart';
import 'epoch.dart';

/// Something that happened in the simulation that other contexts or the UI care
/// about. Raised by aggregates/services, published by the application layer via
/// the event bus. Immutable, past-tense, self-describing.
///
/// [occurredAt] defaults to [Epoch.zero] when raised inside an aggregate (which
/// has no clock); the application tick stamps the real epoch on publish.
abstract class DomainEvent {
  final Epoch occurredAt;
  const DomainEvent(this.occurredAt);
}

class SoiTransition extends DomainEvent {
  final VesselId vessel;
  final BodyId from;
  final BodyId to;
  SoiTransition(this.vessel, this.from, this.to) : super(Epoch.zero);
}

class StageSeparation extends DomainEvent {
  final VesselId vessel;
  final int stageIndex;
  StageSeparation(this.vessel, this.stageIndex) : super(Epoch.zero);
}

class ApoapsisReached extends DomainEvent {
  final VesselId vessel;
  ApoapsisReached(this.vessel) : super(Epoch.zero);
}

class AtmosphericEntry extends DomainEvent {
  final VesselId vessel;
  final BodyId body;
  AtmosphericEntry(this.vessel, this.body) : super(Epoch.zero);
}

class Impact extends DomainEvent {
  final VesselId vessel;
  final BodyId body;
  final double speed;
  Impact(this.vessel, this.body, this.speed) : super(Epoch.zero);
}

class DockingCompleted extends DomainEvent {
  final VesselId a;
  final VesselId b;
  DockingCompleted(this.a, this.b) : super(Epoch.zero);
}

class PartOverheated extends DomainEvent {
  final VesselId vessel;
  final PartId part;
  final double temperature;
  PartOverheated(this.vessel, this.part, this.temperature) : super(Epoch.zero);
}

class ResourceMined extends DomainEvent {
  final VesselId vessel;
  final String depositId;
  final double amount;
  ResourceMined(this.vessel, this.depositId, this.amount) : super(Epoch.zero);
}

class PlanAborted extends DomainEvent {
  final VesselId vessel;
  final String reason;
  PlanAborted(this.vessel, this.reason) : super(Epoch.zero);
}

class CrewLost extends DomainEvent {
  final VesselId vessel;
  final String cause; // e.g. 'oxygen', 'food', 'radiation'
  CrewLost(this.vessel, this.cause) : super(Epoch.zero);
}

class CrewIrradiated extends DomainEvent {
  final VesselId vessel;
  final double doseSv; // cumulative dose at the time of sickness
  CrewIrradiated(this.vessel, this.doseSv) : super(Epoch.zero);
}

class MegastructureMilestone extends DomainEvent {
  final String structureId;
  final String message; // "phase 3 complete" / "operational"
  final bool completed; // true once fully operational
  MegastructureMilestone(this.structureId, this.message, {this.completed = false})
      : super(Epoch.zero);
}

class SituationEntered extends DomainEvent {
  final VesselId vessel;
  final String situation; // e.g. 'lowOrbit:mun'
  SituationEntered(this.vessel, this.situation) : super(Epoch.zero);
}

class StructuralFailure extends DomainEvent {
  final VesselId vessel;
  final double dynamicPressure; // Pa at failure
  StructuralFailure(this.vessel, this.dynamicPressure) : super(Epoch.zero);
}
