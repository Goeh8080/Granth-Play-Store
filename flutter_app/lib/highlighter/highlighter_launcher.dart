// Photo Highlighter — opened in a NATIVE Android Activity (HighlighterActivity.kt): a plain
// full-screen WebView on the page served by highlighter_server.dart. Nothing of Flutter sits in
// its touch path (no PlatformView, no gesture arena), so the page gets the finger exactly like
// Chrome. The rest of the app only calls [HighlighterLauncher.open].
import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

import '../services/image_cache.dart';
import '../services/native_bridge.dart';
import '../services/storage.dart';
import '../state/toast.dart';
import '../state/ui_prefs.dart';
import 'highlighter_server.dart';

/// Hindi status line above the page (the page itself is not changed). The Activity shows it
/// as a banner, reading it from the server's /__status.
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

/// What the phone's network allows right now (for the first-time library download).
typedef HlNet = ({bool online, bool wifiOnlyWaiting});

Future<HlNet> _checkNet() async {
  try {
    final net = await Connectivity().checkConnectivity().timeout(const Duration(seconds: 3));
    final wifi = net.contains(ConnectivityResult.wifi) || net.contains(ConnectivityResult.ethernet);
    return (online: !net.contains(ConnectivityResult.none), wifiOnlyWaiting: Store.I.getString(Store.kWifiOnly) == '1' && !wifi);
  } catch (_) {
    return (online: true, wifiOnlyWaiting: false);
  }
}

class HighlighterLauncher {
  HighlighterLauncher._();

  static bool _busy = false;

  /// What the menu calls (tests replace it, the Activity needs a device).
  @visibleForTesting
  static Future<void> Function(BuildContext context) opener = (_) => openWith();

  static Future<void> open(BuildContext context) => opener(context);

  /// Starts the local server, pauses the background download, opens the Activity and waits
  /// until it is closed. Dependencies are parameters so tests can run it without a device.
  @visibleForTesting
  static Future<void> openWith({
    HighlighterServer? server,
    Future<bool> Function(String url, bool keepAwake)? launch,
    Future<HlNet> Function()? net,
    bool? keepAwake,
    VoidCallback Function()? hold,
  }) async {
    if (_busy) return; // a second tap while it is opening
    _busy = true;
    VoidCallback? release;
    try {
      final srv = server ?? HighlighterServer.I;
      // The page gets the phone to itself: the background page download waits its turn.
      release = (hold ?? ImageStore.I.holdBackground)();
      srv.cacheDir ??= Directory('${Store.I.root.path}/highlighter');
      final origin = await srv.start();
      final n = await (net ?? _checkNet)();
      srv.notice = () => highlighterNotice(allCached: srv.allCached, online: n.online, wifiOnlyWaiting: n.wifiOnlyWaiting, prefetch: srv.prefetch.value, missed: srv.missedOffline.value);
      // First open: save OCR / scan libraries for offline use (the page also fetches on demand).
      if (n.online && !n.wifiOnlyWaiting && !srv.allCached) unawaited(srv.prefetchAll());
      final ok = await (launch ?? ((u, k) => NativeBridge.openHighlighter(u, keepAwake: k)))(origin.toString(), keepAwake ?? UiPrefs.I.keepAwake);
      if (!ok) Toast.show('Photo Highlighter नहीं खुल सका');
    } catch (_) {
      Toast.show('Photo Highlighter नहीं खुल सका');
    } finally {
      release?.call();
      _busy = false;
    }
  }
}
