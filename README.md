# Nabrila for Flutter

Instant bug reports with technical context for Flutter apps. A tester taps a
floating button, draws on the screenshot, hides what is private, and gets a
link. The report is encrypted on the phone (AES-256-GCM); on the free plan the
key lives only in the link's `#k=` fragment and never reaches the server.

MIT licensed. Version 0.1.0. Not published on pub.dev yet.

## Install

```yaml
dependencies:
  nabrila: ^0.1.0
```

Get an `appKey` (`nbr_...`) from your Nabrila workspace. It is shown once.

## Use

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

Turn it on only in test builds:

```sh
flutter build apk --dart-define=NABRILA_ENABLED=true
```

TestFlight and internal APKs are release builds, so the SDK ships in release
and `enabled` decides whether it does anything. With `enabled: false` there is
no button, no recording and no uploads, and `runApp` runs as usual.

Record route changes:

```dart
MaterialApp(navigatorObservers: [Nabrila.navigatorObserver], ...)

// go_router hands it to the navigators of its shell routes too, so bottom
// tabs are recorded as well. Routes are named by their path pattern.
GoRouter(observers: [Nabrila.navigatorObserver], routes: [...])
```

Add your own data to every report (environment, test account, feature
flags). Values are sent as text, up to 200 characters, at most 30 pairs; a key
that sounds secret (`token`, `password`, `session`…) is sent as `[REDACTED]`:

```dart
Nabrila.setContext('env', 'staging');
Nabrila.setContext('plan', user.plan);
Nabrila.setContext('plan', null); // removes it
```

Open a report by shaking the phone (on by default; it needs no permission and
only listens while the app is in the foreground):

```dart
Nabrila.run(..., shake: false); // floating button only
```

Let testers opt out: `Nabrila.discardSavedReports()` deletes every report
still waiting on the phone. A build with `enabled: false` does it on its own.

Hide private zones from screenshots (they are exported as solid blocks, and
taps inside them are never labeled):

```dart
NabrilaMask(child: CardNumberView())
```

Record HTTP calls. Integration is explicit; there is no global override.

```dart
// package:http has no interceptors, so wrap the client.
final client = NabrilaHttpClient(http.Client());

// Dio: a separate library, so apps without Dio never import it.
import 'package:nabrila/dio.dart';
dio.interceptors.add(NabrilaDioInterceptor());
```

By default only method, URL (sensitive query values redacted), status, duration
and size are kept. `captureBodies: true` (on either integration) also keeps
headers and body previews, with `authorization`, `cookie`, `token`, `password`,
`secret` and `api_key` values replaced by `[REDACTED]` before they leave memory.

`Nabrila.run(endpoint: ...)` overrides the default `https://nabrila.com`.

## Not only crashes

A report is for anything a person notices: something fails, looks wrong
(colors, spacing, a broken layout), shows wrong data, or an idea. The tester
picks the kind (optional) and can tap the screenshot to point at the element.
The SDK finds it in the live app and sends its widget type, its visible text
(never inside a `NabrilaMask`, never the value of a text field) and, in debug
builds, the file, line and column where it was written, relative to your
package (`lib/checkout/pay_button.dart:42`). Release builds do not track
where widgets are created, so they send the widget and text only.

Before sending, "What gets sent" lists everything the report carries.

## Close the loop

Each upload carries a hash derived from the report key. Whoever holds the link
can mark the report as fixed, needing more details or won't fix, with a short
note encrypted with the report key. The tester's app asks for the status of
the reports it sent (when it opens or comes back, at most every 15 minutes)
and shows it: "Your report was fixed. Try it again." Nabrila never sees the
key or the note in clear. The phone keeps the sent ids and keys for up to 31
days (50 reports) to be able to ask.

## Remote replay switch

If a phone model's native video encoder turns out to crash, Nabrila can turn
the replay off for that model without a new build of your app. The SDK asks
once a day and keeps the answer, so the switch applies from the next start
even offline.

## What it records

Only the last 150 events, in memory, never on disk: route changes, taps
(relative position and a short label of what was touched), `print` and
`debugPrint` output, Flutter and platform errors, and HTTP calls from the
integrations above. A report also carries your app name and version, OS, screen
size, text scale and locale. It does not carry the device model.

## Replay

While the SDK is enabled it keeps the last moments of the app as small masked
pictures, in memory: at most one per second and only when something changed on
screen, so an idle app costs nothing. They are copies of what Flutter painted,
so the phone asks for no permission and nothing outside the app is seen. Text
fields and `NabrilaMask` zones are covered in every picture. When someone opens
the report, the pictures become one H.264 video while they write the note; if
the phone has no usable encoder, the pictures travel as they are. Nothing
leaves the phone until someone taps **Send**.

```dart
Nabrila.run(
  appKey: 'nbr_...',
  enabled: true,
  replay: const NabrilaReplay(
    maxFrames: 120,          // pictures kept; idle moments add none
    maxMemoryBytes: 4000000, // memory they may use
    imageQuality: 45,        // JPEG quality in memory, 10 to 100
    videoQuality: 0.5,       // where the encoder takes a constant quality
    maskAllText: false,      // cover every text, not only text fields
    maskAllImages: false,    // cover every image
  ),
  app: () => runApp(const NabrilaScope(child: MyApp())),
);
```

`NabrilaReplay.off` turns it off; reports then carry the screenshot only.
Measured on a 40-second shopping flow (debug builds): no extra slow frames on
the iOS simulator, about 0.6 ms on the UI thread per picture, and a video of
190 KB (iOS simulator) or 182 KB (Android 16 emulator) for 31 to 33 pictures.

## Delivery

A report is never lost to a dropped connection, a timeout or the app being
closed mid-send:

- It is written to the app's private storage **before** the first attempt
  (Application Support on iOS, excluded from iCloud backups;
  `noBackupFilesDir` on Android), and deleted once the server confirms it or
  refuses it for good.
- If it could not go out, the tester sees that it was saved. It is sent again
  on its own when the app starts, when it comes back to the foreground, and
  after 30 s, 1, 2, 4 minutes and so on (up to an hour, with some jitter).
  When it goes out, a banner shows the link to copy or share.
- Every retry sends the very same encrypted bytes, and the server answers a
  repeat with the report it already made: no duplicates, and the monthly
  limit is counted once.
- Upload time grows with the size (30 s plus 1 s per 16 KB), so a 2 MB report
  still makes it over a weak 2G link.
- At most 10 reports wait, for up to 7 days. The key waits next to its
  report, inside the app's private storage, until it is sent; the link
  stays until the tester has seen it, even across restarts.
- Only a refusal from the Nabrila API itself (invalid key, suspended
  account, monthly limit, invalid report) drops a report. A login page of
  public Wi-Fi, a proxy or a firewall answering instead is retried, and the
  server's `Retry-After` is respected.
- A report keeps the key and server it was made for, so a new build with
  another key never sends it to the wrong app. A double tap on Send makes
  one report. On iOS the app asks for time to finish the upload if the
  tester leaves it right after sending.

## Data it collects

For the _Data safety_ form on Google Play and _App Privacy_ on the App Store.
With `enabled: false` the SDK collects nothing; we recommend turning it on only
in test builds. When it is on, a report is sent only when someone taps **Send**:

- **Photos and screenshots:** the screenshot of the current screen, with the
  tester's drawings and note, and the replay of the moments before it. Areas
  wrapped in `NabrilaMask` and text fields are blacked out in the replay.
- **App interactions:** route changes and taps (relative position and a short
  label of what was touched).
- **Diagnostics:** `print` and `debugPrint` output, Flutter and platform
  errors, app name and version, OS, screen size, text scale and locale.
- **Network activity:** method, URL, status, duration and size of HTTP calls made
  through the integrations; headers and bodies only with `captureBodies: true`,
  with secrets replaced by `[REDACTED]`.

It does not collect device identifiers, advertising IDs, the device model,
location, contacts or what is typed into text fields. Reports travel over HTTPS;
on the Free plan they are encrypted on the device first. Your app is the
controller of this data and Nabrila is the processor
([data processing agreement](https://nabrila.com/dpa)); tell your testers what is
sent and, where the law requires it, ask for their consent.

## Honest limits

- **Native views render blank or missing** in the screenshot: Google Maps,
  WebView, video, ads, camera, the system keyboard, the status bar and native
  permission dialogs. Native views (`AndroidView`, `UiKitView`,
  `PlatformViewLink`, `HtmlElementView`) are marked with a veil and a dashed
  edge in the screenshot and in the replay, labeled "Native view · may
  differ", so a blank area is not mistaken for a bug.
- **Replay needs Android 8 (API 26) or newer.** On Android 7 reports carry
  the screenshot only: the system's software video encoder crashes there.
  On Android, every video is decoded back and compared with its frames
  before it is sent; if an encoder wrote a black or empty video (seen with
  software encoders on Android 9 and 11), the report carries the frames
  instead.
- **`dart:developer.log` is not captured.** Only `print` and `debugPrint` are.
- **Masking is partial.** `NabrilaMask` and the tester's opaque rectangles hide
  what Flutter paints inside them. Nothing detects text inside images or
  `CustomPaint`, and password fields already show bullets. Taps may carry the
  text of the button or label that was touched; wrap sensitive widgets in
  `NabrilaMask` to avoid that. The value of a text field is never read.
- **Tap labels are a best effort.** They come from semantics labels, widget text
  or the widget type. In release builds type names can be minified.
- **Anyone with the whole link can open the report.** Share it only where you
  trust. On the Pro and Team plans Nabrila also keeps the key and can
  technically read the report; on the Free plan it cannot.
- **Shake** uses the accelerometer on Android and the system shake gesture on
  iOS (the one behind "Undo"). On iOS, with a text field focused, the system
  may also offer "Undo Typing".
- **Saved reports go out when the app opens or comes back** to the
  foreground (and on iOS for about 30 seconds after leaving it). There is no
  background upload while the app stays closed.
- **Pointing needs the screen as it was:** the element is found in the live
  app below the capture flow, so an app that changes screen on its own while
  the tester points may name what is there now.
- **Floating button only appears while `NabrilaScope` wraps the app,** and the
  button sits above your own dialogs and routes.
- **Platforms:** Android 7 (API 24) and newer (replay from Android 8), iOS 13 and newer, and desktop (desktop keeps the replay as PNG pictures, with no video). Web is not supported (the SDK uses
  `dart:io`). The Flutter version is not included in reports.
- **Cryptography is pure Dart** (`package:cryptography`), so encryption can be
  slow in debug builds.
- **Size caps:** screenshot PNG up to 1440 px on its longest side and 1.5 MB
  (retaken at lower resolution if needed), whole report up to 2 MiB, note up to
  1000 characters.
- A monthly report limit applies per workspace. When it is reached the tester
  sees a message saying the app hit its monthly limit.

## Dependencies

All pinned to exact versions: `cryptography`, `dio`, `http`, `package_info_plus`
and `share_plus`. `dio` is only imported by `package:nabrila/dio.dart`, but pub
still resolves it for every app, because Dart has no optional dependencies.

## Format

The envelope is `NBR1`: an 18-byte header (magic, version, flags, 12-byte IV)
followed by AES-256-GCM ciphertext and tag, with the first 6 header bytes as
AAD. Only the JSON inside is gzip-compressed. The tests reproduce the shared
vectors in `test/vectors/` byte for byte.
