import 'dart:convert';
import 'dart:io';

import 'status_crypto.dart';

/// `loop/sent.json`: the reports this phone sent, each with its key, its
/// verdict secret and the marks of what the tester already saw or answered.
/// Every read-modify-write runs one at a time.
class LoopStore {
  LoopStore({
    required Future<Directory?> Function() storageDir,
    required DateTime Function() clock,
  }) : _storageDir = storageDir,
       _clock = clock;

  final Future<Directory?> Function() _storageDir;
  final DateTime Function() _clock;

  static const int maxReports = 50;
  static const Duration maxAge = Duration(days: 31);

  Future<void> _last = Future.value();

  Future<T> serial<T>(Future<T> Function() work) {
    final run = _last.then((_) => work());
    _last = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<File?> file() async {
    final dir = await _storageDir();
    return dir == null ? null : File('${dir.path}/loop/sent.json');
  }

  Future<Map<String, Object?>> read(File file) async {
    try {
      return (jsonDecode(await file.readAsString()) as Map)
          .cast<String, Object?>();
    } on Object {
      return {};
    }
  }

  Future<void> write(File file, Map<String, Object?> state) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(state), flush: true);
    await tmp.rename(file.path);
  }

  Map<String, Map<String, Object?>> reports(Map<String, Object?> state) {
    final raw = state['reports'];
    if (raw is! Map) return {};
    return {
      for (final e in raw.entries)
        if (e.value is Map)
          '${e.key}': (e.value as Map).cast<String, Object?>(),
    };
  }

  /// Keeps a sent report so its status can be asked for later.
  Future<void> remember({
    required String id,
    required List<int> key,
    required String endpoint,
    required String appKey,
    String? expiresAt,
    List<int>? verdictSecret,
  }) => serial(() async {
    final file = await this.file();
    if (file == null) return;
    final state = await read(file);
    final all = reports(state)
      ..[id] = {
        'key': base64Encode(key),
        // base64url without padding, as the answer sends it (D34).
        if (verdictSecret != null)
          'verdictSecret': base64UrlNoPad(verdictSecret),
        'endpoint': endpoint,
        'appKey': appKey,
        'sentAt': _clock().toUtc().toIso8601String(),
        'expiresAt': expiresAt,
      };
    state['reports'] = prune(all);
    await write(file, state);
  });

  /// Drops what is too old or expired and keeps the newest [maxReports].
  Map<String, Map<String, Object?>> prune(
    Map<String, Map<String, Object?>> reports,
  ) {
    final now = _clock().toUtc();
    final alive =
        reports.entries.where((e) {
          final sent = DateTime.tryParse('${e.value['sentAt']}');
          final expires = DateTime.tryParse('${e.value['expiresAt']}');
          if (sent == null || now.difference(sent).abs() > maxAge) return false;
          return expires == null || expires.isAfter(now);
        }).toList()..sort(
          (a, b) => '${b.value['sentAt']}'.compareTo('${a.value['sentAt']}'),
        );
    return Map.fromEntries(alive.take(maxReports));
  }

  /// Runs [change] on the saved reports and writes them back, serialized.
  /// Null when there is no file yet.
  Future<T?> edit<T>(T Function(Map<String, Map<String, Object?>>) change) =>
      serial(() async {
        final file = await this.file();
        if (file == null || !await file.exists()) return null;
        final state = await read(file);
        final all = reports(state);
        final result = change(all);
        state['reports'] = all;
        await write(file, state);
        return result;
      });

  /// Adds [values] to the entry of [id].
  Future<void> mark(String id, Map<String, Object?> values) =>
      edit((all) => all[id]?.addAll(values));

  /// Deletes the file.
  Future<void> delete() => serial(() async {
    final file = await this.file();
    if (file != null && await file.exists()) await file.delete();
  });
}
