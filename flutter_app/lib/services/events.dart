import 'dart:math';

import 'storage.dart';

/// Local-only usage log (`ct()` in the web bundle). Nothing is uploaded; capped at 4000 rows.
class EventLog {
  EventLog._();
  static final EventLog I = EventLog._();
  static const _types = {
    'app_open', 'granth_open', 'topic_open', 'praman_open', 'pdf_open', 'pdf_download',
    'praman_download', 'search', 'search_empty', 'sync', 'feedback', 'request',
  };
  List<Map<String, dynamic>>? _rows;
  Future<void> _queue = Future.value();

  String _device() {
    final s = Store.I;
    final have = s.getString(Store.kDevice);
    if (have != null && have.isNotEmpty) return have;
    final r = Random();
    final id = 'dev${List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join()}';
    s.setString(Store.kDevice, id);
    return id;
  }

  void log(String type, [String entityId = '', String label = '']) {
    if (!_types.contains(type) || !Store.I.ready) return;
    _queue = _queue.then((_) async {
      try {
        _rows ??= ((await Store.I.readJson('events.json')) as List?)?.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() ?? [];
        final now = DateTime.now();
        _rows!.add({
          'type': type,
          'entityId': entityId.length > 80 ? entityId.substring(0, 80) : entityId,
          'label': label.length > 160 ? label.substring(0, 160) : label,
          'device': _device(),
          'at': now.millisecondsSinceEpoch,
          'day': '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
        });
        if (_rows!.length > 4000) _rows!.removeRange(0, _rows!.length - 4000);
        await Store.I.writeJson('events.json', _rows);
      } catch (_) {}
    });
  }
}
