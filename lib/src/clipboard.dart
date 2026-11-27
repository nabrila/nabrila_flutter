import 'package:flutter/services.dart';

import 'events.dart' show clip;

const MethodChannel _channel = MethodChannel('nabrila/replay');

/// Copies a link that carries a report key. Android 13 and later mark it
/// as sensitive, so it is hidden from the clipboard preview and keyboard
/// suggestions; iOS keeps it off the person's other devices (no Universal
/// Clipboard). Without the native side it is a plain copy.
Future<void> copySecret(String text) async {
  try {
    final done = await _channel.invokeMethod<bool>('copySensitive', {
      'text': text,
    });
    if (done == true) return;
  } on Object {
    // Older native side, desktop or tests: a plain copy below.
  }
  await Clipboard.setData(ClipboardData(text: text));
}

/// [link] with its key cut to the first characters, for the screen: the
/// whole key is copied or shared, never shown.
String maskedLink(String link) {
  final at = link.indexOf('#k=');
  if (at < 0) return link;
  final key = link.substring(at + 3);
  return '${link.substring(0, at + 3)}${clip(key, 4)}…';
}
