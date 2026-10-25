import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';
import '../models/structure.dart';
import 'catalog_store.dart';
import 'ed25519.dart';
import 'shelves.dart';
import 'storage.dart';

/// One person on the "विशेष जानकार" page.
class Contact {
  const Contact({required this.id, required this.name, this.role = '', this.phone = '', this.whatsapp = false, this.order = 0});
  final String id;
  final String name;
  final String role;
  final String phone;
  final bool whatsapp;
  final int order;
}

/// What the app ships with (names exactly as the owner typed them; phones are NOT invented).
const List<Contact> kSeedContacts = [
  Contact(id: 'c1', name: 'अमित दास', order: 1),
  Contact(id: 'c2', name: 'रामेश्वर दर', order: 2),
  Contact(id: 'c3', name: 'गौतम दास', order: 3),
  Contact(id: 'c4', name: 'अशोक दास', order: 4),
];
const String kContactsTitle = 'विशेष जानकार';

class Announcement {
  const Announcement({required this.id, required this.text, this.level = 'info', this.expiresAt});
  final String id;
  final String text;

  /// `info` / `warn` / `critical`.
  final String level;
  final DateTime? expiresAt;
  bool get expired => expiresAt != null && DateTime.now().toUtc().isAfter(expiresAt!);
}

/// A config that passed every check, ready to apply.
class ParsedConfig {
  ParsedConfig({
    required this.version,
    required this.structure,
    required this.overrides,
    required this.hidden,
    required this.announcement,
    required this.aiEnabled,
    required this.analyticsEnabled,
    required this.analyticsSample,
    required this.aiEndpoint,
    required this.contactsTitle,
    required this.contacts,
  });
  final int version;
  final Structure? structure;
  final Map<String, String> overrides;
  final Set<String> hidden;
  final Announcement? announcement;
  final bool aiEnabled;
  final bool analyticsEnabled;
  final double analyticsSample;
  final String? aiEndpoint;
  final String contactsTitle;
  final List<Contact>? contacts;
}

const _religionIcons = {'om', 'crescent', 'khanda', 'cross', 'dharma', 'jain', 'kabir', 'misc'};
const _groupIcons = {
  'scroll', 'book-red', 'book-green', 'book-blue', 'book-orange', 'swords', 'books', 'quran', 'hadees',
  'granth-sahib', 'dasam', 'bible', 'tripitak', 'dhammapad', 'kabir-sagar', 'bijak', 'shabdavali', 'misc',
};
final _slug = RegExp(r'^[a-z0-9][a-z0-9_-]{0,39}$');
final _gid = RegExp(r'^[0-9]{1,8}$');
final _annId = RegExp(r'^[A-Za-z0-9_-]{1,40}$');
final _phone = RegExp(r'^(\+[0-9]{1,19}|[0-9]{1,20})$');

/// Config icon keys → painted symbols. Unknown → `misc` (never an error).
String religionIconKey(Object? k) {
  final s = '$k';
  if (s == 'ektara') return 'kabir'; // the old key; the इकतारा became the Kabir symbol
  return _religionIcons.contains(s) ? s : 'misc';
}

String groupIconKey(Object? k) => _groupIcons.contains('$k') ? '$k' : 'misc';

Map<String, dynamic>? _map(Object? v) => v is Map ? v.cast<String, dynamic>() : null;
String _title(Object? v) => v is String ? v.trim() : '';

ShelfGroup? _group(Object? raw, {required bool allowSub}) {
  final j = _map(raw);
  if (j == null) return null;
  final id = '${j['id']}';
  final title = _title(j['title']);
  if (!_slug.hasMatch(id) || title.isEmpty || title.length > 60) return null;
  final subs = <ShelfGroup>[];
  if (allowSub && j['subgroups'] is List) {
    final seen = <String>{};
    for (final s in j['subgroups'] as List) {
      final g = _group(s, allowSub: false);
      if (g != null && seen.add(g.id)) subs.add(g);
    }
  }
  List<String> ids(Object? v) => [for (final e in (v is List ? v : const [])) if (e is String && _gid.hasMatch(e)) e];
  List<String> words(Object? v) => [for (final e in (v is List ? v : const [])) if (e is String && e.trim().isNotEmpty) e];
  return ShelfGroup(
    id: id,
    title: title,
    icon: groupIconKey(j['icon']),
    granthIds: ids(j['granthIds'] ?? j['forceIds']),
    keywords: words(j['keywords']),
    notKeywords: words(j['notKeywords']),
    subgroups: subs,
    visible: j['visible'] != false,
    comingSoon: _title(j['coming_soon']),
  );
}

