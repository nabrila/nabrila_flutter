import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import 'capture.dart';
import 'capture_overlay.dart';
import 'clipboard.dart';
import 'element_locator.dart';
import 'events.dart';
import 'l10n.dart';
import 'manifest.dart';
import 'replay/replay_recorder.dart';
import 'report_details.dart';
import 'report_status.dart';
import 'runtime.dart';
import 'shake.dart';
import 'tap_resolver.dart';
import 'uploader.dart';

/// Wrap the whole app with it: `runApp(const NabrilaScope(child: MyApp()))`.
///
/// While the SDK is disabled it returns [child] untouched. While enabled it
/// records taps and shows a floating button that opens the capture flow.
class NabrilaScope extends StatefulWidget {
  const NabrilaScope({super.key, required this.child});

  final Widget child;

  @override
  State<NabrilaScope> createState() => _NabrilaScopeState();
}

class _NabrilaScopeState extends State<NabrilaScope> {
  final GlobalKey _boundaryKey = GlobalKey();
  ScreenCapture? _capture;
  Map<String, Object?> Function(ReportInput input)? _manifest;
  ReportSummary _summary = const ReportSummary();
  ReplayTake? _replay;
  ShakeTrigger? _shake;
  AppLifecycleListener? _lifecycle;
  bool _busy = false;
  Offset _buttonOffset = const Offset(16, 120);

  @override
  void initState() {
    super.initState();
    final runtime = NabrilaRuntime.current;
    runtime?.replay?.attach(() => _boundaryKey.currentContext);
    // Reports saved earlier (no network, app closed mid-send) go out now.
    runtime?.delivery.start();
    if (runtime != null) {
      unawaited(
        runtime.config.apply(() {
          runtime.replay?.detach();
          runtime.replay = null;
        }),
      );
      unawaited(runtime.loop.poll());
      _lifecycle = AppLifecycleListener(
        onResume: () => unawaited(runtime.loop.poll()),
      );
    }
    if (runtime != null && runtime.shake) {
      _shake = ShakeTrigger(() {
        if (_capture == null) unawaited(_open());
      })..start();
    }
  }

  NabrilaStrings get _strings =>
      NabrilaStrings.forLocale(View.of(context).platformDispatcher.locale);

  void _onPointerDown(PointerDownEvent event) {
    final runtime = NabrilaRuntime.current;
    final box = _boundaryKey.currentContext?.findRenderObject();
    final root = _boundaryKey.currentContext;
    if (runtime == null || box is! RenderBox || !box.hasSize || root == null) {
      return;
    }
    TapTarget target;
    try {
      target = resolveTap(
        root as Element,
        hitRenderObjects(event.viewId, event.position),
      );
    } on Object {
      target = (hint: null, masked: false);
    }
    // Inside a mask the tap keeps no position: the spots on a masked PIN
    // pad spell the PIN.
    if (target.masked) {
      runtime.recordTap(xNorm: null, yNorm: null, targetHint: null);
      return;
    }
    final local = box.globalToLocal(event.position);
    runtime.recordTap(
      xNorm: box.size.width == 0 ? 0 : local.dx / box.size.width,
      yNorm: box.size.height == 0 ? 0 : local.dy / box.size.height,
      targetHint: target.hint,
    );
  }

