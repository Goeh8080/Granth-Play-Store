import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';

import '../services/remote_config.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../ai/ai_client.dart';
import '../ai/chat_controller.dart';
import '../ai/chat_store.dart';
import '../ai/sanitize.dart';
import '../models/models.dart';
import '../services/analytics.dart';
import '../services/ai_feedback.dart';
import '../services/api.dart';
import '../services/card_pdf.dart';
import '../services/catalog_store.dart';
import '../services/file_actions.dart';
import '../state/places.dart';
import '../state/router.dart';
import '../state/toast.dart';
import '../theme/colors.dart';
import '../widgets/common.dart';
import '../widgets/granth_image.dart';
import '../widgets/light_markdown.dart';
import '../widgets/overlays.dart';
import '../widgets/panel.dart';

/// Where the AI usage policy page is (the note under the text box links here).
const String kAiPolicyLink = '#/legal?p=ai';

/// Suggestions on the empty chat. Each is answerable from the catalog.
const List<String> kAiSuggestions = [
  'गीता में कर्म योग क्या है?',
  'श्राद्ध के बारे में ग्रंथ क्या कहते हैं?',
  'मूर्ति पूजा पर क्या प्रमाण हैं?',
  'सतलोक क्या है?',
  'पुनर्जन्म से मुक्ति कैसे मिलती है?',
];

/// तत्त्व AI से पूछे — the chat. The text box ([AiComposer]) is pinned under the page by
/// `HomeShell`; everything else is a normal sliver list inside the shared scroll view.
class AiPanel extends StatefulWidget {
  const AiPanel({super.key});

