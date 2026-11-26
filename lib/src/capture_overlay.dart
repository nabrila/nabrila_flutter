import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'annotation_canvas.dart';
import 'annotations.dart';
import 'capture.dart';
import 'element_locator.dart';
import 'envelope.dart';
import 'l10n.dart';
import 'manifest.dart';
import 'outbox.dart';
import 'replay/replay_recorder.dart';
import 'report_details.dart';
import 'runtime.dart';
import 'uploader.dart';

enum _Phase { editing, sending, done, failed }

/// Full-screen capture flow: draw, hide, write a note, send, get the link.
/// It lives in its own `MaterialApp` because the scope sits above the app's
/// own `Navigator`, `Overlay` and theme.
class NabrilaCaptureOverlay extends StatelessWidget {
  const NabrilaCaptureOverlay({
    super.key,
    required this.capture,
    required this.runtime,
    required this.strings,
    required this.buildManifest,
    required this.onClose,
    this.replay,
    this.locate,
    this.summary = const ReportSummary(),
  });

  final ScreenCapture capture;
  final NabrilaRuntime runtime;
  final NabrilaStrings strings;
  final Map<String, Object?> Function(ReportInput input) buildManifest;
  final VoidCallback onClose;
  final ReplayTake? replay;

  /// Finds the widget at a spot of the screenshot (`0..1`), in the live app.
  final PointedElement Function(Offset spot)? locate;
  final ReportSummary summary;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFFE5484D),
      ),
      home: _CaptureFlow(
        capture: capture,
        runtime: runtime,
        strings: strings,
        buildManifest: buildManifest,
        onClose: onClose,
        replay: replay,
        locate: locate,
        summary: summary,
      ),
    );
  }
}

class _CaptureFlow extends StatefulWidget {
  const _CaptureFlow({
    required this.capture,
    required this.runtime,
    required this.strings,
    required this.buildManifest,
    required this.onClose,
    this.replay,
    this.locate,
    this.summary = const ReportSummary(),
  });

  final ScreenCapture capture;
  final NabrilaRuntime runtime;
  final NabrilaStrings strings;
  final Map<String, Object?> Function(ReportInput input) buildManifest;
  final VoidCallback onClose;
  final ReplayTake? replay;

  /// Finds the widget at a spot of the screenshot (`0..1`), in the live app.
  final PointedElement Function(Offset spot)? locate;
  final ReportSummary summary;

  @override
  State<_CaptureFlow> createState() => _CaptureFlowState();
}

class _CaptureFlowState extends State<_CaptureFlow> {
  final List<Annotation> _annotations = [];
  final TextEditingController _note = TextEditingController();
  AnnotationTool _tool = AnnotationTool.pen;
  String? _kind;
  PointedElement? _pointed;
  _Phase _phase = _Phase.editing;
  SealedReport? _sealed;
  PendingReport? _pending;
  UploadResult? _result;
  UploadFailure? _failure;
  bool _saved = false;
  bool _copied = false;

  NabrilaStrings get s => widget.strings;

  @override
  void dispose() {
    // A report still waiting goes out later on its own.
    widget.runtime.delivery.release(_pending);
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    // A double tap reaches here twice before the button is gone; a second
    // seal would make a second, different report.
    if (_phase == _Phase.sending) return;
    setState(() => _phase = _Phase.sending);
    final delivery = widget.runtime.delivery;
    try {
      final sealed = _sealed ??= await _seal();
      // On disk before the first byte goes out: a cut, a timeout or the app
      // being closed never loses the report.
      _pending ??= await delivery.keep(sealed);
      final outcome = await delivery.deliver(sealed, _pending);
      if (!outcome.saved) {
        delivery.release(_pending);
        _pending = null;
      }
      if (!mounted) return;
      final result = outcome.result;
      if (result == null) {
        _fail(outcome.failure!, saved: outcome.saved);
        return;
      }
      setState(() {
        _result = result;
        _phase = _Phase.done;
      });
    } on EnvelopeTooLargeException {
      _fail(UploadFailure.tooLarge);
    } on Object {
      _fail(UploadFailure.server);
    }
  }

  Future<SealedReport> _seal() async {
    final png = _annotations.isEmpty
        ? widget.capture.png
        : await composeAnnotated(widget.capture.image, _annotations) ??
              widget.capture.png;
    return sealReport(
      manifest: widget.buildManifest(
        ReportInput(note: _note.text, kind: _kind, element: _pointed?.toJson()),
      ),
      png: png,
      replay: widget.replay,
    );
  }

  void _fail(UploadFailure failure, {bool saved = false}) {
    if (!mounted) return;
    setState(() {
      _failure = failure;
      _saved = saved;
      _phase = _Phase.failed;
    });
  }

