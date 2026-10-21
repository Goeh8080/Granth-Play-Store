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

  /// Moves a finished temp file into `documents/granth/Granth/name` (rename, or copy +
  /// delete across volumes).
  static Future<File> moveLocal(String source, String name) async {
    final dest = File('${Store.I.pdfDir}/${safeName(name)}');
    final src = File(source);
    try {
      return await src.rename(dest.path);
    } on FileSystemException {
      final part = File('${dest.path}.part');
      try {
        await src.copy(part.path);
        final f = await part.rename(dest.path);
        await src.delete();
        return f;
      } catch (_) {
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
        rethrow;
      }
    }
  }

  /// Writes to `name.part` and renames it into place, so a crash, a full disk or the app
  /// being killed never leaves a broken file under the real name. The partial file is
  /// removed on failure (and by [cleanupPartials] on the next start).
  static Future<File> writeAtomic(File f, List<int> bytes) async {
    final part = File('${f.path}.part');
    try {
      await part.parent.create(recursive: true);
      await part.writeAsBytes(bytes, flush: true);
      return await part.rename(f.path);
    } catch (_) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Removes `*.part` / `*.tmp` leftovers of writes that were cut off (app killed mid-save).
  static Future<int> cleanupPartials() async {
    if (!Store.I.ready) return 0;
    var n = 0;
    for (final dir in [Store.I.pdfDir, Store.I.galleryDir, Store.I.imagesDir, Store.I.root.path]) {
      try {
        final d = Directory(dir);
        if (!await d.exists()) continue;
        await for (final e in d.list(followLinks: false)) {
          if (e is File && (e.path.endsWith('.part') || e.path.endsWith('.tmp'))) {
            try {
              await e.delete();
              n++;
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    return n;
  }

  static Future<File> ensureLocal(String sourcePath, String name) async {
    final dest = File('${Store.I.pdfDir}/${safeName(name)}');
    if (dest.path == sourcePath) return dest;
    if (await dest.exists() && await dest.length() > 64) return dest;
    final part = '${dest.path}.part';
    try {
      await File(sourcePath).copy(part);
      return await File(part).rename(dest.path);
    } catch (_) {
      try {
        await File(part).delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// `xe()`/`we()` — save to the phone: PDFs to Downloads, pictures to the album.
  static Future<bool> exportToDevice(String sourcePath, String name) async => await exportToDeviceUri(sourcePath, name) != null;

  /// Same as [exportToDevice]; returns where the copy went (MediaStore URI or path), or null.
  static Future<String?> exportToDeviceUri(String sourcePath, String name) async {
    final File local;
    try {
      local = await ensureLocal(sourcePath, name);
    } catch (_) {
      return null;
    }
    final mime = mimeOf(name);
    return isPdf(name)
        ? await NativeBridge.copyToDownloads(local.path, safeName(name), mime)
        : await NativeBridge.saveImageToAlbum(local.path, safeName(name), mime);
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
