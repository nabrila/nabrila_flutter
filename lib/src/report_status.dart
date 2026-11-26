import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'uploader.dart';

/// Header of the upload that carries [statusHashOf] the report key.
const String statusHashHeader = 'X-Nabrila-Status';

const String _info = 'nabrila-status-v1';

/// `HKDF-SHA256(key, salt: empty, info: "nabrila-status-v1")`: whoever
/// holds the link can derive it and prove it to the server to set the
/// report's status; the server only keeps its hash.
Future<Uint8List> statusSecretOf(List<int> key) async {
  final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: SecretKey(key),
    nonce: const [],
    info: utf8.encode(_info),
  );
  return Uint8List.fromList(await derived.extractBytes());
}

/// `base64url(SHA-256(statusSecret))`, sent with the upload.
Future<String> statusHashOf(List<int> key) async {
  final hash = await Sha256().hash(await statusSecretOf(key));
  return base64UrlNoPad(hash.bytes);
}

String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List _fromBase64Url(String value) =>
    base64Url.decode(base64Url.normalize(value));

/// Opens the team's note to the tester: `iv(12) || ciphertext || tag(16)`,
/// AES-256-GCM with the report key and `"nabrila-status-v1:" + id` as AAD.
/// Null when it does not open.
Future<String?> openStatusNote(List<int> key, String id, String sealed) async {
  try {
    final bytes = _fromBase64Url(sealed);
    if (bytes.length < 12 + 16 + 1) return null;
    final box = SecretBox(
      bytes.sublist(12, bytes.length - 16),
      nonce: bytes.sublist(0, 12),
      mac: Mac(bytes.sublist(bytes.length - 16)),
    );
    final clear = await AesGcm.with256bits().decrypt(
      box,
      secretKey: SecretKey(key),
      aad: utf8.encode('$_info:$id'),
    );
    return utf8.decode(clear);
  } on Object {
    return null;
  }
}

/// What the team said about a report the tester sent.
class ReportStatus {
  const ReportStatus({
    required this.id,
    required this.status,
    this.note,
    this.updatedAt,
  });

  final String id;

  /// `fixed`, `needs_info` or `wont_fix` (`open` is never shown).
  final String status;

  /// The team's note, decrypted on the phone.
  final String? note;
  final String? updatedAt;

  String get _mark => '$status|$updatedAt';
}

/// Remembers the reports this phone sent and asks the server, now and
/// then, whether the team changed their status. The server answers only
/// for reports of this app key; notes come encrypted with each report's
/// key, which never left this phone and the link.
class ReportLoop {
  ReportLoop({
    required this.client,
    required Future<Directory?> Function() storageDir,
    DateTime Function()? clock,
  }) : _storageDir = storageDir,
       _clock = clock ?? DateTime.now;

  final http.Client client;
  final Future<Directory?> Function() _storageDir;
  final DateTime Function() _clock;

  /// Changes not seen yet; the scope shows the first one.
  final ValueNotifier<List<ReportStatus>> updates = ValueNotifier(const []);

  /// Shortest time between two automatic checks.
  static const Duration every = Duration(minutes: 15);
  static const int maxReports = 50;
  static const Duration maxAge = Duration(days: 31);

  Future<void> _last = Future.value();

  Future<T> _serial<T>(Future<T> Function() work) {
    final run = _last.then((_) => work());
    _last = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<File?> _file() async {
    final dir = await _storageDir();
    return dir == null ? null : File('${dir.path}/loop/sent.json');
  }

  Future<Map<String, Object?>> _read(File file) async {
    try {
      return (jsonDecode(await file.readAsString()) as Map)
          .cast<String, Object?>();
    } on Object {
      return {};
    }
  }

  Future<void> _write(File file, Map<String, Object?> state) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(state), flush: true);
    await tmp.rename(file.path);
  }

  Map<String, Map<String, Object?>> _reports(Map<String, Object?> state) {
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
  }) => _serial(() async {
    final file = await _file();
    if (file == null) return;
    final state = await _read(file);
    final reports = _reports(state)
      ..[id] = {
        'key': base64Encode(key),
        'endpoint': endpoint,
        'appKey': appKey,
        'sentAt': _clock().toUtc().toIso8601String(),
        'expiresAt': expiresAt,
      };
    state['reports'] = _prune(reports);
    await _write(file, state);
  });

  Map<String, Map<String, Object?>> _prune(
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

  /// Asks for the status of every remembered report, at most once every
  /// [every] unless [force]. Never throws.
  Future<void> poll({bool force = false}) => _serial(() async {
    try {
      final file = await _file();
      if (file == null || !await file.exists()) return;
      final state = await _read(file);
      final now = _clock().toUtc();
      final last = DateTime.tryParse('${state['polledAt']}');
      if (!force && last != null && now.difference(last).abs() < every) return;
      final reports = _prune(_reports(state));
      state
        ..['reports'] = reports
        ..['polledAt'] = now.toIso8601String();
      await _write(file, state);
      final groups = <String, List<String>>{};
      for (final e in reports.entries) {
        groups
            .putIfAbsent(
              '${e.value['endpoint']}\n${e.value['appKey']}',
              () => [],
            )
            .add(e.key);
      }
      final found = <ReportStatus>[];
      for (final group in groups.entries) {
        final [endpoint, appKey] = group.key.split('\n');
        found.addAll(await _ask(endpoint, appKey, group.value, reports));
      }
      final fresh = [
        for (final s in found)
          if (s.status != 'open' && reports[s.id]?['seen'] != s._mark) s,
      ];
      if (fresh.isNotEmpty) {
        final known = {for (final u in updates.value) u._mark + u.id};
        updates.value = [
          ...updates.value,
          for (final s in fresh)
            if (!known.contains(s._mark + s.id)) s,
        ];
      }
    } on Object catch (e) {
      debugPrint('nabrila: could not check report status: $e');
    }
  });

  Future<List<ReportStatus>> _ask(
    String endpoint,
    String appKey,
    List<String> ids,
    Map<String, Map<String, Object?>> reports,
  ) async {
    final response = await sendJson(
      client,
      'POST',
      Uri.parse('$endpoint/api/v1/reports/status'),
      appKey,
      {'ids': ids.take(maxReports).toList()},
    );
    if (response.statusCode != 200) return const [];
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    final list = json is Map ? json['reports'] : null;
    if (list is! List) return const [];
    final out = <ReportStatus>[];
    for (final item in list.whereType<Map>()) {
      final id = item['id'];
      final status = item['status'];
      final entry = reports[id];
      if (id is! String || status is! String || entry == null) continue;
      final sealed = item['note'];
      final note = sealed is String
          ? await openStatusNote(base64Decode('${entry['key']}'), id, sealed)
          : null;
      out.add(
        ReportStatus(
          id: id,
          status: status,
          note: note,
          updatedAt: item['updatedAt'] as String?,
        ),
      );
    }
    return out;
  }

  /// The tester saw [update]: it is not shown again unless it changes.
  Future<void> seen(ReportStatus update) async {
    updates.value = updates.value.where((u) => u != update).toList();
    await _serial(() async {
      final file = await _file();
      if (file == null || !await file.exists()) return;
      final state = await _read(file);
      final reports = _reports(state);
      reports[update.id]?['seen'] = update._mark;
      state['reports'] = reports;
      await _write(file, state);
    });
  }

  /// Forgets every sent report.
  Future<void> clear() => _serial(() async {
    updates.value = const [];
    final file = await _file();
    if (file != null && await file.exists()) await file.delete();
  });
}