  @override
  State<AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<AiPanel> {
  final ChatController c = ChatController.I;
  final GlobalKey _lastAnswer = GlobalKey();
  int _tick = 0;
  String? _id;
  final Map<int, Praman> _byId = {};

  @override
  void initState() {
    super.initState();
    _tick = c.tick;
    _id = c.current?.id;
    c.addListener(_onChat);
    c.load().then((_) {
      if (mounted) _toBottomIfFresh();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottomIfFresh());
  }

  @override
  void dispose() {
    c.removeListener(_onChat);
    super.dispose();
  }

  ScrollPosition? get _pos => Scrollable.maybeOf(context)?.position;

  /// First visit (nothing saved for this list): show the newest message, not the top.
  void _toBottomIfFresh() {
    if (!mounted || c.messages.isEmpty || Places.y('ai-place') > 0) return;
    _jumpBottom();
  }

  void _jumpBottom({int frames = 4}) {
    void step(int n) {
      if (!mounted) return;
      final p = _pos;
      if (p != null && p.hasContentDimensions && p.userScrollDirection == ScrollDirection.idle) p.jumpTo(p.maxScrollExtent);
      if (n > 1) WidgetsBinding.instance.addPostFrameCallback((_) => step(n - 1));
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => step(frames));
  }

  /// Scrolling that doesn't fight the person: a new question always shows; an answer
  /// scrolls into view only if they were already following the end; switching chats
  /// jumps to the newest message.
  void _onChat() {
    if (!mounted) return;
    final switched = c.current?.id != _id;
    _id = c.current?.id;
    if (c.tick == _tick) return;
    _tick = c.tick;
    final p = _pos;
    final near = p == null || !p.hasContentDimensions || p.maxScrollExtent - p.pixels < 260;
    final last = c.messages.isEmpty ? null : c.messages.last;
    if (last == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (_pos?.hasContentDimensions ?? false)) _pos!.jumpTo(0);
      });
    } else if (switched) {
      _jumpBottom();
    } else if (last.isUser) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final p = _pos;
        if (!mounted || p == null) return;
        p.animateTo(p.maxScrollExtent, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
      });
    } else if (near) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _lastAnswer.currentContext;
        if (!mounted || ctx == null) return;
        Scrollable.ensureVisible(ctx, alignment: 0.04, duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);
      });
    }
  }

  Praman? _find(int id) {
    if (_byId.isEmpty) {
      for (final p in CatalogStore.I.pramans) {
        final n = int.tryParse(p.id);
        if (n != null) _byId[n] = p;
      }
    }
    return _byId[id];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: RemoteConfig.I, builder: (context, _) => RemoteConfig.I.aiEnabled ? _chat(context) : const _AiOff());

  Widget _chat(BuildContext context) {
    final dx = panelDx();
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final msgs = c.messages;
        final lastAi = msgs.lastIndexWhere((m) => !m.isUser && !m.isAdmin);
        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: Entry(
                index: 0,
                dx: dx,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: PageHeader(
                    tone: Tone.saffron,
                    icon: 'sparkles',
                    title: 'तत्त्व AI से पूछे',
                    subtitle: 'अपना प्रश्न पूछिए, प्रमाण पाइए',
                    tools: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        Pill(
                          key: const ValueKey('ai-history'),
                          icon: 'history',
                          label: 'पुरानी बातचीत',
                          fontSize: 13,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          onTap: () => openChatHistory(context),
                        ),
                        Pill(
                          key: const ValueKey('ai-gyan'),
                          icon: 'book-open',
                          label: 'ज्ञान चर्चा',
                          fontSize: 13,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          onTap: c.sending ? null : _gyan,
                        ),
                        Pill(
                          key: const ValueKey('ai-new'),
                          icon: 'plus',
                          label: 'नई चैट',
                          tone: PillTone.maroon,
                          fontSize: 13,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          onTap: msgs.isEmpty ? null : c.newChat,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (msgs.isEmpty)
              SliverToBoxAdapter(
                child: Entry(
                  index: 1,
                  dx: dx,
                  child: _Intro(onAsk: (q) => askQuestion(q)),
                ),
              )
            else
              SliverList.builder(
                itemCount: msgs.length,
                itemBuilder: (context, i) {
                  final m = msgs[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: m.isUser
                        ? UserBubble(m.text)
                        : m.isAdmin
                        ? AdminBubble(m)
                        : AnswerBubble(key: i == lastAi ? _lastAnswer : ValueKey('ans-${c.current?.id}-$i'), msg: m, question: i > 0 ? msgs[i - 1].text : '', find: _find, chatId: c.current?.id ?? ''),
                  );
                },
              ),
            if (msgs.isNotEmpty)
              SliverToBoxAdapter(
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  alignment: Alignment.topCenter,
                  child: c.sending
                      ? const Padding(padding: EdgeInsets.only(bottom: 14), child: ThinkingBubble())
                      : (c.error != null || (c.current?.pending ?? false))
                      ? Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: _ErrorCard(error: c.error, onRetry: c.retry),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ),
            if (msgs.isNotEmpty && !c.sending && c.offer != null && c.offer!.convId == c.current?.id)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: AskAdminCard(offer: c.offer!, onYes: c.askAdmin, onNo: c.declineOffer),
                ),
              ),
            if (c.gyan != null && c.gyan!.convId == c.current?.id)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: SheetButton(key: const ValueKey('gyan-reveal'), label: 'उत्तर और प्रमाण देखें', icon: 'eye', primary: true, onTap: c.revealGyan),
                ),
              ),
          ],
        );
      },
    );
  }
}

Future<void> _gyan() async {
  if (!await ChatController.I.startGyan()) Toast.show('अभी चर्चा के लिए कोई प्रश्न नहीं है');
}

/// Sends [q] unless the catalog is not there yet (the answer must rest on granth data).
Future<bool> askQuestion(String q) async {
  final c = ChatController.I;
  if (c.sending) return false;
  if (c.pramans.isEmpty) {
    Toast.show('पहले ग्रंथ-डेटा लोड होने दें, फिर प्रश्न पूछें');
    return false;
  }
  return c.send(q);
}

// ---------------------------------------------------------------------------------------

class _Intro extends StatelessWidget {
  const _Intro({required this.onAsk});
  final void Function(String) onAsk;

