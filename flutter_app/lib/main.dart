import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home_shell.dart';
import 'screens/splash_screen.dart';
import 'services/catalog_store.dart';
import 'services/events.dart';
import 'services/storage.dart';
import 'state/router.dart';
import 'theme/colors.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await Store.I.init();
  AppNav.I.restore();
  EventLog.I.log('app_open', 'app');
  final boot = CatalogStore.I.boot();
  runApp(GranthApp(ready: boot));
}

class GranthApp extends StatefulWidget {
  const GranthApp({super.key, this.ready, this.splash = true, this.links = true});
  final Future<void>? ready;
  final bool splash;
  final bool links;
  @override
  State<GranthApp> createState() => _GranthAppState();
}

class _GranthAppState extends State<GranthApp> with WidgetsBindingObserver {
  StreamSubscription<Uri>? _links;
  String _lastLink = '';
  int _lastLinkAt = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.links) _listenLinks();
  }

  void _listenLinks() {
    try {
      final al = AppLinks();
      _links = al.uriLinkStream.listen(_open, onError: (_) {});
    } catch (_) {}
  }

  /// `__granthOpenLink` with the same 5 s de-duplication.
  void _open(Uri u) {
    final h = hashFromLink(u);
    if (h == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastLink == h && now - _lastLinkAt < 5000) return;
    _lastLink = h;
    _lastLinkAt = now;
    AppNav.I.openLink(h);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) CatalogStore.I.onResume();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _links?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ग्रंथ प्रबंधन',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3)),
          child: child!,
        ),
        home: widget.splash ? AnimatedSplash(ready: widget.ready, child: const HomeShell()) : const HomeShell(),
      );
}
