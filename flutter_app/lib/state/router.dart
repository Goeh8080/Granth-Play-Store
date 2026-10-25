import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../services/events.dart';
import '../services/storage.dart';

enum Panel { dashboard, topics, granths, pramans, gallery, ai }

/// `ig()` — the parsed hash route of the web app (`#/pramans?topic=…`).
@immutable
class GRoute {
  const GRoute(this.panel, {this.topicId, this.granthId, this.pramanId, this.religionId, this.groupId, this.subId, this.flat = false});
  final Panel panel;
  final String? topicId;
  final String? granthId;
  final String? pramanId;

  /// Round 10 — the folder levels of the Granth tab (`#/granths?r=…&g=…&s=…`): religion, group,
  /// sub-group. All null = the religions screen. [flat] (`#/granths?all=1`) = the old flat list.
  final String? religionId;
  final String? groupId;
  final String? subId;
  final bool flat;

  static GRoute parse(String hash) {
    final raw = hash.replaceFirst(RegExp('^#'), '');
    final parts = (raw.isEmpty ? '/dashboard' : raw).split('?');
    final path = parts.first.isEmpty ? '/dashboard' : parts.first;
    final q = parts.length > 1 ? Uri.splitQueryString(parts[1].split('#').first) : const <String, String>{};
    String? v(String k) => (q[k] ?? '').isEmpty ? null : q[k];
    if (path.startsWith('/gallery')) return const GRoute(Panel.gallery);
    if (path.startsWith('/ai')) return const GRoute(Panel.ai);
    if (path.startsWith('/topics')) return const GRoute(Panel.topics);
    if (path.startsWith('/granths')) {
      if (v('all') == '1') return const GRoute(Panel.granths, flat: true);
      final r = v('r');
      // A group needs a religion and a sub-group a group: a half-formed link shows the level above.
      final g = r == null ? null : v('g');
      final s = g == null ? null : v('s');
      return GRoute(Panel.granths, religionId: r, groupId: g, subId: s);
    }
    if (path.startsWith('/pramans')) return GRoute(Panel.pramans, topicId: v('topic'), granthId: v('granth'), pramanId: v('id'));
    return const GRoute(Panel.dashboard);
  }

  String get key => '${panel.name}:${topicId ?? ''}:${granthId ?? ''}:${pramanId ?? ''}${_folderKey()}';

  // Empty for every route that existed before round 10, so their keys are unchanged.
  String _folderKey() => flat
      ? '|all'
      : religionId == null
          ? ''
          : '|${[religionId, groupId, subId].nonNulls.join('/')}';

  /// `#/granths?r=…&g=…&s=…` for a folder level.
  static String folderHash({String? religion, String? group, String? sub}) {
    if (religion == null) return '#/granths';
    return '#/granths?r=${Uri.encodeQueryComponent(religion)}${group != null ? '&g=${Uri.encodeQueryComponent(group)}' : ''}${group != null && sub != null ? '&s=${Uri.encodeQueryComponent(sub)}' : ''}';
  }

  @override
  bool operator ==(Object other) => other is GRoute && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

const _topHashes = {'#/dashboard', '#/topics', '#/granths', '#/pramans', '#/gallery', '#/ai'};

bool _isDash(String h) => h == '#/dashboard' || h == '#/' || h.isEmpty || h.startsWith('#/dashboard');

/// Hash-history navigation exactly like `N()` / `__granthBack` in the original shell.
class AppNav extends ChangeNotifier {
  AppNav();
  static AppNav I = AppNav();
  String _hash = '#/dashboard';
  GRoute route = const GRoute(Panel.dashboard);
  final List<String> _stack = [];
  int _forward = 1; // +1 = drilling in, -1 = going back (for the shared-axis direction)
  int _lastGo = 0;
  String _lastGoHash = '';
  int _lastBack = 0;
  int _lastDashBack = 0;
  bool menuOpen = false;

  /// Called when the user should see the exit confirmation.
  VoidCallback? onExitRequest;

  String get hash => _hash;
  int get direction => _forward;
  List<String> get debugStack => List.unmodifiable(_stack);

  /// Start-up: the place the user was at, with the stack that leads back from it, so Back
  /// after a restart (process death, task swiped away) walks up exactly like it did before.
  /// A missing or stale stack is rebuilt from the hash itself ([ancestorsOf]) — Back never
  /// jumps somewhere unexpected.
  void restore() {
    final saved = Store.I.ready ? Store.I.getString(Store.kHash) : null;
    if (saved == null || !saved.startsWith('#/')) return;
    _set(saved, notify: false);
    if (_isDash(saved)) return;
    var stack = <String>[];
    try {
      final raw = Store.I.getString('granth-nav');
      if (raw != null) {
        final j = jsonDecode(raw);
        if (j is List) stack = [for (final e in j) if (e is String && e.startsWith('#/') && e != saved) e];
      }
    } catch (_) {}
    // A stack that does not start at the dashboard cannot be trusted to lead anywhere sane.
    if (stack.isEmpty || !_isDash(stack.first)) stack = ancestorsOf(saved);
    _stack
      ..clear()
      ..addAll(stack);
  }

