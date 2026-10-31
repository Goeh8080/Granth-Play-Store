/// Round 14: अकाउंट (optional Google sign-in) and सहायता (support tickets, CONTRACT §5.1) pages.
/// Login is never required: every other screen works the same without it.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/firebase_bridge.dart';
import '../services/remote_config.dart';
import '../services/support.dart';
import '../state/router.dart';
import '../state/toast.dart';
import '../theme/colors.dart';
import '../widgets/common.dart';
import '../widgets/overlays.dart';

InputDecoration _box(String hint) => InputDecoration(
  hintText: hint,
  filled: true,
  fillColor: GColors.cream,
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: const BorderSide(color: GColors.creamDark),
  ),
);

Widget _page(Key key, List<Widget> children) => SliverPadding(
  key: key,
  padding: const EdgeInsets.fromLTRB(2, 4, 2, 24),
  sliver: SliverToBoxAdapter(
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  ),
);

class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([FirebaseBridge.I, RemoteConfig.I]),
    builder: (context, _) {
      final fb = FirebaseBridge.I;
      final a = fb.account;
      return _page(const ValueKey('account-page'), [
        SheetHead(title: 'अकाउंट', onBack: AppNav.I.back, direct: true),
        FrostCard(
          child: a == null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('लॉगिन ज़रूरी नहीं है', style: GText.script(size: 19, color: GColors.maroon)),
                    const SizedBox(height: 6),
                    Text('पूरा ऐप बिना लॉगिन के चलता है। Google से लॉगिन करने पर आपका नाम और Gmail यहाँ दिखेगा।', style: GText.sans(size: 14, color: GColors.muted, height: 1.45)),
                    const SizedBox(height: 12),
                    SheetButton(
                      key: const ValueKey('account-google'),
                      label: fb.busy ? 'लॉगिन हो रहा है…' : 'Google से लॉगिन करें',
                      primary: true,
                      enabled: !fb.busy,
                      onTap: () async {
                        final e = await fb.signIn();
                        if (e != null) Toast.show(e);
                      },
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        _Avatar(url: a.photo, name: a.name.isEmpty ? a.email : a.name),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                a.name.isEmpty ? 'भक्त' : a.name,
                                key: const ValueKey('account-name'),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: GText.sans(size: 17, weight: FontWeight.w700, color: GColors.maroon),
                              ),
                              Text(
                                a.email,
                                key: const ValueKey('account-email'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GText.sans(size: 13.5, color: GColors.muted),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (RemoteConfig.I.bhaktIdEnabled) ...[
                      const SizedBox(height: 12),
                      Text(
                        'भक्त ID: जल्द आ रहा है',
                        key: const ValueKey('account-bhakt-id'),
                        style: GText.sans(size: 14, color: GColors.brown),
                      ),
                    ],
                    const SizedBox(height: 14),
                    SheetButton(
                      key: const ValueKey('account-logout'),
                      icon: 'log-out',
                      label: 'लॉगआउट',
                      onTap: () async {
                        await fb.signOut();
                        Toast.show('लॉगआउट हो गया');
                      },
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 14),
        if (RemoteConfig.I.supportEnabled)
          Align(
            alignment: Alignment.centerLeft,
            child: Pill(key: const ValueKey('account-support'), direct: true, icon: 'ticket', label: 'सहायता / टिकट', onTap: () => AppNav.I.openLink('#/support')),
          ),
      ]);
    },
  );
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, required this.name});
  final String url, name;
  @override
  Widget build(BuildContext context) {
    final letter = name.isEmpty ? '?' : String.fromCharCode(name.runes.first).toUpperCase();
    final fallback = CircleAvatar(
      radius: 26,
      backgroundColor: GColors.saffron,
      child: Text(
        letter,
        style: GText.sans(size: 20, weight: FontWeight.w700, color: Colors.white),
      ),
    );
    if (!url.startsWith('https://')) return fallback;
    return ClipOval(
      child: Image.network(url, key: const ValueKey('account-photo'), width: 52, height: 52, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
    );
  }
}

class SupportPage extends StatefulWidget {
  const SupportPage({super.key});
  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  final _msg = TextEditingController();
  final _subject = TextEditingController();
  final _reply = TextEditingController();
  bool _sending = false;
  int? _open;

  @override
  void initState() {
    super.initState();
    unawaited(SupportService.I.refresh());
  }

