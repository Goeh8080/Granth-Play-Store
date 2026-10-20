import 'dart:io';
import 'dart:typed_data';

import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'native_bridge.dart';
import 'storage.dart';

/// File helpers replacing the WebView bridge messages (save-chunk, share-chunk, open-chunk,
/// share-saved, export-saved, open-saved, share-text, open-url, open-mail).
class FileActions {
  FileActions._();

  static String safeName(String name) {
    final s = name.replaceAll(RegExp(r'[^\w.\-\u0900-\u097F ]+'), '_');
    final cut = s.length > 80 ? s.substring(0, 80) : s;
    return cut.isEmpty ? 'granth.pdf' : cut;
  }

  static bool isPdf(String name, [String? mime]) => (mime ?? '').contains('pdf') || name.toLowerCase().endsWith('.pdf');

  static String mimeOf(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.pdf')) return 'application/pdf';
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  /// Writes bytes into `documents/granth/Granth/name`.
  static Future<File> writeLocal(Uint8List bytes, String name) async {
    final f = File('${Store.I.pdfDir}/${safeName(name)}');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  static Future<File> ensureLocal(String sourcePath, String name) async {
    final dest = File('${Store.I.pdfDir}/${safeName(name)}');
    if (dest.path == sourcePath) return dest;
    if (await dest.exists() && await dest.length() > 64) return dest;
    return File(sourcePath).copy(dest.path);
  }

  /// `xe()`/`we()` — save to the phone: PDFs to Downloads, pictures to the album.
  static Future<bool> exportToDevice(String sourcePath, String name) async {
    final local = await ensureLocal(sourcePath, name);
    final mime = mimeOf(name);
    final r = isPdf(name)
        ? await NativeBridge.copyToDownloads(local.path, safeName(name), mime)
        : await NativeBridge.saveImageToAlbum(local.path, safeName(name), mime);
    return r != null;
  }

  /// `Ce()` — open a PDF with the system viewer.
  static Future<bool> open(String sourcePath, String name) async {
    final local = await ensureLocal(sourcePath, name);
    final r = await OpenFilex.open(local.path, type: mimeOf(name));
    return r.type == ResultType.done;
  }

  /// `Se()` — share a saved file.
  static Future<void> shareFile(String sourcePath, String name) async {
    final local = await ensureLocal(sourcePath, name);
    await SharePlus.instance.share(ShareParams(files: [XFile(local.path, mimeType: mimeOf(name), name: safeName(name))], title: name));
  }

  /// `_e()` — share text + link.
  static Future<void> shareText(String title, [String? url]) async {
    final text = url == null || url.isEmpty ? title : '$title\n$url';
    await SharePlus.instance.share(ShareParams(text: text, title: title));
  }

  static Future<void> openUrl(String url) async {
    final u = Uri.tryParse(url);
    if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) return;
    await launchUrl(u, mode: LaunchMode.externalApplication);
  }

  static Future<void> openMail(String email) async {
    final to = email.trim();
    if (to.isEmpty) return;
    final gmail = Uri.parse('googlegmail://co?to=${Uri.encodeComponent(to)}');
    try {
      if (await launchUrl(gmail, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
    await launchUrl(Uri(scheme: 'mailto', path: to));
  }
}

class FileActionsBytes {
  FileActionsBytes._();
  static Future<Uint8List> read(String path) => File(path).readAsBytes();
}