  @override
  Widget build(BuildContext context) => GCard(
    key: const ValueKey('ai-intro'),
    padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const IconBox(tone: Tone.saffron, icon: 'sparkles', size: 44, radius: 12, iconSize: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text('नमस्ते! पूछिए', style: GText.display(size: 24, color: GColors.maroon, height: 1.3)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'अपना प्रश्न नीचे लिखिए। मैं इसी ऐप के ग्रंथों और प्रमाणों में से सबसे मिलते-जुलते प्रमाण खोजकर उत्तर दूँगा, और हर उत्तर के साथ वे प्रमाण भी दिखाऊँगा जिन पर वह टिका है।',
          style: GText.sans(size: 15, color: GColors.muted, height: 1.65),
        ),
        const SizedBox(height: 14),
        Text(
          'कुछ सुझाव',
          style: GText.sans(size: 13, weight: FontWeight.w700, color: GColors.brown),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in kAiSuggestions)
              Pill(key: ValueKey('ai-sug-$s'), label: s, tone: PillTone.topic, fontSize: 14, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9), onTap: () => onAsk(s)),
          ],
        ),
        const SizedBox(height: 14),
        const _Caution(),
      ],
    ),
  );
}

/// "AI गलती कर सकता है, मूल ग्रंथ से मिलाएँ" + the policy link.
class _Caution extends StatelessWidget {
  const _Caution({this.size = 12.5});
  final double size;
  @override
  Widget build(BuildContext context) => Pressable(
    onTap: () => AppNav.I.openLink(kAiPolicyLink),
    scale: 0.99,
    child: Text.rich(
      TextSpan(
        style: GText.sans(size: size, color: GColors.muted, height: 1.5),
        children: [
          const TextSpan(text: 'AI गलती कर सकता है, मूल ग्रंथ से मिलाएँ · '),
          TextSpan(
            text: 'AI उपयोग नीति',
            style: GText.sans(size: size, weight: FontWeight.w700, color: GColors.maroon, height: 1.5).copyWith(decoration: TextDecoration.underline),
          ),
        ],
      ),
    ),
  );
}

class UserBubble extends StatelessWidget {
  const UserBubble(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [GColors.maroonLight, GColors.maroon]),
          borderRadius: BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18), bottomLeft: Radius.circular(18), bottomRight: Radius.circular(5)),
        ),
        child: SelectableText(text, style: GText.sans(size: 16, color: GColors.paper, height: 1.55)),
      ),
    ),
  );
}

class _Avatar extends StatelessWidget {
  const _Avatar();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(top: 2),
    child: IconBox(tone: Tone.saffron, icon: 'sparkles', size: 32, radius: 10, iconSize: 17),
  );
}

class AnswerBubble extends StatefulWidget {
  const AnswerBubble({super.key, required this.msg, required this.question, required this.find, this.chatId = ''});
  final ChatMsg msg;
  final String question;
  final Praman? Function(int id) find;
  final String chatId;

  @override
  State<AnswerBubble> createState() => _AnswerBubbleState();
}

class _AnswerBubbleState extends State<AnswerBubble> {
  final _card = GlobalKey();
  bool _busy = false;

  ChatMsg get msg => widget.msg;
  String get _fkey => '${widget.chatId}-${msg.at}';

