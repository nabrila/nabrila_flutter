import 'package:flutter/foundation.dart';

/// How the replay records the moments before a report.
///
/// Every value has a default that was measured on a long shopping flow
/// (iOS simulator and Android emulator): no stutter, about 34 KB per frame
/// in memory and a video of a few hundred KB in the report.
///
/// ```dart
/// Nabrila.run(
///   appKey: 'nbr_...',
///   enabled: true,
///   replay: const NabrilaReplay(maskAllText: true),
///   app: () => runApp(const NabrilaScope(child: MyApp())),
/// );
/// ```
@immutable
class NabrilaReplay {
  const NabrilaReplay({
    this.enabled = true,
    this.frameInterval = const Duration(seconds: 1),
    this.maxFrames = 120,
    this.maxMemoryBytes = 4000000,
    this.maxSide = 960,
    this.imageQuality = 45,
    this.videoQuality = 0.5,
    this.maskAllText = false,
    this.maskAllImages = false,
  }) : assert(maxFrames >= 2),
       assert(maxMemoryBytes >= 200000),
       assert(maxSide >= 240),
       assert(imageQuality >= 10 && imageQuality <= 100),
       assert(videoQuality > 0 && videoQuality <= 1);

  /// No recording at all: reports carry the screenshot only.
  static const NabrilaReplay off = NabrilaReplay(enabled: false);

  final bool enabled;

  /// Shortest time between two frames. A frame is only taken when something
  /// was painted since the last one, so an idle app costs nothing.
  final Duration frameInterval;

  /// Frames kept in memory; the oldest go first. Idle moments add none, so
  /// 120 frames at the default interval cover two minutes of constant
  /// movement and more of normal use.
  final int maxFrames;

  /// Memory the kept frames may use, in bytes.
  final int maxMemoryBytes;

  /// Longest side of a frame, in pixels. Frames are never above 1x density.
  final double maxSide;

  /// JPEG quality of each frame in memory, 10 to 100. It barely changes the
  /// video sent (the video encoder sets that), only the memory used: 45
  /// takes 20% less than 60 with the same legible text.
  final int imageQuality;

  /// Quality of the video sent with the report, above 0 up to 1. Used where
  /// the phone's encoder supports a constant quality; elsewhere a fixed
  /// bitrate applies.
  final double videoQuality;

  /// Covers every text, not only text fields and `NabrilaMask`.
  final bool maskAllText;

  /// Covers every image (`Image`, network or asset).
  final bool maskAllImages;
}