/// The config's `structure` → the app's [Structure], or null when it is unusable.
Structure? parseStructure(Object? raw) {
  final j = _map(raw);
  if (j == null || j['religions'] is! List) return null;
  final religions = <ShelfReligion>[];
  final seen = <String>{};
  for (final r in j['religions'] as List) {
    final m = _map(r);
    if (m == null) continue;
    final id = '${m['id']}';
    final title = _title(m['title']);
    if (!_slug.hasMatch(id) || id == kOtherId || title.isEmpty || title.length > 60 || !seen.add(id)) continue;
    final groups = <ShelfGroup>[];
    final gseen = <String>{};
    for (final g in (m['groups'] is List ? m['groups'] as List : const [])) {
      final p = _group(g, allowSub: true);
      if (p != null && gseen.add(p.id)) groups.add(p);
    }
    final tone = '${m['tone']}';
    religions.add(ShelfReligion(
      id: id,
      title: title,
      tone: const {'saffron', 'maroon', 'gold'}.contains(tone) ? tone : 'saffron',
      icon: religionIconKey(m['icon']),
      groups: groups,
      visible: m['visible'] != false,
      comingSoon: _title(m['coming_soon']),
    ));
  }
  if (religions.isEmpty) return null;
  final o = _map(j['other']);
  final other = o == null
      ? const ShelfGroup(id: kOtherId, title: 'अन्य', icon: 'misc')
      : ShelfGroup(
          id: kOtherId,
          title: _title(o['title']).isEmpty ? 'अन्य' : _title(o['title']),
          icon: religionIconKey(o['icon']),
          granthIds: [for (final e in (o['forceIds'] is List ? o['forceIds'] as List : const [])) if (e is String && _gid.hasMatch(e)) e],
          comingSoon: _title(o['coming_soon']),
        );
  return Structure(religions: religions, other: other);
}

/// `contacts` → valid, visible people, sorted by `order`. Invalid entries are dropped one by one.
List<Contact>? parseContacts(Object? raw) {
  if (raw is! List) return null;
  final out = <Contact>[];
  final ids = <String>{};
  for (final e in raw.take(50)) {
    final m = _map(e);
    if (m == null) continue;
    final id = m['id'];
    final name = m['name'];
    if (id is! String || !RegExp(r'^[A-Za-z0-9_-]{1,40}$').hasMatch(id) || ids.contains(id)) continue;
    if (name is! String || name.trim().isEmpty || name.trim().length > 80) continue;
    final role = m['role'] is String ? (m['role'] as String).trim() : '';
    if (role.length > 80) continue;
    final phone = m['phone'] is String ? (m['phone'] as String) : '';
    if (phone.isNotEmpty && !_phone.hasMatch(phone)) continue;
    final order = m['order'] is num ? (m['order'] as num).toInt() : 1 << 30;
    if (m['visible'] == false) {
      ids.add(id);
      continue;
    }
    ids.add(id);
    out.add(Contact(id: id, name: name.trim(), role: role, phone: phone, whatsapp: phone.isNotEmpty && m['whatsapp'] == true, order: order));
  }
  out.sort((a, b) => a.order.compareTo(b.order));
  return out;
}

