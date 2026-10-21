// Photo Highlighter — full-screen WebView over the bundled page (see highlighter_server.dart).
// Self-contained: the rest of the app only opens [HighlighterScreen.open].
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../services/native_bridge.dart';
import '../services/storage.dart';
import '../state/toast.dart';
import '../theme/colors.dart';
import 'highlighter_server.dart';

class HighlighterScreen extends StatefulWidget {
  const HighlighterScreen({super.key});

  /// What the menu opens (tests replace the WebView, which needs a device).
  @visibleForTesting
  static Widget Function() builder = () => const HighlighterScreen();

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, _, _) => builder(),
      transitionsBuilder: (_, a, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
        child: child,
      ),
    ),
  );

  @override
  State<HighlighterScreen> createState() => _HighlighterScreenState();
}

/// Hindi status line above the page (the page itself is not changed).
String? highlighterNotice({required bool allCached, required bool online, required bool wifiOnlyWaiting, required ({int done, int total, bool running}) prefetch, required bool missed}) {
  if (allCached) return null;
  if (prefetch.running && prefetch.total > 0) {
    final pct = (prefetch.done * 100 / prefetch.total).clamp(0, 100).round();
    return 'पहली बार: OCR और स्कैन की फ़ाइलें फ़ोन में सेव हो रही हैं — $pct%';
  }
  if (!online || missed) {
    return 'इंटरनेट नहीं है — OCR (टेक्स्ट पहचान) और ऑटो-स्कैन पहली बार इंटरनेट से एक बार डाउनलोड होंगे। फ़ोटो जोड़ना, हाइलाइट और PDF बिना इंटरनेट चलते हैं।';
  }
  if (wifiOnlyWaiting) return 'OCR और स्कैन की फ़ाइलें WiFi मिलने पर सेव होंगी (सेटिंग: सिर्फ़ WiFi पर डाउनलोड)।';
  return null;
}

