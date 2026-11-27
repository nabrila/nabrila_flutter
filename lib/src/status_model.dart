/// What the team said about a report the tester sent.
class ReportStatus {
  const ReportStatus({
    required this.id,
    required this.status,
    this.note,
    this.fixedIn,
    this.updatedAt,
    this.askVerdict = false,
  });

  final String id;

  /// `fixed`, `needs_info` or `wont_fix` (`open` and the tester's own
  /// answers are never shown).
  final String status;

  /// The team's note, decrypted on the phone.
  final String? note;

  /// For `fixed`: the version that ships the fix, if the team named one.
  final String? fixedIn;
  final String? updatedAt;

  /// The app already has [fixedIn]: ask whether it works now.
  final bool askVerdict;

  String get mark => '$status|$updatedAt';
}

/// How an answer of the tester stands while its question is on screen.
enum AnswerState { sending, failed }
