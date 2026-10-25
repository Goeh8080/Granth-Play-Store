import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ai/chat_controller.dart';
import '../config.dart';
import '../legal/legal_pages.dart';
import '../services/file_actions.dart';
import '../services/remote_config.dart';
import '../state/router.dart';
import '../state/toast.dart';
import '../theme/colors.dart';
import '../widgets/common.dart';
import '../widgets/overlays.dart';
import '../widgets/panel.dart';

const String kContactsSlug = 'contacts';

/// `#/legal` (the list of policies), `#/legal?p=<slug>` (one policy) and `#/legal?p=contacts`
/// (विशेष जानकार). Everything is bundled, so it reads offline.
class LegalPanel extends StatelessWidget {
  const LegalPanel({super.key, this.page});
  final String? page;

  @override
  Widget build(BuildContext context) {
    final dx = panelDx();
    if (page == kContactsSlug) return const ContactsView();
    final p = legalBySlug(page);
    if (p != null) return _LegalReader(p, dx: dx);
    return _LegalList(dx: dx);
  }
}

class _LegalList extends StatelessWidget {
  const _LegalList({required this.dx});
  final double dx;

  @override
  Widget build(BuildContext context) => SliverMainAxisGroup(slivers: [
        SliverToBoxAdapter(
          child: Entry(
            index: 0,
            dx: dx,
            child: const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: PageHeader(tone: Tone.maroon, icon: 'shield', title: 'कानूनी और नीतियाँ', subtitle: 'ऐप की नीतियाँ, शर्तें और संपर्क'),
            ),
          ),
        ),
        SliverList.builder(
          itemCount: kLegalPages.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return _row(key: const ValueKey('legal-contacts'), icon: 'phone', title: RemoteConfig.I.contactsTitle, blurb: 'ऐप से जुड़े विशेष जानकार लोग', onTap: () => AppNav.I.openLink('#/legal?p=$kContactsSlug'));
            }
            final p = kLegalPages[i - 1];
            return _row(key: ValueKey('legal-${p.slug}'), icon: p.icon, title: p.title, blurb: p.blurb, onTap: () => AppNav.I.openLink('#/legal?p=${p.slug}'));
          },
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text('अंतिम अपडेट: $kLegalUpdated · संस्करण $kAppVersion', textAlign: TextAlign.center, style: GText.sans(size: 12, color: GColors.muted)),
          ),
        ),
      ]);

  Widget _row({required Key key, required String icon, required String title, required String blurb, required VoidCallback onTap}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: GCard(
          key: key,
          padding: const EdgeInsets.all(12),
          onTap: onTap,
          child: Row(children: [
            IconBox(tone: Tone.saffron, icon: icon, size: 40, iconSize: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: GText.script(size: 17, color: GColors.maroon)),
                const SizedBox(height: 2),
                Text(blurb, style: GText.sans(size: 13, color: GColors.muted, height: 1.4)),
              ]),
            ),
            const SizedBox(width: 6),
            const GIcon('chevron-right', size: 18, color: GColors.muted),
          ]),
        ),
      );
}

class _LegalReader extends StatelessWidget {
  const _LegalReader(this.page, {required this.dx});
  final LegalPage page;
  final double dx;

  @override
  Widget build(BuildContext context) {
    final blocks = page.blocks();
    return SliverMainAxisGroup(slivers: [
      SliverToBoxAdapter(
        child: Entry(
          index: 0,
          dx: dx,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: PageHeader(tone: Tone.maroon, icon: page.icon, title: page.title, subtitle: page.blurb),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: GCard(
          key: ValueKey('legal-body-${page.slug}'),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final b in blocks) _block(b)]),
        ),
      ),
      SliverToBoxAdapter(child: _Extras(page.slug)),
    ]);
  }

  Widget _block(LegalBlock b) {
    switch (b.kind) {
      case LegalKind.h:
        return Padding(padding: const EdgeInsets.only(top: 14, bottom: 6), child: Text(b.text, style: GText.script(size: 18, color: GColors.maroon, height: 1.4)));
      case LegalKind.p:
        return Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(b.text, style: GText.sans(size: 14.5, color: GColors.brown, height: 1.65)));
      case LegalKind.bullets:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final t in b.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(padding: const EdgeInsets.only(top: 9, right: 10, left: 2), child: Container(width: 5, height: 5, decoration: const BoxDecoration(color: GColors.saffron, shape: BoxShape.circle))),
                  Expanded(child: Text(t, style: GText.sans(size: 14.5, color: GColors.brown, height: 1.6))),
                ]),
              ),
          ]),
        );
    }
  }
}

/// Buttons that belong under one page's text.
class _Extras extends StatelessWidget {
  const _Extras(this.slug);
  final String slug;

