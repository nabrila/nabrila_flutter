import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'envelope.dart';

/// Sealed reports wait here, on the phone's disk, until the server confirms
/// them (D28). A report is written before its first upload attempt, so a
/// lost connection, a timeout or the app being closed never loses it; the
/// next attempt sends the very same bytes, and the server answers a repeat
/// with the report it already made.
///
/// Each report is two files: `<name>.nbr` (the encrypted envelope) and
/// `<name>.json` (its key, where it goes and its retry state). Both stay in
/// the app's private storage. Once sent, the envelope is deleted and the
/// state stays only until the tester has seen the link (and the team plan
/// has the key), so a link is never lost to the app closing at the wrong
/// moment.
class ReportOutbox {
  ReportOutbox(this.dir, {DateTime Function()? clock, Random? random})
    : _clock = clock ?? DateTime.now,
      _random = random ?? Random.secure();

  final Directory dir;
  final DateTime Function() _clock;
  final Random _random;

  /// Reports older than this are dropped: the tester has long moved on.
  static const Duration maxAge = Duration(days: 7);

  /// At most this many reports wait; the oldest go first.
  static const int maxReports = 10;

  /// Every write and listing runs one at a time: a listing must never see
  /// a report halfway written and take it for a broken one, nor sweep the
  /// temporary file of a write in progress.
  Future<void> _last = Future.value();

  Future<T> _serial<T>(Future<T> Function() work) {
    final run = _last.then((_) => work());
    _last = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  DateTime _now() => _clock().toUtc();

  /// Keeps [sealed], bound for [appKey] at [endpoint], and returns its
  /// handle. A later build with another key or server still sends it where
  /// it was meant to go.
  Future<PendingReport> add(
    SealedReport sealed, {
    required String appKey,
    required String endpoint,
  }) => _serial(() async {
    await dir.create(recursive: true);
    final now = _now();
    final name =
        '${now.microsecondsSinceEpoch}-${_random.nextInt(1 << 32).toRadixString(16)}';
    final report = PendingReport._(
      this,
      name,
      key: sealed.key,
      appKey: appKey,
      endpoint: endpoint,
      createdAt: now,
      nextAt: now,
    );
    // Envelope first, then the state that points to it: a crash in between
    // leaves an envelope without state, which [pending] cleans up.
    await _writeAtomic(report._envelopeFile, sealed.envelope);
    await report._write();
    await _trim();
    return report;
  });

  /// Every report still waiting or still to be seen, oldest first. Broken
  /// or expired entries are deleted on the way.
  Future<List<PendingReport>> pending() => _serial(_pending);

  Future<List<PendingReport>> _pending() async {
    if (!await dir.exists()) return const [];
    final now = _now();
    final out = <PendingReport>[];
    final names = <String>{};
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final file = entity.uri.pathSegments.last;
      if (file.endsWith('.tmp')) {
        await _deleteQuietly(entity);
        continue;
      }
      final dot = file.lastIndexOf('.');
      if (dot > 0) names.add(file.substring(0, dot));
    }
    for (final name in names) {
      final PendingReport? report;
      try {
        report = await PendingReport._load(this, name);
      } on FileSystemException {
        // Locked (iOS before the first unlock) or busy: not broken. It is
        // left alone and read on a later pass.
        continue;
      }
      // A clock moved by days either way counts as old too: better than a
      // report that never expires.
      if (report == null || now.difference(report.createdAt).abs() > maxAge) {
        await PendingReport._deleteFiles(this, name);
        continue;
      }
      out.add(report);
    }
    out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  }

  Future<void> _trim() async {
    final all = await _pending();
    for (final old in all.take(max(0, all.length - maxReports))) {
      await old.remove();
    }
  }
}

/// One report in the [ReportOutbox].
class PendingReport {
  PendingReport._(
    this._outbox,
    this.name, {
    required this.key,
    required this.appKey,
    required this.endpoint,
    required this.createdAt,
    required this.nextAt,
  });

  final ReportOutbox _outbox;
  final String name;
  final Uint8List key;
  final String appKey;
  final String endpoint;
  final DateTime createdAt;

  /// Failed attempts so far.
  int attempts = 0;

  /// Earliest time of the next automatic attempt.
  DateTime nextAt;

  /// Set once the server made the report.
  String? sentId;
  String? expiresAt;

  /// The plan keeps the key and the server does not have it yet.
  bool keyPending = false;

  /// The tester already saw the link.
  bool shown = false;

  bool get sent => sentId != null;

  /// Nothing left to do: the link was seen and the key, if needed, stored.
  bool get settled => sent && shown && !keyPending;

