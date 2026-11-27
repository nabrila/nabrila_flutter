import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'replay/replay_recorder.dart';

/// Hard cap for the whole `NBR1` file (architecture.md, section 3.4).
const int maxEnvelopeBytes = 2097152;

/// Bit 0 of the flags byte: the JSON segment is gzip-compressed.
const int flagGzipJson = 1;

const int _headerLength = 18;

/// The envelope would be larger than [maxEnvelopeBytes].
class EnvelopeTooLargeException implements Exception {
  EnvelopeTooLargeException(this.bytes);

  final int bytes;

  @override
  String toString() => 'EnvelopeTooLargeException: $bytes bytes';
}

/// Result of [sealReport]: the file to upload and the key that opens it.
class SealedReport {
  SealedReport({required this.envelope, required this.key, this.verdictSecret});

  final Uint8List envelope;
  final Uint8List key;

  /// 32 random bytes that stay on the phone (D34): their hash goes with the
  /// upload, and only whoever holds them can answer "does it work now?".
  /// Never part of the link. Null for reports sealed before it existed.
  final Uint8List? verdictSecret;
}

/// `[uint32_be json_length][json segment][png][replay…]`. The PNG and the
/// replay are optional.
Uint8List buildPayload(
  Uint8List jsonSegment,
  Uint8List? png, [
  List<Uint8List> frames = const [],
]) {
  final framesLength = frames.fold<int>(0, (sum, f) => sum + f.length);
  final out = Uint8List(
    4 + jsonSegment.length + (png?.length ?? 0) + framesLength,
  );
  ByteData.sublistView(out).setUint32(0, jsonSegment.length, Endian.big);
  out.setRange(4, 4 + jsonSegment.length, jsonSegment);
  var at = 4 + jsonSegment.length;
  if (png != null) {
    out.setRange(at, at + png.length, png);
    at += png.length;
  }
  for (final frame in frames) {
    out.setRange(at, at + frame.length, frame);
    at += frame.length;
  }
  return out;
}

/// Room kept for the gzip'd manifest, the header and the GCM tag when the
/// replay frames are fitted into [maxEnvelopeBytes].
const int replayReserveBytes = 96 * 1024;

Uint8List randomBytes(int length, [Random? random]) {
  final source = random ?? Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => source.nextInt(256)),
  );
}

/// Encrypts an already-built payload. Pure and deterministic for a given
/// [key], [iv] and [flags], which is what the shared test vectors check.
Future<Uint8List> sealPayload({
  required Uint8List plain,
  required Uint8List key,
  required Uint8List iv,
  required int flags,
}) async {
  final header = Uint8List(_headerLength)
    ..setRange(0, 4, const [0x4e, 0x42, 0x52, 0x31])
    ..[4] = 0x01
    ..[5] = flags
    ..setRange(6, _headerLength, iv);
  final box = await AesGcm.with256bits().encrypt(
    plain,
    secretKey: SecretKey(key),
    nonce: iv,
    aad: header.sublist(0, 6),
  );
  final body = box.concatenation(nonce: false);
  final envelope = Uint8List(_headerLength + body.length)
    ..setRange(0, _headerLength, header)
    ..setRange(_headerLength, _headerLength + body.length, body);
  if (envelope.length > maxEnvelopeBytes) {
    throw EnvelopeTooLargeException(envelope.length);
  }
  return envelope;
}

/// Gzips only the JSON, builds the payload and encrypts it with a fresh
/// 32-byte key and a fresh 12-byte IV.
///
/// With a [replay], the moments before the report go after the screenshot:
/// one MP4 when the native encoder made it and it fits, else the newest
/// single frames that fit. Either way the envelope stays under
/// [maxEnvelopeBytes] and the report is never lost because of the replay.
Future<SealedReport> sealReport({
  required Map<String, Object?> manifest,
  required Uint8List? png,
  ReplayTake? replay,
  Random? random,
}) async {
  var blobs = const <Uint8List>[];
  if (replay != null && replay.frames.isNotEmpty) {
    final budget = maxEnvelopeBytes - replayReserveBytes - (png?.length ?? 0);
    final packed = await _packReplay(replay, budget);
    if (packed != null) {
      blobs = packed.blobs;
      // The replay follows the screenshot in the payload.
      manifest = {
        ...manifest,
        'screenshotBytes': png?.length ?? 0,
        'replay': packed.meta,
      };
    }
  }
  final json = gzip.encode(utf8.encode(jsonEncode(manifest)));
  final plain = buildPayload(Uint8List.fromList(json), png, blobs);
  final key = randomBytes(32, random);
  final iv = randomBytes(12, random);
  final envelope = await sealPayload(
    plain: plain,
    key: key,
    iv: iv,
    flags: flagGzipJson,
  );
  return SealedReport(
    envelope: envelope,
    key: key,
    verdictSecret: randomBytes(32, random),
  );
}

Future<({List<Uint8List> blobs, Map<String, Object?> meta})?> _packReplay(
  ReplayTake replay,
  int budget,
) async {
  int at(ReplayFrame f) => f.at.difference(replay.origin).inMilliseconds;
  var video = await replay.video();
  // Too long for the budget: keep halving to the newest frames.
  while (video != null && video.bytes.length > budget) {
    final fewer = video.frames.length ~/ 2;
    video = fewer < 2 ? null : await replay.video(newest: fewer);
  }
  // Some encoders (Android's software one, for instance) ignore the quality
  // asked for; a video heavier than its own frames is not worth sending.
  if (video != null &&
      video.bytes.length >
          video.frames.fold<int>(0, (sum, f) => sum + f.bytes.length)) {
    video = null;
  }
  if (video != null) {
    final last = video.frames.last;
    return (
      blobs: [video.bytes],
      meta: {
        'format': 'mp4',
        'bytes': video.bytes.length,
        'width': last.width,
        'height': last.height,
        // tMs: real time from the report origin; vMs: time in the video.
        'frames': [
          for (var i = 0; i < video.frames.length; i++)
            {'tMs': at(video.frames[i]), 'vMs': video.times[i]},
        ],
      },
    );
  }
  final frames = framesWithin(replay.frames, budget);
  if (frames.isEmpty) return null;
  return (
    blobs: [for (final f in frames) f.bytes],
    meta: {
      'format': 'images',
      'frames': [
        for (final f in frames)
          {
            'tMs': at(f),
            'bytes': f.bytes.length,
            'format': f.format,
            'width': f.width,
            'height': f.height,
          },
      ],
    },
  );
}

/// `<origin>/r/<id>#k=<base64url key, no padding>`; the origin is
/// `https://nabrila.com` unless the app overrides the endpoint.
String buildShareLink({
  required String id,
  required Uint8List key,
  String origin = 'https://nabrila.com',
}) {
  final k = base64Url.encode(key).replaceAll('=', '');
  final base = origin.endsWith('/')
      ? origin.substring(0, origin.length - 1)
      : origin;
  return '$base/r/${Uri.encodeComponent(id)}#k=$k';
}
