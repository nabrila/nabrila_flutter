import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'envelope.dart';
import 'outbox.dart';
import 'uploader.dart';

/// What happened to a report the tester just sent.
class DeliveryOutcome {
  const DeliveryOutcome.sent(UploadResult this.result)
    : failure = null,
      saved = false;
  const DeliveryOutcome.failed(
    UploadFailure this.failure, {
    required this.saved,
  }) : result = null;

  final UploadResult? result;
  final UploadFailure? failure;

  /// True when the report stayed on the phone and goes out on its own as
  /// soon as it can.
  final bool saved;
}

/// Sends reports so that none is lost (D28): each one is written to the
/// [ReportOutbox] before its first attempt and deleted only when the server
/// confirms it (and the tester saw its link) or refuses it for good.
/// Whatever could not go out is tried again when the app starts, when it
/// comes back to the foreground, and on a growing timer while it stays open.
class ReportDelivery {
  ReportDelivery({
    required this.client,
    required this.endpoint,
    required this.appKey,
    Future<Directory?> Function()? storageDir,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
    this.onSent,
    this.keepKeyOnDevice = false,
  }) : _storageDir = storageDir ?? defaultStorageDir,
       _clock = clock ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed;

  final http.Client client;
  final String endpoint;
  final String appKey;

  /// The key never leaves the phone, even if the plan keeps keys.
  final bool keepKeyOnDevice;
  final Future<Directory?> Function() _storageDir;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;

  /// Told about every report the server made, with the key that opens it.
  final void Function(
    UploadResult result,
    List<int> key,
    String endpoint,
    String appKey,
    List<int>? verdictSecret,
  )?
  onSent;

  /// Reports that went out after the tester closed the flow (or before the
  /// app was closed) and whose link nobody has seen yet. The scope shows
  /// them until [seen] is called.
  final ValueNotifier<List<UploadResult>> delivered = ValueNotifier(const []);
  final Map<String, PendingReport> _unseen = {};

  /// Reports the open capture flow handles itself; the background drain
  /// leaves them alone.
  final Set<String> _claimed = {};
  Future<ReportOutbox?>? _outbox;
  Future<void>? _running;
  bool _drainAgain = false;
  bool _closed = false;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  /// Quick retries inside one send, only after failures that came fast
  /// (no route, connection reset): a timeout already waited long enough.
  static const List<Duration> quickRetries = [
    Duration(seconds: 1),
    Duration(seconds: 3),
  ];

  /// Starts the background drain: now, on every return to the foreground,
  /// and when the next waiting report is due.
  void start() {
    _closed = false;
    _lifecycle ??= AppLifecycleListener(onResume: () => unawaited(drain()));
    unawaited(drain());
  }

