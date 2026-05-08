/// One saved form analysis session — lightweight record for history display.
class FormSessionRecord {
  final String id;
  final DateTime date;
  final double score;
  final String throwType; // 'BH' or 'FH'
  final String? proPlayer;
  final int frameCount;
  final Map<String, double> avgAngles; // per-angle averages for trend charting

  FormSessionRecord({
    required this.id,
    required this.date,
    required this.score,
    required this.throwType,
    this.proPlayer,
    required this.frameCount,
    required this.avgAngles,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'score': score,
        'throwType': throwType,
        'proPlayer': proPlayer,
        'frameCount': frameCount,
        'avgAngles': avgAngles,
      };

  factory FormSessionRecord.fromJson(Map<String, dynamic> json) =>
      FormSessionRecord(
        id: json['id'] as String,
        date: DateTime.parse(json['date'] as String),
        score: (json['score'] as num).toDouble(),
        throwType: (json['throwType'] as String?) ?? 'BH',
        proPlayer: json['proPlayer'] as String?,
        frameCount: (json['frameCount'] as num).toInt(),
        avgAngles: (json['avgAngles'] as Map<String, dynamic>? ?? {}).map(
          (key, value) => MapEntry(key, (value as num).toDouble()),
        ),
      );
}
