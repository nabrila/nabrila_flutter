import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nabrila/src/manifest.dart' show sdkVersion;
import 'package:nabrila/src/uploader.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('names the SDK version and the platform, nothing else', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(clientHeader, 'nabrila-flutter/$sdkVersion (android)');
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(clientHeader, 'nabrila-flutter/$sdkVersion (ios)');
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(clientHeader, 'nabrila-flutter/$sdkVersion (other)');
  });

  test('sends the version that pubspec.yaml publishes', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version: *(\S+)$', multiLine: true);
    expect(version.firstMatch(pubspec)?.group(1), sdkVersion);
  });
}