  /// Never shows a raw "id-467": known ids become the praman's name, unknown ones are dropped.
  String get _text => sanitizeAiText(msg.text, (id) => widget.find(id)?.title);
  String get _plain => markdownPlain(_text);

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _plain));
    Toast.show('उत्तर कॉपी हो गया');
  }

  Future<void> _share() async {
    final q = widget.question.isEmpty ? '' : 'प्रश्न: ${widget.question}\n\n';
    await FileActions.shareText('तत्त्व AI', '$q$_plain\n\n— तत्त्व AI, ग्रंथ प्रबंधन (AI गलती कर सकता है, मूल ग्रंथ से मिलाएँ)');
  }

  void _up() {
    final was = AiFeedback.I.vote(_fkey) == 1;
    AiFeedback.I.up(_fkey);
    if (!was) Toast.show('धन्यवाद! आपकी राय दर्ज हो गई');
  }

  Future<void> _down() async {
    if (AiFeedback.I.vote(_fkey) == -1) return Toast.show('यह उत्तर पहले ही admin को भेजा जा चुका है');
    final reason = await showPop<String>(context, (ctx) => const AiReasonCard(), blurFocus: true);
    if (reason == null) return; // closed: nothing sent
    unawaited(AiFeedback.I.down(_fkey, question: widget.question, answer: _plain, reason: reason, chat: widget.chatId));
    Toast.show('धन्यवाद! यह उत्तर admin को जाँच के लिए भेजा जा रहा है');
  }

  Future<void> _cardPdf() async {
    if (_busy) return;
    final how = await showPop<String>(context, (ctx) => const CardPdfChoice());
    if (how == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final f = await CardPdf.build(_card, CardPdf.fileName(widget.question.isEmpty ? 'तत्त्व AI उत्तर' : widget.question));
      if (f == null) return Toast.show('कार्ड PDF नहीं बन सका');
      if (how == 'save') {
        Toast.show(await CardPdf.save(f) ? 'कार्ड PDF सेव हो गई' : 'सेव नहीं हो सका');
      } else {
        await CardPdf.share(f);
      }
    } catch (_) {
      Toast.show('कार्ड PDF नहीं बन सका');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cited = [for (final id in msg.cited) ?widget.find(id)];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Avatar(),
        const SizedBox(width: 8),
        Expanded(
          child: RepaintBoundary(
            key: _card,
            child: GCard(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Long-press selects a word and shows Copy; handles extend the selection.
                  SelectionArea(child: LightMarkdown(_text, size: 15.5)),
                  if (cited.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'आधार प्रमाण',
                      style: GText.sans(size: 12.5, weight: FontWeight.w700, color: GColors.brown),
                    ),
                    const SizedBox(height: 6),
                    _Citations(cited),
                    for (final p in cited.take(2)) Padding(padding: const EdgeInsets.only(top: 8), child: PramanPreview(p)),
                  ],
                  const SizedBox(height: 8),
                  ListenableBuilder(
                    listenable: AiFeedback.I,
                    builder: (context, _) {
                      final v = AiFeedback.I.vote(_fkey);
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Pill(key: const ValueKey('ai-up'), icon: 'thumbs-up', label: v == 1 ? 'पसंद ✓' : 'पसंद', tone: v == 1 ? PillTone.topic : PillTone.plain, onTap: _up),
                          if (RemoteConfig.I.aiFlagsEnabled)
                            Pill(key: const ValueKey('ai-down'), icon: 'thumbs-down', label: v == -1 ? 'भेजा ✓' : 'गलत', tone: v == -1 ? PillTone.topic : PillTone.plain, onTap: _down),
                          Pill(key: const ValueKey('ai-share'), icon: 'share-2', label: 'शेयर', onTap: _share),
                          Pill(key: const ValueKey('ai-copy'), icon: 'copy', label: 'कॉपी', onTap: _copy),
                          Pill(key: const ValueKey('ai-card-pdf'), icon: 'file-text', label: _busy ? 'बन रही…' : 'कार्ड PDF', onTap: _cardPdf),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 👎: an optional reason, then Send. Pops the reason ('' when empty), or null when closed.
class AiReasonCard extends StatefulWidget {
  const AiReasonCard({super.key});
  @override
  State<AiReasonCard> createState() => _AiReasonCardState();
}

class _AiReasonCardState extends State<AiReasonCard> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FrostCard(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('इस उत्तर में क्या गलत है?', style: GText.script(size: 19, color: GColors.maroon)),
        const SizedBox(height: 4),
        Text('यह प्रश्न और उत्तर admin को जाँच के लिए भेजा जाएगा। कारण लिखना ज़रूरी नहीं।', style: GText.sans(size: 13.5, color: GColors.muted, height: 1.45)),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('ai-reason'),
          controller: _c,
          maxLines: 3,
          minLines: 2,
          maxLength: 300,
          style: GText.sans(size: 15),
          decoration: InputDecoration(
            hintText: 'कारण (वैकल्पिक)',
            filled: true,
            fillColor: GColors.cream,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: GColors.creamDark),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: SheetButton(key: const ValueKey('ai-reason-cancel'), label: 'रहने दें', onTap: () => Navigator.pop(context)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SheetButton(key: const ValueKey('ai-reason-send'), label: 'भेजें', primary: true, onTap: () => Navigator.pop(context, _c.text.trim())),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Card PDF: share it or save it to the phone. Pops 'share' / 'save', or null.
class CardPdfChoice extends StatelessWidget {
  const CardPdfChoice({super.key});
  @override
  Widget build(BuildContext context) => FrostCard(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('कार्ड PDF', style: GText.script(size: 19, color: GColors.maroon)),
        const SizedBox(height: 4),
        Text('यह कार्ड जैसा ऐप में दिखता है, वैसा ही PDF बनेगा।', style: GText.sans(size: 13.5, color: GColors.muted, height: 1.45)),
        const SizedBox(height: 12),
        SheetButton(key: const ValueKey('card-pdf-share'), icon: 'share-2', label: 'शेयर करें', primary: true, onTap: () => Navigator.pop(context, 'share')),
        const SizedBox(height: 8),
        SheetButton(key: const ValueKey('card-pdf-save'), icon: 'folder-down', label: 'फ़ोन में सेव करें', onTap: () => Navigator.pop(context, 'save')),
      ],
    ),
  );
}

void openPraman(Praman p) {
  Analytics.I.aiCiteTap();
  AppNav.I.openLink('#/pramans?id=${Uri.encodeComponent(p.id)}');
}

class _Citations extends StatelessWidget {
  const _Citations(this.pramans);
  final List<Praman> pramans;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) => Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final p in pramans.take(8))
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: c.maxWidth),
            child: Pill(
              key: ValueKey('ai-cite-${p.id}'),
              label: '📖 ${p.granthTitle.isEmpty ? 'ग्रंथ' : p.granthTitle} › ${p.title}',
              tone: PillTone.topic,
              maxLines: 2,
              fontSize: 12.5,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              onTap: () => openPraman(p),
            ),
          ),
        if (pramans.length > 8) Pill(label: '+${pramans.length - 8} और'),
      ],
    ),
  );
}

