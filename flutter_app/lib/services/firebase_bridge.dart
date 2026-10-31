/// Firebase (project granth-management): Analytics, Crashlytics, optional Google sign-in and
/// FCM topic subscriptions. Everything is optional and guarded: when Firebase can not start
/// (tests, no Play services, offline first run) the app works exactly as before.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../state/router.dart';
import '../state/toast.dart';
import 'analytics.dart';
import 'remote_config.dart';
import 'storage.dart';

/// Optional Web OAuth client id (when google-services.json carries none).
const String kGoogleWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

/// FCM topics (provisional until CONTRACT.md names them; see round14_backend_needs.md).
/// CONTRACT §6.3 FCM topics. `all` is always on (unless `flags.notifications_enabled` is false).
class PushTopics {
  static const all = 'all';
  static const newPraman = 'new_praman';
  static const newTopic = 'new_topic';
  static const trending = 'trending';
  static const daily = 'daily';
  static const toggles = [daily, newPraman, newTopic, trending];
  static const every = [all, ...toggles];
}

class AccountInfo {
  const AccountInfo({required this.email, this.name = '', this.photo = ''});
  final String email, name, photo;
  Map<String, String> toJson() => {'email': email, 'name': name, 'photo': photo};
  static AccountInfo? fromJson(Object? j) =>
      j is Map && j['email'] is String && (j['email'] as String).isNotEmpty ? AccountInfo(email: j['email'] as String, name: '${j['name'] ?? ''}', photo: '${j['photo'] ?? ''}') : null;
}

class FirebaseBridge extends ChangeNotifier {
  FirebaseBridge._();
  static final FirebaseBridge I = FirebaseBridge._();

  static const kAccount = 'granth-account';
  static const kPush = 'granth-push-topics';

  bool ready = false;
  bool busy = false;
  String? error;
  AccountInfo? _account;

  static bool get _supported => !kIsWeb && Platform.isAndroid && !Platform.environment.containsKey('FLUTTER_TEST');

  AccountInfo? get account => _account ??= AccountInfo.fromJson(_decode(Store.I.getString(kAccount)));
  bool get signedIn => account != null;

