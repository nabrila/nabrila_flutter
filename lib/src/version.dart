import 'dart:convert';

/// What the team tells the tester, once opened: a text and the version
/// that fixes the report. A note sealed before the version existed is plain
/// text and reads as one.
class StatusNote {
  const StatusNote({this.text, this.fixedIn});

  /// `{"v":1,"text"?,"fixedIn"?}` or plain text.
  factory StatusNote.decode(String plain) {
    try {
      final value = jsonDecode(plain);
      if (value is Map && value['v'] == 1) {
        final text = value['text'];
        final fixedIn = value['fixedIn'];
        return StatusNote(
          text: text is String && text.trim().isNotEmpty ? text : null,
          fixedIn: fixedIn is String && isFixedIn(fixedIn) ? fixedIn : null,
        );
      }
    } on FormatException {
      // Plain text.
    }
    return StatusNote(text: plain);
  }

  final String? text;
  final String? fixedIn;
}

final RegExp _fixedInRx = RegExp(
  r'^(?:\d{1,6}(?:\.\d{1,6}){0,3}(?:\+\d{1,9})?|\+?\d{1,9})$',
);

/// A version as `pubspec.yaml` writes it (`1.4.2`, `1.4.2+37`) or a build
/// number alone (`+37`, `37`), the same rule as the web.
bool isFixedIn(String value) =>
    value.length <= 40 && _fixedInRx.hasMatch(value);

/// Whether the app at [version] (`1.4.2`) and [build] (`37`) already has
/// [fixedIn]. A build number alone compares builds; a version compares its
/// numbers and then, if it names one, the build. A pre-release
/// (`1.4.2-beta`) comes before its release, so it does not have a fix
/// named `1.4.2`. Unknown when either side cannot be read, and then the
/// tester is not asked.
bool? hasVersion({
  required String fixedIn,
  required String version,
  required String build,
}) {
  if (!isFixedIn(fixedIn)) return null;
  final plus = fixedIn.indexOf('+');
  final onlyBuild = !fixedIn.contains('.') && (plus == 0 || plus == -1);
  int? number(String s) => s.isEmpty ? null : int.tryParse(s);
  if (onlyBuild) {
    final want = number(fixedIn.replaceFirst('+', ''));
    final have = number(build.trim());
    return want == null || have == null ? null : have >= want;
  }
  final wantParts = (plus == -1 ? fixedIn : fixedIn.substring(0, plus))
      .split('.')
      .map(int.parse)
      .toList();
  final noBuild = version.trim().split('+').first;
  final dash = noBuild.indexOf('-');
  final preRelease = dash != -1;
  final haveText = preRelease ? noBuild.substring(0, dash) : noBuild;
  final haveParts = haveText.split('.').map(number).toList();
  if (haveParts.isEmpty || haveParts.contains(null)) return null;
  for (var i = 0; i < 4; i++) {
    final want = i < wantParts.length ? wantParts[i] : 0;
    final have = i < haveParts.length ? haveParts[i]! : 0;
    if (have != want) return have > want;
  }
  // The same numbers: a pre-release is still before the release.
  if (preRelease) return false;
  if (plus == -1) return true;
  final wantBuild = number(fixedIn.substring(plus + 1));
  final haveBuild = number(build.trim());
  return wantBuild == null || haveBuild == null ? null : haveBuild >= wantBuild;
}

/// The app's version as `PackageInfo` reads it.
typedef AppVersion = ({String version, String build});