/// A small card for one cited praman: thumbnail (when it has a picture) + title + a snippet.
class PramanPreview extends StatelessWidget {
  const PramanPreview(this.p, {super.key});
  final Praman p;

  @override
  Widget build(BuildContext context) {
    final img = mediaPath(p.imagePath) ?? mediaPath(p.granthImage);
    final snippet = p.description.trim().isEmpty ? p.topicTitle : p.description.trim();
    return Pressable(
      onTap: () => openPraman(p),
      scale: 0.985,
      child: Container(
        key: ValueKey('ai-preview-${p.id}'),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: GColors.cream,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: GColors.creamDark),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (img != null) ...[GranthImage(path: img, kind: ShotKind.thumb), const SizedBox(width: 10)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GText.script(size: 15, color: GColors.maroon),
                  ),
                  if (snippet.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        snippet,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GText.sans(size: 13, color: GColors.muted, height: 1.45),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'खोलें ›',
                      style: GText.sans(size: 12, weight: FontWeight.w700, color: GColors.saffronDark),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ThinkingBubble extends StatefulWidget {
  const ThinkingBubble({super.key});
  @override
  State<ThinkingBubble> createState() => _ThinkingBubbleState();
}

class _ThinkingBubbleState extends State<ThinkingBubble> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final on = !MediaQuery.disableAnimationsOf(context);
    if (on && !_started) {
      _a.repeat();
      _started = true;
    } else if (!on && _started) {
      _a.stop();
      _started = false;
    }
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    key: const ValueKey('ai-thinking'),
    children: [
      const _Avatar(),
      const SizedBox(width: 8),
      Flexible(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: GColors.paper,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: GColors.creamDark),
          ),
          child: AnimatedBuilder(
            animation: _a,
            builder: (context, _) {
              final t = _started ? _a.value : 0.0;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      'सोच रहा हूँ',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GText.sans(size: 15, color: GColors.muted, weight: FontWeight.w500),
                    ),
                  ),
                  const SizedBox(width: 4),
                  for (var i = 0; i < 3; i++)
                    Padding(
                      padding: const EdgeInsets.only(left: 3),
                      child: Opacity(
                        opacity: _started ? (0.25 + 0.75 * math.max(0.0, math.sin((t * 2 - i * 0.28) * math.pi))).clamp(0.25, 1.0) : 0.7,
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(color: GColors.saffron, shape: BoxShape.circle),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    ],
  );
}

/// A message from the admin (an answer to a question the user sent), shown apart from AI answers.
class AdminBubble extends StatelessWidget {
  const AdminBubble(this.msg, {super.key});
  final ChatMsg msg;

  @override
  Widget build(BuildContext context) => GCard(
    key: const ValueKey('admin-msg'),
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'admin का संदेश आया',
          style: GText.sans(size: 13, weight: FontWeight.w700, color: GColors.maroon),
        ),
        if (msg.ask != null) ...[const SizedBox(height: 4), Text('आपका प्रश्न: ${msg.ask}', style: GText.sans(size: 12.5, color: GColors.muted, height: 1.5))],
        const SizedBox(height: 8),
        SelectableText(msg.text, style: GText.sans(size: 15, color: GColors.brown, height: 1.6)),
      ],
    ),
  );
}

