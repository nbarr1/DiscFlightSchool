import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  factory FormSessionRecord.fromJson(Map<String, dynamic> j) =>
      FormSessionRecord(
        id: j['id'] as String,
        date: DateTime.parse(j['date'] as String),
        score: (j['score'] as num).toDouble(),
        throwType: (j['throwType'] as String?) ?? 'BH',
        proPlayer: j['proPlayer'] as String?,
        frameCount: (j['frameCount'] as num).toInt(),
        avgAngles: (j['avgAngles'] as Map<String, dynamic>? ?? {}).map(
          (k, v) => MapEntry(k, (v as num).toDouble()),
        ),
      );
}

class FormHistoryService extends ChangeNotifier {
  static const _prefsKey = 'form_session_history';
  static const _maxRecords = 50;

  List<FormSessionRecord> _sessions = [];
  List<FormSessionRecord> get sessions => List.unmodifiable(_sessions);

  FormHistoryService() {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = prefs.getStringList(_prefsKey) ?? [];
      _sessions = jsonList.map((s) {
        try {
          return FormSessionRecord.fromJson(
              jsonDecode(s) as Map<String, dynamic>);
        } catch (_) {
          return null;
        }
      }).whereType<FormSessionRecord>().toList();
      notifyListeners();
    } catch (e) {
      debugPrint('FormHistoryService load error: $e');
    }
  }

  Future<void> saveSession(FormSessionRecord record) async {
    _sessions.insert(0, record);
    if (_sessions.length > _maxRecords) {
      _sessions = _sessions.sublist(0, _maxRecords);
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _prefsKey,
        _sessions.map((s) => jsonEncode(s.toJson())).toList(),
      );
    } catch (e) {
      debugPrint('FormHistoryService save error: $e');
    }
  }

  Future<void> clearHistory() async {
    _sessions.clear();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }

  /// Returns the last [n] sessions for a given throw type, oldest first,
  /// for trend charting.
  List<FormSessionRecord> trend(String throwType, {int n = 10}) {
    final filtered =
        _sessions.where((s) => s.throwType == throwType).take(n).toList();
    return filtered.reversed.toList();
  }
}
