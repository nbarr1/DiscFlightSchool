import 'disc_detection_service.dart';
import 'disc_tracker.dart';

/// Ways an automatically detected flight path can be untrustworthy.
///
/// These are warnings, not failures: the path is still shown. They exist so
/// the user is told when a plausible-looking curve is mostly guesswork,
/// rather than being left to discover it by eye.
enum DetectionQualityFlag {
  /// The disc was only ever located in a handful of frames.
  tooFewDetections,

  /// The path spans well under half the clip — the disc likely left frame.
  lowCoverage,

  /// More of the path was filled in between sightings than actually detected.
  mostlyInterpolated,

  /// The detections that did land were weak relative to the user's own
  /// sensitivity setting — often a sign of tracking something that isn't the
  /// disc.
  weakMatches,
}

/// Quality assessment of a [FlightTrackingResult] produced by automatic
/// detection.
class DetectionQualityReport {
  /// Detections that came from the model, excluding interpolated fill.
  final int realDetections;

  /// Fraction of the clip the path spans, 0-1.
  final double coverage;

  /// Fraction of the path's points that were interpolated rather than
  /// detected, 0-1.
  final double interpolatedFraction;

  /// Mean confidence across real detections only, or 0 when there are none.
  final double meanConfidence;

  final List<DetectionQualityFlag> flags;

  const DetectionQualityReport({
    required this.realDetections,
    required this.coverage,
    required this.interpolatedFraction,
    required this.meanConfidence,
    required this.flags,
  });

  bool get isLow => flags.isNotEmpty;

  /// The flag to lead with when explaining the problem to the user. Ordered
  /// by how fundamental the problem is, not by severity of the number.
  DetectionQualityFlag? get primaryFlag => flags.isEmpty ? null : flags.first;
}

/// Thresholds for [assessDetectionQuality].
///
/// Grouped and named so they can be retuned from device data in one commit
/// without touching the logic that reads them.
class DetectionQualityThresholds {
  const DetectionQualityThresholds._();

  /// Below this many model-sourced detections, the path is a lucky guess
  /// rather than a track.
  static const int minRealDetections = 5;

  /// Minimum fraction of the clip the path must span.
  ///
  /// The coherence filter inside [DiscDetectionService] already treats a
  /// chain covering 40% of frames as good enough to stop searching, so
  /// anything below half the clip is a fragment by the pipeline's own
  /// standard.
  static const double minCoverage = 0.5;

  /// Above this fraction of interpolated points, the user is looking at a
  /// drawn line more than a detected one. Gaps of up to 10 frames get bridged
  /// during interpolation, so this climbs quickly on a patchy track.
  static const double maxInterpolatedFraction = 0.4;

  /// Floor on mean confidence, regardless of how low the user has set their
  /// sensitivity.
  static const double minMeanConfidence = 0.35;

  /// Mean confidence must also clear the user's own threshold by this factor.
  ///
  /// The threshold is user-tunable from Training Settings, so a fixed bar
  /// would fire constantly for anyone who lowered it and never for anyone who
  /// raised it.
  static const double meanConfidenceFloorMultiple = 2.5;
}

/// Assess how much to trust an automatically detected [result].
///
/// [confidenceFloor] should be the detector's live confidence threshold, so
/// the weak-match test scales with the user's own sensitivity setting.
/// [expectedFrames] defaults to the result's own frame span.
DetectionQualityReport assessDetectionQuality(
  FlightTrackingResult result, {
  required double confidenceFloor,
  int? expectedFrames,
}) {
  final detections = result.detections;

  // Interpolated points are marked with a sentinel confidence of -1 by
  // DiscDetectionService rather than being flagged separately.
  final real = detections.where((d) => d.confidence >= 0).toList();

  final total = detections.length;
  final interpolatedFraction =
      total == 0 ? 0.0 : (total - real.length) / total;

  final meanConfidence = real.isEmpty
      ? 0.0
      : real.map((d) => d.confidence).reduce((a, b) => a + b) / real.length;

  final frameBudget = expectedFrames ?? result.totalFrames;
  double coverage = 0.0;
  if (frameBudget > 0 && detections.isNotEmpty) {
    var minFrame = detections.first.frameIndex;
    var maxFrame = detections.first.frameIndex;
    for (final d in detections) {
      if (d.frameIndex < minFrame) minFrame = d.frameIndex;
      if (d.frameIndex > maxFrame) maxFrame = d.frameIndex;
    }
    coverage = (maxFrame - minFrame + 1) / frameBudget;
  }

  final flags = <DetectionQualityFlag>[];

  if (real.length < DetectionQualityThresholds.minRealDetections) {
    flags.add(DetectionQualityFlag.tooFewDetections);
  }
  if (coverage < DetectionQualityThresholds.minCoverage) {
    flags.add(DetectionQualityFlag.lowCoverage);
  }
  if (interpolatedFraction >
      DetectionQualityThresholds.maxInterpolatedFraction) {
    flags.add(DetectionQualityFlag.mostlyInterpolated);
  }

  final confidenceBar = _maxOf(
    DetectionQualityThresholds.minMeanConfidence,
    confidenceFloor * DetectionQualityThresholds.meanConfidenceFloorMultiple,
  );
  // An empty result is already covered by tooFewDetections; flagging it as a
  // weak match too would just stack a second, less useful message on it.
  if (real.isNotEmpty && meanConfidence < confidenceBar) {
    flags.add(DetectionQualityFlag.weakMatches);
  }

  return DetectionQualityReport(
    realDetections: real.length,
    coverage: coverage,
    interpolatedFraction: interpolatedFraction,
    meanConfidence: meanConfidence,
    flags: flags,
  );
}

double _maxOf(double a, double b) => a > b ? a : b;

/// How many editable keyframes to seed from an automatic result by default.
///
/// Enough control points for a Catmull-Rom spline over a two-to-four second
/// flight, few enough to hand-correct in under a minute, and comfortably
/// above the three that [HybridDiscTracker] needs — so Auto-Refine is
/// available immediately after converting.
const int defaultSeedPointTarget = 8;

/// Sample [detections] down to at most [target] evenly spaced seed points for
/// hand-editing.
///
/// Interpolated points are never selected. They were invented to bridge gaps,
/// and promoting one to a user-editable keyframe would turn a gap in the data
/// into a fact the user appears to have confirmed.
List<TrackerSeedPoint> sampleSeedPoints(
  List<DiscDetection> detections, {
  int target = defaultSeedPointTarget,
}) {
  final real = detections.where((d) => d.confidence >= 0).toList()
    ..sort((a, b) => a.frameIndex.compareTo(b.frameIndex));

  if (real.isEmpty) return const [];
  if (target < 2) target = 2;
  if (real.length <= target) {
    return [
      for (final d in real)
        TrackerSeedPoint(frameIndex: d.frameIndex, x: d.x, y: d.y),
    ];
  }

  // Even spacing that always lands on both endpoints — the same idiom used
  // elsewhere for picking representative frames out of a sequence.
  final step = (real.length - 1) / (target - 1);
  final picked = <int>{};
  for (int i = 0; i < target; i++) {
    picked.add((i * step).round().clamp(0, real.length - 1));
  }

  final indices = picked.toList()..sort();
  return [
    for (final i in indices)
      TrackerSeedPoint(
        frameIndex: real[i].frameIndex,
        x: real[i].x,
        y: real[i].y,
      ),
  ];
}