  File get _envelopeFile => File('${_outbox.dir.path}/$name.nbr');
  File get _stateFile => File('${_outbox.dir.path}/$name.json');

  /// The report as it was sealed, byte for byte.
  Future<SealedReport> load() async =>
      SealedReport(envelope: await _envelopeFile.readAsBytes(), key: key);

  /// The longest wait between two attempts.
  static const Duration maxWait = Duration(hours: 1);

  /// Whether an automatic attempt is due at [now]. A wait longer than the
  /// longest backoff means the clock went back: it is due.
  bool dueAt(DateTime now) {
    final wait = nextAt.difference(now.toUtc());
    return wait <= Duration.zero || wait > maxWait * 1.25;
  }

  /// Records a failed attempt and waits longer before the next one: 30 s,
  /// 1, 2, 4, 8 minutes and so on, up to an hour, with some jitter so many
  /// phones that lost the same network do not all come back at once. The
  /// server's `Retry-After`, when longer, wins.
  Future<void> failed({Duration? retryAfter}) async {
    attempts++;
    final base = Duration(seconds: 30 * (1 << min(attempts - 1, 7)));
    final capped = base > maxWait ? maxWait : base;
    final jitter = capped.inMilliseconds * (0.8 + 0.4 * Random().nextDouble());
    var wait = Duration(milliseconds: jitter.round());
    if (retryAfter != null && retryAfter > wait) wait = retryAfter;
    nextAt = _outbox._now().add(wait);
    await _save();
  }

  /// The server made the report. The envelope is no longer needed; the
  /// state stays until [settled].
  Future<void> markSent({
    required String id,
    String? expiresAt,
    required bool keyPending,
    required bool shown,
  }) async {
    sentId = id;
    this.expiresAt = expiresAt;
    this.keyPending = keyPending;
    this.shown = shown;
    attempts = 0;
    nextAt = _outbox._now();
    if (settled) return remove();
    await _save();
    await _deleteQuietly(_envelopeFile);
  }

  /// Saves [shown] and [keyPending], and deletes the entry once settled.
  Future<void> update({bool? shown, bool? keyPending}) async {
    if (shown != null) this.shown = shown;
    if (keyPending != null) this.keyPending = keyPending;
    if (settled) return remove();
    await _save();
  }

  /// Deletes the report.
  Future<void> remove() => _deleteFiles(_outbox, name);

  Future<void> _save() => _outbox._serial(_write);

  Future<void> _write() => _writeAtomic(
    _stateFile,
    utf8.encode(
      jsonEncode({
        'v': 1,
        'key': base64Encode(key),
        'appKey': appKey,
        'endpoint': endpoint,
        'createdAt': createdAt.toIso8601String(),
        'attempts': attempts,
        'nextAt': nextAt.toIso8601String(),
        'sentId': sentId,
        'expiresAt': expiresAt,
        'keyPending': keyPending,
        'shown': shown,
      }),
    ),
  );

  /// The entry called [name], or null when it is broken for good (missing
  /// state, bad JSON). Throws [FileSystemException] when it cannot be read
  /// right now.
  static Future<PendingReport?> _load(ReportOutbox outbox, String name) async {
    final envelope = File('${outbox.dir.path}/$name.nbr');
    final state = File('${outbox.dir.path}/$name.json');
    if (!await state.exists()) return null;
    final bytes = await state.readAsBytes();
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map;
      final sentId = json['sentId'] as String?;
      // Not sent yet and no envelope: nothing to send.
      if (sentId == null && !await envelope.exists()) return null;
      return PendingReport._(
          outbox,
          name,
          key: base64Decode(json['key'] as String),
          appKey: json['appKey'] as String,
          endpoint: json['endpoint'] as String,
          createdAt: DateTime.parse(json['createdAt'] as String),
          nextAt: DateTime.parse(json['nextAt'] as String),
        )
        ..attempts = json['attempts'] as int
        ..sentId = sentId
        ..expiresAt = json['expiresAt'] as String?
        ..keyPending = json['keyPending'] == true
        ..shown = json['shown'] == true;
    } on Object {
      return null;
    }
  }

  static Future<void> _deleteFiles(ReportOutbox outbox, String name) async {
    await _deleteQuietly(File('${outbox.dir.path}/$name.nbr'));
    await _deleteQuietly(File('${outbox.dir.path}/$name.json'));
  }
}

/// Writes through a temporary file and a rename, so a crash never leaves a
/// half-written file under the real name.
Future<void> _writeAtomic(File file, List<int> bytes) async {
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(file.path);
}

Future<void> _deleteQuietly(File file) async {
  try {
    await file.delete();
  } on FileSystemException {
    // Already gone.
  }
}