  @override
  Widget build(BuildContext context) {
    final pills = <Widget>[];
    Pill pill(String key, String icon, String label, VoidCallback onTap, {PillTone tone = PillTone.plain}) => Pill(
          key: ValueKey(key),
          icon: icon,
          label: label,
          tone: tone,
          fontSize: 13,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          onTap: onTap,
        );
    switch (slug) {
      case 'privacy':
        pills.add(pill('x-ai', 'sparkles', 'AI उपयोग नीति', () => AppNav.I.openLink('#/legal?p=ai')));
        pills.add(pill('x-delete', 'trash-2', 'डेटा हटाने का अधिकार', () => AppNav.I.openLink('#/legal?p=delete')));
      case 'delete':
        pills.add(pill('clear-chats', 'trash-2', 'चैट इतिहास मिटाएँ', () => clearChatHistory(context), tone: PillTone.maroon));
      case 'thirdparty':
        pills.add(pill('licenses', 'library', 'ओपन-सोर्स लाइसेंस देखें', () => showLicensePage(context: context, applicationName: 'ग्रंथ प्रबंधन', applicationVersion: kAppVersion)));
      case 'grievance':
        if (hasContactEmail) pills.add(pill('mail-us', 'send', kContactEmail, () => FileActions.openMail(kContactEmail), tone: PillTone.maroon));
        pills.add(pill('x-contacts', 'phone', RemoteConfig.I.contactsTitle, () => AppNav.I.openLink('#/legal?p=$kContactsSlug')));
      case 'copyright':
        pills.add(pill('x-grievance', 'message-circle', 'शिकायत और संपर्क', () => AppNav.I.openLink('#/legal?p=grievance')));
      case 'ai':
        pills.add(pill('x-privacy', 'shield', 'गोपनीयता नीति', () => AppNav.I.openLink('#/legal?p=privacy')));
    }
    if (pills.isEmpty) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(top: 14), child: Wrap(spacing: 8, runSpacing: 8, children: pills));
  }
}

/// "चैट इतिहास मिटाएँ": confirm, wipe every saved chat, say so.
Future<void> clearChatHistory(BuildContext context) async {
  final ok = await confirmPop(context, 'तत्त्व AI की सारी पुरानी बातचीत इस फ़ोन से मिटा दें? यह वापस नहीं आएगी।');
  if (!ok) return;
  await ChatController.I.clearAll();
  Toast.show('चैट इतिहास मिटा दिया गया');
}

// ---------------------------------------------------------------------------------------------
// विशेष जानकार

class ContactsView extends StatelessWidget {
  const ContactsView({super.key});

  @override
  Widget build(BuildContext context) {
    final dx = panelDx();
    return ListenableBuilder(
      listenable: RemoteConfig.I,
      builder: (context, _) {
        final rc = RemoteConfig.I;
        final list = rc.contacts;
        return SliverMainAxisGroup(slivers: [
          SliverToBoxAdapter(
            child: Entry(
              index: 0,
              dx: dx,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: PageHeader(tone: Tone.saffron, icon: 'users', title: rc.contactsTitle, subtitle: 'ऐप से जुड़े लोग'),
              ),
            ),
          ),
          if (list.isEmpty)
            const SliverToBoxAdapter(child: EmptyState(key: ValueKey('contacts-empty'), title: 'अभी कोई नाम नहीं', body: 'यहाँ जल्द ही नाम जोड़े जाएँगे।'))
          else
            SliverList.builder(
              itemCount: list.length,
              itemBuilder: (context, i) => Padding(padding: const EdgeInsets.only(bottom: 10), child: ContactCard(list[i])),
            ),
        ]);
      },
    );
  }
}

class ContactCard extends StatelessWidget {
  const ContactCard(this.c, {super.key});
  final Contact c;

  @override
  Widget build(BuildContext context) {
    final hasPhone = c.phone.trim().isNotEmpty;
    return GCard(
      key: ValueKey('contact-${c.id}'),
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          const IconBox(tone: Tone.maroon, icon: 'users', size: 40, iconSize: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name, style: GText.script(size: 18, color: GColors.maroon, height: 1.35)),
              if (c.role.trim().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(c.role, style: GText.sans(size: 13, color: GColors.muted, height: 1.4))),
            ]),
          ),
        ]),
        if (hasPhone) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            Pill(
              key: ValueKey('contact-phone-${c.id}'),
              icon: 'phone',
              label: c.phone,
              tone: PillTone.maroon,
              fontSize: 14,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              onTap: () => showContactActions(context, c),
            ),
            if (c.whatsapp)
              Pill(
                key: ValueKey('contact-wa-${c.id}'),
                icon: 'message-circle',
                label: 'WhatsApp',
                fontSize: 14,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                onTap: () => openWhatsApp(c.phone),
              ),
          ]),
        ],
      ]),
    );
  }
}

/// wa.me wants the number as digits only (no "+").
String whatsappDigits(String phone) => phone.replaceAll(RegExp(r'[^0-9]'), '');

Future<void> openWhatsApp(String phone) async {
  final d = whatsappDigits(phone);
  if (d.isEmpty) return;
  try {
    await launchUrl(Uri.parse('https://wa.me/$d'), mode: LaunchMode.externalApplication);
  } catch (_) {
    Toast.show('WhatsApp नहीं खुल सका');
  }
}

Future<void> callNumber(String phone) async {
  try {
    await launchUrl(Uri(scheme: 'tel', path: phone.trim()));
  } catch (_) {
    Toast.show('डायलर नहीं खुल सका');
  }
}

Future<void> showContactActions(BuildContext context, Contact c) => showPop<void>(
      context,
      (ctx) => SheetCard(
        maxWidth: 400,
        children: [
          Text(c.name, style: GText.display(size: 22, color: GColors.maroon, height: 1.3)),
          const SizedBox(height: 4),
          Text(c.phone, key: const ValueKey('contact-sheet-phone'), style: GText.sans(size: 17, weight: FontWeight.w700, color: GColors.brown)),
          const SizedBox(height: 14),
          SheetButton(
            label: 'कॉल करें',
            primary: true,
            onTap: () {
              Navigator.pop(ctx);
              callNumber(c.phone);
            },
          ),
          const SizedBox(height: 8),
          SheetButton(
            label: 'नंबर कॉपी करें',
            onTap: () async {
              Navigator.pop(ctx);
              await Clipboard.setData(ClipboardData(text: c.phone));
              Toast.show('नंबर कॉपी हो गया');
            },
          ),
          const SizedBox(height: 8),
          SheetButton(label: 'रद्द करें', onTap: () => Navigator.pop(ctx)),
        ],
      ),
    );
