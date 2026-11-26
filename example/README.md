# Nabrila example

Only `lib/` and `pubspec.yaml` are kept in the repo. Generate the platform
folders once, then run it:

```sh
flutter create --platforms=android,ios .
flutter run --dart-define=NABRILA_ENABLED=true --dart-define=NABRILA_KEY=nbr_...
```

Without `NABRILA_ENABLED=true` the SDK is off: no button, no recording, no
uploads.
