import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native encoders of the replay (`ios/` and `android/` of this package).
///
/// Every method returns null when the native side is missing (widget tests,
/// desktop) or fails, and the caller falls back to PNG frames: a report must
/// never be lost because of the replay.
class ReplayCodec {
  const ReplayCodec();

  static const MethodChannel _channel = MethodChannel('nabrila/replay');
  static bool _missing = false;

  /// Whether this phone records replays (Android 8 and newer, any iOS the
  /// SDK runs on). Without the native side, frames are kept as PNG.
  Future<bool> supported() async {
    if (_missing) return true;
    try {
      return await _channel.invokeMethod<bool>('supported') ?? false;
    } on MissingPluginException {
      _missing = true;
      return true;
    } on PlatformException {
      return false;
    }
  }

  /// JPEG of an opaque RGBA picture.
  Future<Uint8List?> jpeg(
    Uint8List rgba,
    int width,
    int height, {
    int quality = 60,
  }) => _call('jpeg', {
    'rgba': rgba,
    'width': width,
    'height': height,
    'quality': quality,
  });

  /// One H.264 MP4 of JPEG [frames], each shown at its [times] entry (ms
  /// from the first frame, increasing). The encoder keeps a constant
  /// [quality] (0 to 1) where it can, and [bitrate] where it cannot.
  Future<Uint8List?> video(
    List<Uint8List> frames,
    List<int> times,
    int width,
    int height, {
    int bitrate = 40000,
    double quality = 0.5,
  }) => _call('video', {
    'frames': frames,
    'times': times,
    'width': width,
    'height': height,
    'bitrate': bitrate,
    'quality': quality,
  });

  Future<Uint8List?> _call(String method, Map<String, Object> args) async {
    if (_missing) return null;
    try {
      return await _channel.invokeMethod<Uint8List>(method, args);
    } on MissingPluginException {
      _missing = true;
      return null;
    } on PlatformException catch (e) {
      debugPrint('nabrila: replay $method failed: ${e.code} ${e.message}');
      return null;
    }
  }
}
