import 'package:material_ui/material_ui.dart';

import 'element_locator.dart';
import 'events.dart';
import 'l10n.dart';
import 'manifest.dart';

/// What a report carries besides the screenshot, counted when the flow
/// opens, so the tester can see it before sending.
class ReportSummary {
  const ReportSummary({
    this.taps = 0,
    this.screens = 0,
    this.requests = 0,
    this.logs = 0,
    this.bodies = false,
    this.replaySeconds,
    this.contextKeys = const [],
  });

  factory ReportSummary.of(
    EventBuffer events, {
    int? replaySeconds,
    Iterable<String> contextKeys = const [],
  }) {
    var taps = 0, screens = 0, requests = 0, logs = 0;
    var bodies = false;
    for (final e in events.snapshot()) {
      switch (e.kind) {
        case 'tap':
          taps++;
        case 'navigation':
          screens++;
        case 'http':
          requests++;
          bodies =
              bodies ||
              e.fields.containsKey('reqHeaders') ||
              e.fields.containsKey('resHeaders') ||
              e.fields.containsKey('reqBodyPreview') ||
              e.fields.containsKey('resBodyPreview');
        case 'log':
          logs++;
      }
    }
    return ReportSummary(
      taps: taps,
      screens: screens,
      requests: requests,
      logs: logs,
      bodies: bodies,
      replaySeconds: replaySeconds,
      contextKeys: contextKeys.toList(),
    );
  }

  final int taps;
  final int screens;
  final int requests;
  final int logs;

  /// Some request kept its (redacted) headers or body.
  final bool bodies;

  /// Length of the recording of the last moments, or null without one.
  final int? replaySeconds;
  final List<String> contextKeys;

  /// One line per thing sent, in the tester's language.
  List<String> lines(NabrilaStrings s) => [
    s.includedScreenshot,
    if (replaySeconds != null)
      s.includedReplay.replaceAll('{n}', '$replaySeconds'),
    s.includedEvents
        .replaceAll('{taps}', '$taps')
        .replaceAll('{screens}', '$screens')
        .replaceAll('{requests}', '$requests')
        .replaceAll('{logs}', '$logs'),
    if (requests > 0) bodies ? s.includedBodies : s.includedNoBodies,
    if (contextKeys.isNotEmpty)
      s.includedContext.replaceAll('{keys}', contextKeys.join(', ')),
    s.includedDevice,
    s.nativeWarning,
    s.includedEncrypted,
  ];
}

/// The kinds a person can pick. None is picked at first: it is optional.
class KindPicker extends StatelessWidget {
  const KindPicker({
    super.key,
    required this.strings,
    required this.value,
    required this.onChanged,
  });

  final NabrilaStrings strings;
  final String? value;
  final ValueChanged<String?> onChanged;

  String _label(String kind) => switch (kind) {
    'bug' => strings.kindBug,
    'visual' => strings.kindVisual,
    'data' => strings.kindData,
    _ => strings.kindSuggestion,
  };

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 4,
    children: [
      for (final kind in reportKinds)
        ChoiceChip(
          label: Text(_label(kind)),
          selected: value == kind,
          visualDensity: VisualDensity.compact,
          onSelected: (on) => onChanged(on ? kind : null),
        ),
    ],
  );
}

/// What the person pointed at, with a way to take the point back.
class PointedChip extends StatelessWidget {
  const PointedChip({
    super.key,
    required this.strings,
    required this.element,
    required this.onClear,
  });

  final NabrilaStrings strings;
  final PointedElement element;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final parts = [
      ?element.widget,
      if (element.label != null) '"${element.label}"',
      if (element.source != null) '${element.source}',
    ];
    return InputChip(
      avatar: const Icon(Icons.my_location, size: 18),
      label: Text(
        parts.isEmpty ? strings.pointMarked : parts.join(' · '),
        overflow: TextOverflow.ellipsis,
      ),
      onDeleted: onClear,
      deleteButtonTooltipMessage: strings.clearPoint,
    );
  }
}

/// Bottom sheet that lists what the report carries.
Future<void> showIncluded(
  BuildContext context,
  NabrilaStrings strings,
  ReportSummary summary,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.included,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          for (final line in summary.lines(strings))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 6, right: 10),
                    child: Icon(Icons.circle, size: 6),
                  ),
                  Expanded(child: Text(line)),
                ],
              ),
            ),
        ],
      ),
    ),
  ),
);
