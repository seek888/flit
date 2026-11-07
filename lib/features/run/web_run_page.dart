import 'package:flit/l10n/strings.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/theme.dart';
import '../editor/workbench_layout.dart';
import '../../services/shell.dart';
import 'web_runner.dart';

/// 桌面端的 Web 预览降级面板：Windows/Linux 没有 webview 实现。
class _DesktopPreviewFallback extends StatelessWidget {
  const _DesktopPreviewFallback({
    required this.url,
    required this.onShowOutput,
  });

  final String url;
  final VoidCallback onShowOutput;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.language, size: 40, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text('预览服务已就绪', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            SelectableText(
              url.isEmpty ? '（等待地址…）' : url,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: url.isEmpty ? null : () => Shell.instance.openUrl(url),
              icon: const Icon(Icons.open_in_browser, size: 18),
              label: const Text('用系统浏览器打开'),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: onShowOutput, child: const Text('查看输出')),
            const SizedBox(height: 12),
            Text(
              '桌面端不支持内嵌 WebView，热重载仍在终端里生效',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An embedded workspace view. Its native WebView stays mounted between tabs.
class WebRunPreview extends StatelessWidget {
  const WebRunPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final run = context.read<WebRunController>();
    // 看日志 = 终端切到 Web 运行的会话并展开
    void onShowOutput() =>
        context.read<WorkbenchLayout>().showOutput(sessionId: run.session?.id);
    return ListenableBuilder(
      listenable: run,
      builder: (context, _) {
        if (run.serving && isDesktopPlatform) {
          // 桌面端没有 webview_flutter 实现（官方仅 Android/iOS/macOS），
          // 预览降级为「显示地址 + 用系统浏览器打开」。
          return _DesktopPreviewFallback(
            url: run.url?.toString() ?? '',
            onShowOutput: onShowOutput,
          );
        }
        if (run.serving) {
          return _WebDocument(
            key: ValueKey(run.session!.id),
            run: run,
            onShowOutput: onShowOutput,
          );
        }
        final message = switch (run.state) {
          WebRunState.idle => context.strings.runWebToPreviewHere,
          WebRunState.starting =>
            context.strings.compilingAndStartingTheWebServer,
          WebRunState.serving ||
          WebRunState.stopped => context.strings.webServerStopped,
          WebRunState.failed => run.error ?? context.strings.webStartupFailed,
        };
        return ColoredBox(
          color: AppColors.bg,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (run.starting)
                    const CircularProgressIndicator(strokeWidth: 2)
                  else
                    const Icon(
                      Icons.web,
                      size: 36,
                      color: AppColors.textSecondary,
                    ),
                  const SizedBox(height: 16),
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: onShowOutput,
                    child: Text(context.strings.viewRunLogs),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WebDocument extends StatefulWidget {
  const _WebDocument({
    super.key,
    required this.run,
    required this.onShowOutput,
  });
  final WebRunController run;
  final VoidCallback onShowOutput;

  @override
  State<_WebDocument> createState() => _WebDocumentState();
}

class _WebDocumentState extends State<_WebDocument> {
  late final WebViewController _controller;
  Timer? _frameTimeout;
  bool _loading = true;
  String? _error;
  bool _failedDocument = false;
  Uri? _documentUrl;
  int _navigation = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await _controller.addJavaScriptChannel(
        'FlitPreview',
        onMessageReceived: (message) {
          if (!mounted ||
              message.message != 'frame:$_navigation' ||
              _failedDocument) {
            return;
          }
          _frameTimeout?.cancel();
          setState(() {
            _loading = false;
            _error = null;
          });
          widget.run.setClientReady(true);
        },
      );
      await _controller.setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            if (!mounted) return;
            _documentUrl = Uri.tryParse(url);
            ++_navigation;
            widget.run.setClientReady(false);
            _frameTimeout?.cancel();
            setState(() {
              _loading = true;
              _error = null;
              _failedDocument = false;
            });
            _frameTimeout = Timer(const Duration(seconds: 60), () {
              _showError(
                context.strings.thePageHasNotRenderedYetCheck,
                failedDocument: false,
              );
            });
            unawaited(_watchFirstFrame());
          },
          // HTML load completion is not Flutter's first rendered frame.
          onPageFinished: (_) => unawaited(_watchFirstFrame()),
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) {
              _showError(context.strings.pageLoadFailedP(error.description));
            }
          },
          onHttpError: (error) {
            if (error.request?.uri == _documentUrl) {
              _showError(
                context.strings.pageRequestFailedHttpP(
                  error.response?.statusCode,
                ),
              );
            }
          },
        ),
      );
      if (mounted) await _controller.loadRequest(widget.run.url!);
    } catch (e) {
      _showError(strings.unableToLoadPreviewP(e));
    }
  }

