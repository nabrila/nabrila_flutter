# Nabrila for Flutter

[![pub package](https://img.shields.io/pub/v/nabrila.svg)](https://pub.dev/packages/nabrila)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/nabrila/nabrila_flutter/blob/main/LICENSE)
[![CI](https://github.com/nabrila/nabrila_flutter/actions/workflows/ci.yml/badge.svg)](https://github.com/nabrila/nabrila_flutter/actions/workflows/ci.yml)

Bug reports from a tester's phone: annotated screenshot, taps, route, console
and HTTP calls in one encrypted link. Copy it to Claude Code or Cursor.

**[See an example report](https://nabrila.com/r/example)** ·
[Docs](https://nabrila.com/docs) ·
[Create your workspace](https://nabrila.com/login)

Whoever tests your app taps a floating button (or shakes the phone), draws on
the screenshot, hides what is private and writes what happened. Your team gets
a link with the screenshot, the taps before it, the screen they were on, the
console and the server calls, and can paste it into a coding agent as is.

## Quick start

It takes three steps.

**1. Get your `appKey`.** Sign in at [nabrila.com](https://nabrila.com/login),
create your workspace and register your app. The `appKey` (`nbr_...`) is
shown once.

**2. Add the package and wrap your app.**

```sh
flutter pub add nabrila
```

```dart
import 'package:flutter/material.dart';
import 'package:nabrila/nabrila.dart';

void main() {
  Nabrila.run(
    appKey: 'nbr_...',
    enabled: const bool.fromEnvironment('NABRILA_ENABLED'),
    app: () => runApp(const NabrilaScope(child: MyApp())),
  );
}
```

**3. Build for your testers and tap the button.**

```sh
flutter build apk --dart-define=NABRILA_ENABLED=true
```

That's it. Builds without the `--dart-define` (the one you ship to the stores)
have no button, record nothing and upload nothing.

Add `--dart-define=NABRILA_COMMIT=$(git rev-parse HEAD)` and every report says
which commit the build came from, so your coding agent can see
[what changed since](https://nabrila.com/docs/coding-agents).

## Record more

Route changes, with `MaterialApp` or `go_router` (shell routes included):

```dart
MaterialApp(navigatorObservers: [Nabrila.navigatorObserver])
GoRouter(observers: [Nabrila.navigatorObserver], routes: [...])
```

HTTP calls. You choose the client; nothing is intercepted globally. With
`package:http`:

```dart
final client = NabrilaHttpClient(http.Client());
```

With Dio:

```dart
import 'package:nabrila/dio.dart';

dio.interceptors.add(NabrilaDioInterceptor());
```

Your own data in every report (environment, test account, feature flags):

```dart
Nabrila.setContext('env', 'staging');
```

When the person signed in to your app changes (sign-out, account switch),
forget what was recorded so far, so the next report never carries the
previous person's taps, logs or calls:

```dart
Nabrila.clearSession();
```

More in [Flutter SDK](https://nabrila.com/docs/flutter-sdk) and
[Network requests](https://nabrila.com/docs/network).

## What a report carries

The screenshot with the tester's drawings and note, and a short
[replay](https://nabrila.com/docs/replay) of the moments before it, as video
or pictures. The kind of report (something fails, looks wrong, shows wrong
data, or an idea) and the element the tester pointed at, with its file and
line in debug builds.

The last 150 events: route changes, taps with what was touched, `print` and
`debugPrint` output, Flutter and platform errors, and HTTP calls (method, URL,
status, duration and size). Also your app name and version, OS, screen size,
text scale and locale. Before sending, the tester sees everything the report
carries.

It is a report for anything a person notices, not only crashes. If the
connection drops, it waits on the phone and goes out later, with no
duplicates ([Report delivery](https://nabrila.com/docs/delivery)). When your
team marks it as fixed, the tester's app says so; if the team names the version
with the fix, the app asks the tester, once they have it, whether it works now,
and the answer shows in the report. Only the tester's phone can answer: each
report has a secret that never leaves it (and is not in the link), and an
answer that could not be sent is kept and retried.

## Privacy and encryption

The report is encrypted on the phone with AES-256-GCM before it is uploaded.
On the Free plan the key travels only in the link's `#k=` fragment, which
browsers never send to a server, so Nabrila cannot read your reports. Anyone
with the whole link can, so share it where you trust the audience.

Text fields are never read. Wrap anything private in `NabrilaMask` and it
leaves the screenshot and the replay as a solid block, and taps inside it
keep neither a label nor a position:

```dart
NabrilaMask(child: CardNumberView())
```

Request headers and bodies stay out unless you pass `captureBodies: true`,
and even then tokens, cookies and passwords are replaced by `[REDACTED]`.
Only text bodies (JSON, forms, XML, plain text) are previewed, up to 64 KB;
files and images go out untouched and responses still stream. Console lines
are redacted the same way.

On paid plans the server keeps the key so your team can open reports from
the inbox. To keep it on the phone whatever the plan says, start with
`Nabrila.run(keepKeyOnDevice: true, ...)`; reports then open only from their
link. Reports go only to an `https://` endpoint.
The SDK collects no device identifiers, advertising IDs, device model,
location or contacts. For the Google Play and App Store forms, see
[What data it sends](https://nabrila.com/docs/data-collected).

## Platforms

| Platform | Support |
| --- | --- |
| Android | 7 (API 24) or newer; replay from Android 8 (API 26) |
| iOS | 13 or newer |
| Desktop | Yes; the replay is kept as pictures, with no video |
| Web | No (the SDK uses `dart:io`) |

Flutter 3.47 or newer (Dart 3.13). It works the same whether your app uses
`material_ui` or the Material library bundled with Flutter.

## Limits

Native views (maps, WebView, video, ads, camera) show up blank, and the SDK
marks them so a blank area is not mistaken for a bug. Only `print` and
`debugPrint` reach the console, not `dart:developer.log`. Reports go out
while the app is open, with no background upload. Every limit is in
[Known limits](https://nabrila.com/docs/limits).

## Learn more

- [Quickstart](https://nabrila.com/docs/quickstart): from zero to your first
  report.
- [Hide private data](https://nabrila.com/docs/masking) and
  [Encryption and keys](https://nabrila.com/docs/security), with the `NBR1`
  envelope format.
- [Open in your agent](https://nabrila.com/docs/coding-agents): Claude Code,
  Cursor and the local MCP server.
- Questions: support@nabrila.com.
  [Issues](https://github.com/nabrila/nabrila_flutter/issues) are welcome.

## License

MIT. See [LICENSE](https://github.com/nabrila/nabrila_flutter/blob/main/LICENSE).