/// Verify + validate a config text. Returns null (with [why] set) when it must be ignored — the
/// caller then keeps the last good config / the bundled structure. Never throws.
ParsedConfig? parseConfig(String text, {int cachedVersion = 0, int appBuild = kBuildNumber, List<int>? publicKey, void Function(String why)? why}) {
  ParsedConfig? fail(String m) {
    why?.call(m);
    return null;
  }

  try {
    if (text.length > 70000) return fail('too big');
    final dec = jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
    final j = _map(dec);
    if (j == null) return fail('not an object');
    final sigText = j.remove('sig');
    if (sigText is! String) return fail('no signature');
    final ok = ed25519Verify(publicKey ?? base64Decode(kConfigPublicKey), canonicalBytes(j), base64Decode(sigText));
    if (!ok) return fail('bad signature');
    if (j['schema'] != 1) return fail('schema');
    final version = j['version'];
    if (version is! int || version < cachedVersion) return fail('older version');
    final minApp = j['min_app'];
    if (minApp is num && minApp > appBuild) return fail('min_app');
    Structure? structure;
    if (j.containsKey('structure')) {
      structure = parseStructure(j['structure']);
      if (structure == null) return fail('structure');
    }
    final leafKeys = {for (final l in (structure ?? Shelves.bundled).leaves()) l.key, kOtherId};
    final overrides = <String, String>{};
    final ov = _map(j['overrides']);
    if (ov != null) {
      ov.forEach((id, v) {
        final leaf = _map(v)?['leaf'];
        if (_gid.hasMatch(id) && leaf is String && leafKeys.contains(leaf)) overrides[id] = leaf;
      });
    }
    final hidden = <String>{
      for (final e in (j['hidden_granth_ids'] is List ? j['hidden_granth_ids'] as List : const [])) if (e is String && _gid.hasMatch(e)) e,
    };
    Announcement? ann;
    final a = _map(j['announcement']);
    if (a != null && a['enabled'] == true) {
      final t = _title(a['text']);
      final id = a['id'];
      if (t.isNotEmpty && t.length <= 280 && id is String && _annId.hasMatch(id)) {
        final lv = '${a['level']}';
        ann = Announcement(
          id: id,
          text: t,
          level: const {'info', 'warn', 'critical'}.contains(lv) ? lv : 'info',
          expiresAt: a['expires_at'] is String ? DateTime.tryParse(a['expires_at'] as String)?.toUtc() : null,
        );
      }
    }
    final f = _map(j['flags']) ?? const <String, dynamic>{};
    final sample = f['analytics_sample'];
    String? ai;
    final ep = _map(j['endpoints']);
    if (ep != null && ep['ai'] is String) {
      final u = Uri.tryParse((ep['ai'] as String).trim());
      if (u != null && u.scheme == 'https' && u.host.isNotEmpty && (ep['ai'] as String).length <= 200) ai = (ep['ai'] as String).trim().replaceAll(RegExp(r'/+$'), '');
    }
    final cp = _map(j['contacts_page']);
    final ct = cp == null ? '' : _title(cp['title']);
    return ParsedConfig(
      version: version,
      structure: structure,
      overrides: overrides,
      hidden: hidden,
      announcement: ann,
      aiEnabled: f['ai_enabled'] != false,
      analyticsEnabled: f['analytics_enabled'] != false,
      analyticsSample: sample is num ? sample.toDouble().clamp(0.0, 1.0) : 1.0,
      aiEndpoint: ai,
      contactsTitle: ct.isNotEmpty && ct.length <= 60 ? ct : kContactsTitle,
      contacts: parseContacts(j['contacts']),
    );
  } catch (e) {
    return fail('error: $e');
  }
}

String _normEtag(String? e) => (e ?? '').trim().replaceFirst(RegExp(r'^W/'), '');

