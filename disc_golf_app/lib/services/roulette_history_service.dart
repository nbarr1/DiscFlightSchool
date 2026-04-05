import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/roulette_data.dart';

/// Persists up to [_maxEntries] Disc Roulette spins in SharedPreferences.
class RouletteHistoryService extends ChangeNotifier {
  static const _key = 'roulette_spin_history';
  static const int _maxEntries = 200;

  List<RouletteResult> _history = [];
  List<RouletteResult> get history => List.unmodifiable(_history);

  RouletteHistoryService() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _history = list
          .map((e) => RouletteResult.fromJson(e as Map<String, dynamic>))
          .toList();
      notifyListeners();
    } catch (e) {
      debugPrint('RouletteHistoryService: failed to load history: $e');
    }
  }

  Future<void> addResult(RouletteResult result) async {
    _history.insert(0, result); // newest first
    if (_history.length > _maxEntries) {
      _history = _history.sublist(0, _maxEntries);
    }
    notifyListeners();
    await _persist();
  }

  Future<void> clearHistory() async {
    _history.clear();
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(_history.map((r) => r.toJson()).toList()));
  }
}