  static Object? _decode(String? s) {
    try {
      return s == null ? null : jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  Future<void> init() async {
    if (!_supported || ready) return;
    try {
      await Firebase.initializeApp().timeout(const Duration(seconds: 4));
      ready = true;
    } catch (e) {
      debugPrint('firebase: init: $e');
      return;
    }
    try {
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(!kDebugMode);
      final prev = FlutterError.onError;
      FlutterError.onError = (d) {
        prev?.call(d);
        FirebaseCrashlytics.instance.recordFlutterError(d);
      };
      final prevP = PlatformDispatcher.instance.onError;
      PlatformDispatcher.instance.onError = (e, st) {
        FirebaseCrashlytics.instance.recordError(e, st, fatal: true);
        return prevP?.call(e, st) ?? true;
      };
    } catch (e) {
      debugPrint('firebase: crashlytics: $e');
    }
    Analytics.screenForward = (screen) => unawaited(FirebaseAnalytics.instance.logScreenView(screenName: screen).catchError((_) {}));
    Analytics.forward = (name, params) => unawaited(FirebaseAnalytics.instance.logEvent(name: name, parameters: params).catchError((_) {}));
    // The signed-in Firebase user wins over the cache (e.g. revoked on another device).
    try {
      final u = FirebaseAuth.instance.currentUser;
      if (u == null && _account != null) await _setAccount(null);
      if (u != null && u.email != null) await _setAccount(AccountInfo(email: u.email!, name: u.displayName ?? '', photo: u.photoURL ?? ''));
    } catch (_) {}
    unawaited(syncTopics());
    unawaited(_initMessaging());
    notifyListeners();
  }

  /// Records a non-fatal error (no-op without Firebase).
  void recordError(Object e, StackTrace? st) {
    if (!ready) return;
    try {
      FirebaseCrashlytics.instance.recordError(e, st);
    } catch (_) {}
  }

  Future<void> _setAccount(AccountInfo? a) async {
    _account = a;
    if (a == null) {
      await Store.I.remove(kAccount);
    } else {
      await Store.I.setString(kAccount, jsonEncode(a.toJson()));
    }
    notifyListeners();
  }

  /// Google sign-in (optional). Returns null on success, or a Hindi message.
  Future<String?> signIn() async {
    if (busy) return null;
    if (!ready) return error = 'लॉगिन अभी उपलब्ध नहीं है।';
    busy = true;
    error = null;
    notifyListeners();
    try {
      final g = GoogleSignIn.instance;
      await g.initialize(serverClientId: kGoogleWebClientId.isEmpty ? null : kGoogleWebClientId);
      final acc = await g.authenticate();
      final idToken = acc.authentication.idToken;
      final cred = await FirebaseAuth.instance.signInWithCredential(GoogleAuthProvider.credential(idToken: idToken));
      final u = cred.user;
      await _setAccount(AccountInfo(email: u?.email ?? acc.email, name: u?.displayName ?? acc.displayName ?? '', photo: u?.photoURL ?? acc.photoUrl ?? ''));
      return null;
    } on GoogleSignInException catch (e) {
      error = e.code == GoogleSignInExceptionCode.canceled ? null : 'Google लॉगिन नहीं हो सका।';
      return error;
    } catch (e) {
      recordError(e, StackTrace.current);
      return error = 'Google लॉगिन नहीं हो सका।';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    try {
      if (ready) {
        await FirebaseAuth.instance.signOut();
        await GoogleSignIn.instance.signOut();
      }
    } catch (_) {}
    await _setAccount(null);
  }

  /// A fresh Firebase ID token (for the server's Firebase verify), or null.
  Future<String?> idToken() async {
    try {
      return ready ? await FirebaseAuth.instance.currentUser?.getIdToken() : null;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------ push topics
  Set<String> get topics {
    final j = _decode(Store.I.getString(kPush));
    if (j is List) {
      return {
        PushTopics.all,
        for (final e in j)
          if (e is String && PushTopics.every.contains(e)) e,
      };
    }
    return {...PushTopics.every};
  }

  bool subscribed(String t) => topics.contains(t);

  Future<void> setTopic(String t, bool on) async {
    final s = topics;
    on ? s.add(t) : s.remove(t);
    await Store.I.setString(kPush, jsonEncode(s.toList()..sort()));
    notifyListeners();
    if (!ready || !RemoteConfig.I.notificationsEnabled) return;
    try {
      if (on) {
        await FirebaseMessaging.instance.requestPermission();
        await FirebaseMessaging.instance.subscribeToTopic(t);
      } else {
        await FirebaseMessaging.instance.unsubscribeFromTopic(t);
      }
    } catch (e) {
      debugPrint('fcm: $t: $e');
    }
  }

  bool? _pushOn;

  /// Subscribes to the chosen topics, or unsubscribes from every topic when
  /// `flags.notifications_enabled === false` (CONTRACT §6.1). Re-run on config change.
  Future<void> syncTopics() async {
    if (!ready) return;
    final on = RemoteConfig.I.notificationsEnabled;
    _pushOn = on;
    try {
      final m = FirebaseMessaging.instance;
      final want = on ? topics : <String>{};
      for (final t in PushTopics.every) {
        want.contains(t) ? await m.subscribeToTopic(t) : await m.unsubscribeFromTopic(t);
      }
    } catch (e) {
      debugPrint('fcm: sync: $e');
    }
  }

  void _onConfig() {
    if (ready && _pushOn != RemoteConfig.I.notificationsEnabled) unawaited(syncTopics());
  }

  /// `data {topic, id?}` → the screen to open (CONTRACT §6.3), or null.
  static String? linkFor(Map<String, dynamic> data) {
    final id = '${data['id'] ?? ''}'.trim();
    if (id.isEmpty || !RegExp(r'^[A-Za-z0-9_-]{1,40}$').hasMatch(id)) return null;
    final kind = '${data['kind'] ?? data['type'] ?? ''}';
    if (kind == 'granth') return '#/pramans?granth=$id';
    return switch ('${data['topic'] ?? ''}') {
      PushTopics.newTopic || PushTopics.trending => '#/pramans?topic=$id',
      _ => kind == 'topic' ? '#/pramans?topic=$id' : '#/pramans?id=$id',
    };
  }

  void _openMessage(RemoteMessage m) {
    final l = linkFor(m.data);
    if (l != null) AppNav.I.openLink(l);
  }

  Future<void> _initMessaging() async {
    RemoteConfig.I.addListener(_onConfig);
    try {
      FirebaseMessaging.onMessageOpenedApp.listen(_openMessage);
      FirebaseMessaging.onMessage.listen((m) {
        final n = m.notification;
        if (n != null && (n.title ?? n.body) != null) Toast.show([n.title, n.body].whereType<String>().join(' · '));
      });
      final first = await FirebaseMessaging.instance.getInitialMessage();
      if (first != null) _openMessage(first);
    } catch (e) {
      debugPrint('fcm: init: $e');
    }
  }

  @visibleForTesting
  Future<void> debugSetAccount(AccountInfo? a) => _setAccount(a);
}