  Future<void> _open() async {
    final runtime = NabrilaRuntime.current;
    final boundary = _boundaryKey.currentContext?.findRenderObject();
    if (_busy || runtime == null || boundary is! RenderRepaintBoundary) return;
    _busy = true;
    try {
      final view = View.of(context);
      final capture = await captureBoundary(
        boundary,
        view.devicePixelRatio,
        root: _boundaryKey.currentContext as Element?,
        nativeLabel: _strings.nativeView,
      );
      if (!mounted) return;
      if (capture == null) return;
      final app = await _appInfo();
      final frozen = EventBuffer();
      for (final event in runtime.buffer.snapshot()) {
        frozen.add(event);
      }
      final capturedAt = runtime.now();
      final route = runtime.activeRoute;
      final appContext = Map.of(runtime.context);
      final recorder = runtime.replay?..pause();
      final replay = recorder == null || recorder.frames.isEmpty
          ? null
          : ReplayTake(
              frames: recorder.frames,
              origin: frozen.origin ?? capturedAt,
              quality: recorder.options.videoQuality,
            );
      // The video is built while the person writes the note.
      if (replay != null) unawaited(replay.video());
      final device = DeviceInfo(
        platform: Platform.operatingSystem,
        osVersion: Platform.operatingSystemVersion,
        logicalWidth: capture.logicalSize.width,
        logicalHeight: capture.logicalSize.height,
        pixelRatio: view.devicePixelRatio,
        textScaleFactor: view.platformDispatcher.textScaleFactor,
        locale: view.platformDispatcher.locale.toLanguageTag(),
      );
      if (!mounted) return;
      final frames = recorder?.frames ?? const <ReplayFrame>[];
      setState(() {
        _capture = capture;
        _replay = replay;
        _summary = ReportSummary.of(
          frozen,
          replaySeconds: replay == null || frames.length < 2
              ? null
              : frames.last.at.difference(frames.first.at).inSeconds,
          contextKeys: appContext.keys,
        );
        _manifest = (input) => buildManifest(
          capturedAt: capturedAt,
          note: input.note,
          kind: input.kind,
          element: input.element,
          context: appContext,
          app: app,
          activeRoute: route,
          device: device,
          events: frozen,
        );
      });
    } finally {
      _busy = false;
    }
  }