  @override
  void dispose() {
    _msg.dispose();
    _subject.dispose();
    _reply.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    final a = FirebaseBridge.I.account;
    final e = await SupportService.I.create(_msg.text, subject: _subject.text, name: a?.name ?? '', contact: a?.email ?? '');
    if (!mounted) return;
    setState(() => _sending = false);
    if (e != null) {
      Toast.show(e);
      return;
    }
    _msg.clear();
    _subject.clear();
    final t = SupportService.I.tickets.isEmpty ? null : SupportService.I.tickets.first;
    Toast.show(t == null ? 'टिकट भेज दिया गया' : 'टिकट भेज दिया गया · ${t.label}');
  }

  Future<void> _toggle(SupportTicket t) async {
    setState(() => _open = _open == t.id ? null : t.id);
    if (t.hasNewReply) await SupportService.I.ack([t.id]);
  }

  Future<void> _sendReply(SupportTicket t) async {
    final e = await SupportService.I.reply(t.id, _reply.text);
    if (e != null) {
      Toast.show(e);
      return;
    }
    _reply.clear();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: SupportService.I,
    builder: (context, _) {
      final s = SupportService.I;
      return _page(const ValueKey('support-page'), [
        SheetHead(title: 'सहायता', onBack: AppNav.I.back, direct: true),
        FrostCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('नया टिकट', style: GText.script(size: 19, color: GColors.maroon)),
              const SizedBox(height: 4),
              Text('अपनी समस्या लिखें। हर टिकट को उस दिन का टोकन नंबर मिलता है। जवाब यहीं दिखेगा।', style: GText.sans(size: 13.5, color: GColors.muted, height: 1.45)),
              const SizedBox(height: 10),
              TextField(key: const ValueKey('support-subject'), controller: _subject, maxLength: 120, style: GText.sans(size: 15), decoration: _box('विषय (वैकल्पिक)')),
              TextField(key: const ValueKey('support-message'), controller: _msg, minLines: 3, maxLines: 6, maxLength: 2000, style: GText.sans(size: 15), decoration: _box('संदेश')),
              const SizedBox(height: 6),
              SheetButton(key: const ValueKey('support-send'), label: _sending ? 'भेजा जा रहा है…' : 'टिकट भेजें', primary: true, enabled: !_sending, onTap: _send),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text(
                'मेरे टिकट',
                style: GText.sans(size: 16, weight: FontWeight.w700, color: GColors.maroon),
              ),
            ),
            Pill(key: const ValueKey('support-refresh'), direct: true, icon: 'refresh-cw', label: s.loading ? '…' : 'ताज़ा करें', onTap: s.refresh),
          ],
        ),
        const SizedBox(height: 8),
        if (s.error != null && s.tickets.isEmpty)
          Text(
            s.error!,
            key: const ValueKey('support-error'),
            style: GText.sans(size: 13.5, color: GColors.muted),
          ),
        if (s.error == null && !s.loading && s.tickets.isEmpty) Text('अभी कोई टिकट नहीं है।', style: GText.sans(size: 13.5, color: GColors.muted)),
        for (final t in s.tickets)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: FrostCard(
              key: ValueKey('ticket-${t.id}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TapTarget(
                    key: ValueKey('ticket-head-${t.id}'),
                    onTap: () => _toggle(t),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t.label,
                                style: GText.sans(size: 14.5, weight: FontWeight.w700, color: GColors.maroon),
                              ),
                              Text(
                                t.subject.isEmpty ? t.message : t.subject,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: GText.sans(size: 13.5, color: GColors.brown),
                              ),
                            ],
                          ),
                        ),
                        if (t.hasNewReply) Pill(key: ValueKey('ticket-new-${t.id}'), label: 'नया जवाब', tone: PillTone.maroon),
                        const SizedBox(width: 6),
                        Text(t.open ? 'खुला' : 'बंद', style: GText.sans(size: 12, color: GColors.muted)),
                      ],
                    ),
                  ),
                  if (_open == t.id) ...[
                    const SizedBox(height: 8),
                    for (final m in t.messages)
                      Align(
                        alignment: m.fromAdmin ? Alignment.centerLeft : Alignment.centerRight,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                          decoration: BoxDecoration(color: m.fromAdmin ? GColors.cream : GColors.creamDark, borderRadius: BorderRadius.circular(12)),
                          child: Text('${m.fromAdmin ? 'एडमिन: ' : ''}${m.text}', style: GText.sans(size: 14, height: 1.4)),
                        ),
                      ),
                    if (t.open) ...[
                      TextField(key: ValueKey('ticket-reply-${t.id}'), controller: _reply, minLines: 1, maxLines: 4, maxLength: 2000, style: GText.sans(size: 14.5), decoration: _box('जवाब लिखें')),
                      SheetButton(key: ValueKey('ticket-reply-send-${t.id}'), label: 'भेजें', primary: true, onTap: () => _sendReply(t)),
                    ],
                  ],
                ],
              ),
            ),
          ),
      ]);
    },
  );
}
