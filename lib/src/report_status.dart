import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'loop_store.dart';
import 'status_crypto.dart';
import 'status_model.dart';
import 'uploader.dart';
import 'verdict_post.dart';
import 'version.dart';

export 'status_crypto.dart';
export 'status_model.dart';
export 'version.dart';

/// The team's answers the tester sees; `verified` and `reopened` are theirs.
const Set<String> _teamStatuses = {'fixed', 'needs_info', 'wont_fix'};

/// Remembers the reports this phone sent and asks the server, now and
/// then, whether the team changed their status. The server answers only
/// for reports of this app key; notes come encrypted with each report's
/// key, which never left this phone and the link.
class ReportLoop {
  ReportLoop({
    required this.client,
    required Future<Directory?> Function() storageDir,
    DateTime Function()? clock,
    Future<AppVersion?> Function()? appVersion,
  }) : _clock = clock ?? DateTime.now,
       _appVersion = appVersion ?? (() async => null) {
    _store = LoopStore(storageDir: storageDir, clock: _clock);
  }

  final http.Client client;
  final DateTime Function() _clock;
  late final LoopStore _store;

  /// The app as it runs now, to know whether it has the fixing version.
  final Future<AppVersion?> Function() _appVersion;

  /// Changes not seen yet; the scope shows the first one.
  final ValueNotifier<List<ReportStatus>> updates = ValueNotifier(const []);

  /// Reports whose answer is on its way or could not go out yet; the banner
  /// shows it. A report that is not here has nothing pending to show.
  final ValueNotifier<Map<String, AnswerState>> answering = ValueNotifier(
    const {},
  );

  /// Reports with an answer being sent right now, so a poll does not send
  /// the same one at the same time.
  final Set<String> _inFlight = {};

  /// Shortest time between two automatic checks.
  static const Duration every = Duration(minutes: 15);
  static const int maxReports = LoopStore.maxReports;
  static const Duration maxAge = LoopStore.maxAge;

  /// Keeps a sent report so its status can be asked for later.
  Future<void> remember({
    required String id,
    required List<int> key,
    required String endpoint,
    required String appKey,
    String? expiresAt,
    List<int>? verdictSecret,
  }) => _store.remember(
    id: id,
    key: key,
    endpoint: endpoint,
    appKey: appKey,
    expiresAt: expiresAt,
    verdictSecret: verdictSecret,
  );

  /// Sends the answers still pending, then asks for the status of every
  /// remembered report, at most once every [every] unless [force]. Never
  /// throws.
  Future<void> poll({bool force = false}) => _store.serial(() async {
    try {
      final file = await _store.file();
      if (file == null || !await file.exists()) return;
      final state = await _store.read(file);
      final now = _clock().toUtc();
      final reports = _store.prune(_store.reports(state));
      // A pending answer goes out on every poll, whatever the 15 minutes.
      await _retryVerdicts(reports);
      state['reports'] = reports;
      final last = DateTime.tryParse('${state['polledAt']}');
      // A new version of the app may be the one with a fix: ask right away.
      final app = await _appVersion();
      final appMark = app == null ? null : '${app.version}+${app.build}';
      final updated = appMark != null && appMark != state['polledApp'];
      if (!force &&
          !updated &&
          last != null &&
          now.difference(last).abs() < every) {
        await _store.write(file, state);
        return;
      }
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
      var answered = false;
      for (final group in groups.entries) {
        final [endpoint, appKey] = group.key.split('\n');
        try {
          final list = await _ask(endpoint, appKey, group.value, reports);
          if (list == null) continue;
          answered = true;
          found.addAll(list);
        } on Object catch (e) {
          // One failing server never stops the others.
          debugPrint('nabrila: could not check report status: $e');
        }
      }
      // Only an answer counts as a check: offline, the app update is still
      // to be asked about when the network comes back.
      if (answered) {
        state
          ..['polledAt'] = now.toIso8601String()
          ..['polledApp'] = appMark;
      }
      await _store.write(file, state);
      final fresh = <ReportStatus>[];
      for (final s in found) {
        if (!_teamStatuses.contains(s.status)) continue;
        final entry = reports[s.id];
        final fixedIn = s.fixedIn;
        if (s.status == 'fixed' &&
            fixedIn != null &&
            s.updatedAt != null &&
            app != null &&
            entry?['verdictSecret'] is String &&
            entry?['asked'] != s.mark &&
            hasVersion(
                  fixedIn: fixedIn,
                  version: app.version,
                  build: app.build,
                ) ==
                true) {
          fresh.add(
            ReportStatus(
              id: s.id,
              status: s.status,
              note: s.note,
              fixedIn: fixedIn,
              updatedAt: s.updatedAt,
              askVerdict: true,
            ),
          );
        } else if (entry?['seen'] != s.mark) {
          fresh.add(s);
        }
      }
      if (fresh.isNotEmpty) {
        final known = {for (final u in updates.value) u.mark + u.id};
        updates.value = [
          ...updates.value,
          for (final s in fresh)
            if (!known.contains(s.mark + s.id)) s,
        ];
      }
    } on Object catch (e) {
      debugPrint('nabrila: could not check report status: $e');
    }
  });