  Future<AppInfo> _appInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return AppInfo(
        appName: info.appName.isEmpty ? 'unknown' : info.appName,
        appVersion: info.version,
        buildNumber: info.buildNumber,
        commit: buildCommit,
      );
    } on Object {
      return const AppInfo(
        appName: 'unknown',
        appVersion: '',
        buildNumber: '',
        commit: buildCommit,
      );
    }
  }

  void _close() {
    _capture?.dispose();
    NabrilaRuntime.current?.replay?.resume();
    setState(() {
      _capture = null;
      _manifest = null;
      _replay = null;
    });
  }

  /// The widget at [spot] of the screenshot, found in the live app that
  /// sits right below the capture flow.
  PointedElement _locate(Offset spot) {
    final root = _boundaryKey.currentContext;
    final box = root?.findRenderObject();
    if (root is! Element || box is! RenderBox) {
      return PointedElement(xNorm: spot.dx, yNorm: spot.dy);
    }
    return locateElement(root, box, xNorm: spot.dx, yNorm: spot.dy);
  }

  @override
  void dispose() {
    _shake?.dispose();
    _lifecycle?.dispose();
    _capture?.dispose();
    NabrilaRuntime.current?.replay?.detach();
    NabrilaRuntime.current?.delivery.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final runtime = NabrilaRuntime.current;
    if (runtime == null) return widget.child;
    final capture = _capture;
    final manifest = _manifest;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            key: _boundaryKey,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onPointerDown,
              child: widget.child,
            ),
          ),
          if (capture == null) _button(),
          if (capture == null)
            ValueListenableBuilder<List<UploadResult>>(
              valueListenable: runtime.delivery.delivered,
              builder: (context, delivered, _) => delivered.isNotEmpty
                  ? _deliveredBanner(runtime, delivered.first)
                  : ValueListenableBuilder<List<ReportStatus>>(
                      valueListenable: runtime.loop.updates,
                      builder: (context, updates, _) => updates.isEmpty
                          ? const SizedBox.shrink()
                          : _statusBanner(runtime, updates.first),
                    ),
            ),
          if (capture != null && manifest != null)
            Positioned.fill(
              child: NabrilaCaptureOverlay(
                capture: capture,
                runtime: runtime,
                strings: _strings,
                buildManifest: manifest,
                onClose: _close,
                replay: _replay,
                locate: _locate,
                summary: _summary,
              ),
            ),
        ],
      ),
    );
  }

  /// What the team said about a report this phone sent.
  Widget _statusBanner(NabrilaRuntime runtime, ReportStatus update) =>
      ValueListenableBuilder<Map<String, AnswerState>>(
        valueListenable: runtime.loop.answering,
        builder: (context, answering, _) =>
            _statusFrame(runtime, update, answering[update.id]),
      );

  Widget _statusFrame(
    NabrilaRuntime runtime,
    ReportStatus update,
    AnswerState? answer,
  ) {
    final s = _strings;
    final fixedIn = update.fixedIn;
    final title = answer == AnswerState.sending
        ? s.loopSending
        : answer == AnswerState.failed
        ? s.loopSendFailed
        : update.askVerdict
        ? s.loopAsk
        : switch (update.status) {
            'fixed' when fixedIn != null => s.loopFixedIn.replaceAll(
              '{version}',
              fixedIn,
            ),
            'fixed' => s.loopFixed,
            'needs_info' => s.loopNeedsInfo,
            _ => s.loopWontFix,
          };
    final note = update.note;
    return _bannerFrame(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: _bannerText),
          if (answer == null && note != null && note.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                s.loopNoteFrom.replaceAll('{note}', note.trim()),
                style: _bannerText.copyWith(color: Colors.white70),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
      [
        if (update.askVerdict && answer == null) ...[
          _bannerAction(
            Icons.thumb_up_alt_outlined,
            s.loopWorks,
            () => unawaited(runtime.loop.answer(update, works: true)),
          ),
          _bannerAction(
            Icons.thumb_down_alt_outlined,
            s.loopStillFails,
            () => unawaited(runtime.loop.answer(update, works: false)),
          ),
        ],
        _bannerAction(
          Icons.close,
          s.close,
          () => unawaited(runtime.loop.seen(update)),
        ),
      ],
    );
  }

  static const TextStyle _bannerText = TextStyle(
    color: Colors.white,
    fontSize: 14,
  );

  Widget _bannerFrame(Widget content, List<Widget> actions) => Positioned(
    left: 12,
    right: 12,
    top: MediaQuery.maybePaddingOf(context)?.top ?? 24,
    child: Material(
      color: const Color(0xFF111827),
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            Expanded(child: content),
            ...actions,
          ],
        ),
      ),
    ),
  );

  /// Link of a saved report that went out after its flow was closed.
  Widget _deliveredBanner(NabrilaRuntime runtime, UploadResult result) {
    final delivery = runtime.delivery;
    const text = _bannerText;
    return Positioned(
      left: 12,
      right: 12,
      top: MediaQuery.maybePaddingOf(context)?.top ?? 24,
      child: Material(
        color: const Color(0xFF111827),
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
          child: Row(
            children: [
              Expanded(child: Text(_strings.deliveredLater, style: text)),
              _bannerAction(Icons.copy, _strings.copy, () {
                unawaited(copySecret(result.link));
                delivery.seen(result);
              }),
              _bannerAction(Icons.ios_share, _strings.share, () {
                SharePlus.instance.share(ShareParams(text: result.link));
                delivery.seen(result);
              }),
              _bannerAction(
                Icons.close,
                _strings.close,
                () => delivery.seen(result, dismiss: true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// An icon button that needs no `Overlay` or localizations: the scope
  /// sits above the app's `MaterialApp`, so `IconButton` tooltips would
  /// have nowhere to show.
  Widget _bannerAction(IconData icon, String label, VoidCallback onTap) =>
      Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      );

  Widget _button() {
    final size =
        MediaQuery.maybeSizeOf(context) ??
        View.of(context).physicalSize / View.of(context).devicePixelRatio;
    return Positioned(
      right: _buttonOffset.dx,
      bottom: _buttonOffset.dy,
      child: GestureDetector(
        onPanUpdate: (d) => setState(() {
          _buttonOffset = clampButtonOffset(_buttonOffset - d.delta, size);
        }),
        child: Semantics(
          button: true,
          label: _strings.floatingButton,
          child: Material(
            color: const Color(0xFF111827),
            elevation: 6,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _open,
              child: const SizedBox(
                width: 48,
                height: 48,
                child: Icon(Icons.bug_report_outlined, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Size of the floating button's touch area.
const double _buttonExtent = 56;

/// Where the floating button may sit: inside the window, measured from its
/// bottom right corner. A window smaller than the button (a split screen,
/// a picture-in-picture app) pins it to the corner instead of failing.
@visibleForTesting
Offset clampButtonOffset(Offset wanted, Size window) => Offset(
  wanted.dx.clamp(0, math.max(0, window.width - _buttonExtent)),
  wanted.dy.clamp(0, math.max(0, window.height - _buttonExtent)),
);
