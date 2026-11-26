import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'uploader.dart';

/// The remote switch for the replay: Nabrila can turn it off for phone
/// models where the native encoder is known to crash, without a new build
/// of the app. The answer is kept on the phone and asked again once a day,
/// so a phone on a blocked list is protected from its next start on, even
/// offline.
class RemoteConfig {
  RemoteConfig({
    required this.client,
    required this.endpoint,
    required this.appKey,
    required Future<Directory?> Function() storageDir,
    Future<String?> Function()? deviceModel,
    DateTime Function()? clock,
  }) : _storageDir = storageDir,
       _deviceModel = deviceModel ?? _nativeModel,
       _clock = clock ?? DateTime.now;

  final http.Client client;
  final String endpoint;
  final String appKey;
  final Future<Directory?> Function() _storageDir;
  final Future<String?> Function() _deviceModel;
  final DateTime Function() _clock;

  /// Calls [disableReplay] when this phone's model is blocked: first from
  /// the answer kept on disk, then from a fresh one when it is a day old.
  /// Never throws.
  Future<void> apply(VoidCallback disableReplay) async {
    try {
      final model = (await _deviceModel())?.toLowerCase().trim();
      final file = await _file();
      if (model == null || model.isEmpty || file == null) return;
      final kept = await _read(file);
      if (_blocked(kept, model)) {
        disableReplay();
        return;
      }
      final fetchedAt = DateTime.tryParse('${kept?['fetchedAt']}');
      final refresh = Duration(
        seconds: (kept?['refreshAfterSeconds'] as num?)?.toInt() ?? 0,
      );
      final now = _clock().toUtc();
      if (kept != null &&
          kept['appKey'] == appKey &&
          fetchedAt != null &&
          now.difference(fetchedAt).abs() < refresh) {
        return;
      }
      final fresh = await _fetch();
      if (fresh == null) return;
      await _write(file, fresh..['fetchedAt'] = now.toIso8601String());
      if (_blocked(fresh, model)) disableReplay();
    } on Object catch (e) {
      debugPrint('nabrila: could not read the remote config: $e');
    }
  }

  bool _blocked(Map<String, Object?>? config, String model) {
    if (config == null || config['appKey'] != appKey) return false;
    final patterns = config['blockedDevices'];
    if (patterns is! List) return false;
    return patterns.whereType<String>().any((p) => matchesDevice(p, model));
  }

  Future<Map<String, Object?>?> _fetch() async {
    final response = await sendJson(
      client,
      'GET',
      Uri.parse('$endpoint/api/v1/config'),
      appKey,
    );
    if (response.statusCode != 200) return null;
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    if (json is! Map) return null;
    final replay = json['replay'];
    final blocked = replay is Map ? replay['blockedDevices'] : null;
    final refresh = json['refreshAfterSeconds'];
    return {
      'appKey': appKey,
      'blockedDevices': blocked is List
          ? blocked.whereType<String>().toList()
          : const <String>[],
      'refreshAfterSeconds': refresh is num
          ? refresh.clamp(300, 7 * 86400).toInt()
          : 86400,
    };
  }

  Future<File?> _file() async {
    final dir = await _storageDir();
    return dir == null ? null : File('${dir.path}/loop/config.json');
  }

  Future<Map<String, Object?>?> _read(File file) async {
    try {
      return (jsonDecode(await file.readAsString()) as Map)
          .cast<String, Object?>();
    } on Object {
      return null;
    }
  }

  Future<void> _write(File file, Map<String, Object?> config) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(config), flush: true);
    await tmp.rename(file.path);
  }

  static Future<String?> _nativeModel() async {
    try {
      return await const MethodChannel(
        'nabrila/replay',
      ).invokeMethod<String>('deviceModel');
    } on Object {
      return null;
    }
  }
}

/// Whether [model] (`"manufacturer model"`, lowercase) matches [pattern], a
/// lowercase glob where `*` stands for anything.
bool matchesDevice(String pattern, String model) {
  final parts = pattern.toLowerCase().split('*').map(RegExp.escape);
  return RegExp('^${parts.join('.*')}\$').hasMatch(model);
}