  Future<void> _watchFirstFrame() async {
    if (!mounted) return;
    try {
      await _controller.runJavaScript('''
(() => {
  const token = $_navigation;
  if (window.__flitPreviewToken === token) return;
  window.__flitPreviewToken = token;
  let done = false;
  const ready = () => {
    if (done || window.__flitPreviewToken !== token) return;
    done = true;
    window.removeEventListener('flutter-first-frame', ready);
    FlitPreview.postMessage('frame:' + token);
  };
  window.addEventListener('flutter-first-frame', ready, {once: true});
  // Recover if the native callback arrived after the first-frame event.
  const scene = document.querySelector('flt-glass-pane')?.shadowRoot
      ?.querySelector('flt-scene-host > flt-scene');
  if (scene) requestAnimationFrame(() => requestAnimationFrame(ready));
})();
''');
    } catch (_) {
      // onPageStarted may precede the JS context; onPageFinished retries setup.
    }
  }

  void _showError(String message, {bool failedDocument = true}) {
    if (!mounted) return;
    _frameTimeout?.cancel();
    widget.run.setClientReady(false);
    setState(() {
      _loading = false;
      _error = message;
      _failedDocument = failedDocument;
    });
  }

  Future<void> _refresh() async {
    if (!widget.run.serving) return;
    _frameTimeout?.cancel();
    widget.run.setClientReady(false);
    setState(() {
      _loading = true;
      _error = null;
      _failedDocument = false;
    });
    try {
      await _controller.loadRequest(widget.run.url!);
    } catch (e) {
      _showError(strings.unableToLoadPreviewP(e));
    }
  }

  @override
  void dispose() {
    _frameTimeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 36,
          color: AppColors.surface,
          padding: const EdgeInsets.only(left: 12),
          child: Row(
            children: [
              const Icon(
                Icons.language,
                size: 14,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.run.url.toString(),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              IconButton(
                tooltip: context.strings.reloadPageResetPageState,
                iconSize: 18,
                padding: EdgeInsets.zero,
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: WebViewWidget(controller: _controller)),
              if (_loading || _error != null)
                Positioned.fill(
                  child: ColoredBox(
                    color: AppColors.bg,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_loading)
                              const CircularProgressIndicator(strokeWidth: 2),
                            const SizedBox(height: 16),
                            Text(
                              _error ?? context.strings.loadingPreview,
                              textAlign: TextAlign.center,
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: 12),
                              OutlinedButton(
                                onPressed: _refresh,
                                child: Text(context.strings.reload),
                              ),
                              TextButton(
                                onPressed: widget.onShowOutput,
                                child: Text(context.strings.viewRunLogs),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (widget.run.error != null || widget.run.reloading)
          Container(
            width: double.infinity,
            color: AppColors.surface,
            padding: const EdgeInsets.all(8),
            child: Text(
              widget.run.reloading
                  ? context.strings.updating
                  : widget.run.error!,
              style: TextStyle(
                fontSize: 12,
                color: widget.run.error != null
                    ? AppColors.danger
                    : AppColors.textSecondary,
              ),
            ),
          ),
      ],
    );
  }
}