/// "क्या आप यह प्रश्न admin को भेजना चाहेंगे?" with हाँ / नहीं.
class AskAdminCard extends StatelessWidget {
  const AskAdminCard({super.key, required this.offer, required this.onYes, required this.onNo});
  final AdminOffer offer;
  final VoidCallback onYes;
  final VoidCallback onNo;

  @override
  Widget build(BuildContext context) => GCard(
    key: const ValueKey('ask-admin'),
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'क्या आप यह प्रश्न admin को भेजना चाहेंगे?',
          style: GText.sans(size: 15, weight: FontWeight.w600, color: GColors.brown, height: 1.5),
        ),
        if (offer.message != null) ...[const SizedBox(height: 6), Text(offer.message!, style: GText.sans(size: 13, color: GColors.muted, height: 1.5))],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (offer.canRetry) SheetButton(key: const ValueKey('ask-admin-yes'), label: offer.sending ? 'भेज रहे हैं…' : 'हाँ', icon: 'send', primary: true, enabled: !offer.sending, onTap: onYes),
            SheetButton(key: const ValueKey('ask-admin-no'), label: 'नहीं', icon: 'x', onTap: onNo),
          ],
        ),
      ],
    ),
  );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error, required this.onRetry});
  final AiException? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _Avatar(),
      const SizedBox(width: 8),
      Expanded(
        child: GCard(
          key: const ValueKey('ai-error'),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(error?.message ?? 'इस प्रश्न का उत्तर अभी नहीं मिला। कृपया फिर कोशिश करें।', style: GText.sans(size: 15, color: GColors.brown, height: 1.6)),
              const SizedBox(height: 4),
              Text('आपका प्रश्न ऊपर सुरक्षित है — दोबारा लिखने की ज़रूरत नहीं।', style: GText.sans(size: 12.5, color: GColors.muted, height: 1.5)),
              const SizedBox(height: 12),
              SheetButton(key: const ValueKey('ai-retry'), label: 'फिर कोशिश करें', icon: 'refresh-cw', primary: true, onTap: onRetry),
            ],
          ),
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------------------

/// The text box + send button + the AI-can-be-wrong note, pinned under the page.
class AiComposer extends StatefulWidget {
  const AiComposer({super.key});
  @override
  State<AiComposer> createState() => _AiComposerState();
}

class _AiComposerState extends State<AiComposer> {
  final ChatController c = ChatController.I;

