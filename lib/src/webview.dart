import 'dart:async';
import 'dart:convert';
import 'package:webview_flutter/webview_flutter.dart';
import 'manifest.dart';

/// A bridge into a retained, first-party WebView document running owls-web-loader.
/// Call only after onPageFinished for the allowed document. Never install on arbitrary web content.
class WebViewLoaderBridge {
  final WebViewController controller;
  final Uri document;
  final _pending = <String, Completer<void>>{};
  int _next = 0;
  bool _disposed = false;
  WebViewLoaderBridge(this.controller, this.document) {
    if (document.scheme != 'https' ||
        document.userInfo.isNotEmpty ||
        document.hasQuery ||
        document.hasFragment) {
      throw const LoaderException(
          'origin', 'Bridge requires a fixed first-party HTTPS document');
    }
  }
  Future<void> attach() => controller.addJavaScriptChannel('OwlsLoaderResults',
          onMessageReceived: (message) {
        try {
          final value = jsonDecode(message.message) as Map<String, dynamic>;
          final pending = _pending.remove(value['requestId']);
          if (pending == null) return;
          if (value['ok'] == true) {
            pending.complete();
          } else {
            pending.completeError(const LoaderException(
                'activation', 'WebView operation failed'));
          }
        } catch (_) {/* ignore malformed messages; deadline remains active */}
      });
  Future<void> _send(String method, String releaseKey) async {
    if (_disposed) throw const LoaderException('disposed', 'Bridge disposed');
    final current = await controller.currentUrl();
    if (current != document.toString())
      throw const LoaderException('navigation', 'WebView document changed');
    // Fixed method names; JSON arguments never become executable source.
    final id = (++_next).toString();
    final done = Completer<void>();
    _pending[id] = done;
    final command = jsonEncode({
      'requestId': id,
      'method': method,
      'releaseKey': releaseKey,
      'document': document.toString()
    });
    // Attach the error handler before issuing JS, which can reply synchronously.
    final completed = done.future.timeout(const Duration(seconds: 30));
    try {
      await Future.wait<void>([
        controller.runJavaScript('globalThis.owlsBridge.receive($command);'),
        completed,
      ], eagerError: true);
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> prepare(String releaseKey) => _send('prefetch', releaseKey);
  Future<void> activate(String releaseKey) => _send('activate', releaseKey);
  Future<void> dispose() async {
    _disposed = true;
    for (final p in _pending.values) {
      p.completeError(const LoaderException('disposed', 'Bridge disposed'));
    }
    _pending.clear();
    await controller.removeJavaScriptChannel('OwlsLoaderResults');
  }
}
