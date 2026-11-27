## 0.1.0

- `--dart-define=NABRILA_COMMIT=<sha>` adds the build's git commit to every
  report.
- When the team marks a report fixed in a version, the tester is asked, once
  their app has it, whether it works now (`verified` or `reopened`).
- Each report gets a random verdict secret that stays on the phone; only its
  hash is sent (`X-Nabrila-Verdict`), and the answer is proved with it, so
  nobody who only has the link can answer for the tester. The answer is saved
  before it is sent and retried on every check until the server takes it or
  refuses it for good; the banner shows when it is sending or will retry.
- The app-update check is not lost when the phone is offline, and a
  pre-release (`1.4.2-beta`) counts as before its release.

- First version: floating capture button, annotation canvas with opaque
  rectangles, `NabrilaMask`, in-memory ring buffer (taps, routes, console, HTTP),
  `NBR1` encryption (AES-256-GCM) and encrypted share links.
