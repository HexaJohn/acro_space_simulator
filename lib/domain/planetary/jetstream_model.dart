import 'dart:math' as math;

/// Banded zonal (east-west) winds as a function of latitude — the steady
/// large-scale circulation that produces Earth's trade winds and jet streams or
/// Jupiter's alternating cloud bands. Pure domain: no Flutter/IO.
///
/// The wind speed alternates sign across latitude bands. With [bandCount] bands
/// per hemisphere the zonal wind follows a cosine in latitude so neighbouring
/// bands blow in opposite directions and the speed scales linearly with
/// [peakSpeed]. Sign is positive for eastward (prograde) flow, negative for
/// westward.
///
/// Output is a single scalar (m/s) suitable for feeding the weather context as
/// the east component of a prevailing wind, without touching the weather files.
class JetstreamModel {
  /// Number of wind bands per hemisphere (Earth ~3: trades, westerlies, polar).
  final int bandCount;

  /// Peak zonal wind speed (m/s) at a band centre.
  final double peakSpeed;

  const JetstreamModel({this.bandCount = 3, this.peakSpeed = 30})
      : assert(bandCount > 0, 'bandCount must be positive');

  /// Zonal (east-west) wind speed (m/s) at [latitude] (rad). Positive is
  /// eastward, negative westward. Alternates sign every band from equator to
  /// pole and scales with [peakSpeed].
  double zonalWindAt(double latitude) {
    // Fold to a [0..pi/2] colatitude-from-equator so both hemispheres mirror.
    final absLat = latitude.abs().clamp(0.0, math.pi / 2);
    // Each band spans (pi/2)/bandCount in latitude. A cosine over the bands
    // gives alternating-sign lobes that peak at +/-peakSpeed at band centres
    // and cross zero at band boundaries (equator and poles included).
    final bandsFromEquator = absLat / (math.pi / 2) * bandCount;
    return peakSpeed * math.cos(bandsFromEquator * math.pi);
  }
}