class _HighlighterScreenState extends State<HighlighterScreen> {
  WebViewController? _c;
  final _srv = HighlighterServer.I;
  bool _online = true;
  bool _wifiOnlyWaiting = false;
  bool _hideNotice = false;
  final Map<int, ({IOSink sink, File file, String name, String mime, String mode})> _incoming = {};

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    _srv.cacheDir ??= Directory('${Store.I.root.path}/highlighter');
    final origin = await _srv.start();
    try {
      final net = await Connectivity().checkConnectivity().timeout(const Duration(seconds: 3));
      _online = !net.contains(ConnectivityResult.none);
      final wifi = net.contains(ConnectivityResult.wifi) || net.contains(ConnectivityResult.ethernet);
      _wifiOnlyWaiting = Store.I.getString(Store.kWifiOnly) == '1' && !wifi;
    } catch (_) {}
    // First open: save OCR / scan libraries for offline use (the page also fetches on demand).
    if (_online && !_wifiOnlyWaiting && !_srv.allCached) unawaited(_srv.prefetchAll());
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF111111))
      ..addJavaScriptChannel('GranthHL', onMessageReceived: (m) => _onMessage(m.message))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (r) {
            // Only the local page; anything else (none expected) opens nowhere.
            final u = Uri.tryParse(r.url);
            return u != null && (u.host == '127.0.0.1' || u.scheme == 'about' || u.scheme == 'blob' || u.scheme == 'data') ? NavigationDecision.navigate : NavigationDecision.prevent;
          },
        ),
      );
    await c.setOnJavaScriptAlertDialog((r) => _alert(r.message));
    await c.setOnJavaScriptConfirmDialog((r) => _confirm(r.message));
    await c.setOnJavaScriptTextInputDialog((r) => _prompt(r.message, r.defaultText));
    final p = c.platform;
    if (p is AndroidWebViewController) {
      await p.setTextZoom(100); // the page's own layout, whatever the phone's font size
      await p.setMediaPlaybackRequiresUserGesture(true);
      await p.setOnShowFileSelector(_pickFiles);
    }
    await c.loadRequest(origin);
    if (mounted) setState(() => _c = c);
  }

  Future<List<String>> _pickFiles(FileSelectorParams params) async {
    final r = await NativeBridge.pickFiles(accept: params.acceptTypes, multiple: params.mode == FileSelectorMode.openMultiple, capture: params.isCaptureEnabled);
    return r;
  }

  Future<void> _alert(String msg) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(msg, style: GText.sans(size: 15)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  Future<bool> _confirm(String msg) async {
    if (!mounted) return false;
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(msg, style: GText.sans(size: 15)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('रद्द करें')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
        ],
      ),
    );
    return r ?? false;
  }

  Future<String> _prompt(String msg, String? def) async {
    if (!mounted) return '';
    final t = TextEditingController(text: def ?? '');
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(msg, style: GText.sans(size: 15)),
            TextField(controller: t, autofocus: true),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('रद्द करें')),
          TextButton(onPressed: () => Navigator.pop(ctx, t.text), child: const Text('OK')),
        ],
      ),
    );
    return r ?? '';
  }

  /// Files from the page (download / share), sent in base64 pieces by hl-shim.js.
  Future<void> _onMessage(String raw) async {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = (m['id'] as num?)?.toInt() ?? 0;
    switch (m['t']) {
      case 'begin':
        final name = safeHlName('${m['name'] ?? 'file'}', '${m['mime'] ?? ''}');
        final dir = await Directory('${Directory.systemTemp.path}/highlighter-out').create(recursive: true);
        final f = File('${dir.path}/${DateTime.now().microsecondsSinceEpoch}-$name');
        _incoming[id] = (sink: f.openWrite(), file: f, name: name, mime: hlMime(name, '${m['mime'] ?? ''}'), mode: '${m['mode'] ?? 'save'}');
      case 'chunk':
        _incoming[id]?.sink.add(base64Decode('${m['b64']}'));
      case 'end':
        final e = _incoming.remove(id);
        if (e == null) return;
        await e.sink.close();
        await _deliver(e.file, e.name, e.mime, e.mode);
      case 'fail':
        final e = _incoming.remove(id);
        await e?.sink.close();
        Toast.show('फ़ाइल सेव नहीं हो सकी');
    }
  }

  Future<void> _deliver(File f, String name, String mime, String mode) async {
    try {
      if (mode == 'share') {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(f.path, mimeType: mime, name: name)],
            title: name,
          ),
        );
        return;
      }
      final saved = await NativeBridge.copyToDownloads(f.path, name, mime);
      if (saved != null) {
        Toast.show('Downloads में सेव हुआ: $name');
      } else {
        // Could not write to Downloads (old phone without permission…): offer the share sheet.
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(f.path, mimeType: mime, name: name)],
            title: name,
          ),
        );
      }
    } catch (_) {
      Toast.show('फ़ाइल सेव नहीं हो सकी');
    }
  }

  Future<void> _back() async {
    final c = _c;
    if (c != null && await c.canGoBack()) {
      await c.goBack();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    for (final e in _incoming.values) {
      e.sink.close();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(statusBarColor: const Color(0xFF111111)),
      child: Scaffold(
        backgroundColor: const Color(0xFF111111),
        body: SafeArea(
          child: Column(
            children: [
              ListenableBuilder(
                listenable: Listenable.merge([_srv.prefetch, _srv.missedOffline]),
                builder: (context, _) {
                  final t = _hideNotice
                      ? null
                      : highlighterNotice(allCached: _srv.allCached, online: _online, wifiOnlyWaiting: _wifiOnlyWaiting, prefetch: _srv.prefetch.value, missed: _srv.missedOffline.value);
                  if (t == null) return const SizedBox.shrink();
                  return Material(
                    key: const ValueKey('hl-notice'),
                    color: GColors.brown,
                    child: InkWell(
                      onTap: () => setState(() => _hideNotice = true),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(t, style: GText.sans(size: 12.5, color: GColors.cream, height: 1.35)),
                            ),
                            const SizedBox(width: 8),
                            Icon(Icons.close, size: 16, color: GColors.cream.withValues(alpha: 0.7)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              Expanded(
                child: _c == null ? const Center(child: CircularProgressIndicator(color: GColors.gold)) : WebViewWidget(controller: _c!),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// File name for Downloads: no path characters; an extension that matches the type.
String safeHlName(String name, String mime) {
  var n = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]+'), ' ').trim();
  if (n.isEmpty) n = 'file';
  if (!n.contains('.')) {
    if (mime.contains('pdf')) n = '$n.pdf';
    if (mime.contains('png')) n = '$n.png';
    if (mime.contains('jpeg') || mime.contains('jpg')) n = '$n.jpg';
  }
  return n.length > 120 ? n.substring(n.length - 120) : n;
}

String hlMime(String name, String mime) {
  if (mime.isNotEmpty) return mime;
  final l = name.toLowerCase();
  if (l.endsWith('.pdf')) return 'application/pdf';
  if (l.endsWith('.png')) return 'image/png';
  if (l.endsWith('.jpg') || l.endsWith('.jpeg')) return 'image/jpeg';
  return 'application/octet-stream';
}
