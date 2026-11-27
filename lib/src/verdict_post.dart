import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'uploader.dart';

/// What became of sending the tester's answer.
enum VerdictOutcome { done, refused, retry }

/// `POST .../status` with the tester's own proof: no app key, no note and
/// nothing derived from the link. [entry] is the report's `sent.json` entry
/// and [pending] its `{status, askedAt}`.
Future<VerdictOutcome> postVerdict(
  http.Client client,
  String id,
  Map<String, Object?> entry,
  Map<Object?, Object?> pending,
) async {
  final secret = entry['verdictSecret'];
  if (secret is! String) return VerdictOutcome.refused;
  try {
    final response = await sendJson(
      client,
      'POST',
      Uri.parse(
        '${entry['endpoint']}/api/v1/reports/'
        '${Uri.encodeComponent(id)}/status',
      ),
      null,
      {
        'verdict': secret,
        'status': pending['status'],
        'askedAt': pending['askedAt'],
      },
    );
    return switch (response.statusCode) {
      200 => VerdictOutcome.done,
      // Wrong proof, no such report, or the team changed the status
      // meanwhile: asking again never changes the answer.
      403 || 404 || 409 => VerdictOutcome.refused,
      _ => VerdictOutcome.retry,
    };
  } on Object catch (e) {
    debugPrint('nabrila: could not send the answer: $e');
    return VerdictOutcome.retry;
  }
}
