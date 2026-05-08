import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/form_session_record.dart';
export '../models/form_session_record.dart';

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
