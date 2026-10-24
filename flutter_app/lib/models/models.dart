/// Catalog and gallery models mirroring the JSON served by
/// https://granth.wnmsolutions.com/api/index.php (getTopics / getGranths / getPramans).
library;

import 'dart:convert';

String _s(Object? v) => v == null ? '' : '$v';

class Topic {
  Topic(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw['id']);
  String get title => _s(raw['title']);
  String get description => _s(raw['description']);
  String get position => _s(raw['position']).isEmpty ? '0' : _s(raw['position']);
  int get pramanCount => int.tryParse(_s(raw['praman_count'])) ?? 0;
  int get granthCount => int.tryParse(_s(raw['granth_count'])) ?? 0;
  Map<String, dynamic> toJson() => raw;
}

class Granth {
  Granth(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw['id']);
  String get title => _s(raw['title']);
  String get author => _s(raw['author']).trim();
  String get description => _s(raw['description']);
  String get imagePath => _s(raw['imagePath']);
  String get editorImagePath => _s(raw['editorImagePath']);
  String get granthUrl => _s(raw['granthURL']).trim();
  String get position => _s(raw['position']).isEmpty ? '0' : _s(raw['position']);
  int get pramanCount => int.tryParse(_s(raw['pramanCount'])) ?? 0;
  Map<String, dynamic> toJson() => raw;
}

class Praman {
  Praman(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw['id']);
  String get title => _s(raw['title']);
  String get description => _s(raw['description']);
  bool get isFavorite => _s(raw['is_favorate']) == '1';
  String get topicId => _s(raw['topic_id']);
  String get granthId => _s(raw['granth_id']);
  String get imagePath => _s(raw['image_path']);
  String get youtubeUrl => _s(raw['youtube_url']);
  int get youtubeStart => int.tryParse(_s(raw['youtube_start'])) ?? 0;
  String get youtubeDesc => _s(raw['youtube_desc']);
  String get topicTitle => _s(raw['topic_title']);
  String get granthTitle => _s(raw['granth_title']);
  String get granthImage => _s(raw['granth_image']);
  String get editorImagePath => _s(raw['editorImagePath']);
  String get granthAuthor => _s(raw['granth_auther']);
  Map<String, dynamic> toJson() => raw;
}

class Catalog {
  Catalog({required this.topics, required this.granths, required this.pramans, this.syncedAt, this.contentKey, this.fileText});
  final List<Topic> topics;
  final List<Granth> granths;
  final List<Praman> pramans;
  final int? syncedAt;

  /// [catalogContentKey] when it was already worked out off the UI thread (else null).
  final String? contentKey;

  /// `catalog.json` text when it was already encoded off the UI thread (else null).
  final String? fileText;

  Catalog withSyncedAt(int? t) => Catalog(topics: topics, granths: granths, pramans: pramans, syncedAt: t ?? syncedAt, contentKey: contentKey);

  static Catalog empty() => Catalog(topics: const [], granths: const [], pramans: const []);

  Map<String, dynamic> toJson() => {
        'topics': topics.map((e) => e.raw).toList(),
        'granths': granths.map((e) => e.raw).toList(),
        'pramans': pramans.map((e) => e.raw).toList(),
        'syncedAt': syncedAt,
      };

  static Catalog? fromJson(Object? j) {
    if (j is! Map || j['topics'] is! List) return null;
    List<Map<String, dynamic>> list(Object? v) =>
        v is List ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : <Map<String, dynamic>>[];
    return Catalog(
      topics: list(j['topics']).map(Topic.new).toList(),
      granths: list(j['granths']).map(Granth.new).toList(),
      pramans: list(j['pramans']).map(Praman.new).toList(),
      syncedAt: j['syncedAt'] is num ? (j['syncedAt'] as num).toInt() : int.tryParse('${j['syncedAt']}'),
    );
  }
}

enum GalleryKind { image, pdf }

class GalleryItem {
  GalleryItem({
    required this.id,
    required this.kind,
    required this.title,
    this.text = '',
    this.topic = '',
    this.granth = '',
    this.folderId = '',
    required this.createdAt,
    required this.size,
    required this.fileName,
    required this.filePath,
    this.previewPath,
  });

  final String id;
  final GalleryKind kind;
  final String title;
  final String text;
  final String topic;
  final String granth;
  String folderId;
  final int createdAt;
  final int size;
  final String fileName;
  final String filePath;
  final String? previewPath;

  GalleryItem withFile(String path) => GalleryItem(
        id: id,
        kind: kind,
        title: title,
        text: text,
        topic: topic,
        granth: granth,
        folderId: folderId,
        createdAt: createdAt,
        size: size,
        fileName: fileName,
        filePath: path,
        previewPath: previewPath,
      );

  GalleryItem copyWith({String? folderId}) => GalleryItem(
        id: id,
        kind: kind,
        title: title,
        text: text,
        topic: topic,
        granth: granth,
        folderId: folderId ?? this.folderId,
        createdAt: createdAt,
        size: size,
        fileName: fileName,
        filePath: filePath,
        previewPath: previewPath,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'text': text,
        'topic': topic,
        'granth': granth,
        'folderId': folderId,
        'createdAt': createdAt,
        'size': size,
        'fileName': fileName,
        'filePath': filePath,
        'preview': previewPath,
      };

  static GalleryItem fromJson(Map<String, dynamic> j) => GalleryItem(
        id: _s(j['id']),
        kind: j['kind'] == 'pdf' ? GalleryKind.pdf : GalleryKind.image,
        title: _s(j['title']),
        text: _s(j['text']),
        topic: _s(j['topic']),
        granth: _s(j['granth']),
        folderId: _s(j['folderId']),
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        size: (j['size'] as num?)?.toInt() ?? 0,
        fileName: _s(j['fileName']),
        filePath: _s(j['filePath']),
        previewPath: j['preview'] is String ? j['preview'] as String : null,
      );
}

class GalleryFolder {
  GalleryFolder({required this.id, required this.name});
  final String id;
  final String name;
  Map<String, dynamic> toJson() => {'id': id, 'name': name};
  static GalleryFolder fromJson(Map<String, dynamic> j) => GalleryFolder(id: _s(j['id']), name: _s(j['name']));
}

/// The lists without the sync time: two downloads with the same key carry the same data.
String catalogContentKey(Catalog c) => jsonEncode(c.toJson()..remove('syncedAt'));