/// The signed remote config: folders, hidden granths, announcement, flags, contacts.
///
/// Everything has a fallback: the bundled structure and seed contacts. A failed fetch, a bad
/// signature, a wrong schema, an older version or an app older than `min_app` changes nothing and
/// shows nothing. Fetched on every catalog sync with a conditional GET (ETag).
class RemoteConfig extends ChangeNotifier {
  RemoteConfig({Dio? dio, this.url = kConfigUrl, this.build = kBuildNumber, this.publicKey})
      : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 8), receiveTimeout: const Duration(seconds: 8)));
  static RemoteConfig I = RemoteConfig();

  static const fileName = 'remote_config.json';
  static const kEtag = 'granth-cfg-etag';
  static const kDismissed = 'granth-ann-dismissed';

  final Dio _dio;
  final String url;
  final int build;

  /// Tests sign with their own key; the app always uses [kConfigPublicKey].
  final List<int>? publicKey;

  /// Off under `flutter test` (no test talks to the real server unless it builds its own instance).
  bool enabled = !Platform.environment.containsKey('FLUTTER_TEST');

  int version = 0;
  Set<String> hidden = const {};
  Announcement? announcement;
  bool aiEnabled = true;
  bool analyticsEnabled = true;
  double analyticsSample = 1.0;
  String? aiEndpoint;
  String contactsTitle = kContactsTitle;
  List<Contact> contacts = kSeedContacts;

  /// Last refresh outcome, for tests/diagnostics: `updated`, `unchanged`, `ignored:<why>`, `failed`.
  String lastResult = 'none';

  /// Version string sent with analytics.
  int get cfgVersion => version;

  bool get hasContacts => contacts.isNotEmpty;

  /// The banner to show now (enabled, not expired, not dismissed).
  Announcement? get banner {
    final a = announcement;
    if (a == null || a.expired) return null;
    return Store.I.getString(kDismissed) == a.id ? null : a;
  }

  Future<void> dismissBanner() async {
    final a = announcement;
    if (a == null) return;
    await Store.I.setString(kDismissed, a.id);
    notifyListeners();
  }

  /// Boot: apply the saved config (checked again — a damaged / tampered file is dropped).
  Future<void> load() async {
    try {
      final text = await Store.I.readText(fileName);
      if (text == null) return;
      final p = parseConfig(text, appBuild: build, publicKey: publicKey);
      if (p == null) {
        unawaited(Store.I.remove(kEtag));
        return;
      }
      _apply(p, notify: false);
    } catch (e) {
      debugPrint('remote config: load: $e');
    }
  }

  Future<bool>? _running;

  /// Conditional GET; returns true when a newer config was applied. Never throws.
  Future<bool> refresh() => _running ??= _refresh().whenComplete(() => _running = null);

  Future<bool> _refresh() async {
    if (!enabled) return false;
    try {
      final etag = Store.I.getString(kEtag);
      final res = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {if (etag != null && etag.isNotEmpty && version > 0) 'If-None-Match': etag},
          validateStatus: (s) => s == 200 || s == 304,
        ),
      );
      if (res.statusCode == 304) {
        lastResult = 'unchanged';
        return false;
      }
      final body = res.data ?? '';
      final newTag = res.headers.value('etag');
      if (newTag != null && version > 0 && _normEtag(newTag) == _normEtag(etag)) {
        lastResult = 'unchanged';
        return false;
      }
      String? why;
      final p = parseConfig(body, cachedVersion: version, appBuild: build, publicKey: publicKey, why: (m) => why = m);
      if (p == null) {
        lastResult = 'ignored:$why';
        return false;
      }
      final changed = p.version != version || !_same(body);
      await Store.I.writeText(fileName, body);
      if (newTag != null) await Store.I.setString(kEtag, newTag);
      _cachedBody = body;
      if (changed) _apply(p);
      lastResult = 'updated';
      return changed;
    } catch (e) {
      lastResult = 'failed';
      debugPrint('remote config: $e');
      return false;
    }
  }

  String? _cachedBody;
  bool _same(String body) => _cachedBody == body;

  void _apply(ParsedConfig p, {bool notify = true}) {
    version = p.version;
    hidden = p.hidden;
    announcement = p.announcement;
    aiEnabled = p.aiEnabled;
    analyticsEnabled = p.analyticsEnabled;
    analyticsSample = p.analyticsSample;
    aiEndpoint = p.aiEndpoint;
    contactsTitle = p.contactsTitle;
    contacts = p.contacts ?? kSeedContacts;
    Shelves.useRemote(p.structure, p.overrides);
    CatalogStore.I.setHidden(p.hidden);
    if (notify) notifyListeners();
  }

  /// Tests: apply a parsed config directly.
  @visibleForTesting
  void debugApply(ParsedConfig p) => _apply(p);

  /// Tests: forget everything (back to the bundled state).
  @visibleForTesting
  void debugReset() {
    version = 0;
    hidden = const {};
    announcement = null;
    aiEnabled = true;
    analyticsEnabled = true;
    analyticsSample = 1.0;
    aiEndpoint = null;
    contactsTitle = kContactsTitle;
    contacts = kSeedContacts;
    lastResult = 'none';
    _cachedBody = null;
    Shelves.useRemote(null, const {});
  }
}