  /// The screens "above" [h], nearest last: granth list → group → religion → religions →
  /// dashboard. Used when the saved back stack is gone.
  @visibleForTesting
  static List<String> ancestorsOf(String h) {
    final r = GRoute.parse(h);
    final out = <String>['#/dashboard'];
    if (r.panel == Panel.dashboard) return const [];
    if (r.panel == Panel.granths && !r.flat) {
      if (r.religionId != null) {
        out.add('#/granths');
        if (r.groupId != null) {
          out.add(GRoute.folderHash(religion: r.religionId));
          if (r.subId != null) out.add(GRoute.folderHash(religion: r.religionId, group: r.groupId));
        }
      }
    } else if (r.panel == Panel.pramans && (r.topicId != null || r.granthId != null) && r.pramanId == null) {
      // A topic's or a granth's pramans: from its list.
      out.add(r.granthId != null ? '#/granths' : '#/topics');
    }
    return out;
  }

  void _persistStack() {
    if (!Store.I.ready) return;
    final s = _stack.length > 24 ? _stack.sublist(_stack.length - 24) : _stack;
    Store.I.setString('granth-nav', jsonEncode(s));
  }

  void _set(String h, {bool notify = true}) {
    final changed = h != _hash;
    _hash = h;
    final next = GRoute.parse(h);
    final before = route;
    route = next;
    if (Store.I.ready) Store.I.setString(Store.kHash, h);
    if (changed || before != next) {
      menuOpen = false;
      if (next.topicId != null) EventLog.I.log('topic_open', next.topicId!);
      if (next.granthId != null) EventLog.I.log('granth_open', next.granthId!);
      if (next.pramanId != null) EventLog.I.log('praman_open', next.pramanId!);
    }
    if (notify) notifyListeners();
  }

  /// `N()`
  void go(String h) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastGoHash == h && now - _lastGo < 400) return;
    _lastGoHash = h;
    _lastGo = now;
    beforeLeave?.call();
    if (_hash == h) {
      route = GRoute.parse(h);
      menuOpen = false;
      notifyListeners();
      return;
    }
    if (h == '#/dashboard' || h == '#/') {
      _stack.clear();
    } else if (_topHashes.contains(h) || _isDash(_hash)) {
      _stack
        ..clear()
        ..add('#/dashboard');
    } else if (_stack.isEmpty || _stack.last != _hash) {
      _stack.add(_hash);
    }
    _forward = 1;
    _persistStack();
    _set(h);
  }

  /// `__granthOpenLink` — deep link: remember where we were.
  void openLink(String h) {
    if (_hash != h) _stack.add(_hash);
    _forward = 1;
    _persistStack();
    _set(h);
  }

  /// Route-level part of `__granthBack` (overlays are popped by the Navigator first).
  void back() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_isDash(_hash)) {
      _stack.clear();
      _persistStack();
      if (now - _lastDashBack > 80 && now - _lastDashBack < 900) {
        _lastDashBack = 0;
        onExitRequest?.call();
      } else {
        _lastDashBack = now;
      }
      return;
    }
    if (now - _lastBack < 260) return;
    _lastBack = now;
    beforeLeave?.call();
    _forward = -1;
    while (_stack.isNotEmpty) {
      final e = _stack.removeLast();
      if (e.isEmpty || e == _hash) continue;
      final dash = _isDash(e);
      if (dash) _stack.clear();
      _persistStack();
      _set(dash ? '#/dashboard' : e);
      return;
    }
    _stack.clear();
    _persistStack();
    _set('#/dashboard');
  }

  void toggleMenu() {
    menuOpen = !menuOpen;
    notifyListeners();
  }

  /// Hook for the shell to remember the scroll place (`yh()`).
  VoidCallback? beforeLeave;

  /// `ae()` — which stat button is lit.
  bool isActive(Panel p) {
    final r = route;
    switch (p) {
      case Panel.topics:
        return r.panel == Panel.topics || (r.panel == Panel.pramans && r.topicId != null && r.granthId == null);
      case Panel.granths:
        return r.panel == Panel.granths || (r.panel == Panel.pramans && r.granthId != null);
      case Panel.pramans:
        return r.panel == Panel.pramans && r.topicId == null && r.granthId == null;
      default:
        return r.panel == p;
    }
  }
}

/// Deep link → hash (`granth://open?topic=…`, `https://granth.grok.me/open?id=…`).
String? hashFromLink(Uri u) {
  final ok = (u.scheme == 'granth') || ((u.scheme == 'https' || u.scheme == 'http') && u.host == 'granth.grok.me' && u.path.startsWith('/open'));
  if (!ok) return null;
  final q = u.queryParameters;
  if ((q['topic'] ?? '').isNotEmpty) return '#/pramans?topic=${q['topic']}';
  if ((q['granth'] ?? '').isNotEmpty) return '#/pramans?granth=${q['granth']}';
  if ((q['id'] ?? '').isNotEmpty) return '#/pramans?id=${q['id']}';
  if (u.fragment.startsWith('/')) return '#${u.fragment}';
  return '#/dashboard';
}
