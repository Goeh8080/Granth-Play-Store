/// Round 15: the first-launch login page. Shown once before the dashboard to anyone not signed
/// in; "बाद में" skips it for good (the app works fully offline and without login). Back here is
/// Back on the app's first screen, so it leaves the app.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../services/firebase_bridge.dart';
import '../services/native_bridge.dart';
import '../services/storage.dart';
import '../state/toast.dart';
import '../theme/colors.dart';
import '../widgets/common.dart';

/// Shows [LoginPage] in front of [child] until the user signs in or skips.
class LoginGate extends StatefulWidget {
  const LoginGate({super.key, required this.child});
  final Widget child;

  /// Tests turn the gate off (they boot straight into the dashboard).
  static bool enabled = true;

  static bool get seen => Store.I.getString(Store.kLoginSeen) == '1';
  static void markSeen() => Store.I.setString(Store.kLoginSeen, '1');

  @override
  State<LoginGate> createState() => _LoginGateState();
}

class _LoginGateState extends State<LoginGate> {
  late bool _show = LoginGate.enabled && !LoginGate.seen && !FirebaseBridge.I.signedIn;

  @override
  void initState() {
    super.initState();
    FirebaseBridge.I.addListener(_auth);
  }

  @override
  void dispose() {
    FirebaseBridge.I.removeListener(_auth);
    super.dispose();
  }

  void _auth() {
    if (_show && FirebaseBridge.I.signedIn) _done();
  }

  void _done() {
    LoginGate.markSeen();
    if (mounted) setState(() => _show = false);
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 320),
    child: _show ? LoginPage(key: const ValueKey('login-page'), onSkip: _done) : KeyedSubtree(key: const ValueKey('login-passed'), child: widget.child),
  );
}

const _gLogo =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/><path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/><path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/><path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/></svg>';

/// Google's "Sign in with Google" button (light theme: white, grey border, the 4-colour G).
class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({super.key, required this.onTap, this.busy = false});
  final VoidCallback onTap;
  final bool busy;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(24),
      side: const BorderSide(color: Color(0xFF747775)),
    ),
    child: InkWell(
      customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      onTap: busy ? null : onTap,
      child: SizedBox(
        height: 48,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2)) : SvgPicture.string(_gLogo, width: 20, height: 20),
            const SizedBox(width: 12),
            Text(
              busy ? 'Signing in…' : 'Sign in with Google',
              style: const TextStyle(fontFamily: 'DMSans', fontSize: 15.5, fontWeight: FontWeight.w600, color: Color(0xFF1F1F1F), letterSpacing: 0.25),
            ),
          ],
        ),
      ),
    ),
  );
}

class LoginPage extends StatelessWidget {
  const LoginPage({super.key, required this.onSkip});
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) NativeBridge.exitApp().catchError((Object _) => SystemNavigator.pop());
    },
    child: Scaffold(
      backgroundColor: GColors.cream,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFFFF7EA), GColors.cream]),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 16, 28, 20),
            child: ListenableBuilder(
              listenable: FirebaseBridge.I,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(flex: 3),
                  Center(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(36),
                        boxShadow: [BoxShadow(color: GColors.saffron.withValues(alpha: 0.35), blurRadius: 40, spreadRadius: 4)],
                      ),
                      child: const LogoIcon(size: 120),
                    ),
                  ),
                  const SizedBox(height: 26),
                  Text(
                    'ग्रंथ प्रबंधन',
                    textAlign: TextAlign.center,
                    style: GText.display(size: 34, color: GColors.maroon, letterSpacing: 0.5),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'सत ग्रंथों के प्रमाण, एक जगह',
                    textAlign: TextAlign.center,
                    style: GText.sans(size: 15.5, color: GColors.brown),
                  ),
                  const Spacer(flex: 2),
                  Text(
                    'लॉगिन करने पर आपका नाम, Gmail और आँकड़े अकाउंट में दिखेंगे। लॉगिन ज़रूरी नहीं है।',
                    textAlign: TextAlign.center,
                    style: GText.sans(size: 13.5, color: GColors.muted, height: 1.45),
                  ),
                  const SizedBox(height: 16),
                  GoogleSignInButton(
                    key: const ValueKey('login-google'),
                    busy: FirebaseBridge.I.busy,
                    onTap: () async {
                      final e = await FirebaseBridge.I.signIn();
                      if (e != null) Toast.show(e);
                    },
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: TextButton(
                      key: const ValueKey('login-skip'),
                      onPressed: onSkip,
                      child: Text(
                        'बाद में',
                        style: GText.sans(size: 14.5, weight: FontWeight.w700, color: GColors.maroon),
                      ),
                    ),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