  void dispose() {
    _closed = true;
    _timer?.cancel();
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  /// Deletes every saved report and every link not seen yet.
  Future<void> discardAll() async {
    _timer?.cancel();
    _timer = null;
    delivered.value = const [];
    _unseen.clear();
    final outbox = await _outboxOnce();
    if (outbox == null) return;
    for (final pending in await outbox.pending()) {
      if (_claimed.contains(pending.name)) continue;
      await _quietly(pending.remove);
    }
  }

  /// Writes [sealed] to disk before it is sent. Null when the disk refuses
  /// (full, no storage): the send still happens, it just cannot survive a
  /// cut.
  Future<PendingReport?> keep(SealedReport sealed) async {
    try {
      final outbox = await _outboxOnce();
      final pending = await outbox?.add(
        sealed,
        appKey: appKey,
        endpoint: endpoint,
      );
      if (pending != null) _claimed.add(pending.name);
      return pending;
    } on Object catch (e) {
      debugPrint('nabrila: could not keep the report on disk: $e');
      return null;
    }
  }

  /// Sends [sealed], already kept as [pending], while the tester watches.
  /// A failure that may pass leaves it on disk for the drain; a refusal
  /// deletes it.
  Future<DeliveryOutcome> deliver(
    SealedReport sealed,
    PendingReport? pending,
  ) => _inBackground(() => _deliver(sealed, pending));

  Future<DeliveryOutcome> _deliver(
    SealedReport sealed,
    PendingReport? pending,
  ) async {
    try {
      final result = await _sendWithQuickRetries(
        sealed,
        pending?.appKey ?? appKey,
        pending?.endpoint ?? endpoint,
      );
      onSent?.call(
        result,
        sealed.key,
        pending?.endpoint ?? endpoint,
        pending?.appKey ?? appKey,
        sealed.verdictSecret,
      );
      // The tester sees the link now; only a key still to store keeps it.
      await _quietly(
        () async => pending?.markSent(
          id: result.id,
          expiresAt: result.expiresAt,
          keyPending: result.keyCustodyFailed,
          keyToken: result.keyToken,
          shown: true,
        ),
      );
      return DeliveryOutcome.sent(result);
    } on UploadException catch (e) {
      if (e.retryable && pending != null) {
        await _quietly(() => pending.failed(retryAfter: e.retryAfter));
        return DeliveryOutcome.failed(e.failure, saved: true);
      }
      await _quietly(() async => pending?.remove());
      return DeliveryOutcome.failed(e.failure, saved: false);
    }
  }

  /// The capture flow closed: its report, if still waiting, now belongs to
  /// the drain.
  void release(PendingReport? pending) {
    if (pending == null || !_claimed.remove(pending.name)) return;
    unawaited(drain());
  }

  /// The tester saw (copied, shared or closed) the link of [result].
  Future<void> seen(UploadResult result, {bool dismiss = false}) async {
    if (dismiss) {
      delivered.value = delivered.value.where((r) => r != result).toList();
    }
    final pending = _unseen.remove(result.id);
    if (pending != null) await _quietly(() => pending.update(shown: true));
  }

  /// Sends every waiting report that is due, oldest first. A call during a
  /// running drain makes it go round once more and waits for it.
  Future<void> drain() {
    if (_closed) return Future.value();
    final running = _running;
    if (running != null) {
      _drainAgain = true;
      return running;
    }
    return _running = _inBackground(_drainLoop)
        .whenComplete(() => _running = null);
  }

  Future<void> _drainLoop() async {
    try {
      do {
        _drainAgain = false;
        await _drainOnce();
      } while (_drainAgain && !_closed);
    } on Object catch (e) {
      debugPrint('nabrila: outbox drain failed: $e');
    } finally {
      await _scheduleNext();
    }
  }

  Future<void> _drainOnce() async {
    final outbox = await _outboxOnce();
    if (outbox == null) return;
    for (final pending in await outbox.pending()) {
      if (_closed) return;
      if (_claimed.contains(pending.name)) continue;
      // One odd report never stops the others.
      try {
        if (!await _drainOne(pending)) return;
      } on Object catch (e) {
        debugPrint('nabrila: could not send a saved report: $e');
        try {
          await pending.failed();
        } on Object {
          // Read-only disk: it is tried again next time anyway.
        }
      }
    }
  }

  /// Handles one waiting report. False when the network is down and the
  /// round should stop.
  Future<bool> _drainOne(PendingReport pending) async {
    if (pending.sent) {
      if (!pending.shown) _announce(pending);
      if (pending.keyPending && pending.dueAt(_clock())) {
        await _storeKeyLater(pending);
      }
      return true;
    }
    if (!pending.dueAt(_clock())) return true;
    // A locked file (iOS before the first unlock) throws here and is tried
    // again later; it is not deleted.
    final sealed = await pending.load();
    try {
      final result = await uploadReport(
        client: client,
        endpoint: pending.endpoint,
        appKey: pending.appKey,
        sealed: sealed,
        keepKeyOnDevice: keepKeyOnDevice,
      );
      onSent?.call(
        result,
        sealed.key,
        pending.endpoint,
        pending.appKey,
        sealed.verdictSecret,
      );
      await pending.markSent(
        id: result.id,
        expiresAt: result.expiresAt,
        keyPending: result.keyCustodyFailed,
        keyToken: result.keyToken,
        shown: false,
      );
      _announce(pending);
    } on UploadException catch (e) {
      if (!e.retryable) {
        await pending.remove();
        return true;
      }
      await pending.failed(retryAfter: e.retryAfter);
      // Still no network: the others would fail the same way.
      if (e.failure == UploadFailure.network) return false;
    }
    return true;
  }

  /// Shows the link of a report sent in the background, once.
  void _announce(PendingReport pending) {
    final id = pending.sentId!;
    if (_unseen.containsKey(id)) return;
    _unseen[id] = pending;
    delivered.value = [
      ...delivered.value,
      UploadResult(
        id: id,
        link: buildShareLink(
          id: id,
          key: pending.key,
          origin: pending.endpoint,
        ),
        expiresAt: pending.expiresAt,
        keyStoredOnServer: !pending.keyPending,
        keyCustodyFailed: pending.keyPending,
      ),
    ];
  }

  /// The team plan keeps the key, and the first try to give it failed. It
  /// is tried again with the permission the upload got; without one (or
  /// when the app now keeps keys on the phone) it is not sent.
  Future<void> _storeKeyLater(PendingReport pending) async {
    final token = pending.keyToken;
    if (token == null || keepKeyOnDevice) {
      debugPrint('nabrila: the key of ${pending.sentId} stays on the phone.');
      await pending.update(keyPending: false);
      return;
    }
    final outcome = await storeKey(
      client: client,
      endpoint: pending.endpoint,
      appKey: pending.appKey,
      id: pending.sentId!,
      key: pending.key,
      keyToken: token,
    );
    switch (outcome) {
      case KeyUpload.stored:
        await pending.update(keyPending: false);
      case KeyUpload.refused:
        debugPrint('nabrila: the server refused the key of ${pending.sentId}.');
        await pending.update(keyPending: false);
      case KeyUpload.failed:
        await pending.failed();
    }
  }

  Future<void> _scheduleNext() async {
    _timer?.cancel();
    _timer = null;
    final outbox = await _outboxOnce();
    if (outbox == null || _closed) return;
    final waiting = (await outbox.pending()).where(
      (p) => !_claimed.contains(p.name) && (!p.sent || p.keyPending),
    );
    if (waiting.isEmpty || _closed) return;
    final next = waiting
        .map((p) => p.nextAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    var wait = next.difference(_clock().toUtc());
    if (wait < const Duration(seconds: 5)) wait = const Duration(seconds: 5);
    if (wait > PendingReport.maxWait) wait = PendingReport.maxWait;
    _timer = Timer(wait, () => unawaited(drain()));
  }

  Future<UploadResult> _sendWithQuickRetries(
    SealedReport sealed,
    String appKey,
    String endpoint,
  ) async {
    for (var attempt = 0; ; attempt++) {
      final started = _clock();
      try {
        return await uploadReport(
          client: client,
          endpoint: endpoint,
          appKey: appKey,
          sealed: sealed,
          keepKeyOnDevice: keepKeyOnDevice,
        );
      } on UploadException catch (e) {
        final fast = _clock().difference(started) < const Duration(seconds: 10);
        final again =
            e.retryable &&
            e.failure != UploadFailure.rateLimited &&
            fast &&
            attempt < quickRetries.length;
        if (!again) rethrow;
        await _sleep(quickRetries[attempt]);
      }
    }
  }

  Future<ReportOutbox?> _outboxOnce() => _outbox ??= () async {
    final dir = await _storageDir();
    return dir == null ? null : ReportOutbox(dir, clock: _clock);
  }();

  /// Runs [work] with time granted by iOS to finish it in the background
  /// (about 30 seconds). Android keeps a backgrounded app running anyway.
  static Future<T> _inBackground<T>(Future<T> Function() work) async {
    int? task;
    try {
      task = await _channel.invokeMethod<int>('beginBackground');
    } on Object {
      task = null;
    }
    try {
      return await work();
    } finally {
      if (task != null) {
        unawaited(
          _channel.invokeMethod<void>('endBackground', task).catchError((_) {}),
        );
      }
    }
  }

  static const MethodChannel _channel = MethodChannel('nabrila/replay');

  static Future<void> _quietly(Future<void> Function() work) async {
    try {
      await work();
    } on Object {
      // The report is still on disk; the drain will find it.
    }
  }
}

/// The app's private folder that is never purged and never backed up
/// (`ios/` and `android/` of this package), or a temporary folder where the
/// native side is missing.
Future<Directory?> defaultStorageDir() async {
  try {
    final path = await ReportDelivery._channel.invokeMethod<String>(
      'storageDir',
    );
    if (path != null) return Directory(path);
  } on MissingPluginException {
    // Desktop or tests.
  } on PlatformException {
    // Falls through to the temporary folder.
  }
  try {
    return Directory('${Directory.systemTemp.path}/nabrila-outbox');
  } on Object {
    return null;
  }
}