  Future<void> _send() async {
    final t = c.input.text.trim();
    if (t.isEmpty || c.sending) return;
    if (c.pramans.isEmpty) {
      Toast.show('पहले ग्रंथ-डेटा लोड होने दें, फिर प्रश्न पूछें');
      return;
    }
    c.input.clear();
    HapticFeedback.selectionClick();
    final ok = await c.send(t);
    if (!ok && c.input.text.isEmpty) c.input.text = t;
  }

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: GColors.cream,
      border: const Border(top: BorderSide(color: GColors.creamDark)),
      boxShadow: [BoxShadow(color: GColors.shadow(0.08), blurRadius: 14, offset: const Offset(0, -4))],
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListenableBuilder(
              listenable: Listenable.merge([c, c.input]),
              builder: (context, _) {
                final empty = c.input.text.trim().isEmpty;
                final can = !empty && !c.sending;
                final n = c.input.text.length;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: GColors.paper,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: GColors.saffron.withValues(alpha: 0.7), width: 1.3),
                        ),
                        padding: const EdgeInsets.fromLTRB(16, 2, 12, 2),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            TextField(
                              key: const ValueKey('ai-input'),
                              controller: c.input,
                              minLines: 1,
                              maxLines: 4,
                              maxLength: kQuestionMax,
                              keyboardType: TextInputType.multiline,
                              textInputAction: TextInputAction.newline,
                              textCapitalization: TextCapitalization.sentences,
                              cursorColor: GColors.saffron,
                              style: GText.sans(size: 16, height: 1.5),
                              buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
                              decoration: InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                hintText: 'अपना प्रश्न लिखिए…',
                                hintStyle: GText.sans(size: 16, color: GColors.muted),
                                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                              ),
                            ),
                            if (n > kQuestionMax - 100)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text('$n/$kQuestionMax', style: GText.sans(size: 11, color: n >= kQuestionMax ? GColors.maroon : GColors.muted)),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Pressable(
                      key: const ValueKey('ai-send'),
                      onTap: can ? _send : null,
                      enabled: can,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(color: can ? GColors.maroon : GColors.creamDark, shape: BoxShape.circle),
                        alignment: Alignment.center,
                        child: c.sending
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: GColors.saffron))
                            : GIcon('send', size: 21, color: can ? GColors.paper : GColors.muted),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 5),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: _Caution(size: 11.5)),
          ],
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------------------

String _when(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String t(int n) => n.toString().padLeft(2, '0');
  return '${t(d.day)}/${t(d.month)}/${d.year} ${t(d.hour)}:${t(d.minute)}';
}

Future<void> openChatHistory(BuildContext context) async {
  await ChatController.I.load();
  if (!context.mounted) return;
  await showPop<void>(context, (ctx) => const _HistorySheet());
}

class _HistorySheet extends StatelessWidget {
  const _HistorySheet();

  @override
  Widget build(BuildContext context) {
    final c = ChatController.I;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => SheetCard(
        maxWidth: 480,
        children: [
          SheetHead(title: 'पुरानी बातचीत', onBack: () => Navigator.pop(context)),
          if (c.chats.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'अभी कोई बातचीत सेव नहीं है।',
                textAlign: TextAlign.center,
                style: GText.sans(size: 15, color: GColors.muted),
              ),
            )
          else ...[
            for (final i in c.chats)
              Padding(
                key: ValueKey('chat-${i.id}'),
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Pressable(
                        onTap: () async {
                          Navigator.pop(context);
                          await c.open(i.id);
                        },
                        scale: 0.985,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: i.id == c.current?.id ? GColors.pillTopic : GColors.cream,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: GColors.creamDark),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                i.title.isEmpty ? 'नई बातचीत' : i.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: GText.sans(size: 15, weight: FontWeight.w600, color: GColors.maroon, height: 1.4),
                              ),
                              const SizedBox(height: 2),
                              Text('${_when(i.updated)} · ${i.count} संदेश', style: GText.sans(size: 12, color: GColors.muted)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Pressable(
                      key: ValueKey('chat-del-${i.id}'),
                      onTap: () async {
                        if (await confirmPop(context, 'यह बातचीत मिटा दें?')) await c.delete(i.id);
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: GIcon('trash-2', size: 20, color: GColors.maroon),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            SheetButton(
              key: const ValueKey('chat-clear-all'),
              label: 'सारी बातचीत मिटाएँ',
              icon: 'trash-2',
              onTap: () async {
                if (await confirmPop(context, 'सारी AI बातचीत इस फ़ोन से मिटा दें? यह वापस नहीं आएगी।')) {
                  await c.clearAll();
                  Toast.show('AI बातचीत मिटा दी गई');
                }
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// `ai_enabled: false` in the remote config: a friendly note instead of the chat.
class _AiOff extends StatelessWidget {
  const _AiOff();
  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: EmptyState(
      key: const ValueKey('ai-off'),
      title: 'तत्त्व AI अभी बंद है',
      body: 'यह सुविधा कुछ समय के लिए रोकी गई है। कृपया थोड़ी देर बाद फिर देखिए।',
      actionLabel: 'होम पर जाएँ',
      onAction: () => AppNav.I.go('#/dashboard'),
    ),
  );
}
