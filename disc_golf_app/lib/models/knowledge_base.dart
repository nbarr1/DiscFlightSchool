class KBStudy {
  final String id;
  final String title;
  final String authors;
  final int year;
  final String filename;
  final String summary;

  const KBStudy({
    required this.id,
    required this.title,
    required this.authors,
    required this.year,
    required this.filename,
    required this.summary,
  });

  factory KBStudy.fromJson(Map<String, dynamic> json) {
    return KBStudy(
      id: json['id'] as String,
      title: json['title'] as String,
      authors: json['authors'] as String,
      year: json['year'] as int,
      filename: json['filename'] as String,
      summary: json['summary'] as String,
    );
  }

  String get citation => '$authors ($year)';
}

class KBArticle {
  final String id;
  final String category;
  final String type; // "faq" or "tip"
  final String question;
  final String answer;
  final List<String> keyFindings;
  final List<String> sourceIds;

  const KBArticle({
    required this.id,
    required this.category,
    required this.type,
    required this.question,
    required this.answer,
    this.keyFindings = const [],
    this.sourceIds = const [],
  });

  factory KBArticle.fromJson(Map<String, dynamic> json) {
    return KBArticle(
      id: json['id'] as String,
      category: json['category'] as String,
      type: json['type'] as String,
      question: json['question'] as String,
      answer: json['answer'] as String,
      keyFindings: (json['keyFindings'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      sourceIds: (json['sourceIds'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }

  bool get isFaq => type == 'faq';
  bool get isTip => type == 'tip';
}

class KBCategory {
  final String id;
  final String name;
  final String iconName;
  final int colorValue;
  final String description;

  const KBCategory({
    required this.id,
    required this.name,
    required this.iconName,
    required this.colorValue,
    required this.description,
  });

  factory KBCategory.fromJson(Map<String, dynamic> json) {
    return KBCategory(
      id: json['id'] as String,
      name: json['name'] as String,
      iconName: json['iconName'] as String,
      colorValue: json['colorValue'] as int,
      description: json['description'] as String,
    );
  }
}