  String _failureText(UploadFailure failure) => switch (failure) {
    UploadFailure.invalidKey => s.errInvalidKey,
    UploadFailure.suspended => s.errSuspended,
    UploadFailure.tooLarge => s.errTooLarge,
    UploadFailure.quota => s.errQuota,
    UploadFailure.rateLimited => s.errRateLimited,
    UploadFailure.badEnvelope => s.errBadEnvelope,
    UploadFailure.network => s.errNetwork,
    UploadFailure.server => s.errServer,
  };

  void _point(Offset spot) {
    final locate = widget.locate;
    setState(
      () => _pointed = locate != null
          ? locate(spot)
          : PointedElement(xNorm: spot.dx, yNorm: spot.dy),
    );
  }

  Future<void> _copy(String link) async {
    await Clipboard.setData(ClipboardData(text: link));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: switch (_phase) {
          _Phase.editing => _editor(),
          _Phase.sending => _message(
            child: const CircularProgressIndicator(),
            text: s.sending,
          ),
          _Phase.done => _doneView(_result!),
          _Phase.failed => _failedView(),
        },
      ),
    );
  }

  Widget _editor() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.reportBug,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton(onPressed: widget.onClose, child: Text(s.cancel)),
            ],
          ),
          Expanded(
            child: AnnotationCanvas(
              capture: widget.capture,
              annotations: _annotations,
              tool: _tool,
              onChanged: () => setState(() {}),
              pointed: _pointed == null
                  ? null
                  : Offset(_pointed!.xNorm, _pointed!.yNorm),
              onPoint: _point,
            ),
          ),
          if (_pointed != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: PointedChip(
                strings: s,
                element: _pointed!,
                onClear: () => setState(() => _pointed = null),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              // Narrow phones (320 pt) and long labels: it shrinks, never
              // overflows.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<AnnotationTool>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: AnnotationTool.pen,
                        icon: const Icon(Icons.edit),
                        label: Text(s.pen),
                      ),
                      ButtonSegment(
                        value: AnnotationTool.block,
                        icon: const Icon(Icons.crop_square),
                        label: Text(s.hide),
                      ),
                      ButtonSegment(
                        value: AnnotationTool.point,
                        icon: const Icon(Icons.my_location),
                        label: Text(s.point),
                      ),
                    ],
                    selected: {_tool},
                    onSelectionChanged: (v) => setState(() => _tool = v.first),
                  ),
                ),
              ),
              IconButton(
                tooltip: s.undo,
                onPressed: _annotations.isEmpty
                    ? null
                    : () => setState(_annotations.removeLast),
                icon: const Icon(Icons.undo),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: KindPicker(
              strings: s,
              value: _kind,
              onChanged: (kind) => setState(() => _kind = kind),
            ),
          ),
          TextField(
            controller: _note,
            maxLength: maxNoteLength,
            maxLines: 2,
            minLines: 1,
            decoration: InputDecoration(
              hintText: s.notePlaceholder,
              border: const OutlineInputBorder(),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => showIncluded(context, s, widget.summary),
                    icon: const Icon(Icons.info_outline, size: 18),
                    label: Text(s.included, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _send, child: Text(s.send)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _message({required Widget child, required String text}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          const SizedBox(height: 16),
          Text(text, textAlign: TextAlign.center),
        ],
      ),
    ),
  );

  Widget _doneView(UploadResult result) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              s.linkReady,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            SelectableText(result.link),
            const SizedBox(height: 12),
            Text(s.linkWarning, style: Theme.of(context).textTheme.bodySmall),
            if (result.keyCustodyFailed) ...[
              const SizedBox(height: 8),
              Text(
                s.keyCustodyFailed,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _copy(result.link),
              icon: Icon(_copied ? Icons.check : Icons.copy),
              label: Text(_copied ? s.copied : s.copy),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () =>
                  SharePlus.instance.share(ShareParams(text: result.link)),
              icon: const Icon(Icons.ios_share),
              label: Text(s.share),
            ),
            TextButton(onPressed: widget.onClose, child: Text(s.close)),
          ],
        ),
      ),
    );
  }

  Widget _failedView() {
    final failure = _failure ?? UploadFailure.server;
    final canRetry =
        failure != UploadFailure.quota &&
        failure != UploadFailure.suspended &&
        failure != UploadFailure.invalidKey;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_failureText(failure), textAlign: TextAlign.center),
            if (_saved) ...[
              const SizedBox(height: 12),
              Text(
                s.savedForLater,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            if (canRetry) FilledButton(onPressed: _send, child: Text(s.retry)),
            TextButton(onPressed: widget.onClose, child: Text(s.close)),
          ],
        ),
      ),
    );
  }
}