  /// Tries again every answer saved as pending in [reports] (changing it);
  /// the caller writes it down.
  Future<void> _retryVerdicts(Map<String, Map<String, Object?>> reports) async {
    for (final e in reports.entries) {
      final pending = e.value['pendingVerdict'];
      if (pending is! Map || _inFlight.contains(e.key)) continue;
      final askedAt = '${pending['askedAt']}';
      final outcome = await postVerdict(client, e.key, e.value, pending);
      if (outcome == VerdictOutcome.retry) {
        _showAnswer(e.key, askedAt, AnswerState.failed);
      } else {
        _settle(e.value, e.key, askedAt, outcome == VerdictOutcome.done);
      }
    }
  }

  /// The answer is over, taken or refused for good: forget it and close its
  /// question.
  void _settle(
    Map<String, Object?> entry,
    String id,
    String askedAt,
    bool taken,
  ) {
    final pending = entry.remove('pendingVerdict');
    if (taken && pending is Map) entry['verdict'] = pending['status'];
    // The question is over: the same `fixed` is not shown again.
    entry['seen'] = 'fixed|$askedAt';
    _showAnswer(id, askedAt, null);
    updates.value = updates.value
        .where((u) => !(u.id == id && u.updatedAt == askedAt))
        .toList();
  }

  /// Marks the question of [id] as sending or failed in the banner (null
  /// clears it), only while that very question is still shown.
  void _showAnswer(String id, String askedAt, AnswerState? state) {
    final shown = updates.value.any(
      (u) => u.id == id && u.updatedAt == askedAt,
    );
    final next = {...answering.value};
    if (state == null || !shown) {
      next.remove(id);
    } else {
      next[id] = state;
    }
    answering.value = next;
  }

  /// Null when the server did not answer 200.
  Future<List<ReportStatus>?> _ask(
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
    if (response.statusCode != 200) return null;
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
      final plain = sealed is String
          ? await openStatusNote(base64Decode('${entry['key']}'), id, sealed)
          : null;
      final note = plain == null ? null : StatusNote.decode(plain);
      out.add(
        ReportStatus(
          id: id,
          status: status,
          note: note?.text,
          fixedIn: note?.fixedIn,
          updatedAt: item['updatedAt'] as String?,
        ),
      );
    }
    return out;
  }

  /// The tester saw [update]: it is not shown again unless it changes. A
  /// question closed without an answer is not asked again either.
  Future<void> seen(ReportStatus update) async {
    updates.value = updates.value.where((u) => u != update).toList();
    await _store.mark(update.id, {
      'seen': update.mark,
      if (update.askVerdict) 'asked': update.mark,
    });
  }

  /// The tester answers whether the fix works: `verified` or `reopened`,
  /// proved with the verdict secret that was made on this phone for that
  /// report and never left it. The answer is saved before it is sent and
  /// goes out again on every [poll] until the server takes it (`200`) or
  /// refuses it for good (`403`, `404`, `409`).
  ///
  /// True when the question is closed: the server took the answer or will
  /// never take it. False when it could not be sent yet (the answer stays
  /// pending and is retried) or this phone cannot answer that report.
  Future<bool> answer(ReportStatus update, {required bool works}) async {
    final id = update.id;
    final askedAt = update.updatedAt;
    if (_inFlight.contains(id)) return false;
    final status = works ? 'verified' : 'reopened';
    final entry = askedAt == null
        ? null
        : await _store.edit((all) {
            final entry = all[id];
            if (entry == null || entry['verdictSecret'] is! String) return null;
            return entry
              ..['pendingVerdict'] = {'status': status, 'askedAt': askedAt}
              ..['asked'] = update.mark;
          });
    if (entry == null || askedAt == null) {
      // A report this phone cannot answer: the question just goes away.
      updates.value = updates.value.where((u) => u != update).toList();
      return false;
    }
    _inFlight.add(id);
    try {
      _showAnswer(id, askedAt, AnswerState.sending);
      final outcome = await postVerdict(client, id, entry, {
        'status': status,
        'askedAt': askedAt,
      });
      if (outcome == VerdictOutcome.retry) {
        _showAnswer(id, askedAt, AnswerState.failed);
        return false;
      }
      await _store.edit((all) {
        final saved = all[id];
        if (saved != null) {
          _settle(saved, id, askedAt, outcome == VerdictOutcome.done);
        }
      });
      // The report was forgotten meanwhile: close the question anyway.
      _settle({}, id, askedAt, false);
      return true;
    } finally {
      _inFlight.remove(id);
    }
  }

  /// Forgets every sent report.
  Future<void> clear() async {
    updates.value = const [];
    answering.value = const {};
    await _store.delete();
  }
}
