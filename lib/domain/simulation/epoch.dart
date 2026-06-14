/// A point in simulation time: seconds since the universe epoch (game start).
///
/// Value object. Uses a `double` of seconds — fine for gameplay timescales; if
/// multi-millennium precision is ever needed, split into (whole seconds:int,
/// fraction:double) the same way [PreciseVector3] splits position. Kept simple
/// for now to avoid premature complexity.
class Epoch {
  final double seconds;
  const Epoch(this.seconds);

  static const Epoch zero = Epoch(0);

  double secondsSince(Epoch other) => seconds - other.seconds;

  Epoch operator +(double dtSeconds) => Epoch(seconds + dtSeconds);
  Epoch operator -(double dtSeconds) => Epoch(seconds - dtSeconds);

  bool operator <(Epoch o) => seconds < o.seconds;
  bool operator >(Epoch o) => seconds > o.seconds;
  bool operator <=(Epoch o) => seconds <= o.seconds;
  bool operator >=(Epoch o) => seconds >= o.seconds;

  @override
  bool operator ==(Object other) => other is Epoch && other.seconds == seconds;
  @override
  int get hashCode => seconds.hashCode;
  @override
  String toString() => 'Epoch(${seconds.toStringAsFixed(2)}s)';
}
