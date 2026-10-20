import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../theme/colors.dart';
import 'common.dart';

/// `.video-block` — "वीडियो चलाएँ" then an embedded YouTube player (needs internet).
class VideoBlock extends StatefulWidget {
  const VideoBlock({super.key, required this.videoId, required this.start, required this.desc, required this.title});
  final String videoId;
  final int start;
  final String desc;
  final String title;
  @override
  State<VideoBlock> createState() => _VideoBlockState();
}

class _VideoBlockState extends State<VideoBlock> {
  WebViewController? _c;

  void _play() {
    final src = 'https://www.youtube.com/embed/${widget.videoId}?autoplay=1&playsinline=1${widget.start > 0 ? '&start=${widget.start}' : ''}';
    final html = '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>html,body{margin:0;height:100%;background:#000}iframe{border:0;width:100%;height:100%}</style></head>'
        '<body><iframe src="$src" title="${const HtmlEscape().convert(widget.title)}" '
        'allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe></body></html>';
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      ..loadHtmlString(html, baseUrl: 'https://granth.grok.me/');
    setState(() => _c = c);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            transitionBuilder: (c, a) => FadeTransition(opacity: a, child: SizeTransition(sizeFactor: a, alignment: Alignment.topCenter, child: c)),
            child: _c == null || kIsWeb
                ? Padding(
                    key: const ValueKey('btn'),
                    padding: const EdgeInsets.only(top: 12),
                    child: Pill(label: 'वीडियो चलाएँ ${widget.start > 0 ? '(${widget.start}s)' : ''}', tone: PillTone.maroon, onTap: _play),
                  )
                : Padding(
                    key: const ValueKey('player'),
                    padding: const EdgeInsets.only(top: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: AspectRatio(aspectRatio: 16 / 9, child: WebViewWidget(controller: _c!)),
                    ),
                  ),
          ),
          if (widget.desc.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(widget.desc, style: GText.sans(size: 14, color: GColors.muted, height: 1.55))),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('वीडियो चलाने के लिए इंटरनेट चाहिए। पेज की तस्वीर ऑफलाइन रहती है।', style: GText.sans(size: 12, color: GColors.muted)),
          ),
        ]),
      );
}

class HtmlEscape {
  const HtmlEscape();
  String convert(String s) => s.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}
