import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nabrila/src/redaction.dart';

void main() {
  test('sanitizeUrl redacts sensitive query values and drops user info', () {
    final url = Uri.parse(
      'https://user:pw@api.example.com:8443/v1/pay?token=abc&page=2&API_KEY=z#frag',
    );
    expect(
      sanitizeUrl(url),
      'https://api.example.com:8443/v1/pay?token=[REDACTED]&page=2&API_KEY=[REDACTED]',
    );
  });

  test('sanitizeUrl keeps a plain URL as it is', () {
    expect(
      sanitizeUrl(Uri.parse('https://api.example.com/v1/items')),
      'https://api.example.com/v1/items',
    );
  });

  test('sanitizeHeaders redacts the sensitive ones', () {
    final out = sanitizeHeaders({
      'Authorization': ['Bearer x'],
      'Cookie': ['a=b'],
      'X-Api-Key': ['k'],
      'Accept': ['application/json'],
    });
    expect(out['authorization'], redacted);
    expect(out['cookie'], redacted);
    expect(out['x-api-key'], redacted);
    expect(out['accept'], 'application/json');
  });

  test('sessions, presigned URLs and auth headers count as sensitive', () {
    for (final name in [
      'JSESSIONID',
      'X-Amz-Signature',
      'X-Amz-Credential',
      'x-auth-user',
      'id_jwt',
      'Set-Cookie',
    ]) {
      expect(isSensitiveName(name), isTrue, reason: name);
    }
    expect(isSensitiveName('Accept-Language'), isFalse);
    expect(
      sanitizeUrl(Uri.parse('https://s3.test/f.png?X-Amz-Signature=abc&w=2')),
      'https://s3.test/f.png?X-Amz-Signature=$redacted&w=2',
    );
  });

  test('sanitizeBody redacts nested JSON keys', () {
    final out = sanitizeBody(
      jsonEncode({
        'user': 'ana',
        'password': 'hunter2',
        'nested': {
          'refresh_token': 't',
          'items': [
            {'secret': 's', 'id': 1},
          ],
        },
      }),
    );
    final json = jsonDecode(out!) as Map<String, dynamic>;
    expect(json['user'], 'ana');
    expect(json['password'], redacted);
    expect(json['nested']['refresh_token'], redacted);
    expect(json['nested']['items'][0]['secret'], redacted);
    expect(json['nested']['items'][0]['id'], 1);
  });

  test('sanitizeBody redacts form fields and caps the preview', () {
    expect(sanitizeBody('user=ana&password=x'), 'user=ana&password=[REDACTED]');
    expect(sanitizeBody('a' * 20000)!.length, 8000);
    expect(sanitizeBody(''), isNull);
    expect(sanitizeBody(null), isNull);
  });
}
